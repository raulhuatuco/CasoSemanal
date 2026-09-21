-- La tabla que comparten los tres modulos. Ninguno escribe CSV: todos llenan
-- esta, y armar_casos.py la pivotea a las 48 medias horas.
--
-- El par (categoria, restriccion) es el que usa Yupana en
-- datosrestricciones.csv, y `equipo` es el id de la tabla correspondiente:
-- categoria 4 -> plantah.csv, categoria 3 -> modot.csv.
CREATE TABLE IF NOT EXISTS crudo.hecho_restriccion (
    modulo      VARCHAR,   -- mantenimientos / renovables / caudales
    equipo      INTEGER,   -- id_yupana dentro de su categoria
    nombre      VARCHAR,
    categoria   INTEGER,
    restriccion INTEGER,
    fecha       DATE,
    slot        TINYINT,   -- 1..48
    valor       DOUBLE
);

-- Mantenimientos: el valor es el porcentaje indisponible, 0 disponible y 100
-- fuera de servicio, que es como lo guarda el caso base.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'mantenimientos';

INSERT INTO crudo.hecho_restriccion
SELECT 'mantenimientos', id_yupana, equipo,
       CASE tipo WHEN 'hidro' THEN 4 ELSE 3 END,
       CASE tipo WHEN 'hidro' THEN 1 ELSE 14 END,
       fecha, slot, round(indisponibilidad * 100, 4)
FROM crudo.indisp_yupana;
