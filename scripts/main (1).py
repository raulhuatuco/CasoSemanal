import pandas as pd
import numpy as np
import os
from pathlib import Path
from manttos import procesar_manttos_generacion,procesar_manttos_transmision
from formatos import cambiar_formato_diario,cambiar_formato_perfil
from gestion_archivos import copiar_carpeta

#%% user_inputs

'''
Esta línea puede ser reemplazada por cwd = Path(r"ruta de la carpeta Yupana")
si de esa forma le resulta más práctico al usuario
'''

cwd = Path(os.getcwd()).parents[0] #obtiene el directorio de trabajo (.\Yupana)

#%% archivos_y_carpetas

CarpetaDatos    = Path(os.path.join(cwd,"data"))
RutasExcelDatos = [p for p in CarpetaDatos.iterdir() if p.is_file() and p.suffix == ".xlsx" and p.stem != "match_centrales"]
NuevosCasos     = os.path.join(cwd,"nuevos_casos")

#%% nuevos_casos

# Información general para los nuevos escenarios
df_centrales = pd.read_excel(os.path.join(CarpetaDatos,"match_centrales.xlsx"),
                             sheet_name="match_centrales",
                             engine="calamine"
                             )
df_centrales = df_centrales.dropna(subset=['nombre_coes'])

df_lineas = pd.read_excel(os.path.join(CarpetaDatos,"match_centrales.xlsx"),
                          sheet_name="match_lineas",
                          engine="calamine"
                          )
df_lineas = df_lineas.dropna(subset=['nombre_coes_1'])

df_codigos   = pd.read_excel(os.path.join(CarpetaDatos,"match_centrales.xlsx"),
                             sheet_name="codigos_yupana",
                             engine="calamine"
                             )
df_codigos   = df_codigos.set_index(keys="Descripcion equipo")

# Creación de casos
for datos in RutasExcelDatos:
    
    '''
    Se crea una copia de la carpeta del caso base y se le pone el mismo nombre 
    que el archivo excel de datos de modificaciones
    '''
    
    df_data_param =  pd.read_excel(datos,sheet_name = "parametros_ejecucion",
                                   index_col = 0,
                                   usecols   = [0,1],
                                   engine    = "calamine")
    
    YupanaBase = df_data_param.loc["caso_base"].values[0]
    YupanaBase = Path(os.path.join(cwd,"caso_base",YupanaBase))
    
    copiar_carpeta(origen = YupanaBase,
                   destino = NuevosCasos,
                   nuevo_nombre = datos.stem,
                   sobrescribir = True
                   )
    
    YupanaNuevo = Path(os.path.join(NuevosCasos,datos.stem))
    
    '''
    Se modifican las fechas del archivo datosrestricciones.csv para que cuadren
    con el nuevo horizonte de simulación asignado en el archivo excel de datos
    de modificaciones
    '''
    
    escenario_base   = pd.read_csv(os.path.join(YupanaBase,"escenario.csv"),header=None)
    fecha_base       = pd.to_datetime(escenario_base.iloc[0,1])
    nueva_fecha_base = df_data_param.loc["inicio_de_ejecucion"].values[0]
    
    df_DatRes = pd.read_csv(os.path.join(YupanaNuevo,"datosrestricciones.csv"))
    df_DatRes.loc[:,"Fecha:"] = pd.to_datetime(df_DatRes.loc[:,"Fecha:"])-fecha_base+nueva_fecha_base
    
    '''
    Procesa los mantenimientos de generación y convierte su formato al mismo de
    datosrestricciones.csv
    '''
    
    #importación de mantenimientos
    df_mantos =  pd.read_excel(datos,
                               sheet_name='mantenimientos',
                               engine='calamine',
                               skiprows = 5,
                               header = 0
                               )
    
    #eliminación de información innecesaria y conversión de tipo de datos
    df_mantos            = df_mantos.iloc[:,1:]
    df_mantos            = df_mantos[df_mantos['INDISPONIBILIDAD']=='F/S']
    df_mantos            = df_mantos[['UBICACIÓN','EQUIPO','INICIO','FINAL']]
    df_mantos['INICIO']  = pd.to_datetime(df_mantos['INICIO'],dayfirst=True)
    df_mantos['FINAL']   = pd.to_datetime(df_mantos['FINAL'],dayfirst=True)
    
    #procesamiento de mantenimientos
    horizonte = df_data_param.loc["horizonte_dias"].values[0]
    fecha_fin = nueva_fecha_base + pd.Timedelta(days=horizonte-1)
    
    df_mantos_gen = procesar_manttos_generacion(df_mantos,
                                                df_centrales,
                                                fecha_inicio = nueva_fecha_base,
                                                fecha_fin = fecha_fin,
                                                verbose = False
                                                )
    
    #cambio de formato
    df_mantos_gen["inicio"] = df_mantos_gen["inicio"].clip(lower=nueva_fecha_base)
    df_mantos_gen["final"]  = df_mantos_gen["final"].clip(upper=fecha_fin)
    
    df_mantos_gen = pd.concat([df_mantos_gen.reset_index(drop=True),
                               df_codigos.loc[df_mantos_gen.loc[:,"central/modo"]].reset_index(drop=True)
                               ],
                              axis=1
                              )
    
    fechas = pd.date_range(nueva_fecha_base,
                           fecha_fin + pd.Timedelta(days=1),
                           freq="30min",
                           inclusive="left"
                           )
    
    df_mantos_gen_yupana = cambiar_formato_diario(df_datos=df_mantos_gen,
                                                  columna_equipos="central/modo",
                                                  columna_valor="indisponibilidad",
                                                  fechas=fechas 
                                                  )
    
    del df_mantos_gen

    df_mantos_gen_yupana["Restriccion"] = np.where(df_mantos_gen_yupana["Categoria equipo"] == 4,
                                               1,
                                               14
                                               )
    df_mantos_gen_yupana["Desc. Restriccion"] = np.where(df_mantos_gen_yupana["Categoria equipo"] == 4,
                                                         "Mantenimiento Planta Hidro",
                                                         "Mantenimiento Plantas Termicas"
                                                         )

    df_mantos_gen_yupana = df_mantos_gen_yupana.loc[:,df_DatRes.columns]
    df_mantos_gen_yupana = df_mantos_gen_yupana.sort_values(by=["Equipo","Desc. Restriccion"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Mantenimiento Planta Hidro",
                                                      "Mantenimiento Plantas Termicas"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_mantos_gen_yupana,df_DatRes])
    
    del df_mantos_gen_yupana,mask
    
    '''
    Procesa los mantenimientos de transmisión y convierte su formato al mismo de
    datosrestricciones.csv
    '''
    
    #procesamiento de mantenimientos
    df_mantos_trans = procesar_manttos_transmision(df_mantos,
                                                   df_lineas,
                                                   fecha_inicio = nueva_fecha_base,
                                                   fecha_fin = fecha_fin,
                                                   verbose = False
                                                   )
    
    #cambio de formato
    df_mantos_trans["inicio"] = df_mantos_trans["inicio"].clip(lower=nueva_fecha_base)
    df_mantos_trans["final"]  = df_mantos_trans["final"].clip(upper=fecha_fin)
    
    df_mantos_trans = pd.concat([df_mantos_trans.reset_index(drop=True),
                                 df_codigos.loc[df_mantos_trans.loc[:,"equipo"]].reset_index(drop=True)
                                 ],
                                axis=1
                                )
    
    df_mantos_trans_yupana = cambiar_formato_diario(df_datos=df_mantos_trans,
                                                    columna_equipos="equipo",
                                                    columna_valor="indisponibilidad",
                                                    fechas=fechas 
                                                    )
    
    del df_mantos_trans
    
    df_mantos_trans_yupana["Restriccion"] = 28

    df_mantos_trans_yupana["Desc. Restriccion"] = "Mantenimiento en los Circuitos"

    df_mantos_trans_yupana = df_mantos_trans_yupana.loc[:,df_DatRes.columns]
    df_mantos_trans_yupana = df_mantos_trans_yupana.sort_values(by=["Equipo","Desc. Restriccion"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Mantenimiento en los Circuitos"])
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_mantos_trans_yupana,df_DatRes])
    
    del df_mantos_trans_yupana,mask
    
    '''
    Convierte el fomrato de los aportes hidro al mismo de
    datosrestricciones.csv
    '''
    df_aportes =  pd.read_excel(datos,
                                sheet_name='aporte_hidro',
                                engine='calamine',
                                header = 0
                                )
    
    df_aportes = pd.concat([df_aportes.reset_index(drop=True),
                           df_codigos.loc[df_aportes.loc[:,"nombre_yupana"]].reset_index(drop=True)
                           ],
                          axis=1
                          )
    
    df_aportes_yupana = cambiar_formato_diario(df_datos=df_aportes,
                                               columna_equipos="nombre_yupana",
                                               columna_valor="caudal_m3s",
                                               fechas=fechas 
                                               )
    
    del df_aportes
    
    df_aportes_yupana["Restriccion"] = np.where(df_aportes_yupana["Categoria equipo"] == 4,
                                                2,
                                                6
                                                )
    
    df_aportes_yupana["Desc. Restriccion"] = np.where(df_aportes_yupana["Categoria equipo"] == 4,
                                                      "Aportes Planta Hidro",
                                                      "Aportes Embalse"
                                                      )

    df_aportes_yupana = df_aportes_yupana.loc[:,df_DatRes.columns]
    df_aportes_yupana = df_aportes_yupana.sort_values(by=["Equipo","Desc. Restriccion"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Aportes Planta Hidro",
                                                      "Aportes Embalse"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_aportes_yupana,df_DatRes])
    
    del df_aportes_yupana,mask
    
    '''
    Convierte el fomrato de los requerimientos de riego al mismo de
    datosrestricciones.csv
    '''
    df_riego =  pd.read_excel(datos,
                              sheet_name='riego',
                            engine='calamine',
                              header = 0
                              )
    
    df_riego = pd.concat([df_riego.reset_index(drop=True),
                          df_codigos.loc[df_riego.loc[:,"nombre_yupana"]].reset_index(drop=True)
                          ],
                         axis=1
                         )
    
    df_riego_yupana = cambiar_formato_diario(df_datos=df_riego,
                                               columna_equipos="nombre_yupana",
                                               columna_valor="caudal_m3s",
                                               fechas=fechas 
                                               )
    
    del df_riego
    
    df_riego_yupana["Restriccion"] = 12
    
    df_riego_yupana["Desc. Restriccion"] = "Caudal de Riego"

    df_riego_yupana = df_riego_yupana.loc[:,df_DatRes.columns]
    df_riego_yupana = df_riego_yupana.sort_values(by=["Equipo","Desc. Restriccion"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Caudal de Riego"])
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_riego_yupana,df_DatRes])
    
    del df_riego_yupana, mask
    
    '''
    Convierte el fomrato de la defluencia máxima y mínina al mismo de 
    datosrestricciones.csv
    '''
    df_def =  pd.read_excel(datos,
                            sheet_name='defluencia_min_max',
                            engine='calamine',
                            header = 0
                            )
    df_def.columns = list(df_def.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_def = pd.concat([df_def.reset_index(drop=True),
                        df_codigos.loc[df_def.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    dias = pd.date_range(nueva_fecha_base,
                         fecha_fin + pd.Timedelta(days=1),
                         freq="D"
                         )
    
    df_def_yupana = cambiar_formato_perfil(df_datos = df_def,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_def
    
    df_def_yupana["Restriccion"] = np.where(df_def_yupana["tipo"] == "MIN",
                                                10,
                                                11
                                                )
    
    df_def_yupana["Desc. Restriccion"] = np.where(df_def_yupana["tipo"] == "MIN",
                                                  "Defluencia Minima",
                                                  "Defluencia Maxima"
                                                  )

    df_def_yupana = df_def_yupana.loc[:,df_DatRes.columns]
    df_def_yupana = df_def_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Defluencia Minima",
                                                      "Defluencia Maxima"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_def_yupana,df_DatRes])
    
    del df_def_yupana, mask
    
    '''
    Convierte el fomrato del volumen máximo y mínino al mismo de 
    datosrestricciones.csv
    '''
    df_vol =  pd.read_excel(datos,
                            sheet_name='volumen_min_max',
                            engine='calamine',
                            header = 0
                            )
    df_vol.columns = list(df_vol.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_vol = pd.concat([df_vol.reset_index(drop=True),
                        df_codigos.loc[df_vol.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_vol_yupana = cambiar_formato_perfil(df_datos = df_vol,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_vol
    
    df_vol_yupana["Restriccion"] = np.where(df_vol_yupana["tipo"] == "MIN",
                                                7,
                                                8
                                                )
    
    df_vol_yupana["Desc. Restriccion"] = np.where(df_vol_yupana["tipo"] == "MIN",
                                                  "Volumen Minimo",
                                                  "Volumen Maximo"
                                                  )

    df_vol_yupana = df_vol_yupana.loc[:,df_DatRes.columns]
    df_vol_yupana = df_vol_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Volumen Minimo",
                                                      "Volumen Maximo"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_vol_yupana,df_DatRes])
    
    del df_vol_yupana, mask
    
    '''
    Convierte el fomrato del requerimiento de RPF al mismo de 
    datosrestricciones.csv
    '''
    df_rpf =  pd.read_excel(datos,
                            sheet_name='rpf',
                            engine='calamine',
                            header = 0
                            )
    
    df_rpf = pd.concat([df_rpf.reset_index(drop=True),
                        df_codigos.loc[df_rpf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rpf_yupana = cambiar_formato_diario(df_datos=df_rpf,
                                           columna_equipos="nombre_yupana",
                                           columna_valor="porcentaje",
                                           fechas=fechas 
                                           )
    
    del df_rpf
    
    df_rpf_yupana["Restriccion"] = np.where(df_rpf_yupana["Categoria equipo"] == 4,
                                                3,
                                                21
                                                )
    
    df_rpf_yupana["Desc. Restriccion"] = np.where(df_rpf_yupana["Categoria equipo"] == 4,
                                                  "Reserva Primaria Planta Hidro",
                                                  "Reserva Primaria PT"
                                                  )

    df_rpf_yupana = df_rpf_yupana.loc[:,df_DatRes.columns]
    df_rpf_yupana = df_rpf_yupana.sort_values(by=["Equipo","Desc. Restriccion"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Reserva Primaria Planta Hidro",
                                                      "Reserva Primaria PT"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rpf_yupana,df_DatRes])
    
    del df_rpf_yupana,mask

    '''
    Convierte el fomrato del requerimiento de RSF al mismo de 
    datosrestricciones.csv
    '''
    df_rsf =  pd.read_excel(datos,
                            sheet_name='rsf_sein',
                            engine='calamine',
                            header = 0
                            )
    df_rsf.columns = list(df_rsf.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rsf = pd.concat([df_rsf.reset_index(drop=True),
                        df_codigos.loc[df_rsf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rsf_yupana = cambiar_formato_perfil(df_datos = df_rsf,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_rsf
    
    df_rsf_yupana["Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                47,
                                                48
                                                )
    
    df_rsf_yupana["Desc. Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                  "Reserva Up",
                                                  "Reserva Dn"
                                                  )

    df_rsf_yupana = df_rsf_yupana.loc[:,df_DatRes.columns]
    df_rsf_yupana = df_rsf_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Reserva Primaria Planta Hidro",
                                                      "Reserva Primaria PT"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rsf_yupana,df_DatRes])
    
    del df_rsf_yupana, mask
    
    '''
    Convierte el formato del oferta de RSF al mismo de 
    datosrestricciones.csv
    '''
    df_rsf =  pd.read_excel(datos,
                            sheet_name='oferta_rsf',
                            engine='calamine',
                            header = 0
                            )
    
    df_rsf.columns = list(df_rsf.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rsf = pd.concat([df_rsf.reset_index(drop=True),
                        df_codigos.loc[df_rsf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rsf_yupana = cambiar_formato_perfil(df_datos = df_rsf,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_rsf
    
    df_rsf_yupana["Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                45,
                                                46
                                                )
    
    df_rsf_yupana["Desc. Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                  "Resv Sec Urs Tramo1 Up",
                                                  "Resv Sec Urs Tramo1 Dn"
                                                  )

    df_rsf_yupana = df_rsf_yupana.loc[:,df_DatRes.columns]
    df_rsf_yupana = df_rsf_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Resv Sec Urs Tramo1 Up",
                                                      "Resv Sec Urs Tramo1 Dn"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rsf_yupana,df_DatRes])
    
    del df_rsf_yupana, mask

    '''
    Convierte el formato de la oferta mínima de RSF al mismo de 
    datosrestricciones.csv
    '''
    df_rsf =  pd.read_excel(datos,
                            sheet_name='oferta_rsf_min',
                            engine='calamine',
                            header = 0
                            )
    
    df_rsf.columns = list(df_rsf.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rsf = pd.concat([df_rsf.reset_index(drop=True),
                        df_codigos.loc[df_rsf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rsf_yupana = cambiar_formato_perfil(df_datos = df_rsf,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_rsf
    
    df_rsf_yupana["Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                43,
                                                44
                                                )
    
    df_rsf_yupana["Desc. Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                  "Resv Sec Urs Min Up",
                                                  "Resv Sec Urs Min Dn"
                                                  )

    df_rsf_yupana = df_rsf_yupana.loc[:,df_DatRes.columns]
    df_rsf_yupana = df_rsf_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Resv Sec Urs Min Up",
                                                      "Resv Sec Urs Min Dn"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rsf_yupana,df_DatRes])
    
    del df_rsf_yupana, mask
    
    '''
    Convierte el formato del precio de oferta de RSF al mismo de 
    datosrestricciones.csv
    '''
    df_rsf =  pd.read_excel(datos,
                            sheet_name='oferta_rsf_min',
                            engine='calamine',
                            header = 0
                            )
    
    df_rsf.columns = list(df_rsf.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rsf = pd.concat([df_rsf.reset_index(drop=True),
                        df_codigos.loc[df_rsf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rsf_yupana = cambiar_formato_perfil(df_datos = df_rsf,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_rsf
    
    df_rsf_yupana["Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                41,
                                                42
                                                )
    
    df_rsf_yupana["Desc. Restriccion"] = np.where(df_rsf_yupana["tipo"] == "UP",
                                                  "Resv Sec Precio Tramo1 Up",
                                                  "Resv Sec Precio Tramo1 Dn"
                                                  )

    df_rsf_yupana = df_rsf_yupana.loc[:,df_DatRes.columns]
    df_rsf_yupana = df_rsf_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Resv Sec Precio Tramo1 Up",
                                                      "Resv Sec Precio Tramo1 Dn"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rsf_yupana,df_DatRes])
    
    del df_rsf_yupana, mask
    
    '''
    Convierte el formato de la indisponibilidad de RSF al mismo de 
    datosrestricciones.csv
    '''
    df_rsf =  pd.read_excel(datos,
                            sheet_name='indisp_rsf',
                            engine='calamine',
                            header = 0
                            )
    
    df_rsf.columns = list(df_rsf.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rsf = pd.concat([df_rsf.reset_index(drop=True),
                        df_codigos.loc[df_rsf.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rsf_yupana = cambiar_formato_perfil(df_datos = df_rsf,
                                           dias = dias,
                                           incluye_tipo = True
                                           )
    
    del df_rsf
    
    mask_hidro = df_rsf_yupana["Categoria equipo"]==4
    df_rsf_yupana_hidro   = df_rsf_yupana.loc[mask_hidro].copy()
    df_rsf_yupana_termico = df_rsf_yupana.loc[~mask_hidro].copy()
    
    df_rsf_yupana_hidro["Restriccion"] = np.where(df_rsf_yupana_hidro["tipo"] == "UP",
                                                  114,
                                                  115
                                                  )
    
    df_rsf_yupana_hidro["Desc. Restriccion"] = np.where(df_rsf_yupana_hidro["tipo"] == "UP",
                                                        "Indisponibilidad RSF Hidro Up",
                                                        "Indisponibilidad RSF Hidro Dn"
                                                        )
    
    df_rsf_yupana_termico["Restriccion"] = np.where(df_rsf_yupana_termico["tipo"] == "UP",
                                                    116,
                                                    117
                                                    )
    
    df_rsf_yupana_termico["Desc. Restriccion"] = np.where(df_rsf_yupana_termico["tipo"] == "UP",
                                                          "Indisponibilidad RSF Termica Up",
                                                          "Indisponibilidad RSF Termica Dn"
                                                          )
    
    df_rsf_yupana = pd.concat([df_rsf_yupana_hidro,df_rsf_yupana_termico])
    df_rsf_yupana = df_rsf_yupana.loc[:,df_DatRes.columns]
    df_rsf_yupana = df_rsf_yupana.sort_values(by=["Equipo","Desc. Restriccion","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"].isin(["Indisponibilidad RSF Hidro Up",
                                                      "Indisponibilidad RSF Hidro Dn",
                                                      "Indisponibilidad RSF Termica Up",
                                                      "Indisponibilidad RSF Termica Dn"
                                                      ]
                                                     )
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rsf_yupana,df_DatRes])
    
    del df_rsf_yupana, mask, mask_hidro, df_rsf_yupana_hidro, df_rsf_yupana_termico
    
    '''
    Convierte el formato de los perfiles de generación renovables al mismo de 
    datosrestricciones.csv
    '''
    df_rer =  pd.read_excel(datos,
                            sheet_name='perfil_rer',
                            engine='calamine',
                            header = 0
                            )
    
    df_rer.columns = list(df_rer.columns[:-48])+list(df_DatRes.columns[-48:])
    
    df_rer = pd.concat([df_rer.reset_index(drop=True),
                        df_codigos.loc[df_rer.loc[:,"nombre_yupana"]].reset_index(drop=True)
                        ],
                       axis=1
                       )
    
    df_rer_yupana = cambiar_formato_perfil(df_datos=df_rer,
                                           dias = dias,
                                           incluye_tipo = False
                                           )
    
    del df_rer
    
    df_rer_yupana["Restriccion"] = 26
    
    df_rer_yupana["Desc. Restriccion"] = "Generacion RER"

    df_rer_yupana = df_rer_yupana.loc[:,df_DatRes.columns]
    df_rer_yupana = df_rer_yupana.sort_values(by=["Equipo","Fecha:"])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"]=="Generacion RER"
    
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_rer_yupana,df_DatRes])
    
    del df_rer_yupana, mask
    
    '''
    Agrega los precios de combustible a datosrestricciones.csv
    '''
    df_comb =  pd.read_excel(datos,
                             sheet_name='precio_combustible',
                             engine='calamine',
                             header = 0
                             )
    
    df_comb.columns = list(df_comb.columns[:-48])+list(df_DatRes.columns[-48:])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"]=="Costos de Combustibles"
    
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_comb,df_DatRes])
    del df_comb, mask
    
    '''
    Agrega la demanda por barra a datosrestricciones.csv
    '''
    df_dem =  pd.read_excel(datos,
                            sheet_name='demanda',
                            engine='calamine',
                            header = 0
                            )
    
    df_dem.columns = list(df_dem.columns[:-48])+list(df_DatRes.columns[-48:])
    
    mask = df_DatRes.loc[:,"Desc. Restriccion"]=="Demanda en Barra"
    
    df_DatRes = df_DatRes.loc[~mask]
    df_DatRes = pd.concat([df_dem,df_DatRes])
    del df_dem, mask
    
    '''
    Modificación de parámetros y datos de ejecución
    '''
    df_DatRes.to_csv(os.path.join(YupanaNuevo,"datosrestricciones.csv"),index=False)
    
    escenario_nuevo = pd.read_csv(os.path.join(YupanaNuevo,"escenario.csv"),header=None)
    escenario_nuevo.iloc[0,0] = YupanaNuevo.stem
    escenario_nuevo.iloc[0,1] = df_data_param.loc["inicio_de_ejecucion"].values[0]
    escenario_nuevo.iloc[0,2] = df_data_param.loc["horizonte_dias"]
    escenario_nuevo.iloc[0,4] = df_data_param.loc["tipo_escenario"]
    escenario_nuevo.iloc[0,6] = df_data_param.loc["dias"]
    escenario_nuevo.to_csv(os.path.join(YupanaNuevo,"escenario.csv"),
                           index = False,
                           header = False
                           )
    
    detalle_etapa = pd.read_csv(os.path.join(YupanaNuevo,"detalleetapa.csv"),header=None)
    detalle_etapa.iloc[0,2] = df_data_param.loc["horas"]
    detalle_etapa.iloc[0,3] = df_data_param.loc["delta"]
    detalle_etapa.to_csv(os.path.join(YupanaNuevo,"detalleetapa.csv"),
                         index = False,
                         header = False
                         )
    
    del df_DatRes, escenario_nuevo, detalle_etapa, fechas, horizonte, dias
    del df_data_param, escenario_base









