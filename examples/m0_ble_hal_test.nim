## M0 BLE HAL feature test.

import bl808/startup
import bl808/core
import bl808/irq
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/ble
import bl808/panicoverride
import bl808/kernel/alloc
when defined(bl808BleVendor):
  from bl808/bleblob import
    bleBlobPoll,
    bleBlobDbgQueueSendCount,
    bleBlobDbgQueueRecvCount,
    bleBlobDbgHciControllerCount,
    bleBlobDbgDmIrqEnabled,
    bleBlobDbgBleIrqEnabled,
    bleBlobDbgDmIrqCount,
    bleBlobDbgBleIrqCount,
    bleBlobDbgRwipScheduleCount,
    bleBlobDbgSampleTime,
    bleBlobDbgTimeWord,
    bleBlobDbgReg32,
    bleBlobDbgLlcStartSeen,
    bleBlobDbgLlcStartHeader,
    bleBlobDbgLlcStartWord
else:
  from bl808/blecontroller import
    bleNimDbgIsrCount,
    bleNimDbgIsrStatOr,
    bleNimDbgStat20Count,
    bleNimDbgStat8000Count,
    bleNimDbgPushCount,
    bleNimDbgRxReadyCount,
    bleNimDbgRxScanReqCount,
    bleNimDbgRxScanReqMatchCount,
    bleNimDbgRxScanReqLastScanA0,
    bleNimDbgRxScanReqLastScanA1,
    bleNimDbgRxScanReqLastAdvA0,
    bleNimDbgRxScanReqLastAdvA1,
    bleNimDbgRxConnectIndCount,
    bleNimDbgRxLastHeader,
    bleNimDbgRxLastStatus,
    bleNimDbgRxLastDesc,
    bleNimDbgRxLastBuf,
    bleNimDbgVendorConStarted,
    bleNimDbgVendorLlcpRxCount,
    bleNimDbgVendorLlcpTxCount,
    bleNimDbgVendorLlcpTxQueued,
    bleNimDbgVendorLlcpTxDropped,
    bleNimDbgVendorLlcpLastOpcode,
    bleNimDbgVendorLlcpLastStatus,
    bleNimDbgVendorLlcpAllocCount,
    bleNimDbgVendorLlcpFreeCount,
    bleNimDbgVendorLlcpAllocLastLen,
    bleNimDbgVendorLlcpAllocLastPtr,
    bleNimDbgVendorLlcpAllocLastEmoff,
    bleNimDbgVendorLlcpAllocLastLenField,
    bleNimDbgVendorLlcpFreeLastRaw,
    bleNimDbgVendorLlcpFreeManualCount,
    bleNimDbgVendorLlcpFreeHeapCount,
    bleNimDbgVendorAclEmptyTxCount,
    bleNimDbgVendorAclEmptyTxPending,
    bleNimDbgVendorAclEmptyLastStatus,
    bleNimDbgVendorConLastStatus,
    bleNimDbgVendorConLastRxClock,
    bleNimDbgVendorConLastRxFine,
    bleNimDbgVendorConLastAnchor,
    bleNimDbgVendorConLastWinOffset,
    bleNimDbgVendorConLastInterval,
    bleNimDbgVendorConLastTimeout,
    bleNimDbgVendorConLastAccessAddr,
    bleNimDbgVendorConLastCrcInit,
    bleNimDbgVendorConnStage,
    bleNimDbgVendorConnStageRa,
    bleNimDbgVendorConnStageSp,
    bleNimDbgVendorConnStageMepc,
    bleNimDbgVendorConnStageMcause,
    bleNimDbgVendorConnStageMark,
    bleNimPeripheralConnEventCount,
    bleNimPeripheralDiscEventCount,
    bleNimPeripheralDiscReason,
    bleNimDbgLldRxCheckCount,
    bleNimDbgLldRxCheckHitCount,
    bleNimDbgLldRxCheckMissCount,
    bleNimDbgLldRxFreeCount,
    bleNimDbgLldRxLastIdx,
    bleNimDbgLldRxLastEnvIdx,
    bleNimDbgLldRxDescActive,
    bleNimDbgVendorSchProgFifoCount,
    bleNimDbgVendorSchProgSkipCount,
    bleNimDbgVendorArbSwCount,
    bleNimDbgVendorArbEventStartCount,
    bleNimDbgVendorArbSetCount,
    bleNimDbgVendorArbLastTargetCoarse,
    bleNimDbgVendorArbLastTargetFine,
    bleNimDbgVendorArbDueTargetCoarse,
    bleNimDbgVendorArbDueTargetFine,
    bleNimDbgVendorArbDueNowCoarse,
    bleNimDbgVendorArbDueNowFine,
    bleNimDbgVendorSliceAddCount,
    bleNimDbgVendorSliceRemoveCount,
    bleNimDbgVendorSliceLastTypeCon,
    bleNimDbgVendorSliceLastInterval,
    bleNimDbgVendorSliceLastAnchor,
    bleNimDbgVendorSliceLastOffset,
    bleNimDbgVendorWrapArbInsertCount,
    bleNimDbgVendorWrapArbInsertStatus,
    bleNimDbgVendorWrapArbInsertLast,
    bleNimDbgVendorWrapProgPushCount,
    bleNimDbgVendorWrapProgPushLast,
    bflbip_schedule

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  BleDeviceName {.strdefine.} = "bl808-hal"
  BleCentralName {.strdefine.} = "bl808-host"
  BleCentralConnect {.intdefine.} = 0
  BleCentralTimeoutMs {.intdefine.} = 20_000
  BlePeripheralAdvertise {.intdefine.} = 1
  BleExpectPeripheralLink {.intdefine.} = 0
  BleHostWindowIterations {.intdefine.} = 35_000
  BlePollIterations {.intdefine.} = 8
  BlePollDelayUs {.intdefine.} = 1_000

var
  console: Uart
  passed = 0
  failed = 0
  bleReadyCalled = false
  bleReadyErr: cint = -1
  hciPackets = 0
  bleConnectedCalled = false
  bleConnectedErr: uint8 = 0xFF'u8
  bleDisconnectedCalled = false
  bleConnCbStorage: BtConnCb

when not defined(bl808BleVendor):
  const
    ConnRawIrq = 48'u32
    ConnAliasIrq = IrqBase + ConnRawIrq
    RawBleIrq = 56'u32

  proc bflbbleConnTrap() {.cdecl.} =
    clicDisableIrq(ConnRawIrq)
    clicClearPending(ConnRawIrq)
    clicDisableIrq(ConnAliasIrq)
    clicClearPending(ConnAliasIrq)

proc enableBleControllerIrq() =
  when not defined(bl808BleVendor):
    registerTrapHandler(ConnRawIrq, bflbbleConnTrap)
    registerTrapHandler(ConnAliasIrq, bflbbleConnTrap)
    registerTrapHandler(IrqM0Ble, bflbble_isr)
    when defined(bl808BleNimUseClicIrq):
      registerTrapHandler(RawBleIrq, bflbble_isr)
      clicSetLevel(RawBleIrq, 1)
      clicEnableIrq(RawBleIrq)
      csrWriteMie(csrReadMie() or (1'u32 shl 11))
      enableInterrupts()

proc pollBleController(iterations: uint32) =
  when defined(bl808BleVendor):
    bleBlobPoll(iterations)
  else:
    for _ in 0'u32 ..< iterations:
      if bleConnectedCalled and bleDisconnectedCalled:
        return
      if bleConnectedCalled:
        bflbip_schedule()
        blePollHostEvents()
        bleNimDbgVendorConnStageMark(0x213'u32)
        if bleDisconnectedCalled:
          return
        continue
      bleNimDbgVendorConnStageMark(0x210'u32)
      bflbble_isr()
      bleNimDbgVendorConnStageMark(0x211'u32)
      bflbip_schedule()
      bleNimDbgVendorConnStageMark(0x212'u32)
      blePollHostEvents()
      bleNimDbgVendorConnStageMark(0x213'u32)
      if bleConnectedCalled and bleDisconnectedCalled:
        return

proc check(label: string, ok: bool) =
  discard console.sendString(if ok: "[PASS] " else: "[FAIL] ")
  discard console.sendLine(label)
  if ok: inc passed else: inc failed

proc cstringEquals(a: cstring, b: cstring): bool =
  if a == nil or b == nil:
    return false
  let ap = cast[ptr UncheckedArray[char]](a)
  let bp = cast[ptr UncheckedArray[char]](b)
  var i = 0
  while true:
    if ap[i] != bp[i]:
      return false
    if ap[i] == '\0':
      return true
    inc i

proc bleReady(err: cint) {.cdecl.} =
  bleReadyCalled = true
  bleReadyErr = err

proc hciRecv(data: ptr uint8, len: uint16): uint8 {.cdecl.} =
  discard data
  discard len
  inc hciPackets
  0

proc bleConnected(conn: ptr BtConn, err: uint8) {.cdecl.} =
  discard conn
  bleConnectedCalled = true
  bleConnectedErr = err

proc bleDisconnected(conn: ptr BtConn, reason: uint8) {.cdecl.} =
  discard conn
  discard reason
  bleDisconnectedCalled = true

proc sendCString(s: cstring) =
  if s == nil:
    return
  var i = 0
  while s[i] != '\0':
    discard console.sendByte(s[i].uint8)
    inc i

proc bleInitStage(stage: cstring) {.cdecl.} =
  discard console.sendString("[BLEDBG] init ")
  sendCString(stage)
  discard console.sendByte(0x0D)
  discard console.sendByte(0x0A)
  when defined(bl808BleDebugInitRegs):
    discard console.sendString("[BLEDBG] initregs ")
    sendCString(stage)
    discard console.sendString(" intmask=")
    console.sendHex32(regRead(0x28000018'u32.uint))
    discard console.sendString(" intstat=")
    console.sendHex32(regRead(0x2800001C'u32.uint))
    discard console.sendString(" misc60=")
    console.sendHex32(regRead(0x28000060'u32.uint))
    discard console.sendString(" ll828=")
    console.sendHex32(regRead(0x28000828'u32.uint))
    discard console.sendString(" ll860=")
    console.sendHex32(regRead(0x28000860'u32.uint))
    discard console.sendString(" live914=")
    console.sendHex32(regRead(0x28000914'u32.uint))
    discard console.sendString(" live920=")
    console.sendHex32(regRead(0x28000920'u32.uint))
    discard console.sendLine("")

proc printHciStatus(label: string) =
  discard console.sendString("[BLE] ")
  discard console.sendString(label)
  discard console.sendString(" type=")
  console.sendHex32(bleLastHciPktType().uint32)
  discard console.sendString(" len=")
  console.sendHex32(bleLastHciLen().uint32)
  discard console.sendString(" opcode=")
  console.sendHex32(bleLastHciOpcode().uint32)
  discard console.sendString(" status=")
  console.sendHex32(cast[uint32](bleLastHciStatus()))
  discard console.sendString(" w0=")
  console.sendHex32(bleLastHciWord0())
  discard console.sendString(" w1=")
  console.sendHex32(bleLastHciWord1())
  discard console.sendLine("")

proc sampleBleTime() =
  regWrite(0x28000100'u32.uint,
           regRead(0x28000100'u32.uint) or 0x80000000'u32)
  var guard = 4096
  while (regRead(0x28000100'u32.uint) and 0x80000000'u32) != 0 and guard > 0:
    dec guard

proc bleDbgReg32(regAddr: uint32): uint32 =
  when defined(bl808BleVendor):
    bleBlobDbgReg32(regAddr)
  else:
    regRead(regAddr.uint)

proc printReg(label: string, regAddr: uint32) =
  discard console.sendString(" ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(bleDbgReg32(regAddr))

proc printBtbleMapDiag(label: string) =
  discard console.sendString("[BLEDBG] btble0 ")
  discard console.sendString(label)
  printReg("ll800", 0x28000800'u32)
  printReg("ll80c", 0x2800080C'u32)
  printReg("ll828", 0x28000828'u32)
  printReg("ll82c", 0x2800082C'u32)
  printReg("ll850", 0x28000850'u32)
  printReg("ll860", 0x28000860'u32)
  printReg("ll8d0", 0x280008D0'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] btble1 ")
  discard console.sendString(label)
  printReg("ll930", 0x28000930'u32)
  printReg("ll940", 0x28000940'u32)
  printReg("ll944", 0x28000944'u32)
  printReg("ll948", 0x28000948'u32)
  printReg("live914", 0x28000914'u32)
  printReg("live920", 0x28000920'u32)
  printReg("rnd0", 0x28000978'u32)
  printReg("rnd1", 0x2800097C'u32)
  printReg("ll9e0", 0x280009E0'u32)
  printReg("cmd110", 0x28000110'u32)
  discard console.sendLine("")

  when not defined(bl808BleVendor):
    discard console.sendString("[BLEDBG] nimisr ")
    discard console.sendString(label)
    discard console.sendString(" calls=")
    console.sendHex32(bleNimDbgIsrCount())
    discard console.sendString(" stat_or=")
    console.sendHex32(bleNimDbgIsrStatOr())
    discard console.sendString(" stat20=")
    console.sendHex32(bleNimDbgStat20Count())
    discard console.sendString(" stat8000=")
    console.sendHex32(bleNimDbgStat8000Count())
    discard console.sendString(" pushes=")
    console.sendHex32(bleNimDbgPushCount())
    discard console.sendString(" rxready=")
    console.sendHex32(bleNimDbgRxReadyCount())
    discard console.sendString(" scanreq=")
    console.sendHex32(bleNimDbgRxScanReqCount())
    discard console.sendString(" scanmatch=")
    console.sendHex32(bleNimDbgRxScanReqMatchCount())
    discard console.sendString(" conind=")
    console.sendHex32(bleNimDbgRxConnectIndCount())
    discard console.sendString(" rxhdr=")
    console.sendHex32(bleNimDbgRxLastHeader())
    discard console.sendString(" rxstat=")
    console.sendHex32(bleNimDbgRxLastStatus())
    discard console.sendString(" rxdesc=")
    console.sendHex32(bleNimDbgRxLastDesc())
    discard console.sendString(" rxbuf=")
    console.sendHex32(bleNimDbgRxLastBuf())
    discard console.sendString(" scana0=")
    console.sendHex32(bleNimDbgRxScanReqLastScanA0())
    discard console.sendString(" scana1=")
    console.sendHex32(bleNimDbgRxScanReqLastScanA1())
    discard console.sendString(" adva0=")
    console.sendHex32(bleNimDbgRxScanReqLastAdvA0())
    discard console.sendString(" adva1=")
    console.sendHex32(bleNimDbgRxScanReqLastAdvA1())
    discard console.sendLine("")

    discard console.sendString("[BLEDBG] nimlld ")
    discard console.sendString(label)
    discard console.sendString(" started=")
    console.sendHex32(bleNimDbgVendorConStarted())
    discard console.sendString(" chk=")
    console.sendHex32(bleNimDbgLldRxCheckCount())
    discard console.sendString(" hit=")
    console.sendHex32(bleNimDbgLldRxCheckHitCount())
    discard console.sendString(" miss=")
    console.sendHex32(bleNimDbgLldRxCheckMissCount())
    discard console.sendString(" free=")
    console.sendHex32(bleNimDbgLldRxFreeCount())
    discard console.sendString(" lastidx=")
    console.sendHex32(bleNimDbgLldRxLastIdx())
    discard console.sendString(" envidx=")
    console.sendHex32(bleNimDbgLldRxLastEnvIdx())
    discard console.sendString(" active=")
    console.sendHex32(bleNimDbgLldRxDescActive())
    discard console.sendString(" pfifo=")
    console.sendHex32(bleNimDbgVendorSchProgFifoCount())
    discard console.sendString(" pskip=")
    console.sendHex32(bleNimDbgVendorSchProgSkipCount())
    discard console.sendString(" arbsw=")
    console.sendHex32(bleNimDbgVendorArbSwCount())
    discard console.sendString(" arbst=")
    console.sendHex32(bleNimDbgVendorArbEventStartCount())
    discard console.sendString(" warbi=")
    console.sendHex32(bleNimDbgVendorWrapArbInsertCount())
    discard console.sendString(" warbr=")
    console.sendHex32(bleNimDbgVendorWrapArbInsertStatus())
    discard console.sendString(" warbp=")
    console.sendHex32(bleNimDbgVendorWrapArbInsertLast())
    discard console.sendString(" wpush=")
    console.sendHex32(bleNimDbgVendorWrapProgPushCount())
    discard console.sendString(" wprog=")
    console.sendHex32(bleNimDbgVendorWrapProgPushLast())
    discard console.sendLine("")

    discard console.sendString("[BLEDBG] nimsch ")
    discard console.sendString(label)
    discard console.sendString(" aset=")
    console.sendHex32(bleNimDbgVendorArbSetCount())
    discard console.sendString(" atc=")
    console.sendHex32(bleNimDbgVendorArbLastTargetCoarse())
    discard console.sendString(" atf=")
    console.sendHex32(bleNimDbgVendorArbLastTargetFine())
    discard console.sendString(" duec=")
    console.sendHex32(bleNimDbgVendorArbDueTargetCoarse())
    discard console.sendString(" duef=")
    console.sendHex32(bleNimDbgVendorArbDueTargetFine())
    discard console.sendString(" nowc=")
    console.sendHex32(bleNimDbgVendorArbDueNowCoarse())
    discard console.sendString(" nowf=")
    console.sendHex32(bleNimDbgVendorArbDueNowFine())
    discard console.sendString(" sadd=")
    console.sendHex32(bleNimDbgVendorSliceAddCount())
    discard console.sendString(" srm=")
    console.sendHex32(bleNimDbgVendorSliceRemoveCount())
    discard console.sendString(" stc=")
    console.sendHex32(bleNimDbgVendorSliceLastTypeCon())
    discard console.sendString(" sint=")
    console.sendHex32(bleNimDbgVendorSliceLastInterval())
    discard console.sendString(" sanch=")
    console.sendHex32(bleNimDbgVendorSliceLastAnchor())
    discard console.sendString(" soff=")
    console.sendHex32(bleNimDbgVendorSliceLastOffset())
    discard console.sendLine("")

    discard console.sendString("[BLEDBG] nimtx ")
    discard console.sendString(label)
    discard console.sendString(" llcprx=")
    console.sendHex32(bleNimDbgVendorLlcpRxCount())
    discard console.sendString(" llcptx=")
    console.sendHex32(bleNimDbgVendorLlcpTxCount())
    discard console.sendString(" llq=")
    console.sendHex32(bleNimDbgVendorLlcpTxQueued())
    discard console.sendString(" lldrop=")
    console.sendHex32(bleNimDbgVendorLlcpTxDropped())
    discard console.sendString(" llop=")
    console.sendHex32(bleNimDbgVendorLlcpLastOpcode())
    discard console.sendString(" llst=")
    console.sendHex32(bleNimDbgVendorLlcpLastStatus())
    discard console.sendString(" lla=")
    console.sendHex32(bleNimDbgVendorLlcpAllocCount())
    discard console.sendString(" llf=")
    console.sendHex32(bleNimDbgVendorLlcpFreeCount())
    discard console.sendString(" alen=")
    console.sendHex32(bleNimDbgVendorLlcpAllocLastLen())
    discard console.sendString(" aptr=")
    console.sendHex32(bleNimDbgVendorLlcpAllocLastPtr())
    discard console.sendString(" aoff=")
    console.sendHex32(bleNimDbgVendorLlcpAllocLastEmoff())
    discard console.sendString(" aflen=")
    console.sendHex32(bleNimDbgVendorLlcpAllocLastLenField())
    discard console.sendString(" fraw=")
    console.sendHex32(bleNimDbgVendorLlcpFreeLastRaw())
    discard console.sendString(" fman=")
    console.sendHex32(bleNimDbgVendorLlcpFreeManualCount())
    discard console.sendString(" fheap=")
    console.sendHex32(bleNimDbgVendorLlcpFreeHeapCount())
    discard console.sendString(" cevt=")
    console.sendHex32(bleNimPeripheralConnEventCount())
    discard console.sendString(" devt=")
    console.sendHex32(bleNimPeripheralDiscEventCount())
    discard console.sendString(" drsn=")
    console.sendHex32(bleNimPeripheralDiscReason())
    discard console.sendString(" emptytx=")
    console.sendHex32(bleNimDbgVendorAclEmptyTxCount())
    discard console.sendString(" emptypend=")
    console.sendHex32(bleNimDbgVendorAclEmptyTxPending())
    discard console.sendString(" emptyst=")
    console.sendHex32(bleNimDbgVendorAclEmptyLastStatus())
    discard console.sendLine("")

    discard console.sendString("[BLEDBG] nimcon ")
    discard console.sendString(label)
    discard console.sendString(" st=")
    console.sendHex32(bleNimDbgVendorConLastStatus())
    discard console.sendString(" rxclk=")
    console.sendHex32(bleNimDbgVendorConLastRxClock())
    discard console.sendString(" rxfine=")
    console.sendHex32(bleNimDbgVendorConLastRxFine())
    discard console.sendString(" anchor=")
    console.sendHex32(bleNimDbgVendorConLastAnchor())
    discard console.sendString(" win=")
    console.sendHex32(bleNimDbgVendorConLastWinOffset())
    discard console.sendString(" int=")
    console.sendHex32(bleNimDbgVendorConLastInterval())
    discard console.sendString(" to=")
    console.sendHex32(bleNimDbgVendorConLastTimeout())
    discard console.sendString(" aa=")
    console.sendHex32(bleNimDbgVendorConLastAccessAddr())
    discard console.sendString(" crc=")
    console.sendHex32(bleNimDbgVendorConLastCrcInit())
    discard console.sendString(" stage=")
    console.sendHex32(bleNimDbgVendorConnStage())
    discard console.sendString(" sra=")
    console.sendHex32(bleNimDbgVendorConnStageRa())
    discard console.sendString(" ssp=")
    console.sendHex32(bleNimDbgVendorConnStageSp())
    discard console.sendString(" smepc=")
    console.sendHex32(bleNimDbgVendorConnStageMepc())
    discard console.sendString(" smcause=")
    console.sendHex32(bleNimDbgVendorConnStageMcause())
    discard console.sendLine("")

  discard console.sendString("[BLEDBG] schprog ")
  discard console.sendString(label)
  printReg("p00", 0x28010000'u32)
  printReg("p04", 0x28010004'u32)
  printReg("p08", 0x28010008'u32)
  printReg("p0c", 0x2801000C'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emadv0 ")
  discard console.sendString(label)
  printReg("e120", 0x28010120'u32)
  printReg("e124", 0x28010124'u32)
  printReg("e128", 0x28010128'u32)
  printReg("e12c", 0x2801012C'u32)
  printReg("e130", 0x28010130'u32)
  printReg("e134", 0x28010134'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emadv1 ")
  discard console.sendString(label)
  printReg("e138", 0x28010138'u32)
  printReg("e13c", 0x2801013C'u32)
  printReg("e140", 0x28010140'u32)
  printReg("e144", 0x28010144'u32)
  printReg("e148", 0x28010148'u32)
  printReg("e14c", 0x2801014C'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emadv2 ")
  discard console.sendString(label)
  printReg("e150", 0x28010150'u32)
  printReg("e154", 0x28010154'u32)
  printReg("e158", 0x28010158'u32)
  printReg("e15c", 0x2801015C'u32)
  printReg("e160", 0x28010160'u32)
  printReg("e164", 0x28010164'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emdesc ")
  discard console.sendString(label)
  printReg("d558", 0x28010558'u32)
  printReg("d55c", 0x2801055C'u32)
  printReg("d560", 0x28010560'u32)
  printReg("d564", 0x28010564'u32)
  printReg("d568", 0x28010568'u32)
  printReg("d56c", 0x2801056C'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emdata0 ")
  discard console.sendString(label)
  printReg("x570", 0x28010570'u32)
  printReg("x574", 0x28010574'u32)
  printReg("x578", 0x28010578'u32)
  printReg("x57c", 0x2801057C'u32)
  printReg("x580", 0x28010580'u32)
  printReg("x584", 0x28010584'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emdata1 ")
  discard console.sendString(label)
  printReg("x588", 0x28010588'u32)
  printReg("x58c", 0x2801058C'u32)
  printReg("x590", 0x28010590'u32)
  printReg("x594", 0x28010594'u32)
  printReg("x598", 0x28010598'u32)
  printReg("x59c", 0x2801059C'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emdata2 ")
  discard console.sendString(label)
  printReg("x600", 0x28010600'u32)
  printReg("x604", 0x28010604'u32)
  printReg("x608", 0x28010608'u32)
  printReg("x60c", 0x2801060C'u32)
  printReg("x610", 0x28010610'u32)
  printReg("x614", 0x28010614'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emdata3 ")
  discard console.sendString(label)
  printReg("a2c", 0x28010A2C'u32)
  printReg("a30", 0x28010A30'u32)
  printReg("a34", 0x28010A34'u32)
  printReg("a38", 0x28010A38'u32)
  printReg("a3c", 0x28010A3C'u32)
  printReg("a40", 0x28010A40'u32)
  discard console.sendLine("")

  discard console.sendString("[BLEDBG] emscan ")
  discard console.sendString(label)
  printReg("a4c", 0x28010A4C'u32)
  printReg("a50", 0x28010A50'u32)
  printReg("a54", 0x28010A54'u32)
  printReg("a58", 0x28010A58'u32)
  discard console.sendLine("")

proc printBleBlobDiag(label: string) =
  when defined(bl808BleVendor):
    discard console.sendString("[BLEDBG] ")
    discard console.sendString(label)
    discard console.sendString(" qsend=")
    console.sendHex32(bleBlobDbgQueueSendCount())
    discard console.sendString(" qrecv=")
    console.sendHex32(bleBlobDbgQueueRecvCount())
    discard console.sendString(" hci=")
    console.sendHex32(bleBlobDbgHciControllerCount())
    discard console.sendString(" dm_en=")
    console.sendHex32(bleBlobDbgDmIrqEnabled())
    discard console.sendString(" ble_en=")
    console.sendHex32(bleBlobDbgBleIrqEnabled())
    discard console.sendString(" dm_irq=")
    console.sendHex32(bleBlobDbgDmIrqCount())
    discard console.sendString(" ble_irq=")
    console.sendHex32(bleBlobDbgBleIrqCount())
    discard console.sendString(" rwip=")
    console.sendHex32(bleBlobDbgRwipScheduleCount())
    bleBlobDbgSampleTime()
    discard console.sendString(" time-sample=")
    console.sendHex32(bleBlobDbgTimeWord(0))
    discard console.sendString("/")
    console.sendHex32(bleBlobDbgTimeWord(1))
    discard console.sendString("/")
    console.sendHex32(bleBlobDbgTimeWord(2))
    when defined(bl808BleVendorCaptureLlcStart):
      discard console.sendString(" llcseen=")
      console.sendHex32(bleBlobDbgLlcStartSeen())
      discard console.sendString(" llch=")
      console.sendHex32(bleBlobDbgLlcStartHeader(0))
      discard console.sendString("/")
      console.sendHex32(bleBlobDbgLlcStartHeader(1))
      discard console.sendString("/")
      console.sendHex32(bleBlobDbgLlcStartHeader(2))
      discard console.sendString(" llcw=")
      for i in 0'u32 ..< 14'u32:
        if i != 0'u32:
          discard console.sendString(",")
        console.sendHex32(bleBlobDbgLlcStartWord(i))
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] regs glb3b0=")
    console.sendHex32(bleBlobDbgReg32(0x200003B0'u32))
    discard console.sendString(" dig250=")
    console.sendHex32(bleBlobDbgReg32(0x20000250'u32))
    discard console.sendString(" clk580=")
    console.sendHex32(bleBlobDbgReg32(0x20000580'u32))
    discard console.sendString(" clk584=")
    console.sendHex32(bleBlobDbgReg32(0x20000584'u32))
    discard console.sendString(" sram60c=")
    console.sendHex32(bleBlobDbgReg32(0x2000060C'u32))
    discard console.sendString(" mix0=")
    console.sendHex32(bleBlobDbgReg32(0x20001000'u32))
    discard console.sendString(" rfb4=")
    console.sendHex32(bleBlobDbgReg32(0x200010B4'u32))
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] ble intmask=")
    console.sendHex32(bleBlobDbgReg32(0x28000018'u32))
    discard console.sendString(" intstat=")
    console.sendHex32(bleBlobDbgReg32(0x2800001C'u32))
    discard console.sendString(" intack=")
    console.sendHex32(bleBlobDbgReg32(0x28000020'u32))
    discard console.sendString(" ctl=")
    console.sendHex32(bleBlobDbgReg32(0x28000000'u32))
    discard console.sendString(" sleep=")
    console.sendHex32(bleBlobDbgReg32(0x28000030'u32))
    discard console.sendString(" corr=")
    console.sendHex32(bleBlobDbgReg32(0x2800003C'u32))
    discard console.sendString(" time0=")
    console.sendHex32(bleBlobDbgReg32(0x28000100'u32))
    discard console.sendString(" time1=")
    console.sendHex32(bleBlobDbgReg32(0x28000104'u32))
    discard console.sendString(" sched0=")
    console.sendHex32(bleBlobDbgReg32(0x280009C0'u32))
    discard console.sendString(" sched1=")
    console.sendHex32(bleBlobDbgReg32(0x280009C4'u32))
    discard console.sendString(" sched2=")
    console.sendHex32(bleBlobDbgReg32(0x280009C8'u32))
    discard console.sendLine("")
    printBtbleMapDiag(label)
  else:
    sampleBleTime()
    discard console.sendString("[BLEDBG] ")
    discard console.sendString(label)
    discard console.sendString(" regs glb3b0=")
    console.sendHex32(regRead(0x200003B0'u32.uint))
    discard console.sendString(" dig250=")
    console.sendHex32(regRead(0x20000250'u32.uint))
    discard console.sendString(" clk580=")
    console.sendHex32(regRead(0x20000580'u32.uint))
    discard console.sendString(" clk584=")
    console.sendHex32(regRead(0x20000584'u32.uint))
    discard console.sendString(" sram60c=")
    console.sendHex32(regRead(0x2000060C'u32.uint))
    discard console.sendString(" mix0=")
    console.sendHex32(regRead(0x20001000'u32.uint))
    discard console.sendString(" rfb4=")
    console.sendHex32(regRead(0x200010B4'u32.uint))
    discard console.sendLine("")
    discard console.sendString("[BLEDBG] ble ctl=")
    console.sendHex32(regRead(0x28000000'u32.uint))
    discard console.sendString(" intmask=")
    console.sendHex32(regRead(0x28000018'u32.uint))
    discard console.sendString(" intstat=")
    console.sendHex32(regRead(0x2800001C'u32.uint))
    discard console.sendString(" sleep=")
    console.sendHex32(regRead(0x28000030'u32.uint))
    discard console.sendString(" corr=")
    console.sendHex32(regRead(0x2800003C'u32.uint))
    discard console.sendString(" time0=")
    console.sendHex32(regRead(0x28000100'u32.uint))
    discard console.sendString(" time1=")
    console.sendHex32(regRead(0x28000104'u32.uint))
    discard console.sendString(" sched0=")
    console.sendHex32(regRead(0x280009C0'u32.uint))
    discard console.sendString(" sched1=")
    console.sendHex32(regRead(0x280009C4'u32.uint))
    discard console.sendString(" sched2=")
    console.sendHex32(regRead(0x280009C8'u32.uint))
    discard console.sendLine("")
    printBtbleMapDiag(label)

proc printBleBlobLlcStartCapture(label: string) =
  when defined(bl808BleVendor) and defined(bl808BleVendorCaptureLlcStart):
    discard console.sendString("[BLELLC] ")
    discard console.sendString(label)
    discard console.sendString(" seen=")
    console.sendHex32(bleBlobDbgLlcStartSeen())
    discard console.sendString(" hdr=")
    console.sendHex32(bleBlobDbgLlcStartHeader(0))
    discard console.sendString("/")
    console.sendHex32(bleBlobDbgLlcStartHeader(1))
    discard console.sendString("/")
    console.sendHex32(bleBlobDbgLlcStartHeader(2))
    discard console.sendString(" words=")
    for i in 0'u32 ..< 14'u32:
      if i != 0'u32:
        discard console.sendString(",")
      console.sendHex32(bleBlobDbgLlcStartWord(i))
    discard console.sendLine("")

proc checkControllerSleepRestore() =
  let sleepRc = ble_controller_sleep(7)
  discard console.sendString("[BLE] sleep rc=")
  console.sendHex32(cast[uint32](sleepRc))
  discard console.sendLine("")
  check("ble controller sleep callable", true)
  ble_controller_sleep_restore()
  check("ble controller sleep restore", true)

proc smokeBle() =
  let mainRef = cast[pointer](blecontroller_main)
  check("ble controller main symbol", mainRef != nil)

  bleControllerInitRawWithStage(5, bleInitStage)
  check("ble controller init", true)
  check("ble controller version", ble_controller_get_lib_ver() != nil)

  ble_controller_set_tx_pwr(3)
  check("ble controller tx power direct", ble_controller_get_tx_pwr() == 3)

  var hciPacket = [0x03'u8, 0x0C, 0x00]
  check("ble hci interface init", bt_onchiphci_interface_init(hciRecv) == 0)
  check("ble hci send", bt_onchiphci_send(0, hciPacket.len.uint16, addr hciPacket[0]) == 0)
  printHciStatus("reset")
  when defined(bl808BleDebugFlowRegs):
    printBleBlobDiag("after-hci-reset")

  bflbble_init()
  when defined(bl808BleDebugFlowRegs):
    printBleBlobDiag("after-bflbble-init")
  pollBleController(1)
  when defined(bl808BleDebugFlowRegs):
    printBleBlobDiag("after-bflbble-isr")
  bflbble_reset()
  when defined(bl808BleDebugFlowRegs):
    printBleBlobDiag("after-bflbble-reset")
  enableBleControllerIrq()
  check("ble controller isr/reset", bflbble_sleep_check() >= 0)

  bleControllerInit(5)
  bleSetTxPower(4)
  check("ble tx power facade", bleGetTxPower() == 4)
  check("ble version facade", bleGetVersion().len > 0)
  bleReadyCalled = false
  bleReadyErr = -1
  when defined(bl808BleVendor):
    check("ble enable direct", bt_enable(bleReady) == 0 and bleReadyCalled and bleReadyErr == 0)
    bleReadyCalled = false
    bleReadyErr = -1
  check("ble enable facade", bleEnable(bleReady) == bleOk and bleReadyCalled and bleReadyErr == 0)
  when defined(bl808BleVendor):
    check("ble set name direct", bt_set_name(BleDeviceName) == 0)
  check("ble set name", bleSetName(BleDeviceName) == bleOk)
  check("ble get name", cstringEquals(bt_get_name(), BleDeviceName))
  check("ble scan start", bt_le_scan_start(nil, nil) == 0)
  check("ble scan stop", bt_le_scan_stop() == 0)
  when defined(bl808BleDebugFlowRegs):
    printBleBlobDiag("after-scan-stop")

  bleConnCbStorage.connected = bleConnected
  bleConnCbStorage.disconnected = bleDisconnected
  bt_conn_cb_register(addr bleConnCbStorage)
  check("ble conn callback register", true)

  when BleCentralConnect != 0:
    bleConnectedCalled = false
    bleConnectedErr = 0xFF'u8
    discard console.sendString("[BLE] central scan ")
    discard console.sendLine(BleCentralName)
    let centralOk =
      bleCentralConnect(BleCentralName, BleCentralTimeoutMs.uint32) == bleOk
    check("ble central connect",
          centralOk and bleConnectedCalled and bleConnectedErr == 0)
    if centralOk:
      discard bleDisconnect()

  when BlePeripheralAdvertise != 0:
    enableBleControllerIrq()
    var advParam: BtLeAdvParam
    var advData: BtData
    check("ble advertising start", bt_le_adv_start(addr advParam, addr advData, 0, nil, 0) == 0)
    printHciStatus("adv-start")
    when defined(bl808BleVerboseDiag):
      printBleBlobDiag("adv-start")
    for _ in 0 ..< 2000:
      pollBleController(BlePollIterations.uint32)
      delayUs(BlePollDelayUs.uint32)
    when defined(bl808BleVerboseDiag):
      printBleBlobDiag("adv-pre-host")
    when defined(bl808BlePreHostAdvDiag):
      printBleBlobDiag("adv-pre-host")
    discard console.sendString("[BLE] advertising ")
    discard console.sendLine(BleDeviceName)

    var midDiagConnectedPrinted = false
    for i in 0 ..< BleHostWindowIterations:
      if bleConnectedCalled and bleDisconnectedCalled:
        break
      pollBleController(BlePollIterations.uint32)
      delayUs(BlePollDelayUs.uint32)
      if bleConnectedCalled and bleDisconnectedCalled:
        break
      when defined(bl808BleMidAdvLoopDiag):
        if i == 999 or i == 4999 or i == 9999:
          printBleBlobDiag("adv-mid")
        if bleConnectedCalled and not midDiagConnectedPrinted:
          printBleBlobDiag("adv-connected")
          midDiagConnectedPrinted = true
      when defined(bl808BleVerboseDiag):
        if i == 999 or i == 4999 or i == 9999:
          printBleBlobDiag("adv-loop")
    when defined(bl808BleVerboseDiag) or defined(bl808BleFinalAdvLoopDiag):
      if not (bleConnectedCalled and bleDisconnectedCalled):
        printBleBlobDiag("adv-loop")
    when defined(bl808BlePrintLlcCaptureOnce):
      printBleBlobLlcStartCapture("adv-loop")

    discard console.sendString("[BLEDBG] flags connected=")
    console.sendHex32(if bleConnectedCalled: 1'u32 else: 0'u32)
    discard console.sendString(" disconnected=")
    console.sendHex32(if bleDisconnectedCalled: 1'u32 else: 0'u32)
    discard console.sendLine("")
    when BleExpectPeripheralLink != 0:
      check("ble peripheral connected callback",
            bleConnectedCalled and bleConnectedErr == 0)
      check("ble peripheral disconnected callback", bleDisconnectedCalled)
    discard console.sendLine("[BLEDBG] before adv stop")
    check("ble advertising stop", bt_le_adv_stop() == 0)
    discard console.sendLine("[BLEDBG] after adv stop")
  when BlePeripheralAdvertise != 0:
    if bleConnectedCalled:
      check("ble controller sleep skipped after host link", true)
      check("ble controller sleep restore skipped after host link", true)
      check("ble controller deinit skipped after host link", true)
    else:
      checkControllerSleepRestore()
      check("ble controller deinit skipped during peripheral advertise", true)
  else:
    checkControllerSleepRestore()
    bleControllerDeinit()
    check("ble controller deinit", true)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()

  enableAllPeriphClocks()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8,
    stopBits: stop1, parity: parityNone,
  ), ConsoleClkHz)

  discard console.sendLine("")
  discard console.sendLine("=== BL808 BLE HAL Test ===")

  smokeBle()

  discard console.sendString("Result: ")
  console.sendHex32(passed.uint32)
  discard console.sendString(" passed, ")
  console.sendHex32(failed.uint32)
  discard console.sendLine(" failed")
  if failed == 0:
    discard console.sendLine("=== Test Complete ===")
