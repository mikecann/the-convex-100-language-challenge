//! Test-only NDJSON adapter protocol v1.
//!
//! The adapter calls the native Rust client for every operation. Its output
//! gate owns subscription generations as well as the writer, so a stale relay
//! can never cross a replacement, unsubscribe, or close acknowledgement.

use convex_rust_demo::{Client, Error, FunctionError, Mailbox, Update};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::env;
use std::io::{self, BufRead, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const RUST_RUNTIME: &str = "rust-1.89.0";

#[derive(Deserialize)]
struct Command {
    id: Option<String>,
    op: Option<String>,
    #[serde(rename = "protocolVersion")]
    protocol_version: Option<u32>,
    path: Option<String>,
    args: Option<Value>,
    #[serde(rename = "subscriptionId")]
    subscription_id: Option<String>,
    token: Option<String>,
}

#[derive(Clone)]
struct Output(Arc<Mutex<OutputState>>);

struct OutputState {
    writer: Box<dyn Write + Send>,
    generations: HashMap<String, u64>,
    active: HashMap<String, u64>,
    closed: bool,
}

impl Output {
    fn new(writer: impl Write + Send + 'static) -> Self {
        Self(Arc::new(Mutex::new(OutputState {
            writer: Box::new(writer),
            generations: HashMap::new(),
            active: HashMap::new(),
            closed: false,
        })))
    }

    fn send(&self, value: Value) {
        let mut state = self.0.lock().unwrap();
        if !state.closed {
            write_value(&mut state.writer, &value);
        }
    }

    fn activate_and_ack(&self, subscription_id: &str, command_id: Option<&str>) -> u64 {
        let mut state = self.0.lock().unwrap();
        let generation = state
            .generations
            .get(subscription_id)
            .copied()
            .unwrap_or(0)
            .wrapping_add(1);
        state
            .generations
            .insert(subscription_id.to_owned(), generation);
        state.active.insert(subscription_id.to_owned(), generation);
        if !state.closed {
            write_value(&mut state.writer, &event("ack", command_id));
        }
        generation
    }

    fn invalidate(&self, subscription_id: &str) {
        let mut state = self.0.lock().unwrap();
        let generation = state
            .generations
            .get(subscription_id)
            .copied()
            .unwrap_or(0)
            .wrapping_add(1);
        state
            .generations
            .insert(subscription_id.to_owned(), generation);
        state.active.remove(subscription_id);
    }

    fn invalidate_and_ack(&self, subscription_id: &str, command_id: Option<&str>) {
        let mut state = self.0.lock().unwrap();
        let generation = state
            .generations
            .get(subscription_id)
            .copied()
            .unwrap_or(0)
            .wrapping_add(1);
        state
            .generations
            .insert(subscription_id.to_owned(), generation);
        state.active.remove(subscription_id);
        if !state.closed {
            write_value(&mut state.writer, &event("ack", command_id));
        }
    }

    fn relay(&self, subscription_id: &str, generation: u64, value: Value) -> bool {
        let mut state = self.0.lock().unwrap();
        if state.closed || state.active.get(subscription_id).copied() != Some(generation) {
            return false;
        }
        write_value(&mut state.writer, &value);
        true
    }

    fn close(&self, command_id: Option<&str>) {
        let mut state = self.0.lock().unwrap();
        if state.closed {
            return;
        }
        state.active.clear();
        state.closed = true;
        write_value(&mut state.writer, &event("closed", command_id));
    }
}

fn write_value(writer: &mut Box<dyn Write + Send>, value: &Value) {
    serde_json::to_writer(&mut **writer, value).expect("serialize adapter event");
    writer.write_all(b"\n").expect("write adapter newline");
    writer.flush().expect("flush adapter event");
}

fn event(event_type: &str, id: Option<&str>) -> Value {
    let mut value = Map::new();
    value.insert("type".into(), Value::String(event_type.into()));
    if let Some(id) = id {
        value.insert("id".into(), Value::String(id.into()));
    }
    Value::Object(value)
}

fn result_event(id: Option<&str>, value: Value, logs: Vec<String>) -> Value {
    let mut result = event("result", id);
    result["value"] = value;
    if !logs.is_empty() {
        result["logs"] = json!(logs);
    }
    result
}

fn subscription_event(subscription_id: &str, update: Update) -> Value {
    match update.error {
        Some(error) => failure_event(None, Some(subscription_id), &error),
        None if update.value.is_some() => {
            let mut value = event("subscription", None);
            value["subscriptionId"] = Value::String(subscription_id.into());
            value["value"] = update.value.unwrap();
            if !update.logs.is_empty() {
                value["logs"] = json!(update.logs);
            }
            value
        }
        None => failure_event(
            None,
            Some(subscription_id),
            &Error::Protocol("Live success omitted value".into()),
        ),
    }
}

fn failure_event(id: Option<&str>, subscription_id: Option<&str>, error: &Error) -> Value {
    let event_type = if subscription_id.is_some() {
        "subscription"
    } else {
        "error"
    };
    let mut value = event(event_type, id);
    if let Some(subscription_id) = subscription_id {
        value["subscriptionId"] = Value::String(subscription_id.into());
    }

    let (name, data, logs) = match error {
        Error::Function(FunctionError { data, logs, .. }) => {
            ("FunctionError", data.clone(), logs.clone())
        }
        Error::Protocol(_) => ("ProtocolError", None, Vec::new()),
        Error::Transport(_) => ("TransportError", None, Vec::new()),
        Error::Closed => ("Error", None, Vec::new()),
    };
    let mut detail = json!({"name": name, "message": error.to_string()});
    if let Some(data) = data {
        detail["data"] = data;
    }
    value["error"] = detail;
    if !logs.is_empty() {
        value["logs"] = json!(logs);
    }
    value
}

fn relay(
    output: Output,
    subscription_id: String,
    generation: u64,
    mailbox: Mailbox,
    delay: Duration,
) {
    thread::spawn(move || {
        loop {
            match mailbox.recv_timeout(Duration::from_secs(60)) {
                Ok(update) => {
                    // The integration fixture delays a relay after dequeueing to
                    // reproduce the exact late-publication race deterministically.
                    if !delay.is_zero() {
                        thread::sleep(delay);
                    }
                    let value = subscription_event(&subscription_id, update);
                    if !output.relay(&subscription_id, generation, value) {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
}

fn client_or_create(client: &mut Option<Client>) -> Result<&Client, Error> {
    if client.is_none() {
        let url =
            env::var("CONVEX_URL").map_err(|_| Error::Protocol("CONVEX_URL is required".into()))?;
        *client = Some(Client::new(&url)?);
    }
    Ok(client.as_ref().unwrap())
}

fn run(reader: impl BufRead, writer: impl Write + Send + 'static) {
    let output = Output::new(writer);
    let mut client = None;
    let mut subscriptions: HashMap<String, convex_rust_demo::Subscription> = HashMap::new();
    let relay_delay = env::var("ADAPTER_TEST_RELAY_DELAY_MS")
        .ok()
        .and_then(|value| value.parse().ok())
        .map(Duration::from_millis)
        .unwrap_or_default();

    for line in reader.lines().map_while(std::result::Result::ok) {
        let command: Command = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                output.send(failure_event(
                    None,
                    None,
                    &Error::Protocol(format!("invalid adapter command: {error}")),
                ));
                continue;
            }
        };
        let command_id = command.id.as_deref();
        let operation = command.op.as_deref().unwrap_or("");
        let args = command.args.unwrap_or_else(|| json!({}));

        match operation {
            "hello" if command.protocol_version == Some(1) => {
                let mut ready = event("ready", command_id);
                ready["protocolVersion"] = json!(1);
                ready["language"] = json!("rust");
                ready["implementation"] = json!("native-rust-0.1.0");
                ready["runtime"] = json!(RUST_RUNTIME);
                output.send(ready);
            }
            "query" | "mutation" | "action" => {
                let path = command.path.as_deref().unwrap_or("");
                let result = match client_or_create(&mut client) {
                    Ok(client) => match operation {
                        "query" => client.query(path, args),
                        "mutation" => client.mutation(path, args),
                        _ => client.action(path, args),
                    },
                    Err(error) => Err(error),
                };
                match result {
                    Ok(result) => output.send(result_event(command_id, result.value, result.logs)),
                    Err(error) => output.send(failure_event(command_id, None, &error)),
                }
            }
            "setAuth" => {
                let result = client_or_create(&mut client)
                    .and_then(|client| client.set_auth(command.token.as_deref().unwrap_or("")));
                match result {
                    Ok(()) => output.send(event("ack", command_id)),
                    Err(error) => output.send(failure_event(command_id, None, &error)),
                }
            }
            "subscribe" => {
                let subscription_id = command.subscription_id.unwrap_or_default();
                if let Some(old) = subscriptions.remove(&subscription_id) {
                    let _ = old.close();
                    // If replacement setup fails, the removed relay is still
                    // invalid and cannot cross the command's error response.
                    output.invalidate(&subscription_id);
                }
                let result = client_or_create(&mut client).and_then(|client| {
                    client.subscribe(command.path.as_deref().unwrap_or(""), args)
                });
                match result {
                    Ok(subscription) => {
                        let mailbox = subscription.updates();
                        subscriptions.insert(subscription_id.clone(), subscription);
                        let generation = output.activate_and_ack(&subscription_id, command_id);
                        relay(
                            output.clone(),
                            subscription_id,
                            generation,
                            mailbox,
                            relay_delay,
                        );
                    }
                    Err(error) => output.send(failure_event(command_id, None, &error)),
                }
            }
            "unsubscribe" => {
                let subscription_id = command.subscription_id.unwrap_or_default();
                if let Some(subscription) = subscriptions.remove(&subscription_id) {
                    let _ = subscription.close();
                }
                // Invalidation and acknowledgement share the relay's writer lock.
                output.invalidate_and_ack(&subscription_id, command_id);
            }
            "debugDisconnect" => {
                let result =
                    client_or_create(&mut client).and_then(Client::debug_disconnect_for_adapter);
                match result {
                    Ok(()) => output.send(event("ack", command_id)),
                    Err(error) => output.send(failure_event(command_id, None, &error)),
                }
            }
            "close" => {
                for (_, subscription) in subscriptions.drain() {
                    let _ = subscription.close();
                }
                if let Some(client) = &client {
                    let _ = client.close();
                }
                output.close(command_id);
                return;
            }
            _ => output.send(failure_event(
                command_id,
                None,
                &Error::Protocol("unknown operation".into()),
            )),
        }
    }

    for (_, subscription) in subscriptions.drain() {
        let _ = subscription.close();
    }
    if let Some(client) = &client {
        let _ = client.close();
    }
}

fn main() {
    if let Ok(address) = env::var("ADAPTER_LISTEN") {
        let listener = TcpListener::bind(address).expect("bind ADAPTER_LISTEN");
        let (socket, _) = listener.accept().expect("accept controller");
        run(io::BufReader::new(socket.try_clone().unwrap()), socket);
    } else {
        run(io::BufReader::new(io::stdin()), io::stdout());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone)]
    struct Buffer(Arc<Mutex<Vec<u8>>>);

    impl Write for Buffer {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn serialized_events_omit_absent_fields_and_preserve_null_data_and_logs() {
        let transport = failure_event(Some("transport"), None, &Error::Transport("offline".into()));
        assert!(transport.get("subscriptionId").is_none());
        assert!(transport["error"].get("data").is_none());
        assert!(transport.get("logs").is_none());

        let function = Error::Function(FunctionError {
            operation: "query".into(),
            message: "failed".into(),
            data: Some(Value::Null),
            logs: vec!["kept".into()],
        });
        let failed = failure_event(None, Some("live"), &function);
        assert_eq!(failed["error"]["data"], Value::Null);
        assert_eq!(failed["logs"], json!(["kept"]));
        assert!(failed.get("id").is_none());

        let success = subscription_event(
            "live",
            Update {
                value: Some(Value::Null),
                error: None,
                logs: vec!["null".into()],
            },
        );
        assert_eq!(success["value"], Value::Null);
        assert_eq!(success["logs"], json!(["null"]));
    }

    #[test]
    fn relay_generation_and_writer_are_one_serialized_barrier() {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let output = Output::new(Buffer(bytes.clone()));
        let old = output.activate_and_ack("same", Some("first"));
        output.invalidate_and_ack("same", Some("unsubscribe"));
        assert!(!output.relay(
            "same",
            old,
            json!({"type":"subscription","subscriptionId":"same","value":99})
        ));
        let lines = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
        let events: Vec<Value> = lines
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["id"], "first");
        assert_eq!(events[1]["id"], "unsubscribe");
    }

    #[test]
    fn hello_reports_the_pinned_rust_toolchain_not_the_package_version() {
        assert_eq!(RUST_RUNTIME, "rust-1.89.0");
    }
}
