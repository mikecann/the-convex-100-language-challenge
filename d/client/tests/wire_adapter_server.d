/** Deterministic HTTP outcomes for final adapter NDJSON wire assertions. */
module wire_adapter_server;

import std.conv : to;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf;

enum port = 18156;

private void sendAll(Socket peer, string text)
{
    size_t sent;
    while (sent < text.length)
    {
        auto written = peer.send(cast(const(ubyte)[]) text[sent .. $]);
        assert(written > 0);
        sent += cast(size_t) written;
    }
}

private void receiveRequest(Socket peer)
{
    ubyte[4096] buffer;
    string request;
    while (request.indexOf("\r\n\r\n") < 0 || request.indexOf(`"format":"json"`) < 0)
    {
        auto received = peer.receive(buffer);
        assert(received > 0);
        request ~= cast(string) buffer[0 .. received].idup;
    }
    assert(request.indexOf("POST /api/query HTTP/") >= 0);
}

private string response(string body)
{
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        ~ body.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ body;
}

void main()
{
    auto listener = new TcpSocket();
    scope (exit)
        listener.close();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(3);
    foreach (number; 0 .. 3)
    {
        auto peer = listener.accept();
        scope (exit)
            peer.close();
        receiveRequest(peer);
        final switch (number)
        {
        case 0:
            sendAll(peer, response(`{"status":"success","value":{"count":1}}`));
            break;
        case 1:
            sendAll(peer, response(`{"status":"error","errorMessage":"function absent"}`));
            break;
        case 2:
            sendAll(peer,
                    response(
                        `{"status":"error","errorMessage":"function data","errorData":{"code":"BAD"}}`));
            break;
        }
    }
}
