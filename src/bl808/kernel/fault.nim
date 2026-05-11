## Fault diagnostics and low-cost runtime guardrails.
##
## This module is intentionally usable from trap context: no heap allocation,
## no logging dependency, and only bounded polling on the emergency UART.

import ../core
import ../memmap
import ../mmio
import ../uart

const
  FaultMagic* = 0x464C_5431'u32  ## "FLT1"
  FaultVersion* = 1'u32

  FaultReasonNone* = 0'u32
  FaultReasonTrap* = 1'u32
  FaultReasonManual* = 2'u32
  FaultReasonStackGuard* = 3'u32

  FaultRecordAddr* = XramBase + 0x2E00'u
    ## Fixed crash record address, below the XramUserBase IPC region.

  StackGuardMagic* = 0xA5C3_3C5A'u32
  StackGuardWords* = 32

type
  FaultRecord* = object
    magic*: uint32
    version*: uint32
    core*: uint32
    reason*: uint32
    causeLo*, causeHi*: uint32
    epcLo*, epcHi*: uint32
    tvalLo*, tvalHi*: uint32
    spLo*, spHi*: uint32
    stackStart*, stackEnd*: uint32
    flags*: uint32

{.emit: """
#include <stdint.h>
extern unsigned long _sstack;
extern unsigned long _estack;

static inline uintptr_t __kernel_stack_start(void) {
  return (uintptr_t)&_sstack;
}

static inline uintptr_t __kernel_stack_end(void) {
  return (uintptr_t)&_estack;
}

static inline uintptr_t __kernel_read_sp(void) {
  uintptr_t v;
  __asm__ volatile("mv %0, sp" : "=r"(v));
  return v;
}
""".}

proc kernelStackStart*(): uint {.importc: "__kernel_stack_start", nodecl.}
proc kernelStackEnd*(): uint {.importc: "__kernel_stack_end", nodecl.}
proc readStackPointer*(): uint {.importc: "__kernel_read_sp", nodecl.}

proc currentCoreCode(): uint32 {.inline.} =
  when defined(bl808m0):
    0'u32
  elif defined(bl808d0):
    1'u32
  elif defined(bl808lp):
    2'u32
  else:
    0xFFFF_FFFF'u32

proc low32(v: uint): uint32 {.inline.} =
  (v and 0xFFFF_FFFF'u).uint32

proc high32(v: uint): uint32 {.inline.} =
  when sizeof(uint) > 4:
    ((v shr 32) and 0xFFFF_FFFF'u).uint32
  else:
    0'u32

proc recordWrite(offset: uint, value: uint32) {.inline.} =
  regWrite(FaultRecordAddr + offset, value)

proc recordRead(offset: uint): uint32 {.inline.} =
  regRead(FaultRecordAddr + offset)

proc stackGuardOk*(): bool {.raises: [].}

proc faultClearRecord*() =
  ## Clear the persistent fault record.
  for off in countup(0'u, 60'u, 4'u):
    recordWrite(off, 0)

proc faultRecordValid*(): bool =
  recordRead(0) == FaultMagic and recordRead(4) == FaultVersion

proc faultRecordSnapshot*(): FaultRecord =
  ## Read the current crash record from XRAM.
  FaultRecord(
    magic: recordRead(0),
    version: recordRead(4),
    core: recordRead(8),
    reason: recordRead(12),
    causeLo: recordRead(16),
    causeHi: recordRead(20),
    epcLo: recordRead(24),
    epcHi: recordRead(28),
    tvalLo: recordRead(32),
    tvalHi: recordRead(36),
    spLo: recordRead(40),
    spHi: recordRead(44),
    stackStart: recordRead(48),
    stackEnd: recordRead(52),
    flags: recordRead(56),
  )

proc faultRecord*(reason: uint32, cause, epc, tval: uint) {.raises: [].} =
  ## Store a bounded crash record in shared XRAM.
  let sp = readStackPointer()
  recordWrite(0, FaultMagic)
  recordWrite(4, FaultVersion)
  recordWrite(8, currentCoreCode())
  recordWrite(12, reason)
  recordWrite(16, low32(cause))
  recordWrite(20, high32(cause))
  recordWrite(24, low32(epc))
  recordWrite(28, high32(epc))
  recordWrite(32, low32(tval))
  recordWrite(36, high32(tval))
  recordWrite(40, low32(sp))
  recordWrite(44, high32(sp))
  recordWrite(48, low32(kernelStackStart()))
  recordWrite(52, low32(kernelStackEnd()))
  recordWrite(56, if stackGuardOk(): 0'u32 else: 1'u32)

proc emergencyUartBase(): uint {.inline.} =
  when defined(bl808d0):
    Uart3Base
  else:
    Uart0Base

proc emergencyPutc(ch: uint8) =
  let base = emergencyUartBase()
  var timeout = 10_000'u32
  while (regRead(base + UartFifoConfig1) and FifoTxFreeMask) == 0'u32:
    timeout.dec
    if timeout == 0:
      return
  regWrite(base + UartFifoWdata, ch.uint32)

proc emergencyWrite*(s: string) {.raises: [].} =
  ## Best-effort direct UART write. Requires the console UART to have already
  ## been initialized by the firmware.
  for ch in s:
    emergencyPutc(ch.uint8)

proc emergencyHexNibble(v: uint32) {.raises: [].} =
  let n = v and 0xF'u32
  emergencyPutc((if n < 10: ord('0').uint32 + n else: ord('A').uint32 + n - 10).uint8)

proc emergencyHex32*(v: uint32) {.raises: [].} =
  emergencyWrite("0x")
  for shift in countdown(28, 0, 4):
    emergencyHexNibble((v shr shift).uint32)

proc emergencyHexUint*(v: uint) {.raises: [].} =
  when sizeof(uint) > 4:
    emergencyHex32(high32(v))
    emergencyPutc(ord('_').uint8)
  emergencyHex32(low32(v))

proc faultDump*(reason: uint32, cause, epc, tval: uint) {.raises: [].} =
  emergencyWrite("\r\n[FAULT] reason=")
  emergencyHex32(reason)
  emergencyWrite(" cause=")
  emergencyHexUint(cause)
  emergencyWrite(" epc=")
  emergencyHexUint(epc)
  emergencyWrite(" tval=")
  emergencyHexUint(tval)
  emergencyWrite(" sp=")
  emergencyHexUint(readStackPointer())
  emergencyWrite("\r\n")

proc faultHandleTrap*(cause, epc, tval: uint) =
  ## Record and print a trap. Caller remains responsible for halting.
  faultRecord(FaultReasonTrap, cause, epc, tval)
  faultDump(FaultReasonTrap, cause, epc, tval)

proc faultHalt*(reason: uint32, cause, epc, tval: uint) {.noreturn.} =
  ## Record, print, and halt. Safe to call after interrupts are disabled.
  ## iter 258: Nim's codegen injects a `nimInErrorMode` check after EVERY
  ## proc call regardless of {.noreturn.}, with the !=0 branch ret'ing
  ## past the wfi loop. That left trap_entry's mret restoring the bad
  ## mepc, infinite trap loop, hardware reset (~200 boot iterations).
  ## Wrap the body in a single block that ends with raw asm wfi-loop +
  ## __builtin_unreachable so the codegen produces no fall-through path.
  faultRecord(reason, cause, epc, tval)
  faultDump(reason, cause, epc, tval)
  {.emit: """
    __asm__ volatile("csrci mstatus, 0x8\n"
                     "1: wfi\n"
                     "j 1b\n"
                     ::: "memory");
    __builtin_unreachable();
  """.}

proc stackGuardInit*() =
  ## Fill the low end of the reserved stack window with a sentinel.
  let start = kernelStackStart()
  for i in 0 ..< StackGuardWords:
    regWrite(start + (i.uint * 4'u), StackGuardMagic)

proc stackGuardOk*(): bool {.raises: [].} =
  let start = kernelStackStart()
  for i in 0 ..< StackGuardWords:
    if regRead(start + (i.uint * 4'u)) != StackGuardMagic:
      return false
  true

proc stackBytesUsed*(): uint =
  let sp = readStackPointer()
  let start = kernelStackStart()
  let finish = kernelStackEnd()
  if sp >= start and sp <= finish:
    finish - sp
  elif sp < start:
    finish - start
  else:
    0'u

proc faultInit*() =
  ## Initialize guardrails that should be active for every firmware image.
  stackGuardInit()

proc faultCheckStackGuard*(): bool =
  ## Check the stack sentinel and record a fault if it has been damaged.
  result = stackGuardOk()
  if not result:
    faultRecord(FaultReasonStackGuard, 0'u, 0'u, 0'u)
