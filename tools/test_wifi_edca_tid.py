"""Keep unsupported HCCA identifiers out of the EDCA data/PS state machines."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_decapsulation as rx
import test_wifi_tx_sequence as tx
import test_wifi_ba_response_owner as ba
import test_wifi_ps_frame_logging as ps
import test_wifi_rx_ps_owner as ap_ps
import test_wifi_frame_preparation as frames
import test_wifi_tx_trace_owner as trace


MODES = ["checked", "release", "asan"]


@pytest.mark.parametrize("mode", MODES)
def test_rx_rejects_the_full_unsupported_tid(tmp_path: Path, mode: str) -> None:
    code = rx.dispatch_source() + rx.CHECKS.split("# Unprotected IP", 1)[0]
    run_program(tmp_path, mode, code + r'''
for fc in [0x0188'u16, 0x0288, 0x0388, 0x8188, 0x8288, 0x8388]:
  for protected in [false, true]:
    for tid in 8'u8 .. 15'u8:
      for protocol in [0x0800'u16, 0x888E]:
        let wireFc = fc or (if protected: 0x4000'u16 else: 0'u16)
        let macLen = rxu_cntrl_machdr_len_get(wireFc).int
        let headerLen = macLen + (if protected: 8 else: 0)
        setup(wireFc, headerLen, 40)
        vifs[0].vifType = if (fc and 0x300) == 0x100: 2 else: 0
        let qosOffset = if (fc and 0x300) == 0x300: 30 else: 24
        bytes[qosOffset] = tid
        snapAt(headerLen, protocol)
        let beforeStations = stations
        let beforeVifs = vifs
        let beforeBytes = bytes
        doAssert rxu_cntrl_frame_handle(addr mpdu) == 0,
          "unsupported four-bit RX TID was aliased to an EDCA queue"
        doAssert replayCalls == 0 and micCalls == 0 and eapolCalls == 0
        doAssert transferred == 0 and prepared == 0 and allocations == 0
        doAssert stations == beforeStations and vifs == beforeVifs and bytes == beforeBytes
''')


@pytest.mark.parametrize("mode", MODES)
def test_raw_capture_preserves_all_four_tid_bits(tmp_path: Path, mode: str) -> None:
    code = rx.dispatch_source()
    code = code.replace(procedure(code, "rxu_mpdu_upload_and_indicate"), r'''
var rawUploads: int
proc rxu_mpdu_upload_and_indicate(p: pointer) =
  inc rawUploads
  mpdu.curDesc = cast[pointer](1)
''', 1)
    code += rx.CHECKS.split("# Unprotected IP", 1)[0]
    run_program(tmp_path, mode, code + r'''
for fc in [0x0188'u16, 0x0288, 0x0388, 0x8188, 0x8288, 0x8388]:
  for tid in 0'u8 .. 15'u8:
    let headerLen = rxu_cntrl_machdr_len_get(fc).int
    setup(fc, headerLen, 40)
    sw.hwFlags = sw.hwFlags and not 0x02000000'u32
    let qosOffset = if (fc and 0x300) == 0x300: 30 else: 24
    bytes[qosOffset] = tid
    let before = bytes
    rawUploads = 0
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1 and rawUploads == 1
    doAssert envState.tid == tid and bytes == before
    doAssert transferred == 0 and prepared == 0 and replayCalls == 0 and eapolCalls == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_direct_tx_builder_rejects_unsupported_tid_before_writes(tmp_path: Path, mode: str) -> None:
    code = tx.program_source() + tx.CHECKS.split("proc checkTx(", 1)[0]
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  for tid in 8'u8 .. 254'u8:
    reset()
    interrupts = incoming
    var desc = HostTxDescView(staInfoIdx: 0, staIdx: tid, vifIdx: 0,
      hdrLen: 34, frameLen: 0x0008, seqAssigned: 9)
    var buffer: array[160, uint8]
    for byte in buffer.mitems: byte = 0xA5
    let before = buffer
    let beforeStations = sta_info_tab
    doAssert not txuBuildFrame(addr desc, addr buffer[128]),
      "direct builder emitted an unsupported QoS TID"
    doAssert buffer == before and sta_info_tab == beforeStations
    doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", MODES)
def test_addba_declines_unsupported_stream_identifiers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ba.source() + r'''
for incoming in [false, true]:
  for tid in 8'u16 .. 15'u16:
    for window in [0'u16, 1, 12, 64, 1023]:
      for previous in [0xABCD0010'u32, 0xABCD0090'u32]:
        setupOwner(incoming)
        logging = false
        mmio = previous
        var message: Message
        let params = (window shl 6) or (tid shl 2) or 3
        let p = request(message, 2, params)
        let before = message
        doAssert rxu_mgt_ind_handler_bam(p) == 0
        doAssert allocations == 1 and pushes == 1 and interrupts == incoming
        let body = addBaRspActionBodyAt(addr link.macHeader[24])
        doAssert body.statusCode == 37,
          "ADDBA granted a stream identifier without a TSPEC implementation"
        doAssert ((body.baParams shr 2) and 15) == tid and body.dialogToken == 0xEF
        doAssert mmio == previous and message == before
''')


@pytest.mark.parametrize("mode", MODES)
def test_sta_power_save_does_not_alias_received_tid(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps.source("psTxTidToAc", "ps_check_frame") + r'''
for fourAddress in [false, true]:
  for tid in 8'u16 .. 15'u16:
    setup()
    ps.enabled = 1
    ps.psActive = 1
    vif.uapsdBitmap = 15
    var frame: Qos4Header
    frame.header.frameControl = if fourAddress: 0x0388 else: 0x0088
    if fourAddress: frame.qosCtrl = tid or 0x10
    else: cast[ptr QosHeader](addr frame).qosCtrl = tid or 0x10
    let beforeVif = vif
    let beforePs = ps
    ps_check_frame(addr frame, 0, addr vif)
    doAssert vif == beforeVif and ps == beforePs and events.len == 0 and lookups == 0,
      "unsupported RX TID changed STA power-save state"
''')


@pytest.mark.parametrize("mode", MODES)
def test_sta_power_save_skips_qos_read_before_early_exits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ps.source("psTxTidToAc", "ps_check_frame") + r'''
for protected in [false, true]:
  for options in [0'u8, 1]:
    setup()
    ps.enabled = 1
    ps.psActive = 1
    vif.psOptions = options
    var frame: MacHeader
    frame.frameControl = 0x0088'u16 or (if protected: 0x2000'u16 else: 0'u16)
    frame.addr1[0] = 1
    ps_check_frame(addr frame, 0, addr vif)
    let clearsGroup = not protected or options != 0
    doAssert vif.flags == (if clearsGroup: 0xA5A5000C'u32 else: 0xA5A5000E'u32)
    doAssert events.len == 0 and lookups == 0

setup()
ps.enabled = 1
ps.psActive = 1
var amsdu: MacHeader
amsdu.frameControl = 0x0088
ps_check_frame(addr amsdu, 0x200, addr vif)
doAssert vif.flags == 0xA5A5000E'u32 and events.len == 0

setup()
ps.enabled = 1
var inactive: MacHeader
inactive.frameControl = 0x0088
ps_check_frame(addr inactive, 0, addr vif)
doAssert vif.flags == 0xA5A5000A'u32 and events == @["traffic"]
''')


@pytest.mark.parametrize("mode", MODES)
def test_ap_power_save_does_not_alias_received_tid(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, ap_ps.source() + r'''
for incoming in [false, true]:
  for fourAddress in [false, true]:
    for tid in 8'u16 .. 15'u16:
      setup("empty")
      interruptsEnabled = incoming
      if fourAddress:
        frame.header.frameControl = 0x1388
        frame.qosCtrl = tid
      else: cast[ptr MacQosDataFrameHeaderView](addr frame).qosCtrl = tid
      let beforeStations = stas
      let beforeVifs = vifs
      run()
      doAssert actions.len == 0 and allocationCount == 0,
        "unsupported RX TID triggered an AP service period"
      doAssert stas == beforeStations and vifs == beforeVifs and interruptsEnabled == incoming
''')


@pytest.mark.parametrize("mode", MODES)
def test_qos_null_rejects_unsupported_tid_before_allocation(tmp_path: Path, mode: str,
                                                         monkeypatch: pytest.MonkeyPatch) -> None:
    checks = frames.CHECKS.split("for irq in [false, true]:", 1)[0] + r'''
for incoming in [false, true]:
  for tid in 8'u16 .. 15'u16:
    for flags in [0'u16, 0x10, 0x80, 0xFFF0]:
      setup(incoming, 0)
      doAssert txl_frame_send_qosnull_frame(2, flags or tid, nil, 0) == 1,
        "QoS-null builder emitted an unsupported TID"
      doAssert pushes == 0 and powers == 0 and interruptsEnabled == incoming
      doAssert co_list_cnt(addr frameEnv.freeList) == 4
'''
    monkeypatch.setattr(frames, "CHECKS", checks)
    frames.test_frame_preparation(tmp_path, mode, None)


@pytest.mark.parametrize("mode", MODES)
def test_tx_tid_snapshot_survives_trace_callbacks(tmp_path: Path, mode: str) -> None:
    code = trace.source()
    code = code.replace(procedure(code, "trace"), r'''
proc trace(label: string) =
  traceCalls.add(label)
  if label == stopAt: frames[0].staIdx = changeKind.uint8
''', 1)
    run_program(tmp_path, mode, code + r'''
for incoming in [false, true]:
  for replacementTid in [7, 8, 255]:
    for label in ["tx_eapol_fc ", "tx_eapol_a12 ", "tx_eapol_a3 ",
                  "tx_eapol_ahi ", "tx_eapol_snap "]:
      prepare(0x8E88, replacementTid)
      interrupts = incoming
      stopAt = "[WIFI-CT] " & label
      doAssert not txuBuildFrame(addr frames[0], addr links[0].macHeader[34]),
        "TX builder continued after its QoS identity changed"
      doAssert traceCalls[^1] == stopAt and interrupts == incoming
''')
