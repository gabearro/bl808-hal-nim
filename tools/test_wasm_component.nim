import std/[os, strutils]
import cps/wasm/component
import wasm_component_named_fixture
import wasm_component_resource_fixture
import wasm_component_indirect_fixture
import wasm_component_flat_fixture
import wasm_component_nested_list_fixture
import wasm_component_nested_value_fixture
import wasm_component_resource_bundle_fixture
import wasm_component_host_definition_fixture

proc expectInvalid(data: seq[byte]) =
  var rejected = false
  try:
    discard decodeComponent(data)
  except ComponentError:
    rejected = true
  doAssert rejected

proc main() =
  doAssert paramCount() == 179
  let bytes = cast[seq[byte]](readFile(paramStr(1)))
  let plan = decodeComponent(bytes)
  doAssert plan.exports.len == 3
  let instance = instantiateComponent(plan)
  let sum = instance.invoke("add", [componentValue(cpS32, 19),
                                    componentValue(cpS32, 23)])
  doAssert sum.len == 1 and sum[0].kind == cpS32 and sum[0].bits == 42
  let sumAgain = instance.invoke("add", [componentValue(cpS32, 1),
                                         componentValue(cpS32, 2)])
  doAssert sumAgain.len == 1 and sumAgain[0].bits == 3
  let graph = decodeComponent(cast[seq[byte]](readFile(paramStr(28))))
  let linkedGraph = instantiateComponent(graph)
  let freshGraph = instantiateComponent(graph)
  doAssert linkedGraph.invoke("increment", [componentValue(cpS32, 19)])[0].bits == 38
  doAssert linkedGraph.invoke("increment", [componentValue(cpS32, 2)])[0].bits == 42
  doAssert linkedGraph.invoke("read", [])[0].bits == 21
  doAssert freshGraph.invoke("read", [])[0].bits == 0
  expectInvalid(cast[seq[byte]](readFile(paramStr(29))))
  let textImport = decodeComponent(cast[seq[byte]](readFile(paramStr(30))))
  var textCalls = 0
  let countText: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    inc textCalls
    doAssert args.len == 1 and args[0].kind == cpString
    @[componentValue(cpU32, args[0].text.len.uint64)]
  let countBinding = ComponentHostBinding(name: "count", callback: countText,
    signature: ComponentFuncType(params: @[cpString],
      hasResult: true, resultType: cpU32))
  let importedText = instantiateComponent(textImport, [countBinding])
  doAssert importedText.invoke("answer", [componentString("é")])[0].bits == 3
  doAssert importedText.invoke("answer", [componentString("")])[0].bits == 1
  for name in ["bad-pointer", "bad-text"]:
    let bad = instantiateComponent(textImport, [countBinding])
    var rejectedText = false
    try:
      discard bad.invoke(name, [])
    except ComponentError:
      rejectedText = true
    doAssert rejectedText
    var locked = false
    try:
      discard bad.invoke("answer", [componentString("a")])
    except ComponentError as e:
      locked = e.msg == "component store locked after trap"
    doAssert locked
  doAssert textCalls == 2
  let textResult = decodeComponent(cast[seq[byte]](readFile(paramStr(31))))
  let reply: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    doAssert args.len == 1 and args[0].kind == cpString
    @[componentString(args[0].text & "!")]
  let replyBinding = ComponentHostBinding(name: "reply", callback: reply,
    signature: ComponentFuncType(params: @[cpString],
      hasResult: true, resultType: cpString))
  let withReply = instantiateComponent(textResult, [replyBinding])
  doAssert withReply.invoke("message", [componentString("Ox64")])[0].text == "Ox64!"
  doAssert withReply.invoke("message", [componentString("")])[0].text == "!"
  let tuplePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(32))))
  let single = instantiateComponent(tuplePlan)
  let firstTuple = single.invoke("value", [componentValue(cpU64, 0x1_0000_0000'u64)])
  let secondTuple = single.invoke("value", [componentValue(cpU64, 42)])
  doAssert firstTuple[0].kind == cpTuple and
    firstTuple[0].fields[0].bits == 0x1_0000_0000'u64
  doAssert secondTuple[0].fields[0].bits == 0x1_0000_002a'u64
  for i in 33 .. 34:
    let encodedPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(i))))
    let encoded = instantiateComponent(encodedPlan, [replyBinding])
    doAssert encoded.invoke("message", [componentString("hö🍰")])[0].text == "hö🍰!"
    doAssert encoded.invoke("message", [componentString("é")])[0].text == "é!"
    doAssert encoded.invoke("encoded-length", [componentString("é")])[0].bits == 1
    let emojiUnits = if i == 33: 2'u64 else: 0x80000002'u64
    doAssert encoded.invoke("encoded-length", [componentString("🍰")])[0].bits ==
      emojiUnits
    let illegalAlignment = instantiateComponent(encodedPlan, [replyBinding])
    var trapped = false
    try:
      discard illegalAlignment.invoke("odd-empty", [])
    except ComponentError as e:
      trapped = e.msg == "unaligned canonical string pointer"
    doAssert trapped
    if i == 33:
      trapped = false
      let unpaired = instantiateComponent(encodedPlan, [replyBinding])
      try:
        discard unpaired.invoke("bad-surrogate", [])
      except ComponentError as e:
        trapped = e.msg == "missing UTF-16 low surrogate"
      doAssert trapped
  let resourcePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(35))))
  var destroyed: seq[uint64]
  let observeDrop: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    destroyed.add(args[0].bits)
  let resourceBinding = ComponentHostBinding(name: "observe-drop",
    callback: observeDrop, signature: ComponentFuncType(params: @[cpU32]))
  let localResources = instantiateComponent(resourcePlan, [resourceBinding])
  let counter = localResources.invoke("make", [componentValue(cpU32, 42)])[0]
  doAssert localResources.invoke("read", [counter])[0].bits == 42
  doAssert localResources.invoke("drop", [counter]).len == 0 and destroyed == @[42'u64]
  var staleRejected = false
  try:
    discard localResources.invoke("drop", [counter])
  except ComponentError as e:
    staleRejected = "crInvalidHandle" in e.msg
  doAssert staleRejected and destroyed == @[42'u64]
  let wrongResource = instantiateComponent(resourcePlan, [resourceBinding])
  let other = wrongResource.invoke("make", [componentValue(cpU32, 9)])[0]
  var wrongTypeRejected = false
  try:
    discard wrongResource.invoke("read-wrong", [other])
  except ComponentError as e:
    wrongTypeRejected = "crInvalidType" in e.msg
  doAssert wrongTypeRejected
  let closeResource = instantiateComponent(resourcePlan, [resourceBinding])
  discard closeResource.invoke("make", [componentValue(cpU32, 25)])
  closeComponent(closeResource)
  closeComponent(closeResource)
  doAssert destroyed == @[42'u64, 25'u64]
  let ownedInstance = instantiateComponent(resourcePlan, [resourceBinding])
  let owned = ownedInstance.invoke("make-owner", [componentValue(cpU32, 71)])[0]
  doAssert owned.kind == cpOwnedResource
  let loan = borrowComponentResource(owned)
  doAssert ownedInstance.invoke("inspect", [loan])[0].bits == 71
  var retypedLoan = loan
  retypedLoan.kind = cpOwnedResource
  var invalidOwnershipRejected = false
  try:
    discard ownedInstance.invoke("take", [retypedLoan])
  except ComponentError as e:
    invalidOwnershipRejected = "ownership mismatch" in e.msg
  doAssert invalidOwnershipRejected
  var closeWithOwnerRejected = false
  try:
    closeComponent(ownedInstance)
  except ComponentError as e:
    closeWithOwnerRejected = "live owned" in e.msg
  doAssert closeWithOwnerRejected
  var moveWhileLentRejected = false
  try:
    discard ownedInstance.invoke("conflict", [loan, owned])
  except ComponentError as e:
    moveWhileLentRejected = "owner and alias" in e.msg
  doAssert moveWhileLentRejected
  var otherInstanceRejected = false
  let unrelatedInstance = instantiateComponent(resourcePlan, [resourceBinding])
  try:
    discard unrelatedInstance.invoke("inspect", [loan])
  except ComponentError as e:
    otherInstanceRejected = "owner mismatch" in e.msg
  doAssert otherInstanceRejected
  discard ownedInstance.invoke("take", [owned])
  doAssert destroyed == @[42'u64, 25'u64, 71'u64]
  var expiredLoanRejected = false
  try:
    discard ownedInstance.invoke("inspect", [loan])
  except ComponentError as e:
    expiredLoanRejected = "owner mismatch" in e.msg
  doAssert expiredLoanRejected
  let hostOwner = ownedInstance.invoke("make-owner", [componentValue(cpU32, 81)])[0]
  dropComponentResource(hostOwner)
  doAssert destroyed == @[42'u64, 25'u64, 71'u64, 81'u64]
  closeComponent(ownedInstance)
  let wrapped = instance.invoke("wrap", [componentValue(cpU8, 255)])
  doAssert wrapped.len == 1 and wrapped[0].kind == cpU8 and wrapped[0].bits == 0
  let half = instance.invoke("halve", [componentValue(cpF64,
                                            cast[uint64](12.0'f64))])
  doAssert half.len == 1 and half[0].kind == cpF64 and
    cast[float64](half[0].bits) == 6.0
  var wrongType = false
  try:
    discard instance.invoke("add", [componentValue(cpU32, 1),
                                     componentValue(cpS32, 2)])
  except ComponentError:
    wrongType = true
  doAssert wrongType
  var bad = bytes
  bad[4] = 1
  expectInvalid(bad)
  expectInvalid(bytes[0 ..< bytes.len - 1])
  var tooManyTypes = bytes
  for _ in 0 ..< 130:
    tooManyTypes.add([0x07'u8, 0x03, 0x01, 0x70, 0x7d])
  expectInvalid(tooManyTypes)
  let imported = decodeComponent(cast[seq[byte]](readFile(paramStr(2))))
  var unresolved = false
  try:
    discard instantiateComponent(imported)
  except ComponentError:
    unresolved = true
  doAssert unresolved
  let signature = ComponentFuncType(params: @[cpS32],
                                    hasResult: true, resultType: cpS32)
  let scale: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    doAssert args.len == 1
    @[componentValue(cpS32, cast[uint64](cast[int64](args[0].bits) * 3))]
  let linked = instantiateComponent(imported,
    [ComponentHostBinding(name: "scale", signature: signature, callback: scale)])
  let adjusted = linked.invoke("adjusted", [componentValue(cpS32, 7)])
  doAssert adjusted.len == 1 and adjusted[0].bits == 23
  var typeMismatch = false
  try:
    discard instantiateComponent(imported,
      [ComponentHostBinding(name: "scale",
        signature: ComponentFuncType(params: @[cpU32],
          hasResult: true, resultType: cpS32), callback: scale)])
  except ComponentError:
    typeMismatch = true
  doAssert typeMismatch
  let multi = decodeComponent(cast[seq[byte]](readFile(paramStr(3))))
  let doubleFn: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    @[componentValue(cpS32, args[0].bits * 2)]
  let tripleFn: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    @[componentValue(cpS32, args[0].bits * 3)]
  let combined = instantiateComponent(multi,
    [ComponentHostBinding(name: "double", signature: signature,
      callback: doubleFn),
     ComponentHostBinding(name: "triple", signature: signature,
      callback: tripleFn)])
  let combinedResult = combined.invoke("combine", [componentValue(cpS32, 9)])
  doAssert combinedResult[0].bits == 45
  let stringPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(4))))
  let stringInstance = instantiateComponent(stringPlan)
  let first = stringInstance.invoke("first-byte", [componentString("Aha")])
  doAssert first.len == 1 and first[0].kind == cpU32 and first[0].bits == 65
  let utf8 = stringInstance.invoke("first-byte", [componentString("é")])
  doAssert utf8[0].bits == 0xc3
  var invalidUtf8 = false
  try:
    discard componentString("\xff")
  except ComponentError:
    invalidUtf8 = true
  doAssert invalidUtf8
  let badRealloc = decodeComponent(cast[seq[byte]](readFile(paramStr(5))))
  let badInstance = instantiateComponent(badRealloc)
  var outOfBounds = false
  try:
    discard badInstance.invoke("first-byte", [componentString("ABC")])
  except ComponentError:
    outOfBounds = true
  doAssert outOfBounds
  let resultPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(6))))
  let resultInstance = instantiateComponent(resultPlan)
  let greeting = resultInstance.invoke("greet", [])
  doAssert greeting.len == 1 and greeting[0].kind == cpString and
    greeting[0].text == "Hello, Ox64"
  let afterPost = resultInstance.invoke("greet", [])
  doAssert afterPost.len == 1 and afterPost[0].text == "Post called"
  let oobPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(7))))
  let oobInstance = instantiateComponent(oobPlan)
  var rejectedOob = false
  try:
    discard oobInstance.invoke("greet", [])
  except ComponentError:
    rejectedOob = true
  doAssert rejectedOob
  let bytesPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(8))))
  let bytesInstance = instantiateComponent(bytesPlan)
  let echoed = bytesInstance.invoke("echo-bytes",
    [componentBytes([0'u8, 1, 255, 0])])
  doAssert echoed.len == 1 and echoed[0].kind == cpBytes and
    echoed[0].bytes == @[0'u8, 1, 255, 0]
  let empty = bytesInstance.invoke("echo-bytes", [componentBytes([])])
  doAssert empty.len == 1 and empty[0].bytes.len == 0
  let wordsPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(22))))
  let wordsInstance = instantiateComponent(wordsPlan)
  let words = wordsInstance.invoke("echo-words",
    [componentU32List([0'u32, 0x1020_3040'u32, high(uint32)])])
  doAssert words.len == 1 and words[0].kind == cpU32List and
    words[0].fields.len == 3 and words[0].fields[0].bits == 0 and
    words[0].fields[1].bits == 0x1020_3040'u64 and
    words[0].fields[2].bits == high(uint32).uint64
  let emptyWords = wordsInstance.invoke("echo-words", [componentU32List([])])
  doAssert emptyWords.len == 1 and emptyWords[0].fields.len == 0
  var wrongWord = componentU32List([1'u32])
  wrongWord.fields[0].kind = cpS32
  var rejectedWord = false
  try:
    discard wordsInstance.invoke("echo-words", [wrongWord])
  except ComponentError:
    rejectedWord = true
  doAssert rejectedWord
  let unalignedWords = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(23)))))
  var rejectedUnaligned = false
  try:
    discard unalignedWords.invoke("echo-words", [componentU32List([1'u32])])
  except ComponentError:
    rejectedUnaligned = true
  doAssert rejectedUnaligned
  let qwordsPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(24))))
  let qwordsInstance = instantiateComponent(qwordsPlan)
  let qwords = qwordsInstance.invoke("echo-qwords",
    [componentU64List([0'u64, 0x1020_3040_5060_7080'u64,
                       high(uint64)])])
  doAssert qwords.len == 1 and qwords[0].kind == cpU64List and
    qwords[0].fields.len == 3 and qwords[0].fields[0].bits == 0 and
    qwords[0].fields[1].bits == 0x1020_3040_5060_7080'u64 and
    qwords[0].fields[2].bits == high(uint64)
  let emptyQwords = qwordsInstance.invoke("echo-qwords", [componentU64List([])])
  doAssert emptyQwords.len == 1 and emptyQwords[0].fields.len == 0
  var wrongQword = componentU64List([1'u64])
  wrongQword.fields[0].kind = cpU32
  var rejectedQword = false
  try:
    discard qwordsInstance.invoke("echo-qwords", [wrongQword])
  except ComponentError:
    rejectedQword = true
  doAssert rejectedQword
  let unalignedQwords = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(25)))))
  var rejectedUnalignedQword = false
  try:
    discard unalignedQwords.invoke("echo-qwords", [componentU64List([1'u64])])
  except ComponentError:
    rejectedUnalignedQword = true
  doAssert rejectedUnalignedQword
  let optionString = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(26)))))
  let absentText = optionString.invoke("len", [componentOptionNone()])
  doAssert absentText.len == 1 and absentText[0].bits == 0
  let presentText = optionString.invoke("len", [componentOptionSome(
    componentString("Ox64"))])
  doAssert presentText.len == 1 and presentText[0].bits == 4
  let emptyText = optionString.invoke("len", [componentOptionSome(
    componentString(""))])
  doAssert emptyText.len == 1 and emptyText[0].bits == 0
  let greetingText = optionString.invoke("get", [])
  doAssert greetingText.len == 1 and greetingText[0].kind == cpOption and
    greetingText[0].caseIndex == 1 and greetingText[0].fields.len == 1 and
    greetingText[0].fields[0].kind == cpString and
    greetingText[0].fields[0].text == "Ox64"
  var wrongOptionString = false
  try:
    discard optionString.invoke("len", [componentOptionSome(
      componentValue(cpU32, 1))])
  except ComponentError:
    wrongOptionString = true
  doAssert wrongOptionString
  let optionStringOob = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(27)))))
  var rejectedOptionStringOob = false
  try:
    discard optionStringOob.invoke("get", [])
  except ComponentError:
    rejectedOptionStringOob = true
  doAssert rejectedOptionStringOob
  let recordPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(9))))
  let recordInstance = instantiateComponent(recordPlan)
  let summed = recordInstance.invoke("sum-pair", [componentRecord([
    componentValue(cpU32, 19), componentValue(cpU32, 23)])])
  doAssert summed.len == 1 and summed[0].kind == cpU32 and
    summed[0].bits == 42
  let made = recordInstance.invoke("make-pair", [
    componentValue(cpU32, 12), componentValue(cpU32, 30)])
  doAssert made.len == 1 and made[0].kind == cpRecord and
    made[0].fields.len == 2 and made[0].fields[0].bits == 12 and
    made[0].fields[1].bits == 30
  let madeAgain = recordInstance.invoke("make-pair", [
    componentValue(cpU32, 1), componentValue(cpU32, 2)])
  doAssert madeAgain[0].fields[0].bits == 1 and
    madeAgain[0].fields[1].bits == 2
  var badRecord = false
  try:
    discard recordInstance.invoke("sum-pair", [componentRecord([
      componentValue(cpU32, 1), componentValue(cpS32, 2)])])
  except ComponentError:
    badRecord = true
  doAssert badRecord
  let recordOob = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(10)))))
  var rejectedRecordOob = false
  try:
    discard recordOob.invoke("make-pair", [
      componentValue(cpU32, 1), componentValue(cpU32, 2)])
  except ComponentError:
    rejectedRecordOob = true
  doAssert rejectedRecordOob
  let mixed = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(11)))))
  let mixedValue = mixed.invoke("echo-mixed", [componentRecord([
    componentValue(cpBool, 1),
    componentValue(cpU64, 0x1122_3344_5566_7788'u64),
    componentValue(cpS16, cast[uint64](-7'i64)),
    componentValue(cpF32, cast[uint32](1.25'f32).uint64)])])
  doAssert mixedValue.len == 1 and mixedValue[0].kind == cpRecord and
    mixedValue[0].fields.len == 4 and
    mixedValue[0].fields[0].bits == 1 and
    mixedValue[0].fields[1].bits == 0x1122_3344_5566_7788'u64 and
    cast[int64](mixedValue[0].fields[2].bits) == -7 and
    cast[float32](mixedValue[0].fields[3].bits.uint32) == 1.25'f32
  let generatedResource = decodeComponent(cast[seq[byte]](readFile(paramStr(12))))
  doAssert checkGeneratedResource(instantiateComponent(generatedResource))
  let firstCounter = instantiateComponent(generatedResource)
  let secondCounter = instantiateComponent(generatedResource)
  let handle = firstCounter.invokeInterface("counters", "[constructor]counter",
    [componentValue(cpU32, 99)])[0]
  try:
    discard secondCounter.invokeInterface("counters", "[method]counter.get",
        [borrowComponentResource(handle)])
    doAssert false, "accepted a resource from another component instance"
  except ComponentError as error:
    doAssert "resource argument type or owner mismatch" in error.msg
  doAssert secondCounter.invokeInterface("counters", "last-dropped", [])[0].bits == 0
  try:
    closeComponent(firstCounter)
    doAssert false, "closed the resource provider while its owner was live"
  except ComponentError as error:
    doAssert "live owned" in error.msg
  let retainedBorrow = borrowComponentResource(handle)
  dropComponentResource(handle)
  try:
    discard firstCounter.invokeInterface("counters", "[method]counter.get", [retainedBorrow])
    doAssert false, "accepted a borrow of a destroyed resource"
  except ComponentError as error:
    doAssert "resource argument type or owner mismatch" in error.msg
  doAssert firstCounter.invokeInterface("counters", "last-dropped", [])[0].bits == 99
  closeComponent(firstCounter)
  let postPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(13))))
  var callbackCount = 0
  let countedScale: ComponentHostFunc = proc(args: openArray[ComponentValue]):
      seq[ComponentValue] =
    inc callbackCount
    @[componentValue(cpS32, args[0].bits * 3)]
  let postInstance = instantiateComponent(postPlan,
    [ComponentHostBinding(name: "scale", signature: signature,
      callback: countedScale)])
  doAssert postInstance.invoke("ping", []).len == 0
  var postRejected = false
  try:
    discard postInstance.invoke("adjusted", [componentValue(cpS32, 7)])
  except ComponentError:
    postRejected = true
  doAssert postRejected and callbackCount == 1
  var postLocked = false
  try:
    discard postInstance.invoke("ping", [])
  except ComponentError as e:
    postLocked = e.msg == "component store locked after trap"
  doAssert postLocked
  let optionInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(14)))))
  doAssert optionInstance.invoke("choose", [componentOptionNone()])[0].bits == 0
  doAssert optionInstance.invoke("choose", [componentOptionSome(
    componentValue(cpU32, 41))])[0].bits == 42
  let optional = optionInstance.invoke("make-option", [componentValue(cpU32, 9)])
  doAssert optional.len == 1 and optional[0].kind == cpOption and
    optional[0].caseIndex == 1 and optional[0].fields.len == 1 and
    optional[0].fields[0].kind == cpU32 and optional[0].fields[0].bits == 9
  let variantInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(15)))))
  doAssert variantInstance.invoke("describe", [componentVariant(0)])[0].bits == 0
  doAssert variantInstance.invoke("describe", [componentVariant(1,
    [componentValue(cpU32, 17)])])[0].bits == 17
  doAssert variantInstance.invoke("describe", [componentVariant(2,
    [componentValue(cpU64, 0x1122_3344_5566_7788'u64)])])[0].bits ==
    0x1122_3344_5566_7788'u64
  doAssert variantInstance.invoke("describe", [componentVariant(3,
    [componentValue(cpF32, cast[uint32](1.25'f32).uint64)])])[0].bits ==
    cast[uint32](1.25'f32).uint64
  let variant = variantInstance.invoke("make-wide", [
    componentValue(cpU64, 0x8877_6655_4433_2211'u64)])
  doAssert variant.len == 1 and variant[0].kind == cpVariant and
    variant[0].caseIndex == 2 and variant[0].fields.len == 1 and
    variant[0].fields[0].kind == cpU64 and
    variant[0].fields[0].bits == 0x8877_6655_4433_2211'u64
  let enumInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(16)))))
  let mode = enumInstance.invoke("echo-mode", [componentEnum(2)])
  doAssert mode.len == 1 and mode[0].kind == cpEnum and mode[0].caseIndex == 2
  var badEnum = false
  try:
    discard enumInstance.invoke("echo-mode", [componentEnum(3)])
  except ComponentError:
    badEnum = true
  doAssert badEnum
  let resultInstance2 = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(17)))))
  let okValue = resultInstance2.invoke("inspect", [componentResult(0,
    [componentValue(cpU32, 23)])])
  doAssert okValue.len == 1 and okValue[0].bits == 23
  let errorValue = resultInstance2.invoke("make-error", [
    componentValue(cpU64, 0x1234_5678_9abc_def0'u64)])
  doAssert errorValue.len == 1 and errorValue[0].kind == cpResult and
    errorValue[0].caseIndex == 1 and errorValue[0].fields.len == 1 and
    errorValue[0].fields[0].kind == cpU64 and
    errorValue[0].fields[0].bits == 0x1234_5678_9abc_def0'u64
  let tupleInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(18)))))
  let tupleSum = tupleInstance.invoke("sum-tuple", [componentTuple([
    componentValue(cpU32, 19), componentValue(cpU32, 23)])])
  doAssert tupleSum.len == 1 and tupleSum[0].bits == 42
  let tupleValue = tupleInstance.invoke("make-tuple", [
    componentValue(cpU32, 12), componentValue(cpU32, 30)])
  doAssert tupleValue.len == 1 and tupleValue[0].kind == cpTuple and
    tupleValue[0].fields.len == 2 and tupleValue[0].fields[0].bits == 12 and
    tupleValue[0].fields[1].bits == 30
  let flagsInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(19)))))
  let flags = flagsInstance.invoke("echo-flags", [componentFlags(5)])
  doAssert flags.len == 1 and flags[0].kind == cpFlags and flags[0].bits == 5
  var badFlags = false
  try:
    discard flagsInstance.invoke("echo-flags", [componentFlags(8)])
  except ComponentError:
    badFlags = true
  doAssert badFlags
  let invalidVariantInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(20)))))
  var invalidVariant = false
  try:
    discard invalidVariantInstance.invoke("make-invalid", [])
  except ComponentError:
    invalidVariant = true
  doAssert invalidVariant
  let charInstance = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(21)))))
  let scalar = charInstance.invoke("echo-char", [componentValue(cpChar,
    0x1f600'u64)])
  doAssert scalar.len == 1 and scalar[0].kind == cpChar and
    scalar[0].bits == 0x1f600'u64
  var invalidChar = false
  try:
    discard charInstance.invoke("echo-char", [componentValue(cpChar,
      0xd800'u64)])
  except ComponentError:
    invalidChar = true
  doAssert invalidChar
  let namedPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(36))))
  let provided = biasBinding()
  doAssert checkNamedArithmetic(instantiateComponent(namedPlan, [],
    interfaces = [provided]))
  try:
    discard instantiateComponent(namedPlan, provided.functions)
    doAssert false, "accepted a standalone host function for a missing interface"
  except ComponentError as error:
    doAssert "unresolved component interface" in error.msg
  var wrongMethod = biasBinding()
  wrongMethod.functions[0].signature.params = @[cpU32]
  try:
    discard instantiateComponent(namedPlan, [], interfaces = [wrongMethod])
    doAssert false, "accepted a method with a different component type"
  except ComponentError as error:
    doAssert "component host import type mismatch" in error.msg
  let composedPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(37))))
  doAssert checkNamedArithmetic(instantiateComponent(composedPlan))
  let indirect = decodeComponent(cast[seq[byte]](readFile(paramStr(38))))
  doAssert checkIndirectArguments(instantiateComponent(indirect))
  let linkedIndirect = decodeComponent(cast[seq[byte]](readFile(paramStr(39))))
  var indirectCalls = 0
  let linkedInstance = instantiateComponent(linkedIndirect,
    [indirectArgumentsBinding(linkedIndirect, addr indirectCalls)])
  doAssert checkIndirectArguments(linkedInstance) and indirectCalls == 1
  try:
    discard linkedInstance.invoke("bad-arguments", [])
    doAssert false, "accepted an out-of-bounds canonical parameter area"
  except ComponentError as error:
    doAssert "linear memory range out of bounds" in error.msg
  doAssert indirectCalls == 1
  let flat = decodeComponent(cast[seq[byte]](readFile(paramStr(40))))
  var flatCalls = 0
  let flatInstance = instantiateComponent(flat, [flatArgumentsBinding(flat, addr flatCalls)])
  doAssert checkFlatArguments(flatInstance) and flatCalls == 2
  try:
    discard flatInstance.invoke("bad-tag", [])
    doAssert false, "flat variant accepted a discriminant outside its cases"
  except ComponentError as error:
    doAssert "canonical variant discriminant out of range" in error.msg
  doAssert flatCalls == 2
  let namedRecordPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(41))))
  let namedRecord = instantiateComponent(namedRecordPlan)
  let namedRecordResult = namedRecord.invokeInterface("arithmetic", "sum", [
    componentRecord([componentValue(cpU32, 19), componentValue(cpU32, 23)])])
  doAssert namedRecordResult.len == 1 and namedRecordResult[0].kind == cpU32 and
    namedRecordResult[0].bits == 42
  for fixture in 42 .. 43:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(fixture))))
      doAssert false, "accepted an instance with a different named value type"
    except ComponentError as error:
      doAssert "component instance value type mismatch: value" in error.msg
  let visibleList = decodeComponent(cast[seq[byte]](readFile(paramStr(44))))
  doAssert visibleList.instantiateComponent() != nil
  let nestedLists = decodeComponent(cast[seq[byte]](readFile(paramStr(45))))
  doAssert checkNestedList(instantiateComponent(nestedLists))
  for i, message in ["unaligned canonical list pointer",
                     "canonical list transfer exceeds profile limit",
                     "linear memory range out of bounds"]:
    let lists = instantiateComponent(nestedLists)
    try:
      discard lists.invoke("echo", nestedListArguments((i + 1).uint8))
      doAssert false, "accepted a malformed nested list"
    except ComponentError as error:
      doAssert message in error.msg, error.msg
    try:
      discard checkNestedList(lists)
      doAssert false, "accepted a call after a canonical lift trap"
    except ComponentError as error:
      doAssert "component store locked after trap" in error.msg
  let nestedValue = decodeComponent(cast[seq[byte]](readFile(paramStr(46))))
  doAssert checkNestedValue(instantiateComponent(nestedValue))
  let nestedBridge = decodeComponent(cast[seq[byte]](readFile(paramStr(47))))
  var nestedCalls = 0
  let relay: ComponentHostFunc = proc(args: openArray[ComponentValue]): seq[ComponentValue] =
    inc nestedCalls
    @[args[0]]
  let nestedInstance = instantiateComponent(nestedBridge, [
    ComponentHostBinding(name: "relay", signature: nestedBridge.exports[0].signature,
                         callback: relay)])
  doAssert checkNestedValue(nestedInstance) and nestedCalls == 2
  let bundlePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(48))))
  doAssert checkResourceBundle(instantiateComponent(bundlePlan))
  let bundles = instantiateComponent(bundlePlan)
  let ticket = makeTicket(bundles, 42)
  try:
    discard bundles.invokeInterface("bundles", "exchange", [bundleValue([ticket, ticket])])
    doAssert false, "accepted two copies of one nested owner"
  except ComponentError as error:
    doAssert "resource supplied as both owner and alias" in error.msg
  let otherBundles = instantiateComponent(bundlePlan)
  try:
    discard otherBundles.invokeInterface("bundles", "exchange", [bundleValue([ticket])])
    doAssert false, "accepted a nested owner from another instance"
  except ComponentError as error:
    doAssert "resource argument type or owner mismatch" in error.msg
  let exchanged = bundles.invokeInterface("bundles", "exchange", [bundleValue([ticket])])
  try:
    discard borrowComponentResource(ticket)
    doAssert false, "retained ownership of a moved ticket"
  except ComponentError as error:
    doAssert "invalid component owned value" in error.msg
  dropComponentResource(exchanged[0].fields[1].fields[0])
  let foreignBorrow = decodeComponent(cast[seq[byte]](readFile(paramStr(49))))
  let borrower = instantiateComponent(foreignBorrow)
  for _ in 0 .. 1:
    let values = borrower.invoke("run", [])
    doAssert values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
  try:
    discard borrower.invoke("leak", [])
    doAssert false, "foreign borrow escaped its call"
  except ComponentError as error:
    doAssert "canonical call returned with a live borrow handle" in error.msg
  try:
    discard borrower.invoke("run", [])
    doAssert false, "component store remained callable after a leaked borrow"
  except ComponentError as error:
    doAssert "component store locked after trap" in error.msg
  let smallBorrow = decodeComponent(cast[seq[byte]](readFile(paramStr(50))))
  let smallBorrower = instantiateComponent(smallBorrow)
  doAssert smallBorrower.invoke("run", [])[0].bits == 42
  closeComponent(smallBorrower)
  let linkedBundle = decodeComponent(cast[seq[byte]](readFile(paramStr(51))))
  let linkedResources = instantiateComponent(linkedBundle)
  let returnedBundle = linkedResources.invoke("run", [])
  doAssert returnedBundle.len == 1 and returnedBundle[0].bits == 42
  try:
    discard linkedResources.invoke("duplicate", [])
    doAssert false, "copied a guest-owned handle into two list elements"
  except ComponentError as error:
    doAssert "crInvalidHandle" in error.msg, error.msg
  let annotated = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(52)))))
  let owner = annotated.invokeInterface("tickets", "make", [componentValue(cpU32, 42)])[0]
  let peek = annotated.invokeInterface("tickets", "get", [borrowComponentResource(owner)])
  doAssert peek.len == 1 and peek[0].bits == 42
  dropComponentResource(owner)
  try:
    discard annotated.invokeInterface("tickets", "hidden", [])
    doAssert false, "annotation exposed an omitted function"
  except ComponentError as error:
    doAssert "unknown component interface function" in error.msg
  for i in 53 .. 56:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(i))))
      doAssert false, "accepted an instance export with incompatible resource identities"
    except ComponentError as error:
      doAssert "component interface export" in error.msg and "resource type mismatch" in error.msg
  let typedPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(57))))
  let typedInstance = instantiateComponent(typedPlan)
  let typedResult = typedInstance.invoke("run", [])
  doAssert typedResult.len == 1 and typedResult[0].kind == cpU32 and typedResult[0].bits == 42
  try:
    discard typedInstance.invoke("wrong-owner", [])
    doAssert false, "accepted a resource from a different instance of the typed import"
  except ComponentError as error:
    doAssert "crInvalidType" in error.msg, error.msg
  closeComponent(typedInstance)
  let freshTypedInstance = instantiateComponent(typedPlan)
  doAssert freshTypedInstance.invoke("run", [])[0].bits == 42
  closeComponent(freshTypedInstance)
  for i, diagnostic in ["component import function resource type mismatch",
                        "component import requires function: required"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(58 + i))))
      doAssert false, "accepted an incompatible component definition"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let consumer = decodeComponent(cast[seq[byte]](readFile(paramStr(60))))
  let provider = decodeComponent(cast[seq[byte]](readFile(paramStr(61))))
  let unusedFactory = decodeComponent(cast[seq[byte]](readFile(paramStr(62))))
  let definition = ComponentHostDefinition(name: "factory", plan: provider)
  let incompatible = ComponentHostDefinition(name: "factory", plan: plan)
  let unvalidated = ComponentHostDefinition(name: "factory")
  var starts = 0
  let started: ComponentHostFunc =
    proc(args: openArray[ComponentValue]): seq[ComponentValue] = inc starts
  let functions = hostDefinitionFunctions(started)
  for (target, supplied, diagnostic) in [
      (consumer, newSeq[ComponentHostDefinition](), "unresolved component definition: factory"),
      (consumer, @[definition, definition], "duplicate host component definition: factory"),
      (consumer, @[unvalidated], "unvalidated host component definition: factory"),
      (consumer, @[incompatible], "component import provider lacks function export: apply"),
      (unusedFactory, @[incompatible], "component import provider lacks function export: apply")]:
    try:
      discard instantiateComponent(target, functions, components = supplied)
      doAssert false, "accepted an invalid host definition"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
    doAssert starts == 0, "a guest start ran before validating component bindings"
  let fromHost = instantiateComponent(consumer, functions, components = [definition])
  doAssert starts == 1 and checkHostDefinition(fromHost) and checkHostDefinition(fromHost)
  closeComponent(fromHost)
  closeComponent(instantiateComponent(unusedFactory, functions, components = [definition]))
  doAssert starts == 2
  let reexported = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(63)))))
  doAssert reexported.invoke("run", [])[0].bits == 42
  doAssert reexported.invoke("run", [])[0].bits == 42
  closeComponent(reexported)
  let typedInterface = decodeComponent(cast[seq[byte]](readFile(paramStr(64))))
  let typedInterfaceInstance = instantiateComponent(typedInterface, [],
    interfaces = [provided],
    components = [ComponentHostDefinition(name: "factory", plan: namedPlan)])
  doAssert checkNamedArithmetic(typedInterfaceInstance)
  closeComponent(typedInterfaceInstance)
  let typedResourceInterface = decodeComponent(cast[seq[byte]](readFile(paramStr(65))))
  let typedResourceInstance = instantiateComponent(typedResourceInterface)
  for _ in 0 .. 1:
    doAssert typedResourceInstance.invoke("run", [])[0].bits == 42
  closeComponent(typedResourceInstance)
  for i, diagnostic in ["component import resource export type mismatch: ticket",
                        "component import provider lacks interface function: forward"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(66 + i))))
      doAssert false, "accepted an incompatible instance in a component contract"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let relayed = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(68)))))
  for _ in 0 .. 1:
    doAssert relayed.invoke("run", [])[0].bits == 42
  closeComponent(relayed)
  let moduleConsumer = decodeComponent(cast[seq[byte]](readFile(paramStr(69))))
  let moduleProvider = ComponentHostCoreModule(name: "engine",
    bytes: cast[seq[byte]](readFile(paramStr(70))))
  for (supplied, diagnostic) in [
      (newSeq[ComponentHostCoreModule](), "unresolved core module import: engine"),
      (@[moduleProvider, moduleProvider], "duplicate host core module: engine"),
      (@[ComponentHostCoreModule(name: "engine")], "invalid embedded core module")]:
    try:
      discard instantiateComponent(moduleConsumer, [], coreModules = supplied)
      doAssert false, "accepted an invalid host core module"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  for _ in 0 .. 1:
    let fromModule = instantiateComponent(moduleConsumer, [], coreModules = [moduleProvider])
    doAssert fromModule.invoke("run", [])[0].bits == 42
    closeComponent(fromModule)
  let memoryModule = decodeComponent(cast[seq[byte]](readFile(paramStr(71))))
  closeComponent(instantiateComponent(memoryModule))
  for i, diagnostic in ["core module requires import: inputs:unused",
                        "unresolved core import: .decoy"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(72 + i))))
      doAssert false, "accepted an incompatible module in a component contract"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let definitionRelayPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(74))))
  for _ in 0 .. 1:
    let relay = instantiateComponent(definitionRelayPlan)
    doAssert relay.invoke("run", [])[0].bits == 42
    doAssert relay.invoke("run", [])[0].bits == 43
    doAssert relay.invoke("run-second", [])[0].bits == 42
    doAssert relay.invoke("run-direct", [])[0].bits == 42
    closeComponent(relay)
  let smallerDefinition = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(75)))))
  doAssert smallerDefinition.invoke("run", [])[0].bits == 42
  closeComponent(smallerDefinition)
  for i, diagnostic in ["component import provider lacks function export: missing",
                        "component import provider lacks function export: extra",
                        "unknown component instance function: extra",
                        "component contract nesting limit"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(76 + i))))
      doAssert false, "accepted an incompatible component definition"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let nestedResources = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(80)))))
  doAssert nestedResources.invoke("run", [])[0].bits == 42
  let nestedOwner = nestedResources.invokeInterface(["nested", "inner"], "make", [])[0]
  doAssert nestedResources.invokeInterface(["nested", "mirror"], "read",
    [borrowComponentResource(nestedOwner)])[0].bits == 42
  dropComponentResource(nestedOwner)
  let projectedOwner = nestedResources.invokeInterface(["projected", "inner"], "make", [])[0]
  doAssert nestedResources.invokeInterface(["projected", "inner"], "read",
    [borrowComponentResource(projectedOwner)])[0].bits == 42
  dropComponentResource(projectedOwner)
  closeComponent(nestedResources)
  let typedNested = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(81)))))
  doAssert typedNested.invoke("run", [])[0].bits == 42
  closeComponent(typedNested)
  let projectedNested = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(82)))))
  doAssert projectedNested.invokeInterface(["api", "inner"], "run", [])[0].bits == 42
  try:
    discard projectedNested.invokeInterface(["api", "inner"], "extra", [])
    doAssert false, "exposed a nested function outside its annotation"
  except ComponentError as error:
    doAssert "unknown component interface function" in error.msg
  closeComponent(projectedNested)
  for i, diagnostic in ["component instantiation resource equality mismatch",
                        "component import provider lacks nested interface export: methods",
                        "component import function type mismatch: get"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(83 + i))))
      doAssert false, "accepted an incompatible nested instance"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let nestedHostPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(86))))
  let readClock: ComponentHostFunc =
    proc(args: openArray[ComponentValue]): seq[ComponentValue] = @[componentValue(cpU32, 42)]
  let clockInterface = ComponentHostInterface(name: "clock", functions: @[
    ComponentHostBinding(name: "read", signature: ComponentFuncType(
      hasResult: true, resultType: cpU32), callback: readClock)])
  let nestedHost = instantiateComponent(nestedHostPlan, [],
    interfaces = [ComponentHostInterface(name: "services", interfaces: @[clockInterface])])
  doAssert nestedHost.invoke("run", [])[0].bits == 42
  closeComponent(nestedHost)
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(87))))
    doAssert false, "accepted an oversized expanded instance surface"
  except ComponentError as error:
    doAssert "instance import surface limit" in error.msg, error.msg
  let lexicalResources = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(88)))))
  for _ in 0 .. 1:
    let values = lexicalResources.invoke("run", [])
    doAssert values.len == 1 and values[0].kind == cpU32 and values[0].bits == 42
  closeComponent(lexicalResources)
  for i, diagnostic in ["named component case payload type is not externally visible",
                        "component instantiation resource equality mismatch",
                        "outer type alias refers to a resource",
                        "outer type alias refers to a resource",
                        "named component parameter type is not externally visible",
                        "interface type refers to a name outside its component",
                        "interface import depends on an exported value type"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(89 + i))))
      doAssert false, "accepted an invalid outer resource alias"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  for i in 96 .. 97:
    let plan = decodeComponent(cast[seq[byte]](readFile(paramStr(i))))
    for _ in 0 .. 1:
      let instance = instantiateComponent(plan)
      doAssert instance.invoke("run", [])[0].bits == 42
      closeComponent(instance)
  let interfaceModulePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(98))))
  let directEngine = ComponentHostCoreModule(name: "engine",
    bytes: cast[seq[byte]](readFile(paramStr(99))))
  let nestedEngine = ComponentHostCoreModule(name: "engine",
    bytes: cast[seq[byte]](readFile(paramStr(100))))
  for (modules, diagnostic) in [
      (newSeq[ComponentHostCoreModule](), "unresolved core module import: engine"),
      (@[nestedEngine, nestedEngine], "duplicate host core module: engine"),
      (@[ComponentHostCoreModule(name: "engine")], "invalid embedded core module")]:
    let port = ComponentHostInterface(name: "port", coreModules: modules)
    try:
      discard instantiateComponent(interfaceModulePlan, [],
        interfaces = [ComponentHostInterface(name: "service", interfaces: @[port])],
        coreModules = [directEngine])
      doAssert false, "accepted an invalid nested host module"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let port = ComponentHostInterface(name: "port", coreModules: @[nestedEngine])
  let suppliedModules = instantiateComponent(interfaceModulePlan, [],
    interfaces = [ComponentHostInterface(name: "service", interfaces: @[port])],
    coreModules = [directEngine])
  doAssert suppliedModules.invoke("run", [])[0].bits == 42
  closeComponent(suppliedModules)
  for i, diagnostic in ["core module lacks export: decoy", "unknown core module export: decoy",
                        "invalid core export alias",
                        "component import provider lacks interface core module: engine"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(101 + i))))
      doAssert false, "accepted an invalid interface core module"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let interfaceComponentPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(105))))
  for _ in 0 .. 1:
    let instance = instantiateComponent(interfaceComponentPlan)
    doAssert instance.invoke("run", [])[0].bits == 42
    doAssert instance.invoke("run", [])[0].bits == 43
    doAssert instance.invoke("run-second", [])[0].bits == 42
    doAssert instance.invoke("run-control", [])[0].bits == 85
    closeComponent(instance)
  let interfaceComponentSmall = instantiateComponent(decodeComponent(
    cast[seq[byte]](readFile(paramStr(106)))))
  doAssert interfaceComponentSmall.invoke("run", [])[0].bits == 42
  closeComponent(interfaceComponentSmall)
  let interfaceComponentHost = decodeComponent(cast[seq[byte]](readFile(paramStr(107))))
  let directTask = ComponentHostDefinition(name: "task",
    plan: decodeComponent(cast[seq[byte]](readFile(paramStr(108)))))
  let nestedTask = ComponentHostDefinition(name: "task",
    plan: decodeComponent(cast[seq[byte]](readFile(paramStr(109)))))
  let emptyTask = decodeComponent([0x00'u8, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00])
  for (definitions, diagnostic) in [
      (newSeq[ComponentHostDefinition](), "unresolved component definition: task"),
      (@[nestedTask, nestedTask], "duplicate host component definition: task"),
      (@[ComponentHostDefinition(name: "task")], "unvalidated host component definition: task"),
      (@[ComponentHostDefinition(name: "task", plan: emptyTask)],
       "component import provider lacks function export: run")]:
    let port = ComponentHostInterface(name: "port", components: definitions)
    try:
      discard instantiateComponent(interfaceComponentHost, [],
        interfaces = [ComponentHostInterface(name: "package", interfaces: @[port])],
        components = [directTask])
      doAssert false, "accepted an invalid nested host definition"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let taskPort = ComponentHostInterface(name: "port", components: @[nestedTask])
  let suppliedTasks = instantiateComponent(interfaceComponentHost, [],
    interfaces = [ComponentHostInterface(name: "package", interfaces: @[taskPort])],
    components = [directTask])
  doAssert suppliedTasks.invoke("run", [])[0].bits == 42
  doAssert suppliedTasks.invoke("run-direct", [])[0].bits == 21
  closeComponent(suppliedTasks)
  for i, diagnostic in ["component import provider lacks function export: extra",
                        "unknown component definition export: hidden",
                        "unknown component instance function: extra",
                        "component import provider lacks interface component: task",
                        "component contract nesting limit"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(110 + i))))
      doAssert false, "accepted an invalid component-valued instance member"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let capturePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(115))))
  let capturedWorkerA = ComponentHostDefinition(name: "worker",
    plan: decodeComponent(cast[seq[byte]](readFile(paramStr(118)))))
  let capturedWorkerB = ComponentHostDefinition(name: "worker",
    plan: decodeComponent(cast[seq[byte]](readFile(paramStr(120)))))
  let captureEngineA = ComponentHostCoreModule(name: "engine",
    bytes: cast[seq[byte]](readFile(paramStr(117))))
  let captureEngineB = ComponentHostCoreModule(name: "engine",
    bytes: cast[seq[byte]](readFile(paramStr(119))))
  let capturedA = instantiateComponent(capturePlan, [], components = [capturedWorkerA],
    coreModules = [captureEngineA])
  let capturedB = instantiateComponent(capturePlan, [], components = [capturedWorkerB],
    coreModules = [captureEngineB])
  doAssert capturedA.invoke("run", [])[0].bits == 42
  doAssert capturedB.invoke("run", [])[0].bits == 85
  doAssert capturedA.invoke("run", [])[0].bits == 43
  doAssert capturedA.invoke("run-second", [])[0].bits == 42
  doAssert capturedB.invoke("run-second", [])[0].bits == 85
  closeComponent(capturedA)
  closeComponent(capturedB)
  let smallCapture = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(116)))),
    [], components = [capturedWorkerA])
  doAssert smallCapture.invoke("run", [])[0].bits == 22
  closeComponent(smallCapture)
  for i, diagnostic in ["unknown core module value", "unknown component definition"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(121 + i))))
      doAssert false, "accepted an out-of-scope outer definition"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let smallModuleCapture = instantiateComponent(
    decodeComponent(cast[seq[byte]](readFile(paramStr(123)))), [], coreModules = [captureEngineA])
  doAssert smallModuleCapture.invoke("run", [])[0].bits == 20
  closeComponent(smallModuleCapture)
  let functionEquality = instantiateComponent(
    decodeComponent(cast[seq[byte]](readFile(paramStr(124)))))
  doAssert functionEquality.invoke("run", [])[0].bits == 42
  doAssert functionEquality.invoke("direct", [componentRecord([componentValue(cpU32, 41)])])[0].bits == 42
  closeComponent(functionEquality)
  let scalarFunctionEquality = instantiateComponent(
    decodeComponent(cast[seq[byte]](readFile(paramStr(125)))))
  doAssert scalarFunctionEquality.invoke("run", [])[0].bits == 42
  closeComponent(scalarFunctionEquality)
  let nominalFunctionEquality = instantiateComponent(
    decodeComponent(cast[seq[byte]](readFile(paramStr(126)))))
  closeComponent(nominalFunctionEquality)
  for i, diagnostic in ["named component parameter type is not externally visible",
                        "component instantiation function type mismatch: signature",
                        "component instantiation function resource type mismatch: signature",
                        "function type export annotation mismatch"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(127 + i))))
      doAssert false, "accepted an invalid equality-bound function type"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  for i in 131 .. 132:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    let instance = instantiateComponent(decodeComponent(bytes))
    let answer = instance.invoke("run", [])
    doAssert answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
    closeComponent(instance)
  for i, diagnostic in ["component import function type mismatch: run",
                        "component import provider lacks function export: extra",
                        "component instantiation argument sort mismatch",
                        "unknown component instance function: extra"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(133 + i))))
      doAssert false, "accepted an invalid equality-bound component type"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let resourceContract = decodeComponent(cast[seq[byte]](readFile(paramStr(137))))
  closeComponent(instantiateComponent(resourceContract))
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(138))))
    doAssert false, "accepted a different abstract resource for an equality-bound export"
  except ComponentError as error:
    doAssert "component import resource export type mismatch: second" in error.msg, error.msg
  let namedContract = decodeComponent(cast[seq[byte]](readFile(paramStr(139))))
  closeComponent(instantiateComponent(namedContract))
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(140))))
    doAssert false, "accepted a contract function that uses an external record name"
  except ComponentError as error:
    doAssert "named component result type is not externally visible" in error.msg, error.msg
  for i in 141 .. 143:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    let instance = instantiateComponent(decodeComponent(bytes))
    if i < 143:
      let answer = instance.invoke("run", [])
      doAssert answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
    closeComponent(instance)
  discard decodeComponent(cast[seq[byte]](readFile(paramStr(144))))
  for i, diagnostic in ["component import provider lacks interface function: extra",
                        "component import function type mismatch: read",
                        "component import resource export type mismatch: resource",
                        "component import resource export type mismatch: token",
                        "local resource type found in export but not exported itself",
                        "component import resource export type mismatch: token",
                        "component import resource export type mismatch: token"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(145 + i))))
      doAssert false, "accepted an invalid equality-bound instance type"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  for i in 152 .. 154:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    let instance = instantiateComponent(decodeComponent(bytes))
    if i < 154:
      let answer = instance.invoke("run", [])
      doAssert answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
    closeComponent(instance)
  for i, diagnostic in ["component import resource export type mismatch: ticket",
                        "component instantiation resource equality mismatch",
                        "resource parameter type is not exported",
                        "local resource type found in export but not exported itself",
                        "component import resource export type mismatch: ticket",
                        "component import resource export type mismatch: ticket"]:
    try:
      discard decodeComponent(cast[seq[byte]](readFile(paramStr(155 + i))))
      doAssert false, "accepted an invalid component type resource capture"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
  let resourceValuePlan = decodeComponent(cast[seq[byte]](readFile(paramStr(161))))
  let firstGraph = instantiateComponent(resourceValuePlan)
  let secondGraph = instantiateComponent(resourceValuePlan)
  doAssert firstGraph.invoke("run", [])[0].bits == 42
  closeComponent(firstGraph)
  doAssert secondGraph.invoke("run", [])[0].bits == 42
  closeComponent(secondGraph)
  for i in 162 .. 164:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    let instance = instantiateComponent(decodeComponent(bytes))
    doAssert instance.invoke("run", [])[0].bits == 42
    closeComponent(instance)
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(165))))
    doAssert false, "accepted a resource from another component instance"
  except ComponentError as error:
    doAssert "component instantiation resource equality mismatch" in error.msg, error.msg
  for i in 166 .. 169:
    let bytes = cast[seq[byte]](readFile(paramStr(i)))
    let instance = instantiateComponent(decodeComponent(bytes))
    let answer = instance.invoke("run", [])
    doAssert answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
    closeComponent(instance)
  let directCore = decodeComponent(cast[seq[byte]](readFile(paramStr(170))))
  let adjust = ComponentHostBinding(name: "adjust", signature: ComponentFuncType(
    params: @[cpBool], hasResult: true, resultType: cpU32),
    callback: proc(args: openArray[ComponentValue]): seq[ComponentValue] =
      doAssert args.len == 1 and args[0].kind == cpBool and args[0].bits == 1
      @[componentValue(cpU32, 42)])
  let directInstance = instantiateComponent(directCore, [adjust])
  doAssert directInstance.invoke("run", [componentValue(cpU32, 2)])[0].bits == 42
  closeComponent(directInstance)
  let staged = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(171)))))
  doAssert staged.invoke("run", [])[0].bits == 42
  closeComponent(staged)
  var generatedDrops: seq[uint64]
  let observeGeneratedDrop = ComponentHostBinding(name: "observe",
    signature: ComponentFuncType(params: @[cpU32]),
    callback: proc(args: openArray[ComponentValue]): seq[ComponentValue] =
      generatedDrops.add(args[0].bits))
  let lifecycle = instantiateComponent(
    decodeComponent(cast[seq[byte]](readFile(paramStr(172)))), [observeGeneratedDrop])
  dropComponentResource(lifecycle.invoke("make", [componentValue(cpU32, 42)])[0])
  dropComponentResource(lifecycle.invoke("make-linked", [componentValue(cpU32, 85)])[0])
  doAssert generatedDrops == @[42'u64, 85'u64]
  try:
    discard lifecycle.invoke("trap", [])
    doAssert false, "post-return called a generated canonical lowering"
  except ComponentError as error:
    doAssert "canonical host call during realloc or post-return" in error.msg, error.msg
  doAssert generatedDrops == @[42'u64, 85'u64]
  let generatedAllocPlan = decodeComponent(cast[seq[byte]](readFile(paramStr(173))))
  var allocatorCalls = 0
  let generatedAllocator = ComponentHostBinding(name: "allocate",
    signature: ComponentFuncType(params: @[cpU32, cpU32, cpU32, cpU32],
      hasResult: true, resultType: cpU32),
    callback: proc(args: openArray[ComponentValue]): seq[ComponentValue] =
      inc allocatorCalls
      @[componentValue(cpU32, 64)])
  let generatedText = ComponentHostBinding(name: "text",
    signature: ComponentFuncType(hasResult: true, resultType: cpString),
    callback: proc(args: openArray[ComponentValue]): seq[ComponentValue] =
      @[componentString("Ox64")])
  for (name, args) in [("trap-in-lift", @[componentString("Ox64")]),
                       ("trap-in-lower", newSeq[ComponentValue]())]:
    let reallocInstance = instantiateComponent(generatedAllocPlan, [generatedAllocator, generatedText])
    try:
      discard reallocInstance.invoke(name, args)
      doAssert false, "realloc called a generated canonical lowering"
    except ComponentError as error:
      doAssert "canonical host call during realloc or post-return" in error.msg, error.msg
  doAssert allocatorCalls == 0
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(174))))
    doAssert false, "canonical lift accepted the wrong generated core signature"
  except ComponentError as error:
    doAssert "canonical function type mismatch" in error.msg, error.msg
  let crossPost = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(175)))))
  doAssert crossPost.invoke("run", [])[0].bits == 42
  closeComponent(crossPost)
  for i, diagnostic in ["unreachable", "linear memory range out of bounds"]:
    let trapped = instantiateComponent(
      decodeComponent(cast[seq[byte]](readFile(paramStr(176 + i)))))
    try:
      discard trapped.invoke("run", [])
      doAssert false, "cross-component ABI call did not trap"
    except ComponentError as error:
      doAssert diagnostic in error.msg, error.msg
    try:
      discard trapped.invoke("run", [])
      doAssert false, "cross-component ABI trap did not lock its store"
    except ComponentError as error:
      doAssert "component store locked after trap" in error.msg, error.msg
  let tagRelay = instantiateComponent(decodeComponent(cast[seq[byte]](readFile(paramStr(178)))))
  doAssert tagRelay.invoke("run", [])[0].bits == 42
  closeComponent(tagRelay)
  try:
    discard decodeComponent(cast[seq[byte]](readFile(paramStr(179))))
    doAssert false, "accepted a typed core tag with the wrong payload"
  except ComponentError as error:
    doAssert "core module export type mismatch: t" in error.msg, error.msg
  echo "component scalar ABI:ok"

main()
