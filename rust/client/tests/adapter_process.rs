//! Child-process adapter regression for same-ID replacement. The fixture sends
//! an old-query transition after the replacement command has been accepted.
use serde_json::{json, Value};
use std::{io::{BufRead, BufReader, Write}, net::TcpListener, process::{Command, Stdio}, sync::mpsc, thread, time::Duration};
use tungstenite::{Message, WebSocket};

fn version(query_set:u32, ts:&str)->Value { json!({"querySet":query_set,"identity":0,"ts":ts}) }
fn transition(start:Value,end:Value,id:u64,count:i64)->String { json!({"type":"Transition","startVersion":start,"endVersion":end,"modifications":[{"type":"QueryUpdated","queryId":id,"value":{"count":count},"logLines":[]}]}).to_string() }
fn add(socket:&mut WebSocket<std::net::TcpStream>)->u64 { let _:Value=serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); let message:Value=serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); message["modifications"][0]["queryId"].as_u64().unwrap() }
fn next(rx:&mpsc::Receiver<String>)->Value { serde_json::from_str(&rx.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap() }

#[test]
fn same_id_replacement_and_unsubscribe_are_relay_barriers() {
    let listener=TcpListener::bind("127.0.0.1:0").unwrap(); let address=listener.local_addr().unwrap();
    thread::spawn(move || { let (stream,_)=listener.accept().unwrap(); let mut socket=tungstenite::accept(stream).unwrap(); let old=add(&mut socket); let zero=version(0,"AAAAAAAAAAA="); let one=version(1,"AQAAAAAAAAA="); socket.send(Message::Text(transition(zero,one.clone(),old,1).into())).unwrap();
        // The adapter may Add(new) before it removes old, but the relay
        // generation is changed before its acknowledgement in either order.
        let first:Value=serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); let second:Value=serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); let new=[first,second].iter().find(|message|message["modifications"][0]["type"]=="Add").unwrap()["modifications"][0]["queryId"].as_u64().unwrap(); let two=version(2,"AgAAAAAAAAA="); socket.send(Message::Text(transition(one.clone(),two.clone(),old,99).into())).unwrap(); let three=version(2,"AwAAAAAAAAA="); socket.send(Message::Text(transition(two,three,new,2).into())).unwrap();
        // The controller then unsubscribes the replacement. A late value must not relay.
        let _:Value=serde_json::from_str(&socket.read().unwrap().into_text().unwrap()).unwrap(); });
    let binary=env!("CARGO_BIN_EXE_convex-adapter"); let mut child=Command::new(binary).env("CONVEX_URL",format!("http://{address}")).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap(); let mut input=child.stdin.take().unwrap(); let stdout=child.stdout.take().unwrap(); let (tx,rx)=mpsc::channel(); thread::spawn(move||for line in BufReader::new(stdout).lines().map_while(Result::ok){let _=tx.send(line);});
    input.write_all(b"{\"id\":\"a\",\"op\":\"subscribe\",\"subscriptionId\":\"X\",\"path\":\"demo:state\",\"args\":{\"room\":\"a\"}}\n").unwrap(); assert_eq!(next(&rx)["id"],"a"); let initial=next(&rx); assert_eq!(initial["value"]["count"],1);
    input.write_all(b"{\"id\":\"b\",\"op\":\"subscribe\",\"subscriptionId\":\"X\",\"path\":\"demo:state\",\"args\":{\"room\":\"b\"}}\n").unwrap(); assert_eq!(next(&rx)["id"],"b"); let replacement=next(&rx); assert_eq!(replacement["type"],"subscription"); assert_eq!(replacement["value"]["count"],2,"stale old value crossed replacement ack");
    input.write_all(b"{\"id\":\"u\",\"op\":\"unsubscribe\",\"subscriptionId\":\"X\"}\n{\"id\":\"c\",\"op\":\"close\"}\n").unwrap(); assert_eq!(next(&rx)["id"],"u"); assert_eq!(next(&rx)["id"],"c"); assert!(child.wait().unwrap().success());
}
