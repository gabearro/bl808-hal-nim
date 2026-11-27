## FreeNetRadio's D0 MP3 worker. M0 installs the RAM-linked image at boot.

import bl808/[core, ipc, irq, startup]
import bl808/kernel/cps
import ./mp3dec, ./mp3_d0_job

var
  decoder: Mp3Decoder
  generation: uint32
  haveGeneration: bool

proc decodeFrame() =
  let job = mp3Job()
  let request = addr job.request
  let reply = addr job.reply
  dcacheInvalidateRange(cast[uint](request), 64)
  core.fence()
  let token = request.token
  if token == 0 or request.inputBytes notin 1'u32 .. Mp3JobWindow.uint32:
    return
  dcacheInvalidateRange(cast[uint](addr request.input[0]), request.inputBytes.uint)
  core.fence()
  if not haveGeneration or request.generation != generation:
    initDecoder(decoder)
    generation = request.generation
    haveGeneration = true
  var info: FrameInfo
  let started = readTick()
  let decoded = decoder.decode(request.input.toOpenArray(0, request.inputBytes.int - 1),
                               reply.pcm, info)
  reply.decodeUs = ticksToUs(readTick() - started).uint32
  reply.consumed = decoded.consumed.uint32
  reply.status = decoded.status.ord.uint32
  reply.samples = info.samplesProduced.uint32
  reply.channels = info.channels.uint32
  reply.rate = info.sampleRate.uint32
  reply.bitrate = info.bitrateKbps.uint32
  reply.layer = info.layer.uint32
  reply.spectrumCount = decoder.takeSpectrum(reply.spectrum)
  # Publish the payload before the header that identifies the completed job.
  let samples = info.samplesProduced * info.channels
  dcacheCleanRange(cast[uint](addr reply.spectrum[0]),
                   (sizeof(reply.spectrum) + samples * sizeof(int16)).uint)
  core.fence()
  reply.token = token
  dcacheCleanRange(cast[uint](reply), 64)
  fenceIo()
  ipcSendSignal(ipcM0, Mp3Signal)

proc requestIrq() {.cdecl.} =
  if (ipcReadSignals(ipcM0) and (1'u32 shl Mp3Signal.uint32)) != 0:
    ipcClearSignal(ipcM0, Mp3Signal)
    postFromIsr(decodeFrame)

proc main() {.exportc, cdecl.} =
  systemInit()
  # Enable the C906 instruction/data caches and branch prediction.
  {.emit: """asm volatile("csrs 0x7c1, %0" :: "r"(0x67UL) : "memory");""".}
  heapInit()
  schedulerInit()
  ipcInit()
  registerTrapHandler(IrqD0Ipc, requestIrq)
  plicEnableIrq(IrqD0Ipc)
  plicSetPriority(IrqD0Ipc, 1)
  csrWriteMie(csrReadMie() or (1'u shl 11))
  runScheduler()
