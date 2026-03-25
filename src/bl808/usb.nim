## BL808 USB 2.0 OTG controller driver.
##
## USB at 0x20072000 — Faraday FOTG210 (EHCI-compatible) USB OTG.
## NOT DWC2/Synopsys. Supports Full-Speed and High-Speed USB 2.0.
##
## Register map from bouffalo_sdk usb_v2_reg.h.
## This module provides register-level access and basic initialization.

import mmio, memmap

# =============================================================================
# Host Mode Registers (EHCI-compatible)
# =============================================================================
const
  UsbHccap*         = UsbBase + 0x000'u  # Capability: CAPLENGTH[7:0], HCIVERSION[31:16]
  UsbHcsparams*     = UsbBase + 0x004'u  # N_PORTS[3:0]
  UsbHccparams*     = UsbBase + 0x008'u  # Capability params
  UsbUsbcmd*        = UsbBase + 0x010'u  # USB command
  UsbUsbsts*        = UsbBase + 0x014'u  # USB status
  UsbUsbintr*       = UsbBase + 0x018'u  # USB interrupt enable
  UsbFrindex*       = UsbBase + 0x01C'u  # Frame index
  UsbPeriodicBase*  = UsbBase + 0x024'u  # Periodic list base address
  UsbAsyncListAddr* = UsbBase + 0x028'u  # Async list address
  UsbPortsc*        = UsbBase + 0x030'u  # Port status/control
  UsbHcmisc*        = UsbBase + 0x040'u  # Host misc
  UsbFsEof*         = UsbBase + 0x044'u  # FS EOF timing
  UsbHsEof*         = UsbBase + 0x048'u  # HS EOF timing

# =============================================================================
# OTG Registers
# =============================================================================
const
  UsbOtgCsr*        = UsbBase + 0x080'u  # OTG control/status
  UsbOtgIsr*        = UsbBase + 0x084'u  # OTG interrupt status
  UsbOtgIer*        = UsbBase + 0x088'u  # OTG interrupt enable

# =============================================================================
# Global Interrupt Registers
# =============================================================================
const
  UsbGlbIsr*        = UsbBase + 0x0C0'u  # Global interrupt status
  UsbGlbInt*        = UsbBase + 0x0C4'u  # Global interrupt mask

# =============================================================================
# Identification
# =============================================================================
const
  UsbRevision*      = UsbBase + 0x0E0'u  # Revision ID
  UsbFeature*       = UsbBase + 0x0E4'u  # Feature (EP count, FIFO count)
  UsbAxiCr*         = UsbBase + 0x0E8'u  # AXI config

# =============================================================================
# Device Mode Registers
# =============================================================================
const
  UsbDevCtl*        = UsbBase + 0x100'u  # Device control
  UsbDevAdr*        = UsbBase + 0x104'u  # Device address
  UsbDevTst*        = UsbBase + 0x108'u  # Device test
  UsbDevSfn*        = UsbBase + 0x10C'u  # SOF frame number
  UsbDevSmt*        = UsbBase + 0x110'u  # SOF micro-frame timing
  UsbPhyTst*        = UsbBase + 0x114'u  # PHY test
  UsbDevVctl*       = UsbBase + 0x118'u  # Vendor control
  UsbDevCxcfg*      = UsbBase + 0x11C'u  # CX config (VSTA)
  UsbDevCxcfe*      = UsbBase + 0x120'u  # CX completion/FIFO empty
  UsbDevIcr*        = UsbBase + 0x124'u  # Idle counter

  # Interrupt group registers
  UsbDevMigr*       = UsbBase + 0x130'u  # Masked interrupt group
  UsbDevMisg0*      = UsbBase + 0x134'u  # Masked int: CX events
  UsbDevMisg1*      = UsbBase + 0x138'u  # Masked int: FIFO events
  UsbDevMisg2*      = UsbBase + 0x13C'u  # Masked int: USB events
  UsbDevIgr*        = UsbBase + 0x140'u  # Raw interrupt group
  UsbDevIsg0*       = UsbBase + 0x144'u  # Raw int: CX events
  UsbDevIsg1*       = UsbBase + 0x148'u  # Raw int: FIFO events
  UsbDevIsg2*       = UsbBase + 0x14C'u  # Raw int: USB events
  UsbDevRxz*        = UsbBase + 0x150'u  # RX zero-length
  UsbDevTxz*        = UsbBase + 0x154'u  # TX zero-length
  UsbDevIse*        = UsbBase + 0x158'u  # ISO error

  # Endpoint max packet size
  UsbDevInmps1*     = UsbBase + 0x160'u  # IN EP1 max packet (stride 4)
  UsbDevOutmps1*    = UsbBase + 0x180'u  # OUT EP1 max packet (stride 4)

  # Endpoint/FIFO mapping
  UsbDevEpmap0*     = UsbBase + 0x1A0'u  # EP1-4 FIFO mapping
  UsbDevEpmap1*     = UsbBase + 0x1A4'u  # EP5-8 FIFO mapping
  UsbDevFmap*       = UsbBase + 0x1A8'u  # FIFO-to-EP mapping
  UsbDevFcfg*       = UsbBase + 0x1AC'u  # FIFO configuration
  UsbDevFibc0*      = UsbBase + 0x1B0'u  # FIFO0 byte count (stride 4)

  # DMA
  UsbDmaTfn*        = UsbBase + 0x1C0'u  # DMA transfer FIFO number
  UsbDmaCps1*       = UsbBase + 0x1C8'u  # DMA control
  UsbDmaCps2*       = UsbBase + 0x1CC'u  # DMA memory address

  # VDMA
  UsbVdmaCxfps1*    = UsbBase + 0x300'u  # VDMA CX FIFO
  UsbVdmaCtrl*      = UsbBase + 0x330'u  # VDMA control
  UsbDevIsg3*       = UsbBase + 0x328'u  # VDMA interrupt status
  UsbDevMisg3*      = UsbBase + 0x32C'u  # VDMA masked interrupt

# =============================================================================
# USBCMD fields
# =============================================================================
const
  UsbcmdRs*         = 0       # Run/Stop
  UsbcmdHcReset*    = 1       # Host controller reset
  UsbcmdPschEn*     = 4       # Periodic schedule enable
  UsbcmdAschEn*     = 5       # Async schedule enable

# =============================================================================
# USBSTS fields
# =============================================================================
const
  UsbstsInt*        = 0       # USB interrupt
  UsbstsErrInt*     = 1       # USB error interrupt
  UsbstsPoChgDet*   = 2       # Port change detected
  UsbstsHalted*     = 12      # HC halted

# =============================================================================
# PORTSC fields
# =============================================================================
const
  PortscConnSts*    = 0       # Connection status
  PortscConnChg*    = 1       # Connection change
  PortscPoEn*       = 2       # Port enable
  PortscPoEnChg*    = 3       # Port enable change
  PortscPoResm*     = 6       # Force port resume
  PortscPoSusp*     = 7       # Port suspend
  PortscPoReset*    = 8       # Port reset
  PortscLineStsShift* = 10    # Line state [11:10]

# =============================================================================
# OTG_CSR fields
# =============================================================================
const
  OtgBBusReq*       = 0       # B-device bus request
  OtgBHnpEn*        = 1       # B-device HNP enable
  OtgABusReq*       = 4       # A-device bus request
  OtgABusDrop*      = 5       # A-device bus drop
  OtgCrole*         = 20      # Current role (0=host, 1=device)
  OtgId*            = 21      # ID pin state (0=A/host, 1=B/device)
  OtgSpdTypShift*   = 22      # Speed type [23:22]

# =============================================================================
# DEV_CTL fields
# =============================================================================
const
  DevCtlCapRmWkup*  = 0       # Remote wakeup capable
  DevCtlHalfSpeed*  = 1       # Half speed mode
  DevCtlGlintEn*    = 2       # Global interrupt enable
  DevCtlGoSusp*     = 3       # Enter suspend
  DevCtlSfRst*      = 4       # Soft reset
  DevCtlChipEn*     = 5       # Chip enable
  DevCtlHsEn*       = 6       # High-speed enable
  DevCtlForceFs*    = 9       # Force full-speed

# =============================================================================
# DEV_CXCFE fields (endpoint 0 completion)
# =============================================================================
const
  CxDone*           = 0       # CX transfer done
  CxTstPkDone*      = 1       # Test packet done
  CxStl*            = 2       # CX stall
  CxClr*            = 3       # CX clear feature
  CxFul*            = 4       # CX FIFO full
  CxEmp*            = 5       # CX FIFO empty

# =============================================================================
# Interrupt group bits (DEV_IGR / DEV_MIGR)
# =============================================================================
const
  IntG0*            = 0       # CX (endpoint 0) events
  IntG1*            = 1       # FIFO events
  IntG2*            = 2       # USB bus events
  IntG3*            = 3       # VDMA events
  IntG4*            = 4       # LPM events

# =============================================================================
# DEV_ISG2 USB bus event bits
# =============================================================================
const
  Isg2UsbRst*       = 0       # USB reset
  Isg2Susp*         = 1       # Suspend
  Isg2Resm*         = 2       # Resume
  Isg2IsoSeqErr*    = 3       # ISO sequence error
  Isg2Tx0byte*      = 5       # TX zero-length packet
  Isg2Rx0byte*      = 6       # RX zero-length packet
  Isg2DmaCmplt*     = 7       # DMA complete
  Isg2DmaError*     = 8       # DMA error
  Isg2DevIdle*      = 9       # Device idle

# =============================================================================
# Types
# =============================================================================
type
  UsbSpeed* = enum
    usbHighSpeed = 0
    usbFullSpeed = 1

  UsbRole* = enum
    usbHost
    usbDevice

# =============================================================================
# USB Device Mode initialization
# =============================================================================
proc usbDeviceInit*(highSpeed: bool = true) =
  ## Initialize USB in device mode (FOTG210).
  # Soft reset
  regSet(UsbDevCtl, 1'u32 shl DevCtlSfRst)
  for i in 0 ..< 1000: discard regRead(UsbDevCtl)
  regClear(UsbDevCtl, 1'u32 shl DevCtlSfRst)

  # Configure device control
  var ctl = (1'u32 shl DevCtlChipEn) or (1'u32 shl DevCtlGlintEn)
  if highSpeed:
    ctl = ctl or (1'u32 shl DevCtlHsEn)
  else:
    ctl = ctl or (1'u32 shl DevCtlForceFs)
  regWrite(UsbDevCtl, ctl)

  # Clear all interrupts
  discard regRead(UsbDevIsg0)
  discard regRead(UsbDevIsg1)
  discard regRead(UsbDevIsg2)

proc usbDeviceSetAddress*(addr: uint8) =
  regWrite(UsbDevAdr, addr.uint32 and 0x7F)

proc usbDeviceGetFrameNumber*(): uint32 =
  regRead(UsbDevSfn) and 0x7FF

# =============================================================================
# CX (Control Endpoint 0) operations
# =============================================================================
proc usbCxDone*() =
  ## Signal that EP0 transfer is complete.
  regSet(UsbDevCxcfe, 1'u32 shl CxDone)

proc usbCxStall*() =
  ## Stall EP0.
  regSet(UsbDevCxcfe, 1'u32 shl CxStl)

proc usbCxFifoEmpty*(): bool =
  (regRead(UsbDevCxcfe) and (1'u32 shl CxEmp)) != 0

proc usbCxFifoFull*(): bool =
  (regRead(UsbDevCxcfe) and (1'u32 shl CxFul)) != 0

# =============================================================================
# Endpoint configuration
# =============================================================================
proc usbSetInEpMaxPacket*(ep: uint32, maxPkt: uint32) =
  ## Set max packet size for an IN endpoint (1-8).
  if ep >= 1 and ep <= 8:
    let addr = UsbDevInmps1 + (ep - 1) * 4
    regModify(addr, 0x7FF'u32, maxPkt and 0x7FF)

proc usbSetOutEpMaxPacket*(ep: uint32, maxPkt: uint32) =
  if ep >= 1 and ep <= 8:
    let addr = UsbDevOutmps1 + (ep - 1) * 4
    regModify(addr, 0x7FF'u32, maxPkt and 0x7FF)

proc usbStallInEp*(ep: uint32) =
  if ep >= 1 and ep <= 8:
    regSet(UsbDevInmps1 + (ep - 1) * 4, 1'u32 shl 11)

proc usbStallOutEp*(ep: uint32) =
  if ep >= 1 and ep <= 8:
    regSet(UsbDevOutmps1 + (ep - 1) * 4, 1'u32 shl 11)

proc usbResetToggleInEp*(ep: uint32) =
  if ep >= 1 and ep <= 8:
    regSet(UsbDevInmps1 + (ep - 1) * 4, 1'u32 shl 12)

proc usbResetToggleOutEp*(ep: uint32) =
  if ep >= 1 and ep <= 8:
    regSet(UsbDevOutmps1 + (ep - 1) * 4, 1'u32 shl 12)

# =============================================================================
# FIFO configuration
# =============================================================================
proc usbGetFifoByteCount*(fifo: uint32): uint32 =
  ## Read the byte count in a FIFO (0-3).
  if fifo <= 3:
    regRead(UsbDevFibc0 + fifo * 4) and 0x7FF
  else: 0

# =============================================================================
# Interrupt status
# =============================================================================
proc usbReadGlobalInt*(): uint32 =
  ## Read the global interrupt status register.
  regRead(UsbGlbIsr)

proc usbIsDeviceMode*(): bool =
  (regRead(UsbGlbIsr) and 1) != 0  # DEV_INT

proc usbReadDeviceIntGroup*(): uint32 =
  regRead(UsbDevIgr)

proc usbReadCxEvents*(): uint32 =
  regRead(UsbDevIsg0)

proc usbReadFifoEvents*(): uint32 =
  regRead(UsbDevIsg1)

proc usbReadBusEvents*(): uint32 =
  regRead(UsbDevIsg2)

# =============================================================================
# OTG role detection
# =============================================================================
proc usbGetRole*(): UsbRole =
  if (regRead(UsbOtgCsr) and (1'u32 shl OtgCrole)) != 0:
    usbDevice
  else:
    usbHost

proc usbIsIdDevice*(): bool =
  ## Returns true if ID pin indicates device (B-device).
  (regRead(UsbOtgCsr) and (1'u32 shl OtgId)) != 0

# =============================================================================
# Host Mode operations
# =============================================================================
proc usbHostReset*() =
  regSet(UsbUsbcmd, 1'u32 shl UsbcmdHcReset)
  var timeout = 100_000'u32
  while (regRead(UsbUsbcmd) and (1'u32 shl UsbcmdHcReset)) != 0:
    timeout.dec
    if timeout == 0: break

proc usbHostStart*() =
  regSet(UsbUsbcmd, 1'u32 shl UsbcmdRs)

proc usbHostStop*() =
  regClear(UsbUsbcmd, 1'u32 shl UsbcmdRs)

proc usbHostPortReset*() =
  regSet(UsbPortsc, 1'u32 shl PortscPoReset)
  for i in 0 ..< 50000: discard regRead(UsbPortsc)
  regClear(UsbPortsc, 1'u32 shl PortscPoReset)

proc usbHostPortConnected*(): bool =
  (regRead(UsbPortsc) and (1'u32 shl PortscConnSts)) != 0
