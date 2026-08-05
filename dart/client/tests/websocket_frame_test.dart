import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../convex_client.dart';

Future<void> main() async {
  await _fragmentedUtf8WithControlFrame();
  await _boundedCloseDuringPartialFrame();
  stdout.writeln('PASS Dart fragmented UTF-8/control and partial-frame close');
}

Future<void> _fragmentedUtf8WithControlFrame() async {
  final fixture = await _RawFixture.start((reader, socket) async {
    await _upgrade(reader, socket);
    await _readClientJson(reader); // Connect
    final modify = await _readClientJson(reader);
    final queryId = ((modify['modifications'] as List).first as Map)['queryId'];
    final transition = utf8.encode(
      jsonEncode({
        'type': 'Transition',
        'startVersion': {'querySet': 0, 'identity': 0, 'ts': 'AAAAAAAAAAA='},
        'endVersion': {'querySet': 1, 'identity': 0, 'ts': 'AQAAAAAAAAA='},
        'modifications': [
          {
            'type': 'QueryUpdated',
            'queryId': queryId,
            'value': {'text': '世界 👋'},
            'logLines': <String>[],
          },
        ],
      }),
    );
    final multibyte = transition.indexOf(0xe4);
    _sendFrame(
      socket,
      transition.sublist(0, multibyte + 1),
      opcode: 1,
      fin: false,
    );
    _sendFrame(
      socket,
      const [],
      opcode: 9,
      fin: true,
    ); // Ping between fragments.
    _sendFrame(socket, transition.sublist(multibyte + 1), opcode: 0, fin: true);
  });
  final client = ConvexClient(fixture.url);
  final subscription = await client.subscribe('demo:echo', {'value': '世界 👋'});
  final update = await subscription.updates.first.timeout(
    const Duration(seconds: 2),
  );
  _check(
    update.error == null && (update.value as Map)['text'] == '世界 👋',
    'fragmented UTF-8 value was not reconstructed',
  );
  await subscription.close();
  await client.close();
  await fixture.close();
}

Future<void> _boundedCloseDuringPartialFrame() async {
  final fixture = await _RawFixture.start((reader, socket) async {
    await _upgrade(reader, socket);
    await _readClientJson(reader); // Connect
    await _readClientJson(reader); // Add
    socket.add([0x81, 100, 0x7b]); // Claims 100 bytes, then stalls after one.
  });
  final client = ConvexClient(fixture.url);
  await client.subscribe('demo:state', {'room': 'partial'});
  await fixture.handlerReached.future.timeout(const Duration(seconds: 2));
  await client.close().timeout(const Duration(seconds: 1));
  await fixture.close();
}

class _RawFixture {
  _RawFixture._(this.server, this.listener);

  static Future<_RawFixture> start(
    Future<void> Function(_ByteReader reader, Socket socket) handler,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    late final _RawFixture fixture;
    final listener = server.listen((socket) {
      fixture._sockets.add(socket);
      final reader = _ByteReader(socket);
      unawaited(
        handler(reader, socket).whenComplete(() {
          if (!fixture.handlerReached.isCompleted)
            fixture.handlerReached.complete();
        }),
      );
    });
    fixture = _RawFixture._(server, listener);
    return fixture;
  }

  final ServerSocket server;
  final StreamSubscription<Socket> listener;
  final Completer<void> handlerReached = Completer<void>();
  final List<Socket> _sockets = [];

  String get url => 'http://${server.address.address}:${server.port}';

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await server.close();
  }
}

class _ByteReader {
  _ByteReader(Socket socket) : iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> iterator;
  final List<int> buffered = [];

  Future<List<int>> read(int count) async {
    while (buffered.length < count) {
      if (!await iterator.moveNext()) throw StateError('raw peer closed early');
      buffered.addAll(iterator.current);
    }
    return buffered.removeRangeCopy(0, count);
  }

  Future<List<int>> until(List<int> marker) async {
    while (true) {
      final index = _indexOf(buffered, marker);
      if (index >= 0) return buffered.removeRangeCopy(0, index + marker.length);
      if (!await iterator.moveNext()) throw StateError('raw peer closed early');
      buffered.addAll(iterator.current);
    }
  }
}

extension on List<int> {
  List<int> removeRangeCopy(int start, int end) {
    final result = sublist(start, end);
    removeRange(start, end);
    return result;
  }
}

Future<void> _upgrade(_ByteReader reader, Socket socket) async {
  final request = ascii.decode(await reader.until([13, 10, 13, 10]));
  final key =
      RegExp(
        r'^Sec-WebSocket-Key:\s*(.+)$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(request)?.group(1)?.trim();
  if (key == null) throw StateError('WebSocket key missing');
  final accept = base64Encode(
    _sha1(
      ascii.encode(
        '$key'
        '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
      ),
    ),
  );
  socket.add(
    ascii.encode(
      'HTTP/1.1 101 Switching Protocols\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Accept: $accept\r\n\r\n',
    ),
  );
  await socket.flush();
}

Future<Map<String, dynamic>> _readClientJson(_ByteReader reader) async {
  final header = await reader.read(2);
  var length = header[1] & 0x7f;
  if (length == 126) {
    final extended = await reader.read(2);
    length = (extended[0] << 8) | extended[1];
  }
  final mask = await reader.read(4);
  final payload = await reader.read(length);
  for (var index = 0; index < payload.length; index += 1) {
    payload[index] ^= mask[index % 4];
  }
  return jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
}

void _sendFrame(
  Socket socket,
  List<int> payload, {
  required int opcode,
  required bool fin,
}) {
  final frame = <int>[(fin ? 0x80 : 0) | opcode];
  if (payload.length < 126) {
    frame.add(payload.length);
  } else {
    frame.addAll([126, payload.length >> 8, payload.length & 0xff]);
  }
  socket.add([...frame, ...payload]);
}

int _indexOf(List<int> source, List<int> marker) {
  for (var start = 0; start <= source.length - marker.length; start += 1) {
    var matches = true;
    for (var offset = 0; offset < marker.length; offset += 1) {
      if (source[start + offset] != marker[offset]) matches = false;
    }
    if (matches) return start;
  }
  return -1;
}

List<int> _sha1(List<int> input) {
  final message = [...input, 0x80];
  while (message.length % 64 != 56) message.add(0);
  final bitLength = input.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    message.add((bitLength >> shift) & 0xff);
  }
  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;
  var h4 = 0xc3d2e1f0;
  for (var chunk = 0; chunk < message.length; chunk += 64) {
    final words = List<int>.filled(80, 0);
    for (var index = 0; index < 16; index += 1) {
      final offset = chunk + index * 4;
      words[index] =
          (message[offset] << 24) |
          (message[offset + 1] << 16) |
          (message[offset + 2] << 8) |
          message[offset + 3];
    }
    for (var index = 16; index < 80; index += 1) {
      words[index] = _rotate(
        words[index - 3] ^
            words[index - 8] ^
            words[index - 14] ^
            words[index - 16],
        1,
      );
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    for (var index = 0; index < 80; index += 1) {
      final (function, constant) = switch (index) {
        < 20 => ((b & c) | ((~b) & d), 0x5a827999),
        < 40 => (b ^ c ^ d, 0x6ed9eba1),
        < 60 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
        _ => (b ^ c ^ d, 0xca62c1d6),
      };
      final temporary =
          (_rotate(a, 5) + function + e + constant + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotate(b, 30);
      b = a;
      a = temporary;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  return [h0, h1, h2, h3, h4]
      .expand(
        (word) => [
          word >> 24,
          word >> 16,
          word >> 8,
          word,
        ].map((byte) => byte & 0xff),
      )
      .toList();
}

int _rotate(int value, int bits) =>
    ((value << bits) | ((value & 0xffffffff) >> (32 - bits))) & 0xffffffff;

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
