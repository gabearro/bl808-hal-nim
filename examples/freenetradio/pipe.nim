## The compressed-stream buffer between the stream client and the decoder
## (upstream's `STREAM` pipe). A plain byte ring: the stream client writes
## what fits and holds the rest back, which back-pressures the connection.

const
  UpstreamPipeLen* = 10 * 1024
    ## Upstream's size; the level at which playback starts is defined by it.
  PipeLen* {.intdefine: "radioPipeBytes".} = UpstreamPipeLen
    ## The buffer's size, and what the percentage on screen is a share of.
    ## More than upstream's rides out a reception stall of that many bytes
    ## of stream (`freenetradio.nims` asks for 64 KB: four seconds at
    ## 128 kbit/s); a server's start-up burst fills it.

static: doAssert PipeLen >= UpstreamPipeLen

type
  BytePipe* = object
    data: ptr UncheckedArray[byte]
    head, count: int

var stream*: BytePipe

proc pipeInit*() =
  ## Call once at boot, after the heap is up (the buffer lives on the heap
  ## so it stays out of the small on-chip RAM).
  if stream.data == nil:
    stream.data = cast[ptr UncheckedArray[byte]](allocShared0(PipeLen))
  stream.head = 0
  stream.count = 0

func len*(p: BytePipe): int {.inline.} = p.count
func free*(p: BytePipe): int {.inline.} = PipeLen - p.count
proc clear*(p: var BytePipe) =
  p.head = 0
  p.count = 0

proc write*(p: var BytePipe; src: openArray[byte]): int =
  ## Append what fits; returns how many bytes were taken.
  result = min(src.len, p.free)
  var tail = (p.head + p.count) mod PipeLen
  for i in 0 ..< result:
    p.data[tail] = src[i]
    tail = if tail + 1 == PipeLen: 0 else: tail + 1
  p.count += result

proc read*(p: var BytePipe; dst: var openArray[byte]): int =
  ## Move up to `dst.len` bytes out; returns how many.
  result = min(dst.len, p.count)
  for i in 0 ..< result:
    dst[i] = p.data[p.head]
    p.head = if p.head + 1 == PipeLen: 0 else: p.head + 1
  p.count -= result
