## BL808 EMAC (Ethernet MAC) driver.
##
## EMAC at 0x20070000 — 10/100 Mbps Ethernet MAC with MII/RMII interface.
## Supports TX/RX with descriptor rings, flow control, multicast hash filter.

import mmio, memmap

# =============================================================================
# EMAC register offsets
# =============================================================================
const
  EmacMode*         = EmacBase + 0x00'u   # Mode configuration
  EmacIntSrc*       = EmacBase + 0x04'u   # Interrupt source
  EmacIntMask*      = EmacBase + 0x08'u   # Interrupt mask
  EmacIpgt*         = EmacBase + 0x0C'u   # Inter-packet gap (TX)
  EmacPktLen*       = EmacBase + 0x18'u   # Max/Min packet length
  EmacCollConfig*   = EmacBase + 0x1C'u   # Collision configuration
  EmacTxBdBase*     = EmacBase + 0x20'u   # TX buffer descriptor base
  EmacFlowCtrl*     = EmacBase + 0x24'u   # Flow control
  EmacMiiMode*      = EmacBase + 0x28'u   # MII mode (RMII/MII select)
  EmacMiiCmd*       = EmacBase + 0x2C'u   # MII command
  EmacMiiAddr*      = EmacBase + 0x30'u   # MII PHY address
  EmacMiiTxData*    = EmacBase + 0x34'u   # MII TX data
  EmacMiiRxData*    = EmacBase + 0x38'u   # MII RX data
  EmacMiiStatus*    = EmacBase + 0x3C'u   # MII status
  EmacMacAddr0*     = EmacBase + 0x40'u   # MAC address bytes 0-3
  EmacMacAddr1*     = EmacBase + 0x44'u   # MAC address bytes 4-5
  EmacHash0*        = EmacBase + 0x48'u   # Hash filter word 0
  EmacHash1*        = EmacBase + 0x4C'u   # Hash filter word 1
  EmacTxCtrl*       = EmacBase + 0x50'u   # TX control
  EmacRxCtrl*       = EmacBase + 0x54'u   # RX control

  # TX buffer descriptors start at offset 0x400
  EmacTxBdStart*    = EmacBase + 0x400'u
  # RX buffer descriptors start at offset 0x600
  EmacRxBdStart*    = EmacBase + 0x600'u

# =============================================================================
# Mode register fields
# =============================================================================
const
  EmacRxEn*         = 0       # RX enable
  EmacTxEn*         = 1       # TX enable
  EmacNoPre*        = 2       # No preamble
  EmacBro*          = 3       # Reject broadcast
  EmacIam*          = 4       # IAM mode
  EmacPro*          = 5       # Promiscuous mode
  EmacIfg*          = 6       # Inter-frame gap
  EmacLoop*         = 7       # Loopback mode
  EmacNbuf*         = 8       # No back-off
  EmacRecSmall*     = 16      # Receive small packets
  EmacPad*          = 15      # Pad short frames
  EmacHuge*         = 14      # Accept huge frames
  EmacFullDuplex*   = 10      # Full duplex mode
  EmacCrcEn*        = 13      # CRC enable

# =============================================================================
# Interrupt bits
# =============================================================================
const
  EmacIntTxB*       = 0       # TX buffer done
  EmacIntTxE*       = 1       # TX error
  EmacIntRxB*       = 2       # RX buffer done
  EmacIntRxE*       = 3       # RX error
  EmacIntBusy*      = 4       # RX busy (no buffer)
  EmacIntTxC*       = 5       # TX control frame
  EmacIntRxC*       = 6       # RX control frame

# =============================================================================
# Buffer descriptor
# =============================================================================
type
  EmacBd* {.packed.} = object
    ## Ethernet buffer descriptor (8 bytes).
    status*: uint32   # Status/control
    address*: uint32  # Buffer address (physical)

const
  # TX BD status bits
  TxBdReady*        = 15      # BD ready for transmission
  TxBdIrq*          = 14      # Generate interrupt on completion
  TxBdWrap*         = 13      # Wrap (last BD in ring)
  TxBdPad*          = 12      # Pad short frame
  TxBdCrc*          = 11      # Append CRC
  TxBdLenShift*     = 16      # Frame length [31:16]
  TxBdLenMask*      = 0xFFFF'u32 shl 16

  # RX BD status bits
  RxBdEmpty*        = 15      # BD empty (ready for RX)
  RxBdIrq*          = 14      # Generate interrupt
  RxBdWrap*         = 13      # Wrap (last BD in ring)
  RxBdLenShift*     = 16      # Received length [31:16]
  RxBdLenMask*      = 0xFFFF'u32 shl 16

# =============================================================================
# Types
# =============================================================================
type
  EmacError* = enum
    emacOk
    emacTimeout
    emacNoBuffer

# =============================================================================
# EMAC initialization
# =============================================================================
proc emacInit*(macAddr: array[6, uint8], fullDuplex: bool = true) =
  ## Initialize the Ethernet MAC.

  # Set MAC address
  let mac0 = macAddr[0].uint32 or
             (macAddr[1].uint32 shl 8) or
             (macAddr[2].uint32 shl 16) or
             (macAddr[3].uint32 shl 24)
  let mac1 = macAddr[4].uint32 or
             (macAddr[5].uint32 shl 8)
  regWrite(EmacMacAddr0, mac0)
  regWrite(EmacMacAddr1, mac1)

  # Configure mode
  var mode = (1'u32 shl EmacCrcEn) or (1'u32 shl EmacPad)
  if fullDuplex:
    mode = mode or (1'u32 shl EmacFullDuplex)
  regWrite(EmacMode, mode)

  # Set inter-packet gap (typical: 0x15 for full duplex, 0x12 for half)
  if fullDuplex:
    regWrite(EmacIpgt, 0x15)
  else:
    regWrite(EmacIpgt, 0x12)

  # Set max packet length
  regWrite(EmacPktLen, (1518'u32 shl 16) or 64)  # Max 1518, min 64

  # Clear all interrupts
  regWrite(EmacIntSrc, 0xFF)

proc emacEnableRx*() =
  regSet(EmacMode, 1'u32 shl EmacRxEn)

proc emacEnableTx*() =
  regSet(EmacMode, 1'u32 shl EmacTxEn)

proc emacDisableRx*() =
  regClear(EmacMode, 1'u32 shl EmacRxEn)

proc emacDisableTx*() =
  regClear(EmacMode, 1'u32 shl EmacTxEn)

# =============================================================================
# MDIO (PHY management)
# =============================================================================
proc emacMdioRead*(phyAddr: uint8, regAddr: uint8,
                   timeout: uint32 = 100_000): (uint16, EmacError) =
  ## Read a PHY register via MDIO.
  # Set PHY address and register address
  regWrite(EmacMiiAddr, (phyAddr.uint32 shl 8) or regAddr.uint32)

  # Issue read command
  regWrite(EmacMiiCmd, 1'u32)  # Read

  # Wait for completion
  var countdown = timeout
  while (regRead(EmacMiiStatus) and 1) != 0:  # Busy
    countdown.dec
    if countdown == 0: return (0'u16, emacTimeout)

  let data = regRead(EmacMiiRxData) and 0xFFFF
  (data.uint16, emacOk)

proc emacMdioWrite*(phyAddr: uint8, regAddr: uint8, data: uint16,
                    timeout: uint32 = 100_000): EmacError =
  ## Write a PHY register via MDIO.
  regWrite(EmacMiiAddr, (phyAddr.uint32 shl 8) or regAddr.uint32)
  regWrite(EmacMiiTxData, data.uint32)

  # Issue write command
  regWrite(EmacMiiCmd, 2'u32)  # Write

  var countdown = timeout
  while (regRead(EmacMiiStatus) and 1) != 0:
    countdown.dec
    if countdown == 0: return emacTimeout
  emacOk

# =============================================================================
# Interrupt control
# =============================================================================
proc emacEnableInterrupt*(intBit: uint32) =
  regSet(EmacIntMask, 1'u32 shl intBit)

proc emacDisableInterrupt*(intBit: uint32) =
  regClear(EmacIntMask, 1'u32 shl intBit)

proc emacClearInterrupt*(intBit: uint32) =
  regWrite(EmacIntSrc, 1'u32 shl intBit)

proc emacReadInterruptStatus*(): uint32 =
  regRead(EmacIntSrc)

# =============================================================================
# Promiscuous / broadcast mode
# =============================================================================
proc emacSetPromiscuous*(enable: bool) =
  if enable:
    regSet(EmacMode, 1'u32 shl EmacPro)
  else:
    regClear(EmacMode, 1'u32 shl EmacPro)

proc emacRejectBroadcast*(reject: bool) =
  if reject:
    regSet(EmacMode, 1'u32 shl EmacBro)
  else:
    regClear(EmacMode, 1'u32 shl EmacBro)

# =============================================================================
# Hash filter
# =============================================================================
proc emacSetHashFilter*(hash0, hash1: uint32) =
  regWrite(EmacHash0, hash0)
  regWrite(EmacHash1, hash1)
