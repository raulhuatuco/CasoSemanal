# Bitacora de la sesion — 2026-09-21 / 22

Mejora de la proyeccion solar y eolica, y paso a BD-OyM como base principal.
El detalle tecnico esta en los commits y en `motor/README.md`; lo de la base,
en el repo BD-OyM (`BITACORA-2026-09-21.md`).

## 1. Renovables en el motor

- **Metodo nuevo** (`motor/sql/20_renovables/10_proyeccion.sql`): perfil tipico
  en factor de planta, escalado a la capacidad de hoy. Solar y eolica: 50 %
  ultimos 28 dias + 50 % misma epoca del anio pasado; otras RER: ultima semana.
- **Medido** en 74 semanas a 4 semanas vista (nMAE a 30 min sobre capacidad):

  | | semana analoga | perfil tipico |
  |---|---|---|
  | solar | 8.4 % | 4.9 % |
  | eolica | 21.0 % | 16.0 % |
  | otras RER | 10.4 % | 6.9 % |

  La analoga ademas subestimaba la solar un 15 %: las plantas que no existian
  en la semana copiada salian en cero.
- **Cruce RER corregido** (`mapeo_rer.csv`): WAYRA_EXP tomaba la solar Wayra en
  lugar de Wayra Extension (178 MW); CS CARHUAQUERO sumaba la C.H. Carhuaquero
  (92 MW); se agregaron Punta Lomitas Exp., Intipampa Exp., Yarucaya, Coenergy.
- **Pendiente**: 16 RER sin cruce (~89 MW medios) pierden sus filas porque
  `armar_casos.py` reemplaza la restriccion 25/26 entera. Falta decidir.

## 2. Decisiones del usuario

- La base principal es BD-OyM (`C:\RAUL\00Proy\02_BD-OyM\almacen.duckdb`).
- El **medidor es definitivo**; el ejecutado (waMediciones) es una aproximacion
  que informan las empresas. Se usa medidor donde existe y ejecutado donde
  falta. El ejecutado no valida al medidor.
- Solar: basta el perfil tipico (generacion estable, nubosidad de poco peso).
- Eolica: calibrar reproduciendo cada mes medido, empezando por el ultimo
  (agosto 2026). Meta: **error de energia mensual de 2 a 3 %**. La proyeccion
  debe llevar temperatura.
- El maestro del parque son las hojas `Gen`, `Historia` y `Curvas` de
  `01Analisis\Balance_Esperado0126.xlsx`.

## 3. Resultado de la calibracion eolica

LightGBM unico para todas las plantas, con viento corregido por densidad,
temperatura, contraste aire-mar y anomalia Nino 1+2; capacidad instalada por
fecha desde `Historia`; correccion de sesgo con los 3 meses previos. Con clima
ERA5, ultimos 12 meses:

- parque completo: sesgo -0.2 %, error de energia mensual 2.6 % (max 6.7 %);
- por central: 3.9 % (Tres Hermanas) a 20 % (Duna). Cupisnique, Duna y
  Huambos son los peores.

Hallazgo: el Nino costero de 2026 (anomalia +4.6 C) reduce la produccion a
igual viento en la zona de Marcona. Un modelo por planta lo confundia con la
puesta en marcha de San Juan y Punta Lomitas (2023, tambien anio Nino); el
modelo conjunto lo aprende de las plantas antiguas.

## 4. Siguiente

1. Descontar mantenimientos por planta.
2. Coordenadas exactas de Duna y Huambos; estaciones NOAA como contraste de ERA5.
3. Medir el pronostico real con `OM-D1..D7` (semana 1).
4. Llevar el modelo eolico al motor y migrar el motor a leer de BD-OyM.
5. En la hoja `Params` de `Yupana_Motor.xlsm`: cambiar `10_semana_analoga.sql`
   por `10_proyeccion.sql`.
