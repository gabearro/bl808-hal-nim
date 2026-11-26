## The user's settings that the menu edits, the display and audio read, and
## `settings.nim` remembers: clock offset and DST, status bar contents,
## visualiser, clock on the dimmed screen, and the equaliser's gains and
## preset switcher. (Upstream keeps these as statics in `clock.rs`,
## `display.rs` and `eq.rs`; they are gathered here so those modules do not
## import each other.) Pure Nim; task context only.

const
  MinOffsetQh* = -48      ## UTC-12:00, in quarter hours
  MaxOffsetQh* = 56       ## UTC+14:00

  InfoBoth* = 0'u8        ## 0 so records saved before the option existed keep the old look
  InfoClock* = 1'u8
  InfoCodec* = 2'u8
  InfoOff* = 3'u8
  InfoOrder = [InfoClock, InfoCodec, InfoBoth, InfoOff]   ## the menu's stepping order

  VisMeters* = 0'u8
  VisSpectrum* = 1'u8
  VisCycle* = 2'u8

  EqMaxDb* = 10
  EqPresets*: array[6, tuple[name: string; gains: array[3, int8]]] = [
    ("Flat", [0'i8, 0, 0]),
    ("Bass Boost", [6'i8, 0, 0]),
    ("Treble Boost", [0'i8, 0, 6]),
    ("Vocal", [-2'i8, 3, 2]),
    ("Rock", [5'i8, -2, 4]),
    ("Warm", [3'i8, 0, -3]),
  ]
  EqCustom* = EqPresets.len.uint8
    ## The switcher's seventh entry: whatever gains were last set by hand.

type
  Prefs = object
    offsetQh: int32
    dst: bool
    statusInfo: uint8
    visualiser: uint8
    sleepClockOff: bool     # inverted so the zero state is upstream's default (on)
    eqGains: array[3, int8]
    eqSelected: uint8
    eqCustom: array[3, int8]

var p: Prefs

# ---- Clock ---------------------------------------------------------------

proc offsetQh*(): int {.inline.} = p.offsetQh.int
proc setOffsetQh*(qh: int) = p.offsetQh = clamp(qh, MinOffsetQh, MaxOffsetQh).int32
proc dstEnabled*(): bool {.inline.} = p.dst
proc setDstEnabled*(on: bool) = p.dst = on

# ---- Status bar ----------------------------------------------------------

proc statusInfo*(): uint8 {.inline.} = p.statusInfo
proc setStatusInfo*(v: uint8) = p.statusInfo = (if v <= InfoOff: v else: InfoBoth)
proc stepStatusInfo*(step: int) =
  ## Next (+1) or previous (-1) choice, wrapping round.
  var i = InfoOrder.find(p.statusInfo)
  if i < 0: i = 0
  setStatusInfo InfoOrder[((i + step) mod InfoOrder.len + InfoOrder.len) mod InfoOrder.len]
proc statusInfoName*(v: uint8): string =
  case v
  of InfoClock: "Clock"
  of InfoCodec: "Codec"
  of InfoOff: "Off"
  else: "Both"

# ---- Visualiser ----------------------------------------------------------

proc visualiser*(): uint8 {.inline.} = p.visualiser
proc setVisualiser*(v: uint8) = p.visualiser = (if v <= VisCycle: v else: VisMeters)
proc stepVisualiser*(step: int) =
  setVisualiser uint8(((p.visualiser.int + step) mod 3 + 3) mod 3)
proc visualiserName*(v: uint8): string =
  case v
  of VisSpectrum: "Spectrum"
  of VisCycle: "Cycle"
  else: "Meters"

# ---- Clock on the dimmed screen -------------------------------------------

proc sleepClock*(): bool {.inline.} = not p.sleepClockOff
proc setSleepClock*(on: bool) = p.sleepClockOff = not on

# ---- Equaliser -------------------------------------------------------------

proc eqGain*(band: int): int {.inline.} = p.eqGains[band].int
proc setEqGain*(band, db: int) = p.eqGains[band] = clamp(db, -EqMaxDb, EqMaxDb).int8
proc eqGains*(): array[3, int8] {.inline.} = p.eqGains
proc eqSelected*(): uint8 {.inline.} = p.eqSelected
proc eqCustom*(): array[3, int8] {.inline.} = p.eqCustom

proc eqPresetName*(): string =
  ## The switcher's current entry: a built-in's name, or "Custom".
  if p.eqSelected < EqCustom: EqPresets[p.eqSelected].name else: "Custom"

proc stepEqPreset*(step: int) =
  ## Switch to the next (+1) or previous (-1) entry and apply its gains.
  let n = EqPresets.len + 1
  let sel = uint8(((p.eqSelected.int + step) mod n + n) mod n)
  let gains = if sel < EqCustom: EqPresets[sel].gains else: p.eqCustom
  for band in 0 .. 2: setEqGain(band, gains[band].int)
  p.eqSelected = sel

proc adjustEqGain*(band, step: int) =
  ## Change one band by hand: the gains become Custom, which is selected.
  setEqGain(band, eqGain(band) + step)
  p.eqCustom = p.eqGains
  p.eqSelected = EqCustom

proc restoreEq*(gains: array[3, int8]; selected: uint8; custom: array[3, int8]) =
  for band in 0 .. 2:
    setEqGain(band, gains[band].int)
    p.eqCustom[band] = clamp(custom[band].int, -EqMaxDb, EqMaxDb).int8
  p.eqSelected = min(selected, EqCustom)

proc prefsInit*() =
  ## Factory defaults (also the zero state). Call once at boot, before
  ## `settingsRestore`.
  p = Prefs()
