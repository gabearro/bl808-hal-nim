## Screen state shared between the display and the code that talks to it
## (upstream's `display::show_osd` / `wake`, the `OSD` box, the dim timer's
## activity stamp, and `main.rs`'s `SCREEN` pointer for `GET /screen`).
## The display package draws from this; nobody needs to import the display.
## Pure Nim; task context only.

import ./text, ./timebase

const
  ScreenWidth* = 256
  ScreenHeight* = 64
  ScreenBytes* = ScreenWidth * ScreenHeight div 2
    ## 4 bits per pixel, left pixel in the high nibble.
  OsdMs = 1500

type
  Osd* = object
    lines*: array[3, Text[64]]
    count*: int
    big*: bool
    untilMs*: uint64      ## 0 = nothing showing

type
  Capture* = object
    on*, snapReady*, snapDone*: bool
    frames*: uint32

var
  osd*: Osd
  lastActivityMs*: uint64
    ## When something last happened (button, message...): restarts the dim timer.
  wakeRequested*: bool
    ## Set to wake an idle display at once; the display task clears it.
  screen*: ptr array[ScreenBytes, byte]
    ## The framebuffer, once the display has allocated it (for GET /screen).

  capture*: Capture
    ## Diag screen recording (GET /screen/stream): while `capture.on`, the
    ## display raises `snapReady` after each finished frame and waits (up
    ## to 500 ms) for the web task to copy it out and raise `snapDone`;
    ## `frames` counts them (clock-driven animation runs on it meanwhile).

proc wake*() =
  ## Note user activity: wakes a dimmed screen and restarts the dim timer.
  lastActivityMs = nowMs()
  wakeRequested = true

proc showOsd*(text: openArray[char]) =
  ## Show a short message for 1.5 s (large text if it fits).
  osd.lines[0].set text
  osd.count = 1
  osd.big = text.len <= 22
  osd.untilMs = nowMs() + OsdMs
  wake()

proc osdActive*(): bool =
  ## Whether a message box is showing now (expires it when its time is up).
  if osd.untilMs != 0 and nowMs() >= osd.untilMs:
    osd.untilMs = 0
  osd.untilMs != 0
