## Diagnostics counters behind `GET /stats` (upstream's `diag` feature).
##
## Each package updates its own fields; `httpd.nim` prints them. The counters
## are always kept (they are cheap here); only the `/stats`, `/stats/reset`
## and `/screen/stream` routes depend on `-d:radioDiag`.

import ./timebase

const DiagEnabled* = defined(radioDiag)

type
  TaskSlice* = enum
    ## One stretch of work between two points where a task lets the others
    ## run. Every task shares the processor, so the longest of these is how
    ## long the audio task can be kept waiting.
    slAudio, slDraw, slFlushStart, slFlushEnd, slStream, slHttp, slControls, slNtp, slNet

var sliceMaxUs*: array[TaskSlice, uint32]
  ## Longest run of each slice since the last read (diag builds).
var sliceTotalUs*: array[TaskSlice, uint64]
  ## Time spent in each slice since the last read (diag builds).

template timed*(slice: TaskSlice; body: untyped) =
  ## Run `body`, and in diag builds remember the longest it has taken.
  when DiagEnabled:
    let sliceStart = nowUs()
    body
    let sliceUs = nowUs() - sliceStart
    sliceTotalUs[slice] += sliceUs
    if sliceUs > sliceMaxUs[slice].uint64:
      sliceMaxUs[slice] = uint32(min(sliceUs, high(uint32).uint64))
  else:
    body

type
  Diag* = object
    # stream client (C)
    connectStage*: uint32      ## 1 DNS, 2 TCP connect, 3 TLS handshake, 4 request sent, 5 headers, 6 streaming
    streamBytes*: uint32
    reconnects*: uint32
    outages*: uint32
    tlsHandshakeMs*: uint32
    tlsReadMaxUs*: uint32      ## reset when read
    tlsLastError*: int32       ## raw mbedTLS code of the last TLS read error
    failInfo*: array[4, uint32]  ## at the last TLS read error: tcp rx, tcp tx, tls decoded, tls pending
    # audio (B)
    audioLoops*: uint32
    minQueued*: uint32         ## DAC queue low-water, frames; reset to high(uint32) when read
    maxLoopGapUs*: uint32      ## reset when read
    decodeErrors*: array[4, uint32]  ## no frame, reservoir, corrupt, other
    underrunInfo*: array[4, uint32]  ## ms since play, kind (1 DMA overtook / 2 starved), buffered, queued
    i2sUnderruns*: uint32
    dmaErrors*: uint32
    spectrumDb*: array[5, int16]     ## raw dB of bands 0 10 20 30 39
    # display (D)
    displayFrames*: uint32
    displayStage*: uint32      ## 1 drawing, 2 flushing, 3 waiting
    flushTimeouts*: uint32
    overlayMaxUs*: uint32
    frameGapMinMs*: uint32     ## reset to high(uint32) when read
    frameGapMaxMs*: uint32     ## reset when read
    # controls (E)
    irLastCode*: uint32        ## address shl 8 or command; high(uint32) = none
    irFrames*: uint32
    irErrors*: uint32
    settingsSaves*: uint32
    settingsFailures*: uint32
    settingsLastError*: string  ## a literal; "" = none
    # network (C)
    wifiReconnects*: uint32

var stats*: Diag

proc diagInit*() =
  stats = Diag(minQueued: high(uint32), frameGapMinMs: high(uint32),
               irLastCode: high(uint32))

proc resetWaterMarks*() =
  ## `POST /stats/reset`: restart the marks, to measure one activity.
  stats.minQueued = high(uint32)
  stats.maxLoopGapUs = 0
  stats.overlayMaxUs = 0
