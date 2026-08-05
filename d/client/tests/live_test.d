module live_test;

import convex : ConvexClient, ConvexError, LiveUpdate;

version (ConvexAdapter) import convex : adapterDebugDisconnect;
import core.thread : Thread;
import core.time : msecs;
import std.base64 : Base64;
import std.conv : to;
import std.digest.sha : sha1Of;
import std.json : JSONValue, parseJSON;
import std.socket : InternetAddress, Socket, TcpSocket;
import std.string : indexOf, splitLines, startsWith, strip;

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

private void sendAll(Socket peer, string text)
{
    sendAll(peer, cast(const(ubyte)[]) text);
}

private ubyte[] receiveExact(Socket peer, size_t length)
{
    ubyte[] bytes = new ubyte[length];
    size_t offset;
    while (offset < length)
    {
        auto received = peer.receive(bytes[offset .. $]);
        assert(received > 0);
        offset += cast(size_t) received;
    }
    return bytes;
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
    sendAll(peer, "HTTP/1.1 101 Switching Protocols\r\n"
            ~ "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            ~ "Sec-WebSocket-Accept: " ~ accept ~ "\r\n\r\n");
}

private struct RawFrame
{
    ubyte opcode;
    ubyte[] payload;
}

private RawFrame receiveFrame(Socket peer)
{
    auto header = receiveExact(peer, 2);
    auto opcode = cast(ubyte)(header[0] & 0x0f);
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
    return RawFrame(opcode, payload);
}

private string receiveText(Socket peer)
{
    auto frame = receiveFrame(peer);
    assert(frame.opcode == 1);
    return cast(string) frame.payload;
}

private void sendFrame(Socket peer, bool finalFrame, ubyte opcode, const(ubyte)[] payload)
{
    ubyte[] frame;
    frame ~= cast(ubyte)((finalFrame ? 0x80 : 0) | opcode);
    if (payload.length < 126)
    {
        frame ~= cast(ubyte) payload.length;
    }
    else
    {
        frame ~= 126;
        frame ~= cast(ubyte)(payload.length >> 8);
        frame ~= cast(ubyte) payload.length;
    }
    frame ~= payload;
    sendAll(peer, frame);
}

private void sendText(Socket peer, string text)
{
    sendFrame(peer, true, 1, cast(const(ubyte)[]) text);
}

private string timestamp(ulong value)
{
    ubyte[8] bytes;
    foreach (index; 0 .. bytes.length)
        bytes[index] = cast(ubyte)(value >> (index * 8));
    return Base64.encode(bytes).idup;
}

private string versionJson(uint querySet, ulong ts)
{
    return `{"querySet":` ~ querySet.to!string ~ `,"identity":0,"ts":"` ~ timestamp(ts) ~ `"}`;
}

private string transition(uint startQuerySet, ulong startTs, uint endQuerySet,
        ulong endTs, string modifications)
{
    return `{"type":"Transition","startVersion":` ~ versionJson(startQuerySet,
            startTs) ~ `,"endVersion":` ~ versionJson(endQuerySet,
            endTs) ~ `,"modifications":` ~ modifications ~ `}`;
}

unittest
{
    enum port = 18144;
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(1);
    auto server = new Thread({
        scope (exit)
            listener.close();
        auto peer = listener.accept();
        scope (exit)
            peer.close();
        handshake(peer);
        auto connect = parseJSON(receiveText(peer));
        assert(connect.object["type"].str == "Connect");
        assert(connect.object["connectionCount"].integer == 0);
        assert("maxObservedTimestamp" !in connect.object);
        auto add = parseJSON(receiveText(peer));
        assert(add.object["type"].str == "ModifyQuerySet");
        assert(add.object["baseVersion"].integer == 0);
        assert(add.object["newVersion"].integer == 1);
        assert(add.object["modifications"].array[0].object["type"].str == "Add");
        assert(add.object["modifications"].array[0].object["udfPath"].str == "demo:state");
        sendText(peer, transition(0, 0, 1, 1,
            `[{"type":"QueryUpdated","queryId":0,"value":{"count":99}},`
            ~ `{"type":"QueryUpdated","queryId":0,"value":{"count":0},"logLines":["initial"]}]`));
        sendText(peer, transition(1, 1, 1, 2, `[{"type":"QueryFailed","queryId":0,"errorMessage":"expected","errorData":{"code":"BROKEN"},"logLines":["failed"]}]`));
        auto recovery = transition(1, 2, 1, 256,
            `[{"type":"QueryUpdated","queryId":0,"value":{"count":1},"logLines":["recovered ☃"]}]`);
        size_t split;
        foreach (index, octet; cast(const(ubyte)[]) recovery)
            if (octet == 0xE2)
            {
                split = index + 1;
                break;
            }
        assert(split > 0);
        sendFrame(peer, false, 1, cast(const(ubyte)[]) recovery[0 .. split]);
        sendFrame(peer, true, 9, cast(const(ubyte)[]) "ping");
        sendFrame(peer, true, 0, cast(const(ubyte)[]) recovery[split .. $]);
        auto pong = receiveFrame(peer);
        assert(pong.opcode == 10 && cast(string) pong.payload == "ping");
        auto remove = parseJSON(receiveText(peer));
        assert(remove.object["baseVersion"].integer == 1);
        assert(remove.object["newVersion"].integer == 2);
        assert(remove.object["modifications"].array[0].object["type"].str == "Remove");
    });
    server.start();

    auto client = new ConvexClient("http://127.0.0.1:" ~ port.to!string);
    auto subscription = client.subscribe("demo:state", JSONValue([
        "room": JSONValue("fixture")
    ]));
    auto initial = subscription.next(2_000);
    assert(initial !is null && initial.hasValue
            && initial.value.object["count"].integer == 0 && initial.logs == [
                "initial"
    ]);
    auto failed = subscription.next(2_000);
    assert(failed !is null && failed.error !is null
            && failed.error.kind == "FunctionError"
            && failed.error.data.object["code"].str == "BROKEN" && failed.logs == [
                "failed"
    ]);
    auto recovered = subscription.next(2_000);
    assert(recovered !is null && recovered.hasValue
            && recovered.value.object["count"].integer == 1 && recovered.logs == [
                "recovered ☃"
    ]);
    subscription.close();
    client.close();
    server.join();
}

version (ConvexAdapter) unittest
{
    enum port = 18145;
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(2);
    auto server = new Thread({
        scope (exit)
            listener.close();
        foreach (connection; 0 .. 6)
        {
            auto peer = listener.accept();
            handshake(peer);
            auto connect = parseJSON(receiveText(peer));
            assert(connect.object["connectionCount"].integer == connection);
            if (connection == 0)
            {
                assert("maxObservedTimestamp" !in connect.object);
            }
            else
            {
                assert(connect.object["lastCloseReason"].str == "DebugDisconnect");
                assert(connect.object["maxObservedTimestamp"].str == timestamp(1));
            }
            auto add = parseJSON(receiveText(peer));
            assert(add.object["baseVersion"].integer == 0);
            assert(add.object["newVersion"].integer == 1);
            assert(add.object["modifications"].array.length == 1);
            sendText(peer, transition(0, 0, 1, 1,
                `[{"type":"QueryUpdated","queryId":0,"value":{"count":0}}]`));
            if (connection == 5)
            {
                Thread.sleep(150.msecs);
                /* Crossing 255 -> 256 also proves timestamp maxima use the
                 * decoded little-endian integer, not lexicographic bytes. */
                sendText(peer, transition(1, 1, 1, 256,
                    `[{"type":"QueryUpdated","queryId":0,"value":{"count":1}}]`));
            }
            ubyte[32] ignored;
            peer.receive(ignored);
            peer.close();
        }
    });
    server.start();

    auto client = new ConvexClient("http://127.0.0.1:" ~ port.to!string);
    auto subscription = client.subscribe("demo:state", JSONValue([
        "room": JSONValue("reconnect")
    ]));
    auto initial = subscription.next(2_000);
    assert(initial !is null && initial.hasValue && initial.value.object["count"].integer == 0);
    foreach (_; 0 .. 5)
    {
        adapterDebugDisconnect(client);
        Thread.sleep(300.msecs);
    }
    auto changed = subscription.next(2_000);
    assert(changed !is null && changed.hasValue && changed.value.object["count"].integer == 1);
    assert(subscription.next(50) is null);
    client.close();
    server.join();
}

unittest
{
    enum port = 18146;
    ubyte[][] malformed = [
        [0x81, 126, 0, 2, cast(ubyte) '{', cast(ubyte) '}'],
        [0x81, 0x82, 1, 2, 3, 4, cast(ubyte)('{' ^ 1), cast(ubyte)('}' ^ 2)],
        [0x09, 0], [0x83, 0], [0x81, 1, 0xff], [0x82, 0]
    ];
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", port));
    listener.listen(2);
    auto server = new Thread({
        scope (exit)
            listener.close();
        foreach (connection; 0 .. malformed.length + 1)
        {
            auto peer = listener.accept();
            handshake(peer);
            auto connect = parseJSON(receiveText(peer));
            assert(connect.object["connectionCount"].integer == connection);
            assert("maxObservedTimestamp" !in connect.object);
            auto add = parseJSON(receiveText(peer));
            assert(add.object["modifications"].array[0].object["type"].str == "Add");
            if (connection < malformed.length)
            {
                /* A complete Ping is valid traffic and resets retry backoff;
                 * the following malformed frame must still retire the socket. */
                sendFrame(peer, true, 9, cast(const(ubyte)[]) "ok");
                auto pong = receiveFrame(peer);
                assert(pong.opcode == 10 && cast(string) pong.payload == "ok");
                sendAll(peer, malformed[connection]);
            }
            else
            {
                sendText(peer, transition(0, 0, 1, 1,
                    `[{"type":"QueryUpdated","queryId":0,"value":{"count":7}}]`));
            }
            ubyte[32] ignored;
            peer.receive(ignored);
            peer.close();
        }
    });
    server.start();

    auto client = new ConvexClient("http://127.0.0.1:" ~ port.to!string);
    auto subscription = client.subscribe("demo:state", JSONValue([
        "room": JSONValue("malformed")
    ]));
    foreach (_; 0 .. malformed.length)
    {
        auto failed = subscription.next(3_000);
        assert(failed !is null && failed.error !is null && failed.error.kind == "ProtocolError");
    }
    auto recovered = subscription.next(3_000);
    assert(recovered !is null && recovered.hasValue && recovered.value.object["count"].integer == 7);
    client.close();
    server.join();
}
