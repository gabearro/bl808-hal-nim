## Host tests for the shared modules (text, status, pipe, prefs, ui, menu,
## spectrum, wallclock, about, webpage).
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_shared.nim

import std/[strutils, osproc, os]
import ../text, ../timebase, ../status, ../pipe, ../prefs, ../ui, ../menu,
       ../spectrum, ../wallclock, ../about, ../webpage, ../board, ../diag,
       ../netstate, ../netio

block: # text
  var t: Text[8]
  t.add "abc"
  t.addInt -42
  doAssert $t == "abc-42"
  t.add "xyz"                       # truncates
  doAssert $t == "abc-42xy" and t.len == 8
  var u: Text[4]
  u.add "a\xC3\xA9\xC3\xA9"         # never cuts inside a UTF-8 character
  doAssert $u == "a\xC3\xA9"
  var s: Text[16]
  s.addSanitized "A\tB\xC3\xA9\xFFC"
  doAssert $s == "A B??C"
  doAssert s == "A B??C" and "x".toText(4) == "x".toText(9)
  var z: Text[4]
  z.addInt 0
  doAssert $z == "0"

block: # statusAndCommands
  statusInit()
  doAssert player.volume == 10 and player.phase == phStopped
  doAssert $phOffline == "offline"
  play("  http://example/stream \n")
  doAssert player.url == "http://example/stream"
  # Rust's `str::trim` (Unicode White_Space), not just ASCII: NBSP, NEL,
  # IDEOGRAPHIC SPACE. White space inside the URL stays.
  play("\xC2\xA0http://x/ y\xC2\x85\xE3\x80\x80")
  doAssert player.url == "http://x/ y"
  play(" \xE2\x80\x83\t")
  doAssert player.url.isEmpty
  stop()
  play("http://b/")
  doAssert takeCommand() == cmdPlay and takeCommand() == cmdNone
  doAssert player.url == "http://b/"
  setVolume(0)
  doAssert player.muted
  doAssert toggleMute() == false and player.volume == UnmuteVolume
  setVolume(250)
  doAssert player.volume == 100 and not player.muted
  player.levelL = 9
  setPhase(phError, "x")
  doAssert player.levelL == 0 and player.message == "x"
  restore("http://c/", 0, false, true)
  doAssert player.muted and takeCommand() == cmdPlay

block: # pipe
  pipeInit()
  var src: array[3000, byte]
  for i in 0 ..< src.len: src[i] = byte(i mod 251)
  var total = 0
  for round in 0 ..< 5:
    total += stream.write(src)
  doAssert total == PipeLen and stream.free == 0
  var dst: array[4000, byte]
  doAssert stream.read(dst) == 4000 and dst[3001] == byte(1)
  doAssert stream.write(src) == 3000 and stream.len == PipeLen - 1000
  stream.clear()
  doAssert stream.len == 0

block: # prefsAndMenu
  prefsInit(); menuInit()
  doAssert sleepClock() and statusInfoName(statusInfo()) == "Both"
  stepStatusInfo(1)
  doAssert statusInfo() == InfoOff
  stepStatusInfo(1)
  doAssert statusInfo() == InfoClock
  stepEqPreset(-1)
  doAssert eqPresetName() == "Custom"
  stepEqPreset(2)
  doAssert eqPresetName() == "Bass Boost" and eqGain(0) == 6
  adjustEqGain(2, 20)
  doAssert eqPresetName() == "Custom" and eqGains() == [6'i8, 0, 10]
  setFakeTimeUs(1_000_000)
  doAssert not isOpen()
  toggle()
  var page: Page
  var row: int
  doAssert view(page, row) and page == pgMain and row == 0 and wakeRequested
  key(keyUp)
  doAssert view(page, row) and row == RowAbout
  key(keyRight)
  doAssert view(page, row) and page == pgAbout
  key(keyDown); key(keyDown); key(keyDown)
  doAssert view(page, row) and row <= max(aboutItems() - 2, 0)
  key(keyOk)
  doAssert view(page, row) and page == pgMain and row == RowAbout
  for _ in 0 ..< 4: key(keyDown)
  doAssert view(page, row) and row == RowDst
  key(keyLeft)
  doAssert dstEnabled()
  key(keyUp); key(keyRight); key(keyRight)
  doAssert offsetQh() == 2
  advanceFakeTimeMs(15_000)
  doAssert not isOpen()

block: # osd
  showOsd("Volume 11")
  doAssert osd.big and osdActive()
  advanceFakeTimeMs(1500)
  doAssert not osdActive()

block: # spectrumBars
  spectrumInit(); diagInit()
  var energy: array[Bands, float32]
  energy[0] = 1.0
  energy[39] = 1e-5
  publish(energy, 1)
  var bars: array[Bands, uint8]
  doAssert read(bars) and bars[0] == 255 and bars[1] == 0 and bars[39] in 70'u8 .. 82'u8
  doAssert abs(log2Approx(8.0) - 3.0) < 0.02
  advanceFakeTimeMs(120)
  doAssert not read(bars)

block: # clock
  doAssert daysFromCivil(1970, 1, 1) == 0 and daysFromCivil(2026, 11, 25) == 20782
  doAssert yearOfDays(20782) == 2026
  # 2026: summer time from 29 March 01:00 UTC to 25 October 01:00 UTC.
  let start = daysFromCivil(2026, 3, 29) * 86_400 + 3600
  let finish = daysFromCivil(2026, 10, 25) * 86_400 + 3600
  doAssert not euDst(start - 1) and euDst(start) and euDst(finish - 1) and not euDst(finish)
  doAssert localHourMinute(start, 4, true) == (3'u8, 0'u8)
  doAssert localHourMinute(0, -1, false) == (23'u8, 45'u8)
  wallclockInit(); prefsInit()
  var hm: (uint8, uint8)
  doAssert not hourMinute(hm)
  var pkt: array[48, byte]
  pkt[0] = 0x24; pkt[1] = 2
  pkt[40] = 0xEC; pkt[41] = 0xA5; pkt[42] = 0x12; pkt[43] = 0x34
  var unix: uint64
  doAssert ntpParse(pkt, unix) and unix == 0xECA51234'u64 - 2_208_988_800'u64
  pkt[1] = 0
  doAssert not ntpParse(pkt, unix)
  setSynced(86_400 + 3600 * 5 + 60 * 7, nowMs())
  advanceFakeTimeMs(60_000)
  doAssert hourMinute(hm) and hm == (5'u8, 8'u8)
  doAssert ntpRequest()[0] == 0x23

block: # aboutAndPage
  doAssert about.count() >= 4 and about.entry(0).name == "FreeNetRadio"
  doAssert about.entry(999).name == ""
  let gz = getTempDir() / "freenetradio_page_test.gz"
  writeFile(gz, PageGz)
  let (html, code) = execCmdEx("gzip -dc " & quoteShell(gz))
  removeFile(gz)
  doAssert code == 0 and html == readFile(currentSourcePath().parentDir.parentDir / "index.html")
  doAssert "FreeNetRadio" in html

doAssert ScreenBytes == 8192 and PresetFirstSector == 5 and IoClosed < 0
doAssert not configUp()
echo "t_shared: ok"
