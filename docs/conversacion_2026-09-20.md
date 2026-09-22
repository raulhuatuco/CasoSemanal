# Bitacora de la sesion de diseno — 2026-09-20 / 21

Registro de la conversacion con la que se construyo `motor/`: que se pidio,
que se encontro y que se decidio. Esta ordenado en el tiempo. El detalle
tecnico de cada pieza esta en [`motor/README.md`](../motor/README.md) y en los
mensajes de commit.

## 1. El encargo

El proyecto actualiza un caso Yupana (resolucion de 30 min) a partir de
`caso_base/YUPANA_SEM2326`, modificando `datosrestricciones.csv`. Antes era un
solo script Python (`scripts/`). Se pidio:

- partirlo en tres modulos: **mantenimientos**, **renovables** y **caudales**;
- hacerlo en SQL sobre DuckDB, disparable desde Excel por VBA, reutilizando el
  patron de `00e-Quilibrium/05Extensions` (`EjecutarSQL.bas`, `getvariable`);
- una hoja de configuracion y una carpeta portable con SQL y VBA;
- mantenimientos con prelacion **diario > semanal > mensual**, deduplicando la
  fuente del COES, usando `EquivGen` y la hoja `Gen` sin duplicar impacto.

## 2. Diagnostico inicial

- Los tres modulos escriben la misma tabla: solo cambia el par
  (categoria, restriccion). Se definio un contrato comun,
  `crudo.hecho_restriccion`, y un solo emisor que pivotea a 48 medias horas.
- El script viejo tenia bugs concretos (`clip(lower=)` por `upper=`, mascara
  de RSF equivocada, hoja leida dos veces, formateo fila por fila).
- `Manto2023_2026.xlsm` tenia 332 mil filas pegadas a mano, sin conexion.

## 3. Mantenimientos

**Endpoints.** Salieron de `06DashboardCOES`. La lista HTML abrevia los valores
(`F`, `E`, `P`); el export (`GenerarArchivoReporte` + `ExportarReporte`)
entrega las 16 columnas completas, igual que la hoja `fuente-COES`. Trampas:
`tiposMantenimiento=-1` solo trae EJECUTADOS, y la columna MANTENIMIENTO se
estampa con el tipo pedido, asi que se baja un tipo por llamada.

**Prelacion.** La regla ingenua ("gana el programa mas fino que toque el dia")
fallaba: el diario declara eventos largos cuya cola desplazaba al semanal. Se
paso a un horizonte de vigencia por programa (diario D0 y D0+1, semanal
domingo a sabado, mensual sin tope). El tope inicial del mensual dejaba 17 dias
sin mantenimientos; se lo quito.

**Validacion.** Backtest contra EJECUTADOS de junio 2026: 91% capturado; de lo
que se escapa, 124 de 195 son forzados. Contra el caso base: 74% de
coincidencia de celdas. De ahi salio un bug real: `plantah.csv` trae la central
entera **y** sus unidades (HUINCO y HUINCO G1..G4) y el caso elige una con
`Considera Equipo`. Se emitian las dos. Corregido.

**Decisiones del usuario.**
- `E/S` no va. Es lo que ya hacia `main.py:90`; no es decision del motor.
- `parcial` reparte por potencia de maquina y `total` saca la central entera.
  Si la central no sale de servicio, no hay efecto.
- Los valores 1.87 y 9.00 de MANTARO en el caso base no salen de esa logica ni
  de los datos del COES. No hay que reproducirlos: las diferencias con el
  programa del COES no importan, porque sus supuestos cambian en el diario.

## 4. Renovables

Primero se implemento **semana analoga**: la semana historica mas parecida a
la ultima observada, y las siguientes a ella. El usuario dudo del metodo. Se
midio contra lo ejecutado:

| metodo | RMSE | MAE |
|---|---|---|
| programa semanal del COES | 90 MW | 68 MW |
| semana analoga | 177 MW | 144 MW |

Como el horizonte pedido empieza **despues** del ultimo programa del COES, el
PSO no esta disponible ahi. Se mantuvo el analogo pero copiando el **factor de
planta** en vez de los MW, escalado a la capacidad de hoy (la capacidad RER
paso de 1879 a 2189 MW en pocos meses). Aprobado por el usuario.

El cruce plantanco.csv con las unidades del COES no existia: se hizo por
nombre, con Jaccard y deteccion de colisiones. 57 de 80 automaticas; el resto
en `motor/mapeo_rer.csv`.

## 5. Caudales

- La fuente buena es el Historico de Hidrologia del COES
  (`/Portal/Operacion/HistoricoHidrologia`), indicada por el usuario.
  `idsPtoMedicion` son tipos de caudal; el 8 es CAUDAL NATURAL ESTIMADO.
- **Advertencia del usuario:** hacen falta caudales naturales, porque no estan
  afectados por la descarga de la laguna. El libro `CALCULO_DELTAS` usa caudal
  de planta y de embalse, que si lo estan. Se separaron las fuentes en tablas
  distintas y se fijo la regla: el natural manda y nunca se mezclan clases.
- El reporte de caudales va cada 30 min (lo noto el usuario). El cargador
  mandaba 00:30 al slot 2 y el cierre 23:59 chocaba con las 23:00. Corregido.
- Pendiente: poca historia, asi que la proyeccion es persistencia
  (`control_caudal_sin_factor` = 100%).

## 6. Horizonte y armado del caso

- El caso modifica tres archivos: `datosrestricciones.csv`, `escenario.csv`
  (nombre y fecha de inicio) y `detalleetapa.csv`. Es lo mismo que escribia el
  script viejo.
- Se pidio **4 semanas despues de la ultima semana del COES**:
  `armar_casos.py --inicio auto`.
- `armar_casos.py` solo reemplaza las restricciones que un modulo lleno; las
  demas se conservan del caso base con las fechas corridas.

## 7. Base de datos

DuckDB local en `motor/staging/`, fuera del repo. Capa `crudo` append-only con
fecha de descarga, porque el COES reescribe el pasado; `dim` con maestros. Se
mudara a una base mas grande, asi que solo usa llaves naturales del COES y
todo trabaja por unidad (hay eolicas con varios bloques). Hallazgos: el
`executemany` era 250 veces mas lento que la carga en bloque, y los indices ART
inflaban el archivo de 32 a 254 MB sin acelerar nada.

## 8. Pendientes al cierre

1. El mantenimiento no llega al final de las 4 semanas: `control_dia_sin_unidades`
   marca del 1 al 4 de noviembre. Falta PROGRAMADO ANUAL, que solo esta en la
   lista HTML.
2. Cargar mas historia de caudal natural (la descarga se corta a 399 dias por
   el tope de paginas; hay que partir en tramos).
3. Revisar `mapeo_rer.csv` y `mapeo_caudal.csv` (UPAMAYO, TOMA Km 105...).
