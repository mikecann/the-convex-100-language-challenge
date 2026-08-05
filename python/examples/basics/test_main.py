import contextlib, io, os, sys, types, unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import main

whole = main.whole


class TestExample(unittest.TestCase):
    def test_whole_normalizes_integral_json_floats(self):
        self.assertEqual(whole(0.0, "test"), 0)
        self.assertIsInstance(whole(0.0, "test"), int)
        self.assertEqual(whole(1.0, "test"), 1)
        self.assertEqual(whole(-0.0, "test"), 0)

    def test_whole_rejects_values_that_cannot_be_counter_states(self):
        for value in (
            True,
            False,
            0.5,
            float("nan"),
            float("inf"),
            float("-inf"),
            "0",
            None,
        ):
            with self.subTest(value=value):
                self.assertRaises(RuntimeError, whole, value, "test")

    def test_integral_float_payloads_complete_and_cleanup(self):
        class Subscription:
            def __init__(self):
                self.values = iter(
                    [
                        types.SimpleNamespace(value={"count": 0.0}, error=None),
                        types.SimpleNamespace(value={"count": 1.0}, error=None),
                    ]
                )
                self.closed = False

            def next_update(self, timeout):
                return next(self.values)

            def close(self):
                self.closed = True

        class Client:
            instance = None

            def __init__(self, url):
                Client.instance = self
                self.subscription = Subscription()
                self.closed = False

            def query(self, *args):
                return types.SimpleNamespace(value={"count": 0.0})

            def subscribe(self, *args):
                return self.subscription

            def mutation(self, *args):
                return types.SimpleNamespace(
                    value={"applied": True, "state": {"count": 1.0}}
                )

            def close(self):
                self.closed = True

        old_client, old_argv = main.Client, sys.argv
        main.Client = Client
        sys.argv = ["main.py", "unique-room"]
        output = io.StringIO()
        try:
            with mock.patch.dict(
                os.environ, {"CONVEX_URL": "http://example.test"}
            ), contextlib.redirect_stdout(output):
                main.main()
        finally:
            main.Client = old_client
            sys.argv = old_argv
        self.assertTrue(Client.instance.closed)
        self.assertTrue(Client.instance.subscription.closed)
