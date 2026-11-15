type
  ChanProtectionTicket = object
    token: uint32
    ap, pending: bool
  ChanProtectionOperation = object
    source, destination: ChanSwitchContext
    tickets: array[MAX_VIFS, ChanProtectionTicket]
    serial: uint32
    active, building, finishing, accepted: bool

var
  chanProtection {.wifiCtrl.}: ChanProtectionOperation
  chanProtectionSerial {.wifiCtrl.}: uint32
  chanProtectionToken {.wifiCtrl.}: uint32
  chanProtectionScope {.wifiCtrl.}: uint32

proc chanProtectionTagged(param: pointer): bool =
  let value = cast[uint](param)
  value <= high(uint32).uint and (value.uint32 and 0x80000000'u32) != 0

proc chanProtectionActive(): bool = chanProtection.active

proc chanProtectionIdentityCurrent(serial: uint32): bool =
  chanProtection.active and serial != 0 and chanProtection.serial == serial and
    chanSwitchContextCurrent(chanProtection.destination) and
    (chanProtection.source.target == nil or
      chanSwitchContextCurrent(chanProtection.source))

proc chanProtectionCurrent(serial: uint32): bool =
  chanProtectionIdentityCurrent(serial) and
    (chanEnvView().scheduledCtxt == chanProtection.destination.target or
      chanEnvView().currentCtxt == chanProtection.destination.target)

proc chanProtectionSyncCounts() =
  var stations, accessPoints: uint8
  for ticket in chanProtection.tickets:
    if ticket.pending:
      if ticket.ap: inc accessPoints
      else: inc stations
  chanEnvView().scanDelayCount = stations
  chanEnvView().connlessDelayCount = accessPoints

proc chanProtectionInvalidate() =
  chanProtection = default(ChanProtectionOperation)
  chanEnvView().scanDelayCount = 0
  chanEnvView().connlessDelayCount = 0

proc chanProtectionCancel(target: pointer = nil): pointer {.discardable.} =
  if chanProtection.active and (target == nil or
      chanProtection.destination.target == target or
      chanProtection.source.target == target):
    result = chanProtection.destination.target
    chanProtectionInvalidate()

proc chanProtectionCancelSerial(serial: uint32) =
  if chanProtection.active and chanProtection.serial == serial:
    chanSwitchCancel(chanProtection.destination.target)

proc chanProtectionBegin(): uint32 =
  let source = chanSwitchCapture(chanEnvView().currentCtxt)
  let destination = chanSwitchCapture(chanEnvView().scheduledCtxt)
  if not source.captured or not destination.captured: return 0
  inc chanProtectionSerial
  if chanProtectionSerial == 0: inc chanProtectionSerial
  chanProtection = ChanProtectionOperation(source: source, destination: destination,
    serial: chanProtectionSerial, active: true, building: true)
  chanProtectionSyncCounts()
  chanProtectionSerial

proc chanProtectionReserve(serial: uint32; ap: bool): uint32 =
  if not chanProtectionCurrent(serial):
    chanProtectionCancelSerial(serial)
    return 0
  for ticket in chanProtection.tickets.mitems:
    if ticket.token != 0: continue
    chanProtectionToken = (chanProtectionToken + 1) and 0x7FFFFFFF'u32
    if chanProtectionToken == 0: inc chanProtectionToken
    result = chanProtectionToken or 0x80000000'u32
    ticket = ChanProtectionTicket(token: result, ap: ap, pending: true)
    chanProtectionSyncCounts()
    return
  chanSwitchCancel(chanProtection.destination.target)

proc chanProtectionSubmitted(serial, token: uint32; success: bool): bool =
  if not chanProtectionCurrent(serial):
    chanProtectionCancelSerial(serial)
    return false
  for ticket in chanProtection.tickets.mitems:
    if ticket.token != token: continue
    if success: chanProtection.accepted = true
    elif ticket.pending: ticket.pending = false
    chanProtectionSyncCounts()
    return true

proc chanProtectionFinishBuild(serial: uint32): int =
  ## -1 retired, 0 ready without TX, 1 waiting, 2 completed during submission.
  if not chanProtectionCurrent(serial):
    chanProtectionCancelSerial(serial)
    return -1
  chanProtection.building = false
  if chanEnvView().scanDelayCount != 0 or chanEnvView().connlessDelayCount != 0:
    return 1
  chanProtection.finishing = true
  if chanProtection.accepted: 2 else: 0

proc chanProtectionComplete(param: pointer; ap: bool; serial: var uint32): bool =
  if not chanProtectionTagged(param) or not chanProtection.active: return false
  let token = cast[uint](param).uint32
  for ticket in chanProtection.tickets.mitems:
    if ticket.token != token or ticket.ap != ap or not ticket.pending: continue
    if not chanProtectionCurrent(chanProtection.serial):
      chanSwitchCancel(chanProtection.destination.target)
      return false
    ticket.pending = false
    chanProtectionSyncCounts()
    if not chanProtection.building and not chanProtection.finishing and
        chanEnvView().scanDelayCount == 0 and chanEnvView().connlessDelayCount == 0:
      chanProtection.finishing = true
      serial = chanProtection.serial
      return true
    return false

proc chanProtectionAbandon(param: pointer) =
  if not chanProtectionTagged(param) or not chanProtection.active: return
  let token = cast[uint](param).uint32
  for ticket in chanProtection.tickets:
    if ticket.token == token and ticket.pending:
      chanSwitchCancel(chanProtection.destination.target)
      return

proc chanProtectionCallbackCurrent(): bool =
  chanProtectionScope == 0 or chanProtectionCurrent(chanProtectionScope)

proc chanProtectionSelectTarget(target: pointer): bool =
  if chanProtectionScope == 0: return true
  if not chanProtectionIdentityCurrent(chanProtectionScope): return false
  let destination = chanSwitchCapture(target)
  if not destination.captured: return false
  chanProtection.destination = destination
  true

proc chanProtectionResume(serial: uint32) =
  if not chanProtectionCurrent(serial):
    chanProtectionCancelSerial(serial)
    return
  if not chanProtection.finishing: return
  let previous = chanProtectionScope
  chanProtectionScope = serial
  defer:
    chanProtectionScope = previous
    if chanProtection.serial == serial: chanProtectionInvalidate()
  chan_pre_switch_channel()
