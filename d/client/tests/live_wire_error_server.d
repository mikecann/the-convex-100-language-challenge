/** A single real Live QueryFailed event for adapter NDJSON wire assertions. */
module live_wire_error_server;

import std.base64 : Base64;
import std.conv : to;
import std.digest.sha : sha1Of;
import std.json : parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf, splitLines, startsWith, strip;

enum port = 18157;

private void sendAll(Socket peer, const(ubyte)[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        auto sent = peer.send(bytes[offset .. $]);
        assert(sent > 0);
        offset += cast(size_t) sent;
    }
}

private ubyte[] receiveExact(Socket peer, size_t length)
{
    auto bytes = new ubyte[length];
    size_t offset;
    while (offset < length)
    {
        auto received = peer.receive(bytes[offset .. $]);
        assert(received > 0);
        offset += cast(size_t) received;
    }
    return bytes;
}

private string receiveClientText(Socket peer)
{
    auto header = receiveExact(peer, 2);
    assert((header[0] & 0x0f) == 1);
    ulong length = header[1] & 0x7f;
    if (length == 126)
    {
        auto extended = receiveExact(peer, 2);
        length = (cast(ulong) extended[0] << 8) | extended[1];
    }
    else if (length == 127)
    {
        length = 0;
        foreach (octet; receiveExact(peer, 8))
            length = (length << 8) | octet;
    }
    assert((header[1] & 0x80) != 0);
    auto mask = receiveExact(peer, 4);
    auto payload = receiveExact(peer, cast(size_t) length);
    foreach (index, ref octet; payload)
        octet ^= mask[index % 4];
    return cast(string) payload;
}

private ubyte receiveClientOpcode(Socket peer)
{
    auto header = receiveExact(peer, 2);
    auto opcode = cast(ubyte)(header[0] & 0x0f);
    auto length = header[1] & 0x7f;
    assert(length < 126 && (header[1] & 0x80) != 0);
    auto mask = receiveExact(peer, 4);
    auto payload = receiveExact(peer, cast(size_t) length);
    foreach (index, ref octet; payload)
        octet ^= mask[index % 4];
    return opcode;
}

private void handshake(Socket peer)
{
    ubyte[4096] chunk;
    string request;
    while (request.indexOf("\r\n\r\n") < 0)
    {
        auto received = peer.receive(chunk);
        assert(received > 0);
        request ~= cast(string) chunk[0 .. received].idup;
    }
    string key;
    foreach (line; request.splitLines())
    {
        if (line.startsWith("Sec-WebSocket-Key:"))
            key = line[18 .. $].strip;
    }
    assert(key.length > 0);
    auto digest = sha1Of(cast(const(ubyte)[])(key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
    auto accept = Base64.encode(digest).idup;
    sendAll(peer, cast(const(ubyte)[])("HTTP/1.1 101 Switching Protocols\r\n"
            ~ "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            ~ "Sec-WebSocket-Accept: " ~ accept ~ "\r\n\r\n"));
}

private void sendText(Socket peer, string text)
{
    auto payload = cast(const(ubyte)[]) text;
    ubyte[] frame = [cast(ubyte) 0x81];
    assert(payload.length <= ushort.max);
    if (payload.length < 126)
        frame ~= cast(ubyte) payload.length;
    else
    {
        frame ~= 126;
        frame ~= cast(ubyte)(payload.length >> 8);
        frame ~= cast(ubyte) payload.length;
    }
    frame ~= payload;
    sendAll(peer, frame);
}

private string timestamp(ulong value)
{
    ubyte[8] bytes;
    foreach (index; 0 .. bytes.length)
        bytes[index] = cast(ubyte)(value >> (index * 8));
    return Base64.encode(bytes).idup;
}

void main()
{
    auto listener = new TcpSocket();
    scope (exit)
        listener.close();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(1);
    auto peer = listener.accept();
    scope (exit)
        peer.close();

    handshake(peer);
    auto connect = parseJSON(receiveClientText(peer));
    assert(connect.object["type"].str == "Connect");
    auto add = parseJSON(receiveClientText(peer));
    assert(add.object["type"].str == "ModifyQuerySet");
    auto version0 = `{"querySet":0,"identity":0,"ts":"` ~ timestamp(0) ~ `"}`;
    auto version1 = `{"querySet":1,"identity":0,"ts":"` ~ timestamp(1) ~ `"}`;
    sendText(peer, `{"type":"Transition","startVersion":` ~ version0 ~ `,"endVersion":` ~ version1
            ~ `,"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"subscription failed"}]}`);
    /* The adapter's close command closes the shared Live client, so this is
     * an RFC6455 Close rather than a query-set Remove after an error event. */
    assert(receiveClientOpcode(peer) == 8);
}
