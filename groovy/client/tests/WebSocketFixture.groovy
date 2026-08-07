package convex.tests

import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/** Minimal deterministic RFC 6455 server used only by language-local tests. */
final class WebSocketFixture {
  static final JsonSlurper JSON = new JsonSlurper()

  static Peer handshake(Socket socket) {
    socket.soTimeout = 5_000
    InputStream input = socket.inputStream
    OutputStream output = socket.outputStream
    String headers = readHeaders(input)
    String key = header(headers, 'sec-websocket-key')
    String accept = Base64.encoder.encodeToString(
      MessageDigest.getInstance('SHA-1').digest(
        (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
          .getBytes(StandardCharsets.US_ASCII),
      ),
    )
    output.write((
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      "Sec-WebSocket-Accept: ${accept}\r\n\r\n"
    ).getBytes(StandardCharsets.US_ASCII))
    output.flush()
    new Peer(socket, input, output)
  }

  static String readHeaders(InputStream input) {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream()
    int matched = 0
    while (matched < 4) {
      int value = input.read()
      if (value < 0) {
        throw new EOFException('EOF in WebSocket handshake')
      }
      bytes.write(value)
      if (matched == 0) {
        matched = value == (int) '\r' ? 1 : 0
      } else if (matched == 1) {
        matched = value == (int) '\n' ? 2 : 0
      } else if (matched == 2) {
        matched = value == (int) '\r' ? 3 : 0
      } else {
        matched = value == (int) '\n' ? 4 : 0
      }
    }
    bytes.toString(StandardCharsets.US_ASCII)
  }

  private static String header(String headers, String name) {
    for (String line : headers.split('\\r\\n')) {
      int separator = line.indexOf(':')
      if (separator > 0 &&
        line.substring(0, separator).toLowerCase(Locale.ROOT) == name) {
        return line.substring(separator + 1).trim()
      }
    }
    throw new IllegalStateException("missing ${name}")
  }

  static final class Peer implements AutoCloseable {
    final Socket socket
    private final InputStream input
    private final OutputStream output

    Peer(Socket socket, InputStream input, OutputStream output) {
      this.socket = socket
      this.input = input
      this.output = output
    }

    Map readJson() {
      while (true) {
        Frame frame = readFrame()
        if (frame.opcode == 1) {
          return (Map) JSON.parseText(new String(frame.payload, StandardCharsets.UTF_8))
        }
        if (frame.opcode == 8) {
          throw new EOFException('peer sent close')
        }
      }
    }

    Frame readFrame() {
      int first = input.read()
      int second = input.read()
      if (first < 0 || second < 0) {
        throw new EOFException('EOF in WebSocket frame')
      }
      boolean masked = (second & 0x80) != 0
      long length = second & 0x7f
      if (length == 126) {
        length = (input.read() << 8) | input.read()
      } else if (length == 127) {
        length = 0
        for (int index = 0; index < 8; index++) {
          length = (length << 8) | input.read()
        }
      }
      if (length > 4 * 1024 * 1024) {
        throw new IllegalStateException('fixture frame is unexpectedly large')
      }
      byte[] mask = masked ? input.readNBytes(4) : new byte[0]
      byte[] payload = input.readNBytes((int) length)
      if (payload.length != length) {
        throw new EOFException('EOF in WebSocket payload')
      }
      if (masked) {
        for (int index = 0; index < payload.length; index++) {
          payload[index] ^= mask[index % 4]
        }
      }
      new Frame(first & 0x0f, (first & 0x80) != 0, payload)
    }

    void sendJson(Map message) {
      sendFrame(1, true, JsonOutput.toJson(message).getBytes(StandardCharsets.UTF_8))
    }

    void sendFragmentedJson(Map message) {
      byte[] payload = JsonOutput.toJson(message).getBytes(StandardCharsets.UTF_8)
      int first = Math.max(1, payload.length.intdiv(3))
      int second = Math.max(first + 1, (payload.length * 2).intdiv(3))
      sendFrame(1, false, Arrays.copyOfRange(payload, 0, first))
      sendFrame(9, true, 'ok'.getBytes(StandardCharsets.UTF_8))
      sendFrame(0, false, Arrays.copyOfRange(payload, first, second))
      sendFrame(0, true, Arrays.copyOfRange(payload, second, payload.length))
    }

    void sendClose(int code, String reason) {
      ByteArrayOutputStream payload = new ByteArrayOutputStream()
      payload.write((code >>> 8) & 0xff)
      payload.write(code & 0xff)
      payload.write(reason.getBytes(StandardCharsets.UTF_8))
      sendFrame(8, true, payload.toByteArray())
    }

    synchronized void sendFrame(int opcode, boolean finished, byte[] payload) {
      output.write((finished ? 0x80 : 0) | opcode)
      if (payload.length < 126) {
        output.write(payload.length)
      } else if (payload.length <= 0xffff) {
        output.write(126)
        output.write((payload.length >>> 8) & 0xff)
        output.write(payload.length & 0xff)
      } else {
        output.write(127)
        long length = payload.length
        for (int shift = 56; shift >= 0; shift -= 8) {
          output.write((int) ((length >>> shift) & 0xff))
        }
      }
      output.write(payload)
      output.flush()
    }

    void awaitDisconnect() {
      try {
        while (input.read() >= 0) {
          // Drain until the client aborts or closes.
        }
      } catch (IOException ignored) {
        // An abort commonly manifests as a reset.
      }
    }

    @Override
    void close() {
      socket.close()
    }
  }

  static record Frame(int opcode, boolean finished, byte[] payload) {}
}
