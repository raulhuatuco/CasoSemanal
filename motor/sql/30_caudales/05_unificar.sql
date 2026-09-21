-- Junta las dos fuentes de caudal en una sola serie a media hora.
--
-- LA REGLA: EL NATURAL MANDA, Y NUNCA SE MEZCLAN
-- Para un mismo equipo de Yupana puede haber caudal por las dos vias. Se toma
-- el natural de la web y solo si no lo hay se cae al reporte de programacion.
-- No se promedian ni se suman: son magnitudes distintas. El natural es lo que
-- llega a la cuenca; el del reporte es caudal de planta o de embalse, que ya
-- lleva dentro la descarga del embalse, y esa descarga es un resultado del
-- despacho del COES. Sumar las dos, o usar la segunda como aporte, contaria la
-- descarga dos veces y regalaria agua al modelo.

SET VARIABLE preferir_natural = COALESCE(getvariable('preferir_natural'), true);

CREATE OR REPLACE TABLE crudo.caudal_serie AS
WITH web AS (
    -- La web es horaria; cada hora cubre las dos medias horas del modelo.
    SELECT m.id_yupana, m.equipo_yupana, m.categoria, m.restriccion,
           w.fecha, (w.hora * 2 + s)::TINYINT AS slot, w.m3s,
           'natural' AS clase
    FROM crudo.caudal_web w
    JOIN dim.caudal_pto m ON m.fuente = 'web' AND m.clave = w.equipo
    CROSS JOIN (SELECT unnest([1, 2]) AS s) t
    WHERE w.tipo_caudal = 'CAUDAL NATURAL ESTIMADO'
),
rep AS (
    SELECT m.id_yupana, m.equipo_yupana, m.categoria, m.restriccion,
           c.fecha, c.slot, c.m3s, 'programacion' AS clase
    FROM crudo.caudal c
    JOIN dim.caudal_pto m ON m.fuente = 'reporte'
                         AND m.clave = c.cod_pto::VARCHAR
),
todo AS (SELECT * FROM web UNION ALL SELECT * FROM rep)
SELECT id_yupana, equipo_yupana, categoria, restriccion, fecha, slot,
       sum(m3s) AS m3s, any_value(clase) AS clase
FROM todo
-- Varios puntos pueden alimentar el mismo equipo: ahi si se suman, porque son
-- aportes distintos de la misma clase. Lo que no se mezcla son las clases.
WHERE getvariable('preferir_natural') = false
   OR clase = 'natural'
   OR (id_yupana, categoria) NOT IN (SELECT id_yupana, categoria
                                     FROM todo WHERE clase = 'natural')
GROUP BY ALL;

CREATE OR REPLACE VIEW crudo.control_caudal_fuente AS
-- INFORMATIVA: de que clase sale el caudal de cada equipo. Lo que venga de
-- 'programacion' esta afectado por la operacion y conviene reemplazarlo por
-- natural en cuanto el COES lo publique para ese punto.
SELECT clase, categoria, count(DISTINCT id_yupana) AS equipos,
       min(fecha) AS desde, max(fecha) AS hasta
FROM crudo.caudal_serie GROUP BY ALL ORDER BY clase, categoria;
