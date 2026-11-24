## The audit CLI uses the production builder and protects every input path.
import std/[os,osproc,strutils,json,jsonutils]
import cps/zk/wasm_proving_key_file

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() notin 3..4: quit("usage: test_byte_memory_cli CLI CHECKER DIRECTORY [CLAIM]",1)
  let claim = if paramCount() == 4: paramStr(4) else: "source-sha256-byte-queries"
  let cli = absolutePath(paramStr(1))
  let checker = absolutePath(paramStr(2))
  let directory = absolutePath(paramStr(3))
  createDir(directory)
  let wasm = directory / "sample.wasm"
  let profile = directory / "profile.json"
  let audit = directory / "sample.audit"
  let inferred = directory / "inferred.audit"
  var bytes = @[0'u8,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0]
  if claim in ["source-sha256-constant-readers","source-sha256-scalar-payloads","source-sha256-payload-loops","source-sha256-module-context","source-sha256-code-bodies","source-sha256-instruction-stream","source-sha256-validation-events","source-sha256-dynamic-typing","source-sha256-structured-control","source-sha256-runtime-context"]:
    bytes.add @[6'u8,6,1,127,0,65,42,11]
  if claim in ["source-sha256-payload-loops","source-sha256-module-context","source-sha256-code-bodies","source-sha256-instruction-stream","source-sha256-validation-events","source-sha256-dynamic-typing","source-sha256-structured-control","source-sha256-runtime-context"]: bytes.add @[0'u8,3,1,120,255]
  bytes.add @[7'u8,7,1,3,114,117,110,0,0]
  if claim == "source-sha256-code-bodies": bytes.add @[10'u8,8,1,6,1,2,126,65,42,11]
  else: bytes.add @[10'u8,6,1,4,0,65,42,11]
  if claim in ["source-sha256-payload-loops","source-sha256-module-context","source-sha256-code-bodies","source-sha256-instruction-stream","source-sha256-validation-events","source-sha256-dynamic-typing","source-sha256-structured-control","source-sha256-runtime-context"]: bytes.add @[11'u8,5,1,1,2,0,255]
  var content: string
  for b in bytes: content.add char(b)
  writeFile(wasm,content)
  discard run(cli,["module-profile",wasm,profile])
  let originalProfile = readFile(profile)
  let explicit = run(cli,["module-audit",wasm,audit,profile])
  doAssert "claim=" & claim in explicit
  let checked = run(checker,[audit])
  if claim in ["source-sha256-constant-readers","source-sha256-scalar-payloads"]: doAssert "constants=1 " in checked
  if claim in ["source-sha256-payload-loops","source-sha256-module-context"]: doAssert "data=1 " in checked
  if claim == "source-sha256-code-bodies": doAssert "locals=1 " in checked
  stdout.write checked
  let defaultProfile = run(cli,["module-audit",wasm,inferred])
  proc fingerprint(output: string): string =
    for line in output.splitLines():
      if line.startsWith("matrix_sha256="): return line
  doAssert fingerprint(explicit).len > 0 and fingerprint(explicit) == fingerprint(defaultProfile)
  stdout.write run(checker,[inferred])
  discard run(cli,["module-audit",wasm,wasm,profile],false)
  discard run(cli,["module-audit",wasm,profile,profile],false)
  discard run(cli,["module-audit-key",wasm,profile,wasm],false)
  doAssert readFile(wasm) == content and readFile(profile) == originalProfile
  let partial = directory / "partial.json"
  var invalid = parseJson(originalProfile)
  invalid["digestClaim"] = %false
  writeFile(partial,pretty(invalid))
  let rejected = directory / "rejected.audit"
  if fileExists(rejected): removeFile(rejected)
  discard run(cli,["module-audit",wasm,rejected,partial],false)
  doAssert not fileExists(rejected)
  # A well-formed key and VK for a different relation must not certify this matrix.
  var unrelated = initCircuit()
  let x = unrelated.publicInput(scalar(3))
  let y = unrelated.publicInput(scalar(9))
  unrelated.constrain(x,x,y)
  let wrongKey = directory / "unrelated.pk"
  saveModuleProvingKey(wrongKey,setup(unrelated),jsonTo(parseJson(originalProfile),ModuleValidationProfile))
  let mismatch = run(cli,["module-audit-key",wrongKey,wasm,rejected],false)
  doAssert "audit circuit differs from stored proving key" in mismatch,mismatch
  doAssert not fileExists(rejected)
  echo "matrix audit CLI PASS: explicit/inferred profiles agree; 5 unsafe/partial/mismatched requests rejected"

main()
