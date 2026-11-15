# A synchronous host upload retains its original descriptor and session identity.
# Nested uploads get independent tokens, which expire when their calls return.
type
  RxHostLease* = object
    descriptor: pointer
    generation, serial: uint32
    identity: RxStationIdentity
    valid: bool
  RxHostUploadScope = object
    previous: ptr RxHostUploadScope
    lease: RxHostLease
    claimed: bool

var rxHostActiveUpload: ptr RxHostUploadScope
var rxHostUploadSerial: uint32

template rxHostIrqSave(): uint32 =
  block:
    let saved = irqSave()
    {.emit: "asm volatile(\"\" ::: \"memory\");".}
    saved

template rxHostIrqRestore(saved: uint32) =
  {.emit: "asm volatile(\"\" ::: \"memory\");".}
  irqRestore(saved)

proc rxHostLeaseCurrent*(lease: RxHostLease): bool =
  let saved = rxHostIrqSave()
  defer: rxHostIrqRestore(saved)
  if not lease.valid or not rxUploadCurrent(lease.descriptor, lease.generation) or
      not rxIdentityCurrent(lease.identity):
    return false
  var scope = rxHostActiveUpload
  while scope != nil:
    if scope.lease.serial == lease.serial and
        scope.lease.descriptor == lease.descriptor and
        scope.lease.generation == lease.generation:
      return true
    scope = scope.previous
  false

proc captureRxHostLease*(descriptor: pointer; lease: var RxHostLease): bool =
  let saved = rxHostIrqSave()
  defer: rxHostIrqRestore(saved)
  let scope = rxHostActiveUpload
  if scope == nil or scope.lease.descriptor != descriptor or
      scope.claimed or not rxHostLeaseCurrent(scope.lease):
    return false
  scope.claimed = true
  lease = scope.lease
  true

proc rxHostForward(descriptor: pointer; generation, status: uint32;
                   header: pointer; offset: uint32; data: pointer;
                   extra: uint32): cint =
  var scope: RxHostUploadScope
  block:
    let saved = rxHostIrqSave()
    defer: rxHostIrqRestore(saved)
    let index = rxMpduDescIndex(descriptor)
    if index < 0 or not rxUploadCurrent(descriptor, generation) or
        not rxStationCurrent(descriptor):
      return -1
    var active = rxHostActiveUpload
    while active != nil:
      if active.lease.descriptor == descriptor and
          active.lease.generation == generation:
        return -1
      active = active.previous
    inc rxHostUploadSerial
    scope = RxHostUploadScope(previous: rxHostActiveUpload,
      lease: RxHostLease(descriptor: descriptor, generation: generation,
        serial: rxHostUploadSerial, identity: rxStationIdentities[index], valid: true))
    rxHostActiveUpload = addr scope
  defer:
    let saved = rxHostIrqSave()
    var link = addr rxHostActiveUpload
    while link[] != nil:
      if link[] == addr scope:
        link[] = scope.previous
        break
      link = addr link[].previous
    rxHostIrqRestore(saved)
  tcpip_stack_input(descriptor, status, header, offset, data, extra)

# Disconnect notification can arrive after the firmware peer is retired.
# Track epochs here without requiring that the peer is still marked valid.
type RxHostSession* = object
  vifEpoch, stationEpoch: uint32
  vif, station: uint8
  captured: bool

proc captureRxHostSession*(vif, station: uint8): RxHostSession =
  let saved = rxHostIrqSave()
  defer: rxHostIrqRestore(saved)
  if vif >= MAX_VIFS.uint8 or
      (station != 0xFF and station >= STA_MGMT_FREE_STAS.uint8):
    return
  let stationEpoch = if station == 0xFF: 0'u32 else: staDeleteEpoch(station)
  RxHostSession(vifEpoch: rxVifEpochs[vif], stationEpoch: stationEpoch,
    vif: vif, station: station, captured: true)

proc rxHostSessionCurrent*(session: RxHostSession): bool =
  let saved = rxHostIrqSave()
  defer: rxHostIrqRestore(saved)
  session.captured and rxVifEpochs[session.vif] == session.vifEpoch and
    (session.station == 0xFF or staDeleteEpoch(session.station) == session.stationEpoch)
