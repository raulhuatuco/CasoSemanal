-- El resultado del modulo: un intervalo por equipo de Yupana, ya convertido a
-- sus equivalentes, sin duplicados ni solapamientos. Es lo unico que hay que
-- mirar; los pasos anteriores son preproceso.
--
-- Como se arma: la indisponibilidad ya viene resuelta por media hora en
-- crudo.indisp_yupana (ahi se consolidan los equivalentes y se resuelve la
-- prelacion), asi que aqui solo se pegan las medias horas seguidas que tienen
-- el mismo valor. Dos eventos que se solapaban salieron de alli como un solo
-- valor por media hora, y por eso el resultado no puede solaparse.
CREATE OR REPLACE TABLE crudo.mantenimiento_final AS
WITH s AS (
    SELECT tipo, id_yupana, equipo, indisponibilidad,
           fecha + ((slot - 1) * INTERVAL 30 MINUTE) AS inicio,
           fecha + (slot * INTERVAL 30 MINUTE) AS fin,
           row_number() OVER (PARTITION BY tipo, id_yupana
                              ORDER BY fecha, slot) AS n
    FROM crudo.indisp_yupana
    WHERE indisponibilidad > 0
),
-- Un tramo nuevo empieza donde cambia el valor o hay un hueco de media hora.
p AS (
    SELECT *, lag(fin) OVER w AS fin_previo,
              lag(indisponibilidad) OVER w AS valor_previo
    FROM s WINDOW w AS (PARTITION BY tipo, id_yupana ORDER BY n)
),
g AS (
    SELECT *, sum(CASE WHEN inicio = fin_previo
                        AND indisponibilidad = valor_previo THEN 0 ELSE 1 END)
              OVER (PARTITION BY tipo, id_yupana ORDER BY n) AS grupo
    FROM p
)
SELECT tipo, id_yupana, equipo,
       min(inicio) AS inicio, max(fin) AS fin,
       round(epoch(max(fin) - min(inicio)) / 3600, 1) AS horas,
       round(indisponibilidad * 100, 2) AS indisponible_pct
FROM g GROUP BY tipo, id_yupana, equipo, indisponibilidad, grupo
ORDER BY tipo, equipo, inicio;

CREATE OR REPLACE TABLE crudo.control_mantenimiento_solape AS
-- DEBE SER 0: dos tramos del mismo equipo que se pisan.
SELECT a.tipo, a.id_yupana, a.equipo, a.inicio, a.fin, b.inicio AS otro_inicio
FROM crudo.mantenimiento_final a
JOIN crudo.mantenimiento_final b
  ON b.tipo = a.tipo AND b.id_yupana = a.id_yupana
 AND b.inicio > a.inicio AND b.inicio < a.fin;
COMMENT ON TABLE crudo.control_mantenimiento_solape IS
    'DEBE SER 0: dos tramos de mantenimiento del mismo equipo que se solapan.';
