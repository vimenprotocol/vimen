"""Rialto integrator onboarding for Vimen.

Adapted from Rialto's official example (rialto-api-docs/RIALTO_SWAP_API.md);
the payload-hash field order is copied verbatim from it — do not reorder.

Usage (the OWNER key signs off-chain auth messages only, no transactions):

    cd scripts
    python3 -m venv .rialto-venv && .rialto-venv/bin/pip -q install eth-account requests
    source ../contracts/.env
    OWNER_PRIVATE_KEY=$DEPLOY_KEY .rialto-venv/bin/python rialto_onboard.py

If the application returns "pending", re-run after Rialto approves with:

    OWNER_PRIVATE_KEY=$DEPLOY_KEY INTEGRATOR_ID=<id> .rialto-venv/bin/python rialto_onboard.py --key-only

Store the printed api_key immediately: it is shown exactly once.
"""

import os
import sys

import requests
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_utils import keccak

API_BASE = "https://rialto-trade-api.rialto.xyz"
CHAIN_ID = 4663
ACTION_CREATE_APPLICATION = "create_integrator_application"
ACTION_CREATE_API_KEY = "create_integrator_api_key"

DISPLAY_NAME = "Vimen"
SLUG = "vimen"
# docs say optional, but the API rejects null at deserialization (422):
# a real string is required in practice
CONTACT_EMAIL = os.getenv("RIALTO_CONTACT_EMAIL", "")
# same story as contact_email: the API wants a string, not null
TELEGRAM_HANDLE = os.getenv("RIALTO_TELEGRAM", "vimenprotocol")
APP_URL = "https://app.vimen.org"
APPLICATION_DESCRIPTION = (
    "Vimen is an on-chain index basket protocol on Robinhood Chain: "
    "fully-backed ERC-20 baskets of tokenized stocks (MAG7, AI6) with "
    "in-kind mint/redeem and a single-transaction zap router. We route "
    "basket constituent swaps through Rialto as an execution venue "
    "(allowance settlement, contract taker). App: https://app.vimen.org, "
    "contracts verified on Blockscout, code: github.com/vimenprotocol/vimen."
)
REQUESTED_MAX_FEE_BPS = 50


def require_env(name):
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"missing {name}")
    return value


def optional(value):
    return f"some:{value}" if value is not None else "none"


def payload_hash(fields):
    canonical = ""
    for key, value in fields:
        value = str(value)
        canonical += f"{key}={len(value.encode('utf-8'))}:{value}\n"
    return "0x" + keccak(canonical.encode("utf-8")).hex()


def sign_message(private_key, message):
    signed = Account.sign_message(encode_defunct(text=message), private_key)
    return "0x" + bytes(signed.signature).hex()


def nonce(owner, action, hash_value=None):
    body = {"chain_id": CHAIN_ID, "wallet": owner, "action": action}
    if hash_value is not None:
        body["payload_hash"] = hash_value
    response = requests.post(f"{API_BASE}/integrators/nonce", json=body, timeout=30)
    response.raise_for_status()
    return response.json()


def create_key(private_key, owner, integrator_id):
    label = "vimen-production"
    key_hash = payload_hash(
        [
            ("action", ACTION_CREATE_API_KEY),
            ("chain_id", CHAIN_ID),
            ("owner_wallet", owner),
            ("integrator_id", integrator_id),
            ("label", label),
        ]
    )
    key_nonce = nonce(owner, ACTION_CREATE_API_KEY, key_hash)
    key_body = {
        "chain_id": CHAIN_ID,
        "owner_wallet": owner,
        "integrator_id": integrator_id,
        "label": label,
        "payload_hash": key_hash,
        "nonce": key_nonce["nonce"],
        "issued_at": key_nonce["issued_at"],
        "expiration_time": key_nonce["expiration_time"],
        "signature": sign_message(private_key, key_nonce["message"]),
    }
    response = requests.post(f"{API_BASE}/integrators/api-keys", json=key_body, timeout=30)
    if not response.ok:
        print("key creation failed:", response.status_code, response.text)
        raise SystemExit(1)
    created = response.json()
    print("\n=== STORE THIS NOW — SHOWN ONLY ONCE ===")
    print("api_key:", created["api_key"])
    print("masked :", created["masked_key"])
    print("scopes :", created["scopes"])
    print("limits : quote/min", created.get("quote_rate_limit_per_minute"), "| swap/min", created.get("swap_rate_limit_per_minute"))


def main():
    private_key = require_env("OWNER_PRIVATE_KEY")
    owner = Account.from_key(private_key).address.lower()
    print("owner wallet:", owner)

    if "--key-only" in sys.argv:
        create_key(private_key, owner, int(require_env("INTEGRATOR_ID")))
        return

    # The published example predates the current schema (it lacks
    # application_description and treats several now-required fields as
    # optional), so the canonical hash layout is not fully documented.
    # Try the plausible canonicalizations until the server accepts one;
    # hash-rejected attempts are refused before any state is created.
    base = [
        ("action", ACTION_CREATE_APPLICATION),
        ("chain_id", CHAIN_ID),
        ("owner_wallet", owner),
        ("display_name", DISPLAY_NAME),
        ("slug", SLUG),
    ]
    tail = [("fee_recipient", owner), ("requested_max_fee_bps", REQUESTED_MAX_FEE_BPS)]
    plain = [("contact_email", CONTACT_EMAIL), ("telegram_handle", TELEGRAM_HANDLE), ("app_url", APP_URL)]
    wrapped = [
        ("contact_email", optional(CONTACT_EMAIL)),
        ("telegram_handle", optional(TELEGRAM_HANDLE)),
        ("app_url", optional(APP_URL)),
    ]
    desc_plain = ("application_description", APPLICATION_DESCRIPTION)
    desc_wrapped = ("application_description", optional(APPLICATION_DESCRIPTION))
    variants = [
        ("schema order, plain values", base + plain + [desc_plain] + tail),
        ("schema order, some:-wrapped", base + wrapped + [desc_wrapped] + tail),
        ("description last, plain", base + plain + tail + [desc_plain]),
        ("description last, some:-wrapped", base + wrapped + tail + [desc_wrapped]),
    ]

    application = None
    for label, fields in variants:
        app_hash = payload_hash(fields)
        app_nonce = nonce(owner, ACTION_CREATE_APPLICATION, app_hash)
        app_body = {
            "chain_id": CHAIN_ID,
            "owner_wallet": owner,
            "display_name": DISPLAY_NAME,
            "slug": SLUG,
            "contact_email": CONTACT_EMAIL,
            "telegram_handle": TELEGRAM_HANDLE,
            "app_url": APP_URL,
            "application_description": APPLICATION_DESCRIPTION,
            "fee_recipient": owner,
            "requested_max_fee_bps": REQUESTED_MAX_FEE_BPS,
            "payload_hash": app_hash,
            "nonce": app_nonce["nonce"],
            "issued_at": app_nonce["issued_at"],
            "expiration_time": app_nonce["expiration_time"],
            "signature": sign_message(private_key, app_nonce["message"]),
        }
        response = requests.post(f"{API_BASE}/integrators/applications", json=app_body, timeout=30)
        if response.ok:
            application = response.json()
            print(f"application accepted (hash variant: {label})")
            break
        text = response.text.lower()
        if "hash" in text or "signature" in text or "payload" in text:
            print(f"variant '{label}' rejected ({response.status_code}), trying next…")
            continue
        print("application failed:", response.status_code, response.text)
        raise SystemExit(1)

    if application is None:
        print("all hash variants rejected — send me the last error above")
        raise SystemExit(1)
    print("application:", application)

    if application.get("status") == "active":
        create_key(private_key, owner, application["integrator_id"])
    else:
        print("\nPending Rialto review. Once approved, run:")
        print(f"  OWNER_PRIVATE_KEY=$DEPLOY_KEY INTEGRATOR_ID={application.get('integrator_id')} .rialto-venv/bin/python rialto_onboard.py --key-only")


if __name__ == "__main__":
    main()
