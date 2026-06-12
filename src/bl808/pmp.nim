## RISC-V Physical Memory Protection (PMP) for the E907/C906.
##
## PMP constrains the U-mode application the enclave drops into: by default a
## U-mode hart has no access, so the enclave grants exactly the app's own
## flash/RAM/MMIO windows and nothing else. Unlocked PMP entries do not apply
## to M-mode, so the enclave (M-mode) keeps full access.
##
## Hardware facts confirmed on this BL808 (E907): 8 PMP entries, NAPOT
## supported, entry 0 is locked by the BootROM, so usable entries are 1..7.

# CSR numbers must be assembler immediates, so the per-entry accessors are
# switch tables emitted in C rather than a computed CSR address.
{.emit: """/*TYPESECTION*/
static void __pmp_write_addr(int i, unsigned long v) {
  #define A(n,csr) case n: asm volatile("csrw "#csr",%0"::"r"(v)); break;
  switch (i) {
    A(0,0x3b0) A(1,0x3b1) A(2,0x3b2) A(3,0x3b3)
    A(4,0x3b4) A(5,0x3b5) A(6,0x3b6) A(7,0x3b7)
    A(8,0x3b8) A(9,0x3b9) A(10,0x3ba) A(11,0x3bb)
    A(12,0x3bc) A(13,0x3bd) A(14,0x3be) A(15,0x3bf)
  }
  #undef A
}
static unsigned long __pmp_read_addr(int i) {
  unsigned long o = 0;
  #define A(n,csr) case n: asm volatile("csrr %0,"#csr:"=r"(o)); break;
  switch (i) {
    A(0,0x3b0) A(1,0x3b1) A(2,0x3b2) A(3,0x3b3)
    A(4,0x3b4) A(5,0x3b5) A(6,0x3b6) A(7,0x3b7)
    A(8,0x3b8) A(9,0x3b9) A(10,0x3ba) A(11,0x3bb)
    A(12,0x3bc) A(13,0x3bd) A(14,0x3be) A(15,0x3bf)
  }
  #undef A
  return o;
}
static unsigned long __pmp_read_cfg(int i) {
  unsigned long o = 0;
  #define C(n,csr) case n: asm volatile("csrr %0,"#csr:"=r"(o)); break;
  switch (i) { C(0,0x3a0) C(1,0x3a1) C(2,0x3a2) C(3,0x3a3) }
  #undef C
  return o;
}
static void __pmp_write_cfg(int i, unsigned long v) {
  #define C(n,csr) case n: asm volatile("csrw "#csr",%0"::"r"(v)); break;
  switch (i) { C(0,0x3a0) C(1,0x3a1) C(2,0x3a2) C(3,0x3a3) }
  #undef C
}
""".}

proc pmpWriteAddr(i: cint, v: uint) {.importc: "__pmp_write_addr", nodecl.}
proc pmpReadAddr(i: cint): uint {.importc: "__pmp_read_addr", nodecl.}
proc pmpReadCfg(i: cint): uint {.importc: "__pmp_read_cfg", nodecl.}
proc pmpWriteCfg(i: cint, v: uint) {.importc: "__pmp_write_cfg", nodecl.}

const
  PmpEntriesMax* = 16
  PmpFirstUsable* = 1   ## entry 0 is BootROM-locked on this part

type
  PmpMode* = enum
    pmpOff   = 0
    pmpTor   = 1   ## top-of-range: matches [prev_addr, this_addr)
    pmpNa4   = 2   ## naturally-aligned 4-byte region
    pmpNapot = 3   ## naturally-aligned power-of-two region

  PmpPerm* = enum pmpR, pmpW, pmpX
  PmpPerms* = set[PmpPerm]

  PmpRegion* = object
    base*: uint      ## byte address (NAPOT/NA4) or range top (TOR)
    size*: uint      ## power-of-two byte size for NAPOT (ignored for TOR/NA4)
    mode*: PmpMode
    perm*: PmpPerms
    lock*: bool      ## set L: also enforces the rule against M-mode

proc pmpEncodeNapot*(base, size: uint): uint {.inline.} =
  ## pmpaddr encoding for a power-of-two NAPOT region.
  (base shr 2) or ((size - 1) shr 3)

proc pmpEncodeTor*(addrTop: uint): uint {.inline.} =
  ## pmpaddr encoding for a TOR upper bound.
  addrTop shr 2

proc pmpCfgByte*(r: PmpRegion): uint {.inline.} =
  ## Encode a region's config byte: R/W/X | A(mode) | L.
  result = 0
  if pmpR in r.perm: result = result or 0x01
  if pmpW in r.perm: result = result or 0x02
  if pmpX in r.perm: result = result or 0x04
  result = result or (r.mode.uint shl 3)
  if r.lock: result = result or 0x80

proc pmpSetEntry*(index: int, addrVal: uint, cfgByte: uint) =
  ## Low-level: write one PMP entry's address and config byte.
  if index < 0 or index >= PmpEntriesMax: return
  pmpWriteAddr(index.cint, addrVal)
  let reg = (index div 4).cint
  let shift = (index mod 4) * 8
  let cur = pmpReadCfg(reg)
  let masked = cur and not (0xFF'u shl shift)
  pmpWriteCfg(reg, masked or ((cfgByte and 0xFF) shl shift))

proc pmpApplyRegion*(index: int, r: PmpRegion) {.inline.} =
  ## Program a region (NAPOT/NA4/TOR) into PMP entry `index`.
  let a =
    case r.mode
    of pmpNapot: pmpEncodeNapot(r.base, r.size)
    of pmpNa4:   r.base shr 2
    of pmpTor:   pmpEncodeTor(r.base)
    of pmpOff:   0'u
  pmpSetEntry(index, a, pmpCfgByte(r))

proc pmpApplyTable*(regions: openArray[PmpRegion], firstIndex = PmpFirstUsable): bool =
  ## Program a default-deny U-mode table starting at `firstIndex` (1 by default
  ## to skip the BootROM-locked entry 0). Returns false if the table overflows
  ## the available entries.
  if firstIndex + regions.len > PmpEntriesMax:
    return false
  for i in 0 ..< regions.len:
    pmpApplyRegion(firstIndex + i, regions[i])
  true

proc pmpRegionLocked*(index: int): bool =
  ## True if a PMP entry's lock (L) bit is set.
  if index < 0 or index >= PmpEntriesMax: return false
  let byte = (pmpReadCfg((index div 4).cint) shr ((index mod 4) * 8)) and 0xFF
  (byte and 0x80) != 0

proc pmpRegionCount*(): int =
  ## Number of implemented PMP entries (probed once by writing all-ones).
  result = 0
  for i in 0 ..< PmpEntriesMax:
    let saved = pmpReadAddr(i.cint)
    pmpWriteAddr(i.cint, high(uint))
    if pmpReadAddr(i.cint) != 0: inc result
    pmpWriteAddr(i.cint, saved)
