module transport_test;

import convex : ConvexClient, ConvexError;
import core.thread : Thread;
import std.conv : to;
import std.json : JSONValue;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf;

private void sendAll(Socket peer, string text) {
    size_t sent;
    while (sent < text.length) {
        const written = peer.send(cast(const(ubyte)[]) text[sent .. $]);
        assert(written > 0);
        sent += cast(size_t) written;
    }
}

private string receiveRequest(Socket peer) {
    ubyte[4096] buffer;
    string request;
    while (request.indexOf("\r\n\r\n") < 0 || request.indexOf(`"format":"json"`) < 0) {
        const received = peer.receive(buffer);
        assert(received > 0);
        request ~= cast(string) buffer[0 .. received].idup;
    }
    return request;
}

private string response(string body) {
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " ~
        to!string(body.length) ~ "\r\nConnection: close\r\n\r\n" ~ body;
}

unittest {
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", 18143));
    listener.listen(3);
    string[] requests;
    auto server = new Thread({
        scope(exit) listener.close();
        foreach (number; 0 .. 3) {
            auto peer = listener.accept();
            scope(exit) peer.close();
            requests ~= receiveRequest(peer);
            const body = number == 2
                ? `{"status":"error","errorMessage":"expected failure","errorData":{"code":"EXPECTED"}}`
                : `{"status":"success","value":{"count":0},"logLines":["demo:state"]}`;
            sendAll(peer, response(body));
        }
    });
    server.start();

    auto client = new ConvexClient("http://127.0.0.1:18143/");
    client.setAuth("first-token");
    assert(client.query("demo:state", JSONValue(["room": JSONValue("first")])).value.object["count"].integer == 0);
    client.setAuth("replacement-token");
    assert(client.mutation("demo:state", JSONValue(["room": JSONValue("second")])).logs == ["demo:state"]);
    client.setAuth("");
    bool failed;
    try {
        client.action("demo:state", JSONValue(["room": JSONValue("third")]));
    } catch (ConvexError error) {
        failed = error.kind == "FunctionError" && error.data.object["code"].str == "EXPECTED";
    }
    assert(failed);
    server.join();

    assert(requests.length == 3);
    assert(requests[0].indexOf("POST /api/query HTTP/") >= 0);
    assert(requests[0].indexOf("Authorization: Bearer first-token") >= 0);
    assert(requests[1].indexOf("POST /api/mutation HTTP/") >= 0);
    assert(requests[1].indexOf("Authorization: Bearer replacement-token") >= 0);
    assert(requests[2].indexOf("POST /api/action HTTP/") >= 0);
    assert(requests[2].indexOf("Authorization: Bearer") < 0);
    foreach (request; requests) {
        assert(request.indexOf("Convex-Client: d-0.1.0") >= 0);
        assert(request.indexOf(`"path":"demo:state"`) >= 0);
    }
}
