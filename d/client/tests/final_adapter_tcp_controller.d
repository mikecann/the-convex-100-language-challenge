/** Controller for the isolated-cgroup final adapter probe. */
module final_adapter_tcp_controller;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, write;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;
import std.string : indexOf, startsWith;

private void sendAll(Socket peer, const(ubyte)[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        auto sent = peer.send(bytes[offset .. $]);
        enforce(sent > 0);
        offset += cast(size_t) sent;
    }
}

private string readLine(Socket peer, ref ubyte[] pending)
{
    for (;;)
    {
        foreach (index, octet; pending)
            if (octet == '\n')
            {
                auto line = cast(string) pending[0 .. index].idup;
                pending = pending[index + 1 .. $];
                return line;
            }
        ubyte[16_384] chunk;
        auto received = peer.receive(chunk);
        enforce(received > 0, "adapter closed its controller socket");
        pending ~= chunk[0 .. received];
    }
}

private void waitForFile(string path)
{
    foreach (_; 0 .. 1_500)
    {
        if (path.exists)
            return;
        Thread.sleep(20.msecs);
    }
    enforce(false, "fixture gate timed out: " ~ path);
}

private void expectEvent(Socket peer, ref ubyte[] pending, uint expectedSequence,
        char expectedOctet, size_t expectedBytes)
{
    auto line = readLine(peer, pending);
    enforce(line.startsWith(`{"subscriptionId":"retained","type":"subscription","value":{`));
    enforce(line.indexOf(`"error"`) < 0 && line.indexOf("null") < 0);
    auto payloadMarker = `"payload":"`;
    auto markerAt = line.indexOf(payloadMarker);
    enforce(markerAt >= 0);
    auto payloadStart = cast(size_t) markerAt + payloadMarker.length;
    enforce(payloadStart + expectedBytes < line.length && line[payloadStart + expectedBytes] == '"');
    foreach (octet; line[payloadStart .. payloadStart + expectedBytes])
        enforce(octet == expectedOctet);
    enforce(line.indexOf(`"sequence":` ~ expectedSequence.to!string) >= 0);
}

private void expect(Socket peer, ref ubyte[] pending, string expected)
{
    enforce(readLine(peer, pending) == expected);
}

void main()
{
    auto peer = new TcpSocket();
    peer.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 4_096);
    scope (exit)
        peer.close();
    peer.connect(new InternetAddress("127.0.0.1", 18162));
    ubyte[] pending;

    sendAll(peer, cast(const(ubyte)[])(
            `{"id":"retained","op":"subscribe","subscriptionId":"retained","path":"demo:state","args":{}}`
            ~ "\n"));
    expect(peer, pending, `{"id":"retained","type":"ack"}`);

    write("/tmp/d-live-count-start", "ready");
    waitForFile("/tmp/d-live-count-first-sent");
    Thread.sleep(50.msecs);
    write("/tmp/d-live-count-burst", "ready");
    waitForFile("/tmp/d-live-count-done");
    expectEvent(peer, pending, 1, 's', 1_750_000);
    foreach (uint sequence; 3 .. 19)
        expectEvent(peer, pending, sequence, 's', 128 * 1024);

    write("/tmp/d-live-byte-start", "ready");
    waitForFile("/tmp/d-live-byte-first-sent");
    Thread.sleep(50.msecs);
    write("/tmp/d-live-byte-burst", "ready");
    waitForFile("/tmp/d-live-byte-done");
    expectEvent(peer, pending, 101, 'x', 1_750_000);
    foreach (uint sequence; 103 .. 106)
        expectEvent(peer, pending, sequence, 'x', 1_750_000);

    sendAll(peer, cast(const(ubyte)[])(`{"id":"close","op":"close"}` ~ "\n"));
    write("/tmp/d-live-finish", "ready");
    expect(peer, pending, `{"id":"close","type":"closed"}`);
}
