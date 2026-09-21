-- Vuelca la proyeccion renovable al contrato comun.
-- Categoria 25 (Plantas no Convencionales y Otros), restriccion 26
-- (Generacion RER). El valor son MW generados, no un porcentaje.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'renovables';

INSERT INTO crudo.hecho_restriccion
SELECT 'renovables', id_yupana, nombre, 25, 26, fecha, slot, round(mw, 4)
FROM crudo.rer_proyectado;
