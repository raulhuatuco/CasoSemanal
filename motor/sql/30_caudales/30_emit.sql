-- Vuelca los caudales al contrato comun. El destino depende del tipo de punto,
-- que resolvio dim.caudal_pto: Planta va a 4/2 y Embalse a 19/6. El valor son
-- m3/s.
DELETE FROM crudo.hecho_restriccion WHERE modulo = 'caudales';

INSERT INTO crudo.hecho_restriccion
SELECT 'caudales', m.id_yupana, m.equipo_yupana, m.categoria, m.restriccion,
       p.fecha, p.slot, round(sum(p.m3s), 4)
FROM crudo.caudal_proyectado p
JOIN dim.caudal_pto m ON m.cod_pto = p.cod_pto
GROUP BY ALL;
