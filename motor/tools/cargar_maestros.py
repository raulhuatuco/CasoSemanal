"""Carga las hojas Gen y EquivGen del libro maestro a la base.

    python cargar_maestros.py            # usa Manto2023_2026.xlsm

Gen se guarda larga: la hoja trae nombre_g1..g8 y potencia_g1..g7 en columnas,
y aqui sale una fila por unidad Yupana y codigo COES.
"""
from __future__ import annotations

import argparse
import pathlib

import bd

LIBRO = bd.RAIZ.parent / "Manto2023_2026.xlsm"
CASO = bd.RAIZ.parent / "caso_base" / "YUPANA_SEM2326"

# De que archivo del caso sale cada categoria de equipo.
TABLAS_CASO = {4: "plantah.csv", 3: "modot.csv"}


def _hoja(libro: pathlib.Path, nombre: str):
    import openpyxl
    ws = openpyxl.load_workbook(libro, read_only=True, data_only=True)[nombre]
    filas = list(ws.iter_rows(values_only=True))
    # La cabecera no esta en la fila 1: los dos libros llevan titulos encima.
    i = next(k for k, r in enumerate(filas)
             if sum(1 for v in r if v not in (None, "")) > 3)
    cab = [str(v).strip() if v else f"col{j}" for j, v in enumerate(filas[i])]
    datos = [r for r in filas[i + 1:] if any(v not in (None, "") for v in r)]
    return {c: j for j, c in enumerate(cab)}, datos


def _entero(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--libro", default=str(LIBRO))
    p.add_argument("--caso", default=str(CASO))
    p.add_argument("--bd", default=None)
    a = p.parse_args()
    libro = pathlib.Path(a.libro)

    ix, datos = _hoja(libro, "Gen")
    gen = []
    for r in datos:
        base = (_entero(r[ix["id_yupana"]]), r[ix["equipo"]], r[ix["tipo"]],
                r[ix["tipo_calculo"]], r[ix["nombre_coes"]])
        if base[0] is None:
            continue
        for n in range(1, 9):
            cod = _entero(r[ix[f"nombre_g{n}"]]) if f"nombre_g{n}" in ix else None
            if cod is None:
                continue
            pot = r[ix[f"potencia_g{n}"]] if f"potencia_g{n}" in ix else None
            gen.append(base + (n, cod, float(pot) if pot is not None else None))

    ix, datos = _hoja(libro, "EquivGen")
    equiv = [(_entero(r[ix["SICOES"]]), _entero(r[ix["EquivSICOES"]]),
              r[ix.get("EQUIABREV", 0)], r[ix.get("EQUINOMB", 0)],
              r[ix.get("AREANOMB", 0)])
             for r in datos if _entero(r[ix["SICOES"]]) is not None]

    # Que equipos usa el caso. Sin esto se emite mantenimiento para la
    # central entera y para sus unidades a la vez.
    equipos = []
    for cat, archivo in TABLAS_CASO.items():
        filas, _ = bd.leer_csv(pathlib.Path(a.caso) / archivo)
        cab = [str(c).strip() for c in filas[0]]
        ix = {c: j for j, c in enumerate(cab)}
        j_con = ix.get("Considera Equipo", 3)
        j_esc = next((j for c, j in ix.items() if c.startswith("Considera en Escenario")), 12)
        j_cap = next((j for c, j in ix.items() if c.startswith("Capacidad Instalada")), 13)
        for r in filas[1:]:
            if not r or not r[0].strip().isdigit():
                continue
            def num(j):
                try: return float(r[j])
                except (IndexError, ValueError): return None
            equipos.append((cat, int(r[0]), r[1], str(r[j_con]).strip() == "1",
                            str(r[j_esc]).strip() == "1", num(j_cap)))

    import pandas as pd
    cn = bd.abrir(a.bd)
    cn.register("lote", pd.DataFrame(equipos, columns=[
        "categoria", "id_yupana", "equipo", "considera", "escenario",
        "capacidad"]))
    cn.execute("DELETE FROM dim.equipo_yupana")
    cn.execute("INSERT INTO dim.equipo_yupana SELECT * FROM lote")
    cn.unregister("lote")
    print(f"  {'dim.equipo_yupana':<14} {len(equipos):>5} filas, "
          f"{sum(1 for e in equipos if e[3])} que el caso considera")
    for tabla, filas, cols in [
        ("dim.gen", gen, ["id_yupana", "equipo", "tipo", "tipo_calculo",
                          "nombre_coes", "orden", "cod_coes", "potencia"]),
        ("dim.equivgen", equiv, ["cod_coes", "cod_equiv", "equiabrev",
                                 "equinomb", "areanomb"]),
    ]:
        cn.register("lote", pd.DataFrame(filas, columns=cols))
        cn.execute(f"DELETE FROM {tabla}")
        cn.execute(f"INSERT INTO {tabla} SELECT * FROM lote")
        cn.unregister("lote")
        print(f"  {tabla:<14} {len(filas):>5} filas")

    # Control: codigos del maestro que la base no conoce. Un codigo huerfano no
    # se cruza con ningun mantenimiento, asi que esa unidad nunca sale de
    # servicio y el caso queda optimista sin avisar.
    print(cn.execute("""
        SELECT 'gen' AS hoja, count(*) AS codigos,
               count(*) FILTER (WHERE e.cod_equipo IS NULL) AS huerfanos
        FROM (SELECT DISTINCT cod_coes FROM dim.gen) g
        LEFT JOIN dim.equipo e ON e.cod_equipo = g.cod_coes
        UNION ALL
        SELECT 'equivgen', count(*),
               count(*) FILTER (WHERE e.cod_equipo IS NULL)
        FROM (SELECT DISTINCT cod_coes FROM dim.equivgen) g
        LEFT JOIN dim.equipo e ON e.cod_equipo = g.cod_coes
    """).df().to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
