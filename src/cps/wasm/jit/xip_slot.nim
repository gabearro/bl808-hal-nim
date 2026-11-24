## Read-only validation of a staged, inactive native-code XIP slot.
##
## The code is an opaque, relocation-free image built for one native ISA/ABI
## and one runtime-context ABI. This module never maps code executable and
## never writes flash. A trusted installer must write the header and body to
## an inactive pre-erased slot, verify its body by readback, then program the
## complete first flash page (including the commit word) as the final step.

import bl808/enclave/sha256

const
  XipSlotMagic* = 0x5849_5043'u32  # "CPIX" as a fixed LE word
  XipSlotVersion* = 1'u32
  XipSlotCommit* = 0x434F_4D54'u32
  XipSlotHeaderBytes* = 256
  XipSlotCommitOffset* = 96
  XipSlotHeaderDigestOffset* = 100
  XipSlotMetadataBytes* = 132
  MaxXipSlotCodeBytes* = 256 * 1024

type
  XipCacheTarget* = enum
    xctM0Rv32Ilp32f = 1
    xctD0Rv64Lp64d = 2
    xctLpRv32eIlp32e = 3

  XipSlotStatus* = enum
    xssOk
    xssEmpty
    xssUncommitted
    xssIncompatible
    xssMalformed
    xssCorrupt

  XipSlotIdentity* = object
    moduleDigest*: Sha256Digest
    target*: XipCacheTarget
    contextAbi*: uint32

  XipSlotInfo* = object
    status*: XipSlotStatus
    generation*: uint32
    codeOffset*: uint32
    codeBytes*: uint32
    entryOffset*: uint32

  XipSlotChoice* = object
    selected*: int8               # -1 means interpreter fallback
    slots*: array[2, XipSlotInfo]

proc read32(data: openArray[byte], offset: int): uint32 {.inline.} =
  for i in 0 ..< 4:
    result = result or (data[offset + i].uint32 shl (8 * i))

proc write32(data: var openArray[byte], offset: int, value: uint32) {.inline.} =
  for i in 0 ..< 4:
    data[offset + i] = byte(value shr (8 * i))

proc probeXipSlot*(data: openArray[byte],
                   identity: XipSlotIdentity): XipSlotInfo =
  ## Verify before any caller considers executing this code. A digest checks
  ## corruption, not authenticity; the installer and slot must be trusted.
  result.status = xssMalformed
  if data.len < XipSlotHeaderBytes: return
  var erased = true
  for i in 0 ..< XipSlotHeaderBytes:
    if data[i] != 0xff'u8:
      erased = false
      break
  if erased:
    result.status = xssEmpty
    return
  if read32(data, 0) != XipSlotMagic or
      read32(data, 4) != XipSlotVersion or read32(data, 28) != 0:
    return
  let headerDigest = sha256(data.toOpenArray(0, XipSlotCommitOffset - 1))
  for i in 0 ..< 32:
    if data[XipSlotHeaderDigestOffset + i] != headerDigest[i]:
      result.status = xssCorrupt
      return
  for i in XipSlotMetadataBytes ..< XipSlotHeaderBytes:
    if data[i] != 0xff'u8: return
  let codeBytes = read32(data, 20)
  let entry = read32(data, 24)
  if codeBytes == 0 or codeBytes > MaxXipSlotCodeBytes.uint32 or
      codeBytes.uint64 > uint64(data.len - XipSlotHeaderBytes) or
      (codeBytes and 3) != 0 or entry >= codeBytes or
      (entry and 3) != 0 or read32(data, 16) == 0:
    return
  if read32(data, 8) != identity.target.ord.uint32 or
      read32(data, 12) != identity.contextAbi:
    result.status = xssIncompatible
    return
  for i in 0 ..< 32:
    if data[32 + i] != identity.moduleDigest[i]:
      result.status = xssIncompatible
      return
  let digest = sha256(data.toOpenArray(
    XipSlotHeaderBytes, XipSlotHeaderBytes + codeBytes.int - 1))
  for i in 0 ..< 32:
    if data[64 + i] != digest[i]:
      result.status = xssCorrupt
      return
  let commit = read32(data, XipSlotCommitOffset)
  if commit != XipSlotCommit:
    result.status = if commit == high(uint32): xssUncommitted
      else: xssMalformed
    return
  result.status = xssOk
  result.generation = read32(data, 16)
  result.codeOffset = XipSlotHeaderBytes.uint32
  result.codeBytes = codeBytes
  result.entryOffset = entry

proc chooseXipSlot*(first, second: openArray[byte],
                    identity: XipSlotIdentity): XipSlotChoice =
  result.selected = -1
  result.slots[0] = probeXipSlot(first, identity)
  result.slots[1] = probeXipSlot(second, identity)
  if result.slots[0].status == xssOk:
    result.selected = 0
  if result.slots[1].status == xssOk and
      (result.selected < 0 or
       result.slots[1].generation > result.slots[0].generation):
    result.selected = 1

proc stageXipSlot*(identity: XipSlotIdentity, generation: uint32,
                   code: openArray[byte], entryOffset: uint32): seq[byte] =
  ## Host/installation-time image preparation only. Write and verify the body
  ## from offset 256 first. The first 256-byte page is a separate final write
  ## after its commit marker is filled in by commitStagedXipSlot.
  if identity.contextAbi == 0 or generation == 0 or code.len == 0 or
      code.len > MaxXipSlotCodeBytes or (code.len and 3) != 0 or
      entryOffset >= code.len.uint32 or (entryOffset and 3) != 0:
    return @[]
  result = newSeq[byte](XipSlotHeaderBytes + code.len)
  for i in 0 ..< result.len: result[i] = 0xff'u8
  write32(result, 0, XipSlotMagic)
  write32(result, 4, XipSlotVersion)
  write32(result, 8, identity.target.ord.uint32)
  write32(result, 12, identity.contextAbi)
  write32(result, 16, generation)
  write32(result, 20, code.len.uint32)
  write32(result, 24, entryOffset)
  write32(result, 28, 0)
  for i in 0 ..< 32: result[32 + i] = identity.moduleDigest[i]
  let digest = sha256(code)
  for i in 0 ..< 32: result[64 + i] = digest[i]
  let headerDigest = sha256(result.toOpenArray(0, XipSlotCommitOffset - 1))
  for i in 0 ..< 32:
    result[XipSlotHeaderDigestOffset + i] = headerDigest[i]
  for i, b in code: result[XipSlotHeaderBytes + i] = b

proc commitStagedXipSlot*(image: var seq[byte],
                          identity: XipSlotIdentity): bool =
  ## Models the final first-page flash program on a host image. A target
  ## installer must verify the body in flash before programming the header.
  if probeXipSlot(image, identity).status != xssUncommitted:
    return false
  write32(image, XipSlotCommitOffset, XipSlotCommit)
  probeXipSlot(image, identity).status == xssOk
