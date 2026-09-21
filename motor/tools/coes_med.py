"""Descarga mediciones del COES a la base local, sin repetir lo ya traido.

    python coes_med.py 2026-01-01 2026-09-19            # ejecutado
    python coes_med.py 2026-09-20 2026-09-26 --lectcodi 3   # programa semanal

El servicio devuelve una fila por equipo, dia y magnitud, con 48 columnas
h1..h48 (medias horas, h1 = 00:30 ... h48 = 24:00). Aqui se guarda en largo,
que es como lo consume el resto.

Lo ejecutado de un dia pasado ya no cambia, asi que esos dias se saltan si ya
estan en la base: por eso este modulo se puede correr a diario sin costo. Los
programas (lectcodi 3 y 4) si cambian, y se vuelven a pedir siempre.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import urllib.request

import bd

URL = "https://appserver.coes.org.pe/waMediciones/api/Mediciones"

LECTCODI = {6: "ejecutado", 4: "programa diario", 3: "programa semanal"}

TRAMO = 7          # dias por peticion; con mas, la respuesta se vuelve pesada


def _pedir(lectcodi: int, desde: dt.date, hasta: dt.date) -> list[dict]:
    # Ojo: este servicio quiere las fechas en mm/dd/aaaa, al reves que el
    # portal de mantenimientos, que las quiere en dd/mm/aaaa.
    q = (f"{URL}?lectcodi={lectcodi}"
         f"&fechaIni={desde.strftime('%m/%d/%Y')}"
         f"&fechaFin={hasta.strftime('%m/%d/%Y')}")
    pet = urllib.request.Request(q, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(pet, timeout=300) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def _largo(items: list[dict], lectcodi: int, cuando: dt.datetime):
    """Pasa las 48 columnas h1..h48 a una fila por media hora."""
    for it in items:
        fecha = dt.date.fromisoformat(str(it["Medifecha"])[:10])
        cab = (cuando, lectcodi, fecha)
        cod, mag = it.get("CodigoEquipo"), it.get("Tipoinfoabrev")
        for s in range(1, 49):
            v = it.get(f"h{s}")
            if v is None:
                continue
            yield cab + (s, cod, mag, float(v))


def _unidades(items: list[dict]) -> list[tuple]:
    """El catalogo de unidades que venia en la respuesta.

    Los nombres no se guardan en crudo.medicion: viajan aparte a dim.equipo,
    una fila por unidad en vez de una por cada media hora.
    """
    u = {}
    for it in items:
        cod = it.get("CodigoEquipo")
        if cod is not None:
            u[cod] = (cod, it.get("NombreEquipo"), it.get("CodigoUbicacion"),
                      it.get("NombreUbicacion"), it.get("CodigoEmpresa"),
                      it.get("NombreEmpresa"), it.get("TensionEquipo"))
    return list(u.values())


def _tramos(desde: dt.date, hasta: dt.date, faltan: set[dt.date] | None):
    """Parte el rango en tramos, saltando los dias que ya estan."""
    dias = [desde + dt.timedelta(days=i) for i in range((hasta - desde).days + 1)]
    if faltan is not None:
        dias = [d for d in dias if d in faltan]
    for i in range(0, len(dias), TRAMO):
        grupo = dias[i:i + TRAMO]
        yield grupo[0], grupo[-1], grupo


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("inicio", type=dt.date.fromisoformat)
    p.add_argument("fin", type=dt.date.fromisoformat)
    p.add_argument("--lectcodi", type=int, default=6, choices=sorted(LECTCODI))
    p.add_argument("--bd", default=None)
    p.add_argument("--rehacer", action="store_true",
                   help="vuelve a pedir dias que ya estan en la base")
    a = p.parse_args()

    cn = bd.abrir(a.bd)
    cuando = dt.datetime.now()

    # Un programa se rehace siempre: lo que el COES publica hoy para el jueves
    # no es lo que publico ayer. Solo lo ejecutado se puede dar por cerrado.
    rehacer = a.rehacer or a.lectcodi != 6
    faltan = None
    if not rehacer:
        ya = bd.ya_descargado(cn, "medicion", a.lectcodi)
        faltan = {a.inicio + dt.timedelta(days=i)
                  for i in range((a.fin - a.inicio).days + 1)} - ya
        if not faltan:
            print(f"nada que traer: {LECTCODI[a.lectcodi]} ya esta completo")
            print(bd.resumen(cn))
            return 0

    total = 0
    for desde, hasta, dias in _tramos(a.inicio, a.fin, faltan):
        items = _pedir(a.lectcodi, desde, hasta)
        filas = list(_largo(items, a.lectcodi, cuando))
        if rehacer:
            cn.executemany(
                "DELETE FROM crudo.medicion WHERE lectcodi=? AND fecha=?",
                [(a.lectcodi, d) for d in dias])
            cn.executemany(
                "DELETE FROM crudo.descarga WHERE fuente='medicion'"
                " AND clave=? AND fecha=?",
                [(str(a.lectcodi), d) for d in dias])
        # En bloque, no fila por fila: con executemany estas mismas 93 mil
        # filas tardaban 77 s y la descarga solo 4 s.
        import pandas as pd
        lote = pd.DataFrame(filas, columns=[
            "descarga", "lectcodi", "fecha", "slot", "cod_equipo",
            "magnitud", "valor"])
        cn.register("lote", lote)
        cn.execute("INSERT INTO crudo.medicion SELECT * FROM lote")
        cn.unregister("lote")

        # El catalogo se mantiene al dia con lo que acaba de llegar: una
        # unidad nueva entra, y una que cambio de nombre o de empresa se
        # actualiza.
        cn.register("uni", pd.DataFrame(_unidades(items), columns=[
            "cod_equipo", "equipo", "cod_ubicacion", "ubicacion",
            "cod_empresa", "empresa", "tension"]))
        cn.execute("""
            INSERT INTO dim.equipo BY NAME (
                SELECT *, true AS visto_medicion FROM uni)
            ON CONFLICT (cod_equipo) DO UPDATE SET
                equipo = excluded.equipo, ubicacion = excluded.ubicacion,
                cod_ubicacion = excluded.cod_ubicacion,
                cod_empresa = excluded.cod_empresa, empresa = excluded.empresa,
                tension = excluded.tension, visto_medicion = true""")
        cn.unregister("uni")
        bd.anotar(cn, "medicion", a.lectcodi, dias, len(filas))
        total += len(filas)
        print(f"  {desde}..{hasta}  {len(items):>5} series -> {len(filas):>7} filas",
              file=sys.stderr)

    print(f"{total} filas nuevas en crudo.medicion ({LECTCODI[a.lectcodi]})")
    print(bd.resumen(cn))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
