## M0 forwards one snapshot packet per direction through existing IPC slots.
## The endpoint owns the transfer state, lease, restore and broker claim.

when not defined(wasmManagedMigration):
  {.error: "WASM migration relay requires wasmManagedMigration".}

import ./wasm_migration_wire

type
  RelayPacketState = enum
    relayIdle
    relayQueued
    relayInFlight
    relayReplyReady

  WasmMigrationRelayPacket* = object
    state: RelayPacketState
    requestLen: int
    request*: array[WasmMigrationWirePayloadBytes, byte]
    response*: array[WasmMigrationWireReplyBytes, byte]

  WasmMigrationRelay* = object
    packets: array[2, WasmMigrationRelayPacket]

proc wasmMigrationRelayPacket*(relay: var WasmMigrationRelay,
                                 sourceCoreBit: uint16): ptr WasmMigrationRelayPacket =
  case sourceCoreBit
  of 2: addr relay.packets[0]
  of 4: addr relay.packets[1]
  else: nil

proc processWasmMigrationRelay*(relay: var WasmMigrationRelay, request: openArray[byte],
                                 response: var openArray[byte], sourceCoreBit: uint16): int =
  var decoded: WasmMigrationWireRequest
  if response.len < WasmMigrationWireReplyBytes or
      not request.decodeWasmMigrationRequest(decoded):
    return 0
  var reply = WasmMigrationWireReply(status: mwsRelayPending,
    receiverEpoch: decoded.receiverEpoch, transferId: decoded.transferId)
  let packet = relay.wasmMigrationRelayPacket(sourceCoreBit)
  if packet == nil or not decoded.relayViaM0 or decoded.sourceCoreBit != sourceCoreBit:
    reply.status = mwsInvalid
    return reply.encodeWasmMigrationReply(response)
  if packet.state == relayReplyReady and packet.requestLen == request.len and
      equalMem(unsafeAddr request[0], addr packet.request[0], request.len):
    copyMem(addr response[0], addr packet.response[0], WasmMigrationWireReplyBytes)
    packet.state = relayIdle
    return WasmMigrationWireReplyBytes
  if packet.state in {relayIdle, relayReplyReady}:
    # A new packet from this source supersedes its undelivered reply. The
    # destination can answer repeated packets after an ambiguous delivery.
    copyMem(addr packet.request[0], unsafeAddr request[0], request.len)
    packet.requestLen = request.len
    packet.state = relayQueued
  reply.encodeWasmMigrationReply(response)

proc takeWasmMigrationRelayPacket*(packet: var WasmMigrationRelayPacket): int =
  if packet.state != relayQueued: return 0
  packet.state = relayInFlight
  packet.requestLen

proc finishWasmMigrationRelayPacket*(packet: var WasmMigrationRelayPacket, replyLen: int) =
  if packet.state != relayInFlight: return
  var decoded: WasmMigrationWireReply
  if replyLen == WasmMigrationWireReplyBytes and
      packet.response.decodeWasmMigrationReply(decoded) and decoded.status != mwsRelayPending:
    packet.state = relayReplyReady
  else:
    packet.state = relayIdle
