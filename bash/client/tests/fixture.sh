#!/usr/bin/env bash
# Deterministic HTTP + RFC6455 fixture. It speaks network protocols rather than
# mocking client functions, so tests exercise the same bytes as a deployment.
set -euo pipefail
state_dir=${BASH_FIXTURE_STATE:-/tmp/bash-convex-fixture}
mkdir -p "$state_dir"
exec 2>>"$state_dir/fixture.err"
if [[ ${BASH_FIXTURE_TRACE:-0} = 1 ]]; then exec 8>>"$state_dir/fixture.trace"; BASH_XTRACEFD=8; set -x; fi

write_byte() { printf "\\$(printf '%03o' "$1")"; }
server_frame() {
  local text=$1 opcode=${2:-1} final=${3:-1} n i
  n=$(printf %s "$text" | wc -c | tr -d ' '); write_byte $((final * 128 | opcode))
  if ((n<126)); then write_byte "$n"; elif ((n<65536)); then write_byte 126; write_byte $((n>>8)); write_byte $((n&255)); else return 2; fi
  printf %s "$text"
}
read_byte() { dd bs=1 count=1 status=none | od -An -tu1 | tr -d ' \n'; }
client_frame() {
  local first second n i masks=() bytes value out=''
  first=$(read_byte); second=$(read_byte); n=$((second&127));
  if ((n==126)); then n=$(( $(read_byte)*256 + $(read_byte) )); elif ((n==127)); then n=0; for i in 1 2 3 4 5 6 7 8; do n=$((n*256+$(read_byte))); done; fi
  for i in 0 1 2 3; do masks[$i]=$(read_byte); done
  bytes=$(dd bs=1 count="$n" status=none | od -An -v -tu1); i=0
  for value in $bytes; do printf -v out '%s\\%03o' "$out" $((value ^ masks[i%4])); ((i++)) || true; done
  printf '%b' "$out"
}
http_response() { local body=$1; printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$(printf %s "$body" | wc -c | tr -d ' ')" "$body"; }

IFS= read -r request; request=${request%$'\r'}; length=0; key=
while IFS= read -r header; do
  header=${header%$'\r'}; [[ -z $header ]] && break
  case ${header,,} in content-length:*) length=${header#*: }; length=${length%$'\r'};; sec-websocket-key:*) key=${header#*: }; key=${key%$'\r'};; esac
done
if [[ $request = GET\ /api/sync* ]]; then
  accept=$(printf '%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11' "$key" | openssl dgst -sha1 -binary | openssl base64 -A)
  printf 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' "$accept"
  connect=$(client_frame)
  jq -e '.type=="Connect" and (.sessionId|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))' <<<"$connect" >/dev/null
  printf '%s\n' "$connect" >>"$state_dir/ws.log"
  last=-1
  while modify=$(client_frame); do
    printf '%s\n' "$modify" >>"$state_dir/ws.log"
    while IFS=$'\t' read -r kind q path args; do
      [[ $kind = Remove ]] && continue
      room=$(jq -r '.[0].room // "default"' <<<"$args"); active_q=$q; active_room=$room; room_key=$(printf %s "$room" | sha256sum | cut -d' ' -f1); count_file="$state_dir/$room_key"
      count=$(test -f "$count_file" && cat "$count_file" || printf 0); last=$count
      if [[ $path = demo:requiresNonzero && $count = 0 ]]; then
        transition=$(jq -cn --argjson q "$q" '{type:"Transition",startVersion:{querySet:0,identity:0,ts:"AAAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},modifications:[{type:"QueryFailed",queryId:$q,errorMessage:"room is empty",errorData:{code:"ROOM_EMPTY"},logLines:["query demo:requiresNonzero"]}]}')
      else
        transition=$(jq -cn --argjson q "$q" --arg room "$room" --argjson count "$count" '{type:"Transition",startVersion:{querySet:0,identity:0,ts:"AAAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},modifications:[{type:"QueryUpdated",queryId:$q,value:{room:$room,count:$count,lastLanguage:null,latestRunId:null,updatedAt:null},logLines:["query demo:state 世界 👋"]}]}')
      fi
      # Split a long UTF-8 message across continuation frames.
      split=70; server_frame "${transition:0:split}" 1 0; server_frame "${transition:split}" 0 1
    done < <(jq -r '.modifications[] | [.type,.queryId,(.udfPath // ""),(.args|tojson)] | @tsv' <<<"$modify")
    # Poll the room state while still accepting control frames.
    while :; do
      if IFS= read -r -N 1 -t 0.02 peek; then
        # Put the already-read first header byte back through a tiny decoder path.
        first=$(printf %s "$peek" | od -An -tu1 | tr -d ' '); second=$(read_byte); n=$((second&127)); if ((n==126)); then n=$(( $(read_byte)*256+$(read_byte) )); fi
        masks=(); for i in 0 1 2 3; do masks[$i]=$(read_byte); done; bytes=$(dd bs=1 count="$n" status=none | od -An -v -tu1); decoded=''; i=0; for value in $bytes; do printf -v decoded '%s\\%03o' "$decoded" $((value^masks[i%4])); ((i++))||true; done; modify=$(printf '%b' "$decoded"); printf '%s\n' "$modify" >>"$state_dir/ws.log"; break
      fi
      count=$(test -f "$count_file" && cat "$count_file" || printf 0)
      if [[ $count != "$last" ]]; then last=$count; transition=$(jq -cn --argjson q "$active_q" --arg room "$active_room" --argjson count "$count" '{type:"Transition",startVersion:{querySet:1,identity:0,ts:"AQAAAAAAAAA="},endVersion:{querySet:1,identity:0,ts:"AgAAAAAAAAA="},modifications:[{type:"QueryUpdated",queryId:$q,value:{room:$room,count:$count,lastLanguage:"Bash",latestRunId:"fixture",updatedAt:1},logLines:[]}]}'); server_frame "$transition"; fi
    done
  done
  exit 0
fi

# Content-Length is bytes, while Bash read -N counts locale characters. dd keeps
# UTF-8 request bodies byte-exact.
body=; ((length)) && body=$(dd bs=1 count="$length" status=none)
path=$(jq -r .path <<<"$body"); args=$(jq -c .args <<<"$body")
case $path in
  demo:echo) response=$(jq -cn --argjson value "$(jq -c .value <<<"$args")" '{status:"success",value:$value,logLines:["query demo:echo"]}') ;;
  demo:fail) response=$(jq -cn --arg code "$(jq -r .code <<<"$args")" '{status:"error",errorMessage:"expected fixture error",errorData:{code:$code},logLines:["query demo:fail"]}') ;;
  demo:greet) response='{"status":"success","value":{"message":"Convex is responding to Bash"},"logLines":[]}' ;;
  demo:state|demo:increment)
    room=$(jq -r .room <<<"$args"); room_key=$(printf %s "$room" | sha256sum | cut -d' ' -f1); count_file="$state_dir/$room_key"; count=$(test -f "$count_file" && cat "$count_file" || printf 0)
    if [[ $path = demo:increment ]]; then count=$((count+1)); printf %s "$count" >"$count_file"; response=$(jq -cn --argjson count "$count" '{status:"success",value:{applied:true,state:{count:$count}},logLines:[]}');
    else response=$(jq -cn --arg room "$room" --argjson count "$count" '{status:"success",value:{room:$room,count:$count,lastLanguage:null,latestRunId:null,updatedAt:null},logLines:[]}'); fi ;;
  *) response='{"status":"error","errorMessage":"unknown fixture path","errorData":{"code":"UNKNOWN"}}' ;;
esac
http_response "$response"
