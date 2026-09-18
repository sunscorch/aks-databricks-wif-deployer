import base64
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests


TOKEN_EXCHANGE_GRANT = "urn:ietf:params:oauth:grant-type:token-exchange"
JWT_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt"
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(frozen=True)
class TokenExchangeResult:
    access_token: str
    summary: dict[str, Any]


def required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def sql_identifier(name: str) -> str:
    value = required_env(name)
    if not IDENTIFIER_PATTERN.fullmatch(value):
        raise RuntimeError(f"Unsafe SQL identifier in {name}: {value!r}")
    return value


def decode_jwt_part(encoded: str) -> dict[str, Any]:
    padded = encoded + "=" * (-len(encoded) % 4)
    return json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))


def inspect_projected_jwt(jwt: str) -> dict[str, Any]:
    parts = jwt.split(".")
    if len(parts) != 3:
        raise RuntimeError("Projected ServiceAccount token is not a JWT")

    header = decode_jwt_part(parts[0])
    claims = decode_jwt_part(parts[1])
    expected_audience = required_env("EXPECTED_OIDC_AUDIENCE")
    expected_subject = required_env("EXPECTED_OIDC_SUBJECT")
    audiences = claims.get("aud", [])
    if isinstance(audiences, str):
        audiences = [audiences]

    if expected_audience not in audiences:
        raise RuntimeError(f"Unexpected JWT audience: {audiences}")
    if claims.get("sub") != expected_subject:
        raise RuntimeError(f"Unexpected JWT subject: {claims.get('sub')}")

    expires_at = int(claims.get("exp", 0))
    if expires_at <= int(time.time()):
        raise RuntimeError("Projected ServiceAccount JWT is expired")

    return {
        "algorithm": header.get("alg"),
        "key_id": header.get("kid"),
        "issuer": claims.get("iss"),
        "audience": audiences,
        "subject": claims.get("sub"),
        "expires_at_epoch": expires_at,
        "remaining_seconds": expires_at - int(time.time()),
    }


def exchange_for_databricks_token(
    host: str,
    client_id: str,
    projected_jwt: str,
) -> TokenExchangeResult:
    response = requests.post(
        f"{host.rstrip('/')}/oidc/v1/token",
        data={
            "client_id": client_id,
            "grant_type": TOKEN_EXCHANGE_GRANT,
            "subject_token": projected_jwt,
            "subject_token_type": JWT_TOKEN_TYPE,
            "scope": "all-apis",
        },
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    access_token = payload.get("access_token")
    if not access_token:
        raise RuntimeError("Databricks token response did not contain access_token")

    return TokenExchangeResult(
        access_token=access_token,
        summary={
            "token_type": payload.get("token_type"),
            "scope": payload.get("scope"),
            "expires_in": payload.get("expires_in"),
        },
    )


def databricks_get(
    host: str,
    access_token: str,
    path: str,
    params: dict[str, str] | None = None,
) -> dict[str, Any]:
    response = requests.get(
        f"{host.rstrip('/')}{path}",
        headers={"Authorization": f"Bearer {access_token}"},
        params=params,
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def test_workspace_apis(host: str, access_token: str) -> dict[str, Any]:
    catalog = sql_identifier("DATABRICKS_CATALOG")
    schema = sql_identifier("DATABRICKS_SCHEMA")
    current_user = databricks_get(
        host,
        access_token,
        "/api/2.0/preview/scim/v2/Me",
    )
    clusters = databricks_get(host, access_token, "/api/2.0/clusters/list")
    warehouses = databricks_get(host, access_token, "/api/2.0/sql/warehouses")
    catalogs = databricks_get(host, access_token, "/api/2.1/unity-catalog/catalogs")
    schemas = databricks_get(
        host,
        access_token,
        "/api/2.1/unity-catalog/schemas",
        {"catalog_name": catalog},
    )
    tables = databricks_get(
        host,
        access_token,
        "/api/2.1/unity-catalog/tables",
        {"catalog_name": catalog, "schema_name": schema},
    )
    return {
        "current_user": current_user.get("userName"),
        "clusters": [item.get("cluster_id") for item in clusters.get("clusters", [])],
        "warehouses": [item.get("id") for item in warehouses.get("warehouses", [])],
        "catalogs": [item.get("name") for item in catalogs.get("catalogs", [])],
        "schemas": [item.get("full_name") for item in schemas.get("schemas", [])],
        "tables": [item.get("full_name") for item in tables.get("tables", [])],
    }


def test_sql_warehouse(access_token: str) -> dict[str, Any]:
    from databricks import sql

    catalog = sql_identifier("DATABRICKS_CATALOG")
    schema = sql_identifier("DATABRICKS_SCHEMA")
    table = sql_identifier("DATABRICKS_TABLE")
    with sql.connect(
        server_hostname=required_env("DATABRICKS_SERVER_HOSTNAME"),
        http_path=required_env("DATABRICKS_HTTP_PATH"),
        access_token=access_token,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_user(), current_catalog()")
            identity = cursor.fetchall()
            cursor.execute(f"SELECT id, message FROM {catalog}.{schema}.{table} ORDER BY id")
            rows = cursor.fetchall()
    return {
        "identity": [list(row) for row in identity],
        "table_rows": [list(row) for row in rows],
    }


def main() -> None:
    host = required_env("DATABRICKS_HOST")
    client_id = required_env("DATABRICKS_CLIENT_ID")
    token_path = Path(required_env("DATABRICKS_OIDC_TOKEN_FILEPATH"))
    projected_jwt = token_path.read_text(encoding="utf-8").strip()

    jwt_summary = inspect_projected_jwt(projected_jwt)
    print(json.dumps({"projected_jwt": jwt_summary}, indent=2))

    token_result = exchange_for_databricks_token(host, client_id, projected_jwt)
    print(json.dumps({"databricks_oauth": token_result.summary}, indent=2))

    api_results = test_workspace_apis(host, token_result.access_token)
    print(json.dumps({"workspace_apis": api_results}, indent=2))

    sql_results = test_sql_warehouse(token_result.access_token)
    print(json.dumps({"sql_warehouse": sql_results}, indent=2))


if __name__ == "__main__":
    main()