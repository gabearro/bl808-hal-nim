"""IEEE Std 802.11-2012 protocol projections, independent of BL808 internals.

Edition, normative clause/table references and scope: docs/wifi_model_fuzzer.md.
"""

from dataclasses import dataclass
from enum import Enum, auto


class Arrival(Enum):
    ABSENT = auto()
    IN_WINDOW = auto()
    AT_BOUNDARY = auto()
    AFTER_WINDOW = auto()


@dataclass(frozen=True)
class PassiveScan:
    """6.3.3.2.2 request table: ChannelList, SSID, BSSID and PASSIVE ScanType."""

    channel: int
    ssid: bytes | None  # None denotes the wildcard SSID.
    bssid: bytes | None  # None denotes the broadcast BSSID.


@dataclass(frozen=True)
class BssDescription:
    """Projection of the 6.3.3.3.2 BSSDescription table."""

    bssid: bytes
    ssid: bytes
    channel: int


def reception_orders(scan: PassiveScan, beacon: BssDescription, arrival: Arrival) -> tuple[bool, ...]:
    """Which schedules receive a Beacon during the 10.1.4.2 listen window.

    A boundary event models unresolved arrival-vs-dwell-end order, not leeway
    to ignore a matching Beacon already received during the scan.
    """
    if beacon.channel != scan.channel or arrival in (Arrival.ABSENT, Arrival.AFTER_WINDOW):
        return (False,)
    return (False, True) if arrival is Arrival.AT_BOUNDARY else (True,)


def scan_results(scan: PassiveScan, beacon: BssDescription,
                 arrival: Arrival) -> frozenset[frozenset[BssDescription]]:
    """Permitted BSSDescriptionSet projections (6.3.3.3.2, 10.1.4.1)."""
    matches = (scan.bssid is None or beacon.bssid == scan.bssid) and (
        scan.ssid is None or beacon.ssid == scan.ssid
    )
    return frozenset(frozenset((beacon,)) if received and matches else frozenset()
                     for received in reception_orders(scan, beacon, arrival))


def sa_query_response_body(request_id: int) -> frozenset[bytes]:
    """8.5.10.3, Figure 8-466, Tables 8-38/8-227: response echoes the ID.

    Scope: an accepted request and a response submitted successfully. This
    projection does not prescribe when the response is transmitted or ACKed.
    """
    return frozenset((bytes((8, 1)) + request_id.to_bytes(2, "little"),))
