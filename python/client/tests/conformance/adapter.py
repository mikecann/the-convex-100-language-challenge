#!/usr/local/bin/python3
import json, os, socket, sys, threading
sys.path.insert(0, os.environ.get('CONVEX_CLIENT_PATH', '/opt/convex/client'))
from convex import Client, FunctionError

def error(exc): return {'name':type(exc).__name__, 'message':str(exc), **({'data':exc.data} if isinstance(exc, FunctionError) else {})}
def run(reader, writer):
    client=None; subscriptions={}; write_lock=threading.Lock()
    def emit(event):
        # Subscription workers and command responses share one NDJSON stream.
        # A lock keeps two JSON records from interleaving on stdout or TCP.
        with write_lock: writer.write(json.dumps(event,separators=(',',':'))+'\n'); writer.flush()
    def forward(subscription_id, subscription):
        while True:
            try:
                update=subscription.next_update()
                if update.error: emit({'type':'subscription','subscriptionId':subscription_id,'error':error(update.error), 'logs':update.logs or []})
                else: emit({'type':'subscription','subscriptionId':subscription_id,'value':update.value,'logs':update.logs or []})
            except Exception: return
    for line in reader:
        command={}; ident=None
        try:
            command=json.loads(line); ident=command.get('id'); op=command['op']
            if op=='hello': event={'protocolVersion':1,'id':ident,'type':'ready','language':'python','implementation':'native-python-3.13','runtime':sys.version.split()[0]}
            elif op in ('query','mutation','action'):
                client=client or Client(os.environ['CONVEX_URL'], os.environ.get('CONVEX_AUTH_TOKEN')); result=getattr(client,op)(command['path'],command.get('args',{})); event={'id':ident,'type':'result','value':result.value,'logs':result.logs}
            elif op=='setAuth': client=client or Client(os.environ['CONVEX_URL']); client.set_auth(command.get('token','')); event={'id':ident,'type':'ack'}
            elif op=='subscribe':
                client=client or Client(os.environ['CONVEX_URL']); subscription=client.subscribe(command['path'],command.get('args',{})); subscriptions[command['subscriptionId']]=subscription
                threading.Thread(target=forward,args=(command['subscriptionId'],subscription),daemon=True).start(); event={'id':ident,'type':'ack'}
            elif op=='unsubscribe': subscriptions.pop(command['subscriptionId']).close(); event={'id':ident,'type':'ack'}
            elif op=='debugDisconnect': client.debug_disconnect_for_adapter(); event={'id':ident,'type':'ack'}
            elif op=='close':
                for sub in subscriptions.values(): sub.close()
                if client: client.close()
                emit({'id':ident,'type':'closed'}); return
            else: raise ValueError(f'unknown adapter operation {op!r}')
        except Exception as exc: event={'id':ident,'type':'error','error':error(exc)} if ident else {'type':'error','error':error(exc)}
        emit(event)
if os.environ.get('ADAPTER_LISTEN'):
    host,port=os.environ['ADAPTER_LISTEN'].rsplit(':',1); server=socket.create_server((host,int(port))); connection,_=server.accept(); stream=connection.makefile('r+'); run(stream,stream)
else: run(sys.stdin,sys.stdout)
