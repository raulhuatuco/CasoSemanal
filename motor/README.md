# motor — actualizador de casos Yupana

Carpeta **portable**: no contiene ninguna ruta absoluta. Muévela donde quieras
(otro disco, otro equipo, otro repo) y sigue funcionando, porque todo se
resuelve contra la ubicación del libro `Yupana_Motor.xlsm` mediante
`Absoluta(ruta, base)` de `EjecutarSQL.bas`.

    motor/
      Yupana_Motor.xlsm     único punto de entrada: hoja Params + botones
      Params.csv            plantilla de la hoja Params (pegar en el libro)
      vba/                  módulos .bas exportados, versionables en git
      sql/00_comun/         calendario, dim_equipos, emisor del CSV
      sql/10_mantenimientos/
      sql/20_renovables/
      sql/30_caudales/
      tools/                utilidades python (descarga COES, inspección)
      staging/              base duckdb + parquet intermedios (no versionar)
      logs/                 informes .txt de cada corrida

## Lo único que se edita

La hoja `Params`. El VBA sólo la lee; no hay parámetros dentro del código ni
dentro de los `.sql`. Cuatro bloques, cada uno termina en la primera fila con
la columna A vacía:

- `[CARPETAS]`  `carpeta_scripts` (los .sql), `carpeta_datos` (los libros),
  `carpeta_salida` (el caso nuevo). Relativas al libro.
- `[EJECUCION]` `base` (archivo duckdb) y una fila `script` por cada .sql,
  **en el orden en que corren**. Quitar una fila desactiva ese paso.
- `[VARIABLES]` `clave | valor | tipo` → se envían como `SET VARIABLE` antes
  de los scripts. Tipos: `texto | archivo | numero | logico`.
- `[SALIDAS]`   `consulta | hoja` → vuelca vistas de control al propio libro.

## Cómo lo lee el SQL

Cada `.sql` empieza declarando sus valores por defecto, así corre igual desde
Excel, desde DBeaver o desde `duckdb.exe`:

    SET VARIABLE fecha_ini = COALESCE(getvariable('fecha_ini'), '2026-06-06');

## Contrato entre módulos

Ningún módulo escribe CSV. Los tres llenan una tabla larga común:

    hecho_restriccion(equipo_yupana, categoria, restriccion, fecha, slot, valor, origen)

y `00_comun/90_emit_datosrestricciones.sql` la pivotea a las 48 medias horas y
produce `datosrestricciones.csv`. Agregar un cuarto módulo es un `.sql` más y
una fila más en `[EJECUCION]`.

## La base local

`staging/yupana.duckdb`. Se crea sola con `sql/00_comun/00_esquema.sql`, que es
idempotente. Dos capas:

- `crudo.*`  lo que entrega el COES sin interpretar, **append-only**. Cada fila
  lleva `descarga`. El COES reescribe el pasado (el programa diario de ayer hoy
  figura como ejecutado), asi que sin esa marca no se puede volver a armar un
  caso tal como se armo.
- `dim.*`    maestros del modelo (Gen, EquivGen, Lin), desde el .xlsm.

Dos pasos separados a proposito:

    refrescar     toca la red, llena crudo.*      tools/coes_mtto.py, coes_med.py
    armar_casos   no toca la red, lee crudo.*     los .sql de [EJECUCION]

Asi se puede iterar el SQL sin volver a descargar, y armar casos sin conexion.

    python tools/bd.py                                  # crea y resume
    python tools/coes_mtto.py 2026-09-20 2026-12-19     # 3 meses por llamada
    python tools/coes_med.py  2026-01-01 2026-09-19     # ejecutado, incremental

`coes_med.py` salta los dias que ya estan: lo ejecutado de un dia pasado no
cambia. Los programas (`--lectcodi 3` o `4`) se vuelven a pedir siempre.

## Cuando esta base se mude a la grande

Esta base esta hecha para ser absorbida por otra mas completa, asi que no tiene
nada que la ate a este proyecto:

- **Solo llaves naturales del COES.** `cod_equipo` es el EQUICODI y es la misma
  llave en mantenimientos y en mediciones. No hay ids inventados ni
  autoincrementales que choquen al fusionar.
- **Todo cuelga de `crudo` y `dim`**, no del esquema `main`, asi que se puede
  mover sin renombrar nada.
- **Ninguna tabla depende de la ruta del archivo.**

La mudanza es una sentencia:

    ATTACH 'ruta/yupana.duckdb' AS yup (READ_ONLY);
    CREATE TABLE grande.coes_mtto     AS SELECT * FROM yup.crudo.mtto;
    CREATE TABLE grande.coes_medicion AS SELECT * FROM yup.crudo.medicion;

## La unidad, no la central

Toda la base trabaja por unidad. Una central tiene varias: CHILCA 1 cuatro,
KALLPA cuatro, y entre las eolicas PUNTA LOMITAS reporta dos bloques. Agregar
por central antes de tiempo pierde esa separacion y duplica el impacto de un
mantenimiento que solo saca una unidad. `dim.equipo` es el catalogo, y
`dim.control_equipo` avisa de las unidades que generan pero nunca aparecen en
mantenimientos.

## El maestro del modelo

`Manto2023_2026.xlsm`, hojas `Gen` y `EquivGen`. Se comprobo contra
`Yup_Mtto.xlsm`: la hoja `Gen` es identica en los dos, y el `EquivGen` de
Manto contiene 132 de los 133 pares del otro mas otros 457. Se carga con
`python tools/cargar_maestros.py`.

`Gen` viene ancha (`nombre_g1..g8`, `potencia_g1..g7`) y se guarda larga en
`dim.gen`. `tipo_calculo` decide como se calcula la indisponibilidad:
`total` con MAX sobre los codigos, `parcial` con suma ponderada por potencia.

## Como se corre

    python tools/bd.py                                   crea la base
    python tools/coes_mtto.py 2026-09-20 2026-12-19      mantenimientos, 3 meses
    python tools/coes_med.py  2024-09-01 2026-09-26      mediciones, incremental
    python tools/cargar_maestros.py                      hojas Gen y EquivGen
    python tools/mapear_rer.py                           cruce RER por nombre
    python tools/mapear_caudal.py                        cruce de caudales
    (los .sql de [EJECUCION], desde Excel o duckdb.exe)
    python tools/armar_casos.py --inicio 2026-09-20 --dias 7 --casos 4

Desde Excel es un solo boton: `EjecutarCaso` lee [HORIZONTE], manda fecha_ini y
fecha_fin como variables, corre los .sql de [EJECUCION] sobre una conexion, y
luego los de [COMANDOS], que son los que copian las carpetas (eso el SQL no
puede hacerlo). En un comando, {RAIZ}, {INICIO}, {DIAS} y {CASOS} se sustituyen
por lo que diga [HORIZONTE].

## Estado de los modulos

| modulo | restricciones | estado |
|---|---|---|
| mantenimientos | 4/1, 3/14 | completo, backtest 91% |
| renovables | 25/26 | completo, semana analoga |
| caudales | 4/2, 19/6 | cruce y proyeccion listos; falta la descarga y mas historia |

De los caudales queda pendiente bajarlos solos. En el portal del COES viven en
un repositorio de archivos (Operacion/Estudios/Hidrologia) que se lista con
POST a `/Portal/browser/busqueda`, con los campos ocultos de la pagina
(`hfRelativeDirectory`, `hfIndicadorHeader`, `hfBaseDirectory`,
`hfBreadName`). Ese servicio devuelve 500 a todas las combinaciones que se
probaron, con y sin cookie de sesion y con la ruta en UTF-8 y en cp1252. Queda
ahi documentado para retomarlo.

Mientras tanto los reportes se bajan a mano y entran de golpe:

    python tools/cargar_caudales.py C:eportes --patron "*.xlsx"

Y mientras haya poca historia, `control_caudal_sin_factor` dira 100%: la
proyeccion es en realidad una persistencia del ultimo caudal observado. Es el
numero que hay que mirar para saber si el modulo 3 ya sirve.

Ojo con las hojas de resultados. En CALCULO_DELTAS las hojas `SEM*_2026` no son
semanas observadas sino lo ya calculado, y llevan las fechas de la semana de
referencia: cargarlas contaria esa semana varias veces. El cargador detecta el
rango repetido y las omite.

## Los cruces por nombre

Ni las RER ni los puntos de caudal tienen un archivo que los relacione con los
codigos del COES, asi que se cruzan por nombre y lo dudoso va a revision:

    tools/mapear_rer.py      -> dim.rer         y mapeo_rer.csv
    tools/mapear_caudal.py   -> dim.caudal_pto  y mapeo_caudal.csv

El parecido se mide con Jaccard, palabras compartidas sobre el total de
palabras distintas. No sirve dividir entre el nombre mas corto: con eso
"SAN GABAN III" daba 1.00 contra "SAN GABAN", porque lo contiene entero, y el
caudal del embalse de San Gaban III terminaba sumandose al de San Gaban.

Ademas se avisa de las colisiones, que el puntaje no detecta:

    dos puntos de caudal al mismo equipo de Yupana   habria que sumarlos
    una unidad del COES a dos plantas RER            se contaria dos veces

Los dos casos van a revision en vez de elegir uno. Una planta sin perfil es
preferible a una con el perfil equivocado.

Mientras un modulo no tenga datos, `armar_casos.py` conserva sus restricciones
del caso base y lo avisa. Nunca las borra sin tener con que reemplazarlas.

## Requisito

Driver ODBC de DuckDB con la misma arquitectura que Excel (32/64 bits).
Botón `ProbarConexionDuckDB`.
