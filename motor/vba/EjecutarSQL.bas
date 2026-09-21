Attribute VB_Name = "EjecutarSQL"
'===============================================================================
' EjecutarSQL.bas - arma los casos de Yupana: corre los .sql de DuckDB desde
' Excel, por COM, y luego los comandos que escriben las carpetas
'===============================================================================
' ADODB.Connection -> "DuckDB Driver" (ODBC) -> motor DuckDB dentro de Excel.
' Cada .sql entra completo en un solo cn.Execute: no se trocea ni se copia, y
' es el mismo archivo que corre en DBeaver o con duckdb.exe.
'
' LA HOJA Params LA ESCRIBE QUIEN OPERA EL CASO; ESTE MODULO SOLO LA LEE.
'   [CARPETAS]   carpeta_scripts (los .sql) y carpeta_datos (los libros)
'   [EJECUCION]  script, una fila por script y en el orden en que corren; base
'   [VARIABLES]  clave | valor | tipo, que se mandan como SET VARIABLE
'   [SALIDAS]    consulta | hoja de ESTE libro que la recibe
' Cada bloque empieza en su marca de la columna A y acaba en la primera fila
' con la columna A vacia. La fila de encabezado (Clave, Consulta) y las que
' empiezan por | se saltan. Tipo de una variable: texto | archivo | numero |
' logico. Un archivo se escribe como nombre y se compone con carpeta_datos; si
' ahi no esta, se busca junto a este libro; una ruta completa se respeta tal cual.
'
' EL HORIZONTE. El bloque [HORIZONTE] de Params dice desde cuando, cuantos
' dias dura cada caso y cuantos casos van. De ahi salen fecha_ini y fecha_fin,
' que se mandan como variables antes de los scripts: los tres modulos las leen
' con getvariable y calculan sobre el tramo completo, de una vez.
'
' LOS COMANDOS. Los .sql llenan crudo.hecho_restriccion, pero no pueden copiar
' carpetas. El bloque [COMANDOS] corre despues, en orden, y es el que arma las
' carpetas de cada caso. En sus lineas, {RAIZ}, {INICIO}, {DIAS} y {CASOS} se
' sustituyen por lo que dice [HORIZONTE].
'
' EL INFORME. validacion_mantenimiento_hidro.txt en el libro hidro y
' validacion_mantenimiento_termo.txt en el termico, en la carpeta del libro,
' con dos secciones: VALIDACION DE LA FUENTE (ValidarFuenteDelCaso) y
' PREPROCESO (PreprocesarMantenimiento). Cada boton reescribe la suya y deja la
' otra como estaba. El preproceso anota las variables enviadas, el tiempo de
' cada script, las filas de cada hoja y cada tabla o vista control_* que dejan
' los .sql, con su numero de filas y el comentario que le pone el propio .sql
' ("DEBE SER 0 ..." o "INFORMATIVA ..."). La que debe ser 0 y no lo es se marca
' FALLA. Se escribe tambien cuando el preproceso falla, con el error al final.
'
' EL SQL LEE DEL DISCO. st_read abre los libros como archivo: si CHH o Gtt se
' editaron y no se guardaron, el SQL ve la version guardada y no avisa. Por eso
' se ofrece guardar este libro antes de correr.
'
' REQUISITO: el driver ODBC de DuckDB de la misma arquitectura que este Excel
' (boton ProbarConexionDuckDB). Sin referencias: todo va por CreateObject.
'===============================================================================
Option Explicit

Public Const SECCION_VALIDACION As String = "VALIDACION DE LA FUENTE"
Public Const SECCION_PREPROCESO As String = "PREPROCESO"

Private Const HOJA_CFG As String = "Params"
Private Const DRIVER_ODBC As String = "DuckDB Driver"
Private Const TIEMPO_MAX As Long = 900             ' segundos por sentencia
Private Const INFORME_BASE As String = "informe_caso"
Private Const MARCA_SECCION As String = "#### "

Private mLog As Collection
Private nScripts As Long


'===============================================================================
' EL BOTON DEL PREPROCESO
'===============================================================================
Public Sub EjecutarCaso()
    Dim ws As Worksheet, cn As Object
    Dim base As String, sql As String, prologo As String, falta As String
    Dim msgErr As String, t0 As Single, t1 As Single
    Dim filas As Long, i As Long, fallas As Long
    Dim salidas As Variant, linea As Variant
    Dim scripts() As String

    Set ws = HojaCfg()
    If ws Is Nothing Then
        Avisar "No existe la hoja " & HOJA_CFG & " en este libro.", vbExclamation, "Armar caso"
        Exit Sub
    End If
    If Not AvisarSinGuardar(ws) Then Exit Sub

    Set mLog = New Collection
    Registrar "Fecha:  " & Format(Now, "yyyy-mm-dd hh:nn:ss")
    Registrar "Libro:  " & ThisWorkbook.FullName

    scripts = ScriptsDeEjecucion(ws)
    base = ValorEjecucion(ws, "base")
    If base = "" Then base = ":memory:"
    Registrar "Base:   " & base

    If nScripts = 0 Then
        TerminarSinCorrer "El bloque [EJECUCION] de Params no tiene ninguna fila 'script'."
        Exit Sub
    End If
    For i = 1 To nScripts
        If Dir(scripts(i)) = "" Then
            TerminarSinCorrer "No encuentro el script " & scripts(i) & _
                              ". Revisa carpeta_scripts en [CARPETAS] y el nombre en [EJECUCION]."
            Exit Sub
        End If
    Next i
    falta = ArchivoQueFalta(ws)
    If Len(falta) > 0 Then
        TerminarSinCorrer falta
        Exit Sub
    End If

    prologo = PrologoHorizonte(ws) & PrologoVariables(ws)
    Registrar ""
    Registrar "VARIABLES ENVIADAS"
    For Each linea In Split(prologo, vbLf)
        If Len(linea) > 0 Then Registrar "  " & linea
    Next linea

    Application.ScreenUpdating = False
    Application.Cursor = xlWait
    t0 = Timer
    On Error GoTo Fallo
    Set cn = AbrirDuckDB(base)
    If Len(prologo) > 0 Then cn.Execute prologo

    ' Los scripts, en el orden de la hoja, enteros y sobre LA MISMA conexion:
    ' el segundo consume las tablas que deja el primero.
    Registrar ""
    Registrar "SCRIPTS"
    For i = 1 To nScripts
        t1 = Timer
        sql = LeerArchivo(scripts(i))
        cn.Execute sql
        Registrar "  " & Format(Timer - t1, "0.0") & " s   " & scripts(i)
    Next i

    Registrar ""
    Registrar "HOJAS ESCRITAS"
    salidas = Bloque(ws, "[SALIDAS]")
    If Not IsEmpty(salidas) Then
        For i = LBound(salidas, 1) To UBound(salidas, 1)
            If Len(Trim$(CStr(salidas(i, 1)))) > 0 And Left$(Trim$(CStr(salidas(i, 1))), 1) <> "|" Then
                filas = Volcar(cn, CStr(salidas(i, 1)), CStr(salidas(i, 2)))
                Registrar "  " & Trim$(CStr(salidas(i, 2))) & " <- " & Trim$(CStr(salidas(i, 1))) & _
                          "   (" & filas & " filas)"
            End If
        Next i
    End If

    Registrar ""
    fallas = RegistrarControles(cn)
    cn.Close
    Set cn = Nothing

    Registrar ""
    Registrar "COMANDOS"
    EjecutarComandos ws

    Registrar ""
    Registrar "Total: " & Format(Timer - t0, "0.0") & " s"
    EscribirSeccionInforme SECCION_PREPROCESO, mLog

    Application.Cursor = xlDefault
    Application.ScreenUpdating = True
    If fallas > 0 Then
        Avisar "Proceso terminado, con " & fallas & " control(es) que deben dar 0 y no dan 0." & _
               vbLf & vbLf & "El detalle esta en:" & vbLf & RutaInforme(), vbExclamation, "Armar caso"
    Else
        Avisar "Proceso terminado en " & Format(Timer - t0, "0.0") & " s." & _
               vbLf & vbLf & "El detalle esta en:" & vbLf & RutaInforme(), vbInformation, "Armar caso"
    End If
    Exit Sub

Fallo:
    msgErr = "ERROR " & Err.Number & ": " & Err.Description
    On Error Resume Next
    If Not cn Is Nothing Then cn.Close
    Application.Cursor = xlDefault
    Application.ScreenUpdating = True
    Registrar ""
    Registrar msgErr
    EscribirSeccionInforme SECCION_PREPROCESO, mLog
    Avisar "Fallo al armar el caso." & vbLf & vbLf & msgErr & vbLf & vbLf & _
           "El detalle esta en:" & vbLf & RutaInforme(), vbCritical, "Armar caso"
End Sub


' Lo que impide correr tambien queda en el informe: un txt con la fecha de
' otra corrida diria algo que ya no es cierto.
Private Sub TerminarSinCorrer(ByVal mensaje As String)
    Registrar ""
    Registrar "NO SE CORRIO: " & mensaje
    EscribirSeccionInforme SECCION_PREPROCESO, mLog
    Avisar mensaje & vbLf & vbLf & "Anotado en:" & vbLf & RutaInforme(), vbCritical, "Armar caso"
End Sub


'===============================================================================
' LOS CONTROLES
'-------------------------------------------------------------------------------
' Toda tabla o vista cuyo nombre empieza por control_ es un control, y el .sql
' dice en su comentario (COMMENT ON) si tiene que dar cero o es informativa.
' Aqui no hay una lista propia: un control nuevo en el .sql sale en el informe
' sin tocar ni la hoja ni este modulo. Devuelve cuantos deben dar 0 y no dan 0.
'===============================================================================
Private Function RegistrarControles(cn As Object) As Long
    Dim rs As Object, dat As Variant, i As Long, n As Long
    Dim nombre As String, comentario As String, marca As String

    Registrar "CONTROLES  (filas, nombre y lo que dice el .sql)"
    Set rs = cn.Execute("SELECT nombre, COALESCE(comentario, '') AS comentario FROM (" & _
                        "SELECT table_name AS nombre, comment AS comentario FROM duckdb_tables() " & _
                        "UNION ALL " & _
                        "SELECT view_name, comment FROM duckdb_views() WHERE NOT internal) " & _
                        "WHERE starts_with(nombre, 'control_') ORDER BY nombre")
    If rs.EOF Then
        rs.Close
        Registrar "  (ninguno)"
        Exit Function
    End If
    dat = rs.GetRows()                          ' (campo, fila)
    rs.Close

    For i = 0 To UBound(dat, 2)
        nombre = CStr(dat(0, i))
        comentario = CStr(dat(1, i))
        n = Contar(cn, nombre)
        marca = "      "
        If n <> 0 And UCase$(Left$(comentario, 10)) = "DEBE SER 0" Then
            marca = "FALLA "
            RegistrarControles = RegistrarControles + 1
        End If
        Registrar "  " & marca & Right$(Space$(8) & CStr(n), 8) & "  " & nombre & _
                  IIf(Len(comentario) > 0, "  -- " & comentario, "")
    Next i
End Function


Private Function Contar(cn As Object, ByVal vista As String) As Long
    Dim rs As Object
    On Error GoTo Fallo
    Set rs = cn.Execute("SELECT count(*) FROM " & vista)
    Contar = CLng(rs.Fields(0).Value)
    rs.Close
    Exit Function
Fallo:
    Contar = -1                                  ' la vista no se pudo leer
End Function


'===============================================================================
' EL INFORME DEL LIBRO - validacion_mantenimiento_hidro.txt / _termo.txt
'-------------------------------------------------------------------------------
' Una seccion por boton, cada una bajo su linea "#### NOMBRE". Se reescribe la
' seccion pedida y se conservan las demas, siempre en el mismo orden. Lo usa
' tambien ValidarMantenimiento.bas.
'===============================================================================
Public Function RutaInforme() As String
    RutaInforme = ThisWorkbook.Path & "\" & INFORME_BASE & _
                  Format(Date, "yyyy-mm-dd") & ".txt"
End Function


Public Sub EscribirSeccionInforme(ByVal seccion As String, lineas As Collection)
    Dim ruta As String, previo As String, nombre As String, texto As String
    Dim secciones As Object, x As Variant, s As Variant, f As Integer

    On Error GoTo NoSePudo
    ruta = RutaInforme()
    Set secciones = CreateObject("Scripting.Dictionary")

    If Len(Dir(ruta)) > 0 Then
        previo = Replace(LeerArchivo(ruta), vbCrLf, vbLf)
        For Each x In Split(previo, vbLf)
            If Left$(x, Len(MARCA_SECCION)) = MARCA_SECCION Then
                nombre = Trim$(Mid$(x, Len(MARCA_SECCION) + 1))
                secciones(nombre) = ""
            ElseIf Len(nombre) > 0 Then
                secciones(nombre) = secciones(nombre) & x & vbLf
            End If
        Next x
    End If

    texto = ""
    If Not lineas Is Nothing Then
        For Each x In lineas
            texto = texto & CStr(x) & vbLf
        Next x
    End If
    secciones(seccion) = texto

    f = FreeFile
    Open ruta For Output As #f
    For Each s In Array(SECCION_VALIDACION, SECCION_PREPROCESO)
        If secciones.Exists(s) Then
            texto = secciones(s)
            Do While Len(texto) > 0 And Right$(texto, 1) = vbLf
                texto = Left$(texto, Len(texto) - 1)
            Loop
            Print #f, MARCA_SECCION & s
            Print #f, Replace(texto, vbLf, vbCrLf)
            Print #f, ""
        End If
    Next s
    Close #f
    Exit Sub

NoSePudo:
    On Error Resume Next
    If f <> 0 Then Close #f
    Avisar "No pude escribir el informe:" & vbLf & ruta & vbLf & vbLf & Err.Description, _
           vbCritical, "Informe"
End Sub


'===============================================================================
' EL SQL LEE DEL DISCO
'-------------------------------------------------------------------------------
' bloques_perseo.sql saca CHH de libro_hidro y Gtt de libro_termico con st_read,
' que abre el ARCHIVO. Si uno de los dos es este mismo libro y hay cambios sin
' guardar, el SQL trabaja con la version guardada y el resultado no lo delata.
'===============================================================================
Private Function AvisarSinGuardar(ws As Worksheet) As Boolean
    Dim wb As Workbook, propio As String, r As VbMsgBoxResult
    AvisarSinGuardar = True
    Set wb = ws.Parent
    If wb.Saved Then Exit Function
    If wb.Path = "" Then Exit Function

    propio = wb.FullName
    If StrComp(ValorArchivo(ws, "libro_hidro"), propio, vbTextCompare) <> 0 And _
       StrComp(ValorArchivo(ws, "libro_termico"), propio, vbTextCompare) <> 0 Then
        Exit Function
    End If

    ' Desatendido -> Cancelar: ver Avisos.bas.
    r = Preguntar("Este libro tiene cambios sin guardar, y el SQL lo lee DEL DISCO:" & _
                  vbLf & propio & vbLf & vbLf & _
                  "Si sigues sin guardar, el SQL usara el catalogo de la version " & _
                  "guardada y no avisara de la diferencia." & vbLf & vbLf & _
                  "Guardar ahora y continuar?", vbYesNoCancel + vbExclamation, _
                  "Armar caso", vbCancel)
    Select Case r
        Case vbYes:    wb.Save
        Case vbCancel: AvisarSinGuardar = False
    End Select
End Function


'===============================================================================
' COMPROBACION DE INSTALACION - tarda un segundo
'===============================================================================
Public Sub ProbarConexionDuckDB()
    Dim cn As Object, rs As Object, msg As String
    On Error GoTo Fallo
    Set cn = AbrirDuckDB(":memory:")
    Set rs = cn.Execute("SELECT version() AS v")
    msg = "Conexion OK." & vbLf & vbLf & _
          "Motor DuckDB: " & rs.Fields(0).Value & vbLf & _
          "Excel: " & IIf(Es64Bits(), "64", "32") & " bits"
    rs.Close
    cn.Close
    Avisar msg, vbInformation, "DuckDB por ODBC"
    Exit Sub
Fallo:
    Avisar "No se pudo conectar." & vbLf & vbLf & Err.Description & vbLf & vbLf & _
           "Lo mas comun: el driver no esta instalado, o es de otra " & _
           "arquitectura que este Excel (" & IIf(Es64Bits(), "64", "32") & _
           " bits).", vbCritical, "DuckDB por ODBC"
End Sub


Private Function AbrirDuckDB(ByVal base As String) As Object
    Dim cn As Object
    Set cn = CreateObject("ADODB.Connection")
    cn.ConnectionString = "Driver={" & DRIVER_ODBC & "};database=" & base & ";"
    cn.CommandTimeout = TIEMPO_MAX
    cn.Open
    Set AbrirDuckDB = cn
End Function


' Binario, para no depender de como Excel lea el texto.
Private Function LeerArchivo(ByVal ruta As String) As String
    Dim f As Integer, s As String
    f = FreeFile
    Open ruta For Binary Access Read As #f
    s = Space$(LOF(f))
    Get #f, , s
    Close #f
    LeerArchivo = s
End Function


'===============================================================================
' LAS VARIABLES DE LA HOJA -> SET VARIABLE
'-------------------------------------------------------------------------------
' El tipo decide como se escribe el literal:
'   texto    entre comillas simples, con las internas dobladas
'   archivo  igual, compuesto antes con carpeta_datos si es solo un nombre
'   numero   desnudo, con la coma decimal local pasada a punto
'   logico   desnudo (true / false)
'===============================================================================
' Un archivo que no esta se dice aqui y no dentro del SQL, donde st_read falla
' con un mensaje de GDAL que no nombra la celda.
Private Function ArchivoQueFalta(ws As Worksheet) As String
    Dim v As Variant, i As Long, datos As String, nombre As String, ruta As String

    v = Bloque(ws, "[VARIABLES]")
    If IsEmpty(v) Then Exit Function
    datos = Carpeta(ws, "carpeta_datos")

    For i = LBound(v, 1) To UBound(v, 1)
        nombre = Trim$(CStr(v(i, 1)))
        If Len(nombre) > 0 And Left$(nombre, 1) <> "|" Then
            If LCase$(Trim$(CStr(v(i, 3)))) = "archivo" Then
                ruta = Absoluta(Trim$(CStr(v(i, 2))), datos)
                If Len(ruta) = 0 Or Dir(ruta) = "" Then
                    ArchivoQueFalta = "No encuentro el archivo de la variable '" & nombre & _
                                      "': " & ruta & ". Corrige esa fila de [VARIABLES] " & _
                                      "o carpeta_datos en [CARPETAS]."
                    Exit Function
                End If
            End If
        End If
    Next i
End Function


' El horizonte cubre todos los casos de una vez: desde `inicio` hasta el
' ultimo dia del ultimo caso. Los modulos calculan sobre el tramo entero y el
' reparto por caso lo hace despues el comando que arma las carpetas.
Private Function PrologoHorizonte(ws As Worksheet) As String
    Dim ini As Date, dias As Long, casos As Long

    If Len(ValorHorizonte(ws, "inicio")) = 0 Then Exit Function
    ini = FechaISO(ValorHorizonte(ws, "inicio"))
    dias = Val(ValorHorizonte(ws, "dias_caso"))
    casos = Val(ValorHorizonte(ws, "n_casos"))
    If dias <= 0 Then dias = 7
    If casos <= 0 Then casos = 1

    PrologoHorizonte = _
        "SET VARIABLE fecha_ini = '" & Format(ini, "yyyy-mm-dd") & "';" & vbLf & _
        "SET VARIABLE fecha_fin = '" & _
        Format(DateAdd("d", dias * casos - 1, ini), "yyyy-mm-dd") & "';" & vbLf
End Function


 CDate leeria "2026-09-20" segun la configuracion regional de Windows, y en
' una maquina con formato dd/mm daria otra fecha o fallaria. Se parte a mano.
Private Function FechaISO(ByVal s As String) As Date
    Dim p() As String
    p = Split(Trim$(s), "-")
    If UBound(p) <> 2 Then
        Err.Raise vbObjectError + 2, "FechaISO", _
                  "La fecha de [HORIZONTE] debe ir como aaaa-mm-dd, y dice: " & s
    End If
    FechaISO = DateSerial(CLng(p(0)), CLng(p(1)), CLng(p(2)))
End Function


Private Function ValorHorizonte(ws As Worksheet, ByVal clave As String) As String
    Dim v As Variant, i As Long
    v = Bloque(ws, "[HORIZONTE]")
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            ValorHorizonte = Trim$(CStr(v(i, 2)))
            Exit Function
        End If
    Next i
End Function


' Los .sql no pueden copiar carpetas, asi que el armado del caso sale de aqui.
' Se espera a que cada comando termine: el siguiente suele depender del
' anterior, y ademas el informe tiene que poder contar como fue.
Private Sub EjecutarComandos(ws As Worksheet)
    Dim v As Variant, i As Long, linea As String, codigo As Long
    Dim sh As Object

    v = Bloque(ws, "[COMANDOS]")
    If IsEmpty(v) Then
        Registrar "  (ninguno)"
        Exit Sub
    End If
    Set sh = CreateObject("WScript.Shell")
    For i = LBound(v, 1) To UBound(v, 1)
        linea = Trim$(CStr(v(i, 1)))
        If Len(linea) > 0 And Left$(linea, 1) <> "|" Then
            linea = Replace(linea, "{RAIZ}", ThisWorkbook.Path)
            linea = Replace(linea, "{INICIO}", ValorHorizonte(ws, "inicio"))
            linea = Replace(linea, "{DIAS}", ValorHorizonte(ws, "dias_caso"))
            linea = Replace(linea, "{CASOS}", ValorHorizonte(ws, "n_casos"))
            codigo = sh.Run("cmd /c " & linea, 0, True)
            Registrar "  [" & codigo & "]  " & linea
            If codigo <> 0 Then
                Err.Raise vbObjectError + 1, "EjecutarComandos", _
                          "El comando devolvio " & codigo & ": " & linea
            End If
        End If
    Next i
End Sub


Private Function PrologoVariables(ws As Worksheet) As String
    Dim v As Variant, i As Long, s As String
    Dim nombre As String, valor As String, tipo As String, datos As String

    v = Bloque(ws, "[VARIABLES]")
    If IsEmpty(v) Then Exit Function
    datos = Carpeta(ws, "carpeta_datos")

    For i = LBound(v, 1) To UBound(v, 1)
        nombre = Trim$(CStr(v(i, 1)))
        If Len(nombre) > 0 And Left$(nombre, 1) <> "|" Then
            valor = Trim$(CStr(v(i, 2)))
            tipo = LCase$(Trim$(CStr(v(i, 3))))
            Select Case tipo
                Case "archivo"
                    valor = "'" & Replace(Absoluta(valor, datos), "'", "''") & "'"
                Case "numero"
                    valor = Replace(valor, ",", ".")
                Case "logico"
                    valor = Logico(valor)
                Case Else
                    valor = "'" & Replace(valor, "'", "''") & "'"
            End Select
            s = s & "SET VARIABLE " & nombre & " = " & valor & ";" & vbLf
        End If
    Next i
    PrologoVariables = s
End Function


' Una celda con VERDADERO guarda un Booleano, y CStr lo devuelve en el idioma de
' Office ("Verdadero"), que DuckDB no entiende. Lo que no se reconoce va tal
' cual, para que lo nombre DuckDB.
Private Function Logico(ByVal v As String) As String
    Select Case LCase$(Trim$(v))
        Case "true", "verdadero", "1", "-1", "si", "yes", "v"
            Logico = "true"
        Case "false", "falso", "0", "no", "f"
            Logico = "false"
        Case Else
            Logico = v
    End Select
End Function


'===============================================================================
' VOLCADO DE UNA CONSULTA A UNA HOJA DE ESTE LIBRO
'-------------------------------------------------------------------------------
' La hoja tiene que existir: son las hojas del modelo, y una que falta es un
' nombre mal escrito en [SALIDAS], no una hoja que haya que crear. Se limpia
' entera antes de escribir: media tabla vieja debajo de una nueva mas corta es
' la forma silenciosa de mandar dato viejo al modelo.
'===============================================================================
Private Function Volcar(cn As Object, ByVal consulta As String, ByVal destino As String) As Long
    Dim rs As Object, q As String, ws As Worksheet

    destino = Trim$(destino)
    Set ws = HojaDelLibro(destino)
    If ws Is Nothing Then
        Err.Raise vbObjectError + 513, "Armar caso", _
                  "La hoja '" & destino & "' de [SALIDAS] no existe en este libro."
    End If

    q = Trim$(consulta)
    If InStr(1, q, " ") = 0 Then q = "SELECT * FROM " & q
    Set rs = cn.Execute(q)
    Volcar = VuelcaHoja(rs, ws)
    rs.Close
End Function


' GetRows y no CopyFromRecordset: GetRows devuelve el array y deja ver lo que
' llego, incluido el caso de cero filas.
Private Function VuelcaHoja(rs As Object, ws As Worksheet) As Long
    Dim dat As Variant, sal As Variant
    Dim nf As Long, nc As Long, i As Long, j As Long

    ws.Cells.Clear
    nc = rs.Fields.Count
    For j = 0 To nc - 1
        ws.Cells(1, j + 1).Value = rs.Fields(j).Name
    Next j
    ws.Rows(1).Font.Bold = True

    If Not rs.EOF Then
        dat = rs.GetRows()                       ' (campo, fila)
        nf = UBound(dat, 2) + 1
        ReDim sal(1 To nf, 1 To nc)
        For i = 0 To nf - 1
            For j = 0 To nc - 1
                sal(i + 1, j + 1) = dat(j, i)
            Next j
        Next i
        ws.Range("A2").Resize(nf, nc).Value = sal
    End If
    ws.Columns.AutoFit
    VuelcaHoja = nf
End Function


'===============================================================================
' LOS BLOQUES DE LA HOJA Params
'-------------------------------------------------------------------------------
' Se busca la marca en la columna A y se devuelven las filas siguientes hasta la
' primera con A vacia o con otra marca, saltando la fila de encabezado.
'===============================================================================
Private Function Bloque(ws As Worksheet, ByVal marca As String) As Variant
    Dim ultima As Long, i As Long, ini As Long, fin As Long
    Dim v As Variant, j As Long, k As Long

    ultima = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    For i = 1 To ultima
        If UCase$(Trim$(CStr(ws.Cells(i, 1).Value))) = UCase$(marca) Then
            ini = i + 1
            Exit For
        End If
    Next i
    If ini = 0 Then Exit Function

    Select Case UCase$(Trim$(CStr(ws.Cells(ini, 1).Value)))
        Case "CLAVE", "CONSULTA", "VISTA": ini = ini + 1
    End Select

    fin = ini - 1
    For i = ini To ultima
        If Len(Trim$(CStr(ws.Cells(i, 1).Value))) = 0 Then Exit For
        If Left$(Trim$(CStr(ws.Cells(i, 1).Value)), 1) = "[" Then Exit For
        fin = i
    Next i
    If fin < ini Then Exit Function

    ReDim v(ini To fin, 1 To 4)
    For j = ini To fin
        For k = 1 To 4
            v(j, k) = ws.Cells(j, k).Value
        Next k
    Next j
    Bloque = v
End Function


Private Function Carpeta(ws As Worksheet, ByVal clave As String) As String
    Dim v As Variant, i As Long, s As String
    v = Bloque(ws, "[CARPETAS]")
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            s = Trim$(CStr(v(i, 2)))
            Do While Right$(s, 1) = "\"
                s = Left$(s, Len(s) - 1)
            Loop
            Carpeta = s
            Exit Function
        End If
    Next i
End Function


Private Function ScriptsDeEjecucion(ws As Worksheet) As String()
    Dim v As Variant, i As Long, s() As String, base As String
    ReDim s(1 To 32)
    nScripts = 0
    v = Bloque(ws, "[EJECUCION]")
    If IsEmpty(v) Then
        ScriptsDeEjecucion = s
        Exit Function
    End If
    base = Carpeta(ws, "carpeta_scripts")
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = "SCRIPT" Then
            If Len(Trim$(CStr(v(i, 2)))) > 0 Then
                nScripts = nScripts + 1
                s(nScripts) = Absoluta(Trim$(CStr(v(i, 2))), base)
            End If
        End If
    Next i
    ScriptsDeEjecucion = s
End Function


Private Function ValorEjecucion(ws As Worksheet, ByVal clave As String) As String
    Dim v As Variant, i As Long
    v = Bloque(ws, "[EJECUCION]")
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            ValorEjecucion = Trim$(CStr(v(i, 2)))
            Exit Function
        End If
    Next i
End Function


'===============================================================================
' LO QUE ValidarMantenimiento.bas NECESITA DE Params
'===============================================================================
Public Function ValorVariable(ByVal clave As String) As String
    Dim ws As Worksheet, v As Variant, i As Long
    Set ws = HojaCfg()
    If ws Is Nothing Then Exit Function
    v = Bloque(ws, "[VARIABLES]")
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            ValorVariable = Trim$(CStr(v(i, 2)))
            Exit Function
        End If
    Next i
End Function


' Una variable de tipo archivo, ya compuesta con carpeta_datos.
Public Function ValorArchivo(ByVal ws As Worksheet, ByVal clave As String) As String
    Dim v As Variant, i As Long
    If ws Is Nothing Then Set ws = HojaCfg()
    If ws Is Nothing Then Exit Function
    v = Bloque(ws, "[VARIABLES]")
    If IsEmpty(v) Then Exit Function
    For i = LBound(v, 1) To UBound(v, 1)
        If UCase$(Trim$(CStr(v(i, 1)))) = UCase$(clave) Then
            ValorArchivo = Absoluta(Trim$(CStr(v(i, 2))), Carpeta(ws, "carpeta_datos"))
            Exit Function
        End If
    Next i
End Function


Public Function HojaParams() As Worksheet
    Set HojaParams = HojaCfg()
End Function


'===============================================================================
' AUXILIARES
'===============================================================================
' QUE LIBRO ES ESTE. El mismo modulo vive en el libro hidro y en el termico, y
' se reconoce por el catalogo que aloja -- CHH o Gtt --, no por el nombre del
' archivo.
Private Function HojaDelLibro(ByVal nombre As String) As Worksheet
    Dim ws As Worksheet
    For Each ws In ThisWorkbook.Worksheets
        If StrComp(ws.Name, nombre, vbTextCompare) = 0 Then
            Set HojaDelLibro = ws
            Exit Function
        End If
    Next ws
End Function


Private Function HojaCfg() As Worksheet
    Set HojaCfg = HojaDelLibro(HOJA_CFG)
End Function


Private Sub Registrar(ByVal texto As String)
    If mLog Is Nothing Then Set mLog = New Collection
    mLog.Add texto
End Sub


' Nombre + carpeta -> ruta. Una ruta ya completa se respeta tal cual.
'
' Y si el nombre NO esta en esa carpeta, se prueba junto al libro que corre: asi
' una carpeta_datos que apunta a donde vive el libro de mantenimiento no obliga
' a mover tambien 01_config.xlsm ni los libros del caso, que estan al lado de
' este. Cuando no esta en ninguna de las dos, se devuelve la de la carpeta
' declarada, que es la que hay que corregir y la que dice el aviso.
Private Function Absoluta(ByVal p As String, ByVal base As String) As String
    Dim enBase As String

    If Len(p) = 0 Then Exit Function
    If Mid$(p, 2, 1) = ":" Or Left$(p, 2) = "\\" Then
        Absoluta = p
        Exit Function
    End If

    If Len(base) = 0 Then
        Absoluta = ThisWorkbook.Path & "\" & p
        Exit Function
    End If

    enBase = base & "\" & p
    If Dir(enBase) <> "" Then
        Absoluta = enBase
    ElseIf Dir(ThisWorkbook.Path & "\" & p) <> "" Then
        Absoluta = ThisWorkbook.Path & "\" & p
    Else
        Absoluta = enBase
    End If
End Function


Private Function Es64Bits() As Boolean
    #If Win64 Then
        Es64Bits = True
    #End If
End Function
