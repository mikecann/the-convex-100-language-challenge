#!/usr/local/bin/python3
import os, secrets, sys
sys.path.insert(0, os.environ.get('CONVEX_CLIENT_PATH', os.path.abspath(os.path.join(os.path.dirname(__file__), '../../client'))))
from convex import Client

def whole(value, operation):
    # Do not let a malformed JSON value look like a successful counter journey.
    if not isinstance(value, int) or isinstance(value, bool): raise RuntimeError(f'{operation} count was {value!r}, expected a whole number')
    return value

def main():
    # Create a native client for the verifier-provided Convex deployment.
    client=Client(os.environ['CONVEX_URL']); room=sys.argv[1] if len(sys.argv)>1 else 'python-example'
    try:
        # Query the unique room over Convex's documented JSON HTTP endpoint.
        current=whole(client.query('demo:state', {'room':room}).value['count'], 'current query'); print(f'current count: {current}')
        # Start Live first so its initial value cannot miss the following mutation.
        subscription=client.subscribe('demo:state', {'room':room})
        try:
            initial=subscription.next_update(10)
            if initial.error: raise initial.error
            if whole(initial.value['count'],'initial Live value') != current: raise RuntimeError('initial Live value disagreed with HTTP')
            print(f'live initial count: {current}')
            # The random runId makes this logical increment idempotent on retries.
            mutation=client.mutation('demo:increment', {'room':room,'language':'python','runId':secrets.token_hex(8)}).value
            if mutation.get('applied') is not True: raise RuntimeError('mutation was not applied')
            print('mutation applied: true'); expected=current+1
            if whole(mutation['state']['count'],'mutation') != expected: raise RuntimeError('mutation count disagreed')
            print(f'mutation count: {expected}')
            changed=subscription.next_update(10)
            if changed.error: raise changed.error
            if whole(changed.value['count'],'updated Live value') != expected: raise RuntimeError('updated Live count disagreed')
            print(f'live updated count: {expected}'); print(f'verified count: {current} -> {expected}')
        finally: subscription.close()
    finally: client.close()
if __name__ == '__main__': main()
