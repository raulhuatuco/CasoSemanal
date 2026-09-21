-- Traduce el mantenimiento del COES a indisponibilidad por unidad Yupana.
-- Entra crudo.mtto_vigente (por codigo COES, dia y media hora) y sale
-- crudo.indisp_yupana (por unidad de Yupana, dia y media hora).
--
-- DOS PASOS, EN ESTE ORDEN
-- 1. EquivGen. Un mantenimiento de transmision que deja una central aislada se
--    modela como indisponibilidad de esa central. La traduccion se hace antes
--    de agrupar, para que el codigo traducido compita en igualdad con los de
--    generacion y el MAX lo absorba si coinciden.
-- 2. Gen. Cada unidad de Yupana agrupa varios codigos COES, y hay dos formas
--    de calcular, segun tipo_calculo:
--      total    cualquiera de sus codigos la saca entera. Son equipos en
--               serie: la maquina, su transformador, su celda. Se resuelve
--               con MAX, que ademas es lo que impide contar dos veces un
--               equipo con mantenimientos superpuestos.
--      parcial  la unidad agrupa varias maquinas y cada codigo aporta su
--               potencia. Se pierde la fraccion que corresponde a las que
--               estan fuera: suma ponderada sobre el total.

CREATE OR REPLACE TABLE crudo.indisp_yupana AS
WITH traducido AS (
    -- Un codigo puede traducirse a varios equivalentes, y uno de generacion
    -- no se traduce: se queda como esta.
    SELECT v.fecha, v.slot,
           coalesce(eq.cod_equiv, v.cod_equipo) AS cod_coes
    FROM crudo.mtto_vigente v
    LEFT JOIN dim.equivgen eq ON eq.cod_coes = v.cod_equipo
),
fuera AS (
    -- Un codigo puede estar repetido en dos columnas g de la misma unidad;
    -- DISTINCT evita que eso infle la suma de las parciales.
    SELECT DISTINCT fecha, slot, cod_coes FROM traducido
),
-- El divisor de la parcial es la potencia de TODAS las maquinas, esten o no
-- en mantenimiento, asi que se calcula aparte del cruce.
capacidad AS (
    SELECT tipo, id_yupana, sum(potencia) AS potencia_total
    FROM dim.gen WHERE potencia IS NOT NULL
    GROUP BY tipo, id_yupana
),
cruce AS (
    SELECT g.tipo, g.id_yupana, g.equipo, f.fecha, f.slot,
           -- Basta que un codigo de la fila `total` este fuera para que la
           -- unidad entera lo este.
           max(CASE WHEN g.tipo_calculo = 'total' THEN 1.0 ELSE 0.0 END)
               AS por_compartido,
           -- Y de la fila `parcial`, la fraccion de potencia perdida.
           coalesce(sum(g.potencia) FILTER (WHERE g.tipo_calculo = 'parcial')
                    / nullif(max(c.potencia_total), 0), 0.0) AS por_maquinas
    FROM fuera f
    JOIN dim.gen g ON g.cod_coes = f.cod_coes
    LEFT JOIN capacidad c ON c.tipo = g.tipo AND c.id_yupana = g.id_yupana
    GROUP BY g.tipo, g.id_yupana, g.equipo, f.fecha, f.slot
)
SELECT tipo, id_yupana, equipo, fecha, slot,
       -- No se suman: se toma la peor. Sumar contaria dos veces una central
       -- que tiene a la vez una maquina y su patio en mantenimiento.
       least(1.0, greatest(por_compartido, por_maquinas)) AS indisponibilidad
FROM cruce;

-- CONTROLES
CREATE OR REPLACE VIEW crudo.control_indisp_rango AS
-- DEBE SER 0: una indisponibilidad fuera de [0,1] es un error de ponderacion.
SELECT * FROM crudo.indisp_yupana
WHERE indisponibilidad < 0 OR indisponibilidad > 1;

CREATE OR REPLACE VIEW crudo.control_gen_huerfano AS
-- INFORMATIVA: codigos del maestro Gen que la base nunca ha visto, ni en
-- mediciones ni en mantenimientos. Esas unidades no pueden salir de servicio,
-- asi que el caso sale optimista sin avisar.
SELECT g.tipo, g.id_yupana, g.equipo, g.tipo_calculo, g.cod_coes
FROM dim.gen g
LEFT JOIN dim.equipo e ON e.cod_equipo = g.cod_coes
WHERE e.cod_equipo IS NULL;

CREATE OR REPLACE VIEW crudo.control_yupana_sin_mtto AS
-- INFORMATIVA: unidades de Yupana que en todo el horizonte nunca salen. Es
-- normal que haya muchas; sirve para comparar entre corridas.
-- id_yupana se repite entre hidro y termo (el 6 es MANTARO y tambien
-- KALLPACC3GAS), asi que la llave es el par.
SELECT g.tipo, g.id_yupana, g.equipo
FROM (SELECT DISTINCT tipo, id_yupana, equipo FROM dim.gen) g
WHERE (g.tipo, g.id_yupana) NOT IN
      (SELECT tipo, id_yupana FROM crudo.indisp_yupana);
