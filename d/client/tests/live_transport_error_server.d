/** A peer-close Live fixture for a deterministic TransportError wire event. */
module live_transport_error_server;

import std.base64 : Base64;
import core.thread : Thread;
import core.time : msecs;
import std.digest.sha : sha1Of;
import std.file : exists;
import std.json : parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf, splitLines, startsWith, strip;

enum port = 18160;
enum closeGate = "/tmp/d-live-transport-close";

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
    ulong length = header[1] & 0x7f;
    assert(length < 126);
    assert((header[1] & 0x80) != 0);
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

private void sendControl(Socket peer, ubyte opcode, string payload)
{
    auto bytes = cast(const(ubyte)[]) payload;
    assert(bytes.length <= 125);
    ubyte[] frame = [cast(ubyte)(0x80 | opcode), cast(ubyte) bytes.length];
    frame ~= bytes;
    sendAll(peer, frame);
}

private void waitForCloseGate()
{
    foreach (_; 0 .. 400)
    {
        if (closeGate.exists)
            return;
        Thread.sleep(5.msecs);
    }
    assert(false, "adapter did not acknowledge the Live install before Close");
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
    /* The probe creates this gate only after it observes the real adapter ack.
     * The fixture is therefore unable to turn installation failure into a
     * subscription event, while production has no test control at all. */
    waitForCloseGate();
    sendControl(peer, 8, "");
    assert(receiveClientOpcode(peer) == 8);
}
