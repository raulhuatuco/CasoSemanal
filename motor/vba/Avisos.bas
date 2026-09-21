Attribute VB_Name = "Avisos"
'===============================================================================
' Avisos.bas - el unico sitio donde este proyecto llama a MsgBox
'===============================================================================
' POR QUE ES UN MODULO APARTE. Estas cinco rutinas las necesitan TODOS los
' libros del caso, y desde el 2026-09-07 los libros ya no llevan el mismo
' codigo: 01_config.xlsm construye el .gdx y no corre SQL; 02.0_hydroelectric y
' 03_thermal corren el preproceso del mantenimiento y no construyen nada. Tener
' Avisar() dentro de EjecutarSQL.bas obligaba a meter los 1 200 renglones del
' preproceso en 01_config solo para poder avisar. Aqui son 40 renglones y no
' arrastran nada: ni ODBC, ni hoja Params, ni referencias.
'
'===============================================================================
' AVISOS - por que aqui no se llama a MsgBox directamente
'-------------------------------------------------------------------------------
' UN MsgBox NO SE PUEDE CERRAR SOLO. Cuando estos botones se corren desde fuera
' -- reimportar los .bas por COM y dejar Params rehecha sin abrir Excel a mano --
' el MsgBox del final se queda esperando un clic que no va a llegar: el
' Application.Run que lo lanzo no vuelve, y quien llamo se cuelga hasta que su
' llamada caduque. Y NO SE ARREGLA con Application.DisplayAlerts = False: eso
' silencia los avisos que da EXCEL por su cuenta, no los que pide el codigo.
'
' Por eso el aviso pasa por Avisar(). Con alguien delante se comporta igual que
' siempre; sin nadie delante se guarda en vez de mostrarse, y quien llamo lo lee
' con UltimoAviso(). El mensaje no se pierde: deja de bloquear.
'
' COMO SE SABE QUE NO HAY NADIE. Si Application.Visible es False no hay ventana
' donde pulsar, y con eso basta. Ademas se puede decir a mano con
' ModoDesatendido True, que es lo que hay que hacer si la automatizacion deja
' Excel a la vista. La deteccion no puede fallar en el sentido que importaria:
' con Excel visible -- que es como lo ve una persona -- el aviso sale como
' siempre, asi que nadie va a pulsar un boton y quedarse sin respuesta.
'
' LO QUE PREGUNTA NO SE PUEDE CONTESTAR SOLO. Preguntar() no se inventa una
' respuesta desatendida: se le pasa la que corresponde. En el unico sitio que
' pregunta -- guardar el libro antes de que el SQL lo lea del disco -- esa
' respuesta es Cancelar, porque guardar el libro de alguien por iniciativa
' propia y seguir con un CHH que no es el que se esta viendo son justo las dos
' cosas que una corrida automatizada no puede decidir por su cuenta.
'===============================================================================
Option Explicit

Private mDesatendido As Boolean
Private mAviso As String

Public Sub ModoDesatendido(ByVal activo As Boolean)
    mDesatendido = activo
End Sub


Public Function Desatendido() As Boolean
    Desatendido = mDesatendido Or (Not Application.Visible)
End Function


'--- El texto del ultimo aviso, para quien corra esto desde fuera -------------
Public Function UltimoAviso() As String
    UltimoAviso = mAviso
End Function


Public Sub Avisar(ByVal texto As String, _
                  Optional ByVal icono As Long = vbInformation, _
                  Optional ByVal titulo As String = "e-Quilibrium")
    mAviso = titulo & ": " & texto
    Debug.Print mAviso
    If Desatendido() Then Exit Sub
    MsgBox texto, icono, titulo
End Sub


Public Function Preguntar(ByVal texto As String, ByVal botones As Long, _
                          ByVal titulo As String, _
                          ByVal siNoHayNadie As VbMsgBoxResult) As VbMsgBoxResult
    mAviso = titulo & ": " & texto
    Debug.Print mAviso
    If Desatendido() Then
        Preguntar = siNoHayNadie
        Exit Function
    End If
    Preguntar = MsgBox(texto, botones, titulo)
End Function
