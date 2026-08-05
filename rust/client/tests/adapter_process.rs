//! Child-process adapter regression for relay and owner barriers.
//!
//! The old relay dequeues a value and pauses while the controller replaces its
//! subscription ID. The replacement acknowledgement must invalidate that relay
//! before it can publish. The same peer also proves debugDisconnect and
//! unsubscribe acknowledgements follow the actual socket and Remove barriers.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use tungstenite::{Message, WebSocket};

const INITIAL_TS: &str = "AAAAAAAAAAA=";

fn version(query_set: u32, timestamp: &str) -> Value {
    json!({"querySet":query_set,"identity":0,"ts":timestamp})
}

fn transition(start: Value, end: Value, id: u64, count: i64) -> String {
    json!({
        "type":"Transition",
        "startVersion":start,
        "endVersion":end,
        "modifications":[{
            "type":"QueryUpdated",
            "queryId":id,
            "value":{"count":count},
            "logLines":[]
        }]
    })
    .to_string()
}

fn read_value(socket: &mut WebSocket<std::net::TcpStream>) -> Value {
    serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap()
}

fn read_connect_and_add(socket: &mut WebSocket<std::net::TcpStream>) -> (Value, u64) {
    let connect = read_value(socket);
    assert_eq!(connect["type"], "Connect");
    let add = read_value(socket);
    assert_eq!(add["modifications"][0]["type"], "Add");
    (
        connect,
        add["modifications"][0]["queryId"].as_u64().unwrap(),
    )
}

fn next(receiver: &mpsc::Receiver<String>) -> Value {
    serde_json::from_str(
        &receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("adapter event"),
    )
    .unwrap()
}

fn wait_for_eof(stream: &mut std::net::TcpStream) {
    let mut buffer = [0; 256];
    while stream.read(&mut buffer).unwrap_or(0) > 0 {}
}

#[test]
fn replacement_debug_unsubscribe_and_close_are_serialized_barriers() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (late_sent, late_observed) = mpsc::channel();
    let (disconnected, disconnect_observed) = mpsc::channel();
    let (removed, remove_observed) = mpsc::channel();

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut first = tungstenite::accept(stream).unwrap();
        let (_, old_id) = read_connect_and_add(&mut first);
        let zero = version(0, INITIAL_TS);
        let one = version(1, "AQAAAAAAAAA=");
        first
            .send(Message::Text(
                transition(zero, one.clone(), old_id, 0).into(),
            ))
            .unwrap();

        // This update is dequeued by the deliberately delayed old relay before
        // the replacement command arrives.
        thread::sleep(Duration::from_millis(250));
        let two = version(1, "AgAAAAAAAAA=");
        first
            .send(Message::Text(
                transition(one, two.clone(), old_id, 99).into(),
            ))
            .unwrap();
        late_sent.send(()).unwrap();

        let remove = read_value(&mut first);
        let add = read_value(&mut first);
        assert_eq!(remove["modifications"][0]["type"], "Remove");
        assert_eq!(add["modifications"][0]["type"], "Add");
        assert_eq!(remove["baseVersion"], 1);
        assert_eq!(add["baseVersion"], 2);
        let new_id = add["modifications"][0]["queryId"].as_u64().unwrap();

        let three = version(3, "AwAAAAAAAAA=");
        first
            .send(Message::Text(
                transition(two, three.clone(), new_id, 1).into(),
            ))
            .unwrap();
        wait_for_eof(first.get_mut());
        disconnected.send(()).unwrap();

        let (stream, _) = listener.accept().unwrap();
        let mut second = tungstenite::accept(stream).unwrap();
        let (connect, reconnect_id) = read_connect_and_add(&mut second);
        assert_eq!(connect["connectionCount"], 1);
        assert_eq!(connect["lastCloseReason"], "adapter debug disconnect");
        assert_eq!(connect["maxObservedTimestamp"], three["ts"]);
        second
            .send(Message::Text(
                transition(
                    version(0, INITIAL_TS),
                    version(1, "BAAAAAAAAAA="),
                    reconnect_id,
                    2,
                )
                .into(),
            ))
            .unwrap();
        let remove = read_value(&mut second);
        assert_eq!(remove["modifications"][0]["type"], "Remove");
        removed.send(()).unwrap();
        wait_for_eof(second.get_mut());
    });

    let binary = env!("CARGO_BIN_EXE_convex-adapter");
    let mut child = Command::new(binary)
        .env("CONVEX_URL", format!("http://{address}"))
        .env("ADAPTER_TEST_RELAY_DELAY_MS", "150")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (events, receiver) = mpsc::channel();
    thread::spawn(move || {
        for line in BufReader::new(stdout)
            .lines()
            .map_while(std::result::Result::ok)
        {
            let _ = events.send(line);
        }
    });

    input
        .write_all(
            b"{\"id\":\"first\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}\n",
        )
        .unwrap();
    assert_eq!(next(&receiver)["id"], "first");
    assert_eq!(next(&receiver)["value"]["count"], 0);

    late_observed.recv_timeout(Duration::from_secs(2)).unwrap();
    thread::sleep(Duration::from_millis(25));
    input
        .write_all(
            b"{\"id\":\"replace\",\"op\":\"subscribe\",\"subscriptionId\":\"same\",\"path\":\"demo:state\",\"args\":{}}\n",
        )
        .unwrap();
    assert_eq!(next(&receiver)["id"], "replace");
    let replacement = next(&receiver);
    assert_eq!(replacement["type"], "subscription");
    assert_eq!(
        replacement["value"]["count"], 1,
        "old relay crossed replacement acknowledgement"
    );

    input
        .write_all(b"{\"id\":\"debug\",\"op\":\"debugDisconnect\"}\n")
        .unwrap();
    assert_eq!(next(&receiver)["id"], "debug");
    disconnect_observed
        .recv_timeout(Duration::from_secs(1))
        .expect("debug acknowledgement preceded socket detach");
    assert_eq!(next(&receiver)["value"]["count"], 2);

    input
        .write_all(b"{\"id\":\"unsubscribe\",\"op\":\"unsubscribe\",\"subscriptionId\":\"same\"}\n")
        .unwrap();
    assert_eq!(next(&receiver)["id"], "unsubscribe");
    remove_observed
        .recv_timeout(Duration::from_secs(1))
        .expect("unsubscribe acknowledgement preceded Remove write");

    input
        .write_all(b"{\"id\":\"close\",\"op\":\"close\"}\n")
        .unwrap();
    assert_eq!(next(&receiver)["type"], "closed");
    drop(input);
    assert!(child.wait().unwrap().success());
    server.join().unwrap();
}
