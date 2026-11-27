import std/[os, json, strutils]
import cps/wasm/[binary, runtime, types, validate]
import wasm_function_references_fixture
when defined(wasmFunctionReferences):
  from bl808/wasm_store import wasmPayloadCrc32Init, wasmPayloadCrc32Update, wasmPayloadCrc32Finish
when defined(wasmSharedCoreTypes):
  from cps/wasm/flash_image import parseFlashWasmModule
  from cps/wasm/jit/lower import lowerFunction

let manifest = paramStr(1)
let directory = manifest.parentDir
let sharedCorpus = paramCount() > 1
let enabled = if sharedCorpus: defined(wasmSharedCoreTypes) else: defined(wasmFunctionReferences)
let subject = if sharedCorpus: "WASM shared core types" else: "WASM function references"
var commands = parseFile(manifest)["commands"].getElems()
let draftChecksStart = commands.len
if sharedCorpus: commands.add(parseFile(paramStr(2))["commands"].getElems())
let tablesStart = commands.len
if sharedCorpus: commands.add(parseFile(paramStr(3))["commands"].getElems())
let atomicsStart = commands.len
if sharedCorpus: commands.add(parseFile(paramStr(5))["commands"].getElems())
if sharedCorpus: commands.add(parseFile(paramStr(7))["commands"].getElems())
let linearAtomicsStart = commands.len
if sharedCorpus: commands.add(parseFile(paramStr(10))["commands"].getElems())
var validBytes, tableBytes, globalBytes: seq[byte]
var runtimeChecks, validationChecks, decodeChecks, linkChecks: int
var vm = initWasmVM()
var moduleIndex = -1
var lastFunctionModule = -1
var imports: seq[StoreImport]
for number, command in commands:
  let kind = command["type"].getStr()
  case kind
  of "module":
    let bytes = cast[seq[byte]](readFile(directory / command["filename"].getStr()))
    if enabled:
      if validBytes.len == 0: validBytes = bytes
      if number == tablesStart:
        lastFunctionModule = moduleIndex
        tableBytes = bytes
      let module = decodeModule(bytes)
      validateModule(module, allowMultipleMemories = sharedCorpus and number >= linearAtomicsStart)
      moduleIndex = vm.instantiate(module, [], imports)
      if number < atomicsStart:
        for item in module.exports:
          if item.kind == ekFunc and item.name in ["typed-globals", "read"]:
            globalBytes = bytes
    else:
      try:
        discard decodeModule(bytes)
        doAssert false, "typed reference opcodes were accepted without the feature"
      except WasmDecodeError:
        discard
      if sharedCorpus:
        let atomics = cast[seq[byte]](readFile(directory / "atomics.1.wasm"))
        try:
          discard decodeModule(atomics)
          doAssert false, "global atomics were accepted without the feature"
        except WasmDecodeError as error:
          doAssert error.msg.contains("atomic instructions are disabled")
        let linear = cast[seq[byte]](readFile(directory / "linear-atomics.2.wasm"))
        try:
          discard decodeModule(linear)
          doAssert false, "linear-memory atomics were accepted without the feature"
        except WasmDecodeError as error:
          doAssert error.msg.contains("atomic instructions are disabled")
        let memory = cast[seq[byte]](readFile(directory / "memories.0.wasm"))
        try:
          discard decodeModule(memory)
          doAssert false, "shared memory was accepted without the feature"
        except WasmDecodeError:
          discard
      echo subject & " feature gate PASS"
      quit(0)
  of "register":
    for item in vm.store.modules[moduleIndex].exports:
      imports.add((command["as"].getStr(), item.name,
        ExternalStoreRef(kind: item.kind, address: item.idx)))
  of "assert_return", "assert_trap":
    let action = command["action"]
    var args: seq[WasmValue]
    for item in action["args"]:
      doAssert item["type"].getStr() == "i32"
      args.add(wasmI32(cast[int32](parseBiggestInt(item["value"].getStr()))))
    let field = action["field"].getStr()
    try:
      let result = vm.invoke(moduleIndex, field, args)
      doAssert kind == "assert_return", "expected a trap in " & field
      let expected = cast[int32](parseBiggestInt(command["expected"][0]["value"].getStr()))
      doAssert result.len == 1 and result[0].i32 == expected
    except WasmTrap as error:
      doAssert kind == "assert_trap" and error.msg.contains(command["text"].getStr()), error.msg
    inc runtimeChecks
  of "assert_invalid":
    let bytes = cast[seq[byte]](readFile(directory / command["filename"].getStr()))
    for optimize in [true, false]:
      try:
        validateModule(decodeModule(bytes, optimize), allowMultipleMemories = sharedCorpus)
        doAssert false, "accepted invalid guest at line " & $command["line"].getInt()
      except ValidationError, WasmDecodeError:
        if number >= draftChecksStart and number < tablesStart:
          let error = getCurrentException()
          doAssert error.msg.contains(command["text"].getStr()), error.msg
    inc validationChecks
  of "assert_malformed":
    let bytes = cast[seq[byte]](readFile(directory / command["filename"].getStr()))
    try:
      discard decodeModule(bytes)
      doAssert false, "accepted malformed guest at line " & $command["line"].getInt()
    except WasmDecodeError:
      inc decodeChecks
  of "assert_unlinkable":
    let bytes = cast[seq[byte]](readFile(directory / command["filename"].getStr()))
    let module = decodeModule(bytes)
    validateModule(module)
    try:
      discard vm.instantiate(module, [], imports)
      doAssert false, "linked with incompatible core reference types"
    except WasmTrap as error:
      let kind = case module.imports[0].kind
        of ikFunc: "function"
        of ikTable: "table"
        of ikGlobal: "global"
        of ikMemory: "memory"
        else: raiseAssert "unexpected import kind"
      doAssert error.msg.contains("incompatible store " & kind & " import")
      inc linkChecks
  else:
    doAssert false, "unexpected spec directive: " & kind
if sharedCorpus:
  doAssert runtimeChecks == 37 and validationChecks == 36 and decodeChecks == 2 and linkChecks == 6
else:
  doAssert runtimeChecks == 16 and validationChecks == 16 and decodeChecks == 2 and linkChecks == 2
doAssert checkFunctionReferenceImage(validBytes)

# The host can supply raw reference values, so validate them at the entry.
doAssert imports.len == (if sharedCorpus: 12 else: 5) and imports[0].fieldName == "identity"
let identity = imports[0].item.address
for value in [wasmNullFuncRef(), wasmFuncRef(high(int32)), wasmFuncRef(identity.int32)]:
  try:
    discard vm.execute(identity, [value])
    doAssert false, "accepted invalid host reference argument"
  except WasmTrap as error:
    doAssert error.msg.contains(if value.isNull(): "null in non-null reference lane"
      else: "typed function reference value mismatch")
if sharedCorpus:
  let privateValue = vm.getExport(lastFunctionModule, "plain-value").idx
  try:
    discard vm.execute(identity, [wasmFuncRef(privateValue.int32)])
    doAssert false, "accepted an unshared host reference in a shared lane"
  except WasmTrap as error:
    doAssert error.msg.contains("typed function reference value mismatch")

# Park inside the tail-replaced function and restore against the same module.
vm.destroyWasmVM()
vm = initWasmVM()
moduleIndex = vm.instantiate(decodeModule(validBytes), [])
let tail = vm.getExport(moduleIndex, "tail").idx
let digest = default(array[32, byte])
var first: WasmContinuation
discard vm.executeSlice(tail, [wasmI32(42)], first, 19)
doAssert first.status == wesYielded
when defined(wasmFunctionReferences):
  if not sharedCorpus:
    let original = vm.store.tables[0].elems[0]
    for invalid in [wasmNullFuncRef(), wasmFuncRef(1)]:
      vm.store.tables[0].elems[0] = invalid
      doAssert vm.capturePortableSnapshot(first, digest).status == wpsUnsupportedState
      when defined(wasmStreamMigration):
        var stream: WasmPortableStream
        doAssert vm.beginPortableStream(first, digest, 512, stream) == wpsOk
        var output: array[512, byte]
        var written: int
        doAssert vm.readPortableStream(first, stream, output, written) == wpsUnsupportedState
    vm.store.tables[0].elems[0] = original
let snapshot = vm.capturePortableSnapshot(first, digest)
doAssert snapshot.status == wpsOk
var resumedVm = initWasmVM()
discard resumedVm.instantiate(decodeModule(validBytes), [])
var restored: WasmContinuation
when defined(wasmFunctionReferences):
  if not sharedCorpus:
    var invalid = snapshot.bytes
    # This fixture's store ends with the table's single function address
    # and the dropped byte for its declarative element segment.
    doAssert invalid[^5 .. ^2] == @[0'u8, 0, 0, 0]
    for at in invalid.len - 5 .. invalid.len - 2: invalid[at] = 0xff
    var crc = wasmPayloadCrc32Init()
    crc = wasmPayloadCrc32Update(crc, invalid.toOpenArray(0, 59))
    crc = wasmPayloadCrc32Update(crc, invalid.toOpenArray(64, invalid.high))
    crc = wasmPayloadCrc32Finish(crc)
    for i in 0 ..< 4: invalid[60 + i] = (crc shr (8 * i)).byte
    doAssert resumedVm.restorePortableSnapshot(restored, invalid, digest) == wpsInvalidSnapshot
    doAssert resumedVm.store.tables[0].elems[0].funcRef == 0 and restored.status == wesReady
doAssert resumedVm.restorePortableSnapshot(restored, snapshot.bytes, digest) == wpsOk
let answer = resumedVm.executeSlice(tail, [], restored, 4096)
doAssert restored.status == wesComplete and answer.len == 1 and answer[0].i32 == 42
when defined(wasmFunctionReferences):
  let globalModule = decodeModule(globalBytes)
  var globalVm = initWasmVM()
  let index = globalVm.instantiate(globalModule, [])
  let entry = globalVm.getExport(index, if sharedCorpus: "read" else: "typed-globals").idx
  var paused: WasmContinuation
  discard globalVm.executeSlice(entry, [], paused, 1)
  doAssert paused.status == wesYielded
  if sharedCorpus:
    doAssert globalVm.capturePortableSnapshot(paused, digest).status == wpsUnsupportedState
  else:
    let original = globalVm.store.globals[1].value
    globalVm.store.globals[1].value = wasmNullFuncRef()
    doAssert globalVm.capturePortableSnapshot(paused, digest).status == wpsUnsupportedState
    when defined(wasmStreamMigration):
      var stream: WasmPortableStream
      doAssert globalVm.beginPortableStream(paused, digest, 512, stream) == wpsOk
      var output: array[512, byte]
      var written: int
      doAssert globalVm.readPortableStream(paused, stream, output, written) == wpsUnsupportedState
    globalVm.store.globals[1].value = original
    let saved = globalVm.capturePortableSnapshot(paused, digest)
    doAssert saved.status == wpsOk
    var receiver = initWasmVM()
    discard receiver.instantiateForRestore(globalModule)
    var resumed: WasmContinuation
    doAssert receiver.restorePortableSnapshot(resumed, saved.bytes, digest) == wpsOk
    doAssert receiver.executeSlice(entry, [], resumed, 64)[0].i32 == 42
when defined(wasmSharedCoreTypes):
  if sharedCorpus:
    doAssert checkSharedTableImage(tableBytes)
    var sharedVm = initWasmVM()
    let tableModule = sharedVm.instantiate(decodeModule(tableBytes), [])
    let run = sharedVm.getExport(tableModule, "run").idx
    var tableContinuation: WasmContinuation
    discard sharedVm.executeSlice(run, [wasmI32(21)], tableContinuation, 1)
    doAssert tableContinuation.status == wesYielded
    doAssert sharedVm.capturePortableSnapshot(tableContinuation, digest).status ==
      wpsUnsupportedState

    # wasm-tools can emit the passive element expression. The pinned draft
    # stores sharedness in bit 3 of its mode, which has no WAT spelling here.
    var elementBytes = cast[seq[byte]](readFile(paramStr(4)))
    try:
      validateModule(decodeModule(elementBytes))
      doAssert false, "shared function accessed an unshared segment"
    except ValidationError as error:
      doAssert error.msg.contains("accesses an unshared element segment")
    var reader = viewBinaryReader(elementBytes.toOpenArray(8, elementBytes.high))
    var flagPosition = 0
    while not reader.atEnd():
      let sectionId = reader.readByte()
      let size = reader.readU32().int
      if sectionId == 9:
        doAssert reader.readU32() == 1
        flagPosition = elementBytes.len - reader.remaining()
        doAssert reader.readByte() == 5
        break
      discard reader.readBytes(size)
    doAssert flagPosition > 0
    elementBytes[flagPosition] = 13
    doAssert parseFlashWasmModule(elementBytes).tables[0].limits.shared
    let elementGuest = decodeModule(elementBytes)
    validateModule(elementGuest)
    var elementVm = initWasmVM()
    let elementIndex = elementVm.instantiate(elementGuest, [])
    doAssert elementVm.invoke(elementIndex, "run", [wasmI32(21)])[0].i32 == 42
    try:
      discard elementVm.invoke(elementIndex, "run", [wasmI32(21)])
      doAssert false, "shared segment remained readable after elem.drop"
    except WasmTrap as error:
      doAssert error.msg.contains("out of bounds table access")

    var atomics = cast[seq[byte]](readFile(paramStr(6)))
    doAssert checkGlobalAtomicImage(atomics)
    try:
      discard lowerFunction(decodeModule(atomics), 0)
      doAssert false, "JIT lowering admitted global atomics"
    except ValueError as error:
      doAssert error.msg.contains("global atomics require interpreter execution")
    let linearAtomics = cast[seq[byte]](readFile(directory / "linear-atomics.1.wasm"))
    try:
      discard lowerFunction(decodeModule(linearAtomics), 0)
      doAssert false, "JIT lowering admitted linear-memory atomics"
    except ValueError as error:
      doAssert error.msg.contains("linear-memory atomics require interpreter execution")
    var orderingAt = -1
    for i in 0 .. atomics.len - 4:
      if atomics[i .. i+3] == @[0xFE'u8, 0x51, 0x11, 0x00]:
        doAssert orderingAt < 0
        orderingAt = i + 2
    doAssert orderingAt >= 0
    for invalid in [0x01'u8, 0x10, 0x22]:
      atomics[orderingAt] = invalid
      try:
        discard decodeModule(atomics)
        doAssert false, "accepted mismatched or unknown RMW ordering"
      except WasmDecodeError as error:
        doAssert error.msg.contains("invalid global atomic ordering")
      doAssert not checkGlobalAtomicImage(atomics)

    when defined(wasmChunkedMemory):
      let memoryBytes = cast[seq[byte]](readFile(directory / "memories.0.wasm"))
      doAssert checkSharedMemoryImage(memoryBytes, "crosses", 2)
      let data = cast[seq[byte]](readFile(paramStr(8)))
      try:
        validateModule(decodeModule(data))
        doAssert false, "shared function accessed a private data segment"
      except ValidationError as error:
        doAssert error.msg.contains("shared core function accesses an unshared data segment")
      let draft = cast[seq[byte]](readFile(paramStr(9)))
      let flash = parseFlashWasmModule(draft)
      doAssert flash.memories[0].limits.shared and flash.datas[0].shared and flash.datas[1].shared
      doAssert checkSharedMemoryImage(draft, "initialize", 1)
      var dataVm = initWasmVM()
      let dataIndex = dataVm.instantiate(decodeModule(draft), [])
      doAssert dataVm.invoke(dataIndex, "initialize", [])[0].i32 == 42
      try:
        discard dataVm.invoke(dataIndex, "initialize", [])
        doAssert false, "dropped shared segment remained readable"
      except WasmTrap as error:
        doAssert error.msg.contains("out of bounds memory access")
      var invalidTarget = decodeModule(draft)
      invalidTarget.memories[0].limits.shared = false
      try:
        validateModule(invalidTarget)
        doAssert false, "shared active segment targeted a private memory"
      except ValidationError as error:
        doAssert error.msg.contains("shared data segment targets an unshared memory")

      var memoryVm = initWasmVM()
      let index = memoryVm.instantiate(decodeModule(memoryBytes), [])
      let crosses = memoryVm.getExport(index, "crosses").idx
      var paused: WasmContinuation
      discard memoryVm.executeSlice(crosses, [], paused, 1)
      doAssert paused.status == wesYielded
      doAssert memoryVm.capturePortableSnapshot(paused, digest).status == wpsUnsupportedState
echo subject & " PASS: typed signatures, linking, traps, XIP adapter and sliced restore"
