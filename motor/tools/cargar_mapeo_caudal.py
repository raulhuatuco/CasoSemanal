"""Carga en la base la tabla equipo de Yupana -> estacion de caudal natural.

    python cargar_mapeo_caudal.py [mapeo_caudal.csv]

La tabla vive en la base (`dim.caudal_estacion`); el CSV es solo la semilla y
el modo de editarla fuera de Excel. Se rechaza la estacion que no exista en
crudo.caudal_web: una estacion mal escrita dejaria al equipo sin proyeccion y
sin aviso.
"""
from __future__ import annotations

import argparse
import csv

import bd



def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("csv", nargs="?", default=str(bd.RAIZ / "mapeo_caudal.csv"))
    p.add_argument("--bd", default=None)
    a = p.parse_args()
    cn = bd.abrir(a.bd)

    validas = {e for (e,) in cn.execute(
        "SELECT DISTINCT equipo FROM crudo.caudal_web "
        "WHERE tipo_caudal = 'CAUDAL NATURAL ESTIMADO'").fetchall()}
    filas, malas = [], []
    with open(a.csv, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            est = (r.get("estacion") or "").strip() or None
            if est and est not in validas:
                malas.append((r["equipo_yupana"], est))
                continue
            reg = (r.get("regulacion") or "").strip() or None
            if reg == "estacional":
                est = None            # lo fija el plan de descargas
            filas.append((int(r["categoria"]), int(r["id_yupana"]),
                          r["equipo_yupana"], est,
                          (r.get("relacion") or "").strip() or None, reg,
                          (r.get("nota") or "").strip() or None))

    cn.execute("DELETE FROM dim.caudal_estacion")
    cn.executemany(
        "INSERT INTO dim.caudal_estacion VALUES (?, ?, ?, ?, ?, ?, ?)", filas)
    con = sum(1 for f in filas if f[3])
    print(f"  dim.caudal_estacion {len(filas)} equipos, {con} con estacion")
    for eq, est in malas:
        print(f"    estacion desconocida  {eq:<22} {est}")
    return 1 if malas else 0


if __name__ == "__main__":
    raise SystemExit(main())
