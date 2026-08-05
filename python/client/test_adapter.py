import json, os, socket, subprocess, sys, time, unittest

class TestAdapterTCP(unittest.TestCase):
    def test_tcp_ndjson_lifecycle_and_optional_ids(self):
        probe=socket.socket(); probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]; probe.close()
        env=dict(os.environ, ADAPTER_LISTEN=f'127.0.0.1:{port}', PYTHONPATH='/work/client')
        process=subprocess.Popen([sys.executable, '/work/client/tests/conformance/adapter.py'], env=env)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline=time.monotonic()+2
        while True:
            try: connection=socket.create_connection(('127.0.0.1',port),.1); break
            except OSError:
                if time.monotonic()>deadline: self.fail('adapter did not listen')
                time.sleep(.02)
        reader=connection.makefile('r'); writer=connection.makefile('w'); writer.write('{bad json}\n'); writer.flush()
        malformed=json.loads(reader.readline()); self.assertNotIn('id', malformed); self.assertEqual(malformed['type'],'error')
        writer.write('{"protocolVersion":1,"op":"hello"}\n'); writer.flush()
        ready=json.loads(reader.readline()); self.assertNotIn('id',ready); self.assertEqual(ready['language'],'python')
        writer.write('{"id":"bye","op":"close"}\n'); writer.flush()
        self.assertEqual(json.loads(reader.readline()), {'id':'bye','type':'closed'})
        reader.close(); writer.close(); connection.close(); self.assertEqual(process.wait(2),0)
