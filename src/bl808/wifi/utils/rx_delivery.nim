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
  let current = block:
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    defer:
      {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
      if (saved and 8) != 0: enableInterrupts()
    rxDeliveryCurrent(delivery)
  if not current:
    discard pbuf_free(packet)
    return rxDeliveryStale
  # Admission is complete; the callback runs with the incoming IRQ state.
  if delivery.input(packet, delivery.netif) != 0:
    inc nimFwDbgTcpipInputFail
    discard pbuf_free(packet)
    return rxInputRejected
  inc nimFwDbgTcpipInputOk
  rxDelivered
