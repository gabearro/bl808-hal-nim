## The shared player status and the play/stop command mailbox (the top of
## upstream `src/radio.rs`).
##
## Everything here is touched from task context only (the kernel is
## cooperative and no interrupt handler reads it), so plain globals do.
## The stream task owns `phase`, `message`, `station`, `title` and
## `generation`; the audio task owns the format, levels, buffer and decode
## timing fields; anyone may call the commands below.

import ./text

type
  Phase* = enum
    phStopped = "stopped"
    phConnecting = "connecting"
    phBuffering = "buffering"
    phPlaying = "playing"
    phError = "error"
    phOffline = "offline"
      ## The network is down (or has no address yet); the stream picks up
      ## again by itself when it is back.

  Status* = object
    phase*: Phase
    message*: Text[96]     ## error or end-of-stream explanation
    url*: Text[256]
    station*: Text[128]    ## icy-name (usually "Name: description")
    title*: Text[128]      ## latest ICY StreamTitle
    sampleRate*: uint32
    bitrate*: uint32       ## kbit/s
    channels*: uint8
    bufferPct*: uint8      ## compressed data buffered, 0..100
    underruns*: uint32     ## times playback ran dry since power-on
    volume*: uint8         ## 0..100
    muted*: bool           ## the volume setting is kept
    levelL*, levelR*: uint8  ## peak of the latest frame, 0..255 (dB scale)
    generation*: uint32    ## bumped on every play/stop so audio resets
    decodeMaxUs*: uint32   ## since last read
    decodeAvgUs*: uint32

  Command* = enum
    cmdNone, cmdPlay, cmdStop

const
  UnmuteVolume* = 2'u8    ## volume after unmuting from 0
  DefaultVolume* = 10'u8

var
  player*: Status
  pending: Command

proc statusInit*() =
  ## Call once at boot (module-level initialisers do not run on the target).
  player = Status(volume: DefaultVolume)
  pending = cmdNone

proc takeCommand*(): Command =
  ## The newest command since the last call (a later one replaces an
  ## earlier one, like upstream's `Signal`), or `cmdNone`.
  result = pending
  pending = cmdNone

proc commandPending*(): bool {.inline.} = pending != cmdNone

proc play*(url: string) =
  ## Start playing `url` (valid UTF-8), replacing whatever is playing.
  ## White space around it is dropped by Rust's `str::trim` rule, as upstream.
  let span = trimmed(url)
  if span.len > 0: player.url.set url.toOpenArray(span.a, span.b)
  else: player.url.clear()
  pending = cmdPlay

proc stop*() =
  pending = cmdStop

proc restore*(url: string; volume: uint8; muted, playing: bool) =
  ## Bring back saved settings at startup: the station (played if
  ## `playing`, otherwise just selected so OK plays it), volume and mute.
  player.url.set url
  player.volume = min(volume, 100)
  player.muted = muted or volume == 0
  if playing and url.len > 0:
    pending = cmdPlay

proc setVolume*(volume: uint8) =
  ## 0..100. 0 means muted; anything else unmutes.
  player.volume = min(volume, 100)
  player.muted = player.volume == 0

proc toggleMute*(): bool =
  ## Returns whether it is now muted. Unmuting at volume 0 goes to a quiet
  ## `UnmuteVolume` rather than staying silent.
  player.muted = not player.muted
  if not player.muted and player.volume == 0:
    player.volume = UnmuteVolume
  player.muted

proc setPhase*(phase: Phase; message: string) =
  player.phase = phase
  player.message.set message
  if phase notin {phBuffering, phPlaying}:
    player.levelL = 0
    player.levelR = 0
    player.bufferPct = 0

proc beginGeneration*() =
  ## A play or stop was taken: the old stream's details no longer apply.
  player.generation += 1
  player.station.clear()
  player.title.clear()
  player.sampleRate = 0
  player.bitrate = 0
  player.channels = 0

