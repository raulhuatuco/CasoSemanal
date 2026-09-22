# motor — actualizador de casos Yupana

Carpeta **portable**: no contiene ninguna ruta absoluta. Muévela donde quieras
(otro disco, otro equipo, otro repo) y sigue funcionando, porque todo se
resuelve contra la ubicación del libro `Yupana_Motor.xlsm` mediante
`Absoluta(ruta, base)` de `EjecutarSQL.bas`.

    motor/
      Yupana_Motor.xlsm     único punto de entrada: hoja Params + botones
      Params.csv            plantilla de la hoja Params (pegar en el libro)
      Params_caudales.csv   Params del libro de caudales
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
    python tools/coes_caudal.py 2026-09-01 2026-09-21    caudal natural, a diario
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
| mantenimientos | 4/1, 3/14 | completo; ver el aviso de abajo sobre el final del horizonte |
| renovables | 25/26 | completo, perfil tipico por tecnologia, escalado a la capacidad de hoy |
| caudales | 4/2, 19/6 | completo, anomalia del caudal natural sobre su climatologia; libro propio |

Un libro por tema. Cada uno tiene su hoja `Params` con solo sus scripts y sus
salidas, y todos escriben en la misma base: cada modulo borra y repone solo
sus filas de `crudo.hecho_restriccion`, y `armar_casos.py` junta lo que haya.
Caudales usa `Params_caudales.csv`; mantenimientos y RER siguen en
`Params.csv` hasta separarlos igual.

## Los caudales

`30_caudales/10_proyeccion.sql`, en dos pasos:

1. **Estacion natural** (Historico de Hidrologia del COES, CAUDAL NATURAL
   ESTIMADO, 15 estaciones desde 2017). Se proyecta la anomalia en log del
   caudal de la ultima semana respecto de su climatologia, y se diluye con la
   anticipacion: `log Q = clima + phi(k) * anomalia`. `phi` (0.75 a una
   semana, 0.35 a cuatro) y la correccion de volumen salen de la propia
   historia (`crudo.caudal_phi`).
2. **Equipo de Yupana**: aporte del caso base x Qproy / Qobs en la semana del
   caso base. La estacion de cada equipo esta en `mapeo_caudal.csv`:
   `equivalente` (la de CALCULO_DELTAS o el mismo punto), `cuenca` (otro punto
   del mismo rio) o `vecina` (sin estacion en su cuenca; solo presta la forma).
   Sin estacion se repite el caso base.

Backtest (`tools/backtest_caudal.py`), 15 estaciones, 400 origenes semanales
2018-2026, climatologia sin el anio evaluado. Error del volumen semanal:

    semana                    1       2       3       4
    analogo 2020 (DELTAS)   40.0 %  59.9 %  68.3 %  76.4 %   sesgo +9 a +34 %
    persistencia            25.7 %  36.7 %  43.4 %  50.0 %
    anomalia (actual)       24.4 %  30.7 %  32.5 %  33.4 %   sesgo < 1 %

En estiaje (mayo-noviembre) 19 / 26 / 29 / 31 %. El analogo de un solo anio es
el peor: hereda la hidrologia de 2020, que no tiene por que repetirse.

Controles: `control_caudal_equipo` (estacion, escala y factor por semana),
`control_caudal_sin_estacion` y `control_caudal_dato_viejo` (debe ser 0: correr
`coes_caudal.py` antes). Resumen por semana en `resumen_caudal_semanal`.

`coes_caudal.py` pide por tramos de 31 dias: con un rango largo el portal arma
todo el rango en cada pagina y un anio tarda 10 minutos.

Revisar en `mapeo_caudal.csv`: CINCEL sin estacion; AGUADA BLANCA, CH. CHAGLLA,
CHECRAS, CAPILLUCAS y RENOVANDES con estacion vecina; GALLITO CIEGO y
HUALLAMAYO son `equivalente` pero su aporte en el caso base es 2.9 veces el
natural.

## Donde falla todavia

**El mantenimiento no llega al final de un horizonte de 4 semanas.** El
programa mensual del COES declara hasta poco despues del mes en curso, asi que
los ultimos dias se quedan sin ningun evento y el caso sale con toda la
generacion disponible. `control_dia_sin_unidades` los marca: si da distinto de
0, esos dias son optimistas. Queda pendiente rellenarlos con PROGRAMADO ANUAL,
que existe en la lista HTML del portal pero no en el export.

## Las renovables

`20_renovables/10_proyeccion.sql` proyecta en factor de planta por media hora
y multiplica por la capacidad de hoy (el mayor MW de los ultimos 120 dias).
El metodo depende de la tecnologia, que sale del nombre del COES:

    solar, eolica   50 % perfil medio de los ultimos 28 dias
                    50 % misma epoca del anio pasado, +-15 dias
    otras           perfil medio de la ultima semana (hidro de pasada, biomasa)

Reemplazo a la semana analoga. Medido sobre 74 origenes semanales a 4
semanas, error medio absoluto a media hora sobre la capacidad:

                    semana analoga    ahora
    solar            8.4 %            4.9 %
    eolica          21.0 %           16.0 %
    otras RER       10.4 %            6.9 %

La analoga ademas subestimaba la energia solar un 15 %: una planta que no
existia en la semana copiada salia en cero. El perfil tipico es suave, sin
dias nublados ni calmas; para el despacho semanal es lo que corresponde.

Controles: `control_rer_perfil` (metodo, capacidad y factor de planta de cada
planta; 'solo reciente' es una planta sin un anio de historia),
`control_rer_parada` y `control_rer_faltante`.

## Los cruces por nombre

Las RER no tienen un archivo que las relacione con los codigos del COES, asi
que se cruzan por nombre y lo dudoso va a revision (los caudales, 32 equipos,
se asignan a mano en `mapeo_caudal.csv`):

    tools/mapear_rer.py      -> dim.rer         y mapeo_rer.csv

El parecido se mide con Jaccard, palabras compartidas sobre el total de
palabras distintas. No sirve dividir entre el nombre mas corto: con eso
"SAN GABAN III" daba 1.00 contra "SAN GABAN", porque lo contiene entero, y el
caudal del embalse de San Gaban III terminaba sumandose al de San Gaban.

Ademas se avisa de las colisiones, que el puntaje no detecta:

    una unidad del COES a dos plantas RER            se contaria dos veces

Va a revision en vez de elegir una.

El puntaje tampoco sabe de tecnologia: WAYRA_EXP cruzaba con C.S. WAYRA SOLAR
(64 MW) en vez de C.E. WAYRA EXTENSION (178 MW), y CS CARHUAQUERO, una solar
de 0.5 MW, sumaba tambien la C.H. CARHUAQUERO de 92 MW. Estan corregidos en
`mapeo_rer.csv`, que manda sobre el automatico. Una planta sin perfil es
preferible a una con el perfil equivocado.

Mientras un modulo no tenga datos, `armar_casos.py` conserva sus restricciones
del caso base y lo avisa. Nunca las borra sin tener con que reemplazarlas.

## Requisito

Driver ODBC de DuckDB con la misma arquitectura que Excel (32/64 bits).
Botón `ProbarConexionDuckDB`.
