## Real WASM setup -> streaming save -> fresh load -> three module proofs.
import std/[os,times,json,jsonutils]
import cps/zk/[wasm_proving_key_file,wasm_digest_key,wasm_digest_claim,wasm_module_verifier]

proc save(path: string, bytes: openArray[byte]) =
  var text = newString(bytes.len)
  for i,b in bytes: text[i] = char(b)
  writeFile(path,text)

proc section(data: var seq[byte], id: byte, bytes: seq[byte]) =
  doAssert bytes.len < 128
  data.add @[id,byte(bytes.len)] & bytes

proc sample(imported: bool): seq[byte] =
  result = @[0'u8,97,115,109,1,0,0,0]
  result.section(0,@[0'u8,255])
  result.section(1,@[1'u8,96,0,1,127])
  if imported: result.section(2,@[1'u8,1,104,1,103,3,127,0])
  result.section(3,@[1'u8,0])
  result.section(7,@[1'u8,3,114,117,110,0,0])
  result.section(10,@[1'u8,4,0,65,42,11])

proc main() =
  let directory = if paramCount() == 0: "build/zkbuild/persistent-module" else: paramStr(1)
  createDir(directory)
  let profile = ModuleValidationProfile(eventCapacity: 16,sourceCapacity: 64,sectionCapacity: 6,
    instructionCapacity: 3,digestClaim: true,
    declarations: DeclarationProfile(enabled: true,types: 1,functions: 1,results: 1),
    payloads: PayloadProfile(enabled: true,imports: 1,globals: 1,exports: 1,customSections: 1,nameBytes: 8))
  let startup = @[0'u8,97,115,109,1,0,0,0,1,4,1,96,0,0,
    2,7,1,1,104,1,103,0,0,8,1,0]
  let data = @[@[0'u8,97,115,109,1,0,0,0],sample(false),sample(true),startup]
  for bytes in data:
    doAssert profile.fitsModuleProvingProfile(bytes),"test module exceeds chosen profile"
  for i,bytes in data: save(directory / ("module-" & $i & ".wasm"),bytes)
  writeFile(directory / "profile.json",pretty(toJson(profile)))
  var started = cpuTime()
  var key = setupModuleValidation(data[0],profile)
  let vk = encodeModuleDigestKey(key.verificationKey,profile.sourceCapacity)
  save(directory / "module.vk",vk)
  var digest = ""
  const hex = "0123456789abcdef"
  for b in sha256(vk): digest.add hex[int(b shr 4)]; digest.add hex[int(b and 15)]
  writeFile(directory / "key.sha256",digest)
  echo "setup seconds=",cpuTime()-started," constraints=",key.shape.constraints.len
  started = cpuTime()
  saveModuleProvingKey(directory / "module.pk",key,profile)
  echo "save seconds=",cpuTime()-started," bytes=",getFileSize(directory / "module.pk")
  key = ProvingKey()
  started = cpuTime()
  let loaded = loadModuleProvingKey(directory / "module.pk")
  doAssert loaded.profile == profile
  doAssert encodeModuleDigestKey(loaded.key.verificationKey,profile.sourceCapacity) == vk
  echo "load seconds=",cpuTime()-started
  for i,bytes in data:
    started = cpuTime()
    let proof = proveModuleValidation(loaded.key,bytes,loaded.profile)
    doAssert verifyModuleDigest(loaded.key.verificationKey,bytes,proof)
    doAssert not verifyModuleDigest(loaded.key.verificationKey,data[(i+1) mod data.len],proof)
    save(directory / ("module-" & $i & ".proof"),proof)
    echo "persistent proof ",i," PASS seconds=",cpuTime()-started," bytes=",proof.len
  echo "persistent module key PASS (one on-disk key; empty/export/import/start modules)"

main()
