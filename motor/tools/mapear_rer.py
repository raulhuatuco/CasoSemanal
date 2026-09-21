"""Empareja las plantas RER de Yupana con las unidades del COES, por nombre.

    python mapear_rer.py                 # propone y escribe el mapeo
    python mapear_rer.py --revisar       # solo muestra que quedaria sin cruzar

No existe ningun archivo que relacione plantanco.csv con los codigos del COES:
el `Id COES` de plantanco no es el EQUICODI (MAJES es 40 ahi y 13402 en
mediciones), y match_centrales.xlsx solo cubre hidro y termo. Asi que se cruza
por nombre normalizado, y lo que no cruza con confianza queda listado para
arreglarlo a mano en mapeo_rer.csv, que manda sobre lo automatico.
"""
from __future__ import annotations

import argparse
import csv
import pathlib
import re
import unicodedata

import bd


def _aski(x) -> str:
    """La consola de Windows no imprime todo lo que llega del COES."""
    return str(x).encode("ascii", "replace").decode("ascii")


MANUAL = bd.RAIZ / "mapeo_rer.csv"

# Prefijos que el COES pone y Yupana no. Se quitan antes de comparar.
RUIDO = re.compile(
    r"\b(C\.?\s?[SEH]\.?|CENTRAL|PARQUE|SOLAR|EOLICA|EOLICO|HIDROELECTRICA"
    r"|TERMOELECTRICA|CSF|CE|CS|20T|SAC|SA)\b|[^A-Z0-9 ]")


def normalizar(s: str) -> str:
    s = unicodedata.normalize("NFD", str(s or "").upper())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = " ".join(RUIDO.sub(" ", s).split())
    for num, letra in (("1", "UNO"), ("2", "DOS"), ("3", "TRES"),
                       ("4", "CUATRO"), ("5", "CINCO")):
        s = re.sub(rf"{letra}", num, s)
    return s


# Marcas que no distinguen una central de otra: designadores de unidad (G2,
# TG1) y las abreviaturas de embalse, que ya vienen en el tipo del punto.
SUFIJO = re.compile(r"^(?:[A-Z]?G\d+|TG\d+|TV\d*|EM|EMB|CH|CT|MCH|PCH)$")


def puntaje(a: str, b: str) -> float:
    """Jaccard: palabras compartidas sobre el total de palabras distintas.

    No sirve dividir entre el nombre mas corto. Con eso "SAN GABAN III" daba
    1.00 contra "SAN GABAN", porque lo contiene entero, y el punto de caudal
    del embalse de San Gaban III terminaba apuntando al embalse de San Gaban.
    Jaccard penaliza las palabras que sobran y los separa: 0.67 contra
    "SAN GABAN" y 1.00 contra "EMB SAN GABAN III", que es el correcto.
    """
    pa = {x for x in a.split() if not SUFIJO.match(x)}
    pb = {x for x in b.split() if not SUFIJO.match(x)}
    if not pa or not pb:
        return 0.0
    return len(pa & pb) / len(pa | pb)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--revisar", action="store_true")
    p.add_argument("--umbral", type=float, default=0.5)
    p.add_argument("--bd", default=None)
    p.add_argument("--caso", default=str(bd.RAIZ.parent / "caso_base" / "YUPANA_SEM2326"))
    a = p.parse_args()

    filas, _ = bd.leer_csv(pathlib.Path(a.caso) / "plantanco.csv")
    yupana = [(int(r[0]), r[1]) for r in filas[1:] if r and r[0].isdigit()]

    cn = bd.abrir(a.bd)
    # Solo unidades que de verdad generan: las que tienen medicion en MW.
    coes = cn.execute("""
        SELECT e.cod_equipo, e.equipo, e.ubicacion
        FROM dim.equipo e
        WHERE e.cod_equipo IN (SELECT DISTINCT cod_equipo FROM crudo.medicion
                               WHERE magnitud = 'MW')""").fetchall()

    manual = {}
    if MANUAL.exists():
        with open(MANUAL, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r.get("cod_equipo", "").strip().isdigit():
                    manual.setdefault(int(r["id_yupana"]), []).append(
                        int(r["cod_equipo"]))

    pares, sin_cruce = [], []
    for idy, nom in yupana:
        if idy in manual:
            pares += [(idy, nom, c, "manual", 1.0) for c in manual[idy]]
            continue
        n = normalizar(nom)
        # Una planta Yupana puede corresponder a varias unidades COES: Punta
        # Lomitas reporta dos bloques. Se toman todas las que empatan arriba.
        cand = [(puntaje(n, normalizar(f"{u} {e}")), c, e, u)
                for c, e, u in coes]
        mejor = max((s for s, *_ in cand), default=0.0)
        if mejor >= a.umbral:
            pares += [(idy, nom, c, e, s) for s, c, e, _ in cand if s == mejor]
        else:
            top = sorted(cand, key=lambda x: -x[0])[:3]
            sin_cruce.append((idy, nom, top))

    # Una unidad del COES que alimenta a dos plantas de Yupana es un error:
    # su generacion se contaria dos veces. Al reves si es valido, porque una
    # planta puede tener varios bloques.
    veces = {}
    for x in pares:
        veces[x[2]] = veces.get(x[2], 0) + 1
    choque = {x[2] for x in pares if veces[x[2]] > 1}
    if choque:
        for c in sorted(choque):
            afectadas = sorted({x[1] for x in pares if x[2] == c})
            print(_aski(f"    colision   {c} alimentaria a {afectadas}"))
        # Las plantas afectadas pierden su cruce y van a revision, con la
        # unidad en disputa como sugerencia para repartirla a mano.
        en_choque = {(x[0], x[1]): x[2] for x in pares if x[2] in choque}
        pares = [x for x in pares if x[2] not in choque]
        sin_cruce += [(idy, nom, [(1.0, c, "en disputa", "")])
                      for (idy, nom), c in sorted(en_choque.items())]

    print(f"  cruzadas {len({p[0] for p in pares})} de {len(yupana)} plantas"
          f"  ({len(pares)} pares)")
    for idy, nom, top in sin_cruce:
        print(_aski(f"    sin cruce  {idy:>3} {nom:<22} mejores: "
                    + ", ".join(f"{e} ({c}, {s:.2f})" for s, c, e, _ in top)))

    if a.revisar:
        return 0

    import pandas as pd
    cn.execute("""CREATE TABLE IF NOT EXISTS dim.rer (
        id_yupana INTEGER, nombre VARCHAR, cod_equipo INTEGER,
        equipo_coes VARCHAR, puntaje DOUBLE)""")
    cn.execute("DELETE FROM dim.rer")
    cn.register("lote", pd.DataFrame(pares, columns=[
        "id_yupana", "nombre", "cod_equipo", "equipo_coes", "puntaje"]))
    cn.execute("INSERT INTO dim.rer SELECT * FROM lote")
    print(f"  dim.rer {len(pares)} filas")

    if sin_cruce and not MANUAL.exists():
        # Se deja la plantilla para completar a mano lo que no cruzo.
        with open(MANUAL, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["id_yupana", "nombre", "cod_equipo",
                        "sugerencia_1", "sugerencia_2", "sugerencia_3"])
            for idy, nom, top in sin_cruce:
                # Se dejan las sugerencias al lado, no en cod_equipo: hay que
                # confirmarlas a mano. Una planta sin cruce simplemente no
                # recibe perfil, que es preferible a recibir el equivocado.
                w.writerow([idy, nom, ""] +
                           [f"{c} {e} ({s:.2f})" for s, c, e, _ in top])
        print(f"  plantilla para revisar: {MANUAL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
