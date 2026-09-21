-- ============================================================================
-- UNIR MANTENIMIENTOS F/S POR UBICACION + EQUIPO  -- DuckDB
--
-- Lee la hoja de mantenimiento sin modificar el Excel. La salida principal,
-- mantenimientos_fs_unidos, conserva las 22 columnas originales (Field1 ..
-- Field22): solo se actualizan INICIO (Field7) y FINAL (Field8) al consolidar
-- periodos contiguos, solapados o separados por la tolerancia configurada.
--
-- Orden de tratamiento:
--   1. Conserva solamente registros F/S.
--   2. Elimina duplicados identicos considerando TODAS las columnas de datos.
--   3. Une por UBICACION + EQUIPO (sin separar por empresa), encadenando
--      intervalos cuya brecha sea menor o igual a la tolerancia.
--
-- Para los campos que no son fechas, una union conserva un valor existente de
-- forma determinista (el menor texto no nulo). El detalle de cuantos registros
-- fueron unidos queda disponible en control_consolidacion_fs.
-- ============================================================================

INSTALL spatial;
LOAD spatial;

-- ============================================================================
-- CONFIGURACION  -- todos los valores ajustables estan aqui arriba
-- ============================================================================

-- Archivo fuente. Se lee; nunca se escribe.
SET VARIABLE libro = COALESCE(getvariable('libro'),
    'C:\RAUL\00Proy\01_e-Quilibrium\02data\01LP2026q2\2026_35\Manto2023_2026.xlsx');

-- Hoja que contiene los mantenimientos.
SET VARIABLE hoja_mantenimientos = COALESCE(getvariable('hoja_mantenimientos'),
    'Ejecutados');

-- Hoja catalogo. Solo entran F/S cuyo par UBICACION + EQUIPO exista aqui.
-- En este formato, CENTRAL y UNIDAD son Field3 y Field4, respectivamente.
SET VARIABLE hoja_datos = COALESCE(getvariable('hoja_datos'), 'Datos');

-- Valor de INDISPONIBILIDAD (Field12) que entra a la salida.
SET VARIABLE tipo_indisponibilidad = COALESCE(getvariable('tipo_indisponibilidad'),
    'F/S');

-- Brecha maxima entre el FINAL de un registro y el INICIO del siguiente para
-- considerarlos un solo mantenimiento. Con 15 une 10:00--10:15; no 10:16.
SET VARIABLE tolerancia_minutos = COALESCE(getvariable('tolerancia_minutos'), 15);

-- Formato que se conserva en las dos columnas de fecha de salida.
SET VARIABLE formato_fecha_salida = COALESCE(getvariable('formato_fecha_salida'),
    '%Y/%m/%d %H:%M:%S');

-- ============================================================================
-- Derivadas: no editar debajo de esta linea para cambiar parametros.
-- ============================================================================

CREATE OR REPLACE MACRO tolerancia_union() AS
    to_minutes(CAST(getvariable('tolerancia_minutos') AS BIGINT));

CREATE OR REPLACE MACRO clave_union(valor) AS
    upper(trim(CAST(valor AS VARCHAR)));

-- Borra resultados de una ejecucion anterior para que el archivo se pueda
-- ejecutar varias veces dentro de la misma conexion DuckDB.
DROP TABLE IF EXISTS mantenimientos_fs_sin_duplicados;
DROP TABLE IF EXISTS mantenimientos_fs_unidos;
DROP TABLE IF EXISTS catalogo_equipos_datos;
DROP TABLE IF EXISTS control_consolidacion_fs;
DROP TABLE IF EXISTS control_fs_no_consolidable;
DROP TABLE IF EXISTS control_fs_fecha_invalida;

-- ============================================================================
-- 1. CATALOGO DATOS, SOLO F/S Y DEDUPLICACION COMPLETA
--
-- OGC_FID no forma parte de la data: cambia por fila al leer el Excel y por
-- eso se excluye. El DISTINCT se hace sobre las 22 columnas reales, no solo
-- sobre equipo y fechas.
-- ============================================================================
CREATE OR REPLACE TABLE catalogo_equipos_datos AS
SELECT DISTINCT
    clave_union(Field3) AS ubicacion_key,
    clave_union(Field4) AS equipo_key
FROM st_read(
    getvariable('libro'),
    layer=getvariable('hoja_datos'),
    open_options=['HEADERS=FALSE']
)
WHERE clave_union(Field3) <> ''
  AND clave_union(Field4) <> ''
  -- Se excluye el encabezado porque la hoja se lee sin encabezados.
  AND NOT (clave_union(Field3) = 'CENTRAL' AND clave_union(Field4) = 'UNIDAD');

CREATE OR REPLACE TABLE mantenimientos_fs_sin_duplicados AS
SELECT DISTINCT
    Field1, Field2, Field3, Field4, Field5, Field6, Field7, Field8,
    Field9, Field10, Field11, Field12, Field13, Field14, Field15, Field16,
    Field17, Field18, Field19, Field20, Field21, Field22
FROM st_read(
    getvariable('libro'),
    layer=getvariable('hoja_mantenimientos'),
    open_options=['HEADERS=FALSE']
) AS m
WHERE clave_union(m.Field12) = clave_union(getvariable('tipo_indisponibilidad'))
  AND EXISTS (
      SELECT 1
      FROM catalogo_equipos_datos d
      WHERE d.ubicacion_key = clave_union(m.Field4)
        AND d.equipo_key    = clave_union(m.Field6)
  );

-- Filas F/S que no se pueden consolidar porque INICIO/FINAL no son fechas
-- validas o el intervalo no tiene duracion positiva. No se mezclan ni pierden:
-- se reportan aqui para corregir el origen.
CREATE OR REPLACE TABLE control_fs_fecha_invalida AS
WITH fechas AS (
    SELECT *,
        COALESCE(TRY_CAST(Field7 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field7 AS VARCHAR), '%d/%m/%Y %H:%M')) AS inicio,
        COALESCE(TRY_CAST(Field8 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field8 AS VARCHAR), '%d/%m/%Y %H:%M')) AS final
    FROM mantenimientos_fs_sin_duplicados
)
SELECT * EXCLUDE (inicio, final)
FROM fechas
WHERE inicio IS NULL OR final IS NULL OR inicio >= final;

-- ============================================================================
-- 2. UNION POR UBICACION + EQUIPO
--
-- MAX(final) previo, y no solo LAG(final), permite encadenar correctamente
-- intervalos solapados. Por ejemplo: 01--10, 05--06 y 09--12 es una isla.
-- ============================================================================
CREATE OR REPLACE TABLE mantenimientos_fs_unidos AS
WITH fechas AS (
    SELECT *,
        COALESCE(TRY_CAST(Field7 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field7 AS VARCHAR), '%d/%m/%Y %H:%M')) AS inicio,
        COALESCE(TRY_CAST(Field8 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field8 AS VARCHAR), '%d/%m/%Y %H:%M')) AS final
    FROM mantenimientos_fs_sin_duplicados
),
validos AS (
    SELECT *, clave_union(Field4) AS ubicacion_key, clave_union(Field6) AS equipo_key
    FROM fechas
    WHERE inicio IS NOT NULL AND final IS NOT NULL AND inicio < final
),
con_clave AS (
    SELECT * FROM validos
    WHERE ubicacion_key <> '' AND equipo_key <> ''
),
marcas AS (
    SELECT *,
        MAX(final) OVER (
            PARTITION BY ubicacion_key, equipo_key
            ORDER BY inicio, final DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS max_final_previo
    FROM con_clave
),
islas AS (
    SELECT *,
        SUM(CASE WHEN max_final_previo IS NULL
                      OR inicio > max_final_previo + tolerancia_union()
                 THEN 1 ELSE 0 END) OVER (
            PARTITION BY ubicacion_key, equipo_key
            ORDER BY inicio, final DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS isla_id
    FROM marcas
),
unidos AS (
    SELECT
        MIN(Field1) AS Field1, MIN(Field2) AS Field2, MIN(Field3) AS Field3,
        MIN(Field4) AS Field4, MIN(Field5) AS Field5, MIN(Field6) AS Field6,
        strftime(MIN(inicio), getvariable('formato_fecha_salida')) AS Field7,
        strftime(MAX(final),  getvariable('formato_fecha_salida')) AS Field8,
        MIN(Field9) AS Field9, MIN(Field10) AS Field10, MIN(Field11) AS Field11,
        MIN(Field12) AS Field12, MIN(Field13) AS Field13, MIN(Field14) AS Field14,
        MIN(Field15) AS Field15, MIN(Field16) AS Field16, MIN(Field17) AS Field17,
        MIN(Field18) AS Field18, MIN(Field19) AS Field19, MIN(Field20) AS Field20,
        MIN(Field21) AS Field21, MIN(Field22) AS Field22
    FROM islas
    GROUP BY ubicacion_key, equipo_key, isla_id
),
sin_clave AS (
    -- No hay un equipo y una ubicacion con que comparar: se conserva la fila.
    SELECT Field1, Field2, Field3, Field4, Field5, Field6,
           strftime(inicio, getvariable('formato_fecha_salida')) AS Field7,
           strftime(final,  getvariable('formato_fecha_salida')) AS Field8,
           Field9, Field10, Field11, Field12, Field13, Field14, Field15, Field16,
           Field17, Field18, Field19, Field20, Field21, Field22
    FROM validos
    WHERE ubicacion_key = '' OR equipo_key = ''
)
SELECT * FROM unidos
UNION ALL
SELECT * FROM sin_clave;

-- Trazabilidad: una fila por mantenimiento consolidado y cuantos registros
-- F/S sin duplicados lo originaron. Solo lista grupos que realmente se unieron.
CREATE OR REPLACE TABLE control_consolidacion_fs AS
WITH fechas AS (
    SELECT *,
        COALESCE(TRY_CAST(Field7 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field7 AS VARCHAR), '%d/%m/%Y %H:%M')) AS inicio,
        COALESCE(TRY_CAST(Field8 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field8 AS VARCHAR), '%d/%m/%Y %H:%M')) AS final
    FROM mantenimientos_fs_sin_duplicados
),
base AS (
    SELECT *, clave_union(Field4) AS ubicacion_key, clave_union(Field6) AS equipo_key
    FROM fechas
    WHERE inicio IS NOT NULL AND final IS NOT NULL AND inicio < final
      AND clave_union(Field4) <> '' AND clave_union(Field6) <> ''
),
marcas AS (
    SELECT *, MAX(final) OVER (
        PARTITION BY ubicacion_key, equipo_key ORDER BY inicio, final DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS max_final_previo
    FROM base
),
islas AS (
    SELECT *, SUM(CASE WHEN max_final_previo IS NULL
                             OR inicio > max_final_previo + tolerancia_union()
                        THEN 1 ELSE 0 END) OVER (
        PARTITION BY ubicacion_key, equipo_key ORDER BY inicio, final DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS isla_id
    FROM marcas
)
SELECT
    MIN(Field4) AS UBICACION,
    MIN(Field6) AS EQUIPO,
    MIN(inicio) AS INICIO_UNIDO,
    MAX(final) AS FINAL_UNIDO,
    COUNT(*) AS registros_fs_sin_duplicados
FROM islas
GROUP BY ubicacion_key, equipo_key, isla_id
HAVING COUNT(*) > 1
ORDER BY UBICACION, EQUIPO, INICIO_UNIDO;

-- F/S con fecha valida pero sin ubicacion o equipo: estan en la salida sin
-- unirse y se muestran aqui para completar el origen si corresponde.
CREATE OR REPLACE TABLE control_fs_no_consolidable AS
WITH fechas AS (
    SELECT *,
        COALESCE(TRY_CAST(Field7 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field7 AS VARCHAR), '%d/%m/%Y %H:%M')) AS inicio,
        COALESCE(TRY_CAST(Field8 AS TIMESTAMP),
                 TRY_STRPTIME(CAST(Field8 AS VARCHAR), '%d/%m/%Y %H:%M')) AS final
    FROM mantenimientos_fs_sin_duplicados
)
SELECT * EXCLUDE (inicio, final)
FROM fechas
WHERE inicio IS NOT NULL AND final IS NOT NULL AND inicio < final
  AND (clave_union(Field4) = '' OR clave_union(Field6) = '');

-- ============================================================================
-- RESULTADOS
-- ============================================================================
SELECT *
FROM mantenimientos_fs_unidos
ORDER BY Field4, Field6, Field7, Field8;

SELECT * FROM control_consolidacion_fs;
SELECT * FROM control_fs_fecha_invalida;
SELECT * FROM control_fs_no_consolidable;
