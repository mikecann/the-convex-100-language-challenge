//! A deliberately small native Rust Convex demonstration client.
//!
//! HTTP uses the documented JSON envelope. Live uses the pinned, unversioned
//! `/api/sync` profile from convex-rs 0.10.4; it is not an SDK compatibility
//! promise.

use reqwest::blocking::Client as Http;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket, connect};

const INITIAL_TS: &str = "AAAAAAAAAAA=";
const INITIAL_BACKOFF: Duration = Duration::from_millis(100);
const MAX_BACKOFF: Duration = Duration::from_secs(15);
const OWNER_RESPONSE_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_RESPONSE: usize = 2 << 20;
const MAILBOX_CAPACITY: usize = 16;

type ConvexResult<T> = std::result::Result<T, Error>;
type Socket = WebSocket<MaybeTlsStream<std::net::TcpStream>>;

#[derive(Debug, Clone)]
pub struct Result {
    pub value: Value,
    pub logs: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct FunctionError {
    pub operation: String,
    pub message: String,
    pub data: Option<Value>,
    pub logs: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum Error {
    Function(FunctionError),
    Protocol(String),
    Transport(String),
    Closed,
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Function(error) => {
                write!(
                    formatter,
                    "convex {} failed: {}",
                    error.operation, error.message
                )
            }
            Self::Protocol(message) => write!(formatter, "convex protocol error: {message}"),
            Self::Transport(message) => write!(formatter, "convex transport error: {message}"),
            Self::Closed => write!(formatter, "convex client is closed"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Debug, Clone)]
pub struct Update {
    pub value: Option<Value>,
    pub error: Option<Error>,
    pub logs: Vec<String>,
}

#[derive(Clone)]
pub struct Mailbox(Arc<(Mutex<MailboxState>, Condvar)>);

struct MailboxState {
    updates: VecDeque<Update>,
    closed: bool,
}

impl Mailbox {
    fn new() -> Self {
        Self(Arc::new((
            Mutex::new(MailboxState {
                updates: VecDeque::with_capacity(MAILBOX_CAPACITY),
                closed: false,
            }),
            Condvar::new(),
        )))
    }

    fn push(&self, update: Update) {
        let (lock, wake) = &*self.0;
        let mut state = lock.lock().unwrap();
        if state.closed {
            return;
        }
        if state.updates.len() == MAILBOX_CAPACITY {
            state.updates.pop_front();
        }
        state.updates.push_back(update);
        wake.notify_one();
    }

    fn close(&self) {
        let (lock, wake) = &*self.0;
        lock.lock().unwrap().closed = true;
        wake.notify_all();
    }

    pub fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> std::result::Result<Update, mpsc::RecvTimeoutError> {
        let (lock, wake) = &*self.0;
        let mut state = lock.lock().unwrap();
        let deadline = Instant::now() + timeout;

        loop {
            if let Some(update) = state.updates.pop_front() {
                return Ok(update);
            }
            if state.closed {
                return Err(mpsc::RecvTimeoutError::Disconnected);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(mpsc::RecvTimeoutError::Timeout);
            }
            let (next, result) = wake.wait_timeout(state, remaining).unwrap();
            state = next;
            if result.timed_out() {
                return Err(mpsc::RecvTimeoutError::Timeout);
            }
        }
    }
}

pub struct Subscription {
    id: u32,
    manager: Arc<Live>,
    mailbox: Mailbox,
    closed: AtomicBool,
}

impl Subscription {
    pub fn close(&self) -> ConvexResult<()> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.manager.remove(self.id)
    }

    pub fn updates(&self) -> Mailbox {
        self.mailbox.clone()
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

#[derive(Clone)]
pub struct Client {
    url: String,
    http: Http,
    auth: Arc<RwLock<String>>,
    closed: Arc<AtomicBool>,
    live: Arc<Mutex<Option<Arc<Live>>>>,
}

impl Client {
    pub fn new(url: &str) -> ConvexResult<Self> {
        let parsed = url::Url::parse(url).map_err(|error| Error::Protocol(error.to_string()))?;
        if !matches!(parsed.scheme(), "http" | "https")
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
        {
            return Err(Error::Protocol(
                "deployment URL must be absolute http(s) without credentials".into(),
            ));
        }

        Ok(Self {
            url: url.trim_end_matches('/').into(),
            http: Http::builder()
                .timeout(Duration::from_secs(30))
                .build()
                .map_err(|error| Error::Transport(error.to_string()))?,
            auth: Arc::new(RwLock::new(String::new())),
            closed: Arc::new(AtomicBool::new(false)),
            live: Arc::new(Mutex::new(None)),
        })
    }

    pub fn set_auth(&self, token: &str) -> ConvexResult<()> {
        self.ensure_open()?;
        *self.auth.write().unwrap() = token.into();
        Ok(())
    }

    pub fn query(&self, path: &str, args: Value) -> ConvexResult<Result> {
        self.call("query", path, args)
    }

    pub fn mutation(&self, path: &str, args: Value) -> ConvexResult<Result> {
        self.call("mutation", path, args)
    }

    pub fn action(&self, path: &str, args: Value) -> ConvexResult<Result> {
        self.call("action", path, args)
    }

    fn call(&self, operation: &str, path: &str, args: Value) -> ConvexResult<Result> {
        self.ensure_open()?;
        if path.is_empty() || !args.is_object() {
            return Err(Error::Protocol(
                "function path and object arguments are required".into(),
            ));
        }

        let mut request = self
            .http
            .post(format!("{}/api/{operation}", self.url))
            .header("Convex-Client", "rust-0.1.0")
            .header("Accept", "application/json")
            .json(&json!({"path": path, "args": args, "format": "json"}));
        let token = self.auth.read().unwrap().clone();
        if !token.is_empty() {
            request = request.bearer_auth(token);
        }

        let bytes = request
            .send()
            .map_err(|error| Error::Transport(format!("{operation}: {error}")))?
            .bytes()
            .map_err(|error| Error::Transport(format!("{operation}: {error}")))?;
        if bytes.len() > MAX_RESPONSE {
            return Err(Error::Transport("response exceeds 2 MiB".into()));
        }

        let wire: WireResponse = serde_json::from_slice(&bytes)
            .map_err(|error| Error::Transport(format!("non-Convex response: {error}")))?;
        match wire.status.as_str() {
            "success" => wire
                .value
                .into_option()
                .map(|value| Result {
                    value,
                    logs: wire.logs,
                })
                .ok_or_else(|| Error::Protocol("success omitted value".into())),
            "error" => Err(Error::Function(FunctionError {
                operation: operation.into(),
                message: wire
                    .message
                    .unwrap_or_else(|| "Convex function failed".into()),
                data: wire.data.into_option(),
                logs: wire.logs,
            })),
            _ => Err(Error::Protocol("unknown response status".into())),
        }
    }

    pub fn subscribe(&self, path: &str, args: Value) -> ConvexResult<Subscription> {
        self.ensure_open()?;
        if path.is_empty() || !args.is_object() {
            return Err(Error::Protocol(
                "Live query requires path and object arguments".into(),
            ));
        }

        let live = {
            let mut guard = self.live.lock().unwrap();
            self.ensure_open()?;
            if guard.is_none() {
                *guard = Some(Live::start(&self.url)?);
            }
            guard.as_ref().unwrap().clone()
        };
        live.subscribe(path.to_string(), args)
    }

    pub fn debug_disconnect_for_adapter(&self) -> ConvexResult<()> {
        self.ensure_open()?;
        let live = self
            .live
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| Error::Protocol("Live WebSocket has not been started".into()))?;
        live.debug_disconnect()
    }

    pub fn close(&self) -> ConvexResult<()> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let live = self.live.lock().unwrap().clone();
        if let Some(live) = live {
            live.close()?;
        }
        Ok(())
    }

    fn ensure_open(&self) -> ConvexResult<()> {
        if self.closed.load(Ordering::Acquire) {
            Err(Error::Closed)
        } else {
            Ok(())
        }
    }
}

#[derive(Deserialize)]
struct WireResponse {
    status: String,
    #[serde(default)]
    value: Presence<Value>,
    #[serde(rename = "errorMessage")]
    message: Option<String>,
    #[serde(default, rename = "errorData")]
    data: Presence<Value>,
    #[serde(default, rename = "logLines")]
    logs: Vec<String>,
}

#[derive(Debug, Clone)]
enum Presence<T> {
    Missing,
    Present(T),
}

impl<T> Default for Presence<T> {
    fn default() -> Self {
        Self::Missing
    }
}

impl<'de, T> Deserialize<'de> for Presence<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        T::deserialize(deserializer).map(Self::Present)
    }
}

impl<T> Presence<T> {
    fn into_option(self) -> Option<T> {
        match self {
            Self::Missing => None,
            Self::Present(value) => Some(value),
        }
    }
}

enum Command {
    Add {
        path: String,
        args: Value,
        reply: mpsc::Sender<ConvexResult<(u32, Mailbox)>>,
    },
    Remove {
        id: u32,
        reply: mpsc::Sender<ConvexResult<()>>,
    },
    DebugDisconnect {
        reply: mpsc::Sender<ConvexResult<()>>,
    },
    Close {
        reply: mpsc::Sender<ConvexResult<()>>,
    },
}

struct Live {
    commands: mpsc::Sender<Command>,
}

impl Live {
    fn start(url: &str) -> ConvexResult<Arc<Self>> {
        let websocket_url = to_websocket_url(url)?;
        let (commands, receiver) = mpsc::channel();
        thread::spawn(move || LiveOwner::new(websocket_url, receiver).run());
        Ok(Arc::new(Self { commands }))
    }

    fn subscribe(self: &Arc<Self>, path: String, args: Value) -> ConvexResult<Subscription> {
        let (reply, response) = mpsc::channel();
        self.commands
            .send(Command::Add { path, args, reply })
            .map_err(|_| Error::Closed)?;
        let (id, mailbox) = receive_owner_response(response, "accept subscription")??;
        Ok(Subscription {
            id,
            manager: self.clone(),
            mailbox,
            closed: AtomicBool::new(false),
        })
    }

    fn remove(&self, id: u32) -> ConvexResult<()> {
        let (reply, response) = mpsc::channel();
        self.commands
            .send(Command::Remove { id, reply })
            .map_err(|_| Error::Closed)?;
        receive_owner_response(response, "remove subscription")?
    }

    fn debug_disconnect(&self) -> ConvexResult<()> {
        let (reply, response) = mpsc::channel();
        self.commands
            .send(Command::DebugDisconnect { reply })
            .map_err(|_| Error::Closed)?;
        receive_owner_response(response, "disconnect Live socket")?
    }

    fn close(&self) -> ConvexResult<()> {
        let (reply, response) = mpsc::channel();
        self.commands
            .send(Command::Close { reply })
            .map_err(|_| Error::Closed)?;
        receive_owner_response(response, "close Live owner")?
    }
}

fn receive_owner_response<T>(response: mpsc::Receiver<T>, operation: &str) -> ConvexResult<T> {
    response
        .recv_timeout(OWNER_RESPONSE_TIMEOUT)
        .map_err(|error| match error {
            mpsc::RecvTimeoutError::Timeout => {
                Error::Transport(format!("live owner did not {operation} within 3 seconds"))
            }
            mpsc::RecvTimeoutError::Disconnected => Error::Closed,
        })
}

fn to_websocket_url(url: &str) -> ConvexResult<String> {
    let mut parsed = url::Url::parse(url).map_err(|error| Error::Protocol(error.to_string()))?;
    parsed
        .set_scheme(if parsed.scheme() == "https" {
            "wss"
        } else {
            "ws"
        })
        .map_err(|_| Error::Protocol("websocket scheme".into()))?;
    parsed.set_path(&format!("{}/api/sync", parsed.path().trim_end_matches('/')));
    parsed.set_query(None);
    parsed.set_fragment(None);
    Ok(parsed.to_string())
}

struct Sub {
    path: String,
    args: Value,
    mailbox: Mailbox,
}

struct ConnectorResult {
    generation: u64,
    result: std::result::Result<Socket, String>,
}

struct LiveOwner {
    websocket_url: String,
    commands: mpsc::Receiver<Command>,
    active: BTreeMap<u32, Sub>,
    next_id: u32,
    socket: Option<Socket>,
    query_set_version: u32,
    remote_version: StateVersion,
    max_observed_timestamp: Option<String>,
    connection_count: u32,
    last_close_reason: String,
    retry: Duration,
    reconnect_due: Instant,
    connector_sender: mpsc::Sender<ConnectorResult>,
    connector_receiver: mpsc::Receiver<ConnectorResult>,
    connector_generation: u64,
    connecting: Option<u64>,
}

impl LiveOwner {
    fn new(websocket_url: String, commands: mpsc::Receiver<Command>) -> Self {
        let (connector_sender, connector_receiver) = mpsc::channel();
        Self {
            websocket_url,
            commands,
            active: BTreeMap::new(),
            next_id: 0,
            socket: None,
            query_set_version: 0,
            remote_version: StateVersion::zero(),
            max_observed_timestamp: None,
            connection_count: 0,
            last_close_reason: "InitialConnect".into(),
            retry: INITIAL_BACKOFF,
            reconnect_due: Instant::now(),
            connector_sender,
            connector_receiver,
            connector_generation: 0,
            connecting: None,
        }
    }

    fn run(mut self) {
        loop {
            self.start_connector_if_due();
            self.accept_connector_results();

            while let Ok(command) = self.commands.try_recv() {
                if self.handle_command(command) {
                    return;
                }
            }

            self.read_one_message();
            thread::sleep(Duration::from_millis(2));
        }
    }

    fn start_connector_if_due(&mut self) {
        if self.socket.is_some()
            || self.connecting.is_some()
            || self.active.is_empty()
            || Instant::now() < self.reconnect_due
        {
            return;
        }

        self.connector_generation = self.connector_generation.wrapping_add(1);
        let generation = self.connector_generation;
        self.connecting = Some(generation);
        let target = self.websocket_url.clone();
        let sender = self.connector_sender.clone();
        thread::spawn(move || {
            let result = connect_socket(&target);
            let _ = sender.send(ConnectorResult { generation, result });
        });
    }

    fn accept_connector_results(&mut self) {
        while let Ok(result) = self.connector_receiver.try_recv() {
            if self.connecting != Some(result.generation) {
                // Removing the last query or shutting down invalidates the dial.
                // A peer that completes its handshake late must never become current.
                continue;
            }
            self.connecting = None;
            if self.active.is_empty() || self.socket.is_some() {
                continue;
            }

            match result.result {
                Ok(socket) => self.install_connection(socket),
                Err(reason) => self.record_connection_failure(reason),
            }
        }
    }

    fn install_connection(&mut self, mut socket: Socket) {
        if let Err(error) = set_nonblocking(&mut socket) {
            self.record_connection_failure(error.to_string());
            return;
        }

        let mut connect_message = json!({
            "type": "Connect",
            "sessionId": uuid::Uuid::new_v4().to_string(),
            "connectionCount": self.connection_count,
            "lastCloseReason": self.last_close_reason,
            "clientTs": 0,
        });
        if let Some(timestamp) = &self.max_observed_timestamp {
            connect_message["maxObservedTimestamp"] = Value::String(timestamp.clone());
        }

        if let Err(error) = write_message(&mut socket, connect_message) {
            self.record_connection_failure(error.to_string());
            return;
        }

        let modifications: Vec<Value> = self
            .active
            .iter()
            .map(|(id, sub)| add_modification(*id, &sub.path, &sub.args))
            .collect();
        if !modifications.is_empty() {
            let add = json!({
                "type": "ModifyQuerySet",
                "baseVersion": 0,
                "newVersion": 1,
                "modifications": modifications,
            });
            if let Err(error) = write_message(&mut socket, add) {
                // A reconnect is not installed unless its complete Add batch was
                // written. The next attempt starts again at query-set version zero.
                self.record_connection_failure(error.to_string());
                return;
            }
            self.query_set_version = 1;
        } else {
            self.query_set_version = 0;
        }

        self.remote_version = StateVersion::zero();
        self.socket = Some(socket);
        // Backoff is deliberately not reset here. A handshake and client writes
        // do not prove the server has sent a valid protocol message.
    }

    fn handle_command(&mut self, command: Command) -> bool {
        match command {
            Command::Add { path, args, reply } => {
                let Some(id) = self.next_id.checked_add(1).map(|next| {
                    let id = self.next_id;
                    self.next_id = next;
                    id
                }) else {
                    let _ = reply.send(Err(Error::Protocol(
                        "Live query identifier space exhausted".into(),
                    )));
                    return false;
                };
                let mailbox = Mailbox::new();
                self.active.insert(
                    id,
                    Sub {
                        path: path.clone(),
                        args: args.clone(),
                        mailbox: mailbox.clone(),
                    },
                );

                if let Some(socket) = self.socket.as_mut() {
                    let message = json!({
                        "type": "ModifyQuerySet",
                        "baseVersion": self.query_set_version,
                        "newVersion": self.query_set_version + 1,
                        "modifications": [add_modification(id, &path, &args)],
                    });
                    match write_message(socket, message) {
                        Ok(()) => self.query_set_version += 1,
                        Err(error) => self.disconnect(error.to_string(), true),
                    }
                } else if self.connecting.is_none() {
                    self.reconnect_due = Instant::now();
                }

                // The response comes after the owner has installed the state and
                // attempted any required socket write, making Add a real barrier.
                let _ = reply.send(Ok((id, mailbox)));
            }
            Command::Remove { id, reply } => {
                if let Some(sub) = self.active.remove(&id) {
                    sub.mailbox.close();
                    if let Some(socket) = self.socket.as_mut() {
                        let message = json!({
                            "type": "ModifyQuerySet",
                            "baseVersion": self.query_set_version,
                            "newVersion": self.query_set_version + 1,
                            "modifications": [{"type": "Remove", "queryId": id}],
                        });
                        match write_message(socket, message) {
                            Ok(()) => self.query_set_version += 1,
                            Err(error) => self.disconnect(error.to_string(), true),
                        }
                    }
                }
                if self.active.is_empty() && self.socket.is_none() {
                    self.invalidate_connector();
                }
                // No socket read or delivery can run between removal and this reply.
                let _ = reply.send(Ok(()));
            }
            Command::DebugDisconnect { reply } => {
                if self.socket.is_none() {
                    let _ = reply.send(Err(Error::Transport(
                        "Live WebSocket is not connected".into(),
                    )));
                    return false;
                }
                self.disconnect("adapter debug disconnect".into(), true);
                // Reconnect is scheduled no earlier than the ordinary 100 ms
                // backoff, so the adapter can acknowledge the completed detach.
                let _ = reply.send(Ok(()));
            }
            Command::Close { reply } => {
                self.invalidate_connector();
                self.socket.take();
                for sub in self.active.values() {
                    sub.mailbox.close();
                }
                self.active.clear();
                let _ = reply.send(Ok(()));
                return true;
            }
        }
        false
    }

    fn read_one_message(&mut self) {
        let Some(socket) = self.socket.as_mut() else {
            return;
        };
        let message = match socket.read() {
            Ok(message) => message,
            Err(tungstenite::Error::Io(error))
                if error.kind() == std::io::ErrorKind::WouldBlock =>
            {
                return;
            }
            Err(error) => {
                self.disconnect(error.to_string(), true);
                return;
            }
        };

        match message {
            Message::Text(text) => self.handle_text_message(&text),
            Message::Ping(_) | Message::Pong(_) => {
                if let Some(socket) = self.socket.as_mut() {
                    if let Err(error) = socket.flush() {
                        self.disconnect(error.to_string(), true);
                        return;
                    }
                }
                self.mark_valid_traffic();
            }
            Message::Close(frame) => {
                let reason = frame
                    .map(|frame| format!("websocket close {}: {}", frame.code, frame.reason))
                    .unwrap_or_else(|| "websocket close".into());
                self.disconnect(reason, true);
            }
            Message::Binary(_) | Message::Frame(_) => {
                self.protocol_failure("unexpected non-text WebSocket message".into());
            }
        }
    }

    fn handle_text_message(&mut self, text: &str) {
        let envelope: Envelope = match serde_json::from_str(text) {
            Ok(envelope) => envelope,
            Err(error) => {
                self.protocol_failure(format!("decode server message: {error}"));
                return;
            }
        };

        match envelope.message_type.as_str() {
            "Transition" => match self.validate_transition(text) {
                Ok(changed) => {
                    // Commit happened in validate_transition. Publish only the
                    // newest result for each query, in deterministic ID order.
                    for (id, pending) in changed {
                        if let PendingUpdate::Publish(update) = pending {
                            if let Some(sub) = self.active.get(&id) {
                                sub.mailbox.push(update);
                            }
                        }
                    }
                    self.mark_valid_traffic();
                }
                Err(error) => self.protocol_failure(error),
            },
            "Ping" | "MutationResponse" | "ActionResponse" => self.mark_valid_traffic(),
            "TransitionChunk" => self.protocol_failure(
                "TransitionChunk assembly is not implemented by the Rust demonstration".into(),
            ),
            "FatalError" | "AuthError" => {
                self.protocol_failure(format!("{} from Live server", envelope.message_type));
            }
            other => self.protocol_failure(format!("unknown server message {other}")),
        }
    }

    fn validate_transition(
        &mut self,
        text: &str,
    ) -> std::result::Result<BTreeMap<u32, PendingUpdate>, String> {
        let transition: WireTransition =
            serde_json::from_str(text).map_err(|error| format!("decode Transition: {error}"))?;
        if transition.start_version != self.remote_version {
            return Err(format!(
                "Transition start version {:?} does not match local version {:?}",
                transition.start_version, self.remote_version
            ));
        }
        if transition.end_version.timestamp.is_empty() {
            return Err("Transition end timestamp is empty".into());
        }

        // Build the full replacement set before mutating owner state. If any
        // modification is malformed, serde rejects the entire transition and no
        // subscription observes a partial commit.
        let mut changed = BTreeMap::new();
        for modification in transition.modifications {
            match modification {
                WireModification::QueryUpdated {
                    query_id,
                    value,
                    log_lines,
                } => {
                    changed.insert(
                        query_id,
                        PendingUpdate::Publish(Update {
                            value: Some(value),
                            error: None,
                            logs: log_lines,
                        }),
                    );
                }
                WireModification::QueryFailed {
                    query_id,
                    error_message,
                    error_data,
                    log_lines,
                } => {
                    let error = FunctionError {
                        operation: "query".into(),
                        message: error_message,
                        data: error_data.into_option(),
                        logs: log_lines.clone(),
                    };
                    changed.insert(
                        query_id,
                        PendingUpdate::Publish(Update {
                            value: None,
                            error: Some(Error::Function(error)),
                            logs: log_lines,
                        }),
                    );
                }
                WireModification::QueryRemoved { query_id } => {
                    changed.insert(query_id, PendingUpdate::Removed);
                }
            }
        }

        self.max_observed_timestamp = Some(transition.end_version.timestamp.clone());
        self.remote_version = transition.end_version;
        Ok(changed)
    }

    fn protocol_failure(&mut self, message: String) {
        let error = Error::Protocol(message.clone());
        for sub in self.active.values() {
            sub.mailbox.push(Update {
                value: None,
                error: Some(error.clone()),
                logs: Vec::new(),
            });
        }
        self.disconnect(format!("convex protocol error: {message}"), true);
    }

    fn mark_valid_traffic(&mut self) {
        self.retry = INITIAL_BACKOFF;
    }

    fn disconnect(&mut self, reason: String, reconnect: bool) {
        if self.socket.take().is_some() {
            self.connection_count = self.connection_count.saturating_add(1);
        }
        self.last_close_reason = reason;
        self.query_set_version = 0;
        self.remote_version = StateVersion::zero();
        if reconnect && !self.active.is_empty() {
            self.schedule_reconnect();
        }
    }

    fn record_connection_failure(&mut self, reason: String) {
        self.socket.take();
        self.connection_count = self.connection_count.saturating_add(1);
        self.last_close_reason = reason;
        self.query_set_version = 0;
        self.remote_version = StateVersion::zero();
        if !self.active.is_empty() {
            self.schedule_reconnect();
        }
    }

    fn schedule_reconnect(&mut self) {
        self.reconnect_due = Instant::now() + self.retry;
        self.retry = (self.retry * 2).min(MAX_BACKOFF);
    }

    fn invalidate_connector(&mut self) {
        self.connector_generation = self.connector_generation.wrapping_add(1);
        self.connecting = None;
    }
}

fn connect_socket(url: &str) -> std::result::Result<Socket, String> {
    let mut request = url
        .into_client_request()
        .map_err(|error| error.to_string())?;
    request
        .headers_mut()
        .insert("Convex-Client", HeaderValue::from_static("rust-0.1.0"));
    connect(request)
        .map(|(socket, _)| socket)
        .map_err(|error| error.to_string())
}

fn add_modification(id: u32, path: &str, args: &Value) -> Value {
    json!({"type": "Add", "queryId": id, "udfPath": path, "args": [args]})
}

fn write_message(socket: &mut Socket, value: Value) -> ConvexResult<()> {
    socket
        .send(Message::Text(value.to_string().into()))
        .map_err(|error| Error::Transport(error.to_string()))
}

fn set_nonblocking(socket: &mut Socket) -> ConvexResult<()> {
    let result = match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => stream.set_nonblocking(true),
        MaybeTlsStream::Rustls(stream) => stream.get_mut().set_nonblocking(true),
        _ => return Err(Error::Transport("unsupported TLS stream".into())),
    };
    result.map_err(|error| Error::Transport(error.to_string()))
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
struct StateVersion {
    #[serde(rename = "querySet")]
    query_set: u32,
    identity: u32,
    #[serde(rename = "ts")]
    timestamp: String,
}

impl StateVersion {
    fn zero() -> Self {
        Self {
            query_set: 0,
            identity: 0,
            timestamp: INITIAL_TS.into(),
        }
    }
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    message_type: String,
}

#[derive(Deserialize)]
struct WireTransition {
    #[serde(rename = "startVersion")]
    start_version: StateVersion,
    #[serde(rename = "endVersion")]
    end_version: StateVersion,
    modifications: Vec<WireModification>,
}

#[derive(Deserialize)]
#[serde(tag = "type")]
enum WireModification {
    QueryUpdated {
        #[serde(rename = "queryId")]
        query_id: u32,
        value: Value,
        #[serde(default, rename = "logLines")]
        log_lines: Vec<String>,
    },
    QueryFailed {
        #[serde(rename = "queryId")]
        query_id: u32,
        #[serde(rename = "errorMessage")]
        error_message: String,
        #[serde(default, rename = "errorData")]
        error_data: Presence<Value>,
        #[serde(default, rename = "logLines")]
        log_lines: Vec<String>,
    },
    QueryRemoved {
        #[serde(rename = "queryId")]
        query_id: u32,
    },
}

enum PendingUpdate {
    Publish(Update),
    Removed,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{Shutdown, TcpListener, TcpStream};
    use std::sync::Barrier;
    use tungstenite::protocol::CloseFrame;
    use tungstenite::protocol::frame::coding::CloseCode;

    fn version(query_set: u32, timestamp: &str) -> Value {
        json!({"querySet": query_set, "identity": 0, "ts": timestamp})
    }

    fn transition(start: Value, end: Value, modifications: Vec<Value>) -> Value {
        json!({
            "type": "Transition",
            "startVersion": start,
            "endVersion": end,
            "modifications": modifications,
        })
    }

    fn fixture<F>(script: F) -> String
    where
        F: FnOnce(TcpStream) + Send + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            script(stream);
        });
        format!("http://{address}")
    }

    fn read_connect_and_add(socket: &mut WebSocket<TcpStream>) -> (Value, u32) {
        let connect: Value =
            serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(connect["type"], "Connect");
        let modify: Value =
            serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(modify["type"], "ModifyQuerySet");
        let id = modify["modifications"][0]["queryId"].as_u64().unwrap() as u32;
        (connect, id)
    }

    fn raw_frame(stream: &mut TcpStream, fin: bool, opcode: u8, payload: &[u8]) {
        stream
            .write_all(&[(if fin { 0x80 } else { 0 }) | opcode])
            .unwrap();
        match payload.len() {
            length @ 0..=125 => stream.write_all(&[length as u8]).unwrap(),
            length @ 126..=65535 => {
                stream.write_all(&[126]).unwrap();
                stream.write_all(&(length as u16).to_be_bytes()).unwrap();
            }
            _ => panic!("fixture frame too large"),
        }
        stream.write_all(payload).unwrap();
        stream.flush().unwrap();
    }

    fn http_fixture(responses: Vec<&'static str>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            for response in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0; 1024];
                loop {
                    let count = stream.read(&mut buffer).unwrap();
                    request.extend_from_slice(&buffer[..count]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                let body = response.as_bytes();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .unwrap();
                stream.write_all(body).unwrap();
            }
        });
        format!("http://{address}")
    }

    #[test]
    fn http_distinguishes_json_null_from_an_omitted_value_and_preserves_error_detail() {
        let url = http_fixture(vec![
            r#"{"status":"success","value":null,"logLines":["null result"]}"#,
            r#"{"status":"success","logLines":[]}"#,
            r#"{"status":"error","errorMessage":"nope","errorData":null,"logLines":["before failure"]}"#,
        ]);
        let client = Client::new(&url).unwrap();

        let null = client.query("demo:null", json!({})).unwrap();
        assert_eq!(null.value, Value::Null);
        assert_eq!(null.logs, vec!["null result"]);
        assert!(matches!(
            client.query("demo:missing", json!({})),
            Err(Error::Protocol(message)) if message == "success omitted value"
        ));
        match client.query("demo:error", json!({})).unwrap_err() {
            Error::Function(error) => {
                assert_eq!(error.data, Some(Value::Null));
                assert_eq!(error.logs, vec!["before failure"]);
            }
            other => panic!("expected function error, got {other:?}"),
        }
    }

    #[test]
    fn transition_is_atomic_newest_per_query_and_sorted_by_id() {
        let (_commands, receiver) = mpsc::channel();
        let mut owner = LiveOwner::new("ws://unused".into(), receiver);
        let text = transition(
            version(0, INITIAL_TS),
            version(1, "AQAAAAAAAAA="),
            vec![
                json!({"type":"QueryUpdated","queryId":9,"value":1,"logLines":[]}),
                json!({"type":"QueryUpdated","queryId":2,"value":2,"logLines":[]}),
                json!({"type":"QueryUpdated","queryId":9,"value":3,"logLines":[]}),
            ],
        )
        .to_string();
        let changed = owner.validate_transition(&text).unwrap();
        assert_eq!(changed.keys().copied().collect::<Vec<_>>(), vec![2, 9]);
        match changed.get(&9).unwrap() {
            PendingUpdate::Publish(update) => assert_eq!(update.value, Some(json!(3))),
            PendingUpdate::Removed => panic!("newest query state was removed"),
        }

        let before = owner.remote_version.clone();
        let malformed = transition(
            version(1, "AQAAAAAAAAA="),
            version(1, "AgAAAAAAAAA="),
            vec![
                json!({"type":"QueryUpdated","queryId":2,"value":4,"logLines":[]}),
                json!({"type":"QueryFailed","queryId":9,"errorData":{}}),
            ],
        );
        assert!(owner.validate_transition(&malformed.to_string()).is_err());
        assert_eq!(
            owner.remote_version, before,
            "malformed transition committed partially"
        );
    }

    #[test]
    fn live_delivers_null_fragmented_utf8_and_query_failure_recovery() {
        let url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap();
            let (_, id) = read_connect_and_add(&mut socket);
            let zero = version(0, INITIAL_TS);
            let one = version(1, "AQAAAAAAAAA=");
            let initial = transition(
                zero,
                one.clone(),
                vec![json!({
                    "type":"QueryUpdated",
                    "queryId":id,
                    "value":{"count":0,"word":"雪"},
                    "logLines":[]
                })],
            )
            .to_string()
            .into_bytes();
            let split = initial
                .windows("雪".len())
                .position(|bytes| bytes == "雪".as_bytes())
                .unwrap()
                + 1;
            // Exercise control-frame interleaving and a UTF-8 scalar split
            // across continuation frames before decoding the transition.
            raw_frame(socket.get_mut(), true, 0x9, b"ping");
            raw_frame(socket.get_mut(), false, 0x1, &initial[..split]);
            raw_frame(socket.get_mut(), true, 0x0, &initial[split..]);
            let two = version(1, "AgAAAAAAAAA=");
            socket
                .send(Message::Text(
                    transition(
                        one,
                        two.clone(),
                        vec![json!({
                            "type":"QueryUpdated",
                            "queryId":id,
                            "value":null,
                            "logLines":["null"]
                        })],
                    )
                    .to_string()
                    .into(),
                ))
                .unwrap();
            let three = version(1, "AwAAAAAAAAA=");
            socket
                .send(Message::Text(
                    transition(
                        two,
                        three.clone(),
                        vec![json!({
                            "type":"QueryFailed",
                            "queryId":id,
                            "errorMessage":"empty",
                            "errorData":{"code":"EMPTY"},
                            "logLines":["failed"]
                        })],
                    )
                    .to_string()
                    .into(),
                ))
                .unwrap();
            socket
                .send(Message::Text(
                    transition(
                        three,
                        version(1, "BAAAAAAAAAA="),
                        vec![json!({
                            "type":"QueryUpdated",
                            "queryId":id,
                            "value":{"count":1},
                            "logLines":["recovered"]
                        })],
                    )
                    .to_string()
                    .into(),
                ))
                .unwrap();
        });
        let client = Client::new(&url).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"fixture"}))
            .unwrap();
        let updates = subscription.updates();
        assert_eq!(
            updates
                .recv_timeout(Duration::from_secs(3))
                .unwrap()
                .value
                .unwrap()["word"],
            "雪"
        );
        assert_eq!(
            updates.recv_timeout(Duration::from_secs(3)).unwrap().value,
            Some(Value::Null)
        );
        let failed = updates.recv_timeout(Duration::from_secs(3)).unwrap();
        match failed.error.unwrap() {
            Error::Function(error) => {
                assert_eq!(error.data.unwrap()["code"], "EMPTY");
                assert_eq!(error.logs, vec!["failed"]);
            }
            other => panic!("expected function error, got {other:?}"),
        }
        assert_eq!(
            updates
                .recv_timeout(Duration::from_secs(3))
                .unwrap()
                .value
                .unwrap()["count"],
            1
        );
        client.close().unwrap();
    }

    #[test]
    fn blocked_consumer_keeps_the_newest_sixteen_live_updates() {
        let url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap();
            let (_, id) = read_connect_and_add(&mut socket);
            let mut start = version(0, INITIAL_TS);
            for count in 0..20 {
                let end = version(1, &format!("timestamp-{count}"));
                socket
                    .send(Message::Text(
                        transition(
                            start,
                            end.clone(),
                            vec![json!({
                                "type":"QueryUpdated",
                                "queryId":id,
                                "value":{"count":count},
                                "logLines":[]
                            })],
                        )
                        .to_string()
                        .into(),
                    ))
                    .unwrap();
                start = end;
            }
        });
        let client = Client::new(&url).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"slow"}))
            .unwrap();
        let updates = subscription.updates();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let ready = {
                let (lock, _) = &*updates.0;
                let state = lock.lock().unwrap();
                state.updates.len() == MAILBOX_CAPACITY
                    && state
                        .updates
                        .back()
                        .and_then(|update| update.value.as_ref())
                        .and_then(|value| value["count"].as_i64())
                        == Some(19)
            };
            if ready {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "Live owner did not publish all fixture updates"
            );
            thread::sleep(Duration::from_millis(5));
        }
        for expected in 4..20 {
            assert_eq!(
                updates
                    .recv_timeout(Duration::from_secs(1))
                    .unwrap()
                    .value
                    .unwrap()["count"],
                expected
            );
        }
        client.close().unwrap();
    }

    #[test]
    fn reconnect_metadata_persists_timestamp_and_backoff_resets_only_after_valid_traffic() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let observed = Arc::new(Mutex::new(Vec::new()));
        let observations = observed.clone();
        thread::spawn(move || {
            for attempt in 0..3u32 {
                let (stream, _) = listener.accept().unwrap();
                let mut socket = tungstenite::accept(stream).unwrap();
                let (connect, id) = read_connect_and_add(&mut socket);
                observations
                    .lock()
                    .unwrap()
                    .push((connect.clone(), Instant::now()));
                if attempt == 0 {
                    socket
                        .send(Message::Text(
                            transition(
                                version(0, INITIAL_TS),
                                version(1, "AQAAAAAAAAA="),
                                vec![json!({
                                    "type":"QueryUpdated",
                                    "queryId":id,
                                    "value":{"count":0},
                                    "logLines":[]
                                })],
                            )
                            .to_string()
                            .into(),
                        ))
                        .unwrap();
                    socket
                        .close(Some(CloseFrame {
                            code: CloseCode::Error,
                            reason: "first close".into(),
                        }))
                        .unwrap();
                } else if attempt == 1 {
                    // A syntactically invalid message must not reset backoff or
                    // advance maxObservedTimestamp.
                    socket.send(Message::Text("not json".into())).unwrap();
                } else {
                    socket
                        .send(Message::Text(
                            transition(
                                version(0, INITIAL_TS),
                                version(1, "AgAAAAAAAAA="),
                                vec![json!({
                                    "type":"QueryUpdated",
                                    "queryId":id,
                                    "value":{"count":2},
                                    "logLines":[]
                                })],
                            )
                            .to_string()
                            .into(),
                        ))
                        .unwrap();
                }
            }
        });

        let client = Client::new(&format!("http://{address}")).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"retry"}))
            .unwrap();
        let updates = subscription.updates();
        assert_eq!(
            updates
                .recv_timeout(Duration::from_secs(3))
                .unwrap()
                .value
                .unwrap()["count"],
            0
        );
        assert!(matches!(
            updates.recv_timeout(Duration::from_secs(3)).unwrap().error,
            Some(Error::Protocol(_))
        ));
        assert_eq!(
            updates
                .recv_timeout(Duration::from_secs(3))
                .unwrap()
                .value
                .unwrap()["count"],
            2
        );
        let records = observed.lock().unwrap();
        assert_eq!(
            records
                .iter()
                .map(|(connect, _)| connect["connectionCount"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        assert_eq!(records[0].0.get("maxObservedTimestamp"), None);
        assert_eq!(records[1].0["maxObservedTimestamp"], "AQAAAAAAAAA=");
        assert_eq!(records[2].0["maxObservedTimestamp"], "AQAAAAAAAAA=");
        assert!(
            records[1].0["lastCloseReason"]
                .as_str()
                .unwrap()
                .contains("first close")
        );
        assert!(
            records[2].0["lastCloseReason"]
                .as_str()
                .unwrap()
                .contains("protocol error")
        );
        assert!(
            records[2].1.duration_since(records[1].1) >= Duration::from_millis(175),
            "invalid traffic reset the reconnect backoff"
        );
        client.close().unwrap();
    }

    #[test]
    fn remove_and_close_are_owner_barriers() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server_done = Arc::new(Barrier::new(2));
        let peer_done = server_done.clone();
        thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut socket = tungstenite::accept(stream).unwrap();
            let (_, id) = read_connect_and_add(&mut socket);
            socket
                .send(Message::Text(
                    transition(
                        version(0, INITIAL_TS),
                        version(1, "AQAAAAAAAAA="),
                        vec![json!({
                            "type":"QueryUpdated",
                            "queryId":id,
                            "value":{"count":0},
                            "logLines":[]
                        })],
                    )
                    .to_string()
                    .into(),
                ))
                .unwrap();
            let remove: Value =
                serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap();
            assert_eq!(remove["modifications"][0]["type"], "Remove");
            peer_done.wait();
        });
        let client = Client::new(&format!("http://{address}")).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"barrier"}))
            .unwrap();
        let mailbox = subscription.updates();
        mailbox.recv_timeout(Duration::from_secs(3)).unwrap();
        subscription.close().unwrap();
        server_done.wait();
        assert!(matches!(
            mailbox.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));
        client.close().unwrap();
    }

    #[test]
    fn partial_frame_does_not_block_close_and_late_connector_is_discarded() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let release_handshake = Arc::new(Barrier::new(2));
        let release_peer = release_handshake.clone();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut headers = Vec::new();
            let mut byte = [0; 1];
            while !headers.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                headers.push(byte[0]);
            }
            release_peer.wait();
            // The owner may already be closed. Completing this stale handshake
            // must only cause the connector thread to drop its socket.
            let request = String::from_utf8(headers).unwrap();
            let key = request
                .lines()
                .find(|line| line.to_ascii_lowercase().starts_with("sec-websocket-key:"))
                .unwrap()
                .split_once(':')
                .unwrap()
                .1
                .trim();
            let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
            let _ = write!(
                stream,
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            );
            let _ = stream.shutdown(Shutdown::Both);
        });

        let client = Client::new(&format!("http://{address}")).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"late"}))
            .unwrap();
        let mailbox = subscription.updates();
        thread::sleep(Duration::from_millis(30));
        let started = Instant::now();
        subscription.close().unwrap();
        client.close().unwrap();
        assert!(started.elapsed() < Duration::from_millis(600));
        release_handshake.wait();
        assert!(matches!(
            mailbox.recv_timeout(Duration::from_millis(250)),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));

        let partial_url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap();
            let (_, id) = read_connect_and_add(&mut socket);
            let payload = transition(
                version(0, INITIAL_TS),
                version(1, "AQAAAAAAAAA="),
                vec![json!({
                    "type":"QueryUpdated",
                    "queryId":id,
                    "value":{"word":"partial"},
                    "logLines":[]
                })],
            )
            .to_string();
            raw_frame(socket.get_mut(), false, 0x1, &payload.as_bytes()[..10]);
            thread::sleep(Duration::from_secs(1));
        });
        let client = Client::new(&partial_url).unwrap();
        let subscription = client
            .subscribe("demo:state", json!({"room":"partial"}))
            .unwrap();
        let mailbox = subscription.updates();
        thread::sleep(Duration::from_millis(50));
        let started = Instant::now();
        client.close().unwrap();
        assert!(started.elapsed() < Duration::from_millis(600));
        assert!(matches!(
            mailbox.recv_timeout(Duration::from_millis(250)),
            Err(mpsc::RecvTimeoutError::Disconnected)
        ));
    }
}
