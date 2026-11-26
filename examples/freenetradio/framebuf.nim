## The OLED's framebuffer: 256x64 pixels, 4 bits each, two pixels per byte
## with the left one in the high nibble (the buffer half of upstream
## `src/ssd1322.rs`). Drawing is clipped to the screen and to an optional
## clip rectangle. Pure Nim; the buffer itself belongs to the caller.

import ./ui

const
  Width* = ScreenWidth
  Height* = ScreenHeight
  BufLen* = ScreenBytes

type
  FrameBuf* = object
    buf*: ptr array[BufLen, byte]
    x0, y0, x1, y1: int32     # clip rectangle, half open

proc resetClip*(fb: var FrameBuf) {.inline.} =
  fb.x0 = 0
  fb.y0 = 0
  fb.x1 = Width
  fb.y1 = Height

proc setClip*(fb: var FrameBuf; x, y, w, h: int) =
  ## Limit drawing to this rectangle (and the screen) until `resetClip`.
  fb.x0 = clamp(x, 0, Width).int32
  fb.y0 = clamp(y, 0, Height).int32
  fb.x1 = clamp(x + max(w, 0), fb.x0.int, Width).int32
  fb.y1 = clamp(y + max(h, 0), fb.y0.int, Height).int32

proc initFrameBuf*(buf: ptr array[BufLen, byte]): FrameBuf =
  result.buf = buf
  result.resetClip()

proc visible*(fb: FrameBuf; x, y: int): bool {.inline.} =
  x >= fb.x0 and x < fb.x1 and y >= fb.y0 and y < fb.y1

proc setPixel*(fb: var FrameBuf; x, y: int; level: uint8) {.inline.} =
  ## Set one pixel to gray level 0..15. Outside the clip nothing happens.
  if fb.visible(x, y):
    let i = y * (Width div 2) + x div 2
    let b = fb.buf[i]
    fb.buf[i] =
      if (x and 1) == 0: (b and 0x0F) or ((level and 0x0F) shl 4)
      else: (b and 0xF0) or (level and 0x0F)

proc pixel*(fb: FrameBuf; x, y: int): uint8 {.inline.} =
  ## One pixel's gray level; 0 off the screen. The clip does not apply.
  if x < 0 or x >= Width or y < 0 or y >= Height: return 0
  let b = fb.buf[y * (Width div 2) + x div 2]
  if (x and 1) == 0: b shr 4 else: b and 0x0F

proc invertPixel*(fb: var FrameBuf; x, y: int) {.inline.} =
  ## 15 minus what is there (upstream's `Invert` draw target).
  fb.setPixel(x, y, 15'u8 - fb.pixel(x, y))

proc clear*(fb: var FrameBuf; level: uint8 = 0) =
  ## Fill the whole screen (the clip does not apply).
  let l = level and 0x0F
  let fill = (l shl 4) or l
  for b in fb.buf[].mitems: b = fill

proc scaleLevels*(fb: var FrameBuf; num: int) =
  ## Multiply every pixel's gray level by `num`/16 (fades what is drawn).
  let n = clamp(num, 0, 16).uint16
  if n == 16: return
  for b in fb.buf[].mitems:
    let hi = uint8((b shr 4).uint16 * n div 16)
    let lo = uint8((b and 0x0F).uint16 * n div 16)
    b = (hi shl 4) or lo
