"""Lee un REPORTE DE CAUDALES del COES y lo deja en la base.

    python cargar_caudales.py reporte.xlsx
    python cargar_caudales.py "..\..\CALCULO_DELTAS Junio - julio 2026.xlsx" \
           --hojas ULT_SEM_MAYO_2026,ULT_SEM_MAYO_2020

El reporte viene ancho: fila 8 los codigos de punto, la 9 la empresa, la 10 el
tipo (planta o embalse), la 11 las unidades, y de la 12 en adelante una fila
por media hora con la fecha en la primera columna. Se guarda largo.

La descarga automatica de estos reportes esta pendiente. En el portal del COES
viven en un repositorio de archivos (Operacion/Estudios/Hidrologia) que se
lista con POST a /Portal/browser/busqueda; ese servicio responde 500 a todas
las combinaciones de parametros que se probaron, asi que por ahora los
reportes se bajan a mano.

Por eso este cargador acepta una carpeta: se dejan ahi todos los reportes que
se vayan bajando y entran de una vez. Hace falta historia de verdad para que
la proyeccion de caudales sea una proyeccion y no una persistencia; el control
crudo.control_caudal_sin_factor dice cuanto le falta.
"""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re

import bd

FILA_CODIGO, FILA_EMPRESA, FILA_TIPO, FILA_DATOS = 8, 9, 10, 12


def _fecha_slot(v):
    """Fecha y slot 1..48 desde la marca de tiempo de la primera columna.

    El reporte va a media hora y la marca es el FINAL del intervalo, igual que
    las columnas de datosrestricciones.csv: la primera del dia es 00:30 y la
    ultima cierra a las 24:00. Por eso 00:30 es el slot 1 y no el 2.

    El cierre del dia se escribe de tres maneras segun el reporte: 23:59,
    24:00 o 00:00 del dia siguiente. Redondear los minutos a la media hora mas
    cercana las cubre las tres, y un 0 resultante es el cierre del dia
    anterior, su slot 48.
    """
    if isinstance(v, dt.datetime):
        f, h, m = v.date(), v.hour, v.minute
    else:
        m0 = re.match(r"(\d{2})/(\d{2})/(\d{4})\s+(\d{1,2}):(\d{2})", str(v or ""))
        if not m0:
            return None, None
        d, mo, y, h, m = (int(x) for x in m0.groups())
        f, = (dt.date(y, mo, d),)
    slot = round((h * 60 + m) / 30)
    if slot == 0:
        return f - dt.timedelta(days=1), 48
    return f, slot


def _equipo(v) -> tuple[str, str]:
    """La fila EQUIPO junta tipo y nombre: "Caudal Planta ARCATA".

    Hay tres tipos: Planta, Embalse y Toma.
    """
    s = " ".join(str(v or "").split())
    m = re.match(r"Caudal\s+(Planta|Embalse|Toma)\s*(.*)", s, re.I)
    return (m.group(1).capitalize(), m.group(2).strip()) if m else ("", s)


def leer(ruta: pathlib.Path, hoja: str | None = None):
    import openpyxl
    wb = openpyxl.load_workbook(ruta, read_only=True, data_only=True)
    ws = wb[hoja] if hoja else wb[wb.sheetnames[0]]
    filas = list(ws.iter_rows(values_only=True))
    cod = filas[FILA_CODIGO - 1]
    emp = filas[FILA_EMPRESA - 1]
    tip = filas[FILA_TIPO - 1]
    cols = [(j, int(c)) for j, c in enumerate(cod)
            if isinstance(c, (int, float)) or str(c or "").strip().isdigit()]
    out = []
    for r in filas[FILA_DATOS - 1:]:
        f, s = _fecha_slot(r[0])
        if f is None:
            continue
        for j, c in cols:
            v = r[j] if j < len(r) else None
            if isinstance(v, (int, float)):
                out.append((c, str(emp[j] or "").strip()) + _equipo(tip[j])
                           + (f, s, float(v)))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archivo", help="un .xlsx o una carpeta con varios")
    p.add_argument("--patron", default="*.xls*",
                   help="que archivos tomar, si se paso una carpeta")
    p.add_argument("--hojas", default=None, help="separadas por coma")
    p.add_argument("--bd", default=None)
    a = p.parse_args()
    ruta = pathlib.Path(a.archivo)
    archivos = (sorted(ruta.glob(a.patron)) if ruta.is_dir() else [ruta])
    if not archivos:
        print(f"nada que leer en {ruta} con {a.patron}")
        return 1

    import pandas as pd
    cn = bd.abrir(a.bd)
    cuando = dt.datetime.now()
    total = 0
    for arch in archivos:
      for hoja in (a.hojas.split(",") if a.hojas else [None]):
        # Un reporte ilegible no corta el lote: se avisa y se sigue con el
        # resto, que es lo util cuando entran decenas de archivos.
        try:
            filas = leer(arch, hoja)
        except Exception as e:
            print(f"  {arch.name}: no se pudo leer ({type(e).__name__})")
            continue
        if not filas:
            print(f"  {arch.name}{'#' + hoja if hoja else ''}: sin filas")
            continue
        origen = f"{arch.name}#{hoja}" if hoja else arch.name
        # Un reporte cuyo rango de fechas ya esta cargado desde otro origen
        # casi siempre es una hoja de resultados, no una semana observada: en
        # CALCULO_DELTAS las hojas SEM*_2026 llevan las fechas de la semana de
        # referencia. Cargarlas contaria esa semana varias veces.
        rango = (min(f[4] for f in filas), max(f[4] for f in filas))
        ya = cn.execute("""SELECT origen FROM crudo.caudal
                           WHERE origen <> ? GROUP BY origen
                           HAVING min(fecha) = ? AND max(fecha) = ?
                           LIMIT 1""", [origen, *rango]).fetchone()
        if ya:
            print(f"  {origen}: mismo rango que {ya[0]}; se omite"
                  " (parece una hoja de resultados, no una semana observada)")
            continue
        cn.execute("DELETE FROM crudo.caudal WHERE origen = ?", [origen])
        cn.register("lote", pd.DataFrame(
            [(cuando, origen) + f for f in filas],
            columns=["descarga", "origen", "cod_pto", "empresa", "tipo",
                     "nombre", "fecha", "slot", "m3s"]))
        cn.execute("INSERT INTO crudo.caudal SELECT * FROM lote")
        cn.unregister("lote")
        r = cn.execute("""SELECT count(DISTINCT cod_pto), min(fecha), max(fecha)
                          FROM crudo.caudal WHERE origen = ?""", [origen]).fetchone()
        total += len(filas)
        print(f"  {origen}: {len(filas):>6} filas, {r[0]} puntos, {r[1]} .. {r[2]}")

    r = cn.execute("""SELECT count(*), count(DISTINCT fecha), min(fecha), max(fecha)
                      FROM crudo.caudal""").fetchone()
    print(f"{total} filas nuevas | crudo.caudal: {r[0]:,} filas, "
          f"{r[1]} dias, {r[2]} .. {r[3]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
