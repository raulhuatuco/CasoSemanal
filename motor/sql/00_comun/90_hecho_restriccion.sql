-- La tabla comun se crea en 00_esquema.sql.

-- Mantenimientos: el valor es el porcentaje indisponible, 0 disponible y 100
-- fuera de servicio, que es como lo guarda el caso base.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'mantenimientos';

INSERT INTO crudo.hecho_restriccion
SELECT 'mantenimientos', id_yupana, equipo,
       CASE tipo WHEN 'hidro' THEN 4 ELSE 3 END,
       CASE tipo WHEN 'hidro' THEN 1 ELSE 14 END,
       fecha, slot, round(indisponibilidad * 100, 4)
FROM crudo.indisp_yupana;
