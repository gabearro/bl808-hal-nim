## One MP3 request at a time. M0 owns the input until it signals D0.
## D0 owns the slot until it sends the reply.

import bl808/ipc
import ./mp3dec

const
  # Immediately above the FreeNetRadio linker profile's PSRAM heap.
  Mp3JobAddress* = 0x5022_0000'u
  Mp3JobWindow* = 4 * 1024
  Mp3Signal* = 12.IpcSignal

type
  Mp3Request* = object
    token*, generation*, inputBytes*: uint32
    reserved: array[52, byte]  # The input starts on a cache line.
    input*: array[Mp3JobWindow, byte]

  Mp3Reply* = object
    token*, consumed*, status*: uint32
    samples*, channels*, rate*, bitrate*, layer*: uint32
    decodeUs*, spectrumCount*: uint32
    reserved: array[24, byte]  # Completion metadata fits one cache line.
    spectrum*: array[SpectrumBands, float32]
    pcm*: array[MaxSamplesPerFrame, int16]

  Mp3Job* = object
    request*: Mp3Request
    reply*: Mp3Reply

static:
  doAssert sizeof(Mp3Request) == 4160 and sizeof(Mp3Reply) == 4832
  doAssert offsetof(Mp3Job, reply) mod 64 == 0

proc mp3Job*(): ptr Mp3Job {.inline.} =
  cast[ptr Mp3Job](Mp3JobAddress)
