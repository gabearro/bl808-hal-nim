"""Synthetic probe captures for the offline TCP DMA timing audit."""

import json
from dataclasses import replace

import pytest

from analyze_wifi_tcp_dma import audit_round, detail_line, main
from analyze_wifi_tcp_path import CAPACITY, DMA_SHAPE, DOORBELL, HW_DONE, MAC, RX, SW_DONE, TX, TX_REJECT
from test_wifi_tcp_path_analysis import PORT, RESPONSE, SYN, SYN_ACK, event, frame, pcap, ring


OK, RETRY, OTHER = 0x80800200, 0x80010700, 0x80000000
NEW_HEAD = 0xff0300ab
APPEND = 0x060b0120


def trace(stage, tcp=RESPONSE, *, ip_id=7, detail=0, repush=0):
    row = list(event(0, stage, tcp, detail=detail))
    row[1] |= repush << 24
    row[5] = tcp.length | (ip_id << 16)
    return tuple(row)


def submission(tcp=RESPONSE, *, ip_id=7, status=OK, host=None, repush=0, detail=NEW_HEAD):
    return [trace(stage, tcp, ip_id=ip_id, detail=value, repush=ordinal)
            for stage, value, ordinal in ((DOORBELL, detail, 0), (HW_DONE, status, 0),
                                          (MAC, status | 1 if host is None else host, repush))]


def write_capture(path, rows, *, packets=None, ports=(PORT,), first_tick=0, tick_at=None):
    path.mkdir(exist_ok=True)
    rows = [(((first_tick + 10 * i) if tick_at is None else tick_at(i)) & 0xffffffff, *row[1:])
            for i, row in enumerate(rows)]
    (path / "device-trace.bin").write_bytes(ring(rows[-CAPACITY:], head=len(rows)))
    (path / "headers.pcap").write_bytes(pcap([frame(SYN)] if packets is None else packets))
    probes = [{"id": i, "metrics": f"{port} 0.01 0.02 0.03 000", "requested_port": PORT}
              for i, port in enumerate(ports)]
    (path / "probe.json").write_text(json.dumps(probes), encoding="utf-8")
    return path


def test_interleaved_exact_keys_wrap_ticks_and_keep_repush_separate(tmp_path, capsys):
    same_header_new_ip_id = 8
    same_ip_id_new_ack = replace(RESPONSE, ack=RESPONSE.ack + 1)
    syn_done = submission(SYN_ACK, host=OK)  # Publication bit already agrees.
    data_done = submission(status=RETRY)
    rows = [trace(RX, SYN), trace(TX, SYN_ACK), trace(TX), syn_done[0], data_done[0],
            *data_done[1:], *syn_done[1:], *submission(repush=1, detail=APPEND),
            trace(TX, ip_id=same_header_new_ip_id), *submission(ip_id=same_header_new_ip_id),
            trace(TX, same_ip_id_new_ack), *submission(same_ip_id_new_ack, status=OTHER)]
    path = write_capture(tmp_path, rows, first_tick=0xffffffe0)
    audit, _ = audit_round(path)
    assert audit.issues == [] and audit.counts["outputs"] == 4
    assert [(row.output.tcp.kind, row.output.ip_id, row.confirm.repush, row.outcome, row.elapsed)
            for row in audit.samples] == [
        ("SYN-ACK", 7, 0, "ok", (20, 40, 10)),
        ("data", 7, 0, "retry-limit", (20, 10, 10)),
        ("data", 7, 1, "ok", (None, 10, 10)),
        ("data", 8, 0, "ok", (10, 10, 10)),
        ("data", 7, 0, "other", (10, 10, 10)),
    ]
    assert "pre-MAC-seq-ctrl=0x00ab AC=3 new-head TID=255(no-sw-seq)" in detail_line(audit.samples[0])
    assert "pre-MAC-seq-ctrl=0x0120 AC=3 appended TID=6" in detail_line(audit.samples[2])
    assert main([str(path), "--detail-port", str(PORT)]) == 0
    report = capsys.readouterr().out
    assert "not an on-air observation" in report
    assert "SYN-ACK first-output ok n=1 queue-to-first-doorbell=20/20/20/20" in report
    assert "data first-output retry-limit n=1" in report
    assert "data repush ok n=1 queue-to-first-doorbell=n/a" in report
    assert "ip_id=7 ordinals=2/9/10/11 repush=1" in report


BELL, RAW, HOST = submission()


@pytest.mark.parametrize("shape_word", [1114, 1114 | (1 << 19)])
def test_shape_is_bound_to_adjacent_doorbell(tmp_path, shape_word):
    rows = [trace(RX, SYN), trace(TX), BELL, trace(DMA_SHAPE, detail=shape_word), RAW, HOST]
    # Doorbell and layout share the exact timestamp of the MMIO handoff.
    path = write_capture(tmp_path, rows, tick_at=lambda i: min(i, 2) * 10 if i <= 3 else i * 10)
    audit, _ = audit_round(path, require_shape=True)
    assert len(audit.samples) == 1
    assert "mac-bytes=1114" in detail_line(audit.samples[0])
    assert bool(audit.issues) == bool(shape_word >> 16)
    if audit.issues:
        assert "buffer-span" in audit.issues[0]

    path = write_capture(tmp_path, rows)
    audit, _ = audit_round(path)
    assert not audit.samples and any("does not belong to doorbell" in issue for issue in audit.issues)


def test_require_shape_rejects_legacy_capture(tmp_path):
    audit, _ = audit_round(write_capture(tmp_path, [trace(RX, SYN), trace(TX), BELL, RAW, HOST]),
                           require_shape=True)
    assert not audit.samples and any("missing DMA_SHAPE" in issue for issue in audit.issues)


@pytest.mark.parametrize(("rows", "issue"), [
    ([BELL, RAW, HOST], "missing TX output"),
    ([trace(TX)], "missing DOORBELL"),
    ([trace(TX), RAW, HOST], "expected DOORBELL"),
    ([trace(TX), BELL, HOST], "expected HW_DONE"),
    ([trace(TX), BELL, RAW], "missing host-confirm"),
    ([trace(TX), BELL, HOST, RAW], "expected HW_DONE"),
    ([trace(TX), BELL, BELL, RAW, HOST], "expected HW_DONE"),
    ([trace(TX), BELL, RAW, RAW, HOST], "expected host-confirm"),
    ([trace(TX), BELL, RAW, HOST, HOST], "orphan record"),
    ([trace(TX), BELL, RAW, HOST, trace(TX), BELL, RAW, HOST], "ambiguous repeated TX output"),
    ([trace(TX), *submission(repush=1)], "expected repush=0"),
    ([trace(TX), *submission(status=RETRY), *submission(repush=2)], "expected repush=1"),
    ([trace(TX), *submission(host=OK ^ 4)], "status mismatch"),
    ([trace(TX), *submission(status=0)], "invalid raw HW_DONE status"),
    ([trace(TX), *submission(status=OK | SW_DONE)], "invalid raw HW_DONE status"),
    ([trace(TX), BELL, trace(HW_DONE, ip_id=8, detail=OK), HOST], "expected HW_DONE"),
    ([trace(TX), BELL, trace(HW_DONE, replace(RESPONSE, ack=0), detail=OK), HOST], "expected HW_DONE"),
])
def test_does_not_pair_missing_ambiguous_or_orphan_records(tmp_path, rows, issue):
    path = write_capture(tmp_path, [trace(RX, SYN), *rows])
    audit, _ = audit_round(path)
    assert audit.samples == []
    assert any(issue in problem for problem in audit.issues)
    assert audit.counts["excluded-keys"] >= 1


def test_bad_tick_excludes_only_its_key_and_exit_signals_failure(tmp_path, capsys):
    rows = [trace(RX, SYN), trace(TX), *submission(), trace(TX, SYN_ACK), *submission(SYN_ACK)]
    path = write_capture(tmp_path, rows, tick_at=lambda i: 19 if i == 3 else i * 10)
    audit, _ = audit_round(path)
    assert [row.output.tcp for row in audit.samples] == [SYN_ACK]
    assert any("out-of-order or ambiguous ticks" in issue for issue in audit.issues)
    assert main([str(path)]) == 1
    report = capsys.readouterr().out
    assert "FAIL (timings shown for verified keys only)" in report
    assert "data first-output" not in report


def test_rejection_and_software_retirement_are_not_hardware_samples(tmp_path):
    rows = [trace(RX, SYN), trace(TX, SYN_ACK), *submission(SYN_ACK),
            trace(TX), trace(TX_REJECT, detail=1), trace(TX, ip_id=8),
            trace(MAC, ip_id=8, detail=SW_DONE | 1)]
    audit, _ = audit_round(write_capture(tmp_path, rows))
    assert audit.issues == []
    assert audit.counts["rejected"] == audit.counts["software-retired"] == 1
    assert [row.output.tcp for row in audit.samples] == [SYN_ACK]


def test_same_boot_wrapped_rings_use_wire_syn_windows_not_port_or_head_alone(tmp_path, capsys):
    new_syn = replace(SYN, seq=222)
    next_syn = replace(SYN, seq=333)
    other_syn = replace(SYN, src=PORT + 1)
    other_tx = replace(RESPONSE, dst=PORT + 1)
    padding = [trace(RX, other_syn)] * CAPACITY
    old = [trace(RX, SYN), trace(TX), *submission(status=RETRY)]
    new = [trace(RX, new_syn), trace(TX), *submission()]
    future = [trace(RX, next_syn), trace(TX), *submission(status=OTHER)]
    unlisted = [trace(RX, other_syn), trace(TX, other_tx), *submission(other_tx)]
    first = write_capture(tmp_path / "first", padding + old)
    second = write_capture(tmp_path / "second", padding + old + new + unlisted + future,
                           packets=[frame(new_syn), frame(new_syn), frame(other_syn)])
    overlap = write_capture(tmp_path / "overlap", padding + old + new + unlisted + future)

    for path, expected in ((first, "retry-limit"), (second, "ok"), (overlap, "retry-limit")):
        audit, _ = audit_round(path)
        assert audit.head > CAPACITY and audit.issues == []
        assert [row.outcome for row in audit.samples] == [expected]
    assert main([str(first), str(second), str(overlap)]) == 0
    report = capsys.readouterr().out
    aggregate = report.split("Aggregate:", 1)[1]
    assert "verified-attempts=2 duplicate-ring-samples=1" in aggregate
    assert "data first-output ok n=1" in aggregate
    assert "data first-output retry-limit n=1" in aggregate


def test_wrapped_missing_syn_and_zero_ports_are_not_guessed(tmp_path):
    other_syn = replace(SYN, src=PORT + 1)
    other_tx = replace(RESPONSE, dst=PORT + 1)
    rows = [trace(RX, SYN), *[trace(RX, other_syn)] * CAPACITY,
            trace(TX), *submission(), trace(TX, other_tx), *submission(other_tx)]
    path = write_capture(tmp_path, rows, ports=(PORT, 0), packets=[frame(SYN), frame(other_syn)])
    audit, _ = audit_round(path)
    assert any("no retained trace SYN matching the wired SYN" in issue for issue in audit.issues)
    assert audit.counts["unresolved-port"] == 1 and audit.counts["scoped-ports"] == 0
    assert audit.samples == []


@pytest.mark.parametrize(("packets", "issue"), [
    ([], "missing wired flow"),
    ([frame(RESPONSE)], "missing wired SYN"),
    ([frame(SYN), frame(SYN, peer="192.0.2.30")], "ambiguous wired flows"),
    ([frame(SYN), frame(replace(SYN, seq=1))], "ambiguous wired SYN signatures"),
])
def test_requires_unique_wired_connection(tmp_path, packets, issue):
    rows = [trace(RX, SYN), trace(TX), *submission()]
    audit, _ = audit_round(write_capture(tmp_path, rows, packets=packets))
    assert audit.samples == [] and any(issue in problem for problem in audit.issues)


def test_matching_syn_across_device_connection_boundaries_is_ambiguous(tmp_path):
    rows = [trace(RX, SYN), trace(TX), *submission(), trace(RX, replace(SYN, seq=123)),
            trace(RX, SYN), trace(TX), *submission()]
    audit, _ = audit_round(write_capture(tmp_path, rows))
    assert audit.samples == [] and any("recurs across connection boundaries" in issue
                                      for issue in audit.issues)


def test_same_tick_stages_are_ordered_by_ordinal(tmp_path):
    rows = [trace(RX, SYN), trace(TX), *submission()]
    audit, _ = audit_round(write_capture(tmp_path, rows, tick_at=lambda _: 100))
    assert audit.issues == []
    assert [row.elapsed for row in audit.samples] == [(0, 0, 0)]


def test_in_window_ring_hole_prevents_pairing(tmp_path):
    rows = [trace(RX, SYN), trace(TX), BELL, trace(0), RAW, HOST]
    audit, _ = audit_round(write_capture(tmp_path, rows))
    assert audit.samples == [] and any("invalid trace row in the probe window" in issue
                                      for issue in audit.issues)


def test_cli_invalid_capture_exit(tmp_path, capsys):
    write_capture(tmp_path, [])
    (tmp_path / "device-trace.bin").write_bytes(b"bad")
    assert main([str(tmp_path)]) == 2
    assert "INVALID: expected" in capsys.readouterr().out
