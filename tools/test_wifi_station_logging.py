"""Check the broadcast-station initialization log writer ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const STA_MGMT_FREE_STAS = 5
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Station = object
    link: CoListHdr
    instNbr, controlPortState: uint8
    txPolicy, keyMat: pointer
  Keys = object
    defaultKeyPtr: uint32
var
  stations: array[7, Station]
  keys: array[2, Keys]
  policies: array[2, uint32]
  sta_info_env: CoList
  logEnabled: bool
  loggedHolders, loggedKeys: seq[pointer]
proc staInfoForIdx(index: uint8): ptr Station = addr stations[index]
proc staPostponedOwner(p: pointer): ptr Station = cast[ptr Station](p)
proc staMgmtResetEntry(p: ptr Station; release: bool): bool =
  doAssert not release
  p[] = Station(instNbr: 0xFF, controlPortState: 1)
  true
proc txBufferControlBcmcDescAt(index: int): pointer = addr policies[index]
proc vifChannelForIdx(index: uint8): uint8 = index
proc vifKeyPointers(index: uint8): ptr Keys = addr keys[index]
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
{.emit: "#include <stdarg.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint;
            format: cstring) {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and line == 157
  doAssert cast[uint](format) > 4096, "log format is not a string"
  doAssert file == cstring("sta_mgmt.c")
  doAssert format == cstring("------ set default key %p, key ptr %p\r\n")
  var holder, key: pointer
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           holder, " = va_arg(args, void *); ",
           key, " = va_arg(args, void *); va_end(args);"].}
  let vif = loggedHolders.len
  doAssert vif < 2 and holder == (addr keys[vif])
  doAssert key == cast[pointer](keys[vif].defaultKeyPtr.uint)
  doAssert stations[vif + 5].instNbr == vif.uint8
  doAssert stations[vif + 5].keyMat == holder
  doAssert stations[vif + 5].txPolicy == (addr policies[vif])
  doAssert stations[vif + 5].controlPortState == 0
  loggedHolders.add(holder)
  loggedKeys.add(key)
proc getLogFunc(offset: int): pointer =
  doAssert offset == 204
  if logEnabled: cast[pointer](logger) else: nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_broadcast_initialization_logging(tmp_path: Path, mode: str) -> None:
    body = procedure((FW / "sta_management.nim").read_text(), "sta_mgmt_init")
    run_program(tmp_path, mode, PLATFORM + body + r'''
for enabled in [false, true]:
  logEnabled = enabled
  loggedHolders.setLen(0)
  loggedKeys.setLen(0)
  keys[0].defaultKeyPtr = 0x12345678
  keys[1].defaultKeyPtr = 0x87654321'u32
  sta_mgmt_init()
  doAssert loggedHolders.len == (if enabled: 2 else: 0)
  var current = sta_info_env.first
  for index in 0 .. 4:
    doAssert current == (addr stations[index].link)
    doAssert stations[index].instNbr == 0xFF
    current = current.next
  doAssert current == nil and sta_info_env.last == (addr stations[4].link)
  for index in 0 .. 1:
    doAssert stations[index + 5].keyMat == (addr keys[index])
    doAssert stations[index + 5].txPolicy == (addr policies[index])
''')
