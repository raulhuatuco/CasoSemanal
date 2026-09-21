-- Esquema de la base local. Es idempotente: se puede correr siempre.
--
-- La capa `crudo` guarda lo que entrega el COES sin interpretarlo, y no se
-- borra nunca: se le agrega. Por eso cada fila lleva `descarga`. El COES
-- reescribe el pasado (el programa diario de ayer hoy figura como ejecutado),
-- asi que sin esa marca no se puede volver a armar un caso tal como se armo.
-- Quien consulta se queda con la descarga mas reciente; quien audita filtra
-- por fecha y recupera la foto vieja.

CREATE SCHEMA IF NOT EXISTS crudo;
CREATE SCHEMA IF NOT EXISTS dim;

-- Mantenimientos, una fila por evento y por programa que lo declara.
-- El mismo evento aparece en varios programas: eso no es basura, es la
-- secuencia de ajustes, y la resuelve la prelacion en 30_prelacion.sql.
CREATE TABLE IF NOT EXISTS crudo.mtto (
    descarga          TIMESTAMP,
    programa          VARCHAR,   -- EJECUTADOS / PROGRAMADO DIARIO|SEMANAL|MENSUAL
    prelacion         TINYINT,   -- 5 ejecutado, 4 diario, 3 semanal, 2 mensual
    tipo_empresa      VARCHAR,
    empresa           VARCHAR,
    ubicacion         VARCHAR,
    tipo_equipo       VARCHAR,
    equipo            VARCHAR,
    inicio            TIMESTAMP,
    final             TIMESTAMP,
    descripcion       VARCHAR,
    prog              VARCHAR,   -- PROGRAMADO / REPROGRAMADO / FORZADO
    interrupcion      VARCHAR,
    indisponibilidad  VARCHAR,   -- F/S fuera de servicio, E/S en servicio
    tension           VARCHAR,
    tipo_mantto       VARCHAR,
    cod_eq            INTEGER,   -- EQUICODI del COES: la llave para cruzar
    tipo_eq_osinerg   VARCHAR    -- G generacion, T transmision
);

-- Mediciones a 48 medias horas, ya en formato largo: una fila por unidad,
-- dia, magnitud y media hora. Guardarlas asi evita repetir el unpivot en cada
-- consulta y deja el join contra la rejilla de 30 min en una sola condicion.
--
-- Solo lleva el codigo de la unidad: el nombre, la ubicacion y la empresa
-- viven en dim.equipo. Repetirlos en cada una de las 48 medias horas de cada
-- dia inflaba la tabla casi al triple sin aportar nada.
CREATE TABLE IF NOT EXISTS crudo.medicion (
    descarga    TIMESTAMP,
    lectcodi    TINYINT,   -- 6 ejecutado, 4 programa diario, 3 semanal
    fecha       DATE,
    slot        TINYINT,   -- 1..48, donde 1 es 00:30 y 48 es 24:00
    cod_equipo  INTEGER,   -- EQUICODI; el nombre esta en dim.equipo
    magnitud    VARCHAR,   -- MW / MVar
    valor       DOUBLE
);

-- Bitacora de lo ya traido, para no volver a pedir lo mismo. Solo sirve para
-- lo que no cambia: las mediciones ejecutadas de un dia pasado son
-- definitivas. Los mantenimientos futuros cambian a diario y se vuelven a
-- pedir siempre.
CREATE TABLE IF NOT EXISTS crudo.descarga (
    fuente    VARCHAR,   -- 'mtto' | 'medicion'
    clave     VARCHAR,   -- programa o lectcodi
    fecha     DATE,
    descarga  TIMESTAMP,
    filas     INTEGER
);

-- LA UNIDAD ES LA GRANULARIDAD, NO LA CENTRAL.
-- `cod_equipo` es el EQUICODI del COES y es la misma llave en mantenimientos
-- (crudo.mtto.cod_eq) y en mediciones (crudo.medicion.cod_equipo). Una central
-- puede tener varias unidades y hay que tratarlas por separado: CHILCA 1 tiene
-- cuatro, KALLPA cuatro, y entre las eolicas PUNTA LOMITAS reporta dos bloques
-- (BL1 y BL2). Agregar por central antes de tiempo pierde esa separacion y
-- duplica el impacto de un mantenimiento que solo afecta a una unidad.
CREATE TABLE IF NOT EXISTS dim.equipo (
    cod_equipo     INTEGER PRIMARY KEY,
    equipo         VARCHAR,   -- nombre de la unidad: TG11, C.E. PUNTA LOMITAS-BL1
    cod_ubicacion  INTEGER,
    ubicacion      VARCHAR,   -- la central o subestacion que la contiene
    cod_empresa    INTEGER,
    empresa        VARCHAR,
    tension        DOUBLE,
    tipo_osinerg   VARCHAR,   -- G generacion, T transmision
    visto_medicion BOOLEAN DEFAULT false,   -- aparece en crudo.medicion
    visto_mtto     BOOLEAN DEFAULT false    -- aparece en crudo.mtto
);

-- A PROPOSITO NO HAY INDICES SOBRE crudo.medicion NI crudo.mtto.
-- DuckDB ya guarda minimo y maximo por grupo de filas y descarta los que no
-- vienen al caso, que es justo lo que hacen las consultas de aqui (un rango de
-- fechas, un puñado de unidades). Un indice ART explicito no acelera ese
-- barrido y en esta base ocupaba unos 210 MB sobre 30 MB de datos: el archivo
-- pasaba de 32 MB a 254 MB. La unica llave que se mantiene es la primaria de
-- dim.equipo, que tiene mil filas y hace falta para el ON CONFLICT del
-- cargador.

-- MAESTROS DEL MODELO, desde Manto2023_2026.xlsm (hojas Gen y EquivGen).
-- Ese libro es el maestro vivo: su EquivGen contiene 132 de los 133 pares de
-- Yup_Mtto.xlsm y otros 457 mas. La hoja Gen es identica en los dos.
--
-- Gen viene ancha (nombre_g1..g8 y potencia_g1..g7 en columnas). Aqui se
-- guarda larga, una fila por unidad Yupana y codigo COES, que es como se
-- consulta.
CREATE TABLE IF NOT EXISTS dim.gen (
    id_yupana     INTEGER,
    equipo        VARCHAR,   -- nombre de la unidad en Yupana
    tipo          VARCHAR,   -- hidro / termo
    tipo_calculo  VARCHAR,   -- total: cualquier codigo la saca entera
                             -- parcial: cada codigo aporta su potencia
    nombre_coes   VARCHAR,
    orden         INTEGER,   -- 1..8, de que columna g salio
    cod_coes      INTEGER,   -- EQUICODI; cruza con dim.equipo
    potencia      DOUBLE     -- MW que aporta, solo en las parciales
);

-- Traduce codigos de equipos de transmision a su equivalente en generacion:
-- un mantenimiento de linea que deja una central aislada se modela como
-- indisponibilidad de esa central.
CREATE TABLE IF NOT EXISTS dim.equivgen (
    cod_coes      INTEGER,   -- el codigo que aparece en el mantenimiento
    cod_equiv     INTEGER,   -- el codigo de generacion al que se traduce
    equiabrev     VARCHAR,
    equinomb      VARCHAR,
    areanomb      VARCHAR
);

-- Caudales del "REPORTE DE CAUDALES" del COES. El reporte viene ancho: una
-- columna por punto de medicion y una fila por media hora. Aqui va largo,
-- igual que las mediciones.
--
-- OJO: `cod_pto` es el codigo de punto de medicion hidrologico (59800 y
-- siguientes), que NO es el EQUICODI de dim.equipo. Son numeraciones
-- distintas y no se cruzan directamente.
CREATE TABLE IF NOT EXISTS crudo.caudal (
    descarga  TIMESTAMP,
    origen    VARCHAR,   -- de que reporte salio
    cod_pto   INTEGER,
    empresa   VARCHAR,
    tipo      VARCHAR,   -- Planta / Embalse
    nombre    VARCHAR,   -- lo que sigue al tipo: ARCATA, CERRO DEL AGUILA...
    fecha     DATE,
    slot      TINYINT,   -- 1..48
    m3s       DOUBLE
);

-- Caudales del Historico de Hidrologia del COES (la pagina web, no el reporte
-- de programacion). Tabla aparte de crudo.caudal a proposito: son fuentes
-- distintas y NO deben mezclarse.
--
-- POR QUE IMPORTA EL TIPO
-- Para los aportes de Yupana hace falta el CAUDAL NATURAL ESTIMADO: es el que
-- llega a la cuenca y no esta afectado por la operacion. Un caudal turbinado,
-- total o regulado ya lleva dentro la descarga del embalse, que es un
-- resultado del despacho del COES; usarlo como aporte la contaria dos veces.
-- Por eso el tipo se guarda en cada fila y nunca se agrega sin filtrarlo.
CREATE TABLE IF NOT EXISTS crudo.caudal_web (
    descarga     TIMESTAMP,
    lectura      INTEGER,   -- 66 EJECUTADO TR, 75 EJECUTADO HISTORICO, ...
    tipo_caudal  VARCHAR,   -- CAUDAL NATURAL ESTIMADO, TURBINADO, TOTAL, ...
    cuenca       VARCHAR,
    empresa      VARCHAR,
    instalacion  VARCHAR,   -- EMB o ESTACION
    equipo       VARCHAR,   -- el nombre del punto: UPAMAYO, TOMA CAHUA...
    fecha        DATE,
    hora         TINYINT,   -- 0..23; la fuente es horaria, no de media hora
    m3s          DOUBLE
);

-- Que equipos usa el caso, desde plantah.csv y modot.csv.
--
-- POR QUE HACE FALTA
-- Esas tablas traen la central entera Y sus unidades: HUINCO (277.9 MW) y
-- ademas HUINCO G1..G4 (69 MW cada una, que suman lo mismo). El caso usa una
-- representacion u otra, y lo dice la columna "Considera Equipo". Emitir
-- mantenimiento para las dos cuenta la indisponibilidad dos veces.
CREATE TABLE IF NOT EXISTS dim.equipo_yupana (
    categoria  INTEGER,   -- 4 plantah, 3 modot
    id_yupana  INTEGER,
    equipo     VARCHAR,
    considera  BOOLEAN,   -- "Considera Equipo"
    escenario  BOOLEAN,   -- "Considera en Escenario"
    capacidad  DOUBLE
);
