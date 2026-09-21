-- Proyecta la generacion renovable copiando una semana historica parecida.
--
-- EL METODO
-- Se toma la ultima semana observada y se busca en el historico la semana que
-- mas se le parece. Si esta semana se comporta como la semana W de 2025, la
-- que viene se parecera a W+1: el horizonte se llena con las semanas que
-- siguieron a la elegida. Asi se conserva la correlacion entre dias
-- consecutivos y entre plantas, que se perderia promediando.
--
-- El parecido se mide sobre el perfil agregado de todas las renovables a media
-- hora, con la raiz del error cuadratico medio. Se compara el agregado y no
-- cada planta por separado porque lo que importa es el aporte conjunto al
-- despacho, y porque una planta nueva sin historico ensuciaria la distancia.
--
-- Solo se consideran semanas de la misma epoca del anio: la irradiacion y el
-- viento son estacionales, y la semana mas parecida en enero no dice nada
-- sobre una de julio.

SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-09-20');
SET VARIABLE fecha_fin = COALESCE(getvariable('fecha_fin'), '2026-10-17');
-- Cuanto se puede alejar la candidata, en dias del calendario, de la fecha que
-- se quiere proyectar.
SET VARIABLE estacional_dias = COALESCE(getvariable('estacional_dias'), 35);
-- Las semanas inmediatamente anteriores no son candidatas: se solapan con la
-- referencia y ganarian por construccion sin aportar informacion.
SET VARIABLE guarda_dias = COALESCE(getvariable('guarda_dias'), 21);
-- Ventana para medir la capacidad de cada planta: el mayor MW que alcanzo en
-- esos dias. Corta, y se pierde una planta que no tuvo un buen dia; larga, y
-- no se entera de una ampliacion.
SET VARIABLE dias_capacidad = COALESCE(getvariable('dias_capacidad'), 120);

-- Generacion renovable observada, por planta Yupana y media hora.
CREATE OR REPLACE TEMP TABLE rer AS
SELECT r.id_yupana, r.nombre, m.fecha, m.slot, sum(m.valor) AS mw
FROM crudo.medicion m
JOIN dim.rer r ON r.cod_equipo = m.cod_equipo
WHERE m.lectcodi = 6 AND m.magnitud = 'MW'
GROUP BY ALL;

-- La referencia: la ultima semana con datos completos.
CREATE OR REPLACE TEMP TABLE referencia AS
WITH fin AS (
    -- Un dia con menos de 48 medias horas esta a medio publicar y falsearia
    -- la comparacion.
    SELECT max(fecha) AS ultimo FROM (
        SELECT fecha FROM rer GROUP BY fecha HAVING count(DISTINCT slot) = 48)
)
SELECT r.slot,
       (r.fecha - (SELECT ultimo FROM fin)) + 6 AS dia_rel,
       sum(r.mw) AS mw
FROM rer r, fin
WHERE r.fecha BETWEEN fin.ultimo - 6 AND fin.ultimo
GROUP BY ALL;

-- Distancia de cada semana candidata a la referencia.
CREATE OR REPLACE TEMP TABLE candidata AS
WITH agregado AS (
    SELECT fecha, slot, sum(mw) AS mw FROM rer GROUP BY ALL
),
inicio AS (
    SELECT DISTINCT fecha AS desde FROM agregado
),
ventana AS (
    SELECT i.desde, a.slot, (a.fecha - i.desde) AS dia_rel, a.mw
    FROM inicio i
    JOIN agregado a ON a.fecha BETWEEN i.desde AND i.desde + 6
)
SELECT v.desde,
       sqrt(avg((v.mw - r.mw) * (v.mw - r.mw))) AS rmse,
       count(*) AS puntos
FROM ventana v
JOIN referencia r ON r.slot = v.slot AND r.dia_rel = v.dia_rel
GROUP BY v.desde
-- Una semana incompleta no se compara: 7 dias por 48 medias horas.
HAVING count(*) = 336;

-- La elegida, una por cada semana del horizonte.
CREATE OR REPLACE TEMP TABLE elegida AS
WITH semanas AS (
    SELECT d::DATE AS desde,
           (d::DATE - getvariable('fecha_ini')::DATE) / 7 AS n
    FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                                getvariable('fecha_fin')::DATE,
                                INTERVAL 7 DAY)) t(d)
),
-- El ultimo dia con las 48 medias horas publicadas. max(fecha) serviria de
-- poco: el dia en curso suele estar a medias.
ultimo AS (
    SELECT max(fecha) AS f FROM (
        SELECT fecha FROM rer GROUP BY fecha HAVING count(DISTINCT slot) = 48)
),
mejor AS (
    -- La semana base: la mas parecida a la referencia, fuera de la guarda y
    -- dentro de la epoca del anio de la primera semana del horizonte.
    SELECT c.desde
    FROM candidata c, ultimo u
    -- La base tiene que dejar sitio a todas las semanas que le siguen: si el
    -- horizonte son cuatro semanas, la base y las tres siguientes deben estar
    -- completas en el historico.
    WHERE c.desde + (SELECT (max(n) + 1) * 7 FROM semanas)::INT <= u.f + 1
      AND c.desde <= u.f - getvariable('guarda_dias')::INT
      AND abs(dayofyear(c.desde)
              - dayofyear(getvariable('fecha_ini')::DATE)) % 365
          <= getvariable('estacional_dias')::INT
    ORDER BY c.rmse LIMIT 1
)
SELECT s.desde AS semana, s.n,
       -- La semana base para la primera, y las que le siguieron para el resto.
       (SELECT desde FROM mejor) + (s.n * 7)::INT AS analoga
FROM semanas s;

-- LA CAPACIDAD, QUE NO ES LA MISMA ENTONCES QUE AHORA
-- No se copian los MW tal cual. Entre la semana analoga y el horizonte entran
-- plantas nuevas y se amplian las que habia: el pico simultaneo del parque RER
-- paso de 1879 MW en septiembre de 2025 a 2189 en febrero de 2026. Copiar MW
-- crudos arrastra la capacidad vieja y subestima, sin avisar. Se copia el
-- factor de planta (lo que genero sobre lo que podia) y se multiplica por la
-- capacidad de ahora.
CREATE OR REPLACE TEMP TABLE capacidad AS
WITH ultimo AS (
    SELECT max(fecha) AS f FROM (
        SELECT fecha FROM rer GROUP BY fecha HAVING count(DISTINCT slot) = 48)
)
SELECT r.id_yupana,
       max(r.mw) FILTER (
           WHERE r.fecha > u.f - getvariable('dias_capacidad')::INT) AS mw_hoy,
       max(r.mw) FILTER (WHERE r.fecha BETWEEN e.analoga - 60 AND e.analoga + 60)
           AS mw_entonces
FROM rer r, ultimo u, (SELECT min(analoga) AS analoga FROM elegida) e
GROUP BY r.id_yupana;

CREATE OR REPLACE TABLE crudo.rer_proyectado AS
SELECT e.semana + (r.fecha - e.analoga)::INT AS fecha,
       r.slot, r.id_yupana, r.nombre,
       -- Sin capacidad de entonces (planta que no existia) el factor no se
       -- puede calcular y se deja el MW tal cual, que es lo conservador.
       round(r.mw * coalesce(c.mw_hoy / nullif(c.mw_entonces, 0), 1.0), 4) AS mw,
       e.analoga AS origen,
       coalesce(c.mw_hoy / nullif(c.mw_entonces, 0), 1.0) AS factor_capacidad
FROM elegida e
JOIN rer r ON r.fecha BETWEEN e.analoga AND e.analoga + 6
LEFT JOIN capacidad c ON c.id_yupana = r.id_yupana
WHERE e.semana + (r.fecha - e.analoga)::INT
      BETWEEN getvariable('fecha_ini')::DATE AND getvariable('fecha_fin')::DATE;

CREATE OR REPLACE VIEW crudo.control_rer_capacidad AS
-- INFORMATIVA: cuanto se corrigio cada planta por cambio de capacidad. Un
-- factor muy distinto de 1 es una ampliacion o una planta nueva; uno de
-- exactamente 1 en una planta que si existia significa que no se pudo medir.
SELECT id_yupana, any_value(nombre) AS nombre,
       round(any_value(factor_capacidad), 3) AS factor
FROM crudo.rer_proyectado GROUP BY id_yupana
HAVING abs(any_value(factor_capacidad) - 1) > 0.02
ORDER BY factor DESC;

CREATE OR REPLACE VIEW crudo.control_rer_analoga AS
-- INFORMATIVA: que semana historica se copio en cada una del horizonte, y con
-- que error respecto de la referencia.
SELECT e.semana, e.analoga, round(c.rmse, 2) AS rmse_mw
FROM elegida e LEFT JOIN candidata c ON c.desde = e.analoga ORDER BY e.semana;

CREATE OR REPLACE VIEW crudo.control_rer_faltante AS
-- DEBE SER 0: una media hora del horizonte sin proyeccion queda en cero, lo
-- que Yupana lee como planta sin generar.
SELECT d::DATE AS fecha, s AS slot
FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                            getvariable('fecha_fin')::DATE, INTERVAL 1 DAY)) t(d)
CROSS JOIN unnest(generate_series(1, 48)) u(s)
WHERE NOT EXISTS (SELECT 1 FROM crudo.rer_proyectado p
                  WHERE p.fecha = d::DATE AND p.slot = s);
