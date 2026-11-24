## Opt-in BL808 RF SRAM dump. The caller must own the radio and use the
## dedicated CSI linker image, which reserves the OCRAM destination.

import bl808/mmio, bl808/core
from std/volatile import volatileLoad, volatileStore

const
  CsiRfBase* = 0x20001000'u
  CsiSampleBase* = 0x22028000'u
  CsiStartIndex* = 0x2000'u32
  CsiWindowWords* = 8192'u32
  CsiProbeWords* = 256'u32
  CsiGuardWords = 64'u32
  CsiPoison = 0xA5A0055A'u32
  DumpCfg = CsiRfBase + 0x220'u
  DumpSram = CsiRfBase + 0x23C'u
  DumpCtrl = CsiRfBase + 0x240'u
  DumpAddr = CsiRfBase + 0x244'u
  DumpStatus = CsiRfBase + 0x248'u
  DumpDone = 1'u32
  DumpEnable = 2'u32
  DumpLoop = 4'u32
  DumpClear = 8'u32

type
  CsiCaptureStatus* = enum
    csiCaptured, csiInvalidRequest, csiEngineBusy, csiStaleDone,
    csiTimedOut, csiNoBufferChange, csiUnexpectedWritePattern
  CsiCaptureResult* = object
    status*: CsiCaptureStatus
    words*, memoryWords*, strideWords*, tap*: uint32
    ctrlBefore*, ctrlDone*, statusDone*: uint32
    changedWords*, strayWords*, endExtraChanged*: uint32

proc csiSampleWord*(index: uint32): uint32 {.inline.} =
  volatileLoad(cast[ptr uint32](CsiSampleBase + index.uint * 4'u))

proc classifyWrites(result: var CsiCaptureResult, expectedStride: uint32) =
  let samples = cast[ptr UncheckedArray[uint32]](CsiSampleBase)
  let strides = [1'u32, 2'u32, 4'u32, 8'u32]
  for stride in strides:
    if expectedStride != 0'u32 and stride != expectedStride:
      continue
    let span = result.words * stride
    if span + CsiGuardWords > CsiWindowWords:
      continue
    var changed, stray, extra: uint32
    for index in 0'u32 ..< CsiWindowWords:
      if volatileLoad(addr samples[index]) == CsiPoison:
        continue
      if index < span and index mod stride == 0'u32:
        inc changed
      elif index == span:
        inc extra
      else:
        inc stray
    if changed >= (result.words * 3'u32) div 4'u32 and stray <= 4'u32:
      result.strideWords = stride
      result.memoryWords = span
      result.changedWords = changed
      result.strayWords = stray
      result.endExtraChanged = extra
      return
  result.status = csiUnexpectedWritePattern

proc captureRaw(tap, words, pollLimit, expectedStride: uint32): CsiCaptureResult =
  ## The first 256-word probe can reveal 1/2/4/8-word spacing inside the
  ## reserved OCRAM window. Full captures require its observed stride.
  result.words = words
  result.tap = tap
  if tap > 3'u32 or pollLimit == 0'u32 or words < CsiProbeWords or
      (expectedStride == 0'u32 and words != CsiProbeWords) or
      (expectedStride != 0'u32 and expectedStride notin [1'u32, 2'u32, 4'u32, 8'u32]) or
      words > (CsiWindowWords - CsiGuardWords) div max(expectedStride, 1'u32):
    result.status = csiInvalidRequest
    return

  let savedCtrl = regRead(DumpCtrl)
  result.ctrlBefore = savedCtrl
  if (savedCtrl and (DumpEnable or DumpLoop)) != 0'u32:
    result.status = csiEngineBusy
    return
  let savedCfg = regRead(DumpCfg)
  let savedSram = regRead(DumpSram)
  let savedAddr = regRead(DumpAddr)
  # DONE and the upper-halfword counter are read-only; do not echo them back.
  let idleCtrl = savedCtrl and 0x0000FFF0'u32

  regWrite(DumpCtrl, idleCtrl or DumpClear)
  regWrite(DumpCtrl, idleCtrl)
  if (regRead(DumpCtrl) and DumpDone) != 0'u32:
    result.status = csiStaleDone
  else:
    let samples = cast[ptr UncheckedArray[uint32]](CsiSampleBase)
    for i in 0'u32 ..< CsiWindowWords:
      volatileStore(addr samples[i], CsiPoison)
    fenceIo()

    regWrite(DumpCfg, (savedCfg and not (3'u32 shl 9)) or
      ((tap and 3'u32) shl 9))
    # The BL808 diagnostic clears LINK_MODE and SWAP at bits 18:16.
    regWrite(DumpSram, savedSram and not (7'u32 shl 16))
    regWrite(DumpAddr, (CsiStartIndex shl 16) or (CsiStartIndex + words))
    regWrite(DumpCtrl, idleCtrl or DumpEnable)

    var remaining = pollLimit
    while remaining > 0'u32:
      let ctrl = regRead(DumpCtrl)
      if (ctrl and DumpDone) != 0'u32:
        result.ctrlDone = ctrl
        result.statusDone = regRead(DumpStatus)
        result.status = csiCaptured
        break
      dec remaining
    if remaining == 0'u32:
      result.ctrlDone = regRead(DumpCtrl)
      result.statusDone = regRead(DumpStatus)
      result.status = csiTimedOut

    regWrite(DumpCtrl, idleCtrl)
    fenceIo()
    if result.status == csiCaptured:
      classifyWrites(result, expectedStride)
      if result.status == csiCaptured and result.changedWords == 0'u32:
        result.status = csiNoBufferChange

  regWrite(DumpCtrl, idleCtrl or DumpClear)
  regWrite(DumpCtrl, idleCtrl)
  regWrite(DumpAddr, savedAddr)
  regWrite(DumpSram, savedSram)
  regWrite(DumpCfg, savedCfg)

proc csiProbeSnapshot*(tap, pollLimit: uint32): CsiCaptureResult =
  captureRaw(tap, CsiProbeWords, pollLimit, 0'u32)

proc csiCaptureSnapshot*(probe: CsiCaptureResult; words, pollLimit: uint32): CsiCaptureResult =
  if probe.status != csiCaptured or probe.words != CsiProbeWords or
      probe.strideWords == 0'u32:
    result.status = csiInvalidRequest
    return
  result = captureRaw(probe.tap, words, pollLimit, probe.strideWords)
