import pandas as pd
import numpy as np

def cambiar_formato_diario(df_datos: pd.DataFrame,
                           columna_equipos: str,
                           columna_valor: str,
                           fechas: pd.DatetimeIndex 
                           )->pd.DataFrame:
    
    cols = pd.MultiIndex.from_frame(df_datos[["Equipo",
                                              columna_equipos,
                                              "Categoria equipo",
                                              "Descripcion categoria"
                                              ]
                                              ].drop_duplicates()
                                    )
    
    df_formato_yupana = pd.DataFrame(0.0,
                                    index=fechas,
                                    columns=cols,
                                    dtype = np.float32
                                    )
    
    for _,row in df_datos.iterrows():
        equipo    = row.loc["Equipo"]
        central   = row.loc[columna_equipos]
        categoria = row.loc["Categoria equipo"]
        descrip   = row.loc["Descripcion categoria"]
        inicio    = row.loc["inicio"]
        final     = row.loc["final"]
        valor     = row.loc[columna_valor]
        
        df_formato_yupana.loc[inicio:final,(equipo,central,categoria,descrip)] = np.float32(valor)
    
    df_formato_yupana = df_formato_yupana.unstack().reset_index()
    df_formato_yupana.columns  = ["Equipo",
                                  "Descripcion equipo",
                                  "Categoria equipo",
                                  "Descripcion categoria",
                                  "fecha_hora",
                                  columna_valor
                                 ]
    
    df_formato_yupana["Fecha:"] = df_formato_yupana.fecha_hora.dt.strftime("%d/%m/%Y")
    
    df_formato_yupana["hora"]  = df_formato_yupana.fecha_hora + pd.Timedelta(minutes=30)
    df_formato_yupana["hora"]  = df_formato_yupana.hora.dt.strftime("%H:%M")
    df_formato_yupana.loc[df_formato_yupana["hora"]=="00:00","hora"] = "24:00"
    
    df_formato_yupana = df_formato_yupana.drop("fecha_hora",axis=1)
    df_formato_yupana = df_formato_yupana.pivot(index=["Equipo",
                                                       "Descripcion equipo",
                                                       "Categoria equipo",
                                                       "Descripcion categoria",
                                                       "Fecha:"
                                                       ],
                                                columns="hora",
                                                values=columna_valor
                                                ).reset_index()
    return df_formato_yupana

def cambiar_formato_perfil(df_datos: pd.DataFrame,
                           dias: pd.DatetimeIndex,
                           incluye_tipo : bool = True
                           )->pd.DataFrame:
    
    if incluye_tipo:
        cols = ["Equipo",
                "nombre_yupana",
                "Categoria equipo",
                "Descripcion categoria",
                "tipo"
                ]
    else:
        cols = ["Equipo",
                "nombre_yupana",
                "Categoria equipo",
                "Descripcion categoria"
                ]
        
    unicos = df_datos[cols].drop_duplicates()
    df_base = unicos.assign(key=1)
    df_base = df_base.merge(pd.DataFrame({"fecha": dias, "key": 1}), on="key")
    df_base = df_base.drop(columns="key")
    
    df_tmp = df_base.merge(df_datos, 
                           on=cols,
                           how="left"
                           )
    
    mask = (df_tmp["fecha"] >= df_tmp["inicio"]) & (df_tmp["fecha"] <= df_tmp["final"])
    df_tmp.iloc[df_tmp.index[~mask],9:] = 0
    df_tmp["_flag"] = (df_tmp[df_tmp.columns[9:]] > 0).any(axis=1)
    df_tmp = df_tmp.sort_values("_flag",ascending=False)
    
    df_tmp = df_tmp.drop_duplicates(subset=cols + ["fecha"],
                                    keep = "first"
                                    )
    
    df_tmp = df_tmp.drop(columns=["inicio","final","_flag"])
    cols[1] = "Descripcion equipo"

    df_tmp.columns = cols + ["Fecha:"] + list(df_tmp.columns[-48:])

    return df_tmp

