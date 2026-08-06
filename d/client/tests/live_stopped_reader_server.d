/** A deterministic Live fixture for the final adapter stopped-reader test. */
module live_stopped_reader_server;

import std.base64 : Base64;
import std.conv : to;
import std.digest.sha : sha1Of;
import std.json : parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.stdio : stderr;
import std.string : indexOf, splitLines, startsWith, strip;

enum port = 18155;
enum nearMaximumValueBytes = 2_000_000;
enum messageCount = 5;

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

private ubyte[] receiveClientText(Socket peer)
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
    return payload;
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
    if (payload.length < 126)
        frame ~= cast(ubyte) payload.length;
    else if (payload.length <= ushort.max)
    {
        frame ~= 126;
        frame ~= cast(ubyte)(payload.length >> 8);
        frame ~= cast(ubyte) payload.length;
    }
    else
    {
        frame ~= 127;
        foreach_reverse (index; 0 .. 8)
            frame ~= cast(ubyte)(cast(ulong) payload.length >> (index * 8));
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

private string versionJson(uint querySet, ulong value)
{
    return `{"querySet":` ~ querySet.to!string ~ `,"identity":0,"ts":"` ~ timestamp(value) ~ `"}`;
}

private string transition(uint startQuerySet, ulong startTs, uint endQuerySet,
        ulong endTs, string payload)
{
    return `{"type":"Transition","startVersion":` ~ versionJson(startQuerySet,
            startTs) ~ `,"endVersion":` ~ versionJson(endQuerySet,
            endTs) ~ `,"modifications":[{"type":"QueryUpdated","queryId":0,"value":"`
        ~ payload ~ `"}]}`;
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
    auto connect = parseJSON(cast(string) receiveClientText(peer));
    assert(connect.object["type"].str == "Connect");
    auto add = parseJSON(cast(string) receiveClientText(peer));
    assert(add.object["type"].str == "ModifyQuerySet");

    auto payload = new char[nearMaximumValueBytes];
    payload[] = 'x';
    foreach (value; 1 .. messageCount + 1)
        sendText(peer, transition(value == 1 ? 0 : 1, value == 1 ? 0 : value - 1, 1,
                value, payload.idup));

    stderr.writefln("sent %s Live messages of %s bytes", messageCount, nearMaximumValueBytes);
}
