-- Proyeccion RER por perfil tipico, en factor de planta por media hora y escalada a
-- la capacidad actual. Metodo segun tecnologia:
--   solar, eolica  50 % ultimos 28 dias + 50 % misma epoca del anio pasado (+-15 d)
--   otras          ultima semana (hidro de pasada, biomasa)
-- Reemplaza a la semana analoga; comparacion medida en motor/README.md.

SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-09-20');
SET VARIABLE fecha_fin = COALESCE(getvariable('fecha_fin'), '2026-10-17');
-- Capacidad = mayor MW de la planta en esta ventana.
SET VARIABLE dias_capacidad = COALESCE(getvariable('dias_capacidad'), 120);
-- Dias del perfil reciente.
SET VARIABLE rer_dias_recientes = COALESCE(getvariable('rer_dias_recientes'), 28);
SET VARIABLE rer_dias_otras     = COALESCE(getvariable('rer_dias_otras'), 7);
-- Medio ancho de la ventana anual y peso de lo reciente (solar y eolica).
SET VARIABLE rer_ventana_anual  = COALESCE(getvariable('rer_ventana_anual'), 15);
SET VARIABLE rer_peso_reciente  = COALESCE(getvariable('rer_peso_reciente'), 0.5);

-- Tecnologia por prefijo COES (C.S./G.S. solar, C.E. eolica). Se lee de dim.equipo:
-- en los cruces manuales dim.rer.equipo_coes dice 'manual'.
CREATE OR REPLACE TEMP TABLE planta AS
SELECT r.id_yupana, any_value(r.nombre) AS nombre,
       CASE WHEN bool_or(regexp_matches(e.equipo, '^(C\.S\.|G\.S\.)')) THEN 'solar'
            WHEN bool_or(e.equipo LIKE 'C.E.%') THEN 'eolica'
            ELSE 'otras' END AS tec
FROM dim.rer r JOIN dim.equipo e USING (cod_equipo)
GROUP BY r.id_yupana;

-- Generacion observada por planta Yupana y media hora.
CREATE OR REPLACE TEMP TABLE obs AS
SELECT r.id_yupana, m.fecha, m.slot, sum(m.valor) AS mw
FROM crudo.medicion m
JOIN dim.rer r ON r.cod_equipo = m.cod_equipo
WHERE m.lectcodi = 6 AND m.magnitud = 'MW'
GROUP BY ALL;

-- Ultimo dia completo (48 medias horas).
CREATE OR REPLACE TEMP TABLE ultimo AS
SELECT max(fecha) AS f FROM (
    SELECT fecha FROM obs GROUP BY fecha HAVING count(DISTINCT slot) = 48);

-- Rejilla densa desde la primera medicion: sin dato cuenta como 0 MW.
CREATE OR REPLACE TEMP TABLE serie AS
WITH vida AS (
    SELECT id_yupana, min(fecha) AS desde FROM obs GROUP BY id_yupana
),
dias AS (
    SELECT d::DATE AS fecha
    FROM (SELECT min(fecha) AS a FROM obs), ultimo u,
         unnest(generate_series(a, u.f, INTERVAL 1 DAY)) t(d)
),
rejilla AS (
    SELECT v.id_yupana, d.fecha, w.s::TINYINT AS slot
    FROM vida v
    JOIN dias d ON d.fecha >= v.desde
    CROSS JOIN unnest(generate_series(1, 48)) w(s)
)
SELECT g.id_yupana, g.fecha, g.slot, coalesce(o.mw, 0) AS mw
FROM rejilla g
LEFT JOIN obs o USING (id_yupana, fecha, slot);

-- Factor de planta contra la capacidad movil de cada dia, para que ampliaciones y
-- plantas nuevas no arrastren la capacidad vieja.
CREATE OR REPLACE TEMP TABLE fp AS
WITH diario AS (
    SELECT id_yupana, fecha, max(mw) AS pico FROM serie GROUP BY ALL
),
cap AS (
    SELECT id_yupana, fecha,
           max(pico) OVER (PARTITION BY id_yupana ORDER BY fecha
               RANGE BETWEEN to_days(getvariable('dias_capacidad')::INT - 1) PRECEDING
                         AND CURRENT ROW) AS cap
    FROM diario
)
SELECT s.id_yupana, s.fecha, s.slot, s.mw / nullif(c.cap, 0) AS fp
FROM serie s JOIN cap c USING (id_yupana, fecha);

CREATE OR REPLACE TEMP TABLE capacidad AS
SELECT s.id_yupana, max(s.mw) AS cap_mw
FROM serie s, ultimo u
WHERE s.fecha > u.f - getvariable('dias_capacidad')::INT
GROUP BY s.id_yupana;

CREATE OR REPLACE TEMP TABLE reciente AS
SELECT f.id_yupana, f.slot, avg(f.fp) AS fp
FROM fp f JOIN planta p USING (id_yupana), ultimo u
WHERE f.fecha > u.f - CASE p.tec WHEN 'otras'
                               THEN getvariable('rer_dias_otras')::INT
                               ELSE getvariable('rer_dias_recientes')::INT END
GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE horizonte AS
SELECT d::DATE AS fecha
FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                            getvariable('fecha_fin')::DATE, INTERVAL 1 DAY)) t(d);

-- Perfil del anio pasado, con ventana movil por dia del horizonte. Exige 2/3 de los
-- dias de la ventana; si no, la planta usa solo el perfil reciente.
CREATE OR REPLACE TEMP TABLE anual AS
SELECT h.fecha, f.id_yupana, f.slot, avg(f.fp) AS fp
FROM horizonte h
JOIN fp f ON f.fecha BETWEEN h.fecha - 364 - getvariable('rer_ventana_anual')::INT
                         AND h.fecha - 364 + getvariable('rer_ventana_anual')::INT
JOIN planta p USING (id_yupana)
WHERE p.tec <> 'otras'
GROUP BY ALL
HAVING count(f.fp) >= (2 * getvariable('rer_ventana_anual')::INT + 1) * 2 / 3;

CREATE OR REPLACE TABLE crudo.rer_proyectado AS
SELECT h.fecha, w.s::TINYINT AS slot, p.id_yupana, p.nombre, p.tec,
       -- Sin capacidad: 0 MW (ver control_rer_parada).
       round(coalesce(c.cap_mw * CASE
           WHEN a.fp IS NULL THEN r.fp
           ELSE getvariable('rer_peso_reciente')::DOUBLE * r.fp
              + (1 - getvariable('rer_peso_reciente')::DOUBLE) * a.fp END, 0), 4) AS mw,
       CASE WHEN p.tec = 'otras' THEN 'ultima semana'
            WHEN a.fp IS NULL   THEN 'solo reciente'
            ELSE 'reciente + anio pasado' END AS metodo,
       coalesce(c.cap_mw, 0) AS cap_mw
FROM horizonte h
CROSS JOIN planta p
CROSS JOIN unnest(generate_series(1, 48)) w(s)
LEFT JOIN capacidad c ON c.id_yupana = p.id_yupana
LEFT JOIN reciente r  ON r.id_yupana = p.id_yupana AND r.slot = w.s
LEFT JOIN anual a     ON a.fecha = h.fecha AND a.id_yupana = p.id_yupana
                     AND a.slot = w.s;

-- Controles del metodo anterior.
DROP VIEW IF EXISTS crudo.control_rer_analoga;
DROP VIEW IF EXISTS crudo.control_rer_capacidad;

CREATE OR REPLACE VIEW crudo.control_rer_perfil AS
-- INFORMATIVA: metodo, capacidad y factor de planta medio por planta.
-- 'solo reciente' en solar/eolica = menos de un anio de historia.
SELECT id_yupana, any_value(nombre) AS nombre, any_value(tec) AS tec,
       any_value(metodo) AS metodo,
       round(any_value(cap_mw), 1) AS cap_mw,
       round(avg(mw) / nullif(any_value(cap_mw), 0), 3) AS fp,
       round(sum(mw) / 2, 0) AS mwh
FROM crudo.rer_proyectado GROUP BY id_yupana
ORDER BY tec, cap_mw DESC;

CREATE OR REPLACE VIEW crudo.control_rer_parada AS
-- REVISAR: plantas sin generacion en la ventana de capacidad (baja, mantenimiento
-- largo o cruce equivocado). Salen en 0 todo el horizonte.
SELECT DISTINCT id_yupana, nombre, tec
FROM crudo.rer_proyectado WHERE cap_mw = 0;

CREATE OR REPLACE VIEW crudo.control_rer_faltante AS
-- DEBE SER 0: medias horas del horizonte sin proyeccion.
SELECT d::DATE AS fecha, s AS slot
FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                            getvariable('fecha_fin')::DATE, INTERVAL 1 DAY)) t(d)
CROSS JOIN unnest(generate_series(1, 48)) u(s)
WHERE NOT EXISTS (SELECT 1 FROM crudo.rer_proyectado p
                  WHERE p.fecha = d::DATE AND p.slot = s);
