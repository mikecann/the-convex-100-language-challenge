import math, os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__)); from main import whole
class TestExample(unittest.TestCase):
    def test_whole(self): self.assertEqual(whole(0,'test'),0); self.assertRaises(RuntimeError,whole,True,'test'); self.assertRaises(RuntimeError,whole,0.5,'test')
