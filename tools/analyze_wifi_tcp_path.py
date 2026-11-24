#!/usr/bin/env python3
"""Compare a wired Ethernet PCAP with a BL808 Wi-Fi TCP ring snapshot.

Assumes port 80 is on the device and ports are unchanged on the wired side.
Match direction, ports, sequence/ack numbers, flags and declared TCP data
length. IP IDs need not be preserved. No clock alignment, payload inspection,
or attempt to pair individual retransmissions is performed.
"""

from __future__ import annotations

import argparse
import ipaddress
import struct
from collections import Counter, defaultdict
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


HTTP = 80
SYN, RST, ACK = 0x02, 0x04, 0x10
RX, RX_REJECT, TX, TX_REJECT, MAC, ACCEPT, POOL_FULL, RECV, FALLBACK_CHOICE = range(1, 10)
DOORBELL, HW_DONE, DMA_SHAPE = 10, 11, 12
DONE, SW_DONE, SUCCESS = 1 << 31, 1 << 30, 1 << 23
RETRY_LIMIT, POLICY_CAPTURED = 1 << 16, 1 << 16
STAGE_LABEL = {RX: "handoff", RX_REJECT: "reject", TX: "output", TX_REJECT: "reject"}
CAPACITY = 1024
TICK_WRAP = 1 << 32
ENTRY = struct.Struct("<7I")
SNAPSHOT_SIZE = 4 + CAPACITY * ENTRY.size
POLICY_CAPACITY = 384
POLICY_ENTRY = struct.Struct("<13I")
POLICY_SNAPSHOT_SIZE = 4 + POLICY_CAPACITY * POLICY_ENTRY.size
PCAP_ENDIAN = {
    b"\xd4\xc3\xb2\xa1": "<", b"\xa1\xb2\xc3\xd4": ">",  # microseconds
    b"\x4d\x3c\xb2\xa1": "<", b"\xa1\xb2\x3c\x4d": ">",  # nanoseconds
}


@dataclass(frozen=True)
class Tcp:
    src: int
    dst: int
    seq: int
    ack: int
    flags: int
    length: int

    @property
    def direction(self) -> str:
        return "RX" if self.dst == HTTP else "TX"

    @property
    def kind(self) -> str:
        if self.flags & SYN:
            return "SYN-ACK" if self.flags & ACK else "SYN"
        if self.flags & RST:
            return "RST"
        return "data" if self.length else "other"


@dataclass(frozen=True, order=True)
class Flow:
    peer_ip: str
    peer_port: int
    local_ip: str


@dataclass(frozen=True)
class Event:
    tick_offset_us: int
    stage: int
    tcp: Tcp
    ip_id: int
    detail: int
    ordinal: int
    repush: int
    policy_captured: bool


@dataclass(frozen=True)
class Snapshot:
    head: int
    events: list[Event]
    invalid: int
    unused_nonzero: bool


@dataclass(frozen=True)
class TxPolicy:
    rates: tuple[int, ...]
    power: tuple[int, ...]
    policy: int
    retry_limit: int
    ack_control: int
    hardware_status: int

    def settings(self) -> str:
        rates = "/".join(f"{r:08x}" for r in self.rates)
        power = "/".join(f"{p:08x}" for p in self.power)
        return (f"rates={rates} power={power} policy={self.policy:08x}"
                f" limit={self.retry_limit:08x} ack={self.ack_control:08x}")


def read_snapshot(raw: bytes) -> Snapshot:
    if len(raw) != SNAPSHOT_SIZE:
        raise ValueError(f"expected {SNAPSHOT_SIZE} bytes in device snapshot")
    head, = struct.unpack_from("<I", raw)
    count = min(head, CAPACITY)
    # With a low head, old/nonzero slots could also mean the uint32 head wrapped.
    # Use only the guaranteed prefix in that case, not potentially stale rows.
    unused_nonzero = count < CAPACITY and any(raw[4 + count * ENTRY.size:])
    events, invalid = [], 0
    previous = None
    elapsed = 0
    for i in range(head - count, head):
        tick, stage_flags, ports, seq, ack, length_id, detail = ENTRY.unpack_from(
            raw, 4 + (i % CAPACITY) * ENTRY.size
        )
        stage = stage_flags & 0xff
        if not RX <= stage <= DMA_SHAPE:
            invalid += 1
            continue
        if previous is not None:
            # Choose the nearest tick, allowing small reorderings on either side of wrap.
            elapsed += (tick - previous + TICK_WRAP // 2) % TICK_WRAP - TICK_WRAP // 2
        previous = tick
        tcp = Tcp(ports & 0xffff, ports >> 16, seq, ack,
                  (stage_flags >> 8) & 0xff, length_id & 0xffff)
        events.append(Event(elapsed, stage, tcp, length_id >> 16, detail, i,
                            stage_flags >> 24, bool(stage_flags & POLICY_CAPTURED)))
    return Snapshot(head, events, invalid, unused_nonzero)


def read_policies(raw: bytes, snapshot: Snapshot) -> dict[int, TxPolicy]:
    if len(raw) != POLICY_SNAPSHOT_SIZE:
        raise ValueError(f"expected {POLICY_SNAPSHOT_SIZE} bytes in policy snapshot")
    head, = struct.unpack_from("<I", raw)
    if head > snapshot.head:
        raise ValueError("policy head is ahead of TCP head; snapshots differ or wrapped")
    eligible = {e.ordinal for e in snapshot.events if e.stage == MAC and e.policy_captured
                and e.detail & (DONE | SW_DONE) == DONE}
    policies = {}
    for i in range(max(0, head - POLICY_CAPACITY), head):
        ordinal, *words = POLICY_ENTRY.unpack_from(raw, 4 + i % POLICY_CAPACITY * POLICY_ENTRY.size)
        if ordinal not in eligible:
            continue
        if ordinal in policies:
            raise ValueError(f"duplicate policy for TCP ordinal {ordinal}")
        policies[ordinal] = TxPolicy(tuple(words[:4]), tuple(words[8:]),
                                     words[4], words[5], words[6], words[7])
    return policies


def summarize_policies(snapshot: Snapshot, policies: dict[int, TxPolicy],
                       peer_ports: set[int]) -> str:
    groups = defaultdict(Counter)
    rows = []
    retained, captured = 0, 0
    for e in snapshot.events:
        if (e.stage != MAC or e.tcp.src != HTTP or e.detail & (DONE | SW_DONE) != DONE
                or (peer_ports and e.tcp.dst not in peer_ports)):
            continue
        retained += 1
        captured += e.policy_captured
        p = policies.get(e.ordinal)
        if p is None:
            continue
        if e.detail & SUCCESS:
            outcome = "ok"
        elif e.detail & RETRY_LIMIT:
            outcome = "retry-limit"
        else:
            outcome = "other"
        groups[p.settings()][outcome] += 1
        if peer_ports:
            rows.append(f"  port={e.tcp.dst} tick={e.tick_offset_us}us {e.tcp.kind} "
                        f"len={e.tcp.length} repush={e.repush} {outcome} "
                        f"host={e.detail:08x} hw={p.hardware_status:08x} {p.settings()}")
    lines = [f"Submitted TX policy: {sum(map(Counter.total, groups.values()))}/{retained} "
             f"hardware completions matched; {captured} marked captured.",
             "  Grouped by programmed settings, not observed transmissions or RF power."]
    for settings, counts in sorted(groups.items(), key=lambda row: (-row[1].total(), row[0])):
        lines.append(f"  {format_counts(counts, ('ok', 'retry-limit', 'other'))} {settings}")
    return "\n".join(lines + rows)


def ethernet_tcp(file: BinaryIO, start: int, caplen: int, wirelen: int) -> tuple[Flow, Tcp] | None:
    if caplen < 14:
        return None
    eth = file.read(14)
    ethertype = int.from_bytes(eth[12:14], "big")
    ip_offset = 14
    while ethertype in (0x8100, 0x88a8):
        if caplen < ip_offset + 4:
            return None
        ethertype = int.from_bytes(file.read(4)[2:4], "big")
        ip_offset += 4
    if ethertype != 0x0800 or caplen < ip_offset + 20:
        return None
    ip = file.read(20)
    ihl = (ip[0] & 0xf) * 4
    total = int.from_bytes(ip[2:4], "big")
    fragment = int.from_bytes(ip[6:8], "big")
    if (ip[0] >> 4 != 4 or ihl < 20 or ip[9] != 6 or fragment & 0x3fff
            or not ihl + 20 <= total <= wirelen - ip_offset
            or caplen < ip_offset + ihl + 20):
        return None
    file.seek(start + ip_offset + ihl)
    tcp_header = file.read(20)
    src, dst, seq, ack, offset, flags = struct.unpack_from("!HHIIBB", tcp_header)
    tcp_len = (offset >> 4) * 4
    if not 20 <= tcp_len <= total - ihl or (src == HTTP) == (dst == HTTP):
        return None
    tcp = Tcp(src, dst, seq, ack, flags, total - ihl - tcp_len)
    source_ip, dest_ip = str(ipaddress.IPv4Address(ip[12:16])), str(ipaddress.IPv4Address(ip[16:20]))
    if dst == HTTP:
        return Flow(source_ip, src, dest_ip), tcp
    return Flow(dest_ip, dst, source_ip), tcp


def read_pcap(file: BinaryIO) -> Iterator[tuple[Flow, Tcp]]:
    file_size = file.seek(0, 2)
    file.seek(0)
    header = file.read(24)
    endian = PCAP_ENDIAN.get(header[:4])
    if len(header) != 24 or endian is None:
        raise ValueError("expected a classic PCAP global header (not PCAPNG)")
    major, minor, _, _, snaplen, linktype = struct.unpack_from(endian + "HHIIII", header, 4)
    if (major, minor) != (2, 4) or not snaplen or (linktype & 0xffff) != 1:
        raise ValueError("expected classic PCAP v2.4 with Ethernet link type and nonzero snaplen")
    record = struct.Struct(endian + "IIII")
    while file.tell() < file_size:
        header = file.read(record.size)
        if len(header) != record.size:
            raise ValueError("truncated PCAP record header")
        _, _, caplen, wirelen = record.unpack(header)
        start = file.tell()
        if caplen > min(snaplen, wirelen) or start + caplen > file_size:
            raise ValueError("invalid or truncated PCAP record length")
        packet = ethernet_tcp(file, start, caplen, wirelen)
        file.seek(start + caplen)  # Skip options/payload, even if present in the capture.
        if packet is not None:
            yield packet


def stage_counts(rows: Iterable[list[Event]]) -> Counter:
    """Count signatures with each kind of evidence, not events or transmissions."""
    counts = Counter()
    for events in rows:
        labels = set()
        for event in events:
            if event.stage != MAC:
                labels.add(STAGE_LABEL[event.stage])
            elif event.detail & (DONE | SW_DONE) != DONE:
                labels.add("MAC-not-done")
            elif event.detail & SUCCESS:
                labels.add("MAC-done-ok")
            else:
                labels.add("MAC-done-no-success")
        counts.update(labels or {"no-match"})
    return counts


def format_counts(counts: Counter, labels: tuple[str, ...]) -> str:
    return " ".join(f"{label}={counts[label]}" for label in labels)


def summarize(packets: Iterable[tuple[Flow, Tcp]], snapshot: Snapshot,
              peer_ports: set[int] | None = None) -> str:
    flows = defaultdict(Counter)
    for flow, tcp in packets:
        if not peer_ports or flow.peer_port in peer_ports:
            flows[flow][tcp] += 1
    port_uses = Counter(flow.peer_port for flow in flows)
    device = defaultdict(lambda: defaultdict(list))
    apps = defaultdict(Counter)
    for event in snapshot.events:
        tcp = event.tcp
        if event.stage in (RX, RX_REJECT, ACCEPT, POOL_FULL, RECV) and tcp.dst == HTTP:
            if event.stage >= ACCEPT:
                apps[tcp.src][event.stage] += 1
            else:
                device[tcp.src][tcp].append(event)
        elif event.stage in (TX, TX_REJECT, MAC) and tcp.src == HTTP:
            device[tcp.dst][tcp].append(event)

    lines = [f"Ring head={snapshot.head} valid={len(snapshot.events)}/{CAPACITY} "
             f"invalid={snapshot.invalid}."]
    if snapshot.head >= CAPACITY:
        lines.append("Ring full; earlier entries may have been overwritten.")
    if snapshot.unused_nonzero:
        lines.append("Nonzero slots beyond head ignored (stale entries or producer count wrap).")
    if snapshot.events:
        ticks = [event.tick_offset_us for event in snapshot.events]
        lines.append(f"Device tick offsets: {min(ticks)}..{max(ticks)} us from first valid row "
                     "(assumes adjacent ticks within half a wrap).")
    lines.append("No clock alignment or capture coverage assumed; missing matches are inconclusive.")
    lines.append("Counts are distinct signatures except wire copies and HTTP events; "
                 "one signature may have multiple stage or MAC statuses.")
    if not flows:
        lines.append("No selected wired HTTP flows with usable TCP headers.")

    for flow, wire in sorted(flows.items()):
        port = flow.peer_port
        lines.append(f"{flow.peer_ip}:{port} -> {flow.local_ip}:{HTTP}")
        ambiguous = port_uses[port] != 1
        if ambiguous:
            lines.append("  Device mapping ambiguous: multiple wired flows use this port pair.")
        observed = {} if ambiguous else device[port]
        for direction, labels in (
            ("RX", ("handoff", "reject")),
            ("TX", ("output", "reject", "MAC-done-ok", "MAC-done-no-success", "MAC-not-done")),
        ):
            for kind in ("SYN", "SYN-ACK", "data", "RST", "other"):
                wire_keys = [tcp for tcp in wire if tcp.kind == kind and tcp.direction == direction]
                device_only = [events for tcp, events in observed.items() if tcp not in wire
                               and tcp.kind == kind and tcp.direction == direction]
                if not wire_keys and not device_only:
                    continue
                copies = sum(wire[tcp] for tcp in wire_keys)
                line = f"  {direction} {kind}: wire={copies} copies/{len(wire_keys)} signatures"
                if wire_keys and not ambiguous:
                    counts = stage_counts(observed.get(tcp, []) for tcp in wire_keys)
                    line += "; wire signatures: " + format_counts(counts, labels + ("no-match",))
                lines.append(line)
                if device_only:
                    lines.append(f"    device-only={len(device_only)} signatures: "
                                 + format_counts(stage_counts(device_only), labels))
        if not ambiguous and apps[port]:
            counts = apps[port]
            lines.append(f"  HTTP (ports only): accept={counts[ACCEPT]} "
                         f"pool-full={counts[POOL_FULL]} recv={counts[RECV]}")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcap", type=Path, help="wired Ethernet capture file")
    parser.add_argument("snapshot", type=Path, help="raw device ring snapshot file")
    parser.add_argument("--policy-snapshot", type=Path, help="raw device TX policy ring snapshot")
    parser.add_argument("--peer-port", type=int, action="append", help="select peer TCP port (repeatable)")
    args = parser.parse_args()
    if args.peer_port and any(not 1 <= port <= 65535 for port in args.peer_port):
        parser.error("--peer-port must be in 1..65535")
    try:
        peer_ports = set(args.peer_port or ())
        with args.snapshot.open("rb") as ring:
            snapshot = read_snapshot(ring.read(SNAPSHOT_SIZE + 1))
        # Unbuffered reads prevent the file object from reading ahead into payload.
        with args.pcap.open("rb", buffering=0) as pcap:
            print(summarize(read_pcap(pcap), snapshot, peer_ports))
        if args.policy_snapshot is not None:
            with args.policy_snapshot.open("rb") as ring:
                policies = read_policies(ring.read(POLICY_SNAPSHOT_SIZE + 1), snapshot)
            print(summarize_policies(snapshot, policies, peer_ports))
    except (OSError, ValueError) as error:
        parser.exit(2, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
