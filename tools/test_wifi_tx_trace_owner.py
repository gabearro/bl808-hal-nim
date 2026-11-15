"""Stop TX preparation before reading resources retired by trace callbacks."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_lower_preparation import CHECKS, build_program
from test_wifi_message_allocation import run_program


def source() -> str:
    code = "{.define: bl808WifiConnectTrace.}\n" + build_program().split(CHECKS, 1)[0]
    code = "var stopAt: string\nvar changeKind: int\nvar traceCalls: seq[string]\n" + code
    hook = r'''
proc trace(label: string) =
  doAssert not invalidated, "trace accessed a retired preparation"
  traceCalls.add(label)
  if label != stopAt: return
  case changeKind
  of 0: inc rxVifEpochs[1]
  of 1: inc stationEpochs[0]
  of 2: inc txResetEpoch
  of 4: frames[0].bufDesc = addr links[1]
  of 5: frames[0].hwDesc = addr hw[1]
  else:
    inc rxVifEpochs[0]
    return
  invalidated = true
'''
    insertion = code.index("proc nimFwTrace2U32(")
    code = code[:insertion] + hook + code[insertion:]
    for name in ("nimFwTrace2U32", "nimFwConnectTrace2U32"):
        code = code.replace(procedure(code, name),
                            f"proc {name}(label: string; a, b: uint32) = trace(label)\n", 1)
    code = code.replace(procedure(code, "nimFwConnectTraceBytes"),
                        "proc nimFwConnectTraceBytes(label: string; p: pointer; n, limit: uint32) = trace(label)\n", 1)
    return code + r'''
proc prepare(protocol: uint16; kind: int) =
  reset()
  invalidated = false
  traceCalls.setLen(0)
  changeKind = kind
  frames = default(typeof(frames))
  links = default(typeof(links))
  hw = default(typeof(hw))
  backup = default(typeof(backup))
  txEnv = default(TxEnv)
  frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
    hdrLen: 34, frameLen: protocol, seqPassthrough: 16,
    bufDesc: addr links[0], hwDesc: addr hw[0], policy: addr templateBytes)
  frames[0].bufferPtrs[0] = 0x20000000
  frames[0].bufferLens[0] = 16
  links[0].headerLen = 34
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_frame_builder_stops_after_trace_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for kind in 0 .. 3:
    for label in ["tx_eapol_fc ", "tx_eapol_a12 ", "tx_eapol_a3 ",
                  "tx_eapol_ahi ", "tx_eapol_snap "]:
      prepare(0x8E88, kind)
      interrupts = incoming
      stopAt = "[WIFI-CT] " & label
      let built = txuBuildFrame(addr frames[0], addr links[0].macHeader[34])
      doAssert built == (kind == 3) and interrupts == incoming
      if kind != 3: doAssert traceCalls[^1] == stopAt
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_buffer_preparation_stops_after_trace_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for kind in 0 .. 3:
    for protocol in [0x8E88'u16, 0x0008]:
      let labels = if protocol == 0x8E88:
          @["[WIFI-NIMFW] txbuf_eapol ", "[WIFI-NIMFW] txbuf_ctrl ",
            "[WIFI-CT] txbuf_eapol ", "[WIFI-CT] txbuf_ctrl ",
            "[WIFI-CT] txbuf_pol0 ", "[WIFI-CT] txbuf_pol1 "]
        else: @["[WIFI-CT] txbuf_data ", "[WIFI-CT] txbuf_data2 ", "[WIFI-RAW] tx_data "]
      for label in labels:
        prepare(protocol, kind)
        interrupts = incoming
        stopAt = label
        let prepared = txl_buffer_alloc(addr frames[0], 3, 0)
        doAssert (prepared != nil) == (kind == 3) and interrupts == incoming
        if kind != 3:
          doAssert traceCalls[^1] == stopAt
          doAssert backup[3].first == nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_thd_builder_stops_after_trace_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 5:
  for label in ["[WIFI-CT] txthd_data ", "[WIFI-CT] txthd_ptr ",
                "[WIFI-CT] txthd_buf ", "[WIFI-RAW] tx_payload "]:
    prepare(0x0008, kind)
    interrupts = false
    stopAt = label
    let built = txlBuildBufferThd(addr frames[0])
    doAssert built == (kind == 3) and not interrupts
    if kind != 3: doAssert traceCalls[^1] == stopAt
''')
