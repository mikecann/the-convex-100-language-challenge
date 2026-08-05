import contextlib, io, os, sys, types, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(__file__)); import main
whole = main.whole
class TestExample(unittest.TestCase):
    def test_whole(self): self.assertEqual(whole(0,'test'),0); self.assertRaises(RuntimeError,whole,True,'test'); self.assertRaises(RuntimeError,whole,0.5,'test')
    def test_exact_transcript_and_cleanup(self):
        class Subscription:
            def __init__(self): self.values=iter([types.SimpleNamespace(value={'count':0}, error=None), types.SimpleNamespace(value={'count':1}, error=None)]); self.closed=False
            def next_update(self, timeout): return next(self.values)
            def close(self): self.closed=True
        class Client:
            instance=None
            def __init__(self,url): Client.instance=self; self.subscription=Subscription(); self.closed=False
            def query(self,*args): return types.SimpleNamespace(value={'count':0})
            def subscribe(self,*args): return self.subscription
            def mutation(self,*args): return types.SimpleNamespace(value={'applied':True,'state':{'count':1}})
            def close(self): self.closed=True
        old_client, old_argv = main.Client, sys.argv
        main.Client=Client; sys.argv=['main.py','unique-room']; output=io.StringIO()
        try:
            with mock.patch.dict(os.environ, {'CONVEX_URL':'http://example.test'}), contextlib.redirect_stdout(output): main.main()
        finally: main.Client=old_client; sys.argv=old_argv
        self.assertEqual(output.getvalue(), 'current count: 0\nlive initial count: 0\nmutation applied: true\nmutation count: 1\nlive updated count: 1\nverified count: 0 -> 1\n')
        self.assertTrue(Client.instance.closed); self.assertTrue(Client.instance.subscription.closed)
