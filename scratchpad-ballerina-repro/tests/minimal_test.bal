import ballerina/http;
import ballerina/io;
import ballerina/test;

listener http:Listener echoListener = new (19999);

service /echo on echoListener {
    resource function post ping(http:Request request) returns http:Response|error {
        json|http:ClientError body = request.getJsonPayload();
        http:Response response = new;
        response.statusCode = 200;
        response.setJsonPayload({"pong": true});
        return response;
    }
}

@test:Config {}
function clientCanReachLocalListener() returns error? {
    io:println("DEBUG before client construct");
    http:ClientConfiguration httpConfig = {
        httpVersion: http:HTTP_1_1,
        responseLimits: {maxEntityBodySize: 1024 * 1024}
    };
    http:Client c = check new ("http://127.0.0.1:19999", httpConfig);
    io:println("DEBUG client constructed");
    http:Response|http:ClientError response = c->post("/echo/ping", {});
    io:println("DEBUG response received");
    if response is http:ClientError {
        return error("client error: " + response.message());
    }
    json body = check response.getJsonPayload();
    test:assertEquals(body, {"pong": true});
}
