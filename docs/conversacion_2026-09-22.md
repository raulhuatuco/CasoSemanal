# Bitacora de la sesion — 2026-09-22

Caudales (metodo nuevo y mapeo en la base), mantenimientos (una sola salida),
y la potencia efectiva del parque leida de los PDF del COES.

## 1. Caudales

- **Historia**: `tools/coes_caudal.py` baja por tramos de 31 dias (con un rango
  largo el portal arma todo el rango en cada pagina y un anio tarda 10 min).
  Cargado 2017-01 → 2026-09, 15 estaciones de caudal natural, 1.13 M valores.
- **Metodo** (`sql/30_caudales/10_proyeccion.sql`): anomalia en log sobre la
  climatologia, amortiguada con phi(k) ajustado en la propia base; el equipo
  toma el nivel del caso base escalado por su estacion.
- **Medido** (`tools/backtest_caudal.py`, 15 estaciones, 400 origenes, cada
  anio evaluado fuera de muestra). Error del volumen semanal:

  | semana | 1 | 2 | 3 | 4 |
  |---|---|---|---|---|
  | analogo 2020 (CALCULO_DELTAS) | 40 % | 60 % | 68 % | 76 % |
  | persistencia | 26 % | 37 % | 43 % | 50 % |
  | anomalia | 24 % | 31 % | 33 % | 33 % |

  Anclando en el ultimo dia en vez de la semana: 20 % en la semana 1. A nivel
  sistema (suma de las 15) el error es 12 / 18 / 20 / 21 %.
- **Por que no baja mas**: se midio la correlacion del error con lluvia,
  temperatura, evapotranspiracion y Nino 1+2. Solo pesa la lluvia de la semana
  pronosticada (0.28-0.40), y aun con lluvia futura perfecta el error baja ~2
  puntos. El dato del COES salta 20-40 % de un dia a otro y rebota: es un
  balance de embalse, no un rio. Para bajar mas hace falta otra fuente
  (SENAMHI tiene estacion solo en Santa Eulalia y Locumba).
- **Mapeo equipo → estacion**: ahora en la base (`dim.caudal_estacion`,
  cargada con `tools/cargar_mapeo_caudal.py` desde `mapeo_caudal.csv`).
  Reglas del usuario: la estacion tiene que estar en la cuenca de la central
  (se quitaron 7 de cuenca vecina), y el embalse **estacional** no se estima
  porque su aporte lo fija el plan de descargas; solo los de regulacion
  horaria toman caudal de ingreso.
- **Corregido en `armar_casos.py`**: caudales reemplazaba tambien 19/7-12
  (volumenes, defluencias, riego), que se perdian del caso base.

## 2. Mantenimientos

`sql/10_mantenimientos/50_resultado.sql` deja `crudo.mantenimiento_final`: un
tramo por equipo, ya en equivalentes, agrupado y sin solapes (108 tramos, 51
equipos en el horizonte actual; `control_mantenimiento_solape` = 0). Es lo
unico que hay que mirar del modulo.

## 3. Libros por tema

El usuario arma los `.xlsm`. Tres hojas (`Datos`, `Resultado`, `Control`) y dos
botones: **1 Actualizar datos** (refresca de la base segun el horizonte) y
**2 Procesar**. Falta escribir el modulo VBA simple que los soporte; el actual
(`EjecutarSQL.bas`) expone cada script y es demasiado.

## 4. Potencia efectiva (repo BD-OyM)

- opencode descargo 1648 PDF del COES pero su lectura fallo: 453 documentos
  leidos, 145 con potencia y **ninguno anterior a 2020** (OCR a 300 dpi).
  Tampoco dejo la herramienta en el repo.
- Ademas borro de Historia los eventos de ingreso y retiro, y al reponerlos
  quedaron **permutadas las columnas**: `Range.Sort` de Excel por COM reutiliza
  los parametros de la ordenacion anterior y una estaba en horizontal.
  Reparado con `01Analisis/reparar_historia.py`: 800 filas, 393 POT_EFECTIVA y
  407 eventos, sin POT_INSTALADA.
- Dos trampas del libro, anotadas: vive en OneDrive y Excel lo abre por su URL
  de nube (hay que editar una copia local y devolverla), y la hoja tiene
  autofiltro (`End(xlUp)` devuelve la fila 1; usar `UsedRange`).
- **Herramienta nueva**: `scripts/leer_potencia_efectiva.py` (OCR 400 dpi
  `--psm 6`, cache `.txt` al lado del PDF, modo y combustible por fila,
  convencion decimal resuelta por rango fisico) y
  `scripts/cargar_potencia_efectiva.py` (tablas `aterrizaje.potencia_efectiva`
  y `aterrizaje.curva_unidad`, llave unidad + modo + combustible).
- Lo que no se lee no se pierde: `pendientes.csv` con el motivo (solo carta,
  tabla ilegible, valor dudoso, curva no leida) y las columnas a llenar. Lo
  completado se pega en `potencia_efectiva_manual.csv`, que manda sobre el PDF
  y nunca se regenera.

## 5. Siguiente

1. Termina el OCR (iba por 775 de 1700). Volver a correr
   `python scripts/leer_potencia_efectiva.py` (el segundo pase solo reinterpreta
   el cache) y luego `cargar_potencia_efectiva.py`.
2. Mover la carpeta `Carga/potencia_efectiva` cuando termine la lectura.
3. Confirmar con el usuario que embalses son estacionales (hoy: Malpaso,
   Aguada Blanca, Cincel).
4. Escribir el VBA de dos botones y armar los tres libros.
5. Llevar el modelo eolico al motor; migrar el motor a leer de BD-OyM.
