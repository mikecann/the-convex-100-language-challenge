using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Convex;

/// <summary>Small native client for Convex's JSON HTTP functions API.</summary>
public sealed class ConvexClient : IDisposable
{
    private readonly Uri _base;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private string _token = "";
    private bool _closed;

    public ConvexClient(string deployment)
    {
        if (
            !Uri.TryCreate(deployment.TrimEnd('/'), UriKind.Absolute, out var uri)
            || (uri.Scheme != "http" && uri.Scheme != "https")
            || !string.IsNullOrEmpty(uri.UserInfo)
        )
            throw new ArgumentException(
                "Convex deployment URL must be http(s), have a host, and omit user info"
            );
        _base = uri;
    }

    public void SetAuth(string? token)
    {
        EnsureOpen();
        _token = token ?? "";
    }

    public Task<Result> Query(string path, JsonObject args) => Call("query", path, args);

    public Task<Result> Mutation(string path, JsonObject args) => Call("mutation", path, args);

    public Task<Result> Action(string path, JsonObject args) => Call("action", path, args);

    private async Task<Result> Call(string operation, string path, JsonObject args)
    {
        EnsureOpen();
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("Convex function path is required");
        // JsonNode values may have only one parent. Clone caller-owned arguments
        // so the same object remains reusable across any number of calls.
        var request = new HttpRequestMessage(HttpMethod.Post, new Uri(_base, "/api/" + operation))
        {
            Content = JsonContent.Create(
                new JsonObject
                {
                    ["path"] = path,
                    ["args"] = args.DeepClone(),
                    ["format"] = "json",
                }
            ),
        };
        request.Headers.TryAddWithoutValidation("Convex-Client", "csharp-0.1.0");
        if (_token.Length != 0)
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _token);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request);
        }
        catch (Exception e)
        {
            throw new TransportException(operation, e);
        }
        JsonObject decoded;
        try
        {
            decoded =
                (await response.Content.ReadFromJsonAsync<JsonObject>())
                ?? throw new Exception("empty response");
        }
        catch (Exception e)
        {
            throw new TransportException(operation, new Exception("non-Convex HTTP response", e));
        }
        var logs =
            decoded["logLines"]?.AsArray().Select(x => x?.GetValue<string>() ?? "").ToArray() ?? [];
        if (decoded["status"]?.GetValue<string>() == "success")
        {
            if (!decoded.ContainsKey("value"))
                throw new ProtocolException("success response omitted value");
            return new Result(decoded["value"]?.DeepClone(), logs);
        }
        if (decoded["status"]?.GetValue<string>() == "error")
            throw new FunctionException(
                operation,
                decoded["errorMessage"]?.GetValue<string>() ?? "Convex function failed",
                decoded["errorData"],
                logs
            );
        throw new ProtocolException($"HTTP {(int)response.StatusCode} response has unknown status");
    }

    private void EnsureOpen()
    {
        if (_closed)
            throw new ObjectDisposedException(nameof(ConvexClient));
    }

    public void Dispose()
    {
        _closed = true;
        _http.Dispose();
    }

    public record Result(JsonNode? Value, IReadOnlyList<string> Logs);

    public sealed class FunctionException(
        string operation,
        string message,
        JsonNode? data,
        IReadOnlyList<string> logs
    ) : Exception(message)
    {
        public string Operation { get; } = operation;
        public JsonNode? ErrorData { get; } = data;
        public IReadOnlyList<string> Logs { get; } = logs;
    }

    public sealed class TransportException(string operation, Exception inner)
        : Exception(inner.Message, inner)
    {
        public string Operation { get; } = operation;
    }

    public sealed class ProtocolException(string message) : Exception(message);
}
