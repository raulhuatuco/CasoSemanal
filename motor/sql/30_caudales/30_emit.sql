-- Vuelca los caudales al contrato comun. El destino lo trae ya resuelto
-- crudo.caudal_serie: los puntos de planta van a 4/2 y los de embalse a 19/6.
-- El valor son m3/s.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'caudales';

INSERT INTO crudo.hecho_restriccion
SELECT 'caudales', id_yupana, equipo_yupana, categoria, restriccion,
       fecha, slot, round(m3s, 4)
FROM crudo.caudal_proyectado;
