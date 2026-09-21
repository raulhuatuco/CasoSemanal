"""Arma los casos de Yupana: copia el caso base y le mete los datos nuevos.

    python armar_casos.py --inicio 2026-09-20 --dias 7 --casos 4

No toca la red. Lee crudo.hecho_restriccion, que llenaron los modulos, y por
cada caso escribe una carpeta con el caso base modificado en tres archivos:

    datosrestricciones.csv   las restricciones, a 48 medias horas
    escenario.csv            nombre, fecha de inicio, horizonte
    detalleetapa.csv         numero de etapas y paso

Del caso base se conservan todas las restricciones que ningun modulo toca
(demanda, combustibles, reservas...), y se les corren las fechas al horizonte
nuevo. Las que si toca un modulo se reemplazan enteras: mezclarlas con las del
caso base dejaria mantenimientos viejos conviviendo con los nuevos.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import pathlib
import shutil

import bd

# (categoria, restriccion) que cada modulo reemplaza por completo.
REEMPLAZA = {
    "mantenimientos": [(4, 1), (3, 14)],
    "renovables":     [(25, 26)],
    "caudales":       [(4, 2), (19, 6), (19, 10), (19, 11), (19, 12),
                       (19, 7), (19, 8)],
}

CAB_FIJA = ["Equipo", "Descripcion equipo", "Categoria equipo",
            "Descripcion categoria", "Restriccion", "Desc. Restriccion",
            "Fecha:"]
# El slot 1 termina a las 00:30 y el 48 a las 24:00.
CAB_HORA = [f"{(s * 30) // 60:02d}:{(s * 30) % 60:02d}" if s < 48 else "24:00"
            for s in range(1, 49)]


def _leer(ruta: pathlib.Path):
    return bd.leer_csv(ruta)


def _escribir(ruta: pathlib.Path, filas, cod: str) -> None:
    with open(ruta, "w", newline="", encoding=cod) as f:
        csv.writer(f).writerows(filas)


def _descripciones(filas) -> dict:
    """Del caso base salen los textos de cada categoria y restriccion."""
    d = {}
    for r in filas[1:]:
        if len(r) > 6:
            d[(r[2], r[4])] = (r[3], r[5])
    return d


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--inicio", type=dt.date.fromisoformat, required=True)
    p.add_argument("--dias", type=int, default=7)
    p.add_argument("--casos", type=int, default=1)
    p.add_argument("--delta", type=int, default=1, help="paso de etapa, horas")
    p.add_argument("--base", default=str(bd.RAIZ.parent / "caso_base" / "YUPANA_SEM2326"))
    p.add_argument("--salida", default=str(bd.RAIZ.parent / "nuevos_casos"))
    p.add_argument("--prefijo", default="SEM")
    p.add_argument("--bd", default=None)
    a = p.parse_args()

    base = pathlib.Path(a.base)
    salida = pathlib.Path(a.salida)
    cn = bd.abrir(a.bd)

    filas_base, cod_datres = _leer(base / "datosrestricciones.csv")
    desc = _descripciones(filas_base)
    # Fecha de arranque del caso base, para correr las fechas que se conservan.
    fecha_base = min(dt.date.fromisoformat(r[6]) for r in filas_base[1:]
                     if len(r) > 6 and r[6])

    # Solo se descarta del caso base lo que un modulo esta llenando de verdad.
    # Descartar segun la lista fija borraria los caudales y los renovables del
    # caso base mientras esos modulos no estan escritos, y el caso saldria sin
    # ellos y sin avisar.
    activos = {m for (m,) in cn.execute(
        "SELECT DISTINCT modulo FROM crudo.hecho_restriccion").fetchall()}
    reemplazados = {f"{c}|{r}" for m in activos for c, r in REEMPLAZA.get(m, [])}
    inactivos = sorted(set(REEMPLAZA) - activos)
    if inactivos:
        print(f"  aviso: sin datos de {', '.join(inactivos)};"
              " esas restricciones se conservan del caso base")

    for n in range(a.casos):
        ini = a.inicio + dt.timedelta(days=n * a.dias)
        fin = ini + dt.timedelta(days=a.dias - 1)
        iso = ini.isocalendar()
        nombre = f"{a.prefijo}{iso.week:02d}_{iso.year}"
        destino = salida / nombre
        # Se copia encima en vez de borrar y recrear: OneDrive mantiene
        # abiertas carpetas como RESULTADOS y el borrado falla con acceso
        # denegado. Los tres archivos que cambian se reescriben igual.
        shutil.copytree(base, destino, dirs_exist_ok=True)

        nuevas = cn.execute("""
            SELECT equipo, nombre, categoria, restriccion, fecha, slot, valor
            FROM crudo.hecho_restriccion
            WHERE fecha BETWEEN ? AND ? ORDER BY categoria, restriccion, equipo,
                                                fecha, slot""",
                            [ini, fin]).fetchall()

        # Pivot a 48 columnas. Una media hora sin dato queda en 0: en estas
        # restricciones 0 significa "sin restriccion", que es lo correcto.
        pivot: dict = {}
        for eq, nom, cat, res, fecha, slot, valor in nuevas:
            k = (cat, res, eq, nom, fecha)
            pivot.setdefault(k, [0.0] * 48)[slot - 1] = valor

        desplazamiento = (ini - fecha_base).days
        with open(destino / "datosrestricciones.csv", "w", newline="",
                  encoding=cod_datres) as f:
            w = csv.writer(f)
            w.writerow(CAB_FIJA + CAB_HORA)
            # Lo que ningun modulo toca se conserva, con las fechas corridas.
            for r in filas_base[1:]:
                if len(r) < 7 or f"{r[2]}|{r[4]}" in reemplazados:
                    continue
                d = dt.date.fromisoformat(r[6]) + dt.timedelta(days=desplazamiento)
                if ini <= d <= fin:
                    w.writerow(r[:6] + [d.isoformat()] + r[7:])
            for (cat, res, eq, nom, fecha), vals in sorted(pivot.items()):
                dcat, dres = desc.get((str(cat), str(res)), ("", ""))
                w.writerow([eq, nom, cat, dcat, res, dres, fecha.isoformat()]
                           + [round(v, 4) for v in vals])

        esc, cod = _leer(destino / "escenario.csv")
        esc[0][0], esc[0][1] = nombre, ini.isoformat()
        esc[0][2] = esc[0][6] = str(a.dias)
        _escribir(destino / "escenario.csv", esc, cod)

        det, cod = _leer(destino / "detalleetapa.csv")
        det[0][2] = str(a.dias * 24 // a.delta)
        det[0][3] = str(a.delta)
        _escribir(destino / "detalleetapa.csv", det, cod)

        print(f"  {nombre}  {ini}..{fin}  {len(pivot)} filas nuevas -> {destino}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
