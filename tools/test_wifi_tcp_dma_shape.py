"""Check the actual DMA shape observer on a prepared large TCP reply."""

from pathlib import Path

import pytest

from test_wifi_lower_preparation import build_program
from test_wifi_message_allocation import run_program


WIFI = Path(__file__).resolve().parents[1] / "src/bl808/wifi"
CHECKS = r'''
type
  HostTxLinkDescView = PreparedLink
  HostTxHwDescView = Hardware
include "PATH_TO_SHAPE"

const ipStart = 0x20000000'u32
const ipBytes = 1060'u32
const snap = [0xAA'u8, 0xAA, 3, 0, 0, 0, 8, 0]
proc prepare() =
  frames[0] = HostTxDescView(bufDesc: addr links[0], hwDesc: addr hw[0],
    hdrLen: 42, secTailLen: 8, seqPassthrough: ipBytes.uint16)
  frames[0].bufferPtrs[0] = ipStart
  frames[0].bufferLens[0] = ipBytes
  links[0] = PreparedLink(headerLen: 42)
  for i, v in snap:
    links[0].macHeader[34 + i] = v
  hw[0] = Hardware(magic: 0xCAFEBABE'u32, frameLen: 1114,
    chainedThd: addr links[0].rateTemplate[0])
  doAssert txlBuildBufferThd(addr frames[0])

for kind in -1..6:
  prepare()
  var packet = TcpPathPacket(ipv4Length: ipBytes.uint16)
  case kind
  of 0: hw[0].status = 0
  of 1: inc hw[0].frameLen
  of 2: dec links[0].headerThd.payloadEnd
  of 3: inc links[0].payloadThd[0].payloadStart
  of 4: links[0].payloadThd[0].next = addr links[0].payloadThd[1]
  of 5: links[0].macHeader[40] = 0
  of 6: dec packet.ipv4Length
  else: discard
  let word = txlTcpDmaShape(addr frames[0], addr links[0], addr hw[0], packet)
  doAssert (word and 0xFFFF) == hw[0].frameLen
  doAssert (word shr 16) == (if kind < 0: 0'u32 else: 1'u32 shl kind)
'''


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_tcp_dma_shape_on_real_chain_builder(tmp_path: Path, mode: str) -> None:
    shape = str(WIFI / "fw/tx_tcp_dma_shape.nim")
    run_program(tmp_path, mode, f'include "{WIFI / "tcp_path_trace.nim"}"\n' +
                build_program(CHECKS.replace("PATH_TO_SHAPE", shape)))
