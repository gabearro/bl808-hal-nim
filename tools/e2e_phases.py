"""Phase enum + per-phase metadata for the WiFi/BLE e2e soak harness.

This module is the single source of truth. The matching Nim enum is generated
by `tools/gen_e2e_marker_nim.py` and written into `src/bl808/kernel/e2e_marker.nim`
between sentinel comments. Renaming a phase here auto-propagates to firmware.
"""
from __future__ import annotations

from enum import Enum


class Kind(Enum):
    START = "start"
    OK = "ok"
    FAIL = "fail"
    INFO = "info"


class Phase(Enum):
    # Framing
    ATTEMPT = "attempt"
    # WiFi milestone
    SCAN = "scan"
    AUTH = "auth"
    FOUR_WHS = "4whs"
    ASSOC = "assoc"
    DHCP = "dhcp"
    TCP = "tcp"
    # BLE milestone (added now so the Nim enum is stable; firmware tests in later iters use them)
    ADV_START = "adv_start"
    CONNECT_REQ = "connect_req"
    MTU = "mtu"
    GATT_READ = "gatt_read"
    DISCONNECT = "disconnect"


class Milestone(Enum):
    WIFI = "wifi"
    BLE_PERIPHERAL = "ble_peripheral"
    BLE_CENTRAL = "ble_central"


_MILESTONE_SEQUENCES: dict[Milestone, list[Phase]] = {
    Milestone.WIFI: [
        Phase.SCAN, Phase.AUTH, Phase.FOUR_WHS, Phase.ASSOC,
        Phase.DHCP, Phase.TCP,
    ],
    Milestone.BLE_PERIPHERAL: [
        Phase.ADV_START, Phase.CONNECT_REQ, Phase.MTU,
        Phase.GATT_READ, Phase.DISCONNECT,
    ],
    Milestone.BLE_CENTRAL: [
        Phase.SCAN, Phase.CONNECT_REQ, Phase.MTU,
        Phase.GATT_READ, Phase.DISCONNECT,
    ],
}


# Soft per-phase deadlines (seconds). Tunable via CLI in hw_e2e.py later.
_DEADLINES: dict[Phase, float] = {
    Phase.ATTEMPT: 30.0,
    Phase.SCAN: 5.0,
    Phase.AUTH: 3.0,
    Phase.FOUR_WHS: 3.0,
    Phase.ASSOC: 3.0,
    Phase.DHCP: 8.0,
    Phase.TCP: 5.0,
    Phase.ADV_START: 3.0,
    Phase.CONNECT_REQ: 5.0,
    Phase.MTU: 2.0,
    Phase.GATT_READ: 2.0,
    Phase.DISCONNECT: 3.0,
}


def phases_for_milestone(m: Milestone) -> list[Phase]:
    """Canonical per-phase sequence for a milestone."""
    return list(_MILESTONE_SEQUENCES[m])


def deadline_seconds(p: Phase) -> float:
    """Default soft deadline for a phase, in seconds."""
    return _DEADLINES[p]
