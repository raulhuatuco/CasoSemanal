-- Mide cuanto acierta la prelacion, comparandola con lo que de verdad paso.
--
-- Se puede hacer porque el archivo del portal conserva los programas viejos:
-- para junio de 2026 todavia devuelve el diario, el semanal y el mensual de
-- entonces, junto a los ejecutados. Se corre 10_vigente.sql sin dejarle ver
-- los ejecutados y se compara contra ellos.
--
--   10_vigente.sql con anclaje='evento' y sin_ejecutados=true
--   luego este script
--
-- Referencia medida sobre junio de 2026 (28 dias):
--   capturado 91,1%  |  falsos positivos 102  |  escapados 195
-- De los escapados, 124 son FORZADO: fallas, que por definicion ningun
-- programa anticipa. Esa es la cota practica, no un defecto de la regla.

CREATE OR REPLACE TEMP TABLE backtest_verdad AS
SELECT DISTINCT d::DATE AS dia, cod_eq
FROM crudo.mtto,
     unnest(generate_series(inicio::DATE, final::DATE, INTERVAL 1 DAY)) t(d)
WHERE programa = 'EJECUTADOS'
  AND (NOT getvariable('solo_fs') OR indisponibilidad = 'F/S')
  AND d::DATE BETWEEN getvariable('fecha_ini')::DATE
                  AND getvariable('fecha_fin')::DATE;

CREATE OR REPLACE VIEW crudo.control_backtest AS
-- INFORMATIVA: cuanto de lo que paso estaba anunciado.
WITH p AS (SELECT DISTINCT fecha AS dia, cod_equipo AS cod_eq
           FROM crudo.mtto_vigente)
SELECT count(*) FILTER (WHERE v.cod_eq IS NOT NULL AND p.cod_eq IS NOT NULL) AS acierto,
       count(*) FILTER (WHERE v.cod_eq IS NULL)  AS falso_positivo,
       count(*) FILTER (WHERE p.cod_eq IS NULL)  AS escapado,
       round(100.0 * count(*) FILTER (WHERE v.cod_eq IS NOT NULL AND p.cod_eq IS NOT NULL)
             / nullif(count(*) FILTER (WHERE v.cod_eq IS NOT NULL), 0), 1) AS pct_capturado
FROM backtest_verdad v FULL OUTER JOIN p USING (dia, cod_eq);

CREATE OR REPLACE VIEW crudo.control_escapado AS
-- INFORMATIVA: que naturaleza tiene lo que se escapa. Si domina FORZADO, la
-- regla esta bien y el limite es la realidad; si domina PROGRAMADO, hay que
-- revisar los horizontes de vigencia.
WITH p AS (SELECT DISTINCT fecha AS dia, cod_equipo AS cod_eq
           FROM crudo.mtto_vigente),
esc AS (SELECT v.* FROM backtest_verdad v
        LEFT JOIN p USING (dia, cod_eq) WHERE p.cod_eq IS NULL)
SELECT m.prog, m.tipo_eq_osinerg, count(*) AS n
FROM esc JOIN crudo.mtto m
       ON m.cod_eq = esc.cod_eq AND m.programa = 'EJECUTADOS'
      AND esc.dia BETWEEN m.inicio::DATE AND m.final::DATE
GROUP BY ALL ORDER BY n DESC;
