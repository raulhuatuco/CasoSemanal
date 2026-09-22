-- Vuelca los aportes proyectados (m3/s) al contrato comun: 4/2 plantas, 19/6 embalses.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'caudales';

INSERT INTO crudo.hecho_restriccion
SELECT 'caudales', id_yupana, equipo_yupana, categoria, restriccion,
       fecha, slot, round(m3s, 4)
FROM crudo.caudal_proyectado;
