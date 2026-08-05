Imports System.Text.Json
Imports System.Text.Json.Nodes

''' <summary>Normalizes Convex's integral JSON numbers for the counter example.</summary>
Public Module CountValue
    Public Function Read(state As JsonNode, operationName As String) As Integer
        Dim value = TryCast(state("count"), JsonValue)
        If value Is Nothing Then Throw InvalidCount(operationName)

        Dim element As JsonElement
        If value.TryGetValue(element) Then
            If element.ValueKind <> JsonValueKind.Number Then Throw InvalidCount(operationName)
            Dim integerValue As Integer
            If element.TryGetInt32(integerValue) Then Return integerValue
            Dim doubleValue As Double
            If element.TryGetDouble(doubleValue) Then Return Normalize(doubleValue, operationName)
            Throw InvalidCount(operationName)
        End If

        Dim directInteger As Integer
        If value.TryGetValue(directInteger) Then Return directInteger
        Dim directLong As Long
        If value.TryGetValue(directLong) AndAlso directLong >= Integer.MinValue AndAlso directLong <= Integer.MaxValue Then Return CInt(directLong)
        Dim directDouble As Double
        If value.TryGetValue(directDouble) Then Return Normalize(directDouble, operationName)
        Throw InvalidCount(operationName)
    End Function

    Private Function Normalize(value As Double, operationName As String) As Integer
        If Double.IsNaN(value) OrElse Double.IsInfinity(value) OrElse value <> Math.Truncate(value) OrElse value < Integer.MinValue OrElse value > Integer.MaxValue Then Throw InvalidCount(operationName)
        Return CInt(value)
    End Function

    Private Function InvalidCount(operationName As String) As InvalidOperationException
        Return New InvalidOperationException(operationName & " did not return a whole Int32 count")
    End Function
End Module
