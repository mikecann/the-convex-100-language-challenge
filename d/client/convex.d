/**
 * A deliberately small native D Convex HTTP client.
 *
 * The transport comes from Phobos' libcurl binding. The Convex request and
 * response protocol below is implemented here, not delegated to another SDK.
 */
module convex;

import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.algorithm.searching : startsWith;
import std.string : indexOf, stripRight;

enum clientVersion = "d-0.1.0";
enum maxResponseBytes = 2 * 1024 * 1024;

struct ConvexResult {
    JSONValue value;
    string[] logs;
}

class ConvexError : Exception {
    string kind;
    JSONValue data;
    string[] logs;

    this(string kind, string message, JSONValue data = JSONValue.init,
            string[] logs = []) {
        super(message);
        this.kind = kind;
        this.data = data;
        this.logs = logs;
    }
}

/** Keep the public API compact while preserving the error details supplied by
 * Convex. A client may replace or clear its bearer token between calls. */
class ConvexClient {
    private string deployment;
    private string token;
    private bool closed;

    this(string deploymentUrl) {
        deployment = normalizeDeployment(deploymentUrl);
    }

    void setAuth(string bearerToken) {
        ensureOpen();
        token = bearerToken;
    }

    ConvexResult query(string path, JSONValue args) {
        return call("query", path, args);
    }

    ConvexResult mutation(string path, JSONValue args) {
        return call("mutation", path, args);
    }

    ConvexResult action(string path, JSONValue args) {
        return call("action", path, args);
    }

    void close() {
        closed = true;
        token = "";
    }

    private ConvexResult call(string operation, string path, JSONValue args) {
        ensureOpen();
        if (path.length == 0)
            throw new ConvexError("ProtocolError", "Convex function path is required");
        if (args.type != JSONType.object)
            throw new ConvexError("ProtocolError", "Convex arguments must be a JSON object");

        JSONValue[string] request;
        request["path"] = JSONValue(path);
        request["args"] = args;
        request["format"] = JSONValue("json");
        return decodeResponse(operation, requestJson(deployment ~ "/api/" ~ operation, JSONValue(request)));
    }

    private void ensureOpen() {
        if (closed)
            throw new ConvexError("Error", "Convex client is closed");
    }

    private string requestJson(string endpoint, JSONValue body) {
        auto encoded = body.toString();
        auto http = HTTP();
        http.url = endpoint;
        http.addRequestHeader("Accept", "application/json");
        http.addRequestHeader("Convex-Client", clientVersion);
        if (token.length > 0)
            http.addRequestHeader("Authorization", "Bearer " ~ token);
        http.setPostData(encoded, "application/json");

        ubyte[] response;
        http.onReceive = (ubyte[] bytes) {
            if (response.length + bytes.length > maxResponseBytes)
                return cast(size_t) 0;
            response ~= bytes;
            return bytes.length;
        };
        try {
            http.perform();
        } catch (Exception error) {
            throw new ConvexError("TransportError", error.msg);
        }
        return cast(string) response.idup;
    }
}

/** Decode is separate from transport so its success, function-error, malformed
 * response, and log handling can be checked without a network fixture. */
ConvexResult decodeResponse(string operation, string responseBody) {
    JSONValue response;
    try {
        response = parseJSON(responseBody);
    } catch (Exception error) {
        throw new ConvexError("ProtocolError", "HTTP response was not valid Convex JSON");
    }
    if (response.type != JSONType.object || "status" !in response.object)
        throw new ConvexError("ProtocolError", "HTTP response had an unknown status");

    auto status = response.object["status"];
    if (status.type != JSONType.string)
        throw new ConvexError("ProtocolError", "HTTP response had an unknown status");
    auto logs = responseLogs(response);
    if (status.str == "success") {
        if ("value" !in response.object)
            throw new ConvexError("ProtocolError", "HTTP success response omitted value");
        return ConvexResult(response.object["value"], logs);
    }
    if (status.str == "error") {
        JSONValue data = "errorData" in response.object
            ? response.object["errorData"] : JSONValue.init;
        string message = "errorMessage" in response.object &&
                response.object["errorMessage"].type == JSONType.string
            ? response.object["errorMessage"].str : "Convex function failed";
        throw new ConvexError("FunctionError", message, data, logs);
    }
    throw new ConvexError("ProtocolError", "HTTP response had an unknown status");
}

private string[] responseLogs(JSONValue response) {
    string[] logs;
    if ("logLines" !in response.object || response.object["logLines"].type != JSONType.array)
        return logs;
    foreach (line; response.object["logLines"].array) {
        if (line.type == JSONType.string)
            logs ~= line.str;
    }
    return logs;
}

private string normalizeDeployment(string value) {
    auto trimmed = value.stripRight("/");
    if (!(trimmed.startsWith("http://") || trimmed.startsWith("https://")))
        throw new ConvexError("ProtocolError", "Convex deployment URL must use http or https");
    auto afterScheme = trimmed.indexOf("://") + 3;
    if (afterScheme >= trimmed.length || trimmed[afterScheme .. $].length == 0 ||
            trimmed[afterScheme .. $].indexOf('@') >= 0)
        throw new ConvexError("ProtocolError", "Convex deployment URL must include a host and no credentials");
    return trimmed;
}
