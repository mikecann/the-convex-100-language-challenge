import ballerina/http;
import ballerina/test;

const int HTTP_FIXTURE_PORT = 27050;

// A minimal loopback Convex HTTP fixture: replies to every /api/* POST with
// one scripted JSON body, in order. Exists only to prove this client decodes
// the documented envelope correctly, including the distinction between an
// explicit JSON `null` value and a success response that omits `value`
// entirely (Convex's spelling for a function that returned `undefined`).
service class ScriptedApi {
    *http:Service;
    private json[] responses;
    private int nextIndex = 0;

    function init(json[] responses) {
        self.responses = responses;
    }

    resource function post api/[string operation](@http:Payload json body) returns json {
        json response = self.responses[self.nextIndex];
        self.nextIndex += 1;
        return response;
    }
}

@test:Config {}
function testHttpDistinguishesNullFromOmittedValueAndPreservesFunctionErrorDetail() returns error? {
    int port = HTTP_FIXTURE_PORT + 1;
    http:Listener fixtureListener = check new (port);
    check fixtureListener.attach(new ScriptedApi([
        {status: "success", value: null, logLines: ["null result"]},
        {status: "success", logLines: []},
        {status: "error", errorMessage: "nope", errorData: null, logLines: ["before failure"]}
    ]), ());
    check fixtureListener.'start();

    Client convexClient = check new ("http://127.0.0.1:" + port.toString());

    CallResult|ConvexError nullResult = convexClient.query("demo:null", {});
    if nullResult is CallResult {
        test:assertEquals(nullResult.value, ());
        test:assertEquals(nullResult.logs, ["null result"]);
    } else {
        test:assertFail("expected a null CallResult, got " + nullResult.message());
    }

    CallResult|ConvexError missingResult = convexClient.query("demo:missing", {});
    if !(missingResult is ProtocolError) {
        test:assertFail("expected a ProtocolError for an omitted value");
    }

    CallResult|ConvexError errorResult = convexClient.query("demo:error", {});
    if errorResult is FunctionError {
        test:assertEquals(errorResult.detail().data, ());
        test:assertEquals(errorResult.detail().logs, ["before failure"]);
    } else {
        test:assertFail("expected a FunctionError");
    }

    ConvexError? closeErr = convexClient.close();
}

@test:Config {}
function testDeploymentUrlRejectsCredentialsAndNonHttpSchemes() {
    DeploymentUrl|ProtocolError withCredentials = parseDeploymentUrl("https://user:pass@example.convex.cloud");
    test:assertTrue(withCredentials is ProtocolError);

    DeploymentUrl|ProtocolError wrongScheme = parseDeploymentUrl("ftp://example.convex.cloud");
    test:assertTrue(wrongScheme is ProtocolError);

    DeploymentUrl|ProtocolError parsed = parseDeploymentUrl("https://usable-reindeer-44.convex.cloud/");
    if parsed is DeploymentUrl {
        test:assertEquals(parsed.host, "usable-reindeer-44.convex.cloud");
        test:assertEquals(parsed.port, 443);
        test:assertEquals(parsed.pathPrefix, "");
    } else {
        test:assertFail("expected a parsed DeploymentUrl");
    }
}
