const PmMaxNodes = 32

type
  PmRunState = enum
    pmInited, pmStop, pmStart, pmStopped, pmRunning
  PmNode = object
    event: cint
    code, capBit: uint32
    priority: uint16
    ops: PmCb
    arg: pointer
    enabled: bool

var
  pmInitialized: bool
  pmState: PmRunState
  pmWlanCapacity, pmSleepingCapacity: uint32
  pmNodes: array[PmMaxNodes, PmNode]
  pmNodeCount: int

proc pmEventIndex(event: PmEvent): int {.inline.} =
  cast[cint](event).int

proc bl_pm_init*(): cint {.exportc, cdecl.} =
  if pmInitialized:
    return 0
  pmNodeCount = 0
  pmWlanCapacity = 0
  pmSleepingCapacity = 0
  pmState = pmInited
  pmInitialized = true
  0

proc bl_pm_deinit*(): cint {.exportc, cdecl.} =
  if not pmInitialized:
    return -1
  if pmSleepingCapacity != 0:
    pmState = pmStop
    return -1  # Keep wake callbacks registered until the sleeping MAC unwinds.
  pmNodeCount = 0
  pmWlanCapacity = 0
  pmInitialized = false
  0

proc bl_pm_state_run*(): cint {.exportc, cdecl.} =
  if not pmInitialized:
    return -1
  case pmState
  of pmStart:
    pmState = pmRunning
    discard pm_post_event(cast[PmEvent](0), 2'u32, nil)
    0
  of pmRunning:
    0
  of pmStop:
    pmState = pmStopped
    discard pm_post_event(cast[PmEvent](0), 3'u32, nil)
    -1
  of pmInited, pmStopped:
    -1

proc bl_pm_capacity_set*(level: PmLevel): cint {.exportc, cdecl.} =
  if not pmInitialized:
    return -1
  let capacity =
    case cast[cint](level)
    of 1: 0x03'u32
    of 2: 0x33'u32
    of 3: 0x2F'u32
    of 4: 0x1F'u32
    of 5: 0x0E'u32
    of 6: 0x06'u32
    else: return -1
  pmWlanCapacity = capacity
  0

proc bl_pm_event_register*(event: PmEvent; code, capBit: uint32; priority: uint16;
                           ops: PmCb; arg: pointer; enable: PmEventAble): cint
    {.exportc, cdecl.} =
  let eventId = pmEventIndex(event)
  if not pmInitialized or eventId < 0 or eventId >= 6 or
      pmNodeCount == PmMaxNodes:
    return -1
  var insertAt = 0
  while insertAt < pmNodeCount and
      (pmNodes[insertAt].event < eventId or
       (pmNodes[insertAt].event == eventId and
        pmNodes[insertAt].priority <= priority)):
    inc insertAt
  var moveAt = pmNodeCount
  while moveAt > insertAt:
    pmNodes[moveAt] = pmNodes[moveAt - 1]
    dec moveAt
  pmNodes[insertAt] = PmNode(event: eventId.cint, code: code, capBit: capBit,
    priority: priority, ops: ops, arg: arg, enabled: cast[cint](enable) != 0)
  inc pmNodeCount
  0

proc bl_pm_event_switch*(event: PmEvent; code: uint32; enable: PmEventAble): cint
    {.exportc, cdecl.} =
  if not pmInitialized:
    return -1
  let eventId = pmEventIndex(event)
  var found = false
  for nodeIndex in 0 ..< pmNodeCount:
    let node = addr pmNodes[nodeIndex]
    if node.event == eventId and node.code == code:
      node.enabled = cast[cint](enable) != 0
      found = true
  if found: 0 else: -1

proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint
    {.exportc, cdecl.} =
  let eventId = pmEventIndex(event)
  if not pmInitialized or eventId < 0 or eventId >= 6:
    return -1
  if retval != nil:
    retval[] = 0
  let wake = eventId == 2 and code == 2
  if eventId == 1 and code == 1 and pmState == pmRunning:
    pmSleepingCapacity = pmWlanCapacity
  let completingSleep = wake and pmSleepingCapacity != 0
  let capacity = if completingSleep: pmSleepingCapacity else: pmWlanCapacity
  for nodeIndex in 0 ..< pmNodeCount:
    let node = pmNodes[nodeIndex]
    if node.event != eventId or node.code != code or not node.enabled or
        (capacity and node.capBit) == 0 or
        (0xFFFF'u32 and node.capBit) == 0:
      continue
    if eventId != 0 and pmState != pmRunning and not completingSleep:
      break
    if node.ops != nil and node.ops(node.arg) != 0:
      if retval != nil: retval[] = retval[] or 1'u32
      if wake: return 0  # Do not publish wake completion after a failed phase.
  if completingSleep: pmSleepingCapacity = 0
  if eventId == 0:
    case code
    of 0'u32:
      if pmState in {pmInited, pmStopped}:
        pmState = pmStart
    of 1'u32:
      if pmState == pmRunning:
        pmState = pmStop
    else:
      discard
  0
