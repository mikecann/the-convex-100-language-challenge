use convex_rust_demo::{Client, Error, FunctionError, Mailbox};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, env, io::{self, BufRead, Write}, net::TcpListener, sync::{Arc, Mutex}, thread, time::Duration};

#[derive(Deserialize)] struct Cmd { id:String, op:String, #[serde(rename="protocolVersion")] version:Option<u32>, path:Option<String>, args:Option<Value>, #[serde(rename="subscriptionId")] subscription:Option<String>, token:Option<String> }
#[derive(Clone)] struct Out(Arc<Mutex<Box<dyn Write + Send>>>);
impl Out { fn send(&self, value:Value) { let mut writer=self.0.lock().unwrap(); serde_json::to_writer(&mut *writer,&value).unwrap(); writer.write_all(b"\n").unwrap(); writer.flush().unwrap(); } }
fn error_shape(error:&Error)->(&'static str,Value){match error { Error::Function(FunctionError{data,..})=>("FunctionError",data.clone().unwrap_or(Value::Null)), Error::Protocol(_)=>("ProtocolError",Value::Null), Error::Transport(_)=>("TransportError",Value::Null), Error::Closed=>("Error",Value::Null) }}
fn fail(out:&Out,id:String,error:Error){let(name,data)=error_shape(&error);out.send(json!({"id":id,"type":"error","error":{"name":name,"message":error.to_string(),"data":data}}));}
fn relay(out:Out, subscription_id:String, generation:u64, mailbox:Mailbox, generations:Arc<Mutex<HashMap<String,u64>>>) { thread::spawn(move || loop { match mailbox.recv_timeout(Duration::from_secs(60)) { Ok(update) => { if generations.lock().unwrap().get(&subscription_id).copied()!=Some(generation) { return; } match update.error { Some(error)=>{let(name,data)=error_shape(&error);out.send(json!({"type":"subscription","subscriptionId":subscription_id,"error":{"name":name,"message":error.to_string(),"data":data}}));}, None=>out.send(json!({"type":"subscription","subscriptionId":subscription_id,"value":update.value,"logs":update.logs})) } }, Err(_) => return } }); }
fn run(reader:impl BufRead, writer:impl Write + Send + 'static) {
 let out=Out(Arc::new(Mutex::new(Box::new(writer)))); let client=Client::new(&env::var("CONVEX_URL").expect("CONVEX_URL is required")).expect("valid CONVEX_URL");
 let subscriptions:Arc<Mutex<HashMap<String,convex_rust_demo::Subscription>>>=Arc::new(Mutex::new(HashMap::new())); let generations=Arc::new(Mutex::new(HashMap::new()));
 for line in reader.lines().map_while(Result::ok) { let command:Cmd=match serde_json::from_str(&line){Ok(value)=>value,Err(_)=>continue}; let args=command.args.unwrap_or_else(||json!({})); match command.op.as_str() {
  "hello" if command.version==Some(1)=>out.send(json!({"protocolVersion":1,"id":command.id,"type":"ready","language":"rust","implementation":"native-rust-0.1.0","runtime":format!("rust-{}",env!("CARGO_PKG_VERSION"))})),
  "query"|"mutation"|"action"=>{let result=match command.op.as_str(){"query"=>client.query(command.path.as_deref().unwrap_or(""),args),"mutation"=>client.mutation(command.path.as_deref().unwrap_or(""),args),_=>client.action(command.path.as_deref().unwrap_or(""),args)};match result{Ok(result)=>out.send(json!({"id":command.id,"type":"result","value":result.value,"logs":result.logs})),Err(error)=>fail(&out,command.id,error)}},
  "setAuth"=>match client.set_auth(command.token.as_deref().unwrap_or("")){Ok(())=>out.send(json!({"id":command.id,"type":"ack"})),Err(error)=>fail(&out,command.id,error)},
  "subscribe"=>{let id=command.subscription.unwrap_or_default();match client.subscribe(command.path.as_deref().unwrap_or(""),args){Ok(subscription)=>{if let Some(old)=subscriptions.lock().unwrap().insert(id.clone(),subscription){let _=old.close();}let generation={let mut map=generations.lock().unwrap();let value=map.get(&id).copied().unwrap_or(0)+1;map.insert(id.clone(),value);value};let mailbox=subscriptions.lock().unwrap().get(&id).unwrap().updates();relay(out.clone(),id.clone(),generation,mailbox,generations.clone());out.send(json!({"id":command.id,"type":"ack"}));},Err(error)=>fail(&out,command.id,error)}},
  "unsubscribe"=>{let id=command.subscription.unwrap_or_default();generations.lock().unwrap().entry(id.clone()).and_modify(|value|*value+=1).or_insert(1);if let Some(subscription)=subscriptions.lock().unwrap().remove(&id){let _=subscription.close();}out.send(json!({"id":command.id,"type":"ack"}));},
  "debugDisconnect"=>match client.debug_disconnect_for_adapter(){Ok(())=>out.send(json!({"id":command.id,"type":"ack"})),Err(error)=>fail(&out,command.id,error)},
  "close"=>{for (_,subscription) in subscriptions.lock().unwrap().drain(){let _=subscription.close();}let _=client.close();out.send(json!({"id":command.id,"type":"closed"}));return},
  _=>fail(&out,command.id,Error::Protocol("unknown operation".into()))
 }}
}
fn main(){if let Ok(address)=env::var("ADAPTER_LISTEN"){let listener=TcpListener::bind(address).expect("bind ADAPTER_LISTEN");let(socket,_)=listener.accept().expect("accept controller");run(io::BufReader::new(socket.try_clone().unwrap()),socket)}else{run(io::BufReader::new(io::stdin()),io::stdout())}}
