import ballerina/http;

// Convex's documented JSON HTTP envelope for query/mutation/action. This is a
// normal, actively-maintained Ballerina standard library client - unlike
// `ballerina/websocket`, nothing here is suspected or known to be broken, so
// it is used as-is rather than hand-rolled (see ws_frame.bal for the one
// piece of transport this client does write by hand, and why).

type WireSuccess record {|
    "success" status;
    json value = ();
    string[] logLines = [];
|};

type WireFailure record {|
    "error" status;
    string errorMessage = "Convex function failed";
    json errorData = ();
    string[] logLines = [];
|};

# Issues one `query`, `mutation`, or `action` call. `operation` selects both
# the Convex HTTP endpoint (`/api/{operation}`) and the label attached to a
# `FunctionError`.
function callHttp(http:Client httpClient, string operation, string path, json args, string authToken) returns CallResult|ConvexError {
    if path.length() == 0 {
        return error ProtocolError("function path is required", logs = []);
    }
    if !(args is map<json>) {
        return error ProtocolError("function arguments must be a JSON object", logs = []);
    }

    http:Request request = new;
    request.setJsonPayload({path, args, format: "json"});
    request.setHeader("Convex-Client", "ballerina-0.1.0");
    request.setHeader("Accept", "application/json");
    if authToken.length() > 0 {
        request.setHeader("Authorization", "Bearer " + authToken);
    }

    http:Response|http:ClientError response = httpClient->post("/api/" + operation, request);
    if response is http:ClientError {
        return error TransportError(operation + ": " + response.message(), logs = []);
    }

    json|error payload = response.getJsonPayload();
    if payload is error {
        return error TransportError(operation + ": non-Convex response: " + payload.message(), logs = []);
    }

    map<json> body = payload is map<json> ? payload : {};
    json status = body["status"];
    if status == "success" {
        WireSuccess|error success = payload.cloneWithType();
        if success is error {
            return error ProtocolError("success response did not match the expected shape: " + success.message(), logs = []);
        }
        // Convex omits `value` entirely for a function that returns
        // `undefined`; treat that as distinct from an explicit JSON null by
        // checking the raw payload rather than the always-present typed field.
        if !body.hasKey("value") {
            return error ProtocolError("success omitted value", logs = success.logLines);
        }
        return {value: success.value, logs: success.logLines};
    }
    if status == "error" {
        WireFailure|error failure = payload.cloneWithType();
        if failure is error {
            return error ProtocolError("error response did not match the expected shape: " + failure.message(), logs = []);
        }
        return error FunctionError(failure.errorMessage, operation = operation, data = failure.errorData, logs = failure.logLines);
    }
    return error ProtocolError("unknown response status", logs = []);
}
