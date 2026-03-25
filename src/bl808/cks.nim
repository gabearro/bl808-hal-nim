## BL808 CKS (Checksum) engine driver.
##
## CKS at 0x2000A700 — hardware CRC-16/CRC-32 checksum accelerator.
## Computes checksums over data fed through the data register.

import mmio, memmap

# =============================================================================
# CKS register offsets
# =============================================================================
const
  CksConfig*        = memmap.CksBase + 0x00'u  # CKS configuration
  CksDataIn*        = memmap.CksBase + 0x04'u  # Data input (write)
  CksOut*           = memmap.CksBase + 0x08'u  # Checksum output (read)

# =============================================================================
# CKS config fields
# =============================================================================
const
  CksClear*         = 0       # Clear checksum (write 1)
  CksEndian*        = 1       # Endian swap (0=LE, 1=BE)
  CksCrcMode*       = 2       # CRC mode select

# =============================================================================
# Checksum operations
# =============================================================================
proc cksReset*() =
  ## Clear/reset the checksum accumulator.
  regSet(CksConfig, 1'u32 shl CksClear)

proc cksSetEndian*(bigEndian: bool) =
  if bigEndian:
    regSet(CksConfig, 1'u32 shl CksEndian)
  else:
    regClear(CksConfig, 1'u32 shl CksEndian)

proc cksFeedByte*(data: uint8) =
  ## Feed one byte into the checksum engine.
  regWrite(CksDataIn, data.uint32)

proc cksFeedWord*(data: uint32) =
  ## Feed a 32-bit word into the checksum engine.
  regWrite(CksDataIn, data)

proc cksFeedBuffer*(data: openArray[uint8]) =
  ## Feed a buffer of bytes into the checksum engine.
  for b in data:
    regWrite(CksDataIn, b.uint32)

proc cksResult*(): uint16 =
  ## Read the current CRC-16 checksum result.
  (regRead(CksOut) and 0xFFFF).uint16

proc cksCompute*(data: openArray[uint8]): uint16 =
  ## Compute CRC-16 checksum of a buffer (reset + feed + read).
  cksReset()
  cksFeedBuffer(data)
  cksResult()
