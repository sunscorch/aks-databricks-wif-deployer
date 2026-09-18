import base64
import importlib.util
import json
import os
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


SCRIPT_PATH = Path(__file__).with_name("app.py")
SPEC = importlib.util.spec_from_file_location("federation_app", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


def encode(value: dict) -> str:
    raw = json.dumps(value, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


class TokenExchangeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.subject = "system:serviceaccount:test-namespace:test-service-account"
        self.jwt = ".".join(
            [
                encode({"alg": "RS256", "kid": "test-key"}),
                encode(
                    {
                        "iss": "https://issuer.example/",
                        "aud": ["databricks"],
                        "sub": self.subject,
                        "exp": int(time.time()) + 3600,
                    }
                ),
                "signature",
            ]
        )

    def test_projected_jwt_validation(self) -> None:
        env = {
            "EXPECTED_OIDC_AUDIENCE": "databricks",
            "EXPECTED_OIDC_SUBJECT": self.subject,
        }
        with patch.dict(os.environ, env, clear=False):
            summary = MODULE.inspect_projected_jwt(self.jwt)
        self.assertEqual(summary["algorithm"], "RS256")
        self.assertEqual(summary["subject"], self.subject)
        self.assertNotIn(self.jwt, json.dumps(summary))

    @patch.object(MODULE.requests, "post")
    def test_rfc8693_exchange(self, post: Mock) -> None:
        response = Mock()
        response.json.return_value = {
            "access_token": "SENSITIVE_TOKEN",
            "token_type": "Bearer",
            "scope": "all-apis",
            "expires_in": 3600,
        }
        response.raise_for_status.return_value = None
        post.return_value = response

        result = MODULE.exchange_for_databricks_token(
            "https://workspace.example",
            "client-id",
            self.jwt,
        )
        self.assertEqual(result.access_token, "SENSITIVE_TOKEN")
        self.assertNotIn(result.access_token, json.dumps(result.summary))
        post.assert_called_once_with(
            "https://workspace.example/oidc/v1/token",
            data={
                "client_id": "client-id",
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": self.jwt,
                "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
                "scope": "all-apis",
            },
            timeout=30,
        )

    def test_sql_identifier_validation(self) -> None:
        with patch.dict(os.environ, {"TEST_IDENTIFIER": "test_schema"}, clear=False):
            self.assertEqual(MODULE.sql_identifier("TEST_IDENTIFIER"), "test_schema")
        with patch.dict(os.environ, {"TEST_IDENTIFIER": "bad;drop"}, clear=False):
            with self.assertRaises(RuntimeError):
                MODULE.sql_identifier("TEST_IDENTIFIER")


if __name__ == "__main__":
    unittest.main()