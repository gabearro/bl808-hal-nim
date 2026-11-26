## Host tests for the remembered settings (`settings.nim`) on a RAM flash.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_settings.nim

import std/strutils
import ../settings, ../flashdev, ../board, ../timebase, ../status, ../prefs, ../diag, ../text
import ./ramflash

const
  CfgAt = SettingsRingSector * FlashSector
  UrlAt = UrlRingSector * FlashSector
  RingSlots = 32

proc fnv(bytes: openArray[byte]): uint32 =
  result = 0x811C_9DC5'u32
  for b in bytes: result = (result xor b.uint32) * 0x0100_0193'u32

proc le32(v: uint32): array[4, byte] =
  for i in 0 .. 3: result[i] = byte((v shr (8 * i)) and 0xFF)

proc cfgRecord(seq: uint32; body: openArray[byte]): seq[byte] =
  ## A settings page built from upstream's layout: `body` is bytes 12..25.
  result = newSeq[byte](256)
  for i, c in "NRC1": result[i] = c.byte
  for i, b in body: result[12 + i] = b
  result[4 .. 7] = le32(seq)
  result[8 .. 11] = le32(fnv(result.toOpenArray(12, 255)))

proc urlRecord(seq: uint32; url: string): seq[byte] =
  result = newSeq[byte](256)
  for i, c in "NRU1": result[i] = c.byte
  result[4 .. 7] = le32(seq)
  result[8 .. 11] = le32(fnv(cast[seq[byte]](url)))
  result[12] = url.len.byte
  for i, c in url: result[16 + i] = c.byte

proc put(f: RamFlash; at: int; bytes: openArray[byte]) =
  for i, b in bytes: f.mem[at + i] = b

proc page(f: RamFlash; at: int): seq[byte] = f.mem[at ..< at + 256]

proc isBlank(f: RamFlash; at: int): bool =
  for i in 0 ..< 256:
    if f.mem[at + i] != 0xFF: return false
  true

proc boot(f: RamFlash) =
  ## Power-on: factory state, then the saved settings.
  statusInit()
  prefsInit()
  diagInit()
  settingsInit(f.dev)
  settingsRestore()

proc seconds(n: int) =
  for _ in 0 ..< n:
    advanceFakeTimeMs(1000)
    settingsTick()

setFakeTimeUs(10_000_000)

block: # blank flash: nothing restored, nothing written while nothing changes
  let f = newRamFlash()
  boot(f)
  doAssert player.volume == 10 and not player.muted and player.url.isEmpty
  doAssert not commandPending()
  # The factory state differs from "nothing saved", so it is saved once
  # it has sat for 10 s (as upstream).
  seconds(9)
  doAssert f.programs == 0
  seconds(1)
  doAssert f.programs == 1 and f.erases == 0 and stats.settingsSaves == 1
  doAssert f.page(CfgAt) == cfgRecord(1, [10'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  seconds(100)
  doAssert f.programs == 1                  # an empty URL is never saved
  for slot in 0 ..< RingSlots: doAssert f.isBlank(UrlAt + slot * 256)

block: # the settings record, byte for byte, and its restore
  let f = newRamFlash()
  boot(f)
  seconds(10)
  setVolume(37)
  discard toggleMute()
  setOffsetQh(-13)
  setDstEnabled(true)
  setStatusInfo(InfoCodec)
  setSleepClock(false)
  setVisualiser(VisCycle)
  stepEqPreset(4)                           # Rock: 5, -2, 4
  adjustEqGain(1, -3)                       # by hand: Custom 5, -5, 4
  stepEqPreset(-1)                          # back to Warm: 3, 0, -3
  status.play("http://ice1.somafm.com/lush-128-mp3")
  discard takeCommand()
  setPhase(phPlaying, "")
  seconds(10)                               # noticed at the first tick, then 10 s
  doAssert f.programs == 1
  seconds(1)
  doAssert f.programs == 3 and f.erases == 0 and stats.settingsSaves == 3
  doAssert f.page(CfgAt + 256) == cfgRecord(2,
    [37'u8, 1, 1, 0xF3, 1, InfoCodec, 1 or (VisCycle shl 1), 3, 0, 0xFD, 5, 5, 0xFB, 4])
  doAssert f.page(UrlAt) == urlRecord(1, "http://ice1.somafm.com/lush-128-mp3")
  seconds(60)
  doAssert f.programs == 3                  # unchanged: no more writes

  boot(f)
  doAssert player.volume == 37 and player.muted
  doAssert $player.url == "http://ice1.somafm.com/lush-128-mp3"
  doAssert takeCommand() == cmdPlay         # it was playing: it plays again
  doAssert offsetQh() == -13 and dstEnabled() and statusInfo() == InfoCodec
  doAssert not sleepClock() and visualiser() == VisCycle
  doAssert eqGains() == [3'i8, 0, -3] and eqSelected() == 5 and eqCustom() == [5'i8, -5, 4]
  # What was restored is what is saved: nothing to write.
  setPhase(phPlaying, "")
  seconds(30)
  doAssert f.programs == 3

  # Stopped by the user: remembered as not playing; the station stays selected.
  status.stop()
  discard takeCommand()
  setPhase(phStopped, "")
  seconds(11)
  doAssert f.programs == 4
  boot(f)
  doAssert not commandPending() and $player.url == "http://ice1.somafm.com/lush-128-mp3"
  # An error still counts as "was playing".
  setPhase(phError, "The stream ended.")
  seconds(11)
  boot(f)
  doAssert takeCommand() == cmdPlay

block: # only what has settled is saved, once per burst
  let f = newRamFlash()
  boot(f)
  seconds(10)
  doAssert f.programs == 1
  for v in 11 .. 40:                        # holding volume-up for 30 s
    setVolume(v.uint8)
    seconds(1)
  doAssert f.programs == 1
  seconds(9)
  doAssert f.programs == 1
  seconds(1)
  doAssert f.programs == 2
  # Changing and changing back within the settle time costs nothing.
  setVolume(50)
  seconds(5)
  setVolume(40)
  seconds(60)
  doAssert f.programs == 2
  # The two rings are independent.
  status.play("http://a.example/1")
  discard takeCommand()
  seconds(11)
  doAssert f.programs == 3                  # the URL only: the settings did not change
  status.play("http://a.example/2")
  discard takeCommand()
  seconds(11)
  doAssert f.programs == 4 and f.page(UrlAt + 256) == urlRecord(2, "http://a.example/2")
  # A cleared URL is not saved over a real one...
  player.url.clear()
  seconds(30)
  doAssert f.page(UrlAt + 512)[0] == 0xFF
  # ...and one too long to store is not saved either (a cut one wouldn't work).
  status.play("http://long.example/" & repeat('x', 230))
  discard takeCommand()
  doAssert player.url.len == 250
  seconds(30)
  doAssert f.page(UrlAt + 512)[0] == 0xFF
  # 240 characters is the most that fits.
  let longest = "http://long.example/" & repeat('y', 220)
  status.play(longest)
  discard takeCommand()
  seconds(11)
  doAssert f.page(UrlAt + 512) == urlRecord(3, longest)
  boot(f)
  doAssert $player.url == longest

block: # records written by upstream's code restore, with out-of-range values clamped
  let f = newRamFlash()
  f.put(CfgAt + 3 * 256, cfgRecord(7, [200'u8, 0, 1, 0x7F, 0, 9, 6, 0x7F, 0x80, 3, 99, 0x50, 0xB0, 0]))
  f.put(CfgAt + 20 * 256, cfgRecord(6, [1'u8, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  f.put(UrlAt + 31 * 256, urlRecord(0xFFFF_FFFF'u32, "http://up.example/\tx"))
  boot(f)
  doAssert player.volume == 100 and not player.muted
  doAssert $player.url == "http://up.example/ x" and takeCommand() == cmdPlay
  doAssert offsetQh() == 56 and statusInfo() == InfoBoth      # 9 is no status bar choice
  doAssert sleepClock() and visualiser() == VisMeters          # 3 is no visualiser
  doAssert eqGains() == [10'i8, -10, 3] and eqSelected() == EqCustom
  doAssert eqCustom() == [10'i8, -10, 0]
  # Volume 0 comes back muted.
  let g = newRamFlash()
  g.put(CfgAt, cfgRecord(1, [0'u8, 0, 0, 0xD0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  boot(g)
  doAssert player.volume == 0 and player.muted and offsetQh() == -48
  # Only a URL saved: selected, not played, volume left alone.
  let h = newRamFlash()
  h.put(UrlAt + 256, urlRecord(3, "http://only.example/"))
  boot(h)
  doAssert $player.url == "http://only.example/" and not commandPending() and player.volume == 10

block: # the newest valid record wins; corrupt ones are passed over
  let f = newRamFlash()
  for i in 0 ..< 5:
    f.put(CfgAt + i * 256, cfgRecord(uint32(10 + i), [uint8(20 + i), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
  boot(f)
  doAssert player.volume == 24
  f.mem[CfgAt + 4 * 256 + 12] = 99          # payload no longer matches its checksum
  boot(f)
  doAssert player.volume == 23
  f.mem[CfgAt + 3 * 256 + 1] = 'X'.byte     # magic
  boot(f)
  doAssert player.volume == 22
  f.mem[CfgAt + 2 * 256 + 9] = f.mem[CfgAt + 2 * 256 + 9] xor 0x10    # checksum
  boot(f)
  doAssert player.volume == 21
  # The next save goes to a blank slot past the damaged ones, with the next
  # sequence number, without an erase.
  setVolume(60)
  seconds(11)
  doAssert f.erases == 0 and f.page(CfgAt + 5 * 256)[4] == 12 and f.page(CfgAt + 5 * 256)[12] == 60
  boot(f)
  doAssert player.volume == 60
  # A damaged URL record: the older one.
  f.put(UrlAt, urlRecord(1, "http://one/"))
  f.put(UrlAt + 256, urlRecord(2, "http://two/"))
  f.mem[UrlAt + 256 + 20] = 'X'.byte
  boot(f)
  doAssert $player.url == "http://one/"

block: # round the ring: sixteen saves per erase, never the sector with the newest record
  let f = newRamFlash()
  boot(f)
  var expected = 10
  for n in 1 .. 100:
    expected = 10 + n mod 80
    setVolume(expected.uint8)
    seconds(11)
    doAssert f.programs == n
    # Slots 0..31 filled without an erase; then one sector at a time.
    doAssert f.erases == max(0, (n - 1) div 16 - 1)
    if n mod 7 == 0:
      boot(f)
      doAssert player.volume == expected.uint8
  doAssert f.sectorErases[SettingsRingSector] == 3 and f.sectorErases[SettingsRingSector + 1] == 2
  doAssert f.sectorErases[UrlRingSector] == 0 and stats.settingsFailures == 0
  # 100 saves: the newest is sequence 100 in slot 99 mod 32 = 3.
  doAssert f.page(CfgAt + 3 * 256)[4] == 100 and f.page(CfgAt + 3 * 256)[12] == expected.uint8
  doAssert f.isBlank(CfgAt + 4 * 256)

block: # foreign data in the store: erased when the ring gets there
  let f = newRamFlash()
  for i in 0 ..< 4 * FlashSector: f.mem[i] = byte(i * 7 + 3)
  boot(f)
  doAssert player.volume == 10
  seconds(10)
  doAssert f.erases == 1 and f.programs == 1 and f.page(CfgAt)[12] == 10
  status.play("http://a/")
  discard takeCommand()
  seconds(11)
  doAssert f.erases == 2 and f.sectorErases[UrlRingSector] == 1
  boot(f)
  doAssert $player.url == "http://a/" and not commandPending()

block: # failed writes are counted and retried after another 10 s
  let f = newRamFlash()
  boot(f)
  f.failProgram = true
  seconds(10)
  doAssert stats.settingsFailures == 1 and stats.settingsSaves == 0
  doAssert stats.settingsLastError == "Flash write failed"
  seconds(9)
  doAssert stats.settingsFailures == 1
  seconds(1)
  doAssert stats.settingsFailures == 2
  f.failProgram = false
  f.failVerify = true
  seconds(10)
  doAssert stats.settingsFailures == 3 and stats.settingsLastError == "Flash verify failed"
  f.failVerify = false
  seconds(10)
  doAssert stats.settingsSaves == 1 and stats.settingsFailures == 3
  boot(f)
  seconds(30)
  doAssert stats.settingsSaves == 0         # it is what's saved
  # A failing erase.
  let g = newRamFlash()
  for i in 0 ..< 2 * FlashSector: g.mem[i] = 0
  boot(g)
  g.failErase = true
  seconds(10)
  doAssert stats.settingsFailures == 1 and stats.settingsLastError == "Flash write failed"
  g.failErase = false
  seconds(10)
  doAssert stats.settingsSaves == 1 and g.erases == 1
  # No flash at all.
  statusInit()
  prefsInit()
  diagInit()
  settingsInit(FlashDev())
  settingsRestore()
  doAssert player.volume == 10
  seconds(10)
  doAssert stats.settingsFailures == 1 and stats.settingsLastError == "Flash busy"

block: # power cuts at every point, all the way round the ring twice
  # Each save is one program, or an erase and a program. Cut each operation
  # at several points; after the reboot the radio has the old settings or
  # the new ones, never anything else, and saving carries on.
  for bytes in [0, 2, 5, 9, 13, 100, 255, 256, 4096]:
    let f = newRamFlash()
    boot(f)
    var volume = 10
    for n in 1 .. 70:
      let old = volume
      volume = 11 + n
      for op in 0 .. 1:
        setVolume(volume.uint8)
        f.cutAt(op, bytes)
        seconds(11)
        if not f.dead:
          # No such operation in this save (it needed no erase).
          doAssert op == 1 and stats.settingsSaves == 1
          f.powerOn()
          boot(f)
          doAssert player.volume == volume.uint8
          break
        doAssert stats.settingsFailures == 1
        f.powerOn()
        boot(f)
        doAssert player.volume == old.uint8 or player.volume == volume.uint8,
          "n=" & $n & " op=" & $op & " bytes=" & $bytes & " got " & $player.volume
        if player.volume == volume.uint8: break
      # Finish the save if the cut lost it.
      setVolume(volume.uint8)
      seconds(11)
      boot(f)
      doAssert player.volume == volume.uint8, "n=" & $n & " bytes=" & $bytes
  # The same for the URL ring.
  for bytes in [0, 7, 15, 30, 256, 1000]:
    let f = newRamFlash()
    boot(f)
    var url = ""
    for n in 1 .. 40:
      let old = url
      url = "http://station.example/" & $n
      for op in 0 .. 1:
        status.play(url)
        discard takeCommand()
        f.cutAt(op, bytes)
        seconds(11)
        let cut = f.dead
        f.powerOn()
        boot(f)
        discard takeCommand()
        if not cut:
          doAssert $player.url == url
          break
        doAssert $player.url == old or $player.url == url
        if $player.url == url: break
      status.play(url)
      discard takeCommand()
      seconds(11)
      boot(f)
      discard takeCommand()
      doAssert $player.url == url

echo "t_settings: ok"
