"""Drives the adapter's `ADAPTER_LISTEN` mode over a real TCP connection.

The shared harness never speaks to the adapter over stdin; it dials the TCP
port instead. This probe proves that path inside the image build, using the
client's own connection layer rather than a shell networking tool.
"""

from convex import sleep_ms
from net import Conn, connect, now_ms


fn main() raises:
    var deadline = now_ms() + 15000
    # The adapter is started in the background just before this runs, so the
    # first dial can legitimately arrive before its listener is bound.
    var conn = Conn()
    while now_ms() < deadline:
        try:
            conn = connect(String("127.0.0.1"), 18080, False, String(), 2000)
            break
        except:
            _ = sleep_ms(50)
    if conn.fd < 0:
        raise Error("the TCP adapter never accepted a connection")
    var commands = String(
        '{"protocolVersion":1,"id":"tcp-hello","op":"hello"}\n'
    )
    commands += '{"id":"tcp-close","op":"close"}\n'
    conn.write_all(commands.as_bytes(), deadline)
    var transcript = String()
    while now_ms() < deadline:
        if conn.fill(deadline) == 0:
            break
        var raw = List[UInt8]()
        for i in range(conn.buffered()):
            raw.append(conn.peek(i))
        conn.consume(conn.buffered())
        transcript += String(from_utf8_lossy=Span(raw))
        if transcript.find('"type":"closed"') >= 0:
            break
    if transcript.find('"language":"mojo"') < 0:
        raise Error("the TCP adapter did not answer hello: " + transcript)
    if transcript.find('"id":"tcp-close","type":"closed"') < 0:
        raise Error("the TCP adapter did not close cleanly: " + transcript)
    print("PASS mojo adapter TCP mode")
