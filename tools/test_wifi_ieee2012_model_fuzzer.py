"""Compare production SCANU discovery to a set of IEEE 802.11-2012 outcomes."""

from itertools import product
from pathlib import Path
import json
import os
import random

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sa_query import platform as sa_query_platform
from test_wifi_scan_result_updates import source
from wifi_ieee2012_model import (
    Arrival, BssDescription, PassiveScan, reception_orders, sa_query_response_body, scan_results,
)


def bssid(last: int) -> bytes:
    return bytes((2, 0, 0, 0, 0, last))


def case_rows(seed: int, count: int):
    rng = random.Random(seed)
    short = product((1, 11), (None, b"A", b"B"), (None, bssid(1), bssid(2)),
                    (1, 11), (b"A", b"B"), (bssid(1), bssid(2)), Arrival)

    def seeded():
        for _ in range(count):
            channel = rng.randint(1, 11)
            station = bssid(rng.randrange(256))
            ssid = bytes((rng.randrange(256),))
            yield (channel, rng.choice((None, ssid, bytes((ssid[0] ^ 1,)))),
                   rng.choice((None, station, bssid(station[-1] ^ 1))),
                   rng.choice((channel, rng.randint(1, 11))), ssid, station,
                   rng.choice(tuple(Arrival)))

    for family, cases in (("short", short), ("seeded", seeded())):
        for index, (channel, ssid_filter, bssid_filter, rx_channel, ssid, mac, arrival) in enumerate(cases):
            scan = PassiveScan(channel, ssid_filter, bssid_filter)
            beacon = BssDescription(mac, ssid, rx_channel)
            possible = scan_results(scan, beacon, arrival)
            for delivered in reception_orders(scan, beacon, arrival):
                # Also check the concrete schedule. The set for an unresolved
                # boundary must not hide a failure in its receive-first branch.
                concrete = scan_results(scan, beacon, Arrival.IN_WINDOW if delivered else Arrival.ABSENT)
                assert concrete <= possible
                allowed = (1 if frozenset() in concrete else 0) | (
                    2 if frozenset((beacon,)) in concrete else 0)
                yield (f"{family}[{index}] channel={channel} ssid={ssid_filter!r} bssid={bssid_filter!r} "
                       f"rx_channel={rx_channel} rx_ssid={ssid!r} rx_bssid={mac!r} "
                       f"arrival={arrival.name} delivered={delivered}",
                       -1 if ssid_filter is None else ssid_filter[0],
                       -1 if bssid_filter is None else bssid_filter[-1], rx_channel, ssid[0],
                       mac[-1], delivered, allowed)


DRIVER = r'''
proc observe(caseInfo: string; wantedSsid, wantedBssid, rxChannel, ssid, mac: int;
             delivered: bool; allowed: int): bool =
  prepareUpdate(true, -75, ssid.uint8)
  # Present a decoded legacy infrastructure Beacon to the discovery path.
  protocol = 2  # No WPA or RSN information element in this fixture.
  entry.valid = 0
  entry.rssi = -128
  entry.cachedRxuMgtInd = nil
  cached.valid = 0
  scanu_env.resultCount = 0
  original.ssidFilter[0] = (wantedSsid >= 0).uint8
  original.ssidFilter[1] = max(wantedSsid, 0).uint8
  scanu_env.filterBssid = if wantedBssid < 0: [255'u8, 255, 255, 255, 255, 255]
                         else: [2'u8, 0, 0, 0, 0, wantedBssid.uint8]
  let rx = rxuMgtIndAt(addr frame[0])
  let advertisedBssid = [2'u8, 0, 0, 0, 0, mac.uint8]
  let advertisedFreq = (2407 + 5 * rxChannel).uint16
  rx.bssid = advertisedBssid
  rx.capInfo = 1    # ESS capability
  rx.freq = advertisedFreq
  frame[73] = rxChannel.uint8
  if delivered:
    scanu_frame_handler(addr frame[0], frame.len.uint32)
  let observed = if entry.valid == 0: 1
                 elif entry.bssid == advertisedBssid and cached.valid == 1 and
                      cached.length == 1 and cached.ssidBytes[0] == ssid.uint8 and
                      entry.chanPtr != nil and
                      cast[ptr ScanChannelEntry](entry.chanPtr).prim20Freq == advertisedFreq: 2
                 else: 0
  finish()
  result = (observed and allowed) != 0
  if not result:
    echo "IEEE2012-result-mismatch ", caseInfo, " observed=", observed, " allowed=", allowed
'''


def scan_suite(seed: int, steps: int, mutate: bool = False) -> str:
    code = source()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    matcher = "scanuFrameMatchesBssid"
    code = code.replace(procedure(code, matcher), procedure(scan, matcher), 1)
    if mutate:
        code = code.replace("if equalMem(a, b, size.int): 0 else: 1", "0", 1)
    # Observe the projected BSSDescriptionSet before finishing the fixture.
    # Each failing row already contains just one scan and at most one Beacon.
    rows = []
    for case, wanted_ssid, wanted_bssid, channel, ssid, mac, delivered, allowed in case_rows(seed, steps):
        rows.append(f"  ({json.dumps(case)}, {wanted_ssid}, {wanted_bssid}, {channel}, "
                    f'{ssid}, {mac}, {str(delivered).lower()}, {allowed}),')
    return code + DRIVER + f"\necho \"IEEE2012 seed={seed}\"\nfor row in [\n" + "\n".join(rows) + r'''
]:
  doAssert observe(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7])
'''


def test_ieee2012_passive_discovery(tmp_path: Path) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    count = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    run_program(tmp_path, "firmware", scan_suite(seed, count))


def test_ieee2012_oracle_rejects_an_unrequested_ssid(tmp_path: Path) -> None:
    with pytest.raises(AssertionError, match="IEEE2012-result-mismatch"):
        run_program(tmp_path, "firmware", scan_suite(808, 0, mutate=True))


SA_QUERY_DRIVER = r'''
proc observeResponse(requestId: uint16; expected: array[4, uint8]): bool =
  setupSA(1, 4)
  # Inject a decoded, management-protection-verified request from the AP.
  var msg = SmSaQueryFrameView(staIdx: 4, vifIdx: 1, action: 0, transId: requestId)
  setFrameLen(addr msg, 4)
  sm_sa_query_handler(addr msg)
  let observed = [link.macHeader[32], link.macHeader[33],
                  link.macHeader[34], link.macHeader[35]]
  result = pushCalls == 1 and observed == expected
  if not result:
    echo "IEEE2012-response-mismatch requestId=", requestId,
         " sent=", pushCalls, " body=", observed, " allowed=", expected
'''


def sa_query_suite(seed: int, steps: int, mutate: bool = False) -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    handler = procedure(scan, "sm_sa_query_handler")
    if mutate:
        handler = handler.replace("sm_send_sa_query(staIdx, 1, transId)",
                                  "sm_send_sa_query(staIdx, 1, 0'u16)", 1)
    rng = random.Random(seed)
    ids = [0, 1, 0x100, 0xBEEF, 0xFFFF] + [rng.randrange(1 << 16) for _ in range(steps)]
    rows = []
    for request_id in ids:
        (body,) = sa_query_response_body(request_id)
        expected = ", ".join(f"{byte}'u8" for byte in body)
        rows.append(f"  ({request_id}'u16, [{expected}]),")
    return (sa_query_platform() + procedure(scan, "smTrySubmitSaQuery")
            + procedure(scan, "sm_send_sa_query") + handler + SA_QUERY_DRIVER
            + f"\necho \"IEEE2012 SA Query seed={seed}\"\nfor row in [\n" + "\n".join(rows) + r'''
]:
  doAssert observeResponse(row[0], row[1])
''')


def test_ieee2012_sa_query_response(tmp_path: Path) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    count = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    run_program(tmp_path, "firmware", sa_query_suite(seed, count))


def test_ieee2012_oracle_rejects_wrong_response_id(tmp_path: Path) -> None:
    with pytest.raises(AssertionError, match="IEEE2012-response-mismatch"):
        run_program(tmp_path, "firmware", sa_query_suite(808, 0, mutate=True))
