proc os_get_random*(randomBytes: ptr uint8; length: csize_t): cint {.exportc, cdecl.} =
  if length == 0: return 0
  if randomBytes == nil or length > high(int).csize_t: return -1
  let dst = cast[ptr UncheckedArray[uint8]](randomBytes)
  let count = length.int
  var offset = 0
  while offset < count:
    var words: array[8, uint32]
    # Group ownership arbitrates cores; mask local interrupts for one sample.
    let irqState = osEnterCritical()
    let status = trngReadAll(words)
    osExitCritical(irqState)
    if status != secOk:
      zero(randomBytes, length.uint)
      return -1
    let blockLen = min(sizeof(words), count - offset)
    for i in 0 ..< blockLen:
      dst[offset + i] = ((words[i div 4] shr ((i mod 4) * 8)) and 0xff).uint8
    offset += blockLen
  0

proc os_random*(): culong {.exportc, cdecl.} =
  var word: uint32
  if os_get_random(cast[ptr uint8](addr word), sizeof(word).csize_t) == 0:
    return word.culong
  # The scalar SDK ABI cannot report errors; cryptographic callers use the buffer API.
  0
