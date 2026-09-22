# CasoSemanal

Arma casos semanales para Yupana a partir de los datos publicados por el COES.

Un caso es una copia de `caso_base` con tres archivos reescritos:

    datosrestricciones.csv   48 medias horas por equipo, dia y restriccion
    escenario.csv            nombre, fecha de inicio y horizonte
    detalleetapa.csv         numero de etapas y paso

Todo lo demas de la carpeta se copia tal cual, y dentro de
`datosrestricciones.csv` solo se tocan las filas de las restricciones que
produce algun modulo. Las demas se conservan del caso base con las fechas
corridas al horizonte nuevo.

## Los tres modulos

| modulo | restricciones | de donde sale |
|---|---|---|
| mantenimientos | 4/1, 3/14 | portal de mantenimientos del COES |
| renovables | 25/26 | mediciones a 30 min, perfil tipico por tecnologia |
| caudales | 4/2, 19/6 | historico de hidrologia y reporte de caudales |

Todo esta en [`motor/`](motor/), que es una carpeta portable: no tiene rutas
absolutas y se puede mover entera. Su [README](motor/README.md) explica la
hoja `Params`, la base local y como se corre, desde Excel o desde la linea de
comandos.

## Lo que no esta en el repo

Los datos pesados quedan fuera: `caso_base/`, `nuevos_casos/`, los libros de
Excel y la base local `motor/staging/yupana.duckdb`. El codigo los reconstruye
descargando del COES.

`scripts/` guarda la version original en Python, de un solo modulo, como
referencia de lo que hacia antes.
