## Flash-resident anti-rollback counter (downgrade *detection*).
##
## Two flash sectors hold a monotonic ping-pong record; the highest valid `seq`
## wins, and the recorded per-image security versions form a floor that images
## must meet. Writing the new record to the opposite sector before erasing the
## old one keeps a valid record present across a power loss.
##
## WEAKNESS (documented, not fixed in reversible mode): flash is reflashable, so
## an attacker with a programmer can erase the counter. This defends against
## accidental and online downgrade, not against physical rollback — that needs
## an eFuse monotonic counter. To raise the bar the record is MAC'd with a
## device key so it cannot be forged, only erased.

import ../flash
import ../enclave/sha256

const
  RollbackMagic* = 0x424B4C52'u32   # "RLKB"
  SlotA* = 0x10000'u32
  SlotB* = 0x11000'u32
  SectorSize* = 0x1000'u32

type
  RollbackRecord* {.packed.} = object
    magic*: uint32
    seqNo*: uint32
    m0Sec*, d0Sec*, lpSec*, enclaveSec*: uint32
    mac*: array[32, uint8]   ## HMAC-SHA256 over the record prefix (device-keyed)

proc recordPrefixLen(): int = 6 * 4   # bytes before the mac

proc computeMac(rec: RollbackRecord, macKey: openArray[uint8]): array[32, uint8] =
  var buf: array[24, uint8]
  let fields = [rec.magic, rec.seqNo, rec.m0Sec, rec.d0Sec, rec.lpSec, rec.enclaveSec]
  var o = 0
  for f in fields:
    buf[o] = (f and 0xFF).uint8
    buf[o+1] = ((f shr 8) and 0xFF).uint8
    buf[o+2] = ((f shr 16) and 0xFF).uint8
    buf[o+3] = ((f shr 24) and 0xFF).uint8
    o += 4
  hmacSha256(macKey, buf)

proc readSlot(addrFlash: uint32, rec: var RollbackRecord): bool =
  var buf: array[sizeof(RollbackRecord), uint8]
  flashReadXipBuffer(addrFlash, buf)
  copyMem(addr rec, addr buf[0], sizeof(RollbackRecord))
  rec.magic == RollbackMagic

proc currentFloor*(macKey: openArray[uint8], rec: var RollbackRecord): bool =
  ## Return the winning (highest valid seq, MAC-checked) record. False if none.
  var a, b: RollbackRecord
  let aok = readSlot(SlotA, a) and computeMac(a, macKey) == a.mac
  let bok = readSlot(SlotB, b) and computeMac(b, macKey) == b.mac
  if aok and (not bok or a.seqNo >= b.seqNo):
    rec = a; return true
  if bok:
    rec = b; return true
  false

proc accepts*(floor: RollbackRecord, imgType: uint16, secVer: uint32): bool =
  ## True if an image's security version meets or exceeds the recorded floor.
  case imgType
  of 1: secVer >= floor.m0Sec
  of 2: secVer >= floor.d0Sec
  of 3: secVer >= floor.lpSec
  of 4: secVer >= floor.enclaveSec
  else: false
