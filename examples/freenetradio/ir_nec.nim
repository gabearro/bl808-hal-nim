## NEC infrared frames from edge timings (the decoder half of upstream
## `src/ir.rs`). Pure Nim.
##
## The receiver's output idles high and goes low during each IR burst. NEC:
##
##   frame:  9 ms burst, 4.5 ms gap, 32 bits, 560 us burst
##   bit:    560 us burst, then 560 us gap (0) or 1690 us gap (1), LSB first
##   bytes:  address, ~address, command, ~command
##   repeat: 9 ms burst, 2.25 ms gap, 560 us burst, every ~110 ms while held
##
## `ir_rx.nim` timestamps the edges in an interrupt and queues the length of
## each period that just ended; `feed` takes them one at a time.

import ./timebase

type
  Press* = object
    ## A decoded button press.
    address*: uint16
    command*: uint8
    repeat*: bool     ## an NEC repeat code (button held)

  NecState = enum
    nsIdle, nsLeaderBurst, nsBitBurst, nsBitGap, nsRepeatEnd

  NecEvent* = enum
    neNone      ## nothing to report yet
    nePress     ## `press` holds a new press or a repeat
    neError     ## a malformed frame was dropped

  NecDecoder* = object
    ## The zero value is a decoder waiting for a leader burst.
    state: NecState
    bits: uint32
    count: int
    hasLast: bool
    last: Press
    lastAtMs: uint64

const RepeatWindowMs = 250
  ## A repeat code only counts this soon after a press or another repeat.

func near(us, target, tolerance: uint32): bool {.inline.} =
  (if us > target: us - target else: target - us) <= tolerance

proc finishFrame(d: var NecDecoder; press: var Press): NecEvent =
  let
    a = uint8(d.bits and 0xFF)
    aInv = uint8((d.bits shr 8) and 0xFF)
    cmd = uint8((d.bits shr 16) and 0xFF)
    cmdInv = uint8((d.bits shr 24) and 0xFF)
  if (cmd xor cmdInv) != 0xFF:
    return neError
  # Standard NEC has ~address; extended NEC uses a 16-bit address.
  let address =
    if (a xor aInv) == 0xFF: a.uint16
    else: a.uint16 or (aInv.uint16 shl 8)
  press = Press(address: address, command: cmd, repeat: false)
  d.hasLast = true
  d.last = press
  d.lastAtMs = nowMs()
  nePress

proc feed*(d: var NecDecoder; us: uint32; low: bool; press: var Press): NecEvent =
  ## Take one completed level period: the line stayed `low` (a burst) or
  ## high for `us` microseconds.
  result = neNone
  var next = nsIdle
  if d.state in {nsIdle, nsRepeatEnd} and low and near(us, 9000, 1500):
    # Waiting for a 9 ms leader burst (anything else is noise).
    next = nsLeaderBurst
  elif d.state == nsLeaderBurst and not low and near(us, 4500, 700):
    d.bits = 0
    d.count = 0
    next = nsBitBurst
  elif d.state == nsLeaderBurst and not low and near(us, 2250, 500):
    next = nsRepeatEnd
  elif d.state == nsBitBurst and low and near(us, 560, 300):
    if d.count == 32:
      # The trailing burst closes the frame.
      result = finishFrame(d, press)
    else:
      next = nsBitGap
  elif d.state == nsBitGap and not low and near(us, 560, 300):
    inc d.count
    next = nsBitBurst
  elif d.state == nsBitGap and not low and near(us, 1690, 400):
    d.bits = d.bits or (1'u32 shl d.count)
    inc d.count
    next = nsBitBurst
  elif d.state == nsRepeatEnd and low and near(us, 560, 300):
    # Repeat code: only valid shortly after a press.
    if d.hasLast and elapsedMs(d.lastAtMs, nowMs()) < RepeatWindowMs:
      d.last.repeat = true
      d.lastAtMs = nowMs()
      press = d.last
      result = nePress
  elif d.state == nsIdle:
    discard
  else:
    result = neError
  d.state = next
