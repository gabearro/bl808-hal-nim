## Owns the FreeNetRadio D0 worker and its one shared request slot.

import bl808/kernel/cps

const radioD0Mp3Image* {.strdefine.} = ""

# The CPS transform resolves the await even when the worker is disabled.
var decodeReady*: CpsVoidFuture

when radioD0Mp3Image.len != 0:
  import bl808/[core, glb, ipc, irq, memmap, mmio]
  import ./mp3dec, ./mp3_d0_job, ./status

  const
    WorkerImage = staticRead(radioD0Mp3Image)
    WorkerStart = 0x3004_7073'u32  # C906 _start: csrci mstatus, 8
  static:
    doAssert WorkerImage.len in 4 .. 256 * 1024
    doAssert WorkerImage[0..3] == "\x73\x70\x04\x30"

  var
    workerEnabled*: bool
    requestToken: uint32
    sentGeneration: uint32
    lastDecodeUs: uint32
    wakeTimer: TimerId

  proc completedRequest(): bool =
    let reply = addr mp3Job().reply
    dcacheInvalidateRange(cast[uint](reply), 64)
    core.fence()
    reply.token == requestToken

  proc receive() =
    let wake = decodeReady
    if wake != nil and not wake.finished and completedRequest():
      cancelTimer(wakeTimer)
      wakeTimer = 0
      complete(wake)

  proc timeout() =
    wakeTimer = 0
    let wake = decodeReady
    if wake != nil and not wake.finished:
      complete(wake)

  proc responseIrq() {.cdecl.} =
    if (ipcReadSignals(ipcD0) and (1'u32 shl Mp3Signal.uint32)) != 0:
      ipcClearSignal(ipcD0, Mp3Signal)
      postFromIsr(receive)

  proc startMp3Worker*() =
    mmPowerOn()
    holdD0Reset()
    let image = WorkerImage
    copyMem(cast[pointer](DramBase), unsafeAddr image[0], image.len)
    dcacheCleanRange(DramBase, image.len.uint)
    fenceIo()
    if regRead(DramBase) != WorkerStart: return
    let reply = addr mp3Job().reply
    reply.token = 0
    dcacheCleanRange(cast[uint](reply), 64)
    fenceIo()
    ipcInit()
    registerTrapHandler(IrqM0Ipc, responseIrq)
    irqEnable(IrqM0Ipc)
    irqSetLevel(IrqM0Ipc, 1)
    csrWriteMie(csrReadMie() or (1'u shl 11))
    releaseD0(forceLoad = false)
    workerEnabled = true

  proc submit(mp3: openArray[byte]) =
    doAssert mp3.len in 1 .. Mp3JobWindow
    inc requestToken
    if requestToken == 0: inc requestToken
    sentGeneration = status.player.generation
    let request = addr mp3Job().request
    request.token = requestToken
    request.generation = sentGeneration
    request.inputBytes = mp3.len.uint32
    copyMem(addr request.input[0], unsafeAddr mp3[0], mp3.len)
    dcacheCleanRange(cast[uint](request), (64 + mp3.len).uint)
    fenceIo()
    decodeReady = newLocalCpsVoidFuture()
    wakeTimer = addTimerMs(50, timeout)
    ipcSendSignal(ipcD0, Mp3Signal)

  proc stopWorker() =
    holdD0Reset()
    workerEnabled = false

  proc decodeOnD0*(mp3: openArray[byte]; pcm: var openArray[int16];
                   info: var FrameInfo): tuple[consumed: int, status: DecodeStatus] =
    lastDecodeUs = 0
    if decodeReady != nil:
      if not decodeReady.finished:
        return (0, dsPending)
      decodeReady = nil
      if not completedRequest():
        stopWorker()
        return (0, dsNoFrame)
      if sentGeneration == status.player.generation:
        let job = mp3Job()
        let reply = addr job.reply
        if reply.consumed > min(job.request.inputBytes, mp3.len.uint32) or
            reply.status >= dsPending.ord.uint32 or reply.samples > 1152 or
            reply.channels > 2 or reply.samples * reply.channels > pcm.len.uint32:
          stopWorker()
          return (0, dsNoFrame)
        if reply.status == dsDecoded.ord.uint32 and
            (reply.channels == 0 or reply.rate notin 8000'u32 .. 48000'u32):
          stopWorker()
          return (0, dsNoFrame)
        info = FrameInfo(samplesProduced: reply.samples.int, channels: reply.channels.int,
          sampleRate: reply.rate.int, bitrateKbps: reply.bitrate.int, layer: reply.layer.int)
        let samples = info.samplesProduced * info.channels
        dcacheInvalidateRange(cast[uint](addr reply.spectrum[0]),
                              (sizeof(reply.spectrum) + samples * sizeof(int16)).uint)
        core.fence()
        if samples > 0:
          copyMem(addr pcm[0], addr reply.pcm[0], samples * sizeof(int16))
        lastDecodeUs = reply.decodeUs
        return (reply.consumed.int, DecodeStatus(reply.status))
    submit(mp3)
    (0, dsPending)

  proc workerSpectrum*(energy: var array[SpectrumBands, float32]): uint32 =
    let reply = addr mp3Job().reply
    energy = reply.spectrum
    reply.spectrumCount

  proc workerDecodeUs*(): uint32 =
    lastDecodeUs
