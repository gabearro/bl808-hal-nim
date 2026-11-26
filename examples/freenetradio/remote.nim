## What the remote's buttons do (upstream `src/remote.rs`). Used for IR
## presses and the web page's virtual remote. Pure Nim; task context only.
##
##   up / down      volume +/- 1 (repeats after holding for 0.4 s); 0 mutes
##   *              mute / unmute (unmuting at volume 0 goes to 2)
##   left / right   previous / next preset station
##   OK             play / stop
##   digits         preset number 1..99: type one or two digits; a single
##                  digit plays after a 1.2 s pause (a lone 0 means 10)
##   #              settings menu (time zone, daylight saving, address);
##                  while open: up/down pick a row, left/right change it
##                  (hold to repeat), OK or # close
##
## Codes are for the common 17-key NEC remote sold with VS1838B receiver
## kits (address 0x00). Any other code is shown on the display so a
## different remote can be mapped.

import ./ir_nec, ./status, ./ui, ./menu, ./presets, ./text, ./timebase

const
  VolumeStep = 1
  HoldDelayMs = 400
    ## NEC remotes start sending repeat codes ~110 ms into a press, so a
    ## normal tap would count twice. Ignore repeats until the button has
    ## been held this long.
  DigitTimeoutMs = 1200
    ## How long to wait for a second digit.

type
  Button = enum
    btDigit, btStar, btHash, btUp, btDown, btLeft, btRight, btOk

  RemoteState = object
    digitsPending: bool     # a preset number is half-typed
    digitValue: int
    digitCount: int
    digitAtMs: uint64       # when its latest digit arrived
    pressed: bool           # a press (first, non-repeat frame) has been seen
    pressStartMs: uint64

const Keys: array[17, tuple[name: string; command: uint8; button: Button; digit: int]] = [
  ("1", 0x45'u8, btDigit, 1),
  ("2", 0x46'u8, btDigit, 2),
  ("3", 0x47'u8, btDigit, 3),
  ("4", 0x44'u8, btDigit, 4),
  ("5", 0x40'u8, btDigit, 5),
  ("6", 0x43'u8, btDigit, 6),
  ("7", 0x07'u8, btDigit, 7),
  ("8", 0x15'u8, btDigit, 8),
  ("9", 0x09'u8, btDigit, 9),
  ("0", 0x19'u8, btDigit, 0),
  ("star", 0x16'u8, btStar, 0),
  ("hash", 0x0D'u8, btHash, 0),
  ("up", 0x18'u8, btUp, 0),
  ("down", 0x52'u8, btDown, 0),
  ("left", 0x08'u8, btLeft, 0),
  ("right", 0x5A'u8, btRight, 0),
  ("ok", 0x1C'u8, btOk, 0),
]

var state: RemoteState

proc commandFor*(name: openArray[char]): int =
  ## IR command code for a virtual-remote button name ("0".."9", "star",
  ## "hash", "up", "down", "left", "right", "ok"); -1 if there is none.
  for key in Keys:
    if name == key.name:
      return key.command.int
  -1

proc playPreset*(index: int) =
  ## Play preset `index` (0-based) and show it on the display.
  let p = presets.get(index)
  var t: Text[48]
  if p.isEmpty:
    t.add "Preset "
    t.addInt index + 1
    t.add " is empty"
  else:
    status.play($p.url)
    t.addInt index + 1
    t.add ' '
    t.add p.name.chars
  showOsd(t.chars)

proc commitDigits() =
  ## Play the pending preset number, if any.
  if not state.digitsPending: return
  state.digitsPending = false
  # A lone 0 is preset 10, as on a one-digit remote.
  let n = if state.digitCount == 1 and state.digitValue == 0: 10 else: state.digitValue
  if n >= 1 and n <= Slots:
    playPreset(n - 1)
  else:
    showOsd("No preset 0")

proc digit(d: int) =
  if not state.digitsPending:
    state.digitValue = 0
    state.digitCount = 0
  state.digitsPending = true
  state.digitValue = state.digitValue * 10 + d
  inc state.digitCount
  if state.digitCount >= 2:
    commitDigits()      # two digits is the most a preset number has
  else:
    var t: Text[16]
    t.add "Preset "
    t.addInt state.digitValue
    t.add '-'
    showOsd(t.chars)
    state.digitAtMs = nowMs()     # each new digit restarts the wait

proc poll*() =
  ## Call every few ms: plays a half-typed preset number once no further
  ## digit has arrived for 1.2 s (upstream's `digit_task`).
  if state.digitsPending and elapsedMs(state.digitAtMs, nowMs()) >= DigitTimeoutMs:
    commitDigits()

proc showVolume() =
  var t: Text[16]
  t.add "Volume "
  t.addInt player.volume
  showOsd(t.chars)

proc stepPreset(forward: bool) =
  ## Step to the next/previous non-empty preset.
  let start = presets.find(player.url.chars)
  for k in 1 .. Slots:
    let i =
      if start < 0: (if forward: k - 1 else: Slots - k)
      elif forward: (start + k) mod Slots
      else: (start + Slots * 2 - k) mod Slots
    if not presets.get(i).isEmpty:
      playPreset(i)
      return
  showOsd("No presets saved")

proc onPress*(press: Press) =
  ## Act on a button press or repeat.
  ui.wake()     # any button wakes a dimmed screen
  var b = btOk
  var d = 0
  var known = false
  for key in Keys:
    if key.command == press.command:
      b = key.button
      d = key.digit
      known = true
      break
  if not known:
    if not press.repeat:
      const Hex = "0123456789ABCDEF"
      var t: Text[32]
      t.add "IR code 0x"
      t.add Hex[press.command.int shr 4]
      t.add Hex[press.command.int and 0xF]
      showOsd(t.chars)
    return
  # Only volume repeats while a button is held, and only after HoldDelayMs.
  let menuOpen = menu.isOpen()
  if press.repeat:
    let repeats = if menuOpen: b in {btLeft, btRight} else: b in {btUp, btDown}
    if not repeats or not state.pressed or
        elapsedMs(state.pressStartMs, nowMs()) < HoldDelayMs:
      return
  else:
    state.pressed = true
    state.pressStartMs = nowMs()
    # Another button while a number is half-typed: finish the number first.
    if b != btDigit:
      commitDigits()
  if menuOpen:
    case b
    of btUp: menu.key(keyUp)
    of btDown: menu.key(keyDown)
    of btLeft: menu.key(keyLeft)
    of btRight: menu.key(keyRight)
    of btOk: menu.key(keyOk)
    of btHash: menu.toggle()
    of btStar, btDigit: discard
    return
  case b
  of btUp, btDown:
    let v = player.volume.int
    let to = if b == btUp: min(v + VolumeStep, 100) else: max(v - VolumeStep, 0)
    setVolume(to.uint8)     # 0 mutes
    if to == 0: showOsd("Muted")
    else: showVolume()
  of btStar:
    if toggleMute(): showOsd("Muted")
    else: showVolume()
  of btOk:
    if player.phase in {phConnecting, phBuffering, phPlaying, phOffline}:
      status.stop()
      showOsd("Stopped")
    elif not player.url.isEmpty:
      status.play($player.url)
      showOsd("Play")
    else:
      playPreset(0)
  of btDigit: digit(d)
  of btLeft, btRight: stepPreset(b == btRight)
  of btHash: menu.toggle()

proc remoteInit*() =
  state = RemoteState()
