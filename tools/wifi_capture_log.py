#!/usr/bin/env python3
"""Extract compact WiFi auth/debug telemetry from hardware UART logs.

The output is intentionally small enough to paste into a local replay/fuzz
case. It does not parse every UART line, only the counters needed to separate
auth-selection bugs, TX confirmation bugs, and missing RX auth responses.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


PREFIX = "allcore_http_"


KEYS = {
    "wifi_attempt",
    "wifi_status",
    "wifi_reason",
    "scan_key_mgmt",
    "scan_at",
    "scan_smf",
    "scan_caps",
    "auth_tx_meta",
    "auth_tx_len",
    "auth_tx_desc",
    "auth_raw0",
    "auth_raw4",
    "auth_raw8",
    "auth_raw12",
    "auth_raw16",
    "auth_raw20",
    "auth_raw24",
    "auth_own_lo",
    "auth_own_hi",
    "auth_bssid_lo",
    "auth_bssid_hi",
    "auth_rxctrl",
    "auth_cfm_status",
    "auth_cfm_thd",
    "auth_cfm_ack16",
    "auth_cfm_ack23",
    "auth_cfm_ack_fail",
    "auth_cfm_push",
    "auth_mgt_seen",
    "auth_mgt_accept",
    "auth_mgt_reject",
    "rxl_frame_seen",
    "rxl_last_fc",
    "rxl_auth_like_seen",
    "rxu_auth_seen",
    "auth_sm_dispatch",
    "auth_sm_state",
    "auth_handler",
    "auth_handler_last",
    "auth_open_success",
    "assoc_req",
    "assoc_cfm_status",
    "assoc_cfm_thd",
    "assoc_cfm_ack16",
    "assoc_cfm_ack23",
    "assoc_cfm_ack_fail",
    "assoc_rsp_status",
    "set_vif_state",
    "set_vif_state_new",
    "set_vif_state_act",
    "assoc_done",
    "sm_rsp_timeout",
    "sm_rsp_timeout_state",
    "sm_rsp_timeout_rxctrl",
    "ack_fallback_auth",
    "ack_fallback_assoc",
    "ack_fallback_last",
    "eapol_in",
    "wpa_state",
}


def parse_hex(value: str) -> int:
    value = value.strip()
    if value.startswith("0x"):
        return int(value, 16)
    return int(value, 10)


def parse_log(path: Path) -> list[dict[str, int]]:
    attempts: list[dict[str, int]] = []
    current: dict[str, int] = {}
    for raw in path.read_text(errors="ignore").splitlines():
        if PREFIX not in raw or "=" not in raw:
            continue
        key_value = raw.split(PREFIX, 1)[1]
        key, value = key_value.split("=", 1)
        key = key.strip()
        if key == "wifi_attempt" and current:
            attempts.append(current)
            current = {}
        if key in KEYS:
            current[key] = parse_hex(value)
    if current:
        attempts.append(current)
    return attempts


def summarize(attempt: dict[str, int]) -> dict[str, object]:
    key_mgmt = attempt.get("scan_key_mgmt", 0)
    ack_count = attempt.get("auth_cfm_ack16", 0) + attempt.get("auth_cfm_ack23", 0)
    rx_auth = attempt.get("rxl_auth_like_seen", 0)
    auth_handler = attempt.get("auth_handler", 0)
    assoc_ack_count = attempt.get("assoc_cfm_ack16", 0) + attempt.get("assoc_cfm_ack23", 0)
    return {
        "attempt": attempt.get("wifi_attempt", 0),
        "status": attempt.get("wifi_status", 0),
        "scan_key_mgmt": key_mgmt,
        "scan_at": attempt.get("scan_at", 0),
        "auth_algo": (attempt.get("auth_tx_meta", 0) >> 16) & 0xFF,
        "auth_ack_count": ack_count,
        "rx_auth_like_seen": rx_auth,
        "auth_handler": auth_handler,
        "assoc_req": attempt.get("assoc_req", 0),
        "assoc_ack_count": assoc_ack_count,
        "assoc_done": attempt.get("assoc_done", 0),
        "sm_rsp_timeout": attempt.get("sm_rsp_timeout", 0),
        "sm_rsp_timeout_state": attempt.get("sm_rsp_timeout_state", 0),
        "sm_rsp_timeout_rxctrl": attempt.get("sm_rsp_timeout_rxctrl", 0),
        "ack_fallback_auth": attempt.get("ack_fallback_auth", 0),
        "ack_fallback_assoc": attempt.get("ack_fallback_assoc", 0),
        "set_vif_state": attempt.get("set_vif_state", 0),
        "wpa_state": attempt.get("wpa_state", 0),
        "classification": (
            "associated-no-eapol"
            if attempt.get("assoc_done", 0) != 0 and attempt.get("eapol_in", 0) == 0
            else "assoc-fallback-fired"
            if attempt.get("ack_fallback_assoc", 0) != 0
            else "assoc-tx-acked-no-fallback"
            if attempt.get("assoc_req", 0) != 0 and assoc_ack_count != 0
            else "auth-fallback-fired"
            if attempt.get("ack_fallback_auth", 0) != 0
            else
            "rx-auth-dispatched"
            if auth_handler != 0
            else "assoc-tx-acked-no-rx"
            if attempt.get("assoc_req", 0) != 0 and assoc_ack_count != 0
            else "rx-auth-seen-not-dispatched"
            if rx_auth != 0
            else "auth-tx-acked-no-rx"
            if ack_count != 0
            else "auth-tx-no-ack"
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()

    attempts = parse_log(args.log)
    doc = {
        "source": str(args.log),
        "attempts": attempts,
        "summary": [summarize(attempt) for attempt in attempts],
    }
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
