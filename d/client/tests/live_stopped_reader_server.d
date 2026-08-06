/** A gated Live fixture for final-adapter retention and backpressure proof. */
module live_stopped_reader_server;

import core.thread : Thread;
import core.time : msecs;
import std.base64 : Base64;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.digest.sha : sha1Of;
import std.file : exists, write;
import std.json : parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.stdio : stderr;
import std.string : indexOf, splitLines, startsWith, strip;

enum port = 18155;
enum smallValueBytes = 128 * 1024;
enum nearMaximumValueBytes = 1_750_000;
enum countLastSequence = 18;
enum byteFirstSequence = 101;
enum byteLastSequence = 105;

enum countStartGate = "/tmp/d-live-count-start";
enum countFirstSent = "/tmp/d-live-count-first-sent";
enum countBurstGate = "/tmp/d-live-count-burst";
enum countDone = "/tmp/d-live-count-done";
enum byteStartGate = "/tmp/d-live-byte-start";
enum byteFirstSent = "/tmp/d-live-byte-first-sent";
enum byteBurstGate = "/tmp/d-live-byte-burst";
enum byteDone = "/tmp/d-live-byte-done";
enum finishGate = "/tmp/d-live-finish";

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

private string receiveClientControl(Socket peer, ubyte expectedOpcode)
{
    auto header = receiveExact(peer, 2);
    assert((header[0] & 0x0f) == expectedOpcode);
    auto length = header[1] & 0x7f;
    assert(length < 126 && (header[1] & 0x80) != 0);
    auto mask = receiveExact(peer, 4);
    auto payload = receiveExact(peer, cast(size_t) length);
    foreach (index, ref octet; payload)
        octet ^= mask[index % 4];
    return cast(string) payload;
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

private void sendControl(Socket peer, ubyte opcode, string payload)
{
    auto bytes = cast(const(ubyte)[]) payload;
    assert(bytes.length <= 125);
    ubyte[] frame = [cast(ubyte)(0x80 | opcode), cast(ubyte) bytes.length];
    frame ~= bytes;
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
        ulong endTs, uint sequence, string payload)
{
    return `{"type":"Transition","startVersion":` ~ versionJson(startQuerySet,
            startTs) ~ `,"endVersion":` ~ versionJson(endQuerySet,
            endTs) ~ `,"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"sequence":`
        ~ sequence.to!string ~ `,"payload":"` ~ payload ~ `"}}]}`;
}

private void waitForGate(string path)
{
    StopWatch timer;
    timer.start();
    while (!exists(path))
    {
        assert(timer.peek.total!"msecs" < 5_000);
        Thread.sleep(5.msecs);
    }
}

private void mark(string path)
{
    write(path, "ready");
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

    // The controller does not read after the acknowledgement. Make the first
    // count event near the Live frame limit so it cannot all sit in TCP's
    // receive buffers. Subsequent small values isolate the queue's count
    // eviction from its independent encoded-byte budget.
    auto firstCountPayload = new char[nearMaximumValueBytes];
    firstCountPayload[] = 's';
    auto smallPayload = new char[smallValueBytes];
    smallPayload[] = 's';
    waitForGate(countStartGate);
    sendText(peer, transition(0, 0, 1, 1, 1, firstCountPayload.idup));
    mark(countFirstSent);
    waitForGate(countBurstGate);
    foreach (uint sequence; 2 .. countLastSequence + 1)
    {
        sendText(peer, transition(1, sequence - 1, 1, sequence, sequence, smallPayload.idup));
        /* The real owner must decode and commit each transition before the
         * fixture writes another one, while the controller stays stopped. */
        sendControl(peer, 9, "count-decoded");
        assert(receiveClientControl(peer, 10) == "count-decoded");
    }
    mark(countDone);

    auto largePayload = new char[nearMaximumValueBytes];
    largePayload[] = 'x';
    waitForGate(byteStartGate);
    sendText(peer, transition(1, countLastSequence, 1, byteFirstSequence,
            byteFirstSequence, largePayload.idup));
    mark(byteFirstSent);
    waitForGate(byteBurstGate);
    foreach (uint sequence; byteFirstSequence + 1 .. byteLastSequence + 1)
    {
        sendText(peer, transition(1, sequence - 1, 1, sequence, sequence, largePayload.idup));
        sendControl(peer, 9, "bytes-decoded");
        assert(receiveClientControl(peer, 10) == "bytes-decoded");
    }
    mark(byteDone);

    waitForGate(finishGate);
    /* The controller's close command shuts down the shared Live client, so
     * final transport cleanup is an RFC6455 Close instead of query removal. */
    assert(receiveClientControl(peer, 8).length == 0);
    stderr.writefln("sent count and encoded-byte retention bursts through Live");
}
