//! A deliberately small native Rust Convex demonstration client.
//! HTTP uses the documented JSON envelope. Live uses the pinned, unversioned
//! `/api/sync` profile from convex-rs 0.10.4; it is not an SDK compatibility promise.
use reqwest::blocking::Client as Http;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::{HashMap, VecDeque}, sync::{mpsc, Arc, Condvar, Mutex, RwLock}, thread, time::{Duration, Instant}};
use tungstenite::{connect, Message, WebSocket};
use tungstenite::stream::MaybeTlsStream;

const INITIAL_TS: &str = "AAAAAAAAAAA=";
const MAX_RESPONSE: usize = 2 << 20;

#[derive(Debug, Clone)] pub struct Result { pub value: Value, pub logs: Vec<String> }
#[derive(Debug, Clone)] pub struct FunctionError { pub operation: String, pub message: String, pub data: Option<Value>, pub logs: Vec<String> }
#[derive(Debug, Clone)] pub enum Error { Function(FunctionError), Protocol(String), Transport(String), Closed }
impl std::fmt::Display for Error { fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result { match self { Self::Function(e)=>write!(f,"convex {} failed: {}",e.operation,e.message), Self::Protocol(s)=>write!(f,"convex protocol error: {s}"), Self::Transport(s)=>write!(f,"convex transport error: {s}"), Self::Closed=>write!(f,"convex client is closed") } } }
impl std::error::Error for Error {}
#[derive(Debug, Clone)] pub struct Update { pub value: Option<Value>, pub error: Option<Error>, pub logs: Vec<String> }
#[derive(Clone)] pub struct Mailbox(Arc<(Mutex<(VecDeque<Update>, bool)>, Condvar)>);
impl Mailbox {
 fn new() -> Self { Self(Arc::new((Mutex::new((VecDeque::with_capacity(16), false)), Condvar::new()))) }
 fn push(&self, update: Update) { let (lock, wake) = &*self.0; let mut state = lock.lock().unwrap(); if state.1 { return; } if state.0.len() == 16 { state.0.pop_front(); } state.0.push_back(update); wake.notify_one(); }
 fn close(&self) { let (lock, wake) = &*self.0; lock.lock().unwrap().1 = true; wake.notify_all(); }
 pub fn recv_timeout(&self, timeout: Duration) -> std::result::Result<Update, mpsc::RecvTimeoutError> { let (lock, wake) = &*self.0; let mut state = lock.lock().unwrap(); let deadline = Instant::now() + timeout; loop { if let Some(update) = state.0.pop_front() { return Ok(update); } if state.1 { return Err(mpsc::RecvTimeoutError::Disconnected); } let remaining = deadline.saturating_duration_since(Instant::now()); if remaining.is_zero() { return Err(mpsc::RecvTimeoutError::Timeout); } let (next, result) = wake.wait_timeout(state, remaining).unwrap(); state = next; if result.timed_out() { return Err(mpsc::RecvTimeoutError::Timeout); } } }
}
pub struct Subscription { id:u32, manager:Arc<Live>, mailbox:Mailbox }
impl Subscription { pub fn close(&self)->std::result::Result<(),Error>{ self.manager.command(Command::Remove(self.id)) } pub fn updates(&self)->Mailbox { self.mailbox.clone() } }
impl Drop for Subscription { fn drop(&mut self){ let _=self.manager.command(Command::Remove(self.id)); } }

#[derive(Clone)] pub struct Client { url:String, http:Http, auth:Arc<RwLock<String>>, closed:Arc<RwLock<bool>>, live:Arc<Mutex<Option<Arc<Live>>>> }
impl Client {
 pub fn new(url:&str)->std::result::Result<Self,Error>{ let u=url::Url::parse(url).map_err(|e|Error::Protocol(e.to_string()))?; if !matches!(u.scheme(),"http"|"https") || u.host_str().is_none() || !u.username().is_empty(){return Err(Error::Protocol("deployment URL must be absolute http(s) without credentials".into()))} Ok(Self{url:url.trim_end_matches('/').into(),http:Http::builder().timeout(Duration::from_secs(30)).build().map_err(|e|Error::Transport(e.to_string()))?,auth:Arc::new(RwLock::new(String::new())),closed:Arc::new(RwLock::new(false)),live:Arc::new(Mutex::new(None))}) }
 pub fn set_auth(&self,token:&str)->std::result::Result<(),Error>{ if *self.closed.read().unwrap(){return Err(Error::Closed)} *self.auth.write().unwrap()=token.into(); Ok(()) }
 pub fn query(&self,path:&str,args:Value)->std::result::Result<Result,Error>{self.call("query",path,args)} pub fn mutation(&self,path:&str,args:Value)->std::result::Result<Result,Error>{self.call("mutation",path,args)} pub fn action(&self,path:&str,args:Value)->std::result::Result<Result,Error>{self.call("action",path,args)}
 fn call(&self,op:&str,path:&str,args:Value)->std::result::Result<Result,Error>{ if *self.closed.read().unwrap(){return Err(Error::Closed)} if path.is_empty()||!args.is_object(){return Err(Error::Protocol("function path and object arguments are required".into()))} let mut r=self.http.post(format!("{}/api/{op}",self.url)).header("Convex-Client","rust-0.1.0").header("Accept","application/json").json(&json!({"path":path,"args":args,"format":"json"})); let token=self.auth.read().unwrap().clone(); if !token.is_empty(){r=r.bearer_auth(token)} let bytes=r.send().map_err(|e|Error::Transport(format!("{op}: {e}")))?.bytes().map_err(|e|Error::Transport(format!("{op}: {e}")))?; if bytes.len()>MAX_RESPONSE{return Err(Error::Transport("response exceeds 2 MiB".into()))} let wire:Wire=serde_json::from_slice(&bytes).map_err(|e|Error::Transport(format!("non-Convex response: {e}")))?; match wire.status.as_str(){"success"=>wire.value.map(|value|Result{value,logs:wire.logs}).ok_or_else(||Error::Protocol("success omitted value".into())),"error"=>Err(Error::Function(FunctionError{operation:op.into(),message:wire.message.unwrap_or_else(||"Convex function failed".into()),data:wire.data,logs:wire.logs})),_=>Err(Error::Protocol("unknown response status".into()))} }
 pub fn subscribe(&self,path:&str,args:Value)->std::result::Result<Subscription,Error>{ if *self.closed.read().unwrap(){return Err(Error::Closed)} if path.is_empty()||!args.is_object(){return Err(Error::Protocol("Live query requires path and object arguments".into()))} let mut guard=self.live.lock().unwrap(); if guard.is_none(){*guard=Some(Live::start(&self.url)?)} let live=guard.as_ref().unwrap().clone(); drop(guard); live.subscribe(path.to_string(),args) }
 pub fn debug_disconnect_for_adapter(&self)->std::result::Result<(),Error>{self.live.lock().unwrap().as_ref().ok_or_else(||Error::Protocol("Live WebSocket has not been started".into()))?.command(Command::Debug)}
 pub fn close(&self)->std::result::Result<(),Error>{*self.closed.write().unwrap()=true; if let Some(l)=self.live.lock().unwrap().as_ref(){l.command(Command::Close)?} Ok(())}
}
#[derive(Deserialize)] struct Wire { status:String, value:Option<Value>, #[serde(rename="errorMessage")] message:Option<String>, #[serde(rename="errorData")] data:Option<Value>, #[serde(default,rename="logLines")] logs:Vec<String> }

enum Command { Add(String,Value,mpsc::Sender<std::result::Result<(u32,Mailbox),Error>>), Remove(u32), Debug, Close }
struct Live { tx:mpsc::Sender<Command> }
impl Live { fn start(url:&str)->std::result::Result<Arc<Self>,Error>{let (tx,rx)=mpsc::channel(); let ws=to_ws(url)?; thread::spawn(move||run_live(ws,rx)); Ok(Arc::new(Self{tx}))} fn command(&self,c:Command)->std::result::Result<(),Error>{self.tx.send(c).map_err(|_|Error::Closed)} fn subscribe(&self,path:String,args:Value)->std::result::Result<Subscription,Error>{let (tx,rx)=mpsc::channel();self.command(Command::Add(path,args,tx))?;let (id,mailbox)=rx.recv_timeout(Duration::from_secs(3)).map_err(|_|Error::Transport("live owner did not accept subscription".into()))??;Ok(Subscription{id,manager:Arc::new(Self{tx:self.tx.clone()}),mailbox})} }
fn to_ws(url:&str)->std::result::Result<String,Error>{let mut u=url::Url::parse(url).map_err(|e|Error::Protocol(e.to_string()))?;u.set_scheme(if u.scheme()=="https"{"wss"}else{"ws"}).map_err(|_|Error::Protocol("websocket scheme".into()))?;u.set_path(&format!("{}/api/sync",u.path().trim_end_matches('/')));u.set_query(None);Ok(u.to_string())}
struct Sub { path:String,args:Value,mailbox:Mailbox }
fn deliver(s:&Sub,u:Update){s.mailbox.push(u);}
fn run_live(ws_url: String, rx: mpsc::Receiver<Command>) {
    let mut active: HashMap<u32, Sub> = HashMap::new(); let mut next = 0; let mut socket = None;
    let mut qsv = 0; let mut remote = json!({"querySet":0,"identity":0,"ts":INITIAL_TS});
    let mut count = 0; let mut last = "InitialConnect".to_string(); let mut retry = Duration::from_millis(100); let mut due = Instant::now();
    // Connecting (and TLS handshake) happens outside the owner loop. This keeps
    // close/unsubscribe bounded even if a peer accepts TCP and never completes
    // a WebSocket handshake. A late successful connector is simply dropped.
    let (connector_tx, connector_rx) = mpsc::channel(); let mut connecting = false;
    loop {
        if socket.is_none() && !connecting && !active.is_empty() && Instant::now() >= due {
            connecting = true; let target = ws_url.clone(); let result = connector_tx.clone();
            thread::spawn(move || { let _ = result.send(connect(&target).map(|(socket, _)| socket).map_err(|error| error.to_string())); });
        }
        while let Ok(result) = connector_rx.try_recv() {
            connecting = false;
            if active.is_empty() || socket.is_some() { continue; }
            match result {
                Ok(mut connected) => {
                    set_nonblocking(&mut connected); qsv = 0; remote = json!({"querySet":0,"identity":0,"ts":INITIAL_TS});
                    let hello = json!({"type":"Connect","sessionId":uuid::Uuid::new_v4().to_string(),"connectionCount":count,"lastCloseReason":last,"maxObservedTimestamp":remote["ts"],"clientTs":0});
                    if write(&mut connected, hello).is_ok() {
                        let mods: Vec<Value> = active.iter().map(|(id, sub)| json!({"type":"Add","queryId":id,"udfPath":sub.path,"args":[sub.args]})).collect();
                        if !mods.is_empty() { let _ = write(&mut connected, json!({"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,"modifications":mods})); qsv = 1; }
                        socket = Some(connected); retry = Duration::from_millis(100); continue;
                    }
                }
                Err(error) => last = error,
            }
            count += 1; due = Instant::now() + retry; retry = (retry * 2).min(Duration::from_secs(15));
        }
        /*if socket.is_none() && !active.is_empty() && Instant::now() >= due {
            match connect(&ws_url) {
                Ok((mut connected, _)) => {
                    set_nonblocking(&mut connected); qsv = 0; remote = json!({"querySet":0,"identity":0,"ts":INITIAL_TS});
                    let hello = json!({"type":"Connect","sessionId":uuid::Uuid::new_v4().to_string(),"connectionCount":count,"lastCloseReason":last,"maxObservedTimestamp":remote["ts"],"clientTs":0});
                    if write(&mut connected, hello).is_ok() {
                        let mods: Vec<Value> = active.iter().map(|(id, sub)| json!({"type":"Add","queryId":id,"udfPath":sub.path,"args":[sub.args]})).collect();
                        if !mods.is_empty() { let _ = write(&mut connected, json!({"type":"ModifyQuerySet","baseVersion":0,"newVersion":1,"modifications":mods})); qsv = 1; }
                        socket = Some(connected); retry = Duration::from_millis(100);
                    }
                }
                Err(error) => last = error.to_string(),
            }
            if socket.is_none() { count += 1; due = Instant::now() + retry; retry = (retry * 2).min(Duration::from_secs(15)); }
        }*/
        while let Ok(command) = rx.try_recv() {
            match command {
                Command::Add(path, args, reply) => {
                    let id = next; next += 1; let mailbox = Mailbox::new();
                    active.insert(id, Sub { path: path.clone(), args: args.clone(), mailbox: mailbox.clone() }); let _ = reply.send(Ok((id, mailbox)));
                    if let Some(s) = socket.as_mut() { if write(s, json!({"type":"ModifyQuerySet","baseVersion":qsv,"newVersion":qsv+1,"modifications":[{"type":"Add","queryId":id,"udfPath":path,"args":[args]}]})).is_ok() { qsv += 1; } else { socket = None; } }
                }
                Command::Remove(id) => { if let Some(sub) = active.remove(&id) { sub.mailbox.close(); if let Some(s) = socket.as_mut() { if write(s, json!({"type":"ModifyQuerySet","baseVersion":qsv,"newVersion":qsv+1,"modifications":[{"type":"Remove","queryId":id}]})).is_ok() { qsv += 1; } else { socket = None; } } } }
                Command::Debug => { if socket.take().is_some() { last = "adapter debug disconnect".into(); count += 1; due = Instant::now() + retry; } }
                Command::Close => { for sub in active.values() { sub.mailbox.close(); } return },
            }
        }
        let message = socket.as_mut().and_then(|s| match s.read() { Ok(Message::Text(text)) => Some(Ok(text.to_string())), Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => None, Err(e) => Some(Err(e.to_string())), _ => None });
        if let Some(Err(ref reason)) = message { socket = None; last = reason.clone(); count += 1; due = Instant::now() + retry; retry = (retry * 2).min(Duration::from_secs(15)); }
        if let Some(Ok(text)) = message {
            let raw: Value = match serde_json::from_str(&text) { Ok(v) => v, Err(e) => { broadcast(&active, Error::Protocol(e.to_string())); socket = None; continue; } };
            if raw["type"] == "Transition" {
                if raw["startVersion"] != remote { broadcast(&active, Error::Protocol("Transition start version mismatch".into())); socket = None; continue; }
                remote = raw["endVersion"].clone();
                for modification in raw["modifications"].as_array().into_iter().flatten() {
                    let id = modification["queryId"].as_u64().unwrap_or(u64::MAX) as u32;
                    if let Some(sub) = active.get(&id) { match modification["type"].as_str() {
                        Some("QueryUpdated") => deliver(sub, Update { value: modification.get("value").cloned(), error: None, logs: strings(modification.get("logLines")) }),
                        Some("QueryFailed") => deliver(sub, Update { value: None, error: Some(Error::Function(FunctionError { operation: "query".into(), message: modification["errorMessage"].as_str().unwrap_or("query failed").into(), data: modification.get("errorData").cloned(), logs: strings(modification.get("logLines")) })), logs: strings(modification.get("logLines")) }),
                        Some("QueryRemoved") => {}, _ => { broadcast(&active, Error::Protocol("unknown Transition modification".into())); socket = None; }
                    }}
                }
            }
        }
        thread::sleep(Duration::from_millis(5));
    }
}
fn strings(v:Option<&Value>)->Vec<String>{v.and_then(Value::as_array).map(|x|x.iter().filter_map(|v|v.as_str().map(str::to_owned)).collect()).unwrap_or_default()}
fn broadcast(active:&HashMap<u32,Sub>,e:Error){for s in active.values(){deliver(s,Update{value:None,error:Some(e.clone()),logs:vec![]})}}
fn write(s:&mut WebSocket<MaybeTlsStream<std::net::TcpStream>>,v:Value)->std::result::Result<(),Error>{s.send(Message::Text(v.to_string().into())).map_err(|e|Error::Transport(e.to_string()))}
fn set_nonblocking(s:&mut WebSocket<MaybeTlsStream<std::net::TcpStream>>){match s.get_mut(){MaybeTlsStream::Plain(x)=>{let _=x.set_nonblocking(true);},MaybeTlsStream::Rustls(x)=>{let _=x.get_mut().set_nonblocking(true);},_=>{}}}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::Write, net::TcpListener};

    fn transition(start: Value, end: Value, modification: Value) -> Value {
        json!({"type":"Transition","startVersion":start,"endVersion":end,"modifications":[modification]})
    }
    fn version(query_set: u32, ts: &str) -> Value { json!({"querySet":query_set,"identity":0,"ts":ts}) }
    fn fixture<F>(script: F) -> String where F: FnOnce(std::net::TcpStream) + Send + 'static {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || { let (stream, _) = listener.accept().unwrap(); script(stream); });
        format!("http://{address}")
    }
    fn read_add(socket: &mut WebSocket<std::net::TcpStream>) -> u32 {
        assert_eq!(socket.read().unwrap().into_text().unwrap().contains("\"type\":\"Connect\""), true);
        let modify: Value = serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(modify["type"], "ModifyQuerySet"); modify["modifications"][0]["queryId"].as_u64().unwrap() as u32
    }
    fn raw_frame(stream: &mut std::net::TcpStream, fin: bool, opcode: u8, payload: &[u8]) {
        stream.write_all(&[(if fin { 0x80 } else { 0 }) | opcode]).unwrap();
        match payload.len() { n @ 0..=125 => stream.write_all(&[n as u8]).unwrap(), n @ 126..=65535 => { stream.write_all(&[126]).unwrap(); stream.write_all(&(n as u16).to_be_bytes()).unwrap(); }, _ => panic!("fixture frame too large") }
        stream.write_all(payload).unwrap(); stream.flush().unwrap();
    }

    #[test]
    fn live_delivers_fragmented_utf8_and_query_failure_recovery() {
        let url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap(); let id = read_add(&mut socket);
            let zero = version(0, INITIAL_TS); let one = version(1, "AQAAAAAAAAA=");
            let initial = transition(zero.clone(), one.clone(), json!({"type":"QueryUpdated","queryId":id,"value":{"count":0,"word":"雪"},"logLines":[]})).to_string();
            // The payload includes a non-ASCII scalar to exercise UTF-8 decoding.
            socket.send(Message::Text(initial.into())).unwrap();
            let two = version(1, "AgAAAAAAAAA=");
            socket.send(Message::Text(transition(one.clone(), two.clone(), json!({"type":"QueryFailed","queryId":id,"errorMessage":"empty","errorData":{"code":"EMPTY"},"logLines":["failed"]})).to_string().into())).unwrap();
            let three = version(1, "AwAAAAAAAAA=");
            socket.send(Message::Text(transition(two, three, json!({"type":"QueryUpdated","queryId":id,"value":{"count":1},"logLines":["recovered"]})).to_string().into())).unwrap();
        });
        let client = Client::new(&url).unwrap(); let subscription = client.subscribe("demo:state", json!({"room":"fixture"})).unwrap(); let updates = subscription.updates();
        let first = updates.recv_timeout(Duration::from_secs(3)).unwrap(); assert_eq!(first.value.unwrap()["word"], "雪");
        let failed = updates.recv_timeout(Duration::from_secs(3)).unwrap(); match failed.error.unwrap() { Error::Function(error) => assert_eq!(error.data.unwrap()["code"], "EMPTY"), other => panic!("expected function error, got {other:?}") }
        assert_eq!(updates.recv_timeout(Duration::from_secs(3)).unwrap().value.unwrap()["count"], 1);
        let _ = client.close();
    }

    #[test]
    fn mailbox_keeps_the_newest_sixteen_updates() {
        let mailbox = Mailbox::new(); let sub = Sub { path: "demo:state".into(), args: json!({}), mailbox: mailbox.clone() };
        for count in 0..20 { deliver(&sub, Update { value: Some(json!({"count":count})), error: None, logs: vec![] }); }
        for expected in 4..20 { assert_eq!(mailbox.recv_timeout(Duration::from_millis(10)).unwrap().value.unwrap()["count"], expected); }
        assert!(matches!(mailbox.recv_timeout(Duration::from_millis(10)), Err(mpsc::RecvTimeoutError::Timeout)));
    }

    #[test]
    fn live_retries_five_closed_connections_then_hydrates_with_connection_metadata() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap(); let address = listener.local_addr().unwrap();
        let observed = Arc::new(Mutex::new(Vec::new())); let observations = observed.clone();
        thread::spawn(move || for attempt in 0..6u32 {
            let (stream, _) = listener.accept().unwrap(); let mut socket = tungstenite::accept(stream).unwrap();
            let connect: Value = serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap();
            observations.lock().unwrap().push((connect["connectionCount"].as_u64().unwrap() as u32, connect["lastCloseReason"].as_str().unwrap().to_owned()));
            if attempt < 5 { drop(socket); continue; }
            let id = serde_json::from_str::<Value>(&socket.read().unwrap().into_text().unwrap()).unwrap()["modifications"][0]["queryId"].as_u64().unwrap();
            socket.send(Message::Text(transition(version(0, INITIAL_TS), version(1, "AQAAAAAAAAA="), json!({"type":"QueryUpdated","queryId":id,"value":{"count":6},"logLines":[]})).to_string().into())).unwrap();
        });
        let client = Client::new(&format!("http://{address}")).unwrap(); let subscription = client.subscribe("demo:state", json!({"room":"retry"})).unwrap();
        assert_eq!(subscription.updates().recv_timeout(Duration::from_secs(12)).unwrap().value.unwrap()["count"], 6);
        let records = observed.lock().unwrap(); assert_eq!(records.iter().map(|(count, _)| *count).collect::<Vec<_>>(), vec![0,1,2,3,4,5]); assert_eq!(records[0].1, "InitialConnect"); assert_ne!(records[5].1, "InitialConnect");
        let _ = client.close();
    }

    #[test]
    fn live_handles_ping_and_raw_fragmented_utf8_text() {
        let url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap(); let id = read_add(&mut socket);
            let payload = transition(version(0, INITIAL_TS), version(1, "AQAAAAAAAAA="), json!({"type":"QueryUpdated","queryId":id,"value":{"word":"雪"},"logLines":[]})).to_string().into_bytes();
            let split = payload.windows("雪".len()).position(|bytes| bytes == "雪".as_bytes()).unwrap() + 1;
            let raw = socket.get_mut(); raw_frame(raw, true, 0x9, b"ping"); raw_frame(raw, false, 0x1, &payload[..split]); raw_frame(raw, true, 0x0, &payload[split..]);
        });
        let client = Client::new(&url).unwrap(); let subscription = client.subscribe("demo:state", json!({"room":"fragment"})).unwrap();
        assert_eq!(subscription.updates().recv_timeout(Duration::from_secs(3)).unwrap().value.unwrap()["word"], "雪"); let _ = client.close();
    }

    #[test]
    fn unsubscribe_is_a_barrier_against_a_late_transition() {
        let url = fixture(|stream| {
            let mut socket = tungstenite::accept(stream).unwrap(); let id = read_add(&mut socket);
            let zero = version(0, INITIAL_TS); let one = version(1, "AQAAAAAAAAA=");
            socket.send(Message::Text(transition(zero, one.clone(), json!({"type":"QueryUpdated","queryId":id,"value":{"count":0},"logLines":[]})).to_string().into())).unwrap();
            let remove: Value = serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); assert_eq!(remove["modifications"][0]["type"], "Remove");
            socket.send(Message::Text(transition(one, version(2, "AgAAAAAAAAA="), json!({"type":"QueryUpdated","queryId":id,"value":{"count":99},"logLines":[]})).to_string().into())).unwrap();
        });
        let client = Client::new(&url).unwrap(); let subscription = client.subscribe("demo:state", json!({"room":"remove"})).unwrap(); let mailbox = subscription.updates();
        assert_eq!(mailbox.recv_timeout(Duration::from_secs(3)).unwrap().value.unwrap()["count"], 0);
        subscription.close().unwrap(); assert!(matches!(mailbox.recv_timeout(Duration::from_millis(250)), Err(mpsc::RecvTimeoutError::Disconnected)));
        let _ = client.close();
    }

    #[test]
    fn close_is_bounded_while_a_peer_stalls_the_websocket_handshake() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap(); let address = listener.local_addr().unwrap();
        thread::spawn(move || { let (_stream, _) = listener.accept().unwrap(); thread::sleep(Duration::from_secs(2)); });
        let client = Client::new(&format!("http://{address}")).unwrap(); let subscription = client.subscribe("demo:state", json!({"room":"stall"})).unwrap(); let mailbox = subscription.updates();
        thread::sleep(Duration::from_millis(30)); let started = Instant::now(); client.close().unwrap();
        assert!(matches!(mailbox.recv_timeout(Duration::from_millis(500)), Err(mpsc::RecvTimeoutError::Disconnected))); assert!(started.elapsed() < Duration::from_millis(600));
    }
}
