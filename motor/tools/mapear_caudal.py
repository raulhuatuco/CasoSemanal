"""Empareja los puntos de caudal del COES con plantah.csv y embalse.csv.

    python mapear_caudal.py [--revisar]

El `CODIGO PTO` del reporte de caudales (59800 y siguientes) es una numeracion
propia de hidrologia: no es el EQUICODI de dim.equipo ni el `Id COES` de las
tablas de Yupana. Lo unico comun es el nombre, asi que se cruza por ahi y lo
que no cruce con confianza queda en mapeo_caudal.csv para completar a mano.

El tipo del punto decide contra que tabla se cruza y que restriccion alimenta:

    Caudal Planta    plantah.csv   categoria  4, restriccion  2  Aportes Planta
    Caudal Embalse   embalse.csv   categoria 19, restriccion  6  Aportes Embalse
    Caudal Toma      sin destino claro; se deja sin cruzar
"""
from __future__ import annotations

import argparse
import csv
import pathlib

import bd
from mapear_rer import _aski, normalizar, puntaje

MANUAL = bd.RAIZ / "mapeo_caudal.csv"
DESTINO = {"Planta": ("plantah.csv", 4, 2), "Embalse": ("embalse.csv", 19, 6)}


def _tabla(caso: pathlib.Path, archivo: str):
    filas, _ = bd.leer_csv(caso / archivo)
    return [(int(r[0]), r[1]) for r in filas[1:] if r and r[0].isdigit()]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--revisar", action="store_true")
    p.add_argument("--umbral", type=float, default=0.75)
    p.add_argument("--bd", default=None)
    p.add_argument("--caso", default=str(bd.RAIZ.parent / "caso_base" / "YUPANA_SEM2326"))
    a = p.parse_args()
    caso = pathlib.Path(a.caso)
    cn = bd.abrir(a.bd)

    manual = {}
    if MANUAL.exists():
        with open(MANUAL, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r.get("id_yupana", "").strip().isdigit():
                    manual[(r["fuente"], r["clave"])] = int(r["id_yupana"])

    puntos = cn.execute("""
        SELECT 'reporte' AS fuente, cod_pto::VARCHAR AS clave, tipo, nombre
        FROM crudo.caudal
        UNION
        -- Del lado web, EMB es embalse y lo demas es planta.
        -- Sin tipo: una estacion de caudal natural puede alimentar una
        -- planta o un embalse, y el campo INSTALACION no lo dice (SHEQUE y
        -- SAN DIEGO llegan como ESTACION y en Yupana son embalses). Se busca
        -- en las dos tablas y manda el nombre.
        SELECT 'web', equipo, NULL, equipo
        FROM crudo.caudal_web
        WHERE tipo_caudal = 'CAUDAL NATURAL ESTIMADO'
        ORDER BY 1, 3, 4""").fetchall()
    pares, sin_cruce = [], []
    for fuente, cod, tipo, nombre in puntos:
        # Con tipo conocido se busca solo en su tabla; sin tipo, en las dos.
        tablas = [DESTINO[tipo]] if tipo in DESTINO else list(DESTINO.values())
        if tipo is None:
            pass
        elif tipo not in DESTINO:
            sin_cruce.append((fuente, cod, tipo, nombre, []))
            continue
        cand = [(puntaje(normalizar(nombre), normalizar(eq)), idy, eq, cat, res)
                for archivo, cat, res in tablas
                for idy, eq in _tabla(caso, archivo)]
        if (fuente, cod) in manual:
            idy = manual[(fuente, cod)]
            m = next(((e, c, r) for s, i, e, c, r in cand if i == idy), ("", 0, 0))
            pares.append((fuente, cod, tipo, nombre, idy, *m, 1.0))
            continue
        s, idy, eq, cat, res = max(cand, default=(0.0, None, "", 0, 0))
        if s >= a.umbral:
            pares.append((fuente, cod, tipo, nombre, idy, eq, cat, res, s))
        else:
            sin_cruce.append((fuente, cod, tipo, nombre,
                              sorted(cand, key=lambda x: -x[0])[:3]))

    # Dos puntos que caen en el mismo equipo de Yupana son siempre un error:
    # habria que sumarlos, no reemplazar uno con otro. Van los dos a revision.
    veces = {}
    for x in pares:
        veces[(x[0], x[6], x[4])] = veces.get((x[0], x[6], x[4]), 0) + 1
    choque = [x for x in pares if veces[(x[0], x[6], x[4])] > 1]
    if choque:
        pares = [x for x in pares if veces[(x[0], x[6], x[4])] == 1]
        for x in choque:
            sin_cruce.append((x[0], x[1], x[2], x[3], []))
            print(_aski(f"    colision   {x[0]}/{x[3]} y otro punto apuntan"
                        f" al mismo {x[5]} ({x[4]})"))

    print(f"  cruzados {len(pares)} de {len(puntos)} puntos")
    for fuente, cod, tipo, nombre, top in sin_cruce:
        t = tipo or "-"
        print(_aski(f"    sin cruce  {fuente:<8} {t:<8} {nombre:<24} "
                    + ", ".join(f"{e} ({i}, {s:.2f})" for s, i, e, *_ in top)))
    if a.revisar:
        return 0

    import pandas as pd
    cn.execute("DROP TABLE IF EXISTS dim.caudal_pto")
    cn.execute("""CREATE TABLE dim.caudal_pto (
        fuente VARCHAR, clave VARCHAR, tipo VARCHAR, nombre VARCHAR,
        id_yupana INTEGER, equipo_yupana VARCHAR, categoria INTEGER,
        restriccion INTEGER, puntaje DOUBLE)""")
    cn.register("lote", pd.DataFrame(pares, columns=[
        "fuente", "clave", "tipo", "nombre", "id_yupana", "equipo_yupana",
        "categoria", "restriccion", "puntaje"]))
    cn.execute("INSERT INTO dim.caudal_pto SELECT * FROM lote")
    print(f"  dim.caudal_pto {len(pares)} filas")

    if sin_cruce and not MANUAL.exists():
        with open(MANUAL, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["fuente", "clave", "tipo", "nombre", "id_yupana",
                        "sugerencia_1", "sugerencia_2", "sugerencia_3"])
            for fuente, cod, tipo, nombre, top in sin_cruce:
                w.writerow([fuente, cod, tipo, nombre, ""] +
                           [f"{i} {e} ({s:.2f})" for s, i, e, *_ in top])
        print(f"  plantilla para revisar: {MANUAL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
