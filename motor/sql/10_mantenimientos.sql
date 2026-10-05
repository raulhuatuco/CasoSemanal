-- Mantenimientos: el unico script que nombra Params.
--
-- Un modulo, un script. Lo que hace cada paso esta explicado en el archivo que
-- se incluye; aqui solo esta el orden, que es lo que importa: los equipos
-- antes que el programa vigente, el vigente antes que los equivalentes, y el
-- emisor comun al final, cuando ya hay indisponibilidad que emitir.
--
-- `-- #incluir` lo resuelve el VBA antes de mandar nada a DuckDB, pegando el
-- archivo en su sitio. Asi los pasos comunes se escriben una vez y los tres
-- modulos los comparten, sin que Params tenga que enumerarlos.
--
-- El diseno de la base no esta aqui: vive en 00_comun/00_esquema.sql y lo
-- corren las herramientas de descarga cada vez que abren la base.

-- #incluir 00_comun/01_dim_equipo.sql
-- #incluir 10_mantenimientos/10_vigente.sql
-- #incluir 10_mantenimientos/40_equivgen.sql
-- #incluir 10_mantenimientos/50_resultado.sql
-- #incluir 00_comun/90_hecho_restriccion.sql


-- Los controles del modulo en una sola tabla, que es lo que se mira despues de
-- procesar. Las que deben dar 0 van arriba mientras no den 0; el detalle de
-- cada una sigue estando en su propia vista, con el mismo nombre.
CREATE OR REPLACE VIEW crudo.control AS
WITH c AS (
    SELECT 'dia_sin_programa' AS control, true AS debe_ser_cero,
           (SELECT count(*) FROM crudo.control_dia_sin_programa) AS filas,
           'Dias del horizonte sin ningun programa que los cubra.' AS que_significa
    UNION ALL SELECT 'dia_sin_unidades', true,
           (SELECT count(*) FROM crudo.control_dia_sin_unidades),
           'Dias en los que ninguna unidad esta en mantenimiento: el caso sale optimista.'
    UNION ALL SELECT 'indisp_rango', true,
           (SELECT count(*) FROM crudo.control_indisp_rango),
           'Indisponibilidades fuera de [0,1]: error de ponderacion.'
    UNION ALL SELECT 'mantenimiento_solape', true,
           (SELECT count(*) FROM crudo.control_mantenimiento_solape),
           'Dos tramos del mismo equipo que se pisan.'
    UNION ALL SELECT 'prelacion', false,
           (SELECT count(*) FROM crudo.control_prelacion),
           'Que programa termino mandando en cada dia.'
    UNION ALL SELECT 'gen_huerfano', false,
           (SELECT count(*) FROM crudo.control_gen_huerfano),
           'Codigos del maestro Gen que la base nunca ha visto.'
    UNION ALL SELECT 'yupana_sin_mtto', false,
           (SELECT count(*) FROM crudo.control_yupana_sin_mtto),
           'Unidades de Yupana que en todo el horizonte nunca salen.'
    UNION ALL SELECT 'equipo', false,
           (SELECT count(*) FROM dim.control_equipo),
           'De donde sale cada unidad del catalogo.'
)
SELECT CASE WHEN debe_ser_cero AND filas > 0 THEN 'FALLA'
            WHEN debe_ser_cero THEN 'ok'
            ELSE 'informativa' END AS estado,
       control, filas, que_significa
FROM c
ORDER BY (debe_ser_cero AND filas > 0) DESC, debe_ser_cero DESC, control;
