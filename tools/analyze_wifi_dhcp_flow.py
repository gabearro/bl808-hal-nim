#!/usr/bin/env python3
"""Decode the all-core BL808 DHCP rings without inferring retry-to-reply causality."""

import argparse
import json
from collections import Counter
from pathlib import Path

from analyze_wifi_tcp_air import Capture, mac_address, read_capture


RING_SIZE = 8
DONE, SOFTWARE_DONE = 1 << 31, 1 << 30
ACKED, LIFETIME_EXPIRED, RETRY_LIMIT = 1 << 23, 1 << 17, 1 << 16
HAS_POLICY, HAS_TX_XID = 1 << 17, 1 << 22
HAS_RX_XID, SINGLE_RX_CALLBACK = 1 << 8, 1 << 11
RATE_ENABLED = 1 << 31


def hex32(word: int) -> str:
    return f"0x{word:08x}"


def words(snapshot: dict, name: str, count: int) -> list[int]:
    field = snapshot.get("nimfw_dbg_" + name)
    if count == 1:
        field = [field]
    if not isinstance(field, list) or len(field) != count or any(
            type(word) is not int or not 0 <= word <= 0xFFFFFFFF for word in field):
        raise ValueError(f"{name}: expected {count} unsigned 32-bit words")
    return field


def retry_report(status: int, meta: int, policy: list[int]) -> dict | None:
    """Only charge slots for the same normal-ACK profile as firmware feedback."""
    if not meta & HAS_POLICY:
        return None
    raw = policy[7]
    if (raw | 1) != status or (raw & (DONE | SOFTWARE_DONE | LIFETIME_EXPIRED | 0xFF)) != DONE:
        return None
    success = bool(raw & ACKED)
    if success == bool(raw & RETRY_LIMIT) or policy[6] != 0x2200 or (policy[4] & 0xFFFF) != 0x0704:
        return None
    attempts = ((raw >> 8) & 0xFF) + 1
    if attempts > 8:
        return None
    terminal_slot = (attempts - 1) // 4
    slots = []
    for slot in range(terminal_slot + 1):
        rate = policy[slot]
        if not rate & RATE_ENABLED:
            return None
        sent = min(4, attempts - slot * 4)
        slots.append({"index": slot, "rate_word": hex32(rate), "attempts": sent,
                      "acked": success and slot == terminal_slot})
    return {"attempts": attempts, "slots": slots}


def decode(snapshot: dict) -> dict:
    tx_count = words(snapshot, "dhcp_cfm_ring_idx", 1)[0]
    tx_status = words(snapshot, "dhcp_cfm_status_log", RING_SIZE)
    tx_meta = words(snapshot, "dhcp_cfm_meta_log", RING_SIZE)
    tx_xid = words(snapshot, "dhcp_cfm_xid_log", RING_SIZE)
    tx_policy = words(snapshot, "dhcp_cfm_policy_log", RING_SIZE * 8)
    tx_air = (words(snapshot, "dhcp_cfm_air_log", RING_SIZE)
              if "nimfw_dbg_dhcp_cfm_air_log" in snapshot else [0] * RING_SIZE)
    rx_count = words(snapshot, "dhcp_rx_trace_count", 1)[0]
    rx_rows = words(snapshot, "dhcp_rx_trace_log", RING_SIZE * 5)
    tx_old = max(0, tx_count - RING_SIZE)
    rx_old = max(0, rx_count - RING_SIZE)

    groups: dict[str | None, dict] = {}

    def group(xid: str | None) -> dict:
        return groups.setdefault(xid, {"xid": xid, "tx_completions": [], "rx_deliveries": []})

    for index in range(tx_old, tx_count):
        slot = index % RING_SIZE
        meta, status = tx_meta[slot], tx_status[slot]
        xid = hex32(tx_xid[slot]) if meta & HAS_TX_XID else None
        tag = tx_air[slot]
        header = None
        if (tag & 0xFFF8000F) == 0x80000000 and meta & HAS_POLICY:
            header = {"tid": (tag >> 16) & 7, "sequence": (tag >> 4) & 0xFFF}
        group(xid)["tx_completions"].append({
            "index": index, "type": (meta >> 18) & 15,
            "host_repush": meta >> 24, "status": hex32(status),
            "mac": retry_report(status, meta, tx_policy[slot * 8:slot * 8 + 8]),
            "air_header": header,
        })

    for index in range(rx_old, rx_count):
        slot = index % RING_SIZE
        xid, tag, delta, code, metadata = rx_rows[slot * 5:slot * 5 + 5]
        if delta != 1 or not tag & SINGLE_RX_CALLBACK:
            outcome = None
        else:
            outcome = {"code": hex32(code), "metadata": hex32(metadata)}
        group(hex32(xid) if tag & HAS_RX_XID else None)["rx_deliveries"].append({
            "index": index, "type": tag & 0xFF, "stage": (tag >> 9) & 3,
            "lwip_callback_count_delta": delta, "lwip_outcome": outcome,
        })

    return {"tx_completions_seen": tx_count, "tx_completions_overwritten": tx_old,
            "rx_deliveries_seen": rx_count, "rx_deliveries_overwritten": rx_old,
            "transactions": [entry for xid, entry in groups.items() if xid is not None],
            "unattributed": groups.get(None),
            "scope": "Transactions only; no cross-ring timing, reply-to-retry match, or lease proof."}


def match_air(report: dict, capture: Capture) -> None:
    if not capture.counts["ap-beacons"]:
        raise ValueError("capture did not verify the selected AP at 2462 MHz")
    groups = report["transactions"] + ([report["unattributed"]] if report["unattributed"] else [])
    rows = [row for group in groups for row in group["tx_completions"]]
    keyed = [(row, (row["air_header"]["tid"], row["air_header"]["sequence"]))
             for row in rows if row["air_header"] is not None]
    uses = Counter(key for _, key in keyed)
    for row, key in keyed:
        seen = capture.groups.get(key)
        if uses[key] != 1 or (seen is not None and (seen.reused or seen.fragmented)):
            row["air"] = {"state": "ambiguous"}
        elif seen is None:
            row["air"] = {"state": "not-observed", "bad_fcs_headers": capture.bad_fcs_uplink[key]}
        else:
            row["air"] = {
                "state": "observed", "frames": len(seen.attempts), "retry_marked": seen.retries,
                "candidate_acks": seen.ack_candidates, "bad_fcs_headers": capture.bad_fcs_uplink[key],
            }
    report["capture"] = {
        "counts": dict(capture.counts), "ack_clock": capture.ack_clock,
        "scope": "A nearby ACK has no AP address or sequence. Missing headers don't establish silence.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshots", nargs="+", type=Path)
    parser.add_argument("--air", type=Path, help="one boot's channel-11 radiotap PCAP")
    parser.add_argument("--station", type=mac_address, help="captured Ox64 MAC")
    parser.add_argument("--ap", type=mac_address, help="captured BSSID")
    parser.add_argument("--ack-window-us", type=int, default=1000)
    args = parser.parse_args()
    if args.air and (len(args.snapshots) != 1 or args.station is None or args.ap is None):
        parser.error("--air requires exactly one snapshot, --station and --ap")
    if not 0 < args.ack_window_us <= 10_000:
        parser.error("--ack-window-us must be between 1 and 10000")
    reports = []
    for path in args.snapshots:
        try:
            snapshot = json.loads(path.read_text())
            if not isinstance(snapshot, dict):
                raise ValueError("expected a snapshot object")
            report = {"snapshot": str(path), **decode(snapshot)}
            if args.air:
                with args.air.open("rb") as pcap:
                    capture = read_capture(pcap, args.station, args.ap, args.ack_window_us)
                match_air(report, capture)
            reports.append(report)
        except (OSError, ValueError) as exc:
            parser.error(f"{path}: {exc}")
    print(json.dumps(reports, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
