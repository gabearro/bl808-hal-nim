#!/usr/bin/env python3
"""Correlate saved channel-11 MAC headers with one Ox64 TCP ring snapshot."""

from __future__ import annotations

import argparse
import struct
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO

from analyze_wifi_tcp_path import (
    CAPACITY, DONE, DOORBELL, HW_DONE, PCAP_ENDIAN, SNAPSHOT_SIZE, SW_DONE,
    Event, Snapshot, read_snapshot,
)


CHANNEL = 2462
FROG = bytes.fromhex("1c36bb0611dc")
Key = tuple[int, int]  # QoS TID, 12-bit sequence number


@dataclass(frozen=True)
class Stamp:
    record: int
    pcap_ns: int
    tsft_us: int | None


@dataclass
class AirGroup:
    attempts: list[Stamp] = field(default_factory=list)
    retries: int = 0
    reused: bool = False
    fragmented: bool = False
    ack_candidates: int = 0
    mpdu_bytes: Counter[int] = field(default_factory=Counter)


@dataclass
class Capture:
    counts: Counter[str] = field(default_factory=Counter)
    groups: dict[Key, AirGroup] = field(default_factory=lambda: defaultdict(AirGroup))
    bad_fcs_uplink: Counter[Key] = field(default_factory=Counter)
    ack_clock: str = "PCAP timestamps"


def radiotap(file: BinaryIO, start: int, caplen: int) -> tuple[int | None, int | None, int | None]:
    """Read only the presence words and fields through Channel, in wire order."""
    if caplen < 8:
        raise ValueError("short radiotap header")
    version, length, first = struct.unpack("<BxHI", file.read(8))
    if version != 0 or not 8 <= length <= caplen:
        raise ValueError("invalid radiotap version or length")
    present = first
    while present & (1 << 31):
        if file.tell() + 4 > start + length:
            raise ValueError("truncated radiotap presence bitmap")
        present, = struct.unpack("<I", file.read(4))

    offset, values = file.tell() - start, [None, None, None, None]
    for bit, (size, align, fmt) in enumerate(((8, 8, "<Q"), (1, 1, "<B"),
                                              (1, 1, "<B"), (4, 2, "<H2x"))):
        if first & (1 << bit):
            offset += -offset % align
            if offset + size > length:
                raise ValueError("radiotap field exceeds header length")
            file.seek(start + offset)
            values[bit], = struct.unpack(fmt, file.read(size))
            offset += size
    file.seek(start + length)
    tsft, flags, _, frequency = values
    return frequency, flags, tsft


def read_mac(file: BinaryIO, room: int, original_length: int, stamp: Stamp, flags: int | None,
             ox64: bytes, ap: bytes, result: Capture, acks: list[Stamp]) -> None:
    bad_fcs = bool((flags or 0) & 0x40)
    if room < 2:
        result.counts["short-mac"] += 1
        return
    fc, = struct.unpack("<H", file.read(2))
    if fc & 3:
        return
    kind = fc & 0x00fc
    if kind == 0xd4:
        size = 10
    elif kind == 0x80:
        size = 24
    elif kind in (0x88, 0x98, 0xa8, 0xb8) and fc & 0x0300 == 0x0100:
        size = 26
    else:
        return
    if room < size:
        result.counts["short-mac"] += 1
        return
    header = file.read(size - 2)
    ra, ta = header[2:8], header[8:14]
    if kind == 0x80 and ta == ap and header[14:20] == ap and not bad_fcs:
        result.counts["ap-beacons"] += 1
    elif kind == 0xd4 and ra == ox64 and not bad_fcs:
        acks.append(stamp)
    elif size == 26 and ra == ap and ta == ox64:
        seq_ctrl, = struct.unpack_from("<H", header, 20)
        key = header[22] & 15, seq_ctrl >> 4
        if bad_fcs:
            result.bad_fcs_uplink[key] += 1
            return
        group = result.groups[key]
        retry = bool(fc & 0x0800)
        group.reused |= bool(group.attempts) and not retry
        group.fragmented |= bool(seq_ctrl & 15 or fc & 0x0400)
        group.attempts.append(stamp)
        group.retries += retry
        # Length check only for plain three-address QoS Data, no HT
        # control, fragments or A-MSDU. Do not guess an absent Flags field.
        if (flags is not None and kind == 0x88 and not fc & 0x8400
                and not seq_ctrl & 15 and not header[22] & 0x80):
            pad = (-size % 4) if flags & 0x20 else 0
            fcs = 4 if flags & 0x10 else 0
            if original_length >= size + pad + fcs:
                group.mpdu_bytes[original_length - pad - fcs + 4] += 1


def read_capture(file: BinaryIO, ox64: bytes, ap: bytes, ack_window_us: int) -> Capture:
    file_size = file.seek(0, 2)
    file.seek(0)
    header = file.read(24)
    magic = header[:4]
    endian = PCAP_ENDIAN.get(magic)
    if len(header) != 24 or endian is None:
        raise ValueError("expected a classic radiotap PCAP (not PCAPNG)")
    major, minor, _, _, snaplen, linktype = struct.unpack_from(endian + "HHIIII", header, 4)
    if (major, minor) != (2, 4) or not snaplen or linktype & 0xffff != 127:
        raise ValueError("expected classic PCAP v2.4 with radiotap link type and nonzero snaplen")
    ticks = 1_000_000_000 if magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d") else 1_000_000
    record = struct.Struct(endian + "IIII")
    result, acks = Capture(), []
    while file.tell() < file_size:
        if file_size - file.tell() < record.size:
            raise ValueError("truncated PCAP record header; use a complete saved capture")
        sec, fraction, caplen, wirelen = record.unpack(file.read(record.size))
        start = file.tell()
        if fraction >= ticks or caplen > min(snaplen, wirelen) or start + caplen > file_size:
            raise ValueError("invalid or truncated PCAP record; use a complete saved capture")
        result.counts["records"] += 1
        frequency, flags, tsft = radiotap(file, start, caplen)
        if frequency == CHANNEL:
            result.counts["ch11"] += 1
            bad_fcs = bool((flags or 0) & 0x40)
            result.counts["bad-fcs-ch11"] += bad_fcs
            stamp = Stamp(result.counts["records"], sec * 10**9 + fraction * (10**9 // ticks), tsft)
            mac_end = start + min(caplen, wirelen - (4 if (flags or 0) & 0x10 else 0))
            read_mac(file, mac_end - file.tell(), wirelen - (file.tell() - start),
                     stamp, flags, ox64, ap, result, acks)
        else:
            result.counts["no-channel" if frequency is None else "off-channel"] += 1
        file.seek(start + caplen)

    use_tsft = bool(acks and result.groups) and all(
        stamp.tsft_us is not None for group in result.groups.values() for stamp in group.attempts
    ) and all(stamp.tsft_us is not None for stamp in acks)
    result.ack_clock = "receiver TSFT" if use_tsft else "PCAP timestamps"

    def time(stamp: Stamp) -> int:
        return stamp.tsft_us * 1000 if use_tsft else stamp.pcap_ns

    ack_times = sorted((time(ack), ack.record) for ack in acks)
    result.counts["acks-to-ox64"] = len(acks)
    for group in result.groups.values():
        candidates = set()
        for attempt in group.attempts:
            tick = time(attempt)
            lo = bisect_right(ack_times, (tick, attempt.record))
            hi = bisect_right(ack_times, (tick + ack_window_us * 1000, result.counts["records"]))
            candidates.update(index for _, index in ack_times[lo:hi] if index > attempt.record)
        group.ack_candidates = len(candidates)
    return result


@dataclass(frozen=True)
class Submission:
    bell: Event
    done: Event | None
    issue: str | None

    @property
    def key(self) -> Key:
        return self.bell.detail >> 24, (self.bell.detail & 0xffff) >> 4


def submissions(snapshot: Snapshot) -> tuple[list[Submission], int]:
    # DONE does not carry a descriptor ID or sequence control. Pair only
    # unambiguous alternating rows for the exact recorded packet identity.
    by_packet = defaultdict(list)
    ordinals = {row.ordinal for row in snapshot.events}
    holes = sorted(set(range(max(0, snapshot.head - CAPACITY), snapshot.head)) - ordinals)
    for row in snapshot.events:
        if row.stage in (DOORBELL, HW_DONE):
            by_packet[row.tcp, row.ip_id].append(row)
    result = []
    used_done = 0
    for rows in by_packet.values():
        for i, bell in enumerate(rows):
            if bell.stage != DOORBELL:
                continue
            done = rows[i + 1] if i + 1 < len(rows) else None
            issue = None
            if ((i and rows[i - 1].stage == DOORBELL)
                    or (done and done.stage == DOORBELL)
                    or (i + 2 < len(rows) and rows[i + 2].stage == HW_DONE)):
                issue = "ambiguous-trace"
            elif done is None:
                issue = "missing-done"
            elif done.detail & (DONE | SW_DONE) != DONE:
                issue = "invalid-done"
            elif bisect_left(holes, bell.ordinal) != bisect_left(holes, done.ordinal):
                issue = "trace-gap"
            used_done += issue is None
            result.append(Submission(bell, done if issue is None else None, issue))
    orphan = sum(row.stage == HW_DONE for row in snapshot.events) - used_done
    return sorted(result, key=lambda item: item.bell.ordinal), orphan


def report(capture: Capture, snapshot: Snapshot, ap: bytes, ack_window_us: int,
           ports: set[int]) -> tuple[str, bool]:
    counts = capture.counts
    lines = [f"Capture: records={counts['records']} 2462MHz={counts['ch11']} "
             f"off-channel={counts['off-channel']} no-channel={counts['no-channel']} "
             f"short-mac={counts['short-mac']} selected-AP={ap.hex(':')} "
             f"beacons={counts['ap-beacons']}.",
             f"Monitor bad-FCS flags on channel 11: {counts['bad-fcs-ch11']} "
             f"(apparent Ox64 uplink headers: {sum(capture.bad_fcs_uplink.values())}); "
             "not counted as attempts or evidence of AP reception."]
    if not counts["ap-beacons"]:
        return "\n".join(lines + ["Channel/AP not verified: no selected-AP beacon at 2462 MHz."]), False

    samples, orphan = submissions(snapshot)
    sequence_uses = Counter(sample.key for sample in samples)
    selected = {sample.key for sample in samples if not ports or sample.bell.tcp.dst in ports}
    lines.append(f"Air groups (unflagged attempts): ACK candidates are later ACKs to Ox64 within {ack_window_us} us "
                 f"by {capture.ack_clock}; not exclusive or attributable to a specific TX. "
                 f"Total ACK headers to Ox64: {counts['acks-to-ox64']}.")
    air_keys = capture.groups.keys() | capture.bad_fcs_uplink.keys()
    for tid, sequence in sorted(air_keys & selected if ports else air_keys):
        key = tid, sequence
        group = capture.groups.get(key) or AirGroup()
        lines.append(f"  tid={tid} seq=0x{sequence:03x} attempts={len(group.attempts)} "
                     f"retries={group.retries} candidate-acks={group.ack_candidates} "
                     f"apparent-bad-fcs={capture.bad_fcs_uplink[key]}"
                     + (" mac-bytes=" + "/".join(map(str, sorted(group.mpdu_bytes)))
                        if group.mpdu_bytes else "")
                     + (" repeated-start" if group.reused else "")
                     + (" fragmented" if group.fragmented else ""))

    lines.append(f"Trace: head={snapshot.head} invalid={snapshot.invalid} "
                 f"stale-slots={snapshot.unused_nonzero} unpaired-DONE={orphan}; "
                 f"ring-at-capacity={snapshot.head >= CAPACITY}.")
    totals, by_port = Counter(), defaultdict(Counter)
    hardware = 0
    for sample in samples:
        tid, sequence = sample.key
        port = sample.bell.tcp.dst
        if ports and port not in ports:
            continue
        if tid > 15:
            totals["skipped-tid-255" if tid == 255 else "invalid-tid"] += 1
            continue
        group = capture.groups.get(sample.key)
        status = sample.issue
        if sample.done is not None:
            hardware += 1
            if sequence_uses[sample.key] > 1:
                status = "ambiguous-device-key"
            elif group is None:
                status = "missing-capture"
            elif sample.bell.detail & 15 or group.reused or group.fragmented:
                status = "ambiguous-capture"
            else:
                status = "matched"
        totals[status] += 1
        by_port[port][status] += 1
        raw = f" done={sample.done.ordinal} raw=0x{sample.done.detail:08x}" if sample.done else ""
        lines.append(f"  port={port} tid={tid} seq=0x{sequence:03x} "
                     f"doorbell={sample.bell.ordinal}{raw} {status}")

    def summary(row: Counter[str]) -> str:
        labels = ("matched", "missing-capture", "ambiguous-capture", "ambiguous-device-key")
        return " ".join(f"{label}={row[label]}" for label in (*labels, *sorted(row.keys() - set(labels))))

    lines.append(f"Eligible hardware submissions={hardware}: {summary(totals)}")
    for port in sorted(ports):
        lines.append(f"  port={port}: {summary(by_port[port])}")
    lines.append("One overlapping boot assumed. Sequence-only matches cannot rule out unseen reuse, "
                 "pre-MAC sequence rewriting or missed frames. No payload or cross-clock comparison.")
    return "\n".join(lines), True


def mac_address(value: str) -> bytes:
    parts = value.split(":")
    if len(parts) != 6 or any(len(part) != 2 for part in parts):
        raise argparse.ArgumentTypeError("expected a colon-separated MAC address")
    try:
        address = bytes.fromhex("".join(parts))
        if len(address) != 6:
            raise ValueError("wrong MAC length")
        return address
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected a colon-separated MAC address") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="saved classic radiotap PCAP")
    parser.add_argument("trace", type=Path, help="one device-trace.bin snapshot from the same boot")
    parser.add_argument("--ox64-mac", type=mac_address, required=True)
    parser.add_argument("--ap-mac", type=mac_address, default=FROG, help="AP BSSID (default: Frog)")
    parser.add_argument("--peer-port", type=int, action="append", default=[], help="filter report; repeatable")
    parser.add_argument("--ack-window-us", type=int, default=1000, help="capture-local window (default: 1000)")
    args = parser.parse_args(argv)
    if (args.ack_window_us <= 0 or any(not 1 <= port <= 65535 for port in args.peer_port)
            or args.ox64_mac == args.ap_mac):
        parser.error("require a positive ACK window, valid ports and distinct MAC addresses")
    try:
        with args.trace.open("rb") as file:
            snapshot = read_snapshot(file.read(SNAPSHOT_SIZE + 1))
        with args.capture.open("rb", buffering=0) as file:
            capture = read_capture(file, args.ox64_mac, args.ap_mac, args.ack_window_us)
    except (OSError, ValueError, struct.error) as error:
        parser.error(str(error))
    output, verified = report(capture, snapshot, args.ap_mac, args.ack_window_us, set(args.peer_port))
    print(output)
    return 0 if verified else 1


if __name__ == "__main__":
    raise SystemExit(main())
