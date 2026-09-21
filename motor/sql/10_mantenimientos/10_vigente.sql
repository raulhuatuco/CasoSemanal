-- Deja una sola foto del mantenimiento vigente: por dia, por unidad y por
-- media hora, sin superposiciones.
--
-- EL PROBLEMA QUE RESUELVE
-- El COES publica el mismo mantenimiento en varios programas, y las empresas
-- van ajustando: lo del mensual se corrige en el semanal, y eso en el diario.
-- Quedarse con todo duplica el impacto; quedarse con uno solo pierde lo que
-- ese programa no alcanza a cubrir.
--
-- POR QUE NO BASTA "GANA EL PROGRAMA MAS FINO QUE TOQUE EL DIA"
-- Un programa diario tambien declara eventos largos, que se extienden dias mas
-- alla de su vigencia. Midiendo los eventos vigentes por dia se ve la cola:
--
--     dia          PD   PS   PM
--     2026-09-20  135  126  103   <- el diario es una foto completa
--     2026-09-21  129  117  109   <- todavia
--     2026-09-22   88  120  112   <- ya es cola: faltan 32 respecto al semanal
--     2026-09-23   69  150  142
--
-- Si el diario mandara el 22, se perderian los que solo estan en el semanal.
-- Por eso la prelacion se decide por el HORIZONTE DE VIGENCIA del programa,
-- contado desde el dia en que se descargo, y fuera de ese horizonte las filas
-- del programa se descartan en vez de mezclarse.

SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-09-20');
SET VARIABLE fecha_fin = COALESCE(getvariable('fecha_fin'), '2026-10-17');
-- Cuantos dias cubre el programa diario contado desde su publicacion. Se midio
-- 2 (el dia y el siguiente); si el COES cambia de practica, se ajusta aqui.
SET VARIABLE pd_dias = COALESCE(getvariable('pd_dias'), 2);
-- Solo lo que sale de servicio resta disponibilidad. 'E/S' es un
-- mantenimiento que se hace con el equipo en servicio: no afecta.
SET VARIABLE solo_fs = COALESCE(getvariable('solo_fs'), true);
-- DE DONDE SALE LA FECHA DE PUBLICACION DEL PROGRAMA. Son dos usos distintos:
--   'descarga'  para armar casos. Lo que se bajo hoy es el programa de hoy, y
--               `descarga` es la fecha correcta.
--   'evento'    para backtesting. En una carga historica `descarga` es el dia
--               en que se hizo el volcado, no cuando el COES publico: no sirve
--               de ancla. El archivo del portal guarda un solo PD por dia, asi
--               que se ancla cada evento a su propio inicio y se puede medir
--               cuanto acierta la prelacion frente a los EJECUTADOS.
SET VARIABLE anclaje = COALESCE(getvariable('anclaje'), 'descarga');
-- Deja fuera los EJECUTADOS. Solo para el backtest: sirve para preguntarle a
-- la prelacion que creia que iba a pasar, sin dejarle ver lo que paso.
SET VARIABLE sin_ejecutados = COALESCE(getvariable('sin_ejecutados'), false);

CREATE OR REPLACE TEMP TABLE evento AS
WITH ultima AS (
    -- El COES reescribe: lo que ayer era programa diario hoy es ejecutado.
    -- De cada evento se toma la version mas reciente de cada programa.
    SELECT *
    FROM crudo.mtto
    WHERE inicio IS NOT NULL AND final IS NOT NULL AND final > inicio
      AND (NOT getvariable('sin_ejecutados') OR programa <> 'EJECUTADOS')
      AND (NOT getvariable('solo_fs') OR indisponibilidad = 'F/S')
    QUALIFY row_number() OVER (
        PARTITION BY programa, cod_eq, equipo, ubicacion, inicio, final
        ORDER BY descarga DESC) = 1
),
anclada AS (
    SELECT *,
           CASE WHEN getvariable('anclaje') = 'evento'
                THEN inicio::DATE ELSE descarga::DATE END AS publicado
    FROM ultima
),
vigencia AS (
    SELECT *,
           CASE programa
               -- El diario vale el dia que se publica y el siguiente.
               WHEN 'PROGRAMADO DIARIO' THEN publicado
               -- La semana operativa va de domingo a sabado: dayofweek da 0
               -- para el domingo, asi que restarlo cae en el domingo.
               WHEN 'PROGRAMADO SEMANAL'
                   THEN publicado - dayofweek(publicado)::INT
               WHEN 'PROGRAMADO MENSUAL' THEN date_trunc('month', publicado)::DATE
               ELSE publicado               -- ejecutados: solo el pasado
           END AS cubre_desde,
           CASE programa
               WHEN 'PROGRAMADO DIARIO'
                   THEN publicado + (getvariable('pd_dias')::INT - 1)
               WHEN 'PROGRAMADO SEMANAL'
                   THEN publicado - dayofweek(publicado)::INT + 6
               -- El mensual no lleva tope. El horizonte solo existe para
               -- que la cola de un programa fino no desplace a uno mas
               -- grueso; por debajo del mensual no hay nada que proteger, y
               -- ponerle tope dejaba sin mantenimientos todo lo que pase del
               -- mes en curso. De hecho el mensual declara bastante mas alla:
               -- bajado el 20/09 traia 1558 eventos de octubre y 26 de
               -- noviembre.
               WHEN 'PROGRAMADO MENSUAL' THEN DATE '2099-12-31' 
               ELSE publicado
           END AS cubre_hasta
    FROM anclada
)
SELECT * FROM vigencia;

-- Un dia del horizonte por fila, con el programa que manda en el.
CREATE OR REPLACE TEMP TABLE dia_programa AS
WITH dias AS (
    SELECT unnest(generate_series(getvariable('fecha_ini')::DATE,
                                  getvariable('fecha_fin')::DATE,
                                  INTERVAL 1 DAY))::DATE AS dia
)
SELECT d.dia, max(e.prelacion) AS prelacion
FROM dias d
JOIN evento e ON d.dia BETWEEN e.cubre_desde AND e.cubre_hasta
GROUP BY d.dia;

-- La foto final, a media hora. El MAX es lo que impide contar dos veces un
-- equipo con mantenimientos que se solapan: basta con que uno lo cubra.
CREATE OR REPLACE TABLE crudo.mtto_vigente AS
WITH rejilla AS (
    SELECT dp.dia, dp.prelacion, s.slot,
           -- El slot 1 termina a las 00:30 y el 48 a las 24:00, igual que las
           -- columnas de datosrestricciones.csv.
           dp.dia + (s.slot - 1) * INTERVAL 30 MINUTE AS desde,
           dp.dia + s.slot * INTERVAL 30 MINUTE AS hasta
    FROM dia_programa dp
    CROSS JOIN (SELECT unnest(generate_series(1, 48)) AS slot) s
)
SELECT r.dia AS fecha, r.slot,
       e.cod_eq AS cod_equipo, e.equipo, e.ubicacion, e.tipo_eq_osinerg,
       e.programa,
       max(1) AS fuera_servicio
FROM rejilla r
JOIN evento e
  ON e.prelacion = r.prelacion
 AND e.inicio < r.hasta AND e.final > r.desde
GROUP BY ALL;

-- CONTROLES. Los lee EjecutarSQL.bas y los deja en el informe.
CREATE OR REPLACE VIEW crudo.control_dia_sin_programa AS
-- DEBE SER 0: un dia del horizonte sin ningun programa que lo cubra queda sin
-- mantenimientos, y eso es un caso optimista de mas.
SELECT d::DATE AS dia
FROM unnest(generate_series(getvariable('fecha_ini')::DATE,
                            getvariable('fecha_fin')::DATE,
                            INTERVAL 1 DAY)) t(d)
WHERE d::DATE NOT IN (SELECT dia FROM dia_programa);

CREATE OR REPLACE VIEW crudo.control_prelacion AS
-- INFORMATIVA: que programa termino mandando en cada dia.
SELECT dia, prelacion,
       CASE prelacion WHEN 5 THEN 'EJECUTADOS' WHEN 4 THEN 'PROGRAMADO DIARIO'
                      WHEN 3 THEN 'PROGRAMADO SEMANAL'
                      WHEN 2 THEN 'PROGRAMADO MENSUAL' END AS programa,
       (SELECT count(DISTINCT cod_equipo) FROM crudo.mtto_vigente v
        WHERE v.fecha = dp.dia) AS unidades
FROM dia_programa dp ORDER BY dia;
