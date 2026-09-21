"""Acceso a la base local. Lo comparten todas las herramientas.

La base vive donde diga --bd (por defecto ..\staging\yupana.duckdb) y se crea
sola la primera vez corriendo sql\00_comun\00_esquema.sql.
"""
from __future__ import annotations

import datetime as dt
import pathlib

RAIZ = pathlib.Path(__file__).resolve().parent.parent
BD_POR_DEFECTO = RAIZ / "staging" / "yupana.duckdb"
ESQUEMA = RAIZ / "sql" / "00_comun" / "00_esquema.sql"


def abrir(ruta: str | pathlib.Path | None = None):
    import duckdb
    p = pathlib.Path(ruta or BD_POR_DEFECTO)
    p.parent.mkdir(parents=True, exist_ok=True)
    cn = duckdb.connect(str(p))
    cn.execute(ESQUEMA.read_text(encoding="utf-8"))
    return cn


# Los CSV del caso base no comparten codificacion: unos vienen en UTF-8 y
# otros en cp1252. Leerlos con la equivocada no falla siempre: a veces solo
# rompe los acentos, y entonces un cruce por nombre falla sin avisar.
CODIFICACIONES = ("utf-8", "cp1252", "latin-1")


def leer_csv(ruta) -> tuple[list, str]:
    import csv
    for cod in CODIFICACIONES:
        try:
            with open(ruta, newline="", encoding=cod) as f:
                return list(csv.reader(f)), cod
        except UnicodeDecodeError:
            continue
    raise UnicodeDecodeError(f"no se pudo leer {ruta}")


def ya_descargado(cn, fuente: str, clave: str) -> set[dt.date]:
    """Dias que ya estan en la base para esa fuente y clave."""
    filas = cn.execute(
        "SELECT DISTINCT fecha FROM crudo.descarga WHERE fuente=? AND clave=?",
        [fuente, str(clave)]).fetchall()
    return {f[0] for f in filas}


def anotar(cn, fuente: str, clave: str, dias, filas: int) -> None:
    cuando = dt.datetime.now()
    cn.executemany(
        "INSERT INTO crudo.descarga VALUES (?,?,?,?,?)",
        [(fuente, str(clave), d, cuando, filas) for d in dias])


def resumen(cn) -> str:
    l = []
    for t in ("crudo.mtto", "crudo.medicion"):
        n = cn.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
        l.append(f"  {t:<16} {n:>10,} filas")
    r = cn.execute("""SELECT fuente, min(fecha), max(fecha), count(DISTINCT fecha)
                      FROM crudo.descarga GROUP BY 1 ORDER BY 1""").fetchall()
    for f, a, b, n in r:
        l.append(f"  {f:<16} {a} .. {b}  ({n} dias)")
    return "\n".join(l)


def compactar(ruta: str | pathlib.Path | None = None) -> None:
    """Reescribe la base en limpio.

    DuckDB no devuelve al disco el espacio de lo que se borra o se reemplaza,
    asi que despues de una carga grande el archivo queda muy por encima de lo
    que ocupan los datos: en una prueba, 412 MB para 32 MB reales.
    """
    import duckdb
    p = pathlib.Path(ruta or BD_POR_DEFECTO)
    tmp = p.with_suffix(".compacta")
    tmp.unlink(missing_ok=True)
    antes = p.stat().st_size
    cn = duckdb.connect()
    cn.execute(f"ATTACH '{p}' AS v (READ_ONLY); ATTACH '{tmp}' AS n")
    cn.execute("COPY FROM DATABASE v TO n")
    cn.close()
    p.with_suffix(".duckdb.wal").unlink(missing_ok=True)
    p.unlink()
    tmp.rename(p)
    print(f"{antes/1e6:.0f} MB -> {p.stat().st_size/1e6:.0f} MB")


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="crea la base y muestra que tiene")
    p.add_argument("--bd", default=None)
    p.add_argument("--compactar", action="store_true")
    a = p.parse_args()
    if a.compactar:
        compactar(a.bd)
    cn = abrir(a.bd)   # despues de compactar, para reponer lo que falte
    print(f"base: {pathlib.Path(a.bd or BD_POR_DEFECTO)}")
    print(resumen(cn))
