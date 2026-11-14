import os
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


class AuthenticationTests(unittest.TestCase):
    def run_app(self, app, environment, verify, credential_error=None):
        with (
            patch.dict(os.environ, environment, clear=True),
            patch("azure.identity.WorkloadIdentityCredential") as credential_type,
            patch("azure.servicebus.ServiceBusClient") as client_type,
            patch("signal.signal"),
        ):
            credential_type.side_effect = credential_error
            namespace = runpy.run_path(str(ROOT / "src" / app / f"{app}.py"))
            main = namespace["main"]
            if app == "consumer":
                def complete_batch(*args):
                    main.__globals__["running"] = False
                    return 1

                main.__globals__["process_batch"] = complete_batch
            verify(main, credential_type, client_type)

    def test_namespace_uses_workload_identity_even_with_stale_connection_string(self):
        def verify(main, credential_type, client_type):
            main()
            credential_type.assert_called_once_with()
            client_type.assert_called_once_with(
                fully_qualified_namespace="sample.servicebus.windows.net",
                credential=credential_type.return_value.__enter__.return_value,
            )
            client_type.from_connection_string.assert_not_called()
            credential_type.return_value.__exit__.assert_called_once()

        for app in ("producer", "consumer"):
            with self.subTest(app=app):
                self.run_app(app, {
                    "SERVICEBUS_FULLY_QUALIFIED_NAMESPACE": "sample.servicebus.windows.net",
                    "SERVICEBUS_CONNECTION": "stale-emulator-connection",
                    "QUEUE_NAME": "work-items",
                    "MESSAGE_COUNT": "1",
                }, verify)

    def test_emulator_keeps_connection_string_authentication(self):
        def verify(main, credential_type, client_type):
            main()
            credential_type.assert_not_called()
            client_type.from_connection_string.assert_called_once_with("emulator-connection")

        for app in ("producer", "consumer"):
            with self.subTest(app=app):
                self.run_app(app, {
                    "SERVICEBUS_CONNECTION": "emulator-connection",
                    "QUEUE_NAME": "work-items",
                    "MESSAGE_COUNT": "1",
                }, verify)

    def test_workload_identity_configuration_error_does_not_fall_back_to_secret(self):
        def verify(main, credential_type, client_type):
            with self.assertRaisesRegex(ValueError, "missing projected token"):
                main()
            client_type.from_connection_string.assert_not_called()

        for app in ("producer", "consumer"):
            with self.subTest(app=app):
                self.run_app(app, {
                    "SERVICEBUS_FULLY_QUALIFIED_NAMESPACE": "sample.servicebus.windows.net",
                    "SERVICEBUS_CONNECTION": "stale-emulator-connection",
                    "QUEUE_NAME": "work-items",
                    "MESSAGE_COUNT": "1",
                }, verify, ValueError("missing projected token"))


if __name__ == "__main__":
    unittest.main()
