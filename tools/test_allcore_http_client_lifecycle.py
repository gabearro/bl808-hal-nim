"""Exercise the manager's HTTP client slots with fake lwIP PCBs."""

from pathlib import Path
from textwrap import dedent

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


MANAGER = ROOT / "examples/m0_allcore_wasm_cps_live_test.nim"

LWIP = r'''
type
  ErrT = int8
  Pbuf = object
  TcpErrFn = proc(arg: pointer; err: ErrT) {.cdecl.}
  TcpPcb = object
    live: bool
    closeResult: ErrT
    arg: pointer
    onError: TcpErrFn
  TcpRecvFn = proc(arg: pointer; pcb: ptr TcpPcb; p: ptr Pbuf;
                   err: ErrT): ErrT {.cdecl.}
  TcpSentFn = proc(arg: pointer; pcb: ptr TcpPcb; len: uint16): ErrT {.cdecl.}

const
  ErrOk: ErrT = 0
  ErrMem: ErrT = -1
  ErrAbrt: ErrT = -6

template requireLive(pcb: ptr TcpPcb) =
  doAssert pcb != nil and pcb.live, "lwIP operation on a dead PCB"

proc tcpArg(pcb: ptr TcpPcb; arg: pointer) =
  requireLive(pcb)
  pcb.arg = arg

proc tcpErr(pcb: ptr TcpPcb; callback: TcpErrFn) =
  requireLive(pcb)
  pcb.onError = callback

proc tcpRecv(pcb: ptr TcpPcb; callback: TcpRecvFn) = requireLive(pcb)
proc tcpSent(pcb: ptr TcpPcb; callback: TcpSentFn) = requireLive(pcb)

proc destroyPcb(pcb: ptr TcpPcb) =
  requireLive(pcb)
  let (arg, callback) = (pcb.arg, pcb.onError)
  pcb[] = default(TcpPcb) # Keep a tombstone; lwIP frees before calling back.
  if callback != nil:
    callback(arg, ErrAbrt)

proc tcpClose(pcb: ptr TcpPcb): ErrT =
  requireLive(pcb)
  doAssert pcb.onError == nil, "close left the error callback armed"
  result = pcb.closeResult
  if result == ErrOk:
    pcb[] = default(TcpPcb)

proc tcpAbort(pcb: ptr TcpPcb) =
  requireLive(pcb)
  doAssert pcb.onError == nil, "abort left the error callback armed"
  destroyPcb(pcb)

proc allcoreHttpRecv(arg: pointer; pcb: ptr TcpPcb; p: ptr Pbuf;
                     err: ErrT): ErrT {.cdecl.} =
  ErrOk
'''

CHECKS = r'''
proc acceptDirty(pcb: ptr TcpPcb): ptr HttpClientState =
  pcb.live = true
  doAssert allcoreHttpAccept(nil, pcb, ErrOk) == ErrOk
  result = cast[ptr HttpClientState](pcb.arg)
  doAssert result != nil and result[] == HttpClientState(pcb: pcb)
  result.pending = 17
  result.keepOpen = true
  result.closeRequested = true
  result.upgraded = true
  result.wsPath = "/ws"
  result.wsRxBuffer = "partial frame"

var parked: array[HttpClientPoolLen - 1, TcpPcb]
for i in 0 ..< parked.len:
  doAssert acceptDirty(addr parked[i]) == addr httpClients[i]

# Keep all other slots occupied so each accept needs the slot just retired.
for _ in 0 ..< HttpClientPoolLen + 2:
  var pcb: TcpPcb
  let ctx = acceptDirty(addr pcb)
  doAssert ctx == addr httpClients[^1]
  destroyPcb(addr pcb)
  doAssert ctx[] == default(HttpClientState), "fatal error did not release the client slot"

block:
  var pcb: TcpPcb
  let ctx = acceptDirty(addr pcb)
  doAssert closeHttpClient(ctx) == ErrOk
  doAssert not pcb.live and ctx[] == default(HttpClientState)
  doAssert httpCloseFailures == 0

block:
  var pcb = TcpPcb(closeResult: ErrMem)
  let ctx = acceptDirty(addr pcb)
  doAssert closeHttpClient(ctx) == ErrAbrt
  doAssert not pcb.live and ctx[] == default(HttpClientState)
  doAssert httpCloseFailures == 1

block:
  var pcb: TcpPcb
  let ctx = acceptDirty(addr pcb)
  doAssert abortHttpClient(ctx) == ErrAbrt
  doAssert not pcb.live and ctx[] == default(HttpClientState)

for i in 0 ..< parked.len:
  doAssert parked[i].live and httpClients[i].pcb == addr parked[i]
'''


def lifecycle_program(app: str) -> str:
    start = app.index("  type\n    HttpClientState = object")
    state = dedent(app[start:app.index("  {.emit:", start)])
    for name in ("httpClients:", "httpCloseFailures ="):
        declaration = next(line.strip() for line in app.splitlines()
                           if line.startswith(f"    {name}"))
        state += f"var {declaration}\n"

    handlers = dedent(app[app.index("  proc allocHttpClient("):app.index("  proc netifIp4(")])
    return LWIP + state + "".join(procedure(handlers, name) for name in (
        "allocHttpClient", "releaseHttpClient", "allcoreHttpErr", "closeHttpClient",
        "abortHttpClient", "allcoreHttpSent", "allcoreHttpAccept",
    )) + CHECKS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_allcore_http_client_lifecycle(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lifecycle_program(MANAGER.read_text()))
