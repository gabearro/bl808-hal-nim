## Host-only, streaming persistence for full-module proving keys. Canonical
## scalar/point encodings; no witness or setup trapdoor is written. The kernel
## still trusts only its separately pinned 488-byte verification key.
import std/[os, tempfiles]
import prover, fft, wasm_module_prover, wasm_digest_key, wire
export wasm_module_prover

const
  ModuleProfileWords* = 23
  ModuleProvingHeaderSize* = 4+4*ModuleProfileWords+ModuleDigestKeySize+12
  MaxModuleKeyEntries* = 1 shl 24
  ModuleKeyMagic = [0x5a'u8,0x4d,0x50,1]

type
  ModuleProvingKeyFile* = object
    profile*: ModuleValidationProfile
    key*: ProvingKey
  KeyReader = object
    file: File
    position, size: uint64

proc requireFullProfile*(p: ModuleValidationProfile) =
  if not p.digestClaim or not p.declarations.enabled or not p.payloads.enabled:
    raise newException(ValueError,"persistent module keys require the full digest profile")
  p.declarations.validate()
  p.payloads.validate()
  for n in [p.eventCapacity,p.sourceCapacity,p.sectionCapacity,p.instructionCapacity,p.branchCapacity,p.catchCapacity]:
    if n < 0 or uint64(n) > uint64(high(uint32)):
      raise newException(ValueError,"invalid module profile capacity")
  if p.eventCapacity == 0 or p.sourceCapacity < 8 or p.sectionCapacity == 0 or p.instructionCapacity == 0:
    raise newException(ValueError,"persistent module keys require fixed positive row capacities")
  if (p.eventCapacity and (p.eventCapacity-1)) != 0:
    raise newException(ValueError,"module event capacity must be a power of two")

proc profileWords(p: ModuleValidationProfile): array[ModuleProfileWords,uint32] =
  p.requireFullProfile()
  let d = p.declarations
  let a = p.payloads
  let values = [p.eventCapacity,p.sourceCapacity,p.sectionCapacity,p.instructionCapacity,p.branchCapacity,p.catchCapacity,
    d.types,d.functions,d.parameters,d.results,d.tags,d.localGroups,d.localRanges,
    a.imports,a.globals,a.tables,a.memories,a.exports,a.elements,a.datas,a.elementItems,a.customSections,a.nameBytes]
  for i,n in values: result[i] = uint32(n)

proc fromWords(w: array[ModuleProfileWords,uint32]): ModuleValidationProfile =
  for value in w:
    if uint64(value) > uint64(high(int)): raise newException(ValueError,"module profile exceeds host address space")
  result = ModuleValidationProfile(eventCapacity: int(w[0]),sourceCapacity: int(w[1]),sectionCapacity: int(w[2]),
    instructionCapacity: int(w[3]),branchCapacity: int(w[4]),catchCapacity: int(w[5]),digestClaim: true,
    declarations: DeclarationProfile(enabled: true,types: int(w[6]),functions: int(w[7]),parameters: int(w[8]),
      results: int(w[9]),tags: int(w[10]),localGroups: int(w[11]),localRanges: int(w[12])),
    payloads: PayloadProfile(enabled: true,imports: int(w[13]),globals: int(w[14]),tables: int(w[15]),
      memories: int(w[16]),exports: int(w[17]),elements: int(w[18]),datas: int(w[19]),elementItems: int(w[20]),
      customSections: int(w[21]),nameBytes: int(w[22])))
  result.requireFullProfile()

proc writeBytes(f: File, bytes: openArray[byte]) =
  if bytes.len != 0 and f.writeBuffer(unsafeAddr bytes[0],bytes.len) != bytes.len:
    raise newException(IOError,"short module proving-key write")

proc putWord(f: File, value: uint32) =
  var bytes: array[4,byte]
  for i in 0..3: bytes[i] = byte((value shr (8*i)) and 255)
  f.writeBytes(bytes)

proc readBytes(r: var KeyReader, bytes: var openArray[byte]) =
  if uint64(bytes.len) > r.size-r.position:
    raise newException(ValueError,"truncated module proving key")
  if bytes.len != 0 and r.file.readBuffer(addr bytes[0],bytes.len) != bytes.len:
    raise newException(IOError,"short module proving-key read")
  r.position += uint64(bytes.len)

proc word(r: var KeyReader): uint32 =
  var bytes: array[4,byte]
  r.readBytes(bytes)
  for i in 0..3: result = result or (uint32(bytes[i]) shl (8*i))

proc count(r: var KeyReader): int =
  let n = r.word()
  if uint64(n) > uint64(MaxModuleKeyEntries):
    raise newException(ValueError,"module proving key exceeds entry limit")
  int(n)

proc point(f: File, value: Point1) =
  var encoded: array[48,byte]
  if serialize_g1_compressed(encoded,value) != cttCodecEcc_Success:
    raise newException(ValueError,"invalid proving-key G1 point")
  f.writeBytes(encoded)

proc point(f: File, value: Point2) =
  var encoded: array[96,byte]
  if serialize_g2_compressed(encoded,value) != cttCodecEcc_Success:
    raise newException(ValueError,"invalid proving-key G2 point")
  f.writeBytes(encoded)

proc point1(r: var KeyReader, allowInfinity = true): Point1 =
  var encoded: array[48,byte]
  r.readBytes(encoded)
  let status = deserialize_g1_compressed(result,encoded)
  if status != cttCodecEcc_Success and not (allowInfinity and status == cttCodecEcc_PointAtInfinity):
    raise newException(ValueError,"invalid proving-key G1 encoding")

proc point2(r: var KeyReader, allowInfinity = true): Point2 =
  var encoded: array[96,byte]
  r.readBytes(encoded)
  let status = deserialize_g2_compressed(result,encoded)
  if status != cttCodecEcc_Success and not (allowInfinity and status == cttCodecEcc_PointAtInfinity):
    raise newException(ValueError,"invalid proving-key G2 encoding")

proc dimensions(wires, constraints, domain: int) =
  if constraints <= 0 or constraints > MaxModuleKeyEntries or wires < 3 or wires > MaxModuleKeyEntries or
      domain <= 0 or domain > MaxModuleKeyEntries or domain != powerOfTwoCeil(constraints):
    raise newException(ValueError,"invalid module proving-key dimensions")

func pointBytes(wires, domain: int): uint64 =
  96'u64+uint64(wires)*192+uint64(wires-3)*48+uint64(domain-1)*48

proc linear(f: File, value: Linear, wires: int) =
  if value.len > MaxModuleKeyEntries: raise newException(ValueError,"oversized linear combination")
  f.putWord(uint32(value.len))
  for term in value:
    if term.wire < 0 or term.wire >= wires: raise newException(ValueError,"proving key references invalid wire")
    f.putWord(uint32(term.wire))
    f.writeBytes(encodeScalar(term.coefficient))

proc linear(r: var KeyReader, wires: int): Linear =
  let n = r.count()
  if uint64(n)*36 > r.size-r.position: raise newException(ValueError,"truncated linear combination")
  result.setLen(n)
  for term in result.mitems:
    let index = r.word()
    if uint64(index) >= uint64(wires): raise newException(ValueError,"proving key references invalid wire")
    term.wire = int(index)
    var encoded: array[32,byte]
    r.readBytes(encoded)
    if not decodeScalar(encoded,term.coefficient): raise newException(ValueError,"noncanonical proving-key scalar")

proc writeKey(f: File, key: ProvingKey, profile: ModuleValidationProfile) =
  let words = profile.profileWords()
  let wires = key.shape.values.len
  dimensions(wires,key.shape.constraints.len,key.domainSize)
  if key.shape.publicCount != 2 or key.a.len != wires or key.b1.len != wires or key.b2.len != wires or
      key.privateK.len != wires-3 or key.h.len != key.domainSize-1:
    raise newException(ValueError,"inconsistent module proving-key arrays")
  let vk = encodeModuleDigestKey(key.verificationKey,profile.sourceCapacity)
  f.writeBytes(ModuleKeyMagic)
  for word in words: f.putWord(word)
  f.writeBytes(vk)
  f.putWord(uint32(key.domainSize))
  f.putWord(uint32(wires))
  f.putWord(uint32(key.shape.constraints.len))
  for row in key.shape.constraints:
    f.linear(row.a,wires)
    f.linear(row.b,wires)
    f.linear(row.c,wires)
  f.point(key.beta1)
  f.point(key.delta1)
  for value in key.a: f.point(value)
  for value in key.b1: f.point(value)
  for value in key.b2: f.point(value)
  for value in key.privateK: f.point(value)
  for value in key.h: f.point(value)

proc saveModuleProvingKey*(path: string, key: ProvingKey, profile: ModuleValidationProfile) =
  ## Write to a same-directory temporary file, then publish a complete file.
  let directory = parentDir(absolutePath(path))
  let temporary = createTempFile(".zkbuild-key-",".tmp",directory)
  var closed = false
  try:
    temporary.cfile.writeKey(key,profile)
    temporary.cfile.flushFile()
    temporary.cfile.close()
    closed = true
    moveFile(temporary.path,path)
  finally:
    if not closed: temporary.cfile.close()
    if fileExists(temporary.path): removeFile(temporary.path)

proc readModuleProvingProfile*(path: string): ModuleValidationProfile =
  ## Cheap, untrusted header inspection for resource preflight. Full key load
  ## still validates the embedded VK, matrix, all points, and exact file size.
  let file = open(path,fmRead)
  defer: file.close()
  let size = file.getFileSize()
  if size < ModuleProvingHeaderSize: raise newException(ValueError,"truncated module proving-key header")
  var r = KeyReader(file: file,size: uint64(size))
  var magic: array[4,byte]
  r.readBytes(magic)
  if magic != ModuleKeyMagic: raise newException(ValueError,"invalid module proving-key magic")
  var words: array[ModuleProfileWords,uint32]
  for word in words.mitems: word = r.word()
  fromWords(words)

proc fitsModuleProvingProfile*(profile: ModuleValidationProfile, bytes: openArray[byte]): bool =
  let capacity = profile.profileWords()
  if uint64(bytes.len) > uint64(profile.sourceCapacity): return false
  let actual = inferModuleValidationProfile(bytes).profileWords()
  for i in 0..<ModuleProfileWords:
    if actual[i] > capacity[i]: return false
  true

proc loadModuleProvingKey*(path: string): ModuleProvingKeyFile =
  ## The file is never copied into one large byte string. Header and framing
  ## bounds are checked before arrays are allocated; all points are checked.
  let file = open(path,fmRead)
  defer: file.close()
  let size = file.getFileSize()
  if size < ModuleProvingHeaderSize: raise newException(ValueError,"truncated module proving-key header")
  var r = KeyReader(file: file,size: uint64(size))
  var magic: array[4,byte]
  r.readBytes(magic)
  if magic != ModuleKeyMagic: raise newException(ValueError,"invalid module proving-key magic")
  var words: array[ModuleProfileWords,uint32]
  for word in words.mitems: word = r.word()
  result.profile = fromWords(words)
  var encodedVk: array[ModuleDigestKeySize,byte]
  r.readBytes(encodedVk)
  # Parse the same canonical VK format used by the independently pinned kernel
  # verifier. This copy is off-device, and never grants trust to a kernel key.
  var vk = Reader(data: @encodedVk)
  if vk.take(4) != @[0x5a'u8,0x4d,0x44,1] or vk.getU32() != uint32(result.profile.sourceCapacity):
    raise newException(ValueError,"module proving-key verification profile mismatch")
  result.key.verificationKey.alpha = vk.point1(false)
  result.key.verificationKey.beta = vk.point2(false)
  result.key.verificationKey.gamma = vk.point2(false)
  result.key.verificationKey.delta = vk.point2(false)
  for _ in 0..2: result.key.verificationKey.inputs.add vk.point1()
  let domain = r.count()
  let wires = r.count()
  let constraints = r.count()
  dimensions(wires,constraints,domain)
  let points = pointBytes(wires,domain)
  if uint64(constraints)*12+points > r.size-r.position:
    raise newException(ValueError,"truncated module proving-key body")
  result.key.domainSize = domain
  result.key.shape.publicCount = 2
  result.key.shape.values = newSeq[Scalar](wires)
  result.key.shape.values[0] = scalar(1)
  result.key.shape.constraints.setLen(constraints)
  for row in result.key.shape.constraints.mitems:
    row.a = r.linear(wires)
    row.b = r.linear(wires)
    row.c = r.linear(wires)
  if r.size-r.position != points: raise newException(ValueError,"invalid module proving-key point payload length")
  result.key.beta1 = r.point1(false)
  result.key.delta1 = r.point1(false)
  result.key.a.setLen(wires)
  result.key.b1.setLen(wires)
  result.key.b2.setLen(wires)
  result.key.privateK.setLen(wires-3)
  result.key.h.setLen(domain-1)
  for value in result.key.a.mitems: value = r.point1()
  for value in result.key.b1.mitems: value = r.point1()
  for value in result.key.b2.mitems: value = r.point2()
  for value in result.key.privateK.mitems: value = r.point1()
  for value in result.key.h.mitems: value = r.point1()
  var extra: byte
  if r.position != r.size or file.readBuffer(addr extra,1) != 0:
    raise newException(ValueError,"trailing module proving-key data")
