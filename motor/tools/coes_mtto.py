"""Descarga los mantenimientos del COES y los deja en parquet, deduplicados.

    python coes_mtto.py 2026-09-20 2026-12-19 --salida ..\staging\mtto.parquet

Usa el mismo "Exportar Reporte" del portal que se baja a mano, que entrega las
16 columnas completas (TIPO EMPRESA, INDISPONIBILIDAD 'F/S' / 'E/S', PROG
'PROGRAMADO' / 'REPROGRAMADO' / 'FORZADO'), no la lista HTML, que las abrevia
a 'F', 'E', 'P' y ademas no trae TIPO EMPRESA.

Son dos pasos sobre la misma sesion:
    POST eventos/mantenimiento/GenerarArchivoReporte  -> devuelve 1
    GET  eventos/mantenimiento/ExportarReporte?tipo=0 -> devuelve el .xlsx

DOS TRAMPAS DEL PORTAL, DE AHI LA FORMA DE ESTE MODULO:
  * La columna MANTENIMIENTO no describe cada fila: el portal la estampa con
    el tipo que se pidio. Pedir "1,2,3,4" de una vez etiqueta TODO como
    EJECUTADOS y ademas no devuelve la union. Por eso se baja un tipo por
    llamada y se etiqueta con lo que se pidio.
  * El rango maximo por consulta es de 3 meses (el propio portal lo valida),
    asi que un horizonte largo se parte en tramos.

PROGRAMADO ANUAL no existe en el export: el selector solo ofrece los cuatro
tipos de abajo. Si se necesita, esta unicamente en la lista HTML.
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.cookiejar
import io
import sys
import urllib.parse
import urllib.request

BASE = "https://www.coes.org.pe/Portal/eventos/mantenimiento"

# id del portal -> (etiqueta, prelacion). Mayor prelacion = mas vigente.
TIPOS = {
    1: ("EJECUTADOS", 5),
    2: ("PROGRAMADO DIARIO", 4),
    3: ("PROGRAMADO SEMANAL", 3),
    4: ("PROGRAMADO MENSUAL", 2),
}

COLUMNAS = ["mantenimiento", "tipo_empresa", "empresa", "ubicacion",
            "tipo_equipo", "equipo", "inicio", "final", "descripcion", "prog",
            "interrupcion", "indisponibilidad", "tension", "tipo_mantto",
            "cod_eq", "tipo_eq_osinerg"]

MAX_DIAS = 90


def _sesion():
    tarro = http.cookiejar.CookieJar()
    s = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(tarro))
    s.addheaders = [("User-Agent", "Mozilla/5.0"),
                    ("X-Requested-With", "XMLHttpRequest")]
    s.open(BASE, timeout=60).read()          # abre sesion y toma la cookie
    return s


def _exportar(s, tipo: int, desde: dt.date, hasta: dt.date) -> bytes:
    datos = urllib.parse.urlencode({
        "tiposMantenimiento": str(tipo),
        "fechaInicial": desde.strftime("%d/%m/%Y"),
        "fechaFinal": hasta.strftime("%d/%m/%Y"),
        "indispo": "-1", "tiposEmpresa": "-1", "empresas": "-1",
        "tiposEquipo": "-1", "interrupcion": "-1", "tiposMantto": "-1",
    }).encode()
    # Sin filas que reportar el portal responde "-1" en vez de "1". No es un
    # fallo: un tramo futuro no tiene EJECUTADOS, y es normal.
    if s.open(BASE + "/GenerarArchivoReporte", data=datos,
              timeout=300).read().strip() != b"1":
        return b""
    return s.open(BASE + "/ExportarReporte?tipo=0", timeout=300).read()


def _filas(xlsx: bytes, etiqueta: str, prelacion: int) -> list[tuple]:
    if not xlsx:
        return []
    import openpyxl
    ws = openpyxl.load_workbook(io.BytesIO(xlsx), read_only=True).active
    ini = None
    filas = []
    for fila in ws.iter_rows(values_only=True):
        if ini is None:
            # La cabecera no esta en la fila 1: el reporte lleva titulo y
            # fechas encima, y una columna en blanco a la izquierda.
            for j, v in enumerate(fila):
                if str(v or "").strip().upper() == "MANTENIMIENTO":
                    ini = j
                    break
            continue
        c = list(fila[ini:ini + len(COLUMNAS)])
        c += [None] * (len(COLUMNAS) - len(c))
        if not c[5] or not c[6]:                      # sin equipo o sin inicio
            continue
        c[0] = etiqueta                               # el portal la estampa mal
        filas.append(tuple(str(v).strip() if v is not None else "" for v in c)
                     + (prelacion,))
    return filas


def _tramos(desde: dt.date, hasta: dt.date):
    a = desde
    while a <= hasta:
        b = min(a + dt.timedelta(days=MAX_DIAS - 1), hasta)
        yield a, b
        a = b + dt.timedelta(days=1)


def descargar(desde: dt.date, hasta: dt.date, tipos: list[int]) -> list[tuple]:
    s = _sesion()
    filas = []
    for a, b in _tramos(desde, hasta):
        for t in tipos:
            etiqueta, prelacion = TIPOS[t]
            nuevas = _filas(_exportar(s, t, a, b), etiqueta, prelacion)
            filas += nuevas
            print(f"  {a}..{b}  {etiqueta:<20} {len(nuevas):>6}",
                  file=sys.stderr)
    return filas


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("inicio", type=dt.date.fromisoformat)
    p.add_argument("fin", type=dt.date.fromisoformat)
    p.add_argument("--bd", default=None)
    p.add_argument("--tipos", default="1,2,3,4",
                   help="ids del portal: 1 EJ, 2 PD, 3 PS, 4 PM")
    p.add_argument("--parquet", default=None,
                   help="ademas, vuelca lo traido a un parquet suelto")
    a = p.parse_args()

    filas = descargar(a.inicio, a.fin, [int(x) for x in a.tipos.split(",")])
    if not filas:
        print("sin filas", file=sys.stderr)
        return 1

    import bd
    cn = bd.abrir(a.bd)
    cuando = dt.datetime.now()

    # Se carga tal cual a una tabla de paso, se limpia ahi y recien entra a
    # crudo.mtto. Asi el parseo de fechas falla en la tabla de paso y no deja
    # a medias la tabla buena.
    # En bloque, no fila por fila: fila por fila es unas 250 veces mas lento.
    import pandas as pd
    cn.register("lote", pd.DataFrame(filas, columns=COLUMNAS + ["prelacion"]))
    cn.execute("CREATE OR REPLACE TEMP TABLE paso AS SELECT * FROM lote")
    cn.unregister("lote")

    # Los mantenimientos futuros cambian todos los dias, asi que cada corrida
    # agrega una descarga nueva en vez de pisar la anterior: el historico es
    # justamente lo que deja reconstruir un caso viejo.
    n = cn.execute(f"""
        INSERT INTO crudo.mtto
        SELECT TIMESTAMP '{cuando:%Y-%m-%d %H:%M:%S}', mantenimiento, prelacion,
               tipo_empresa, empresa, ubicacion, tipo_equipo, equipo,
               try_strptime(inicio, ['%d/%m/%Y %H:%M', '%d/%m/%Y %H:%M:%S',
                                     '%Y-%m-%d %H:%M:%S']),
               try_strptime(final,  ['%d/%m/%Y %H:%M', '%d/%m/%Y %H:%M:%S',
                                     '%Y-%m-%d %H:%M:%S']),
               descripcion, prog, interrupcion, indisponibilidad, tension,
               tipo_mantto, try_cast(cod_eq AS INTEGER), tipo_eq_osinerg
        FROM paso
        -- Una fila sin fechas legibles viene rota: se descarta aqui y no se
        -- arrastra en silencio hasta el caso.
        WHERE try_strptime(inicio, ['%d/%m/%Y %H:%M', '%d/%m/%Y %H:%M:%S',
                                    '%Y-%m-%d %H:%M:%S']) IS NOT NULL
        -- La fuente repite el mismo evento muchas veces dentro de un mismo
        -- programa. Se queda una sola copia. El duplicado ENTRE programas no
        -- se toca: eso lo resuelve la prelacion, en 30_prelacion.sql.
        QUALIFY row_number() OVER (
            PARTITION BY mantenimiento, cod_eq, equipo, ubicacion,
                         inicio, final, indisponibilidad, prog
            ORDER BY descripcion) = 1
    """).fetchone()[0]

    dias = [a.inicio + dt.timedelta(days=i)
            for i in range((a.fin - a.inicio).days + 1)]
    for t in (int(x) for x in a.tipos.split(",")):
        bd.anotar(cn, "mtto", TIPOS[t][0], dias, n)

    if a.parquet:
        cn.execute(f"COPY (SELECT * FROM crudo.mtto WHERE descarga = TIMESTAMP"
                   f" '{cuando:%Y-%m-%d %H:%M:%S}') TO '{a.parquet}' (FORMAT parquet)")

    print(f"{len(filas)} filas crudas -> {n} unicas -> crudo.mtto")
    print(bd.resumen(cn))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
