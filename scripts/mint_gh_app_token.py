#!/usr/bin/env python3
"""Mint a GitHub App installation access token.

The token is the only value written to stdout. Diagnostics go to stderr and
never include the private key, JWT, or minted installation token.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

try:
    import jwt
    import requests
except ImportError as exc:
    print(f"missing required Python dependency: {exc.name}", file=sys.stderr)
    sys.exit(2)


DEFAULT_APP_ID = "4245332"
DEFAULT_INSTALLATION_ID = "145172957"
DEFAULT_KEY_PATH = "~/.config/ezgha/app_private_key.pem"
GITHUB_API = "https://api.github.com"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Mint a GitHub App installation token for ezgha."
    )
    parser.add_argument("--app-id", default=DEFAULT_APP_ID)
    parser.add_argument("--installation-id", default=DEFAULT_INSTALLATION_ID)
    parser.add_argument("--key-path", default=DEFAULT_KEY_PATH)
    return parser.parse_args()


def fail(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    sys.exit(exit_code)


def response_error(response: requests.Response) -> str:
    try:
        data = response.json()
    except ValueError:
        body = response.text.strip().replace("\n", " ")
        if len(body) > 240:
            body = body[:237] + "..."
        return body or response.reason

    message = data.get("message")
    if isinstance(message, str) and message:
        return message
    return response.reason


def post_with_retry(url: str, headers: dict[str, str], timeout: int) -> requests.Response:
    try:
        resp = requests.post(url, headers=headers, timeout=timeout)
        if resp.status_code < 500:
            return resp
    except requests.RequestException:
        pass

    # Retry exactly once on transient failure (exception or 5xx)
    time.sleep(2.5)
    return requests.post(url, headers=headers, timeout=timeout)


def main() -> int:
    args = parse_args()
    key_path = Path(args.key_path).expanduser()

    try:
        private_key = key_path.read_text()
    except OSError as exc:
        fail(f"failed to read GitHub App private key at {key_path}: {exc}")

    now = int(time.time())
    payload = {
        "iat": now - 60,
        "exp": now + 9 * 60,
        "iss": str(args.app_id),
    }

    try:
        encoded = jwt.encode(payload, private_key, algorithm="RS256")
    except Exception as exc:  # PyJWT/cryptography raise several concrete types.
        fail(f"failed to sign GitHub App JWT: {exc}")

    if isinstance(encoded, bytes):
        encoded = encoded.decode("ascii")

    url = f"{GITHUB_API}/app/installations/{args.installation_id}/access_tokens"
    headers = {
        "Authorization": f"Bearer {encoded}",
        "Accept": "application/vnd.github+json",
    }

    try:
        response = post_with_retry(url, headers=headers, timeout=30)
    except requests.RequestException as exc:
        fail(f"GitHub App token request failed: {exc}")

    if not 200 <= response.status_code < 300:
        fail(
            "GitHub App token request failed: "
            f"HTTP {response.status_code}: {response_error(response)}"
        )

    try:
        data = response.json()
    except ValueError as exc:
        fail(f"GitHub App token response was not JSON: {exc}")

    token = data.get("token")
    if not isinstance(token, str) or not token:
        fail("GitHub App token response did not contain a token field")

    sys.stdout.write(token + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
