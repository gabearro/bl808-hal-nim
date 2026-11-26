## Host tests for the remote's behaviour (`remote.nim`) with the fake clock.
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_remote.nim

import ../remote, ../ir_nec, ../status, ../ui, ../menu, ../prefs, ../presets,
       ../timebase, ../text, ../flashdev, ../board
import ./ramflash

const
  K1 = 0x45'u8
  K2 = 0x46'u8
  K4 = 0x44'u8
  K5 = 0x40'u8
  K0 = 0x19'u8
  Star = 0x16'u8
  Hash = 0x0D'u8
  Up = 0x18'u8
  Down = 0x52'u8
  Left = 0x08'u8
  Right = 0x5A'u8
  Ok = 0x1C'u8

proc press(command: uint8; repeat = false) =
  onPress(Press(address: 0, command: command, repeat: repeat))

proc osdText(): string = $ui.osd.lines[0]

proc fresh() =
  ## Power-on state, built-in presets.
  setFakeTimeUs(1_000_000)
  statusInit()
  prefsInit()
  menuInit()
  remoteInit()
  presetsInit(FlashDev())
  ui.osd = Osd()
  ui.wakeRequested = false

proc played(url: string): bool =
  ## A play command for `url` is waiting.
  result = commandPending() and $player.url == url
  if result: doAssert takeCommand() == cmdPlay

block: # commandFor
  const names = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "star", "hash",
                 "up", "down", "left", "right", "ok"]
  const codes = [0x45, 0x46, 0x47, 0x44, 0x40, 0x43, 0x07, 0x15, 0x09, 0x19, 0x16, 0x0D,
                 0x18, 0x52, 0x08, 0x5A, 0x1C]
  for i, name in names:
    doAssert commandFor(name) == codes[i]
  doAssert commandFor("") == -1 and commandFor("OK") == -1 and commandFor("10") == -1

block: # unknown codes are shown so another remote can be mapped
  fresh()
  press(0x5E)
  doAssert osdText() == "IR code 0x5E" and ui.wakeRequested
  ui.osd = Osd()
  press(0x0A)
  doAssert osdText() == "IR code 0x0A"
  ui.osd = Osd()
  ui.wakeRequested = false
  press(0x5E, repeat = true)
  doAssert osdText() == "" and ui.wakeRequested    # a repeat still wakes the screen

block: # volume, with the hold delay
  fresh()
  doAssert player.volume == 10
  press(Up)
  doAssert player.volume == 11 and osdText() == "Volume 11"
  advanceFakeTimeMs(110)
  press(Up, repeat = true)
  advanceFakeTimeMs(110)
  press(Up, repeat = true)
  advanceFakeTimeMs(110)
  press(Up, repeat = true)              # 330 ms: still a tap
  doAssert player.volume == 11
  advanceFakeTimeMs(70)
  press(Up, repeat = true)              # 400 ms: held
  doAssert player.volume == 12 and osdText() == "Volume 12"
  advanceFakeTimeMs(110)
  press(Up, repeat = true)
  doAssert player.volume == 13
  # A new press restarts the delay.
  press(Down)
  doAssert player.volume == 12
  advanceFakeTimeMs(399)
  press(Down, repeat = true)
  doAssert player.volume == 12
  # Limits.
  setVolume(100)
  press(Up)
  doAssert player.volume == 100 and osdText() == "Volume 100"
  setVolume(1)
  press(Down)
  doAssert player.volume == 0 and player.muted and osdText() == "Muted"
  press(Down)
  doAssert player.volume == 0 and osdText() == "Muted"
  press(Up)
  doAssert player.volume == 1 and not player.muted and osdText() == "Volume 1"
  # Other buttons do not repeat.
  fresh()
  press(Star)
  advanceFakeTimeMs(500)
  press(Star, repeat = true)
  doAssert player.muted
  # A repeat with no press before it does nothing.
  fresh()
  press(Up, repeat = true)
  doAssert player.volume == 10 and osdText() == ""

block: # mute
  fresh()
  press(Star)
  doAssert player.muted and player.volume == 10 and osdText() == "Muted"
  press(Star)
  doAssert not player.muted and osdText() == "Volume 10"
  setVolume(0)
  press(Star)                           # unmuting at 0 goes to a quiet 2
  doAssert not player.muted and player.volume == 2 and osdText() == "Volume 2"

block: # OK: play / stop
  fresh()
  press(Ok)                             # nothing selected: preset 1
  doAssert osdText() == "1 Groove Salad"
  doAssert played("http://ice1.somafm.com/groovesalad-128-mp3")
  for phase in [phConnecting, phBuffering, phPlaying, phOffline]:
    setPhase(phase, "")
    press(Ok)
    doAssert osdText() == "Stopped" and takeCommand() == cmdStop
  for phase in [phStopped, phError]:
    setPhase(phase, "")
    press(Ok)
    doAssert osdText() == "Play"
    doAssert played("http://ice1.somafm.com/groovesalad-128-mp3")

block: # preset numbers
  fresh()
  press(K5)
  doAssert osdText() == "Preset 5-" and not commandPending()
  advanceFakeTimeMs(1199)
  remote.poll()
  doAssert not commandPending()
  advanceFakeTimeMs(1)
  remote.poll()
  doAssert osdText() == "5 Lush" and played("http://ice1.somafm.com/lush-128-mp3")
  remote.poll()
  doAssert not commandPending()
  # Two digits play at once.
  press(K1)
  doAssert osdText() == "Preset 1-"
  advanceFakeTimeMs(1000)
  press(K0)
  doAssert osdText() == "10 Underground 80s" and played("http://ice1.somafm.com/u80s-128-mp3")
  advanceFakeTimeMs(5000)
  remote.poll()
  doAssert not commandPending()
  # A lone 0 is preset 10.
  press(K0)
  doAssert osdText() == "Preset 0-"
  advanceFakeTimeMs(1200)
  remote.poll()
  doAssert osdText() == "10 Underground 80s" and played("http://ice1.somafm.com/u80s-128-mp3")
  # 0 0 is no preset; 0 5 is preset 5.
  press(K0)
  press(K0)
  doAssert osdText() == "No preset 0" and not commandPending()
  press(K0)
  press(K5)
  doAssert osdText() == "5 Lush" and played("http://ice1.somafm.com/lush-128-mp3")
  # An empty slot.
  press(K4)
  press(K2)
  doAssert osdText() == "Preset 42 is empty" and not commandPending()
  # Another button finishes a half-typed number first.
  press(K2)
  press(Up)
  doAssert played("http://ice1.somafm.com/dronezone-128-mp3")
  doAssert player.volume == 11 and osdText() == "Volume 11"
  advanceFakeTimeMs(2000)
  remote.poll()
  doAssert not commandPending()
  # Repeat codes of a digit do not type it again.
  press(K1)
  advanceFakeTimeMs(500)
  press(K1, repeat = true)
  doAssert osdText() == "Preset 1-"
  advanceFakeTimeMs(700)
  remote.poll()
  doAssert osdText() == "1 Groove Salad" and played("http://ice1.somafm.com/groovesalad-128-mp3")

block: # previous / next preset
  fresh()
  press(Right)                          # nothing selected: the first
  doAssert osdText() == "1 Groove Salad" and played("http://ice1.somafm.com/groovesalad-128-mp3")
  press(Right)
  doAssert osdText() == "2 Drone Zone" and played("http://ice1.somafm.com/dronezone-128-mp3")
  press(Left)
  press(Left)                           # wraps past the empty slots 11..99
  doAssert osdText() == "10 Underground 80s" and played("http://ice1.somafm.com/u80s-128-mp3")
  press(Right)
  doAssert osdText() == "1 Groove Salad"
  discard takeCommand()
  advanceFakeTimeMs(500)
  press(Right, repeat = true)           # does not repeat
  doAssert not commandPending()
  fresh()
  press(Left)                           # nothing selected: the last
  doAssert osdText() == "10 Underground 80s"
  # A URL that is no preset counts as nothing selected.
  status.play("http://example.com/x")
  discard takeCommand()
  press(Right)
  doAssert osdText() == "1 Groove Salad"

block: # saved presets with gaps, and none at all
  fresh()
  let flash = newRamFlash()
  presetsInit(flash.dev)
  proc job() =
    while presets.busy():
      advanceFakeTimeMs(5)
      presets.poll()
    doAssert presets.lastError() == ""
  doAssert startSave(49, "Fifty", "http://fifty.example/") == ""
  job()
  press(K5)
  press(K0)
  doAssert osdText() == "50 Fifty" and played("http://fifty.example/")
  press(Right)
  doAssert osdText() == "1 Groove Salad"
  discard takeCommand()
  press(Left)
  doAssert osdText() == "50 Fifty"
  discard takeCommand()
  press(Left)
  doAssert osdText() == "10 Underground 80s"
  discard takeCommand()
  # Clear them all.
  for i in 0 ..< 10:
    doAssert startSave(i, "", "") == ""
    job()
  doAssert startSave(49, "", "") == ""
  job()
  press(Right)
  doAssert osdText() == "No presets saved" and not commandPending()
  press(Left)
  doAssert osdText() == "No presets saved"
  statusInit()
  press(Ok)
  doAssert osdText() == "Preset 1 is empty" and not commandPending()

block: # the settings menu
  fresh()
  press(Hash)
  var page: Page
  var row: int
  doAssert menu.view(page, row) and page == pgMain and row == 0
  press(Down)
  press(Down)
  doAssert menu.view(page, row) and row == RowZone
  doAssert player.volume == 10          # up/down pick a row, not the volume
  press(Right)
  doAssert offsetQh() == 1
  advanceFakeTimeMs(200)
  press(Right, repeat = true)           # not held long enough yet
  doAssert offsetQh() == 1
  advanceFakeTimeMs(200)
  press(Right, repeat = true)
  advanceFakeTimeMs(110)
  press(Right, repeat = true)
  doAssert offsetQh() == 3
  press(Left)
  doAssert offsetQh() == 2
  # Up / down do not repeat while the menu is open.
  press(Up)
  doAssert menu.view(page, row) and row == RowEq
  advanceFakeTimeMs(500)
  press(Up, repeat = true)
  doAssert menu.view(page, row) and row == RowEq
  # Star and digits do nothing.
  press(Star)
  press(K5)
  doAssert not player.muted and osdText() == "" and menu.isOpen()
  # OK opens the Equaliser page from its row; OK there goes back; OK closes.
  press(Ok)
  doAssert menu.view(page, row) and page == pgEqualiser
  press(Ok)
  doAssert menu.view(page, row) and page == pgMain and row == RowEq
  press(Up)
  press(Ok)
  doAssert not menu.isOpen()
  # # closes it from anywhere.
  press(Hash)
  press(Down)
  press(Ok)
  doAssert menu.view(page, row) and page == pgEqualiser
  press(Hash)
  doAssert not menu.isOpen()
  # A half-typed number is finished by # before the menu opens...
  press(K2)
  press(Hash)
  doAssert menu.isOpen() and played("http://ice1.somafm.com/dronezone-128-mp3")
  # ...and the digit typed while it was open (ignored) leaves nothing behind.
  advanceFakeTimeMs(2000)
  remote.poll()
  doAssert not commandPending()
  # The menu closes itself after 15 s; buttons then work normally again.
  advanceFakeTimeMs(15_000)
  press(Up)
  doAssert player.volume == 11

block: # the web page's virtual remote goes the same way
  fresh()
  onPress(Press(address: 0, command: commandFor("ok").uint8, repeat: false))
  doAssert osdText() == "1 Groove Salad"
  playPreset(2)
  doAssert osdText() == "3 DEF CON Radio" and played("http://ice1.somafm.com/defcon-128-mp3")
  playPreset(98)
  doAssert osdText() == "Preset 99 is empty"

echo "t_remote: ok"
