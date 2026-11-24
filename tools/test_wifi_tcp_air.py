"""Header-only fixtures for the offline channel-11 analyzer."""

import io
import struct
from dataclasses import replace

import pytest

from analyze_wifi_tcp_air import FROG, main, read_capture, report, submissions
from analyze_wifi_tcp_path import CAPACITY, DOORBELL, HW_DONE, SW_DONE, read_snapshot
from test_wifi_tcp_path_analysis import PORT, RESPONSE, event, ring


OX64 = bytes.fromhex("b4c2e0ac96f3")
OTHER = b"\xaa" * 6
OK = 0x80800000


def radio(*, channel=2462, flags=0, tsft=None, extended=False):
    present = 2 | (8 if channel is not None else 0) | (1 if tsft is not None else 0)
    suffix = b"\0" * 4 if extended else b""
    if tsft is not None:
        suffix += b"\0" * (-len(suffix) % 8) + struct.pack("<Q", tsft)
    suffix += bytes([flags])
    if channel is not None:
        suffix += b"\0" + struct.pack("<HH", channel, 0)
    return struct.pack("<BBHI", 0, 0, 8 + len(suffix), present | (extended << 31)) + suffix


def beacon(ap=FROG):
    return struct.pack("<HH6s6s6sH", 0x80, 0, b"\xff" * 6, ap, ap, 0)


def uplink(seq, *, tid=0, retry=False, frag=0, fc=0x4188, ra=FROG, ta=OX64):
    return struct.pack("<HH6s6s6sHH", fc | (retry << 11), 0, ra, ta, OTHER, seq << 4 | frag, tid)


def ack(ra=OX64):
    return struct.pack("<HH6s", 0xd4, 0, ra)


def pcap(rows, *, nano=False):
    endian, magic = (">", 0xa1b23c4d) if nano else ("<", 0xa1b2c3d4)
    return struct.pack(endian + "IHHIIII", magic, 2, 4, 0, 0, 1024, 127) + b"".join(
        struct.pack(endian + "IIII", 100, tick * (1000 if nano else 1), len(frame), len(frame)) + frame
        for tick, frame in rows
    )


def sample(stage, value, *, seq=4, port=PORT):
    tcp = replace(RESPONSE, dst=port, seq=seq)
    return event(1234, stage, tcp, detail=value)


def bell(seq, *, tid=0, packet=4, port=PORT):
    return sample(DOORBELL, (tid << 24) | (3 << 16) | (seq << 4), seq=packet, port=port)


def done(*, packet=4, status=OK, port=PORT):
    return sample(HW_DONE, status, seq=packet, port=port)


def test_headers_only_qos_and_candidate_window():
    payload = b"DO NOT READ THIS PAYLOAD"
    raw = pcap([
        (0, radio() + beacon()),
        (20, radio() + ack()),  # Before any target MPDU.
        (50, radio() + uplink(7) + payload),
        (60, radio() + uplink(7, retry=True)),
        (65, radio() + uplink(7, tid=3)),
        (75, radio() + ack()),  # One nonexclusive candidate for each TID.
        (77, radio() + ack(OTHER)),
        (79, radio(flags=0x40) + ack()),
        (81, radio(channel=2437) + ack()),
        (82, radio(channel=None) + ack()),
        (90, radio() + uplink(8, ra=OTHER)),
        (91, radio() + uplink(8, ta=OTHER)),
        (92, radio() + uplink(8, fc=0x0188 ^ 0x0300)),  # FromDS.
        (93, radio() + uplink(8, fc=0x01c8)),  # QoS Null.
        (94, radio(flags=0x40) + uplink(9)),
        (95, radio() + uplink(10)[:24]),  # Missing QoS control.
        (120, radio() + ack()),  # Outside window.
    ])

    class HeadersOnly(io.BytesIO):
        def read(self, size=-1):
            start = raw.index(payload)
            assert size >= 0 and not (self.tell() < start + len(payload) and self.tell() + size > start)
            return super().read(size)

    capture = read_capture(HeadersOnly(raw), OX64, FROG, 30)
    assert capture.ack_clock == "PCAP timestamps"
    assert capture.counts["ap-beacons"] == capture.counts["off-channel"] == capture.counts["no-channel"] == 1
    assert capture.counts["bad-fcs-ch11"] == 2 and capture.counts["short-mac"] == 1
    assert capture.bad_fcs_uplink == {(0, 9): 1}
    assert {key: (len(item.attempts), item.retries, item.ack_candidates) for key, item in capture.groups.items()} == {
        (0, 7): (2, 1, 1), (3, 7): (1, 0, 1),
    }


def test_big_endian_nano_extended_radiotap_and_receiver_clock():
    capture = read_capture(io.BytesIO(pcap([
        (0, radio() + beacon()),
        (20, radio(tsft=4000, extended=True) + uplink(12, retry=True)),
        (2000, radio(tsft=4020) + ack()),
    ], nano=True)), OX64, FROG, 30)
    assert capture.ack_clock == "receiver TSFT"
    assert capture.groups[0, 12].ack_candidates == 1


def test_mpdu_lengths_use_original_record_size_not_capture_limit():
    header = radio(flags=0x30)
    captured = header + uplink(7)
    raw = pcap([(0, captured)])
    # Original length contains radiotap + 1,114 on-air bytes + 2 capture
    # alignment bytes. The packet record deliberately stores only headers.
    raw = raw[:36] + struct.pack("<I", len(header) + 1114 + 2) + raw[40:]
    capture = read_capture(io.BytesIO(raw), OX64, FROG, 30)
    assert capture.groups[0, 7].mpdu_bytes == {1114: 1}
    no_fcs = radio() + uplink(8) + bytes(40)
    capture = read_capture(io.BytesIO(pcap([(0, no_fcs)])), OX64, FROG, 30)
    assert capture.groups[0, 8].mpdu_bytes == {70: 1}


def test_report_same_key_is_not_unique_after_port_filter(tmp_path, capsys):
    pcap_path, trace_path = tmp_path / "air-ch11.pcap", tmp_path / "device-trace.bin"
    pcap_path.write_bytes(pcap([
        (0, radio() + beacon()),
        (1, radio() + uplink(1)),
        (2, radio() + uplink(1, retry=True)),
        (3, radio() + uplink(2)),
        (4, radio() + uplink(2)),
        (5, radio() + uplink(3)),
        (6, radio() + uplink(4, frag=1)),
        (7, radio(flags=0x40) + uplink(5)),
        (8, radio() + uplink(9)),
    ]))
    trace_path.write_bytes(ring([
        bell(1), bell(3, port=PORT + 1), done(port=PORT + 1), done(),
        bell(2), done(), bell(3), done(), bell(4), done(),
        bell(5), done(status=0x80010700), bell(0, tid=255), done(),
        bell(6), done(status=OK | SW_DONE), bell(7),
    ]))
    assert main([str(pcap_path), str(trace_path), "--ox64-mac", OX64.hex(":"), "--peer-port", str(PORT)]) == 0
    output = capsys.readouterr().out
    assert "attempts=2 retries=1 candidate-acks=0" in output
    assert "seq=0x005 attempts=0 retries=0 candidate-acks=0 apparent-bad-fcs=1" in output
    assert "seq=0x009" not in output
    assert "raw=0x80010700 missing-capture" in output
    assert "Eligible hardware submissions=5: matched=1 missing-capture=1 ambiguous-capture=2 ambiguous-device-key=1" in output
    assert "invalid-done=1 missing-done=1 skipped-tid-255=1" in output


def test_trace_holes_duplicate_completions_and_ring_boundary():
    rows = [done(), bell(1), bell(2), done(), bell(3, packet=7), done(packet=7),
            done(packet=7), bell(4, packet=8), (0,) * 7, done(packet=8),
            bell(5, packet=9), done(packet=9)]
    samples, unpaired = submissions(read_snapshot(ring(rows)))
    assert [sample.issue for sample in samples] == ["ambiguous-trace"] * 3 + ["trace-gap", None]
    assert unpaired == 5
    snapshot = read_snapshot(ring([done(), bell(1), done()], head=CAPACITY + 3))
    assert snapshot.invalid  # Sparse retained rows, including a leading unmatched DONE.
    samples, unpaired = submissions(snapshot)
    assert unpaired == 1 and samples[0].done is not None


def test_no_correlation_without_selected_ap_beacon():
    raw = pcap([(0, radio(channel=2437) + beacon()), (1, radio() + beacon(OTHER)),
                (2, radio(flags=0x40) + beacon()), (3, radio() + uplink(4))])
    capture = read_capture(io.BytesIO(raw), OX64, FROG, 1000)
    output, verified = report(capture, read_snapshot(ring([bell(4), done()])), FROG, 1000, set())
    assert not verified and "Channel/AP not verified" in output and "matched" not in output


@pytest.mark.parametrize("raw", [b"\x0a\x0d\x0d\x0a", pcap([(0, radio() + beacon())])[:-1],
                                 pcap([(0, struct.pack("<BBHI", 0, 0, 8, 1 << 31))])])
def test_invalid_or_incomplete_capture_errors(raw):
    with pytest.raises(ValueError):
        read_capture(io.BytesIO(raw), OX64, FROG, 1000)
