import cps/wasm/jit/xip_slot
import bl808/enclave/sha256

proc put32(data: var seq[byte], offset: int, value: uint32) =
  for i in 0 ..< 4: data[offset + i] = byte(value shr (8 * i))

proc main() =
  let module = @[0'u8, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
  let identity = XipSlotIdentity(moduleDigest: sha256(module),
    target: xctD0Rv64Lp64d, contextAbi: 3)
  let code = @[0x13'u8, 0, 0, 0, 0x67, 0x80, 0, 0]
  var old = stageXipSlot(identity, 4, code, 0)
  doAssert old.len == XipSlotHeaderBytes + code.len
  doAssert probeXipSlot(old, identity).status == xssUncommitted
  doAssert chooseXipSlot(old, old, identity).selected == -1
  doAssert commitStagedXipSlot(old, identity)
  doAssert not commitStagedXipSlot(old, identity)
  let valid = probeXipSlot(old, identity)
  doAssert valid.status == xssOk and valid.generation == 4 and
    valid.codeOffset == XipSlotHeaderBytes.uint32 and
    valid.codeBytes == code.len.uint32 and valid.entryOffset == 0
  var next = stageXipSlot(identity, 5, code, 4)
  doAssert commitStagedXipSlot(next, identity)
  doAssert chooseXipSlot(old, next, identity).selected == 1
  next[XipSlotHeaderBytes + 4] = 0xff
  let fallback = chooseXipSlot(old, next, identity)
  doAssert fallback.selected == 0 and fallback.slots[1].status == xssCorrupt
  var wrongModule = identity
  wrongModule.moduleDigest[0] = wrongModule.moduleDigest[0] xor 1
  doAssert probeXipSlot(old, wrongModule).status == xssIncompatible
  var wrongTarget = identity
  wrongTarget.target = xctM0Rv32Ilp32f
  doAssert probeXipSlot(old, wrongTarget).status == xssIncompatible
  var partial = old
  put32(partial, XipSlotCommitOffset, 0xffff_ffff'u32)
  doAssert probeXipSlot(partial, identity).status == xssUncommitted
  doAssert chooseXipSlot(partial, next, identity).selected == -1
  var torn = old
  put32(torn, XipSlotCommitOffset, 0xffff_fffe'u32)
  doAssert probeXipSlot(torn, identity).status == xssMalformed
  var badLength = old
  put32(badLength, 20, high(uint32))
  doAssert probeXipSlot(badLength, identity).status == xssCorrupt
  var badGeneration = old
  put32(badGeneration, 16, 99)
  doAssert probeXipSlot(badGeneration, identity).status == xssCorrupt
  doAssert probeXipSlot(old[0 ..< old.len - 1], identity).status == xssMalformed
  var erased = newSeq[byte](XipSlotHeaderBytes + 8)
  for b in erased.mitems: b = 0xff
  doAssert probeXipSlot(erased, identity).status == xssEmpty
  doAssert stageXipSlot(identity, 0, code, 0).len == 0
  doAssert stageXipSlot(identity, 1, code, 3).len == 0
  echo "WASM XIP slot integrity and fallback:ok"

main()
