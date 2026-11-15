import logging
import os
from pathlib import Path
import runpy
import sys
import threading
import time
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


class ProducerRateTests(unittest.TestCase):
    def test_isolated_workers_sustain_configured_rate(self):
        state = {
            "active": 0,
            "max_active": 0,
            "sent": 0,
            "next_client_id": 0,
            "client_threads": {},
            "next_sender_id": 0,
            "sender_threads": {},
            "completions": [],
        }
        lock = threading.Lock()

        class FakeCredential:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return None

        class FakeClient:
            def __init__(self):
                with lock:
                    state["next_client_id"] += 1
                    self.client_id = state["next_client_id"]
                    state["client_threads"][self.client_id] = set()

            def record_thread(self):
                with lock:
                    state["client_threads"][self.client_id].add(threading.get_ident())

            def __enter__(self):
                self.record_thread()
                return self

            def __exit__(self, *_):
                self.record_thread()
                return None

            def get_queue_sender(self, queue_name):
                self.record_thread()
                return FakeSender(self)

            @classmethod
            def from_connection_string(cls, _):
                return cls()

        class FakeSender:
            def __init__(self, client):
                self.client = client
                with lock:
                    state["next_sender_id"] += 1
                    self.sender_id = state["next_sender_id"]
                    state["sender_threads"][self.sender_id] = set()

            def record_thread(self):
                self.client.record_thread()
                with lock:
                    state["sender_threads"][self.sender_id].add(threading.get_ident())

            def __enter__(self):
                self.record_thread()
                return self

            def __exit__(self, *_):
                self.record_thread()
                return None

            def send_messages(self, messages):
                self.record_thread()
                with lock:
                    state["active"] += 1
                    state["max_active"] = max(state["max_active"], state["active"])
                try:
                    time.sleep(0.04)
                    with lock:
                        state["sent"] += len(messages)
                        state["completions"].append((time.monotonic(), len(messages)))
                finally:
                    with lock:
                        state["active"] -= 1

        azure = types.ModuleType("azure")
        azure.__path__ = []
        identity = types.ModuleType("azure.identity")
        identity.WorkloadIdentityCredential = FakeCredential
        servicebus = types.ModuleType("azure.servicebus")
        servicebus.ServiceBusClient = FakeClient
        servicebus.ServiceBusMessage = str

        with (
            patch.dict(os.environ, {
                "SERVICEBUS_CONNECTION": "test-connection",
                "QUEUE_NAME": "work-items",
                "MESSAGE_COUNT": "5000",
                "MESSAGE_RATE_PER_SECOND": "1000",
            }, clear=True),
            patch.dict(sys.modules, {
                "azure": azure,
                "azure.identity": identity,
                "azure.servicebus": servicebus,
            }),
        ):
            producer = runpy.run_path(
                str(ROOT / "src" / "producer" / "producer.py"),
                run_name="producer",
            )
            start = time.monotonic()
            producer["main"]()

        elapsed = time.monotonic() - start
        achieved_rate = state["sent"] / elapsed
        completion_times = state["completions"]
        first_completion = min(timestamp for timestamp, _ in completion_times)
        sustained_windows = [
            sum(
                count
                for timestamp, count in completion_times
                if window_start <= timestamp < window_start + 1
            )
            for window_start in (first_completion + 1, first_completion + 2, first_completion + 3)
        ]
        logging.getLogger(__name__).info(
            "Completed messages in interior one-second windows: %s", sustained_windows
        )
        self.assertEqual(state["sent"], 5000)
        self.assertGreaterEqual(state["max_active"], 2)
        self.assertGreaterEqual(len(state["client_threads"]), 2)
        self.assertTrue(
            all(len(thread_ids) == 1 for thread_ids in state["client_threads"].values()),
            f"Service Bus clients were shared across threads: {state['client_threads']}",
        )
        self.assertTrue(
            all(len(thread_ids) == 1 for thread_ids in state["sender_threads"].values()),
            f"Service Bus senders were shared across threads: {state['sender_threads']}",
        )
        self.assertTrue(
            all(900 <= count <= 1100 for count in sustained_windows),
            f"Sustained one-second completion counts were {sustained_windows}",
        )
        self.assertGreaterEqual(achieved_rate, 850)


if __name__ == "__main__":
    unittest.main()
