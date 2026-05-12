## RAM-resident M0 UART flash anchor for hardware validation.
##
## JTAG loads this image into RAM and resumes M0. The host then streams flash
## commands over UART0 without putting the board into UART boot mode.

import bl808/startup
import bl808/mmio
import bl808/glb, bl808/gpio, bl808/uart, bl808/flash

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  ReqMagic = 0x3141_4655'u32 # "UFA1"
  ReqGuard = 0x4853_5246'u32 # "FRSH"
  RespMagic = 0x3152_4655'u32 # "UFR1"
  CmdPing = 0'u32
  CmdReadId = 1'u32
  CmdErase = 2'u32
  CmdWriteVerify = 3'u32
  ErrOk = 0'u32
  ErrBadCommand = 1'u32
  ErrBadLength = 2'u32
  ErrChecksum = 3'u32
  ErrTimeout = 4'u32
  ErrVerify = 5'u32
  DataMax = 4096
  SfCtrlCfg1OwnerIahb = 1'u32 shl 28
  SfCtrlCfg1IfEn = 1'u32 shl 29
  SfCtrlCfg1Ahb2SifEn = 1'u32 shl 30

type
  Request = object
    command: uint32
    address: uint32
    length: uint32
    headerChecksum: uint32

var
  console: Uart
  dataBuf: array[DataMax, uint8]

proc spin() {.inline.} =
  discard regRead(GlbSocInfo0)

proc sendBanner() =
  discard console.sendLine("BL808-UART-FLASH-ANCHOR v1")

proc claimSfController() =
  var cfg1 = regRead(SfCtrlCfg1)
  cfg1 = cfg1 and not (SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn)
  cfg1 = cfg1 or SfCtrlCfg1IfEn
  regWrite(SfCtrlCfg1, cfg1)

proc recvByteBlocking(): uint8 =
  while true:
    let (b, ok) = console.tryRecvByte()
    if ok:
      return b
    spin()

proc recvU32(): uint32 =
  result = recvByteBlocking().uint32
  result = result or (recvByteBlocking().uint32 shl 8)
  result = result or (recvByteBlocking().uint32 shl 16)
  result = result or (recvByteBlocking().uint32 shl 24)

proc sendU32(value: uint32) =
  discard console.sendByte((value and 0xFF).uint8)
  discard console.sendByte(((value shr 8) and 0xFF).uint8)
  discard console.sendByte(((value shr 16) and 0xFF).uint8)
  discard console.sendByte(((value shr 24) and 0xFF).uint8)

proc recvRequest(req: var Request) =
  var window = 0'u32
  var idle = 0'u32
  while window != ReqMagic:
    let (b, ok) = console.tryRecvByte()
    if ok:
      window = (window shr 8) or (b.uint32 shl 24)
      idle = 0
    else:
      idle.inc
      if idle >= 2_000_000'u32:
        sendBanner()
        idle = 0
      spin()
  let guard = recvU32()
  if guard != ReqGuard:
    req.command = 0xFFFF_FFFF'u32
    req.address = 0
    req.length = 0
    req.headerChecksum = 0
    return
  req.command = recvU32()
  req.address = recvU32()
  req.length = recvU32()
  req.headerChecksum = recvU32()

proc headerChecksum(command, address, length: uint32): uint32 =
  not (ReqGuard xor command xor address xor length)

proc checksum(length: uint32): uint32 =
  for i in 0 ..< length.int:
    result = (result shl 5) xor (result shr 27) xor dataBuf[i].uint32

proc recvPayload(length: uint32) =
  for i in 0 ..< length.int:
    dataBuf[i] = recvByteBlocking()

proc eraseRange(address, length: uint32): uint32 =
  if length == 0:
    return ErrBadLength
  var pos = address and not (FlashSectorSize - 1'u32)
  let endAddr = (address + length + FlashSectorSize - 1'u32) and
                not (FlashSectorSize - 1'u32)
  while pos < endAddr:
    let err =
      if (pos and (FlashBlock64Size - 1'u32)) == 0 and
          (endAddr - pos) >= FlashBlock64Size:
        let e = flashEraseBlock64(pos)
        pos += FlashBlock64Size
        e
      else:
        let e = flashEraseSector(pos)
        pos += FlashSectorSize
        e
    if err != flashOk:
      return ErrTimeout
  ErrOk

proc writeVerify(address, length, expectedChecksum: uint32): uint32 =
  if length == 0 or length > DataMax.uint32:
    return ErrBadLength
  recvPayload(length)
  if checksum(length) != expectedChecksum:
    return ErrChecksum
  if flashWrite(address, dataBuf.toOpenArray(0, length.int - 1)) != flashOk:
    return ErrTimeout
  for i in 0 ..< length.int:
    if flashReadXipByte(address + i.uint32) != dataBuf[i]:
      return ErrVerify
  ErrOk

proc sendResponse(status, value, counter: uint32) =
  sendU32(RespMagic)
  sendU32(status)
  sendU32(value)
  sendU32(counter)

proc main() {.exportc, cdecl.} =
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)
  claimSfController()

  sendBanner()
  while true:
    var req: Request
    recvRequest(req)
    var status = ErrOk
    var value = 0'u32
    if req.headerChecksum != headerChecksum(req.command, req.address, req.length):
      status = ErrChecksum
    else:
      case req.command
      of CmdPing:
        value = 1
      of CmdReadId:
        let id = flashReadId()
        value = id.manufacturerId.uint32 or
          (id.memoryType.uint32 shl 8) or
          (id.capacity.uint32 shl 16)
      of CmdErase:
        status = eraseRange(req.address, req.length)
      of CmdWriteVerify:
        let payloadChecksum = recvU32()
        status = writeVerify(req.address, req.length, payloadChecksum)
      else:
        status = ErrBadCommand
    sendResponse(status, value, req.address + req.length)
