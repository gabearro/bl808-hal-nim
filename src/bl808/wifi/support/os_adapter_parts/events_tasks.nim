## Sleep, event group, event notification, and task adapter callbacks.

proc osMsleep(ms: clong): cint {.cdecl.} =
  let deadline = readMtimeUs() + uint64(ms) * 1000'u64
  while int64(readMtimeUs() - deadline) < 0:
    vendorPollOnce()
    delayMtimeUs(100)
  0

proc osSleep(seconds: cuint): cint {.cdecl.} = osMsleep(clong(seconds) * 1000)

proc osEventGroupCreate(): pointer {.cdecl.} = c_calloc(1, sizeof(SimpleEventGroup).csize_t)
proc osEventGroupDelete(event: pointer) {.cdecl.} = c_free(event)
proc osEventGroupSend(event: pointer; bits: uint32): uint32 {.cdecl.} =
  if event == nil: return 0
  let g = cast[ptr SimpleEventGroup](event)
  g.bits = g.bits or bits
  g.bits
proc osEventGroupWait(event: pointer; bitsToWaitFor: uint32; clearOnExit, waitForAll: cint;
                      blockTimeTick: uint32): uint32 {.cdecl.} =
  if event == nil:
    return 0
  let g = cast[ptr SimpleEventGroup](event)
  var loops = if blockTimeTick != 0: blockTimeTick * 64'u32 else: 1'u32
  while blockTimeTick == BlOsWaitingForever or loops != 0:
    let bits = g.bits and bitsToWaitFor
    let matched = if waitForAll != 0: bits == bitsToWaitFor else: bits != 0
    if matched:
      if clearOnExit != 0:
        g.bits = g.bits and not bitsToWaitFor
      return bits
    if blockTimeTick != BlOsWaitingForever:
      dec loops
    vendorPollOnce()
    rawDelay(128)
  0

proc osEventRegister(t: cint; cb, arg: pointer): cint {.cdecl.} =
  discard t; discard cb; discard arg; 0
proc osEventNotify(evt, value: cint): cint {.cdecl.} =
  discard evt; discard value; 0
proc osTaskCreate(name: cstring; entry: pointer; stackDepth: uint32; param: pointer;
                  prio: uint32; taskHandle: pointer): cint {.cdecl.} =
  discard name; discard entry; discard stackDepth; discard param; discard prio; discard taskHandle; 0
proc osTaskDelete(taskHandle: pointer) {.cdecl.} = discard taskHandle
proc osTaskGetCurrent(): pointer {.cdecl.} = cast[pointer](1)
proc osTaskNotifyCreate(): pointer {.cdecl.} = cast[pointer](1)
proc osTaskNotify(taskHandle: pointer) {.cdecl.} = discard taskHandle
proc osTaskWait(taskHandle: pointer; tick: uint32) {.cdecl.} =
  discard taskHandle
  discard osEventGroupWait(nil, 0, 0, 0, tick)
proc osNoopVoid() {.cdecl.} = discard
