-- Proyecta los aportes (4/2 y 19/6) del horizonte desde el caudal natural.
--
-- 1. Por estacion natural: log Q(d) = clima(d) + phi(k) * anomalia de la
--    ultima semana, k = semana de anticipacion. clima es la media de log del
--    caudal de 7 dias en ese dia del anio (2017->); phi y el sesgo de volver
--    del log se ajustan con toda la historia. La anomalia de hoy se diluye
--    hacia la climatologia con la anticipacion.
-- 2. Por equipo: aporte del caso base x Qproy(d) / Qobs(semana del caso base).
--    La estacion de cada equipo esta en dim.caudal_estacion. Sin estacion, el
--    aporte del caso base se repite. El embalse de regulacion estacional no
--    se estima: su aporte sale del plan de descargas, no de la lluvia.
-- Backtest y numeros: tools/backtest_caudal.py y README.

SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-09-20');
SET VARIABLE fecha_fin = COALESCE(getvariable('fecha_fin'), '2026-10-17');
SET VARIABLE base_restricciones = COALESCE(getvariable('base_restricciones'),
    '../caso_base/YUPANA_SEM2326/datosrestricciones.csv');

-- Del metodo anterior (persistencia y reporte de programacion).
DROP VIEW IF EXISTS crudo.control_caudal_sin_factor;
DROP VIEW IF EXISTS crudo.control_caudal_fuente;

CREATE OR REPLACE TEMP TABLE nat AS
WITH d AS (
    SELECT equipo AS estacion, fecha, avg(m3s) AS q
    FROM crudo.caudal_web
    WHERE tipo_caudal = 'CAUDAL NATURAL ESTIMADO' AND m3s > 0
    GROUP BY ALL          -- TOMA CAHUA informa 2 a 4 horas por dia
)
SELECT estacion, fecha, q,
       least(dayofyear(fecha), 365) AS dia,
       avg(q) OVER w7c AS q7c, count(*) OVER w7c AS n7c,
       avg(q) OVER w7t AS q7t, count(*) OVER w7t AS n7t
FROM d
WINDOW w7c AS (PARTITION BY estacion ORDER BY fecha
               RANGE BETWEEN INTERVAL 3 DAY PRECEDING AND INTERVAL 3 DAY FOLLOWING),
       w7t AS (PARTITION BY estacion ORDER BY fecha
               RANGE BETWEEN INTERVAL 6 DAY PRECEDING AND CURRENT ROW);

-- Climatologia circular, suavizada +-7 dias para no copiar el ruido de un anio.
CREATE OR REPLACE TEMP TABLE clima AS
WITH c AS (
    SELECT estacion, dia, avg(ln(q7c)) AS lc
    FROM nat WHERE n7c >= 5 GROUP BY ALL
)
SELECT a.estacion, a.dia, avg(b.lc) AS lc
FROM c a JOIN c b ON b.estacion = a.estacion
 AND least(abs(a.dia - b.dia), 365 - abs(a.dia - b.dia)) <= 7
GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE anom AS
SELECT n.estacion, n.fecha, n.dia,
       CASE WHEN n.n7t >= 5 THEN ln(n.q7t) - ct.lc END AS x,   -- semana que cierra
       CASE WHEN n.n7c >= 5 THEN ln(n.q7c) - cc.lc END AS y,   -- centrada en el dia
       cc.lc
FROM nat n
JOIN clima ct ON ct.estacion = n.estacion
             AND ct.dia = CASE WHEN n.dia > 3 THEN n.dia - 3 ELSE n.dia + 362 END
JOIN clima cc ON cc.estacion = n.estacion AND cc.dia = n.dia;

-- phi(k) por minimos cuadrados sin constante, de todos los origenes de la
-- historia. sesgo(k) devuelve del log sin perder volumen: suma real / suma
-- proyectada (la media de exp(residuo) sobrecorrige +5 %).
CREATE OR REPLACE TABLE crudo.caudal_phi AS
WITH p AS (
    SELECT (ceil(l / 7.0))::INT AS k, o.x, f.y, f.lc
    FROM anom o
    CROSS JOIN range(1, 57) t(l)
    JOIN anom f ON f.estacion = o.estacion AND f.fecha = o.fecha + t.l::INT
    WHERE o.x IS NOT NULL AND f.y IS NOT NULL
      AND dayofweek(o.fecha) = 0          -- un origen por semana basta
),
phi AS (SELECT k, sum(x * y) / sum(x * x) AS phi, count(*) AS n FROM p GROUP BY k)
SELECT phi.k, phi.phi,
       sum(exp(p.lc + p.y)) / sum(exp(p.lc + phi.phi * p.x)) AS sesgo, phi.n
FROM phi JOIN p USING (k) GROUP BY ALL ORDER BY k;

-- Ultima semana observada de cada estacion, hasta la vispera del horizonte.
CREATE OR REPLACE TEMP TABLE ref AS
SELECT a.estacion, a.fecha AS fecha_ref, a.x AS anomalia
FROM anom a
JOIN (SELECT estacion, max(fecha) AS f FROM anom
      WHERE x IS NOT NULL AND fecha < getvariable('fecha_ini')::DATE
      GROUP BY 1) u ON u.estacion = a.estacion AND u.f = a.fecha;

CREATE OR REPLACE TEMP TABLE horizonte AS
SELECT d::DATE AS fecha, least(dayofyear(d::DATE), 365) AS dia
FROM range(getvariable('fecha_ini')::DATE,
           getvariable('fecha_fin')::DATE + 1, INTERVAL 1 DAY) t(d);

CREATE OR REPLACE TABLE crudo.caudal_natural_proy AS
SELECT r.estacion, h.fecha, (h.fecha - r.fecha_ref) AS anticipacion,
       exp(c.lc + p.phi * r.anomalia) * p.sesgo AS m3s,
       r.anomalia, p.phi
FROM ref r CROSS JOIN horizonte h
JOIN clima c ON c.estacion = r.estacion AND c.dia = h.dia
JOIN crudo.caudal_phi p
  ON p.k = least(ceil((h.fecha - r.fecha_ref) / 7.0)::INT,
                 (SELECT max(k) FROM crudo.caudal_phi));

-- Aportes del caso base: nivel de cada equipo y su semana.
CREATE OR REPLACE TEMP TABLE base AS
WITH b AS (
    SELECT * FROM read_csv(getvariable('base_restricciones'), header = true,
                           all_varchar = true)
),
l AS (
    UNPIVOT b ON COLUMNS(* EXCLUDE ("Equipo", "Descripcion equipo",
        "Categoria equipo", "Descripcion categoria", "Restriccion",
        "Desc. Restriccion", "Fecha:"))
    INTO NAME hora VALUE v
)
SELECT "Categoria equipo"::INT AS categoria, "Restriccion"::INT AS restriccion,
       "Equipo"::INT AS id_yupana, any_value("Descripcion equipo") AS equipo_yupana,
       avg(v::DOUBLE) AS m3s_base,
       min("Fecha:"::DATE) AS desde, max("Fecha:"::DATE) AS hasta
FROM l
WHERE ("Categoria equipo", "Restriccion") IN (('4', '2'), ('19', '6'))
GROUP BY ALL;

CREATE OR REPLACE TABLE crudo.caudal_equipo AS
SELECT b.*, nullif(trim(m.estacion), '') AS estacion,
       coalesce(nullif(trim(m.relacion), ''),
                CASE m.regulacion WHEN 'estacional' THEN 'embalse estacional'
                                  ELSE 'sin estacion' END) AS relacion,
       m.regulacion,
       (SELECT avg(n.q) FROM nat n WHERE n.estacion = m.estacion
          AND n.fecha BETWEEN b.desde AND b.hasta) AS natural_base
FROM base b
LEFT JOIN dim.caudal_estacion m
       ON m.categoria = b.categoria AND m.id_yupana = b.id_yupana;

CREATE OR REPLACE TABLE crudo.caudal_proyectado AS
SELECT h.fecha, s.slot::TINYINT AS slot, e.id_yupana, e.equipo_yupana,
       e.categoria, e.restriccion,
       round(e.m3s_base * coalesce(p.m3s / nullif(e.natural_base, 0), 1.0), 5) AS m3s,
       coalesce(p.m3s / nullif(e.natural_base, 0), 1.0) AS factor
FROM crudo.caudal_equipo e
CROSS JOIN horizonte h
CROSS JOIN range(1, 49) s(slot)
LEFT JOIN crudo.caudal_natural_proy p
       ON p.estacion = e.estacion AND p.fecha = h.fecha;

CREATE OR REPLACE TABLE crudo.control_caudal_equipo AS
SELECT e.categoria, e.id_yupana, e.equipo_yupana, e.estacion, e.relacion,
       round(e.m3s_base, 2) AS base, round(e.natural_base, 2) AS natural_base,
       round(e.m3s_base / nullif(e.natural_base, 0), 3) AS escala,
       round(avg(p.factor) FILTER (WHERE p.fecha < getvariable('fecha_ini')::DATE + 7), 3) AS f_sem1,
       round(avg(p.factor) FILTER (WHERE p.fecha >= getvariable('fecha_ini')::DATE + 21), 3) AS f_sem4
FROM crudo.caudal_equipo e JOIN crudo.caudal_proyectado p USING (categoria, id_yupana)
GROUP BY ALL ORDER BY 1, 2;
COMMENT ON TABLE crudo.control_caudal_equipo IS
    'INFORMATIVA: estacion de cada equipo, su nivel y el factor medio por semana.';

CREATE OR REPLACE TABLE crudo.control_caudal_sin_estacion AS
SELECT categoria, id_yupana, equipo_yupana, estacion, relacion
FROM crudo.caudal_equipo
WHERE estacion IS NULL OR natural_base IS NULL
   OR estacion NOT IN (SELECT estacion FROM ref);
COMMENT ON TABLE crudo.control_caudal_sin_estacion IS
    'INFORMATIVA: equipos que repiten el aporte del caso base (sin estacion o sin natural en la semana del caso base). Revisar dim.caudal_estacion.';

CREATE OR REPLACE TABLE crudo.control_caudal_dato_viejo AS
SELECT estacion, fecha_ref, getvariable('fecha_ini')::DATE - fecha_ref AS dias
FROM ref WHERE getvariable('fecha_ini')::DATE - fecha_ref > 3;
COMMENT ON TABLE crudo.control_caudal_dato_viejo IS
    'DEBE SER 0: estaciones cuyo ultimo dato es de mas de 3 dias antes del horizonte. Falta correr tools/coes_caudal.py.';

CREATE OR REPLACE TABLE crudo.resumen_caudal_semanal AS
SELECT categoria, id_yupana, equipo_yupana,
       1 + (fecha - getvariable('fecha_ini')::DATE) // 7 AS semana,
       min(fecha) AS desde, round(avg(m3s), 2) AS m3s
FROM crudo.caudal_proyectado GROUP BY ALL ORDER BY 1, 2, 4;
COMMENT ON TABLE crudo.resumen_caudal_semanal IS
    'INFORMATIVA: aporte medio proyectado por equipo y semana del horizonte (m3/s).';
