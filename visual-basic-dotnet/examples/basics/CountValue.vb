Imports System.Globalization
Imports System.Numerics
Imports System.Text.Json
Imports System.Text.Json.Nodes

''' <summary>Parses Convex JSON numbers exactly, without a Double rounding step.</summary>
Public Module CountValue
    Public Function Read(state As JsonNode, operationName As String) As Integer
        Dim value = TryCast(state("count"), JsonValue)
        If value Is Nothing Then Throw InvalidCount(operationName)

        Dim element As JsonElement
        If value.TryGetValue(element) Then
            If element.ValueKind <> JsonValueKind.Number Then Throw InvalidCount(operationName)
            Return ParseExact(element.GetRawText(), operationName)
        End If

        Dim directInteger As Integer
        If value.TryGetValue(directInteger) Then Return directInteger
        Dim directLong As Long
        If value.TryGetValue(directLong) Then Return CheckedInteger(New BigInteger(directLong), operationName)
        Dim directDecimal As Decimal
        If value.TryGetValue(directDecimal) Then Return ParseExact(directDecimal.ToString(CultureInfo.InvariantCulture), operationName)
        Dim directBigInteger As BigInteger
        If value.TryGetValue(directBigInteger) Then Return CheckedInteger(directBigInteger, operationName)
        Throw InvalidCount(operationName)
    End Function

    Private Function ParseExact(raw As String, operationName As String) As Integer
        Dim cursor As Integer
        Dim negative As Boolean
        If raw.StartsWith("-", StringComparison.Ordinal) Then
            negative = True
            cursor = 1
        End If

        Dim exponentIndex = raw.IndexOfAny({"e"c, "E"c}, cursor)
        Dim significand = If(exponentIndex < 0, raw.Substring(cursor), raw.Substring(cursor, exponentIndex - cursor))
        Dim exponent As Long
        If exponentIndex >= 0 AndAlso Not Long.TryParse(raw.Substring(exponentIndex + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, exponent) Then Throw InvalidCount(operationName)

        Dim decimalIndex = significand.IndexOf("."c)
        Dim fractionalDigits = If(decimalIndex < 0, 0, significand.Length - decimalIndex - 1)
        Dim digits = significand.Replace(".", "", StringComparison.Ordinal).TrimStart("0"c)
        If digits.Length = 0 Then Return 0
        If digits.Any(Function(character) character < "0"c OrElse character > "9"c) Then Throw InvalidCount(operationName)

        If exponent < -1000 OrElse exponent > 1000 Then Throw InvalidCount(operationName)
        Dim scale = CLng(fractionalDigits) - exponent

        If scale > 0 Then
            If scale >= digits.Length Then Throw InvalidCount(operationName)
            Dim trailing = CInt(scale)
            If digits.Substring(digits.Length - trailing).Any(Function(character) character <> "0"c) Then Throw InvalidCount(operationName)
            digits = digits.Substring(0, digits.Length - trailing)
        ElseIf scale < 0 Then
            Dim zeros = -scale
            If zeros > 10 OrElse digits.Length + zeros > 11 Then Throw InvalidCount(operationName)
            digits &= New String("0"c, CInt(zeros))
        End If

        Dim parsed As BigInteger
        If Not BigInteger.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, parsed) Then Throw InvalidCount(operationName)
        If negative Then parsed = BigInteger.Negate(parsed)
        Return CheckedInteger(parsed, operationName)
    End Function

    Private Function CheckedInteger(value As BigInteger, operationName As String) As Integer
        If value < Integer.MinValue OrElse value > Integer.MaxValue Then Throw InvalidCount(operationName)
        Return CInt(value)
    End Function

    Private Function InvalidCount(operationName As String) As InvalidOperationException
        Return New InvalidOperationException(operationName & " did not return a whole Int32 count")
    End Function
End Module
