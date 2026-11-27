import std/os
import cps/wasm/component

proc expect(result: ComponentEndpointResult, status: ComponentEndpointStatus, count: uint32) =
  doAssert result.status == status and result.count == count

proc load(path: string): ComponentInstance =
  instantiateComponent(decodeComponent(cast[seq[byte]](readFile(path))))

doAssert paramCount() == 2
let unit = load(paramStr(1))
let pair = newComponentEndpointPair(cpStream)
expect(pair.writable.writeComponentUnits(3), cesPending, 0)
doAssert unit.invoke("run", [pair.readable])[0].bits == 42
expect(pair.writable.pollComponentEndpoint(), cesCompleted, 3)
pair.writable.closeComponentEndpoint()
unit.closeComponent()

let typed = load(paramStr(2))
let values = newComponentEndpointPair(cpStream, cpString)
let reader = values.readable.hostEndpoint()
let offered = [componentString("one"), componentString("two"), componentString("three")]
expect(values.writable.writeComponentEndpoint(offered), cesPending, 0)
let part = reader.readComponentEndpoint(2)
expect(part, cesCompleted, 2)
doAssert part.values[0].text == "one" and part.values[1].text == "two"
let cancelled = values.writable.cancelComponentEndpoint()
expect(cancelled, cesCancelled, 2)
doAssert cancelled.values.len == 1 and cancelled.values[0].text == "three"
reader.closeComponentEndpoint()
expect(values.writable.pollComponentEndpoint(), cesDropped, 0)
values.writable.closeComponentEndpoint()

let ready = newComponentEndpointPair(cpStream, cpString)
let readyRead = ready.readable.hostEndpoint()
expect(readyRead.readComponentEndpoint(0), cesPending, 0)
expect(ready.writable.writeComponentEndpoint([]), cesCompleted, 0)
expect(readyRead.pollComponentEndpoint(), cesPending, 0)
expect(ready.writable.writeComponentEndpoint([componentString("ready")]), cesPending, 0)
expect(readyRead.pollComponentEndpoint(), cesCompleted, 0)
let item = readyRead.readComponentEndpoint()
expect(item, cesCompleted, 1)
doAssert item.values[0].text == "ready"
expect(ready.writable.pollComponentEndpoint(), cesCompleted, 1)
readyRead.closeComponentEndpoint()
ready.writable.closeComponentEndpoint()

let complex = typed.newComponentEndpointPair("consume-string", 0)
expect(complex.writable.writeComponentEndpoint([componentString("AéB")]), cesPending, 0)
doAssert typed.invoke("consume-string", [complex.readable])[0].bits == 233
expect(complex.writable.pollComponentEndpoint(), cesCompleted, 1)
complex.writable.closeComponentEndpoint()
for hostFirst in [false, true]:
  let guest = typed.invoke("make-string", [])[0].hostEndpoint()
  let copied = if hostFirst:
      expect(guest.readComponentEndpoint(), cesPending, 0)
      doAssert typed.invoke("produce-string", [])[0].bits == 0
      guest.pollComponentEndpoint()
    else:
      doAssert typed.invoke("produce-string", [])[0].bits == uint64.high
      guest.readComponentEndpoint()
  expect(copied, cesCompleted, 1)
  doAssert copied.values[0].text == "AéB"
  guest.closeComponentEndpoint()

let delayed = typed.newComponentEndpointPair("park", 0)
discard typed.invoke("park", [delayed.readable])
doAssert typed.invoke("poll", [])[0].bits == uint64.high
expect(delayed.writable.writeComponentUnits(1), cesCompleted, 1)
doAssert typed.invoke("poll", [])[0].bits == 0x10
delayed.writable.closeComponentEndpoint()
doAssert typed.invoke("poll", [])[0].bits == 1

let resource = typed.newComponentEndpointPair("consume", 0)
let ticket = typed.invoke("new", [componentValue(cpU32, 42)])[0]
expect(resource.writable.writeComponentEndpoint([ticket]), cesPending, 0)
try:
  ticket.dropComponentResource()
  doAssert false, "the host buffer retained an alias to the original owner"
except ComponentError: discard
let returned = resource.writable.cancelComponentEndpoint()
expect(returned, cesCancelled, 0)
expect(resource.writable.writeComponentEndpoint(returned.values), cesPending, 0)
discard typed.invoke("consume", [resource.readable])
expect(resource.writable.pollComponentEndpoint(), cesCompleted, 1)
doAssert typed.invoke("sum", [])[0].bits == 42
resource.writable.closeComponentEndpoint()

let nested = typed.newComponentEndpointPair("nested-type", 0)
let inner = newComponentEndpointPair(cpFuture, cpString)
let original = inner.readable.hostEndpoint()
expect(nested.writable.writeComponentEndpoint([inner.readable]), cesPending, 0)
try:
  discard original.pollComponentEndpoint()
  doAssert false, "a buffered endpoint retained the previous owner"
except ComponentError: discard
let nestedReader = nested.readable.hostEndpoint()
let taken = nestedReader.readComponentEndpoint()
expect(taken, cesCompleted, 1)
let moved = taken.values[0].hostEndpoint()
expect(inner.writable.writeComponentEndpoint([componentString("nested")]), cesPending, 0)
doAssert moved.readComponentEndpoint().values[0].text == "nested"
expect(inner.writable.pollComponentEndpoint(), cesCompleted, 1)
expect(nested.writable.pollComponentEndpoint(), cesCompleted, 1)
moved.closeComponentEndpoint()
inner.writable.closeComponentEndpoint()
nestedReader.closeComponentEndpoint()
nested.writable.closeComponentEndpoint()

let waiting = typed.newComponentEndpointPair("wait-number", 0)
let pending = typed.beginCallback("wait-number", [waiting.readable])
doAssert pending.pollCallback() == ccsCoreWaiting
expect(waiting.writable.writeComponentEndpoint([componentValue(cpU32, 42)]), cesCompleted, 1)
doAssert pending.pollCallback() == ccsComplete
doAssert pending.takeCallbackResult()[0].bits == 42
waiting.writable.closeComponentEndpoint()
typed.closeComponent()

let failed = load(paramStr(2))
let failedPair = failed.newComponentEndpointPair("park-transfer", 0)
let recoverable = newComponentEndpointPair(cpFuture, cpString)
let transfer = componentTuple([recoverable.readable, componentString("recover")])
discard failed.invoke("park-transfer", [failedPair.readable])
discard failed.invoke("arm-trap", [])
try:
  discard failedPair.writable.writeComponentEndpoint([transfer])
  doAssert false, "guest realloc should trap during host delivery"
except ComponentError: discard
let recovered = failedPair.writable.pollComponentEndpoint()
expect(recovered, cesDropped, 0)
doAssert recovered.values.len == 1 and recovered.values[0].fields[1].text == "recover"
let recoveredReader = recovered.values[0].fields[0].hostEndpoint()
expect(recoverable.writable.writeComponentEndpoint([componentString("restored")]), cesPending, 0)
doAssert recoveredReader.readComponentEndpoint().values[0].text == "restored"
expect(recoverable.writable.pollComponentEndpoint(), cesCompleted, 1)
recoveredReader.closeComponentEndpoint()
recoverable.writable.closeComponentEndpoint()
failedPair.writable.closeComponentEndpoint()
failed.closeComponent()

echo "Host endpoints PASS: waitables, suspension, transfer, cancellation, peer trap and owned payloads"
