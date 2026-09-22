"""Descarga caudales del Historico de Hidrologia del COES.

    python coes_caudal.py 2026-09-01 2026-09-07
    python coes_caudal.py 2026-01-01 2026-09-20 --lectura 75
    python coes_caudal.py 2017-01-01 2024-08-31 --tramo 31

    https://www.coes.org.pe/Portal/Operacion/HistoricoHidrologia/Index

SOLO CAUDAL NATURAL, Y A PROPOSITO.
Por defecto se pide unicamente el tipo 8, CAUDAL NATURAL ESTIMADO. Es el que
sirve como aporte en Yupana: llega a la cuenca y no esta afectado por la
operacion. El turbinado, el total y el regulado ya llevan dentro la descarga
del embalse, que es un resultado del despacho del COES, asi que usarlos como
aporte la contaria dos veces. Se pueden pedir otros con --puntos, pero quedan
guardados con su tipo y no se mezclan al agregar.

La pagina responde una tabla transpuesta: las primeras filas describen cada
columna (cuenca, empresa, instalacion, equipo, tipo) y de ahi para abajo va una
fila por hora. Los numeros vienen con coma decimal y los huecos como "--".
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import bd

BASE = "https://www.coes.org.pe/Portal/operacion/HistoricoHidrologia"

# Los "puntos de medicion" son tipos de caudal, no estaciones.
PUNTOS = {1: "TURBINADO", 4: "EVACUADO DESCARGA DE FONDO", 8: "NATURAL ESTIMADO",
          10: "TOTAL", 14: "ECOLOGICO", 16: "REGULADO", 18: "DE RIEGO",
          24: "DE SALIDA UTIL"}
LECTURA = {66: "EJECUTADO TR", 75: "EJECUTADO HISTORICO",
           67: "PROGRAMA DIARIO CP", 68: "PROGRAMA SEMANAL CP"}
UNIDAD_CAUDAL = 11

FILA = re.compile(r"<tr[^>]*>(.*?)</tr>", re.S)
CELDA = re.compile(r"<t[hd][^>]*>(.*?)</t[hd]>", re.S)
TAG = re.compile(r"<[^>]+>")
CABECERAS = ("CUENCA", "EMPRESA", "INSTALACION", "EQUIPO", "TIPO")


def _texto(c: str) -> str:
    return html.unescape(TAG.sub("", c)).replace("\xa0", " ").strip()


def _numero(s: str):
    s = s.strip()
    if not s or s == "--":
        return None
    try:
        return float(s.replace(".", "").replace(",", "."))
    except ValueError:
        return None


def _sesion():
    s = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor())
    s.addheaders = [("User-Agent", "Mozilla/5.0"),
                    ("X-Requested-With", "XMLHttpRequest")]
    s.open(BASE + "/Index", timeout=60).read()
    return s


def _pedir(s, lectura: int, puntos: str, desde: dt.date, hasta: dt.date,
           pagina: int) -> str:
    datos = urllib.parse.urlencode({
        "idsEmpresa": "-1", "idsCuenca": "-1", "idsFamilia": "-1",
        "idLectura": str(lectura), "idsPtoMedicion": puntos,
        "fechaInicial": desde.strftime("%d/%m/%Y"),
        "fechaFinal": hasta.strftime("%d/%m/%Y"),
        "nroPagina": str(pagina),
        "anho": str(desde.year), "anhoInicial": str(desde.year),
        "anhoFinal": str(hasta.year), "semanaIni": "1", "semanaFin": "52",
        "opcion": "1", "rbDetalleRpte": "0", "unidad": str(UNIDAD_CAUDAL),
    }).encode()
    return s.open(BASE + "/lista", data=datos,
                  timeout=300).read().decode("utf-8", "replace")


def _parsear(cuerpo: str, lectura: int, cuando: dt.datetime) -> list[tuple]:
    filas = [[_texto(c) for c in CELDA.findall(f)] for f in FILA.findall(cuerpo)]
    cab = {}
    ancho = 0
    datos = []
    for f in filas:
        if not f:
            continue
        if f[0].upper().split("/")[0].strip() in CABECERAS:
            cab[f[0].upper()] = f[1:]
            ancho = max(ancho, len(f) - 1)
        elif re.match(r"\d{4}-\d{2}-\d{2}\s+\d{2}", f[0]):
            datos.append(f)
    if not cab or not datos:
        return []

    def col(nombre, j):
        v = cab.get(nombre, [])
        return v[j] if j < len(v) else ""

    out = []
    for f in datos:
        fecha = dt.date.fromisoformat(f[0][:10])
        hora = int(f[0][11:13])
        for j in range(ancho):
            v = _numero(f[j + 1]) if j + 1 < len(f) else None
            if v is None:
                continue
            out.append((cuando, lectura, col("TIPO", j), col("CUENCA", j),
                        col("EMPRESA", j), col("INSTALACION", j),
                        col("EQUIPO", j), fecha, hora, v))
    return out


def _tramo(s, lectura, puntos, ini, fin, cuando) -> list[tuple]:
    filas, vistas = [], set()
    # La tabla viene paginada por dias; se avanza hasta que se repite.
    for pagina in range(1, 400):
        try:
            cuerpo = _pedir(s, lectura, puntos, ini, fin, pagina)
        except urllib.error.HTTPError as e:
            # Pasado el final, el portal responde 500 en vez de una tabla
            # vacia. No es un fallo: es como avisa que ya no hay mas.
            if e.code == 500 and filas:
                break
            raise
        firma = hash(cuerpo)
        if firma in vistas:
            break
        vistas.add(firma)
        nuevas = _parsear(cuerpo, lectura, cuando)
        if not nuevas:
            break
        filas += nuevas
    return filas


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("inicio", type=dt.date.fromisoformat)
    p.add_argument("fin", type=dt.date.fromisoformat)
    p.add_argument("--lectura", type=int, default=75, choices=sorted(LECTURA))
    p.add_argument("--puntos", default="8",
                   help="tipos de caudal; 8 es NATURAL ESTIMADO")
    p.add_argument("--tramo", type=int, default=31, help="dias por pedido")
    p.add_argument("--bd", default=None)
    a = p.parse_args()

    if a.puntos != "8":
        print("aviso: se estan pidiendo tipos distintos del natural estimado."
              " Quedan guardados con su tipo; no los agregues juntos.",
              file=sys.stderr)

    s = _sesion()
    cuando = dt.datetime.now()
    filas = []
    # El portal arma el rango completo en cada pagina: un anio entero tarda
    # 2 s por pagina, un mes 0.5 s. Por eso se pide por tramos.
    ini = a.inicio
    while ini <= a.fin:
        fin = min(ini + dt.timedelta(days=a.tramo - 1), a.fin)
        filas += _tramo(s, a.lectura, a.puntos, ini, fin, cuando)
        print(f"  {ini} a {fin}: {len(filas):>8} valores", file=sys.stderr)
        ini = fin + dt.timedelta(days=1)

    if not filas:
        print("sin filas", file=sys.stderr)
        return 1

    import time
    import pandas as pd
    # Varias descargas en paralelo comparten la base: se espera el turno.
    for intento in range(60):
        try:
            cn = bd.abrir(a.bd)
            break
        except Exception as e:
            if "already open" not in str(e) or intento == 59:
                raise
            time.sleep(10)
    cn.execute("DELETE FROM crudo.caudal_web WHERE lectura = ? "
               "AND fecha BETWEEN ? AND ?", [a.lectura, a.inicio, a.fin])
    cn.register("lote", pd.DataFrame(filas, columns=[
        "descarga", "lectura", "tipo_caudal", "cuenca", "empresa",
        "instalacion", "equipo", "fecha", "hora", "m3s"]))
    cn.execute("INSERT INTO crudo.caudal_web SELECT * FROM lote")
    print(cn.execute("""SELECT tipo_caudal, count(DISTINCT equipo) AS puntos,
                               count(*) AS valores,
                               min(fecha) AS desde, max(fecha) AS hasta
                        FROM crudo.caudal_web GROUP BY 1""").df().to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
