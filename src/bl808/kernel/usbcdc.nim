## USB CDC ACM using the BL808 controller's virtual DMA channels.

when defined(bl808UsbPioModel):
  import ./usbcdc_pio
  export usbcdc_pio
elif defined(bl808m0):
  import ./clock, ./runtime, ./sched, ./usbdev, ./usb_anchor_serial

  const
    CdcSetLineCoding* = 0x20'u8
    CdcGetLineCoding* = 0x21'u8
    CdcSetCtrlLineState* = 0x22'u8

  type UsbCdc* = ref object
    receiver: CpsFuture[uint8]

  var instance: UsbCdc

  proc state(): UsbDevState =
    if configured(): usbConfigured
    elif addressed(): usbAddressed
    else: usbDefault

  proc poll(now: uint64): uint64 =
    pollUsbAnchorSerial()
    var b: uint8
    if instance.receiver != nil and tryRecvUsb(b):
      let pending = move(instance.receiver)
      complete(pending, b)
    now + usToTicks(250)

  proc initUsbCdc*(): UsbCdc =
    ## Call after schedulerInit. One hardware CDC controller is available.
    if instance == nil:
      instance = UsbCdc()
      let added = addSchedulerTimedPollHook(poll, readTick() + 1)
      if not added:
        instance = nil
        raise newException(IOError, "No USB scheduler poll hook available")
      initUsbAnchorSerial(cdc = true)
      usbDevSetStateProvider(state)
    instance

  proc trySend*(cdc: UsbCdc; data: openArray[uint8]): bool =
    ## Queue all bytes or report backpressure.
    trySendUsb(data)

  proc send*(cdc: UsbCdc; data: openArray[uint8]) =
    ## Best-effort send. Use trySend when the caller needs backpressure.
    discard cdc.trySend(data)

  proc sendByte*(cdc: UsbCdc; b: uint8) =
    cdc.send([b])

  proc sendString*(cdc: UsbCdc; s: string) =
    if s.len != 0:
      let bytes = cast[ptr UncheckedArray[uint8]](unsafeAddr s[0])
      cdc.send(bytes.toOpenArray(0, s.high))

  proc sendLine*(cdc: UsbCdc; s: string) =
    if s.len > usbTxFree() - 2: return
    cdc.sendString(s)
    cdc.send([13'u8, 10])

  proc recv*(cdc: UsbCdc): CpsFuture[uint8] =
    if cdc.receiver != nil:
      return failedLocalFuture[uint8](newException(IOError, "USB CDC receive in progress"))
    var b: uint8
    if tryRecvUsb(b): return completedLocalFuture(b)
    let pending = newLocalCpsFuture[uint8]()
    cdc.receiver = pending
    pending.addCallback proc() =
      if pending.isCancelled and cdc.receiver == pending: cdc.receiver = nil
    pending
else:
  {.error: "Native USB CDC virtual DMA is supported on M0".}
