/** A deterministic HTTP fixture for the adapter's stopped-reader test. */
module stopped_reader_server;

import std.conv : to;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf;

private void sendAll(Socket peer, string value)
{
    size_t offset;
    while (offset < value.length)
    {
        auto sent = peer.send(cast(const(ubyte)[]) value[offset .. $]);
        assert(sent > 0);
        offset += cast(size_t) sent;
    }
}

void main()
{
    auto listener = new TcpSocket();
    scope (exit)
        listener.close();
    listener.bind(new InternetAddress("127.0.0.1", 18153));
    listener.listen(1);
    auto peer = listener.accept();
    scope (exit)
        peer.close();

    string request;
    ubyte[16_384] bytes;
    while (request.indexOf("\r\n\r\n") < 0 || request.indexOf(`"format":"json"`) < 0)
    {
        auto received = peer.receive(bytes);
        assert(received > 0);
        request ~= cast(string) bytes[0 .. received].idup;
    }

    auto payload = new char[1_900_000];
    payload[] = 'x';
    auto body = `{"status":"success","value":"` ~ payload.idup ~ `"}`;
    auto response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        ~ body.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ body;
    sendAll(peer, response);
}
