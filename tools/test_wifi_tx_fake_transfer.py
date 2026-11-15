"""Check internal TX backup queue publication against the vendor helper."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    helper = procedure((FW / "task_handlers.nim").read_text(), "txl_int_fake_transfer")
    code = layouts("HostTxThdEntryView", "HostTxMicScratchView",
                   "HostTxInternalLinkNodeView", "TxlBackupQueueView", "TxlBufferEnvView")
    code += r'''
type
  HostTxDescView = object
    bufDesc, callback: pointer
  LinkStorage = object
    before: array[16, uint8]
    raw: array[sizeof(HostTxInternalLinkNodeView) + 32, uint8]
    after: array[16, uint8]
var
  env: TxlBufferEnvView
  frames: array[5, array[3, LinkStorage]]
  descriptors: array[5, array[3, HostTxDescView]]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxInternalLinkNodeAt(p: pointer): ptr HostTxInternalLinkNodeView =
  cast[ptr HostTxInternalLinkNodeView](p)
template node(storage: untyped): untyped =
  hostTxInternalLinkNodeAt(addr storage.raw[0])
proc txlBufferEnvView(): ptr TxlBufferEnvView = addr env
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
'''
    for name in ["txBackupQueueHeadPtr", "txBackupQueueTailPtr"]:
        declaration = re.search(rf"(?ms)^template {name}\(.*?(?=^\S|\Z)", layout)
        assert declaration is not None
        code += declaration.group(0)
    code += "var\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", helper))))
    return code + helper


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_backup_queue_appends_and_isolation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for tracked in 0 .. 2:
  env = default(TxlBufferEnvView)
  frames = default(typeof(frames))
  descriptors = default(typeof(descriptors))
  nimFwDbgNullFrameFakeSeen = 0
  nimFwDbgNullFrameCbSetPtr = 0x1234
  for byte in env.bufferEnvBaseToBackupQueuesPadding.mitems: byte = 0xA5
  for ac in 0 .. 4:
    for item in 0 .. 2:
      let storage = addr frames[ac][item]
      for byte in storage.before.mitems: byte = 0xA5
      for byte in storage.after.mitems: byte = 0x5A
      for i in sizeof(HostTxInternalLinkNodeView) ..< storage.raw.len:
        storage.raw[i] = 0xCC
      storage.node.headerThd.magic = 0x11223344
      storage.node.next = cast[pointer](0x4560)
      storage.node.txDesc = cast[pointer](0x7890)
      if tracked == 1:
        storage.node.macHeader[0] = 0x48
        storage.node.macHeader[1] = 1
      descriptors[ac][item].bufDesc = storage.node
      if tracked == 2: descriptors[ac][item].callback = cast[pointer](0x1234)
  for item in 0 .. 2:
    for ac in 0 .. 4:
      let beforeQueues = env.backupQueues
      let descriptorBefore = descriptors[ac][item]
      let storage = addr frames[ac][item]
      let before = storage.raw
      txl_int_fake_transfer(addr descriptors[ac][item], ac.uint32)
      doAssert env.backupQueues[ac].first == frames[ac][0].node
      doAssert env.backupQueues[ac].last == storage.node
      doAssert storage.node.next == nil
      doAssert storage.node.txDesc == (addr descriptors[ac][item])
      doAssert storage.node.headerThd.magic == 0xCAFEFADE'u32
      for previous in 0 ..< item:
        doAssert frames[ac][previous].node.next == frames[ac][previous + 1].node
      for other in 0 .. 4:
        if other != ac: doAssert env.backupQueues[other] == beforeQueues[other]
      doAssert descriptors[ac][item] == descriptorBefore
      var expected = before
      let expectedNode = hostTxInternalLinkNodeAt(addr expected[0])
      expectedNode.next = nil
      expectedNode.txDesc = addr descriptors[ac][item]
      expectedNode.headerThd.magic = 0xCAFEFADE'u32
      doAssert storage.raw == expected
      for byte in storage.before: doAssert byte == 0xA5
      for byte in storage.after: doAssert byte == 0x5A
      for byte in env.bufferEnvBaseToBackupQueuesPadding: doAssert byte == 0xA5
      if tracked != 0:
        doAssert nimFwDbgNullFrameFakeQidx == ac.uint32
        doAssert nimFwDbgNullFrameFakeLink == pointerAddrU32(storage.node)
        doAssert nimFwDbgNullFrameFakeHeadBefore == pointerAddrU32(beforeQueues[ac].first)
        doAssert nimFwDbgNullFrameFakeTailBefore == pointerAddrU32(beforeQueues[ac].last)
        doAssert nimFwDbgNullFrameFakeHeadAfter == pointerAddrU32(frames[ac][0].node)
        doAssert nimFwDbgNullFrameFakeTailAfter == pointerAddrU32(storage.node)
  doAssert nimFwDbgNullFrameFakeSeen == (if tracked == 0: 0'u32 else: 15'u32)
''')
