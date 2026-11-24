"""Synthetic, offline tests for the wired PCAP and device ring correlator."""

import io
import struct
import subprocess
import sys
from dataclasses import replace
from ipaddress import IPv4Address
from pathlib import Path

import pytest

from analyze_wifi_tcp_path import (
    POLICY_CAPACITY, POLICY_ENTRY, POLICY_SNAPSHOT_SIZE, Flow, Tcp, read_pcap,
    read_policies, read_snapshot, summarize, summarize_policies,
)


PEER = "192.0.2.10"
LOCAL = "192.0.2.20"
PORT = 49152
SYN = Tcp(PORT, 80, 0xffffffff, 0, 0x02, 0)
SYN_ACK = Tcp(80, PORT, 123, 0, 0x12, 0)
REQUEST = Tcp(PORT, 80, 0, 124, 0x18, 33)
RESPONSE = Tcp(80, PORT, 124, 33, 0x18, 11)
APP = Tcp(PORT, 80, 0, 0, 0, 0)


def frame(tcp, *, peer=PEER, vlan=False, ip_options=0, tcp_options=0, fragment=0):
    eth = bytes(12) + (b"\x81\x00\x00\x07" if vlan else b"") + b"\x08\x00"
    ip_len, tcp_len = 20 + ip_options, 20 + tcp_options
    total = ip_len + tcp_len + tcp.length
    ip = struct.pack("!BBHHHBBH", 0x40 | (ip_len // 4), 0, total, 99, fragment, 64, 6, 0)
    addresses = (peer, LOCAL) if tcp.dst == 80 else (LOCAL, peer)
    ip += b"".join(IPv4Address(a).packed for a in addresses) + bytes(ip_options)
    header = struct.pack("!HHIIBBHHH", tcp.src, tcp.dst, tcp.seq, tcp.ack,
                         (tcp_len // 4) << 4, tcp.flags, 0, 0, 0)
    return eth + ip + header, len(eth) + total


def pcap(records, endian="<", nanos=False):
    magic = 0xa1b23c4d if nanos else 0xa1b2c3d4
    data = struct.pack(endian + "IHHIIII", magic, 2, 4, 0, 0, 65535, 1)
    for i, (captured, wirelen) in enumerate(records):
        # Descending times deliberately disagree with file order.
        data += struct.pack(endian + "IIII", 100, 100 - i, len(captured), wirelen) + captured
    return data


def event(tick, stage, tcp=SYN, *, detail=0):
    return (tick, stage | (tcp.flags << 8), tcp.src | (tcp.dst << 16), tcp.seq, tcp.ack,
            tcp.length | (7 << 16), detail)


def ring(events, *, head=None):
    head = len(events) if head is None else head
    raw = bytearray(4 + 1024 * 28)
    struct.pack_into("<I", raw, 0, head)
    for index, row in enumerate(events, head - len(events)):
        struct.pack_into("<7I", raw, 4 + (index % 1024) * 28, *row)
    return bytes(raw)


def policy_ring(rows, *, head=None):
    head = len(rows) if head is None else head
    raw = bytearray(POLICY_SNAPSHOT_SIZE)
    struct.pack_into("<I", raw, 0, head)
    for index, row in enumerate(rows, head - len(rows)):
        POLICY_ENTRY.pack_into(raw, 4 + (index % POLICY_CAPACITY) * POLICY_ENTRY.size, *row)
    return raw


def policy_event(tick, *, status, repush=0, has_policy=True):
    tick, meta, *rest = event(tick, 5, RESPONSE, detail=status)
    return (tick, meta | (int(has_policy) << 16) | (repush << 24), *rest)


def test_policy_ring_matches_each_completion_and_ignores_retired_rows():
    snapshot = read_snapshot(ring([
        policy_event(5, status=0x80010701),
        policy_event(10, status=0x80800001, repush=1),
        policy_event(15, status=0xc0800000),  # Do not credit a software retire.
        policy_event(20, status=0x80800001, has_policy=False),
    ], head=410))
    settings = [0x80000003, 0x80000004, 0x80000005, 0x80000006,
                0x0704, 0x003f0000, 0x2200]
    power = [0x11, 0x12, 0x13, 0x14]
    raw = policy_ring([
        [399, *settings, 0x80800000, *power],
        [406, *settings, 0x80010700, *power],
        [407, *settings, 0x80800000, *power],
        [408, *settings, 0xc0800000, *power],
        [409, *settings, 0x80800000, *power],
    ], head=385)
    policies = read_policies(raw, snapshot)
    assert set(policies) == {406, 407}
    assert policies[406].power == tuple(power)
    assert policies[406].hardware_status == 0x80010700
    result = summarize_policies(snapshot, policies, {PORT})
    assert "2/3 hardware completions matched; 2 marked captured" in result
    assert "ok=1 retry-limit=1 other=0" in result
    assert "repush=1 ok host=80800001 hw=80800000" in result
    assert "0/0 hardware completions" in summarize_policies(snapshot, policies, {PORT + 1})


def test_policy_ring_rejects_invalid_size_duplicate_or_future_head():
    snapshot = read_snapshot(ring([policy_event(5, status=0x80800001), event(6, 3)]))
    row = [0] * 13
    with pytest.raises(ValueError, match="bytes"):
        read_policies(b"", snapshot)
    with pytest.raises(ValueError, match="duplicate policy"):
        read_policies(policy_ring([row, row]), snapshot)
    with pytest.raises(ValueError, match="ahead"):
        read_policies(policy_ring([row, row, row]), snapshot)


@pytest.mark.parametrize(("endian", "nanos"), [("<", False), (">", False), ("<", True), (">", True)])
def test_truncated_ethernet_snapshots(endian, nanos):
    request, wirelen = frame(REQUEST)
    packets = read_pcap(io.BytesIO(pcap([
        frame(RESPONSE, vlan=True, ip_options=4, tcp_options=12),
        (request[:-1], wirelen),  # Missing part of the minimum TCP header.
        frame(REQUEST, fragment=0x2000),
        frame(REQUEST, fragment=1),
        frame(replace(REQUEST, dst=8080)),
        frame(replace(REQUEST, src=80)),  # Cannot determine device direction.
        frame(REQUEST, fragment=0x4000),  # DF is fine.
        frame(SYN),
    ], endian, nanos)))
    flow = Flow(PEER, PORT, LOCAL)
    assert list(packets) == [(flow, RESPONSE), (flow, REQUEST), (flow, SYN)]


def test_payload_is_not_read_even_if_present():
    request, wirelen = frame(REQUEST)
    start = 24 + 16 + len(request)
    end = start + REQUEST.length

    class HeaderReadsOnly(io.BytesIO):
        def read(self, size=-1):
            assert size >= 0
            assert self.tell() >= end or self.tell() + size <= start
            return super().read(size)

    packets = read_pcap(HeaderReadsOnly(pcap([
        (request + bytes(REQUEST.length), wirelen), frame(RESPONSE),
    ])))
    assert [tcp for _, tcp in packets] == [REQUEST, RESPONSE]


def test_ring_rotation_and_clock_wrap_with_out_of_order_ticks():
    ticks = [0xfffffffc, 3, 0xffffffff, 8, 6]
    rows = [event(tick, 1, REQUEST, detail=i) for i, tick in enumerate(ticks)]
    rows += [event(9, 2, SYN)] * (1024 - len(rows))
    snapshot = read_snapshot(ring(rows, head=1027))
    assert [row.tick_offset_us for row in snapshot.events[:6]] == [0, 7, 3, 12, 10, 13]
    assert [row.detail for row in snapshot.events[:5]] == list(range(5))
    assert snapshot.events[0].tcp == REQUEST
    assert snapshot.events[0].ip_id == 7
    assert len(snapshot.events) == 1024 and snapshot.invalid == 0
    report = summarize([], snapshot)
    assert "earlier entries may have been overwritten" in report
    assert "Device tick offsets: 0..13 us" in report


def test_low_head_ignores_potentially_stale_slots_and_reports_invalid_rows():
    rows = [event(1, 0), event(2, 2), event(3, 1)]
    snapshot = read_snapshot(struct.pack("<I", 2) + ring(rows)[4:])
    assert snapshot.invalid == 1
    assert [row.stage for row in snapshot.events] == [2]
    assert "stale entries or producer count wrap" in summarize([], snapshot)
    assert not read_snapshot(ring([])).events


def test_summary_separates_wire_evidence_from_device_only_and_app_events():
    other_response = replace(RESPONSE, seq=999)
    wire = pcap([frame(tcp) for tcp in (SYN_ACK, SYN, SYN, REQUEST, RESPONSE, APP)])
    events = [
        event(1, 1), event(2, 1),  # Device duplicates do not inflate signature counts.
        event(3, 2, REQUEST),
        event(4, 3, SYN_ACK), event(5, 5, SYN_ACK, detail=0x80800000),
        event(6, 3, RESPONSE), event(7, 5, RESPONSE, detail=0x00800000),
        event(8, 4, other_response), event(9, 5, other_response, detail=0x80000000),
        event(10, 6, APP), event(11, 7, APP), event(12, 8, APP, detail=33),
        event(13, 1, SYN_ACK),  # TX-shaped headers in an RX stage are not TX evidence.
        event(14, 8, replace(APP, src=80, dst=PORT)),
        event(15, 1, replace(REQUEST, flags=0x10)),
        event(16, 1, replace(REQUEST, ack=125)),
        event(17, 1, replace(REQUEST, length=32)),
        event(18, 5, RESPONSE, detail=0xc0800000),  # Software retirement is not a MAC success.
    ]
    report = summarize(read_pcap(io.BytesIO(wire)), read_snapshot(ring(events)))
    assert "RX SYN: wire=2 copies/1 signatures; wire signatures: handoff=1 reject=0 no-match=0" in report
    assert "RX data: wire=1 copies/1 signatures; wire signatures: handoff=0 reject=1 no-match=0" in report
    assert "RX other: wire=1 copies/1 signatures; wire signatures: handoff=0 reject=0 no-match=1" in report
    assert "TX SYN-ACK: wire=1 copies/1 signatures; wire signatures: output=1 reject=0 MAC-done-ok=1" in report
    assert ("TX data: wire=1 copies/1 signatures; wire signatures: output=1 reject=0 "
            "MAC-done-ok=0 MAC-done-no-success=0 MAC-not-done=1 no-match=0") in report
    assert "device-only=1 signatures: output=0 reject=1 MAC-done-ok=0 MAC-done-no-success=1" in report
    assert "HTTP (ports only): accept=1 pool-full=1 recv=1" in report


def test_shared_ports_are_ambiguous_even_with_a_port_filter():
    other = "192.0.2.30"
    wire = pcap([frame(SYN), frame(SYN, peer=other), frame(replace(SYN, src=PORT + 1))])
    snapshot = read_snapshot(ring([event(1, 1), event(2, 6, APP)]))
    report = summarize(read_pcap(io.BytesIO(wire)), snapshot, {PORT})
    assert report.count("Device mapping ambiguous") == 2
    assert f"{other}:{PORT}" in report
    assert f":{PORT + 1} ->" not in report
    assert "handoff=" not in report and "HTTP (ports only)" not in report


def test_missing_evidence_is_inconclusive():
    wire = pcap([frame(SYN)])
    report = summarize(read_pcap(io.BytesIO(wire)), read_snapshot(ring([])))
    assert "no-match=1" in report and "missing matches are inconclusive" in report


@pytest.mark.parametrize(("bad", "message"), [
    (b"not a PCAP", "global header"),
    (pcap([])[:20] + b"\x65\x00\x00\x00", "Ethernet link type"),
    (pcap([]) + b"\x00", "record header"),
    (pcap([frame(SYN)])[:-1], "record length"),
])
def test_malformed_pcap(bad, message):
    with pytest.raises(ValueError, match=message):
        list(read_pcap(io.BytesIO(bad)))


def test_cli(tmp_path):
    wire = tmp_path / "wired.pcap"
    snapshot = tmp_path / "device.bin"
    wire.write_bytes(pcap([frame(SYN), frame(replace(SYN, src=PORT + 1))]))
    snapshot.write_bytes(ring([event(10, 1)]))
    tool = Path(__file__).with_name("analyze_wifi_tcp_path.py")
    command = [sys.executable, str(tool), str(wire), str(snapshot), "--peer-port", str(PORT)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    assert "handoff=1" in result.stdout
    assert f":{PORT + 1} ->" not in result.stdout

    snapshot.write_bytes(b"\x00" * 4)
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 2 and "bytes in device snapshot" in result.stderr
