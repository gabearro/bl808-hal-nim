import std/[os,tempfiles]
import cps/zk/[r1cs,wasm_proving_key_file,wasm_digest_key]

proc bytes(path: string): seq[byte] =
  for ch in readFile(path): result.add byte(ch)
proc save(path: string, bytes: openArray[byte]) =
  var text = newString(bytes.len)
  for i,b in bytes: text[i] = char(b)
  writeFile(path,text)

proc main() =
  let dir = createTempDir("zkbuild-key-","")
  defer: removeDir(dir)
  let path = dir / "test.pk"
  # A tiny arithmetic key exercises the file codec independently from the large
  # WASM relation. It is not a key for WASM validity and is never admitted as one.
  var c = initCircuit()
  let a = c.publicInput(scalar(3))
  let b = c.publicInput(scalar(9))
  let private = c.allocate(scalar(3))
  c.assertEqual(private,a)
  c.constrain(private,private,b)
  let key = setup(c)
  let profile = ModuleValidationProfile(eventCapacity: 4,sourceCapacity: 64,sectionCapacity: 2,
    instructionCapacity: 3,branchCapacity: 1,catchCapacity: 2,digestClaim: true,
    declarations: DeclarationProfile(enabled: true,types: 1,functions: 2,parameters: 3,
      results: 4,tags: 5,localGroups: 6,localRanges: 7),
    payloads: PayloadProfile(enabled: true,imports: 1,globals: 2,tables: 3,memories: 1,
      exports: 5,elements: 6,datas: 7,elementItems: 8,customSections: 9,nameBytes: 10))
  saveModuleProvingKey(path,key,profile)
  let baseline = bytes(path)
  doAssert readModuleProvingProfile(path) == profile
  let loaded = loadModuleProvingKey(path)
  doAssert loaded.profile == profile
  doAssert loaded.key.shape.sameShape(key.shape)
  doAssert encodeModuleDigestKey(loaded.key.verificationKey,64) == encodeModuleDigestKey(key.verificationKey,64)
  doAssert loaded.key.verificationKey.decodeAndVerify(encodeProof(prove(loaded.key,c)),[scalar(3),scalar(9)])
  saveModuleProvingKey(path,loaded.key,loaded.profile)
  doAssert bytes(path) == baseline
  var withWitness = key
  withWitness.shape.values[1] = scalar(1234)
  saveModuleProvingKey(path,withWitness,profile)
  doAssert bytes(path) == baseline,"witness values must not be serialized"
  var forgeries = 0
  template bad(change: untyped) =
    block:
      var data {.inject.} = baseline
      change
      save(path,data)
      var rejected = false
      try: discard loadModuleProvingKey(path)
      except ValueError,IOError: rejected = true
      doAssert rejected,astToStr(change)
      inc forgeries
  bad: data[0] = 0
  bad: data[3] = 2
  bad: data[4] = 0 # zero event capacity
  bad: data[4] = 5 # event permutation requires a power of two
  bad: data[8] = 63 # capacity no longer matches VK
  bad: data[4+4*ModuleProfileWords] = 0
  bad: data[4+4*ModuleProfileWords+8] = 0xc0 # forbidden infinity alpha
  bad: data[ModuleProvingHeaderSize-12] = 0 # domain zero
  bad: data[ModuleProvingHeaderSize-8] = 2 # public wire count too small
  bad: data[ModuleProvingHeaderSize-4] = 3 # constraint/domain mismatch
  bad:
    for i in 0..3: data[ModuleProvingHeaderSize+i] = 255 # oversized term count
  bad:
    for i in 0..3: data[ModuleProvingHeaderSize+4+i] = 255 # wire index
  bad:
    for i in 0..31: data[ModuleProvingHeaderSize+8+i] = 255 # noncanonical scalar
  bad: data.setLen(ModuleProvingHeaderSize-1)
  bad: data.setLen(data.len-1)
  bad: data[data.len-(96+key.shape.values.len*192+(key.shape.values.len-3)*48+(key.domainSize-1)*48)] = 0
  bad: data.add 0
  # Failed writes do not replace an existing complete file.
  save(path,baseline)
  var malformed = key
  malformed.h.add generator1()
  var rejected = false
  try: saveModuleProvingKey(path,malformed,profile)
  except ValueError: rejected = true
  doAssert rejected and bytes(path) == baseline
  for entry in walkFiles(dir / ".zkbuild-key-*.tmp"):
    doAssert false,"temporary key file leaked: " & entry
  echo "proving-key file PASS: canonical round trip, loaded proof, ",forgeries," malformed encodings, atomic failure"

main()
