"""Validate the DHCP trace decoder against representative BL808 ring rows."""

import pytest

from analyze_wifi_dhcp_flow import decode, match_air, retry_report
from analyze_wifi_tcp_air import AirGroup, Capture, Stamp


XID = 0xED029438
POLICY = [0x80001207, 0x80000400, 0x80001003, 0x80000400,
          0xFFFF0704, 0, 0x2200, 0x80800500]


def fixture(tx_count=2, rx_count=2):
    return {
        "nimfw_dbg_dhcp_cfm_ring_idx": tx_count,
        "nimfw_dbg_dhcp_cfm_status_log": [0x80800501] * 8,
        "nimfw_dbg_dhcp_cfm_meta_log": [0x00470101, 0x00470101] + [0] * 6,
        "nimfw_dbg_dhcp_cfm_xid_log": [XID] * 8,
        "nimfw_dbg_dhcp_cfm_policy_log": POLICY * 8,
        "nimfw_dbg_dhcp_rx_trace_count": rx_count,
        "nimfw_dbg_dhcp_rx_trace_log": [XID, 0x902, 1, 0x82, 0x94380206,
                                       XID, 0x905, 1, 0x85, 0x94380501] + [0] * 30,
    }


def test_one_transaction_does_not_identify_one_transmission():
    snapshot = fixture()
    snapshot["nimfw_dbg_dhcp_cfm_meta_log"][1] |= 1 << 24
    report = decode(snapshot)
    assert report["unattributed"] is None
    transaction, = report["transactions"]
    assert transaction["xid"] == "0xed029438"
    assert [row["host_repush"] for row in transaction["tx_completions"]] == [0, 1]
    assert [row["type"] for row in transaction["rx_deliveries"]] == [2, 5]
    assert transaction["rx_deliveries"][1]["lwip_outcome"]["code"] == "0x00000085"
    assert transaction["tx_completions"][0]["mac"] == {
        "attempts": 6,
        "slots": [{"index": 0, "rate_word": "0x80001207", "attempts": 4, "acked": False},
                  {"index": 1, "rate_word": "0x80000400", "attempts": 2, "acked": True}],
    }


def test_wrapped_rings_and_ambiguous_outcome():
    snapshot = fixture(tx_count=10, rx_count=9)
    snapshot["nimfw_dbg_dhcp_rx_trace_log"][2] = 2
    report = decode(snapshot)
    transaction, = report["transactions"]
    assert report["tx_completions_overwritten"] == 2
    assert report["rx_deliveries_overwritten"] == 1
    assert [r["index"] for r in transaction["tx_completions"]] == [8, 9]
    assert [r["index"] for r in transaction["rx_deliveries"]] == [1, 8]
    assert transaction["rx_deliveries"][1]["lwip_outcome"] is None
    assert len(report["unattributed"]["tx_completions"]) == 6


@pytest.mark.parametrize(("index", "bad_word", "status"), [
    (0, 0x1207, 0x80800501), (4, 0xFFFF0304, 0x80800501),
    (6, 0x2201, 0x80800501), (7, 0x80800200, 0x80800501),
    (7, 0x80800502, 0x80800503), (7, 0xC0800500, 0xC0800501),
    (7, 0x80800800, 0x80800801),
])
def test_no_mac_attribution_for_unmatched_or_unsupported_policy(index, bad_word, status):
    policy = POLICY.copy()
    policy[index] = bad_word
    assert retry_report(status, 0x00470101, policy) is None


def test_terminal_retry_limit_has_no_acked_slot():
    policy = POLICY[:7] + [0x80010700]
    result = retry_report(0x80010701, 0x00470101, policy)
    assert [r["attempts"] for r in result["slots"]] == [4, 4]
    assert not any(r["acked"] for r in result["slots"])


def test_missing_or_truncated_ring_is_rejected():
    snapshot = fixture()
    del snapshot["nimfw_dbg_dhcp_cfm_policy_log"][0]
    with pytest.raises(ValueError, match="dhcp_cfm_policy_log"):
        decode(snapshot)


def test_air_match_requires_exact_unreused_sequence_and_tid():
    snapshot = fixture()
    snapshot["nimfw_dbg_dhcp_cfm_air_log"] = [0x80020120, 0x80020130] + [0] * 6
    report = decode(snapshot)
    capture = Capture()
    capture.counts["ap-beacons"] = 1
    capture.groups[2, 0x12] = AirGroup(
        attempts=[Stamp(1, 100000, None), Stamp(4, 300000, None)],
        retries=1, ack_candidates=1,
    )
    capture.groups[3, 0x13] = AirGroup(attempts=[Stamp(5, 400000, None)])
    capture.bad_fcs_uplink[2, 0x13] = 2
    match_air(report, capture)
    first, second = report["transactions"][0]["tx_completions"]
    assert first["air_header"] == {"tid": 2, "sequence": 0x12}
    assert first["air"] == {"state": "observed", "frames": 2, "retry_marked": 1,
                            "candidate_acks": 1, "bad_fcs_headers": 0}
    assert second["air"] == {"state": "not-observed", "bad_fcs_headers": 2}

    capture.groups[2, 0x12].reused = True
    match_air(report, capture)
    assert first["air"] == {"state": "ambiguous"}

    snapshot["nimfw_dbg_dhcp_cfm_air_log"][1] = 0x80020120
    capture.groups[2, 0x12].reused = False
    report = decode(snapshot)
    match_air(report, capture)
    assert [r["air"]["state"] for r in report["transactions"][0]["tx_completions"]] == [
        "ambiguous", "ambiguous",
    ]


def test_air_match_rejects_unverified_channel_or_ap():
    with pytest.raises(ValueError, match="did not verify"):
        match_air(decode(fixture()), Capture())
