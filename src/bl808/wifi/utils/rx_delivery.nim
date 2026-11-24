type
  RxNetifDelivery = object
    lease: firmware.RxHostLease
    station: uint32
    vif: pointer
    netif: ptr Netif
    input: NetifInput
  RxDeliveryResult = enum
    rxDelivered, rxInputRejected, rxDeliveryStale

proc rxDeliveryCurrent(delivery: RxNetifDelivery): bool =
  # The caller masks IRQs through validation and capture of the callback.
  firmware.rxHostLeaseCurrent(delivery.lease) and
    rxVif(cast[pointer](addr wifi_hw), delivery.station) == delivery.vif and
    loadPtr(delivery.vif, BlVifDevOff) == cast[pointer](delivery.netif) and
    delivery.netif.input == delivery.input

proc deliverRxPacket(packet: ptr Pbuf;
                     delivery: RxNetifDelivery): RxDeliveryResult =
  when defined(bl808WifiDiagTcpPath):
    let tcp = observeTcpPath(packet.payload, packet.len.uint, packet.totLen.uint)
  when defined(bl808WifiDiagDhcpTxAttempts):
    let dhcp = observeDhcpRx(packet)
  let current = block:
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if (saved and 8) != 0: enableInterrupts()
    rxDeliveryCurrent(delivery)
  if not current:
    when defined(bl808WifiDiagTcpPath):
      logTcpPath(tcp, tcpRxRejected, rxDeliveryStale.ord.uint32)
    when defined(bl808WifiDiagDhcpTxAttempts):
      if dhcp.present: logDhcpRx(dhcp, rxDeliveryStale.ord.uint32, 0, 0)
    discard pbuf_free(packet)
    return rxDeliveryStale
  # Admission is complete; the callback runs with the incoming IRQ state.
  when defined(bl808WifiDiagDhcpTxAttempts):
    let dhcpBefore = if dhcp.present: dhcpRecvCount() else: 0'u32
  when defined(bl808WifiDiagTcpPath):
    logTcpPath(tcp, tcpRxHandoff)
  let inputResult = delivery.input(packet, delivery.netif)
  when defined(bl808WifiDiagDhcpTxAttempts):
    if dhcp.present:
      let stage = if inputResult == 0: rxDelivered else: rxInputRejected
      logDhcpRx(dhcp, stage.ord.uint32, dhcpBefore, dhcpRecvCount())
  if inputResult != 0:
    when defined(bl808WifiDiagTcpPath):
      logTcpPath(tcp, tcpRxRejected, cast[uint32](inputResult.int32))
    inc nimFwDbgTcpipInputFail
    discard pbuf_free(packet)
    return rxInputRejected
  inc nimFwDbgTcpipInputOk
  rxDelivered
