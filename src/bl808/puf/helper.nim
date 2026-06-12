## SRAM-PUF fuzzy extractor — repetition-code secure sketch (code-offset).
##
## Pure logic so it runs identically on host (enrollment + tests) and device
## (reconstruction). A repetition code is trivially correct in both languages
## with no GF(2^m) decoder, which suits the strong stable-bit mask the
## enrollment selects.
##
## Enrollment (host) picks K output bits; for each it selects `r` strongly
## stable SRAM bit indices and records, per group, the indices plus a parity so
## majority-vote decode recovers the same bit. Helper data is public by design.
##
## Reconstruction (device) reads the raw SRAM window, majority-votes each group
## back to K bits, and feeds them to HKDF for the 256-bit root.

const
  PufKeyBits* = 256          ## output bits before KDF
  PufMaxR* = 15              ## repetition factor upper bound

type
  PufHelper* = object
    ## Public helper data, code-offset repetition construction. For each output
    ## bit, `r` SRAM cell indices and `r` offset bits where
    ## offset[j] = golden_cell[j] XOR keyBit. Each cell then independently votes
    ## `cell XOR offset == keyBit`, so a majority over r corrects per-cell noise.
    r*: int
    indices*: array[PufKeyBits * PufMaxR, uint32]  ## flattened K*r SRAM bit indices
    offset*: array[PufKeyBits * PufMaxR, uint8]    ## flattened K*r offset bits

proc bitAt(window: openArray[uint8], bitIndex: uint32): uint8 {.inline.} =
  let byteIdx = (bitIndex shr 3).int
  let bit = (bitIndex and 7).int
  if byteIdx >= window.len: return 0
  (window[byteIdx] shr bit) and 1

proc reconstructBits*(window: openArray[uint8], helper: PufHelper,
                      outBits: var array[PufKeyBits, uint8]) =
  ## Recover each key bit by majority vote over its r cells, each cell voting
  ## `cell XOR offset`.
  let r = helper.r
  for i in 0 ..< PufKeyBits:
    var ones = 0
    for j in 0 ..< r:
      let vote = bitAt(window, helper.indices[i * r + j]) xor helper.offset[i * r + j]
      if vote != 0: inc ones
    outBits[i] = (if ones * 2 > r: 1'u8 else: 0'u8)

proc enrollOffset*(golden: openArray[uint8], helper: var PufHelper,
                   keyBits: array[PufKeyBits, uint8]) =
  ## Enrollment: given chosen cell indices and target key bits, record the
  ## offsets. (Host-side; the device only ever reconstructs.)
  for i in 0 ..< PufKeyBits:
    for j in 0 ..< helper.r:
      helper.offset[i * helper.r + j] =
        bitAt(golden, helper.indices[i * helper.r + j]) xor keyBits[i]

proc packBits*(bits: array[PufKeyBits, uint8], outBytes: var array[32, uint8]) =
  ## Pack 256 reconstructed bits into 32 bytes (LSB-first per byte).
  for b in 0 ..< 32:
    var v = 0'u8
    for k in 0 ..< 8:
      v = v or (bits[b * 8 + k] shl k)
    outBytes[b] = v
