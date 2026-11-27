import std/os
import cps/wasm/component

let plan = decodeComponent(cast[seq[byte]](readFile(paramStr(1))))

proc checkPin(owner: ComponentValue) =
  var pinned = false
  try:
    owner.dropComponentResource()
  except ComponentError as error:
    pinned = error.msg == "cannot remove owned resource while borrowed"
  doAssert pinned

let instance = instantiateComponent(plan)
let owner = instance.invoke("new", [componentValue(cpU32, 42)])[0]
let call = instance.beginCallback("borrow",
  [owner.borrowComponentResource(), componentValue(cpU32, 0)])
doAssert call.pollCallback() == ccsYielded
checkPin(owner)
doAssert call.pollCallback() == ccsComplete
checkPin(owner)
let answer = call.takeCallbackResult()
doAssert answer.len == 1 and answer[0].kind == cpU32 and answer[0].bits == 42
owner.dropComponentResource()

let abandonedOwner = instance.invoke("new", [componentValue(cpU32, 42)])[0]
block:
  let abandoned = instance.beginCallback("borrow",
    [abandonedOwner.borrowComponentResource(), componentValue(cpU32, 0)])
  doAssert abandoned.pollCallback() == ccsYielded
  checkPin(abandonedOwner)
abandonedOwner.dropComponentResource()

let reborrowed = instance.invoke("new", [componentValue(cpU32, 42)])[0]
block:
  let abandoned = instance.beginCallback("borrow",
    [reborrowed.borrowComponentResource(), componentValue(cpU32, 10)])
  doAssert abandoned.pollCallback() == ccsWaiting
checkPin(reborrowed)
doAssert instance.pollComponentTasks()  # The nested task resolves, with delivery still pending.
checkPin(reborrowed)
let drain = instance.beginCallback("drain", [])
doAssert drain.pollCallback() == ccsWaiting
doAssert drain.pollCallback() == ccsComplete and drain.takeCallbackResult().len == 0
reborrowed.dropComponentResource()
closeComponent(instance)

let closing = instantiateComponent(plan)
let pending = closing.beginCallback("run", [componentValue(cpU32, 10)])
doAssert pending.pollCallback() == ccsWaiting and not pending.callbackResultReady()
closeComponent(closing)
var closed = false
try:
  discard pending.pollCallback()
except ComponentError as error:
  closed = error.msg == "component store locked after trap"
doAssert closed
echo "Component async borrows PASS: host pin, delivery, abandonment and graph cleanup"
