-- Completa dim.equipo con lo que solo sabe crudo.mtto. Es idempotente.
--
-- El catalogo lo alimentan dos lados, y por vias distintas:
--   * coes_med.py lo actualiza en cada carga, porque la respuesta de
--     mediciones ya trae el nombre, la ubicacion y la empresa de cada unidad.
--     Esos campos NO se guardan en crudo.medicion: viven aqui.
--   * este script agrega lo que aparece en mantenimientos y nunca genera:
--     casi todo transmision, mas los generadores chicos que no reportan
--     medicion. Tambien es el unico que sabe el tipo (G o T).
--
-- Por eso no borra nada: solo inserta lo que falta y rellena el tipo.

INSERT INTO dim.equipo BY NAME (
    WITH mtt AS (
        SELECT cod_eq AS cod_equipo, equipo, ubicacion, empresa,
               try_cast(tension AS DOUBLE) AS tension,
               tipo_eq_osinerg AS tipo_osinerg,
               false AS visto_medicion, true AS visto_mtto
        FROM crudo.mtto
        WHERE cod_eq IS NOT NULL
        -- La version mas reciente: nombres y empresas cambian con el tiempo.
        QUALIFY row_number() OVER (PARTITION BY cod_eq
                                   ORDER BY descarga DESC, inicio DESC) = 1
    )
    SELECT * FROM mtt
)
ON CONFLICT (cod_equipo) DO UPDATE SET
    -- A una unidad que ya vino de mediciones solo se le agrega el tipo, que
    -- mediciones no trae. Su nombre y su empresa se respetan.
    tipo_osinerg = coalesce(dim.equipo.tipo_osinerg, excluded.tipo_osinerg),
    visto_mtto   = true;

-- `visto_medicion` se marca desde los codigos que hay en crudo.medicion, que
-- es la verdad aunque esa tabla ya no guarde los nombres.
UPDATE dim.equipo SET visto_medicion = true
WHERE cod_equipo IN (SELECT DISTINCT cod_equipo FROM crudo.medicion);

-- El cargador de mediciones inserta sin tocar visto_mtto, asi que puede
-- quedar en nulo. Nulo no es lo mismo que "no visto": se normaliza.
UPDATE dim.equipo
SET visto_medicion = coalesce(visto_medicion, false),
    visto_mtto     = coalesce(visto_mtto, false)
WHERE visto_medicion IS NULL OR visto_mtto IS NULL;

CREATE OR REPLACE VIEW dim.control_equipo AS
-- INFORMATIVA: de donde sale cada unidad. Que haya muchas solo en
-- mantenimientos es normal, casi todas son de transmision. Que haya muchas
-- solo en mediciones significa que falta historia de mantenimientos.
SELECT visto_medicion, visto_mtto, tipo_osinerg, count(*) AS unidades
FROM dim.equipo GROUP BY ALL ORDER BY unidades DESC;
