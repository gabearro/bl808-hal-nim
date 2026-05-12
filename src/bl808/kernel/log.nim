## Kernel logging framework.
##
## Compile-time severity filtering, zero-allocation UART output.
##
##   logInit(console)
##   logInfo "Scheduler started"
##   logInfo "tasks=": lInt(count); lStr(" ready="); lInt(ready)
##
## Filter at compile time: -d:logLevel=0 (debug) .. 3 (error only).
## Default: 1 (info).

import ../uart

# =============================================================================
# Configuration
# =============================================================================

type LogLevel* = enum
  lvDebug = 0
  lvInfo = 1
  lvWarn = 2
  lvError = 3

const logLevel* {.intdefine.}: int = 1

# =============================================================================
# Output sink
# =============================================================================

var logSink: ptr Uart

proc logInit*(uart: var Uart) =
  ## Set the UART used for log output. Call once per core at boot.
  logSink = addr uart

# =============================================================================
# Value writers — inline, no allocation
# =============================================================================

proc lStr*(s: string) {.inline.} =
  if logSink != nil: discard logSink[].sendString(s)

proc lChar*(c: char) {.inline.} =
  if logSink != nil: discard logSink[].sendByte(c.uint8)

proc lInt*(v: int) {.inline.} =
  ## Write a signed integer in decimal.
  if logSink == nil: return
  if v == 0:
    discard logSink[].sendByte(ord('0').uint8)
    return
  var buf: array[20, uint8]
  var i = 0
  var n = v
  if n < 0:
    discard logSink[].sendByte(ord('-').uint8)
    n = -n
  while n > 0 and i < 20:
    buf[i] = uint8(n mod 10) + ord('0').uint8
    n = n div 10
    inc i
  for j in countdown(i - 1, 0):
    discard logSink[].sendByte(buf[j])

proc lU32*(v: uint32) {.inline.} =
  ## Write an unsigned 32-bit integer in decimal.
  if logSink == nil: return
  if v == 0:
    discard logSink[].sendByte(ord('0').uint8)
    return
  var buf: array[10, uint8]
  var i = 0
  var n = v
  while n > 0 and i < 10:
    buf[i] = uint8(n mod 10) + ord('0').uint8
    n = n div 10
    inc i
  for j in countdown(i - 1, 0):
    discard logSink[].sendByte(buf[j])

proc lU64*(v: uint64) {.inline.} =
  ## Write an unsigned 64-bit integer in decimal.
  if logSink == nil: return
  if v == 0:
    discard logSink[].sendByte(ord('0').uint8)
    return
  var buf: array[20, uint8]
  var i = 0
  var n = v
  while n > 0 and i < 20:
    buf[i] = uint8(n mod 10) + ord('0').uint8
    n = n div 10
    inc i
  for j in countdown(i - 1, 0):
    discard logSink[].sendByte(buf[j])

proc lHex*(v: uint32) {.inline.} =
  ## Write a 32-bit value as "0xABCD1234".
  if logSink != nil: logSink[].sendHex32(v)

proc lBool*(v: bool) {.inline.} =
  lStr(if v: "true" else: "false")

proc lLn*() {.inline.} =
  ## Write CR+LF. Level templates add this automatically.
  if logSink != nil: discard logSink[].sendLine("")

# =============================================================================
# Level templates — zero cost when filtered out
# =============================================================================

const Prefix: array[4, string] = ["[DBG] ", "[INF] ", "[WRN] ", "[ERR] "]

# Simple message
template logDebug*(msg: string) =
  when logLevel <= 0: lStr(Prefix[0]); lStr(msg); lLn()
template logInfo*(msg: string) =
  when logLevel <= 1: lStr(Prefix[1]); lStr(msg); lLn()
template logWarn*(msg: string) =
  when logLevel <= 2: lStr(Prefix[2]); lStr(msg); lLn()
template logError*(msg: string) =
  when logLevel <= 3: lStr(Prefix[3]); lStr(msg); lLn()

# Message + value block (colon syntax)
template logDebug*(msg: string, body: untyped) =
  when logLevel <= 0: lStr(Prefix[0]); lStr(msg); body; lLn()
template logInfo*(msg: string, body: untyped) =
  when logLevel <= 1: lStr(Prefix[1]); lStr(msg); body; lLn()
template logWarn*(msg: string, body: untyped) =
  when logLevel <= 2: lStr(Prefix[2]); lStr(msg); body; lLn()
template logError*(msg: string, body: untyped) =
  when logLevel <= 3: lStr(Prefix[3]); lStr(msg); body; lLn()
