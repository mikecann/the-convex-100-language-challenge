Imports System.Text.Json.Nodes

Module Program
    Private Function State(value As String) As JsonNode
        Return JsonNode.Parse("{""count"":" & value & "}")
    End Function
    Private Sub Equal(expected As Integer, actual As Integer, message As String)
        If expected <> actual Then Throw New Exception(message)
    End Sub
    Private Sub Reject(state As JsonNode)
        Try
            CountValue.Read(state, "test")
            Throw New Exception("invalid number was accepted")
        Catch expected As InvalidOperationException
        End Try
    End Sub
    Public Sub Main()
        Equal(0, CountValue.Read(State("0"), "integer"), "integer was rejected")
        Equal(0, CountValue.Read(State("0.0"), "decimal"), "integral decimal was rejected")
        Equal(Integer.MinValue, CountValue.Read(State(Integer.MinValue.ToString()), "minimum"), "minimum was rejected")
        Equal(Integer.MaxValue, CountValue.Read(State(Integer.MaxValue.ToString()), "maximum"), "maximum was rejected")
        Reject(State("0.5"))
        Reject(JsonNode.Parse("{""count"":""0""}"))
        Reject(State("2147483648"))
        Console.WriteLine("Visual Basic .NET example count tests passed")
    End Sub
End Module
