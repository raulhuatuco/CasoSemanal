# Bitacora de la sesion — 2026-10-05

Las curvas de las termicas salen de un reporte del COES ya digitado, y los
libros de tema quedan con dos botones y un Params corto.

## 1. Las curvas de las termicas, sin OCR

El `Reporte Compensaciones por Costo Variable` del COES (mensual, MME) trae la
hoja `DatosGenerador` con los parametros de las termicas ya digitados: potencia
efectiva, cuatro potencias parciales, su Cec en kJ/kWh, el consumo de
combustible de cada punto, la potencia minima y el **consumo a potencia 0**,
que es el que no sale de los PDF.

- Periodo 2026.Agosto: 156 filas, **85 combinaciones unidad + modo +
  combustible**, 15 empresas, diesel / gas natural / residual. La llave es la
  misma que ya se definio para potencia efectiva: el rotulo de la fila es el
  **modo** (`CHILCA1 CCOMB TG1 & TG2 - GAS`), no la unidad.
- Cubre toda la termica convencional. Quedan fuera los 15 modos de bagazo,
  biogas y RF Talara que si aparecen en la hoja `CvoaCMg`: esos no declaran
  curva de combustible.
- El consumo cuadra con `P x Cec / (LHV x densidad)` al 0.1 % en diesel y en el
  gas con densidad 0 (ahi el LHV viene en kJ/m3). **10 filas de gas traen
  densidad 0.8505 / 0.8405, que es gravedad especifica, no densidad**:
  recalcular da 17 % de mas. Se copia el consumo reportado, no se reconstruye.
- La columna `BARRA / Dia Per.` trae la barra o un numero, que es el dia del mes
  en que se redeclaro. En agosto hay 5 filas con dia 10, todas de Fenix en
  diesel, con potencia efectiva mas baja que la del dia 1.

La hoja `CurvT` de `Balance_Esperado0126.xlsm` ya es esa tabla pegada, sin
duplicados de precio: 90 filas (85 modos + 5 redeclaraciones), con dos columnas
nuevas por llenar, `EQUICODI_UNIDAD` y `FechaVigencia`.

**La fecha de vigencia no es el periodo del reporte** sino la del estudio de
potencia efectiva, que es lo que dan los PDF. Decision del usuario; queda
pendiente como completarla. Las dos fuentes son complementarias: el reporte
trae la curva digitada, el PDF la fecha desde la que rige.

## 2. El cruce con Yupana

`dim.equipo_yupana` categoria 3 (97 equipos) **es** la lista de modos de
operacion, y su `capacidad` es la potencia efectiva: **82 de los 90 modos
cruzan exacto por potencia**. Los 8 que no son los 5 de Fenix del dia 10 y
`STA ROSA TG8`, `SAN NICOLAS TV1` y `TV2`, donde el caso base tiene una
potencia mas vieja: justo lo que el fechado viene a resolver.

El usuario prefiere asociar el modo al **codigo Yupana** y poner el asociado en
la columna `COD_YUPANA` de `Gen` (hoy vacia en las 85 termicas). El cruce de
modo a EQUICODI quedo en `01Analisis/CurvT_codigos.csv`, con el ciclo combinado
como suma de codigos (`202+203+13204`); su columna de fecha no sirve con el
criterio de arriba.

Yupana tiene 15 equipos de categoria 3 sin modo en el reporte de agosto:
TUMBESR6, los de inyeccion de agua de Malacas y Ventanilla, ILO2_CARB,
SN_TV3, ECUADOR-TG y los 5 de REF_TALARA.

## 3. Los libros de tema: dos botones

`vba/Botones.bas`, una macro por boton, las mismas para los tres libros:

| macro | que hace | toca la red |
|---|---|---|
| `ActualizarDatos` | revisa que la base cubra el horizonte y descarga lo que falte | si |
| `Procesar` | corre el script del modulo y deja el resultado a la vista | no |

La revision es una consulta a `crudo.descarga`: cuantos dias del horizonte no
tienen dato y que antiguedad tiene la descarga mas nueva. Si falta algo o pasa
de las horas permitidas, corre el comando de esa fuente, vuelve a revisar y
escribe el estado al lado de la fila. Cierra la conexion antes de descargar:
DuckDB admite un solo escritor y con Excel encima el python no puede escribir.
`Procesar` repite la revision, avisa si la base esta vieja y deja seguir.

Params quedo en 15 filas con dato ([`Params_mantenimientos.csv`](../motor/Params_mantenimientos.csv)),
porque el detalle se movio a donde se usa:

- **Un solo `script`**, `sql/10_mantenimientos.sql`, que declara sus pasos con
  lineas `-- #incluir 10_vigente.sql` y las resuelve el VBA antes de mandar
  nada a DuckDB. Los pasos siguen en su archivo, que es como los comparten los
  tres modulos, pero Params ya no los enumera.
- **El esquema salio de Params**: `00_esquema.sql` es diseno de base y lo corren
  las herramientas de descarga cada vez que la abren.
- **Las 9 hojas `chk_` pasaron a una**: `crudo.control` da una fila por control
  con su conteo, que significa, y `FALLA` cuando la que debe dar 0 no lo da. El
  detalle sigue en su vista con el mismo nombre.
- **Las consultas largas salieron de las celdas**: `crudo.mtto_horizonte`, en el
  esquema, es lo que el boton 1 deja en `Datos`.

Probado de punta a punta por fuera de Excel (expansion de los `#incluir` y
corrida completa): 4 controles en 0, 148 tramos en el resultado, 345 eventos en
el horizonte. El VBA no esta compilado todavia; los botones los pone el
usuario.

Si la carpeta esta en OneDrive, Excel abre el libro por su URL de nube y
`ThisWorkbook.Path` devuelve `https://...`: para eso `[CARPETAS]` admite `raiz`
con la ruta local.

## 4. Potencia efectiva (repo BD-OyM)

El OCR sigue corriendo: 1139 de 1648 PDF leidos. Nada cargado en la base
todavia (`aterrizaje.potencia_efectiva` no existe aun).

## 5. Siguiente

1. Terminar el OCR y cargar; de ahi sale la fecha de vigencia de cada curva.
2. Llenar `CurvT` con el codigo Yupana y `COD_YUPANA` en `Gen`.
3. Importar `Botones.bas` a `Yupana_Mantenimientos.xlsm`, pegar el Params nuevo,
   crear `Datos` / `Resultado` / `Control` y poner los dos botones.
4. Repetir la estructura en los libros de RER y caudales (su `[FUENTE]` es
   `medicion` y `caudal`).
5. Juntar un reporte de compensaciones por mes: es la unica forma de tener
   historia de curvas, y ya viene digitada.
