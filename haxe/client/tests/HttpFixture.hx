import haxe.io.Bytes;
import sys.net.Host;
import sys.net.Socket;
import sys.thread.Deque;
import sys.thread.Thread;

/** A scripted HTTP/1.1 origin. Each queued response is served to exactly one
 * connection, so recovery after a rejected response is observable. */
class HttpFixture {
  public final port:Int;

  final requests = new Deque<String>();

  public function new(responses:Array<String>) {
    var server = new Socket();
    server.bind(new Host("127.0.0.1"), 0);
    server.listen(8);
    port = server.host().port;
    Thread.create(function() {
      for (response in responses) {
        var peer:Null<Socket> = null;
        try {
          peer = server.accept();
          var head = SocketTransport.readUntil(peer, "\r\n\r\n", 65536, Sys.time() + 5.0, "fixture request").toString();
          requests.add(head);
          SocketTransport.writeAll(peer, Bytes.ofString(response), Sys.time() + 5.0, "fixture response");
        } catch (_:Dynamic) {}
        SocketTransport.closeQuietly(peer);
      }
      server.close();
    });
  }

  public function url():String {
    return 'http://127.0.0.1:$port';
  }

  /** The raw request head of the next served request, so header transmission
   * can be asserted byte for byte rather than inferred. */
  public function nextRequest(timeout:Float):String {
    var deadline = Sys.time() + timeout;
    while (Sys.time() < deadline) {
      var head = requests.pop(false);
      if (head != null) return head;
      Sys.sleep(0.005);
    }
    throw "fixture never received a request";
  }

  public static function body(payload:String):String {
    return response(200, payload);
  }

  public static function success(value:String):String {
    return body('{"status":"success","value":$value,"logLines":[]}');
  }

  public static function response(status:Int, payload:String):String {
    var length = Bytes.ofString(payload).length;
    return 'HTTP/1.1 $status Test\r\nContent-Length: $length\r\nConnection: close\r\n\r\n$payload';
  }
}
