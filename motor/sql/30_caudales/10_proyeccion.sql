-- Proyecta los caudales del horizonte a partir de la ultima semana observada.
--
-- EL METODO, EL MISMO DE CALCULO_DELTAS
-- No se copia el caudal de un anio historico tal cual: se copia su FORMA. De
-- la semana de referencia (la ultima observada) se parte, y a cada semana del
-- horizonte se le aplica el factor que tuvo esa misma semana en el anio
-- analogo respecto de su propia semana de referencia:
--
--     caudal(sem k) = caudal(ultima observada) * hist(sem k) / hist(sem ref)
--
-- Asi se conserva el nivel hidrologico actual, que es lo que el anio analogo
-- no sabe, y se toma de el la tendencia estacional, que es lo que la ultima
-- semana no puede dar.
--
-- El anio analogo se elige por ahora a mano (anio_analogo). Cuando haya varios
-- anios cargados conviene elegirlo como en renovables, por menor error contra
-- la semana de referencia.

SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-09-20');
SET VARIABLE fecha_fin = COALESCE(getvariable('fecha_fin'), '2026-10-17');
SET VARIABLE anio_analogo = COALESCE(getvariable('anio_analogo'), 2020);

-- La semana de referencia: la ultima con datos, y su año.
CREATE OR REPLACE TEMP TABLE ref_caudal AS
WITH ultimo AS (
    SELECT max(fecha) AS f FROM crudo.caudal_serie
    WHERE year(fecha) <> getvariable('anio_analogo')::INT
)
SELECT c.id_yupana, c.equipo_yupana, c.categoria, c.restriccion, c.slot, (c.fecha - u.f) + 6 AS dia_rel, c.m3s
FROM crudo.caudal_serie c, ultimo u
WHERE c.fecha BETWEEN u.f - 6 AND u.f
  AND year(c.fecha) <> getvariable('anio_analogo')::INT;

-- La misma semana del calendario, en el anio analogo.
CREATE OR REPLACE TEMP TABLE ref_hist AS
WITH ultimo AS (SELECT max(fecha) AS f FROM crudo.caudal_serie
                WHERE year(fecha) = getvariable('anio_analogo')::INT)
SELECT c.id_yupana, c.equipo_yupana, c.categoria, c.restriccion, c.slot, (c.fecha - u.f) + 6 AS dia_rel, c.m3s
FROM crudo.caudal_serie c, ultimo u
WHERE c.fecha BETWEEN u.f - 6 AND u.f
  AND year(c.fecha) = getvariable('anio_analogo')::INT;

-- El factor de cada dia del horizonte, contra la semana de referencia
-- historica. Se compara media hora con media hora del mismo dia de la semana.
CREATE OR REPLACE TABLE crudo.caudal_proyectado AS
WITH horizonte AS (
    SELECT d::DATE AS fecha,
           (d::DATE - getvariable('fecha_ini')::DATE) % 7 AS dia_rel
    FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                                getvariable('fecha_fin')::DATE,
                                INTERVAL 1 DAY)) t(d)
),
-- El caudal historico del dia equivalente del horizonte.
futuro_hist AS (
    SELECT c.id_yupana, c.equipo_yupana, c.categoria, c.restriccion, c.slot,
           (c.fecha - (SELECT min(fecha) FROM crudo.caudal_serie
                       WHERE year(fecha) = getvariable('anio_analogo')::INT))
           AS desplazamiento,
           c.m3s
    FROM crudo.caudal_serie c
    WHERE year(c.fecha) = getvariable('anio_analogo')::INT
)
SELECT h.fecha, r.slot, r.id_yupana, r.equipo_yupana,
       r.categoria, r.restriccion,
       -- Si el historico no cubre ese dia el factor es 1: se mantiene el
       -- caudal actual en vez de inventar una tendencia.
       round(r.m3s * coalesce(f.m3s / nullif(rh.m3s, 0), 1.0), 5) AS m3s,
       coalesce(f.m3s / nullif(rh.m3s, 0), 1.0) AS factor
FROM horizonte h
JOIN ref_caudal r ON r.dia_rel = h.dia_rel
LEFT JOIN ref_hist rh ON rh.id_yupana = r.id_yupana AND rh.categoria = r.categoria AND rh.slot = r.slot
                     AND rh.dia_rel = r.dia_rel
LEFT JOIN futuro_hist f ON f.id_yupana = r.id_yupana AND f.categoria = r.categoria AND f.slot = r.slot
                       AND f.desplazamiento = (h.fecha - getvariable('fecha_ini')::DATE);

CREATE OR REPLACE VIEW crudo.control_caudal_sin_factor AS
-- INFORMATIVA: medias horas que se quedaron con factor 1 porque el anio
-- analogo no llega hasta ahi. Si son muchas, falta cargar mas semanas
-- historicas y la proyeccion es en realidad una persistencia.
SELECT count(*) AS medias_horas,
       count(DISTINCT fecha) AS dias,
       round(100.0 * count(*) FILTER (WHERE factor = 1.0) / count(*), 1)
           AS pct_sin_factor
FROM crudo.caudal_proyectado;
