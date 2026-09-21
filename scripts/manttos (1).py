import pandas as pd
import numpy as np
from pandas import DataFrame, Timestamp


def buscar_valores(arr_str : np.ndarray,
                   arr_val : np.ndarray, 
                   lista_strings: list
                   )->list:
    
    '''
    busca los strings en el array arr_str y usa la primera ocurrencia para 
    obtener el valor del array arr_val que se encuentra en la misma posición.
    
    la lista devuelta tiene los valores en el mismo orden de la lista de 
    strings buscados.
    '''
    
    resultado = []
    
    for s in lista_strings:
        # encontrar posiciones donde aparece el string
        pos = np.argwhere(arr_str == s)
        
        if pos.size == 0:
            raise ValueError(f"'{s}' no fue encontrado")
        else:
            i, j = pos[0]  # primera ocurrencia
            resultado.append(arr_val[i, j])
    
    return resultado


def procesar_manttos_generacion(df_mantos : DataFrame,
                                df_centrales : DataFrame,
                                fecha_inicio : Timestamp,
                                fecha_fin : Timestamp,
                                verbose : bool = True
                                ) -> DataFrame:
    
    mask_centrales = df_mantos.UBICACIÓN.isin(df_centrales.nombre_coes.unique())
    df_mantos      = df_mantos[mask_centrales]
    
    mask_equipos = df_mantos.EQUIPO.isin(pd.unique(df_centrales.iloc[:,4:12].values.ravel()))
    df_mantos    = df_mantos[mask_equipos]
    
    mask_periodo  = ((df_mantos.FINAL>=fecha_inicio)&(df_mantos.FINAL<=fecha_fin)|
                     (df_mantos.INICIO>=fecha_inicio)&(df_mantos.INICIO<=fecha_fin)
                     )
    
    df_mantos = df_mantos[mask_periodo]
    
    del mask_centrales,mask_equipos,mask_periodo
    
    df_mantos = df_mantos.sort_values(by=["UBICACIÓN","EQUIPO","INICIO"])
    df_mantos = df_mantos.drop_duplicates(ignore_index=True)
    
    df_mantos["prev_fin"] = df_mantos.groupby(["UBICACIÓN", "EQUIPO"])["FINAL"].shift()
    
    df_mantos["nuevo_grupo"] = (((df_mantos["INICIO"]!=df_mantos["prev_fin"])&
                                 (df_mantos["INICIO"]>df_mantos["prev_fin"])
                                 )|
                                (df_mantos["prev_fin"].isna())
                                )
    
    df_mantos["grupo"] = df_mantos.groupby(["UBICACIÓN","EQUIPO"])["nuevo_grupo"].cumsum()
    df_mantos = df_mantos.groupby(["UBICACIÓN","EQUIPO","grupo"]).agg(INICIO=("INICIO","min"),
                                                                      FINAL=("FINAL","max")
                                                                      ).reset_index()
    
    mask_centrales = df_centrales.nombre_coes.isin(df_mantos.UBICACIÓN.unique())
    df_centrales   = df_centrales[mask_centrales]
    df_centrales   = df_centrales.sort_values(by=["tipo_calculo","tipo","nombre_coes"],ignore_index=True)
    
    del mask_centrales
    
    compendio_mantos = []
    
    for central in df_centrales.nombre_coes.unique():
        
        df_mancen    = df_mantos[df_mantos.UBICACIÓN==central]
        df_central   = df_centrales[df_centrales.nombre_coes==central]
        modelación   = df_central.tipo_calculo.iloc[0]
        tipo_central = df_central.tipo.iloc[0]
        
        if verbose:
            print((f'Calculando central {tipo_central}: {central} ({modelación})'))
        
        f_ini = df_mancen.INICIO.min()
        f_fin = df_mancen.FINAL.max()
        
        rango_tiempo = pd.date_range(start=f_ini,
                                     end=f_fin,
                                     freq='h'
                                     )
        
        del f_ini,f_fin
        
        cols = df_central.iloc[:,5:13].dropna(axis=1,how='all').dropna(axis=0,how='any')
        cols = pd.unique(cols.values.ravel())
        
        df_schedule = pd.DataFrame(0.0,columns=cols,index=rango_tiempo)
        
        for _,manto in df_mancen.iterrows():
            equipo = manto.EQUIPO
            f_ini  = manto.INICIO
            f_fin  = manto.FINAL
            df_schedule.loc[f_ini:f_fin,equipo] = 1
        del manto, equipo, f_ini, f_fin
        
        if modelación == "total":
            cols                = df_central.equipo.values
            df_schedule_central = pd.DataFrame(0.0,columns=cols,index=rango_tiempo)
            df_equipos_aux      = df_central.iloc[:,[1]+list(range(5,13))].dropna(axis=1,how="all")
            
            for modo in cols:
                if verbose:
                    print(f"\tSub-central: {modo}")
                    
                unidades = df_equipos_aux[df_equipos_aux.equipo==modo]
                unidades = unidades.iloc[:,1:].dropna(axis=1).values.ravel()
                
                df_schedule_central[modo] = df_schedule.loc[:,unidades].max(axis=1).values
            
            del df_equipos_aux,unidades
                
        elif len(df_schedule.columns)-1==1:
            nombre_yupana = df_central.equipo.values[0]
            
            df_schedule[nombre_yupana] = df_schedule.max(axis=1)
            df_schedule_central      = df_schedule[nombre_yupana].to_frame()
        
        else:
    
            potencias     = buscar_valores(df_central.iloc[:,6:13].to_numpy(),
                                           df_central.iloc[:,13:].to_numpy(),
                                           cols[1:]
                                           )
            nombre_yupana = df_central.equipo.values[0]
            
            df_schedule.iloc[:,1:]       = df_schedule.iloc[:,1:]*potencias/sum(potencias)
            df_schedule["indis_gen_tot"] = df_schedule.iloc[:,1:].sum(axis=1)
            df_schedule[nombre_yupana]     = df_schedule.iloc[:,[0,-1]].max(axis=1)
            df_schedule_central          = df_schedule[nombre_yupana].to_frame()
            
        list_schedule = []
        
        for modo in df_schedule_central.columns:
            df          = df_schedule_central[modo].to_frame()
            df["grupo"] = (df[modo] != df[modo].shift()).cumsum()
            df_agrupado = (df[df[modo] != 0]  # excluir ceros
                           .groupby(["grupo", modo])
                           .agg(hora_inicio=(modo, lambda x: x.index.min()),
                                hora_fin=(modo, lambda x: x.index.max())
                                ).reset_index(drop=True)
                           )
                
            for _,rango in df_agrupado.iterrows():
                ini   = rango.hora_inicio
                fin   = rango.hora_fin
                indis = df.loc[ini,modo]*100
                
                list_schedule.append({"central/modo":modo,
                                      "inicio":ini,
                                      "final":fin,
                                      "indisponibilidad":indis,
                                      "tipo_central":tipo_central
                                      })
                
        compendio_mantos.append(pd.DataFrame(list_schedule))
        
    del df_mancen,df_central,modelación,df_schedule,cols,df_schedule_central
    del potencias,list_schedule,modo,ini,fin,df,df_agrupado,indis,rango
    del rango_tiempo,central,nombre_yupana,tipo_central
    
    return pd.concat(compendio_mantos).reset_index(drop=True)



def procesar_manttos_transmision(df_mantos : DataFrame,
                                 df_centrales : DataFrame,
                                 fecha_inicio : Timestamp,
                                 fecha_fin : Timestamp,
                                 verbose : bool = True
                                 ) -> DataFrame:
    
    mask_equipos = df_mantos.EQUIPO.isin(pd.unique(df_centrales.iloc[:,-2:].values.ravel()))
    df_mantos    = df_mantos[mask_equipos]
    
    mask_periodo  = ((df_mantos.FINAL>=fecha_inicio)&(df_mantos.FINAL<=fecha_fin)|
                     (df_mantos.INICIO>=fecha_inicio)&(df_mantos.INICIO<=fecha_fin)
                     )
    
    df_mantos = df_mantos[mask_periodo]
    
    del mask_equipos,mask_periodo
    
    df_mantos = df_mantos.sort_values(by=["UBICACIÓN","EQUIPO","INICIO"])
    df_mantos = df_mantos.drop_duplicates(ignore_index=True)
    
    df_mantos["prev_fin"] = df_mantos.groupby(["UBICACIÓN", "EQUIPO"])["FINAL"].shift()
    
    df_mantos["nuevo_grupo"] = (((df_mantos["INICIO"]!=df_mantos["prev_fin"])&
                                 (df_mantos["INICIO"]>df_mantos["prev_fin"])
                                 )|
                                (df_mantos["prev_fin"].isna())
                                )
    
    df_mantos["grupo"] = df_mantos.groupby(["UBICACIÓN","EQUIPO"])["nuevo_grupo"].cumsum()
    df_mantos = df_mantos.groupby(["UBICACIÓN","EQUIPO","grupo"]).agg(INICIO=("INICIO","min"),
                                                                      FINAL=("FINAL","max")
                                                                      ).reset_index()
    
    mask_centrales = (df_centrales.nombre_coes_1.isin(df_mantos.EQUIPO.unique()) |
                      df_centrales.nombre_coes_2.isin(df_mantos.EQUIPO.unique())
                      )
    df_centrales   = df_centrales[mask_centrales]
    df_centrales   = df_centrales.sort_values(by=["equipo"],ignore_index=True)
    
    del mask_centrales
    
    compendio_mantos = []
    
    for central in df_centrales.equipo.unique():
        
        df_mancen    = df_mantos[df_mantos.EQUIPO==central]
        df_central   = df_centrales[df_centrales.equipo==central]
        tipo_central = df_central.tipo.iloc[0]
        
        if verbose:
            print((f'Calculando equipo {tipo_central}: {central} ({tipo_central})'))
        
        f_ini = df_mancen.INICIO.min()
        f_fin = df_mancen.FINAL.max()
        
        rango_tiempo = pd.date_range(start=f_ini,
                                     end=f_fin,
                                     freq='h'
                                     )
        
        del f_ini,f_fin
        
        cols = df_central.iloc[:,-2:].dropna(axis=1,how='all').dropna(axis=0,how='any')
        cols = pd.unique(cols.values.ravel())
        
        df_schedule = pd.DataFrame(0.0,columns=cols,index=rango_tiempo)
        
        for _,manto in df_mancen.iterrows():
            equipo = manto.EQUIPO
            f_ini  = manto.INICIO
            f_fin  = manto.FINAL
            df_schedule.loc[f_ini:f_fin,equipo] = 1
        del manto, equipo, f_ini, f_fin
        
        df_schedule[central] = df_schedule.max(axis=1).values
        compendio_mantos.append(df_schedule[central].copy())
    
    df_compendio = pd.concat(compendio_mantos,axis=1)
    df_compendio = df_compendio.fillna(0)
    
    list_schedule = []
    
    for equipo in df_compendio.columns:
        df = df_compendio[equipo].to_frame()
        df["grupo"] = (df[equipo] != df[equipo].shift()).cumsum()
        df_agrupado = (df[df[equipo] != 0]  # excluir ceros
                       .groupby(["grupo", equipo])
                       .agg(hora_inicio=(equipo, lambda x: x.index.min()),
                            hora_fin=(equipo, lambda x: x.index.max())
                            ).reset_index(drop=True)
                       )
        
        for _,rango in df_agrupado.iterrows():
            ini   = rango.hora_inicio
            fin   = rango.hora_fin
            tipo_central = df_centrales.loc[df_centrales.equipo==equipo,"tipo"].values[0]
            
            list_schedule.append({"equipo":equipo,
                                  "inicio":ini,
                                  "final":fin,
                                  "indisponibilidad":1,
                                  "tipo_central":tipo_central
                                  })
    
    df_schedule = pd.DataFrame(list_schedule)
    
    return df_schedule

