"""Exercise the disassembled ps_check_beacon TIM/traffic-detector decisions."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  STA_INFO_TAB_ENTRIES = 7
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
type
  Ie = object
    id, len: uint8
  Tim = object
    ie: Ie
    dtimCount, dtimPeriod, bitmapControl: uint8
    partialBitmap: array[8, uint8]
  Vif = object
    flags: uint32
    vifIdx, psFlags, psOptions, staIdx, uapsdBitmap, state, vifType: uint8
  Station = object
    aid: uint16
  Ps = object
    enabled, flags: uint8
  LogCall = tuple[line: cint, flags: uint32, message: string]
var
  vif: Vif
  station: Station
  ps: Ps
  tim: Tim
  packedFlags: seq[uint32]
  packedVifs: seq[uint8]
  logCalls: seq[LogCall]
  logLookups: int
  rxVifEpochs: array[MAX_VIFS, uint32]
  txResetEpoch, stationEpoch, psModeBuildSerial: uint32
  onHomeChannel: bool
  pollCalls: int
  lookupHook, logHook, packHook: proc()
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < MAX_VIFS.uint8
  addr vif
proc staDeleteEpoch(index: uint8): uint32 =
  doAssert index == vif.staIdx
  stationEpoch
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index == vif.staIdx
  addr station
proc psEnvView(): ptr Ps = addr ps
proc timIeAt(p: pointer): ptr Tim = cast[ptr Tim](p)
proc td_pack_tim_ind(index: uint8) =
  packedFlags.add(vif.flags)
  packedVifs.add(index)
  if packHook != nil: packHook()
proc chan_is_on_operational_channel(p: pointer): bool =
  doAssert p == addr vif
  onHomeChannel
proc ps_send_pspoll(p: pointer): uint8 =
  doAssert p == addr vif
  inc pollCalls
  0
proc logWrite(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 1 and tag == nil and file == cstring("ps.c")
  logCalls.add((line, vif.flags, $format))
  if logHook != nil: logHook()
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc logLookups
  if lookupHook != nil: lookupHook()
  cast[pointer](logWrite)
'''


CHECKS = r'''
for enabled in [0'u8, 1]:
  for scanning in [0'u8, 8]:
    for headerPresent in [false, true]:
      ps = Ps(enabled: enabled, flags: scanning)
      vif = Vif(flags: 0x8000000F'u32, vifIdx: 1, staIdx: 2)
      station.aid = 9
      tim = Tim(ie: Ie(len: 5), bitmapControl: 1)
      tim.partialBitmap[1] = 2
      packedFlags.setLen(0)
      packedVifs.setLen(0)
      logCalls.setLen(0)
      logLookups = 0
      ps_check_beacon(if headerPresent: cast[pointer](addr tim) else: nil, 0,
                      cast[pointer](addr vif))
      if enabled == 0 or scanning != 0 or not headerPresent:
        doAssert vif.flags == 0x8000000E'u32
        doAssert packedFlags.len == 0
        doAssert logLookups == 0 and logCalls.len == 0
      else:
        doAssert vif.flags == 0x8000004E'u32
        doAssert packedFlags == @[0x8000000E'u32]
        doAssert packedVifs == @[1'u8]
        doAssert logLookups == 1
        doAssert logCalls == @[(882.cint, 0x8000000E'u32, "BCMC: Set\r\n")]

for aid in [0'u16, 1, 7, 8, 15, 16, 23, 24, 31, 40, 255, 511]:
  for control in [0'u8, 1, 2, 3, 4, 5]:
    for length in [3'u8, 4, 5, 6]:
      for bitmapSet in [false, true]:
        for options in [0'u8, 1]:
          for psFlags in [0'u8, 1]:
            for uapsd in [0'u8, 15]:
              for initial in [0x80000005'u32, 0x8000000D'u32, 0x8000000F'u32]:
                ps = Ps(enabled: 1)
                vif = Vif(flags: initial, vifIdx: 1, psFlags: psFlags,
                          psOptions: options, staIdx: 2, uapsdBitmap: uapsd)
                station.aid = aid
                tim = Tim(ie: Ie(len: length), bitmapControl: control)
                let bytePos = aid.int shr 3
                let start = (control.int and 0xFE)
                let inside = length >= 4 and bytePos >= start and
                             bytePos <= start + length.int - 4
                if inside and bitmapSet:
                  tim.partialBitmap[bytePos - start] = 1'u8 shl (aid.int and 7)
                packedFlags.setLen(0)
                packedVifs.setLen(0)
                logCalls.setLen(0)
                logLookups = 0
                ps_check_beacon(cast[pointer](addr tim), 0, cast[pointer](addr vif))

                if length < 4:
                  doAssert vif.flags == (initial and not 1'u32)
                  doAssert packedFlags.len == 0 and logCalls.len == 0
                  doAssert logLookups == 0
                  continue

                var expected = initial and not 1'u32
                if options == 0:
                  doAssert logLookups == 1 and logCalls.len == 1
                  doAssert logCalls[0].flags == expected, "multicast log order"
                  doAssert logCalls[0].line == (if (control and 1) != 0: 882 else: 885)
                  doAssert logCalls[0].message == (if (control and 1) != 0:
                    "BCMC: Set\r\n" else: "BCMC: BCN CLR\r\n")
                  if (control and 1) != 0: expected = expected or 2'u32
                  else: expected = expected and not 2'u32
                else:
                  doAssert logLookups == 0 and logCalls.len == 0
                let buffered = inside and bitmapSet
                if not buffered:
                  if uapsd == 15: expected = expected and not 8'u32
                  else: expected = expected and not 4'u32
                let notify = buffered or psFlags != 0 or (expected and 2) != 0
                if notify:
                  doAssert packedFlags == @[expected], "TIM callback order"
                  doAssert packedVifs == @[1'u8]
                  expected = expected or 64'u32
                else:
                  doAssert packedFlags.len == 0 and packedVifs.len == 0
                doAssert vif.flags == expected,
                  "TIM flags aid=" & $aid & " control=" & $control & " len=" & $length

for length in 0'u8 .. 3'u8:
  ps = Ps(enabled: 1)
  vif = Vif(flags: 0xA5A5'u32, staIdx: 2)
  tim = Tim(ie: Ie(len: length), bitmapControl: 1)
  packedFlags.setLen(0)
  logCalls.setLen(0)
  logLookups = 0
  ps_check_beacon(addr tim, 0, addr vif)
  doAssert vif.flags == 0xA5A4'u32 and packedFlags.len == 0
  doAssert logCalls.len == 0 and logLookups == 0

ps = Ps(enabled: 1)
vif = Vif(flags: 0xA5A5'u32, staIdx: STA_INFO_TAB_ENTRIES.uint8)
tim = Tim(ie: Ie(len: 5))
ps_check_beacon(addr tim, 0, addr vif)
ps_check_beacon(addr tim, 0, nil)
doAssert vif.flags == 0xA5A4'u32
'''


LIFETIME_CHECKS = r'''
template prepare() =
  ps = Ps(enabled: 1)
  vif = Vif(flags: 0x0F'u32, vifIdx: 1, staIdx: 2)
  station.aid = 9
  tim = Tim(ie: Ie(len: 5), bitmapControl: 1)
  tim.partialBitmap[1] = 2
  rxVifEpochs = default(typeof(rxVifEpochs))
  txResetEpoch = 0
  stationEpoch = 0
  lookupHook = nil
  logHook = nil
  packHook = nil
  packedFlags.setLen(0)
  packedVifs.setLen(0)

prepare()
lookupHook = proc() =
  inc rxVifEpochs[1]
  vif = Vif(flags: 0xA5'u32, vifIdx: 1, staIdx: 2)
ps_check_beacon(addr tim, 0, addr vif)
doAssert vif.flags == 0xA5'u32 and packedVifs.len == 0

prepare()
logHook = proc() =
  inc stationEpoch
  station.aid = 24
ps_check_beacon(addr tim, 0, addr vif)
doAssert vif.flags == 0x0E'u32 and packedVifs.len == 0

prepare()
logHook = proc() = station.aid = 24
ps_check_beacon(addr tim, 0, addr vif)
doAssert vif.flags == 0x0E'u32 and packedVifs.len == 0

prepare()
logHook = proc() = ps.enabled = 0
ps_check_beacon(addr tim, 0, addr vif)
doAssert vif.flags == 0x0E'u32 and packedVifs.len == 0

prepare()
logHook = proc() =
  tim.bitmapControl = 0
  tim.partialBitmap[1] = 0
ps_check_beacon(addr tim, 0, addr vif)
doAssert packedVifs == @[1'u8] and vif.flags == 0x4E'u32

prepare()
packHook = proc() =
  inc txResetEpoch
  inc rxVifEpochs[1]
  vif = Vif(flags: 0xA5'u32, vifIdx: 1, staIdx: 2)
ps_check_beacon(addr tim, 0, addr vif)
doAssert packedVifs == @[1'u8] and vif.flags == 0xA5'u32
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ps_beacon_tim_notification(tmp_path: Path, mode: str) -> None:
    source = PLATFORM + procedure((FW / "power_save.nim").read_text(), "ps_check_beacon")
    run_program(tmp_path, mode, source + CHECKS)


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_ps_beacon_tim_owner_survives_callbacks(tmp_path: Path, mode: str) -> None:
    source = PLATFORM + procedure((FW / "power_save.nim").read_text(), "ps_check_beacon")
    run_program(tmp_path, mode, source + LIFETIME_CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_static_station_polls_for_its_buffered_legacy_traffic(
    tmp_path: Path, mode: str
) -> None:
    source = PLATFORM + procedure((FW / "power_save.nim").read_text(), "ps_check_beacon")
    run_program(tmp_path, mode, source + r'''
for bitmap in [0'u8, 1, 8, 15]:
  for flags in [0'u8, 1, 2, 4, 8]:
    for buffered in [true, false]:
      for gate in 0 .. 4:
        for superseded in [false, true]:
          ps = Ps(enabled: 1, flags: flags)
          vif = Vif(vifIdx: 1, state: 1, staIdx: 2, uapsdBitmap: bitmap)
          if gate == 1: vif.vifType = 2
          if gate == 2: vif.state = 0
          if gate == 3: ps.enabled = 0
          onHomeChannel = gate != 4
          station.aid = 9
          tim = Tim(ie: Ie(len: 5), bitmapControl: 1) # Multicast alone isn't enough.
          tim.partialBitmap[1] = if buffered: 2 else: 0
          pollCalls = 0
          packedFlags.setLen(0)
          packedVifs.setLen(0)
          logCalls.setLen(0)
          packHook = nil
          if superseded: packHook = proc() = inc psModeBuildSerial
          ps_check_beacon(addr tim, 0, addr vif)
          let shouldPoll = flags == 0 and buffered and bitmap != 15 and
            gate == 0 and not superseded
          doAssert pollCalls == shouldPoll.int
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ps_beacon_high_bitmap_offset_keeps_multicast_independent(
    tmp_path: Path, mode: str
) -> None:
    source = PLATFORM + procedure((FW / "power_save.nim").read_text(), "ps_check_beacon")
    run_program(tmp_path, mode, source + r'''
for control in [254'u8, 255]:
  for psFlag in [0'u8, 1]:
    ps = Ps(enabled: 1)
    vif = Vif(flags: 0x0F'u32, vifIdx: 1, staIdx: 2, psFlags: psFlag)
    station.aid = 2007
    tim = Tim(ie: Ie(len: 5), bitmapControl: control)
    packedFlags.setLen(0)
    packedVifs.setLen(0)
    logCalls.setLen(0)
    logLookups = 0
    ps_check_beacon(addr tim, 0, addr vif)
    let multicast = (control and 1) != 0
    let beforeNotify = if multicast: 0x0A'u32 else: 0x08'u32
    let notify = multicast or psFlag != 0
    doAssert packedFlags == (if notify: @[beforeNotify] else: @[])
    doAssert packedVifs == (if notify: @[1'u8] else: @[])
    doAssert vif.flags == (if notify: beforeNotify or 0x40'u32 else: beforeNotify)
    doAssert logLookups == 1 and logCalls.len == 1
    doAssert logCalls[0].line == (if multicast: 882 else: 885)
''')
