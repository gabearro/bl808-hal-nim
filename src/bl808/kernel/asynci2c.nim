## CPS I2C master transactions backed by DMA.

import ../i2c, ../dma, ../dmablock
import ./runtime, ./sched

type AsyncI2c* = ref object
  i2c*: I2c
  packet: I2cPacket
  pending: CpsFuture[I2cError]

proc initAsyncI2c*(id: I2cId, speed: I2cSpeed, clkHz: uint32): AsyncI2c =
  AsyncI2c(i2c: initI2c(id, speed, clkHz))

proc finish(ai: AsyncI2c; cancelled = false) =
  let resultFuture = move(ai.pending)
  let status = ai.packet.endPacket(cancelled)
  complete(resultFuture, status)

proc transfer(ai: AsyncI2c; address: uint8; data: ptr UncheckedArray[byte];
              len: int; reading: bool; subAddress = -1): CpsFuture[I2cError] =
  if len == 0: return completedLocalFuture(i2cOk)
  if ai.pending != nil or data == nil or len < 0 or len > I2cPacketMax:
    return completedLocalFuture(i2cFifoError)

  let resultFuture = newLocalCpsFuture[I2cError]()
  ai.pending = resultFuture
  let controller = openCoreDma()
  var started = false
  var timer: TimerId
  var delay = 100'u64
  proc poll() =
    timer = 0
    if not started and controller.hasFreeChannels(1):
      started = ai.packet.beginPacket(ai.i2c, address, data, len, reading, subAddress)
      if not started:
        ai.pending = nil
        complete(resultFuture, i2cFifoError)
        return
    if started and ai.packet.pollPacket():
      ai.finish()
    else:
      timer = addTimerUs(delay, poll)
      delay = min(delay * 2, 1_000'u64)
  resultFuture.addCallback proc() =
    if resultFuture.isCancelled:
      if timer != 0: cancelTimer(timer)
      if started: ai.finish(cancelled = true)
      else: ai.pending = nil
  poll()
  resultFuture

proc writePtr*(ai: AsyncI2c; address: uint8; data: ptr UncheckedArray[uint8];
               len: int): CpsFuture[I2cError] =
  ai.transfer(address, data, len, reading = false)

proc readPtr*(ai: AsyncI2c; address: uint8; buf: ptr UncheckedArray[uint8];
              len: int): CpsFuture[I2cError] =
  ai.transfer(address, buf, len, reading = true)

proc writeRegPtr*(ai: AsyncI2c; address, regAddr: uint8;
                  data: ptr UncheckedArray[uint8]; len: int): CpsFuture[I2cError] =
  ai.transfer(address, data, len, reading = false, subAddress = regAddr.int)

proc readRegPtr*(ai: AsyncI2c; address, regAddr: uint8;
                 buf: ptr UncheckedArray[uint8]; len: int): CpsFuture[I2cError] =
  ai.transfer(address, buf, len, reading = true, subAddress = regAddr.int)

proc write*(ai: AsyncI2c; address: uint8; data: openArray[uint8]): CpsFuture[I2cError] =
  let p = if data.len == 0: nil else: cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  ai.writePtr(address, p, data.len)

proc read*(ai: AsyncI2c; address: uint8; buf: var openArray[uint8]): CpsFuture[I2cError] =
  let p = if buf.len == 0: nil else: cast[ptr UncheckedArray[byte]](addr buf[0])
  ai.readPtr(address, p, buf.len)

proc writeReg*(ai: AsyncI2c; address, regAddr: uint8;
               data: openArray[uint8]): CpsFuture[I2cError] =
  let p = if data.len == 0: nil else: cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  ai.writeRegPtr(address, regAddr, p, data.len)

proc readReg*(ai: AsyncI2c; address, regAddr: uint8;
              buf: var openArray[uint8]): CpsFuture[I2cError] =
  let p = if buf.len == 0: nil else: cast[ptr UncheckedArray[byte]](addr buf[0])
  ai.readRegPtr(address, regAddr, p, buf.len)
