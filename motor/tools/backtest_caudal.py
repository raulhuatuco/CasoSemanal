"""Backtest de la proyeccion de caudal natural a 1-4 semanas.

    python backtest_caudal.py [--desde 2019-01-01] [--csv salida.csv]

Origen cada 7 dias; objetivo el caudal medio de las semanas 1 a 4. La
climatologia excluye siempre el anio evaluado (fuera de muestra).

    persistencia   la ultima semana se repite
    analogo_2020   metodo de CALCULO_DELTAS: ultima semana x factor de 2020
    razon          ultima semana x mediana de los factores de todos los anios
    clima          mediana de los anios en esa semana del calendario
    anomalia       log Q = clima + phi(k) (log Q0 - clima0), por volumen
                   (suma real / suma proyectada); es el de 10_proyeccion.sql
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd

import bd

H = 4


def diario(cn) -> pd.DataFrame:
    d = cn.execute("""
        SELECT equipo, fecha, avg(m3s) AS q FROM crudo.caudal_web
        WHERE tipo_caudal = 'CAUDAL NATURAL ESTIMADO' AND m3s > 0
        GROUP BY ALL""").df()
    d["fecha"] = pd.to_datetime(d["fecha"])
    return d.pivot(index="fecha", columns="equipo", values="q").asfreq("D")


def semanas(q: pd.DataFrame, t0: pd.Timestamp) -> np.ndarray:
    """Medias de la semana que cierra en t0 (k=0) y de las H siguientes."""
    out = []
    for k in range(H + 1):
        a = t0 + pd.Timedelta(days=7 * k - 6)
        b = t0 + pd.Timedelta(days=7 * k)
        w = q.loc[a:b]
        out.append(w.mean().where(w.count() >= 5).values)
    return np.array(out)                       # (H+1, estaciones)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--desde", default="2019-01-01")
    p.add_argument("--csv", default=None)
    p.add_argument("--bd", default=None)
    a = p.parse_args()
    import duckdb
    q = diario(duckdb.connect(str(a.bd or bd.BD_POR_DEFECTO), read_only=True))
    est = list(q.columns)
    anios = sorted(set(q.index.year))
    fin = q.index.max() - pd.Timedelta(days=7 * H)

    # Tabla de semanas por (anio, dia del anio del origen): se reusa en todo.
    origenes = pd.date_range(a.desde, fin, freq="7D")
    cache = {}

    def sem(t0):
        if t0 not in cache:
            cache[t0] = semanas(q, t0)
        return cache[t0]

    def mismo_dia(t0, y):
        try:
            return t0.replace(year=y)
        except ValueError:
            return t0.replace(year=y, day=28)

    filas = []
    for t0 in origenes:
        obs = sem(t0)
        if np.isnan(obs[0]).all():
            continue
        otros = [y for y in anios if y != t0.year]
        hist = np.array([sem(mismo_dia(t0, y)) for y in otros])  # (Y,H+1,E)
        with np.errstate(all="ignore"):
            razones = hist[:, 1:, :] / hist[:, :1, :]
            lh = np.log(hist)
            c = np.nanmean(lh, axis=0)                          # (H+1,E)
        y2020 = sem(mismo_dia(t0, 2020)) if t0.year != 2020 else None
        pred = {
            "persistencia": np.repeat(obs[:1], H, axis=0),
            "razon": obs[0] * np.nanmedian(razones, axis=0),
            "clima": np.exp(np.nanmedian(lh[:, 1:, :], axis=0)),
            "anom_c": (np.log(obs[0]), c),
        }
        if y2020 is not None:
            with np.errstate(all="ignore"):
                pred["analogo_2020"] = obs[0] * (y2020[1:] / y2020[:1])
        for k in range(1, H + 1):
            for j, e in enumerate(est):
                if np.isnan(obs[k, j]) or np.isnan(obs[0, j]):
                    continue
                r = {"origen": t0, "k": k, "estacion": e, "real": obs[k, j],
                     "q0": obs[0, j], "c0": c[0, j], "ck": c[k, j]}
                for m, v in pred.items():
                    if m != "anom_c":
                        r[m] = v[k - 1, j]
                filas.append(r)
    df = pd.DataFrame(filas)

    # phi y sesgo por semana k, ajustados dejando fuera el anio evaluado.
    df["anio"] = df["origen"].dt.year
    df["x"] = np.log(df["q0"]) - df["c0"]
    df["y"] = np.log(df["real"]) - df["ck"]
    df["anomalia"] = np.nan
    for (k, y), g in df.groupby(["k", "anio"]):
        t = df[(df.k == k) & (df.anio != y)].dropna(subset=["x", "y"])
        phi = (t.x * t.y).sum() / (t.x ** 2).sum()
        sesgo = t.real.sum() / np.exp(t.ck + phi * t.x).sum()
        df.loc[g.index, "anomalia"] = np.exp(g.ck + phi * g.x) * sesgo
        df.loc[g.index, "phi"] = phi

    metodos = ["persistencia", "analogo_2020", "razon", "clima", "anomalia"]
    ok = df.dropna(subset=metodos)
    pd.set_option("display.width", 200)
    print(f"{ok.origen.nunique()} origenes, {ok.estacion.nunique()} estaciones,"
          f" {ok.origen.min():%Y-%m} a {ok.origen.max():%Y-%m}")
    print("\nerror del volumen semanal, suma |error| / suma real (%)")
    t = ok.groupby("k").apply(lambda g: pd.Series(
        {m: 100 * (g[m] - g.real).abs().sum() / g.real.sum() for m in metodos}))
    print(t.round(1).to_string())
    print("\nmediana del error relativo por estacion (%)")
    t = ok.groupby("k").apply(lambda g: pd.Series(
        {m: 100 * ((g[m] - g.real).abs() / g.real).median() for m in metodos}))
    print(t.round(1).to_string())
    print("\nsesgo, suma error / suma real (%)")
    t = ok.groupby("k").apply(lambda g: pd.Series(
        {m: 100 * (g[m] - g.real).sum() / g.real.sum() for m in metodos}))
    print(t.round(1).to_string())
    print("\nphi medio por k:", ok.groupby("k").phi.mean().round(3).to_dict())
    if a.csv:
        ok.to_csv(a.csv, index=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
