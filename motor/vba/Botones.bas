Attribute VB_Name = "Botones"
'===============================================================================
' Botones.bas - los dos botones de un libro de tema
'===============================================================================
' Un libro por tema (mantenimientos, renovables, caudales). Los tres llevan
' este mismo modulo; lo que cambia de uno a otro es la hoja Params.
'
'   1 ActualizarDatos   Revisa que la base cubra el horizonte de Params. Si le
'                       faltan dias, o la descarga mas nueva pasa de la edad
'                       permitida, corre el comando de descarga de esa fuente y
'                       vuelve a revisar. Despues trae a la vista lo que dice
'                       [DATOS]. No corre ningun .sql: solo mira y descarga.
'
'   2 Procesar          Corre los .sql de [EJECUCION] sobre el mismo horizonte
'                       y vuelca [SALIDAS]. No toca la red. Antes de empezar
'                       repite la revision del boton 1 y avisa si la base esta
'                       vieja, pero deja seguir: a veces se procesa a proposito
'                       con lo que ya hay.
'
' LA HOJA Params LA ESCRIBE QUIEN OPERA; ESTE MODULO SOLO LA LEE.
'   [CARPETAS]  raiz (solo si Excel abre el libro por una URL de OneDrive),
'               carpeta_scripts, carpeta_datos. Relativas a la raiz.
'   [HORIZONTE] inicio, dias, dias_atras -> fecha_ini y fecha_fin, que se
'               mandan como variables a los .sql y como {INICIO} {FIN} a los
'               comandos. Es el unico sitio donde se dice que tramo se usa.
'   [FUENTE]    una fila por fuente que hay que tener al dia: el nombre con el
'               que esa fuente se registra en crudo.descarga, el comando que la
'               baja, y cuantas horas puede tener la descarga mas nueva antes
'               de considerarla vieja. El boton escribe el estado en las dos
'               columnas de la derecha.
'   [EJECUCION] base (el .duckdb) y script, el del modulo. Uno: los pasos y su
'               orden los declara ese .sql con sus lineas -- #incluir, que este
'               modulo resuelve antes de mandarlo. Params dice que se corre, no
'               en cuantos pedazos esta escrito.
'   [VARIABLES] clave | valor | tipo -> SET VARIABLE antes de los scripts.
'   [HOJAS]     hoja | vista | boton: que deja a la vista cada boton.
' Cada bloque empieza en su marca en la columna A y acaba en la primera fila
' con la columna A vacia. Se salta la fila de encabezado y las que empiezan
' por |.
'
' POR QUE DOS BOTONES Y NO UNO. Descargar toca la red y tarda; procesar no.
' Separarlos deja iterar el SQL sin volver a bajar nada, y deja armar un caso
' sin conexion. Es la misma division que en la linea de comandos: refrescar
' por un lado, armar por el otro.
'
' LA CONEXION SE CIERRA ANTES DE DESCARGAR. DuckDB admite un solo escritor: si
' Excel tiene la base abierta, el python de la descarga no puede escribir. Por
' eso la revision abre, lee y cierra, y recien entonces corre el comando.
'
' REQUISITO: el driver ODBC de DuckDB de la misma arquitectura que este Excel.
'===============================================================================
Option Explicit

Private Const HOJA_CFG As String = "Params"
Private Const DRIVER_ODBC As String = "DuckDB Driver"
Private Const TIEMPO_MAX As Long = 900          ' segundos por sentencia
Private Const SIN_DESCARGA As Double = 1000000000#


'===============================================================================
' BOTON 1
'===============================================================================
Public Sub ActualizarDatos()
    Dim ws As Worksheet, cn As Object
    Dim ini As Date, fin As Date
    Dim fuentes As Variant, i As Long
    Dim fuente As String, comando As String, horas As Double
    Dim faltan As Long, edad As Double, ultima As String
    Dim resumen As String, filas As Long

    Set ws = HojaCfg("Actualizar datos")
    If ws Is Nothing Then Exit Sub
    If Not Horizonte(ws, ini, fin) Then Exit Sub

    fuentes = Bloque(ws, "[FUENTE]")
    If IsEmpty(fuentes) Then
        Avisar "El bloque [FUENTE] de Params no tiene ninguna fila.", _
               vbExclamation, "Actualizar datos"
        Exit Sub
    End If

    Application.Cursor = xlWait
    On Error GoTo Fallo

    For i = LBound(fuentes, 1) To UBound(fuentes, 1)
        fuente = Trim$(CStr(fuentes(i, 1)))
        If Len(fuente) > 0 And Left$(fuente, 1) <> "|" Then
            comando = Trim$(CStr(fuentes(i, 2)))
            horas = Numero(CStr(fuentes(i, 3)))

            Revisar ws, fuente, ini, fin, faltan, edad, ultima
            If faltan = 0 And Not EsVieja(edad, horas) Then
                Marcar ws, i, Estado(faltan, edad, horas), ultima
                resumen = resumen & Linea(fuente, faltan, edad, "al dia")
            ElseIf Len(comando) = 0 Then
                Marcar ws, i, "sin comando", ultima
                resumen = resumen & Linea(fuente, faltan, edad, "hay que bajarla a mano")
            Else
                Marcar ws, i, "descargando...", ultima
                DoEvents
                Ejecutar Sustituir(comando, ini, fin)
                Revisar ws, fuente, ini, fin, faltan, edad, ultima
                Marcar ws, i, Estado(faltan, edad, horas), ultima
                resumen = resumen & Linea(fuente, faltan, edad, "descargada")
            End If
        End If
    Next i

    ' Las vistas del boton 1 tambien reciben fecha_ini y fecha_fin: asi el
    ' horizonte se escribe una sola vez, en Params, y no dentro de cada una.
    Set cn = AbrirDuckDB(Base(ws))
    cn.Execute Prologo(ws, ini, fin)
    filas = VolcarBloque(ws, cn, 1)
    cn.Close
    Set cn = Nothing

    Application.Cursor = xlDefault
    Avisar "Horizonte " & Format(ini, "yyyy-mm-dd") & " a " & Format(fin, "yyyy-mm-dd") & _
           vbLf & vbLf & resumen & vbLf & _
           filas & " filas a la vista.", vbInformation, "Actualizar datos"
    Exit Sub

Fallo:
    Application.Cursor = xlDefault
    Cerrar cn
    Avisar "No se pudo actualizar:" & vbLf & vbLf & Err.Description, _
           vbCritical, "Actualizar datos"
End Sub


'===============================================================================
' BOTON 2
'===============================================================================
Public Sub Procesar()
    Dim ws As Worksheet, cn As Object
    Dim ini As Date, fin As Date
    Dim i As Long, ruta As String
    Dim fuentes As Variant, faltan As Long, edad As Double, ultima As String
    Dim viejo As String, fuente As String, horas As Double
    Dim t0 As Single, filas As Long, n As Long

    Set ws = HojaCfg("Procesar")
    If ws Is Nothing Then Exit Sub
    If Not Horizonte(ws, ini, fin) Then Exit Sub

    ' Avisa, pero no obliga: procesar con lo que hay es una decision valida.
    fuentes = Bloque(ws, "[FUENTE]")
    If Not IsEmpty(fuentes) Then
        For i = LBound(fuentes, 1) To UBound(fuentes, 1)
            fuente = Trim$(CStr(fuentes(i, 1)))
            If Len(fuente) > 0 And Left$(fuente, 1) <> "|" Then
                horas = Numero(CStr(fuentes(i, 3)))
                Revisar ws, fuente, ini, fin, faltan, edad, ultima
                If faltan > 0 Or EsVieja(edad, horas) Then
                    viejo = viejo & Linea(fuente, faltan, edad, "")
                End If
            End If
        Next i
        If Len(viejo) > 0 Then
            If Not Preguntar("La base no esta al dia:" & vbLf & vbLf & viejo & vbLf & _
                             "Procesar igual con lo que hay?", _
                             vbYesNo + vbQuestion, "Procesar") Then Exit Sub
        End If
    End If

    ruta = Absoluta(Valor(ws, "[EJECUCION]", "script"), Carpeta(ws, "carpeta_scripts"))
    If Len(ruta) = 0 Or Dir(ruta) = "" Then
        Avisar "El bloque [EJECUCION] de Params tiene que decir que script del " & _
               "modulo se corre." & vbLf & ruta, vbExclamation, "Procesar"
        Exit Sub
    End If

    Application.ScreenUpdating = False
    Application.Cursor = xlWait
    t0 = Timer
    On Error GoTo Fallo

    Application.StatusBar = "Procesando " & Dir(ruta) & "..."
    Set cn = AbrirDuckDB(Base(ws))
    cn.Execute Prologo(ws, ini, fin)
    cn.Execute Expandir(ruta, Carpeta(ws, "carpeta_scripts"), n)

    filas = VolcarBloque(ws, cn, 2)
    cn.Close
    Set cn = Nothing

    Application.StatusBar = False
    Application.ScreenUpdating = True
    Application.Cursor = xlDefault
    Avisar "Listo en " & Format(Timer - t0, "0.0") & " s (" & n & " pasos)." & vbLf & _
           filas & " filas a la vista." & vbLf & vbLf & _
           "Mira la hoja de control: ninguna fila tiene que decir FALLA.", _
           vbInformation, "Procesar"
    Exit Sub

Fallo:
    Application.StatusBar = False
    Application.ScreenUpdating = True
    Application.Cursor = xlDefault
    Cerrar cn
    Avisar "Fallo el proceso:" & vbLf & vbLf & Err.Description, vbCritical, "Procesar"
End Sub


'===============================================================================
' LA REVISION
'-------------------------------------------------------------------------------
' crudo.descarga lleva una fila por fuente, clave y dia, con la marca de cuando
' se bajo. Con eso se contestan las dos preguntas del boton 1: cuantos dias del
' horizonte no tienen dato, y que antiguedad tiene la descarga mas nueva de las
' que si lo tienen. La conexion se abre y se cierra aqui dentro, para dejar la
' base libre antes de correr la descarga.
'===============================================================================
Private Sub Revisar(ws As Worksheet, ByVal fuente As String, _
                    ByVal ini As Date, ByVal fin As Date, _
                    ByRef faltan As Long, ByRef edad As Double, ByRef ultima As String)
    Dim cn As Object, rs As Object, sql As String

    ' Si algo falla (base recien creada, sin la tabla) queda el peor caso, que
    ' es justo el que manda a descargar.
    faltan = DateDiff("d", ini, fin) + 1
    edad = SIN_DESCARGA
    ultima = "nunca"

    sql = "SELECT count(*) FILTER (WHERE d.fecha IS NULL) AS faltan," & _
          "       max(d.descarga) AS ultima" & _
          "  FROM (SELECT unnest(generate_series(DATE '" & Format(ini, "yyyy-mm-dd") & "'," & _
          "                                      DATE '" & Format(fin, "yyyy-mm-dd") & "'," & _
          "                                      INTERVAL 1 DAY))::DATE AS dia) g" & _
          "  LEFT JOIN (SELECT fecha, max(descarga) AS descarga FROM crudo.descarga" & _
          "              WHERE fuente = '" & Replace(fuente, "'", "''") & "'" & _
          "              GROUP BY 1) d ON d.fecha = g.dia"

    On Error GoTo Salir
    Set cn = AbrirDuckDB(Base(ws))
    Set rs = cn.Execute(sql)
    If Not rs.EOF Then
        faltan = CLng(rs.Fields(0).Value)
        If Not IsNull(rs.Fields(1).Value) Then
            ultima = Format(CDate(rs.Fields(1).Value), "yyyy-mm-dd hh:nn")
            edad = (Now - CDate(rs.Fields(1).Value)) * 24#
        End If
    End If
    rs.Close

Salir:
    Cerrar cn
End Sub


Private Function EsVieja(ByVal edad As Double, ByVal horas As Double) As Boolean
    EsVieja = (horas > 0 And edad > horas)
End Function


Private Function Estado(ByVal faltan As Long, ByVal edad As Double, _
                        ByVal horas As Double) As String
    If faltan > 0 Then
        Estado = "faltan " & faltan & " dias"
    ElseIf EsVieja(edad, horas) Then
        Estado = "vieja (" & Format(edad, "0") & " h)"
    Else
        Estado = "al dia"
    End If
End Function


Private Function Linea(ByVal fuente As String, ByVal faltan As Long, _
                       ByVal edad As Double, ByVal nota As String) As String
    Dim s As String
    s = "  " & fuente & ": "
    If faltan > 0 Then
        s = s & faltan & " dias sin dato"
    ElseIf edad >= SIN_DESCARGA Then
        s = s & "sin descargas"
    Else
        s = s & "descarga de hace " & Format(edad, "0") & " h"
    End If
    If Len(nota) > 0 Then s = s & " - " & nota
    Linea = s & vbLf
End Function


Private Sub Marcar(ws As Worksheet, ByVal fila As Long, _
                   ByVal estado As String, ByVal ultima As String)
    ws.Cells(fila, 4).Value = estado
    ws.Cells(fila, 5).Value = ultima
End Sub


'===============================================================================
' EL HORIZONTE
'-------------------------------------------------------------------------------
' inicio y dias son los del caso; dias_atras es la historia que el modulo
' necesita para calcular (el perfil de las renovables, la climatologia del
' caudal) y que tambien tiene que estar descargada.
'===============================================================================
Private Function Horizonte(ws As Worksheet, ByRef ini As Date, ByRef fin As Date) As Boolean
    Dim sIni As String, dias As Double, atras As Double

    sIni = Valor(ws, "[HORIZONTE]", "inicio")
    dias = Numero(Valor(ws, "[HORIZONTE]", "dias"))
    atras = Numero(Valor(ws, "[HORIZONTE]", "dias_atras"))

    If Len(sIni) = 0 Or dias <= 0 Then
        Avisar "El bloque [HORIZONTE] de Params necesita inicio y dias.", _
               vbExclamation, "Horizonte"
        Exit Function
    End If

    On Error GoTo Mal
    ini = CDate(sIni) - atras
    fin = CDate(sIni) + dias - 1
    Horizonte = True
    Exit Function
Mal:
    Avisar "No entiendo la fecha de inicio: " & sIni & _
           ". Escribela como fecha, no como texto.", vbExclamation, "Horizonte"
End Function


Private Function Prologo(ws As Worksheet, ByVal ini As Date, ByVal fin As Date) As String
    Dim v As Variant, i As Long, s As String
    Dim nombre As String, valor As String, tipo As String, datos As String

    s = "SET VARIABLE fecha_ini = '" & Format(ini, "yyyy-mm-dd") & "';" & vbLf & _
        "SET VARIABLE fecha_fin = '" & Format(fin, "yyyy-mm-dd") & "';" & vbLf

    v = Bloque(ws, "[VARIABLES]")
    If IsEmpty(v) Then
        Prologo = s
        Exit Function
    End If
    datos = Carpeta(ws, "carpeta_datos")

    For i = LBound(v, 1) To UBound(v, 1)
        nombre = Trim$(CStr(v(i, 1)))
        If Len(nombre) > 0 And Left$(nombre, 1) <> "|" Then
            valor = Trim$(CStr(v(i, 2)))
            tipo = LCase$(Trim$(CStr(v(i, 3))))
            Select Case tipo
                Case "archivo": valor = "'" & Replace(Absoluta(valor, datos), "'", "''") & "'"
                Case "numero":  valor = Replace(valor, ",", ".")
                Case "logico":  valor = Logico(valor)
                Case Else:      valor = "'" & Replace(valor, "'", "''") & "'"
            End Select
            s = s & "SET VARIABLE " & nombre & " = " & valor & ";" & vbLf
        End If
    Next i
    Prologo = s
End Function


'===============================================================================
' VOLCADO
'-------------------------------------------------------------------------------
' La hoja tiene que existir: una que falta es un nombre mal escrito en Params,
' no una hoja que haya que crear. Se limpia entera antes de escribir: media
' tabla vieja debajo de una nueva mas corta es la forma silenciosa de mandar
' dato viejo al modelo.
'===============================================================================
Private Function VolcarBloque(ws As Worksheet, cn As Object, ByVal boton As Long) As Long
    Dim v As Variant, i As Long, hoja As String, vista As String, total As Long

    v = Bloque(ws, "[HOJAS]")
    If IsEmpty(v) Then Exit Function

    For i = LBound(v, 1) To UBound(v, 1)
        hoja = Trim$(CStr(v(i, 1)))
        vista = Trim$(CStr(v(i, 2)))
        If Len(hoja) > 0 And Left$(hoja, 1) <> "|" And Len(vista) > 0 Then
            If Numero(CStr(v(i, 3))) = boton Then total = total + Volcar(cn, vista, hoja)
        End If
    Next i
    VolcarBloque = total
End Function


Private Function Volcar(cn As Object, ByVal consulta As String, ByVal hoja As String) As Long
    Dim rs As Object, destino As Worksheet, q As String, j As Long, n As Long

    Set destino = HojaDelLibro(hoja)
    If destino Is Nothing Then
        Err.Raise vbObjectError + 3, "Volcar", _
                  "No existe la hoja " & hoja & " que pide Params."
    End If

    q = consulta
    If InStr(1, q, "select", vbTextCompare) = 0 Then q = "SELECT * FROM " & q
    Set rs = cn.Execute(q)

    destino.Cells.Clear
    For j = 0 To rs.Fields.Count - 1
        destino.Cells(1, j + 1).Value = rs.Fields(j).Name
    Next j
    destino.Rows(1).Font.Bold = True
    If Not rs.EOF Then
        destino.Range("A2").CopyFromRecordset rs
        n = destino.Cells(destino.Rows.Count, 1).End(xlUp).Row - 1
    End If
    rs.Close
    destino.Columns.AutoFit
    Volcar = n
End Function


'===============================================================================
' PLOMERIA
'===============================================================================
Private Sub Ejecutar(ByVal linea As String)
    Dim sh As Object, codigo As Long
    Set sh = CreateObject("WScript.Shell")
    codigo = sh.Run("cmd /c " & linea, 0, True)
    If codigo <> 0 Then
        Err.Raise vbObjectError + 4, "Ejecutar", _
                  "El comando devolvio " & codigo & ":" & vbLf & linea
    End If
End Sub


Private Function Sustituir(ByVal linea As String, ByVal ini As Date, ByVal fin As Date) As String
    linea = Replace(linea, "{RAIZ}", Raiz())
    linea = Replace(linea, "{INICIO}", Format(ini, "yyyy-mm-dd"))
    linea = Replace(linea, "{FIN}", Format(fin, "yyyy-mm-dd"))
    Sustituir = linea
End Function


Private Function AbrirDuckDB(ByVal base As String) As Object
    Dim cn As Object
    Set cn = CreateObject("ADODB.Connection")
    cn.CommandTimeout = TIEMPO_MAX
    cn.Open "Driver={" & DRIVER_ODBC & "};database=" & base & ";"
    Set AbrirDuckDB = cn
End Function


Private Sub Cerrar(cn As Object)
    If cn Is Nothing Then Exit Sub
    On Error Resume Next
    cn.Close
    On Error GoTo 0
    Set cn = Nothing
End Sub


Private Function Base(ws As Worksheet) As String
    Dim b As String
    b = Valor(ws, "[EJECUCION]", "base")
    If Len(b) = 0 Then
        Base = ":memory:"
    Else
        Base = Absoluta(b, "")
    End If
End Function


Private Function LeerArchivo(ByVal ruta As String) As String
    Dim f As Integer
    f = FreeFile
    Open ruta For Input As #f
    LeerArchivo = Input$(LOF(f), #f)
    Close #f
End Function


'-------------------------------------------------------------------------------
' -- #incluir otro.sql
'
' El script del modulo dice el orden de los pasos; cada paso sigue viviendo en
' su archivo, porque varios los comparten los tres modulos. Se pega el archivo
' en el sitio de la linea y se sigue: lo que llega a DuckDB es un solo texto, y
' el error de sintaxis apunta al mismo SQL que se lee en disco. Anida hasta
' cinco niveles, que es mas de lo que hace falta y corta cualquier ciclo.
'-------------------------------------------------------------------------------
Private Function Expandir(ByVal ruta As String, ByVal carpeta As String, _
                          ByRef pasos As Long, Optional ByVal nivel As Long = 0) As String
    Dim lineas As Variant, i As Long, linea As String, hijo As String, s As String

    If nivel > 5 Then
        Err.Raise vbObjectError + 6, "Expandir", _
                  "Demasiados -- #incluir anidados en " & ruta
    End If
    pasos = pasos + 1

    lineas = Split(Replace(LeerArchivo(ruta), vbCrLf, vbLf), vbLf)
    For i = LBound(lineas) To UBound(lineas)
        linea = Trim$(CStr(lineas(i)))
        If LCase$(Left$(linea, 11)) = "-- #incluir" Then
            hijo = Absoluta(Trim$(Mid$(linea, 12)), carpeta)
            If Dir(hijo) = "" Then
                Err.Raise vbObjectError + 7, "Expandir", _
                          "El script incluye un archivo que no existe: " & hijo
            End If
            s = s & Expandir(hijo, carpeta, pasos, nivel + 1) & vbLf
        Else
            s = s & lineas(i) & vbLf
        End If
    Next i
    Expandir = s
End Function


'-------------------------------------------------------------------------------
' LA RAIZ. Normalmente es la carpeta del libro. Pero si la carpeta esta
' sincronizada con OneDrive, Excel abre el libro por su URL de nube y
' ThisWorkbook.Path devuelve https://..., con lo que ni Dir ni el python
' encuentran nada. En ese caso Params tiene que traer raiz con la ruta local.
'-------------------------------------------------------------------------------
Private Function Raiz() As String
    Dim ws As Worksheet, r As String

    Set ws = HojaDelLibro(HOJA_CFG)
    If Not ws Is Nothing Then r = Carpeta(ws, "raiz")

    If Len(r) = 0 Then
        r = ThisWorkbook.Path
        If LCase$(Left$(r, 4)) = "http" Then
            Err.Raise vbObjectError + 5, "Raiz", _
                "Excel abrio este libro por su URL de OneDrive:" & vbLf & r & vbLf & vbLf & _
                "Escribe en [CARPETAS] la clave raiz con la ruta local de la carpeta motor."
        End If
    End If
    Raiz = r
End Function


Private Function Absoluta(ByVal p As String, ByVal base As String) As String
    If Len(p) = 0 Then Exit Function
    If Mid$(p, 2, 1) = ":" Or Left$(p, 2) = "\\" Then
        Absoluta = p
    ElseIf Len(base) = 0 Then
        Absoluta = Raiz() & "\" & p
    ElseIf Mid$(base, 2, 1) = ":" Or Left$(base, 2) = "\\" Then
        Absoluta = base & "\" & p
    Else
        Absoluta = Raiz() & "\" & base & "\" & p
    End If
End Function


Private Function Carpeta(ws As Worksheet, ByVal clave As String) As String
    Dim s As String
    s = Valor(ws, "[CARPETAS]", clave)
    Do While Right$(s, 1) = "\"
        s = Left$(s, Len(s) - 1)
    Loop
    Carpeta = s
End Function


Private Function Valor(ws As Worksheet, ByVal marca As String, ByVal clave As String) As String
    Dim v As Variant, i As Long
    v = Bloque(ws, marca)
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            Valor = Trim$(CStr(v(i, 2)))
            Exit Function
        End If
    Next i
End Function


'-------------------------------------------------------------------------------
' Un bloque empieza en su marca en la columna A y acaba en la primera fila con
' la columna A vacia o con otra marca. Devuelve las cinco primeras columnas,
' indexadas por el numero de fila de la hoja, para poder escribir el estado al
' lado de la fila que se acaba de revisar.
'-------------------------------------------------------------------------------
Private Function Bloque(ws As Worksheet, ByVal marca As String) As Variant
    Dim ultima As Long, i As Long, ini As Long, fin As Long
    Dim v As Variant, j As Long, k As Long, cab As String

    ultima = ws.UsedRange.Row + ws.UsedRange.Rows.Count - 1
    For i = 1 To ultima
        If UCase$(Trim$(CStr(ws.Cells(i, 1).Value))) = UCase$(marca) Then
            ini = i + 1
            Exit For
        End If
    Next i
    If ini = 0 Then Exit Function

    cab = UCase$(Trim$(CStr(ws.Cells(ini, 1).Value)))
    If cab = "CLAVE" Or cab = "CONSULTA" Or cab = "VISTA" Or cab = "FUENTE" Then ini = ini + 1

    fin = ini - 1
    For i = ini To ultima
        If Len(Trim$(CStr(ws.Cells(i, 1).Value))) = 0 Then Exit For
        If Left$(Trim$(CStr(ws.Cells(i, 1).Value)), 1) = "[" Then Exit For
        fin = i
    Next i
    If fin < ini Then Exit Function

    ReDim v(ini To fin, 1 To 5)
    For j = ini To fin
        For k = 1 To 5
            v(j, k) = ws.Cells(j, k).Value
        Next k
    Next j
    Bloque = v
End Function


Private Function Numero(ByVal s As String) As Double
    s = Trim$(Replace(s, ",", "."))
    If Len(s) = 0 Then Exit Function
    If IsNumeric(s) Then Numero = CDbl(Val(s))
End Function


' Una celda con VERDADERO guarda un Booleano, y CStr lo devuelve en el idioma
' de Office ("Verdadero"), que DuckDB no entiende.
Private Function Logico(ByVal v As String) As String
    Select Case LCase$(Trim$(v))
        Case "true", "verdadero", "1", "-1", "si", "yes", "v": Logico = "true"
        Case "false", "falso", "0", "no", "f":                 Logico = "false"
        Case Else:                                             Logico = v
    End Select
End Function


Private Function HojaCfg(ByVal titulo As String) As Worksheet
    Set HojaCfg = HojaDelLibro(HOJA_CFG)
    If HojaCfg Is Nothing Then
        Avisar "Este libro no tiene la hoja " & HOJA_CFG & ".", vbExclamation, titulo
    End If
End Function


Private Function HojaDelLibro(ByVal nombre As String) As Worksheet
    Dim ws As Worksheet
    For Each ws In ThisWorkbook.Worksheets
        If StrComp(ws.Name, nombre, vbTextCompare) = 0 Then
            Set HojaDelLibro = ws
            Exit Function
        End If
    Next ws
End Function
