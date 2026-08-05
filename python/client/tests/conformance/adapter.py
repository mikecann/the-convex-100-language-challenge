#!/usr/local/bin/python3
import json, os, socket, sys, threading

sys.path.insert(0, os.environ.get("CONVEX_CLIENT_PATH", "/opt/convex/client"))
from convex import Client, FunctionError


def error(exc):
    return {
        "name": type(exc).__name__,
        "message": str(exc),
        **({"data": exc.data} if isinstance(exc, FunctionError) else {}),
    }


def run(reader, writer):
    client = None
    subscriptions = {}
    write_lock = threading.Lock()

    def emit(event):
        # Subscription workers and command responses share one NDJSON stream.
        # A lock keeps two JSON records from interleaving on stdout or TCP.
        with write_lock:
            writer.write(json.dumps(event, separators=(",", ":")) + "\n")
            writer.flush()

    def forward(subscription_id, subscription):
        while True:
            try:
                update = subscription.next_update()
                if update.error:
                    emit(
                        {
                            "type": "subscription",
                            "subscriptionId": subscription_id,
                            "error": error(update.error),
                            "logs": update.logs or [],
                        }
                    )
                else:
                    emit(
                        {
                            "type": "subscription",
                            "subscriptionId": subscription_id,
                            "value": update.value,
                            "logs": update.logs or [],
                        }
                    )
            except Exception:
                return

    def identified(event, ident):
        if ident is not None:
            event["id"] = ident
        return event

    for line in reader:
        command = {}
        ident = None
        try:
            command = json.loads(line)
            ident = command.get("id")
            op = command["op"]
            if op == "hello":
                event = identified(
                    {
                        "protocolVersion": 1,
                        "type": "ready",
                        "language": "python",
                        "implementation": "native-python-3.13",
                        "runtime": sys.version.split()[0],
                    },
                    ident,
                )
            elif op in ("query", "mutation", "action"):
                client = client or Client(
                    os.environ["CONVEX_URL"], os.environ.get("CONVEX_AUTH_TOKEN")
                )
                result = getattr(client, op)(command["path"], command.get("args", {}))
                event = identified(
                    {"type": "result", "value": result.value, "logs": result.logs},
                    ident,
                )
            elif op == "setAuth":
                client = client or Client(os.environ["CONVEX_URL"])
                client.set_auth(command.get("token", ""))
                event = identified({"type": "ack"}, ident)
            elif op == "subscribe":
                client = client or Client(os.environ["CONVEX_URL"])
                subscription = client.subscribe(
                    command["path"], command.get("args", {})
                )
                subscriptions[command["subscriptionId"]] = subscription
                threading.Thread(
                    target=forward,
                    args=(command["subscriptionId"], subscription),
                    daemon=True,
                ).start()
                event = identified({"type": "ack"}, ident)
            elif op == "unsubscribe":
                subscriptions.pop(command["subscriptionId"]).close()
                event = identified({"type": "ack"}, ident)
            elif op == "debugDisconnect":
                client.debug_disconnect_for_adapter()
                event = identified({"type": "ack"}, ident)
            elif op == "close":
                for sub in subscriptions.values():
                    sub.close()
                if client:
                    client.close()
                emit(identified({"type": "closed"}, ident))
                return
            else:
                raise ValueError(f"unknown adapter operation {op!r}")
        except Exception as exc:
            event = identified({"type": "error", "error": error(exc)}, ident)
        emit(event)


if os.environ.get("ADAPTER_LISTEN"):
    host, port = os.environ["ADAPTER_LISTEN"].rsplit(":", 1)
    server = socket.create_server((host, int(port)))
    connection, _ = server.accept()
    reader = connection.makefile("r")
    writer = connection.makefile("w")
    try:
        run(reader, writer)
    finally:
        reader.close()
        writer.close()
        connection.close()
        server.close()
else:
    run(sys.stdin, sys.stdout)
