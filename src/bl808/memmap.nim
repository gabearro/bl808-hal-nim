## BL808 complete memory map.
##
## Covers all three subsystems: MCU (M0/LP), MM (D0), and shared regions.

# =============================================================================
# Core identification
# =============================================================================
const
  CoreIdAddr*       = 0xF000_0000'u
  CoreIdM0*         = 0xE907_0000'u32
  CoreIdD0*         = 0xDEAD_5500'u32
  CoreIdLP*         = 0xDEAD_E902'u32

# =============================================================================
# RAM regions
# =============================================================================
const
  # MCU subsystem (M0/LP)
  OcramBase*        = 0x2202_0000'u  # 64 KB, non-cached
  OcramCachedBase*  = 0x6202_0000'u
  OcramSize*        = 64 * 1024

  WramBase*         = 0x2203_0000'u  # 160 KB, non-cached
  WramCachedBase*   = 0x6203_0000'u
  WramSize*         = 160 * 1024

  # MM subsystem (D0)
  DramBase*         = 0x3EF8_0000'u  # 512 KB, non-cached
  DramCachedBase*   = 0x7EF8_0000'u
  DramSize*         = 512 * 1024

  VramBase*         = 0x3F00_0000'u  # 32 KB, non-cached
  VramCachedBase*   = 0x7F00_0000'u
  VramSize*         = 32 * 1024

  # Shared / external
  XramBase*         = 0x4000_0000'u  # 16 KB, IPC shared memory
  XramSize*         = 16 * 1024

  PsramBase*        = 0x5000_0000'u  # 64 MB external pSRAM
  PsramSize*        = 64 * 1024 * 1024

  HbnRamBase*       = 0x2001_0000'u  # HBN retention RAM

# =============================================================================
# Flash XIP regions
# =============================================================================
const
  FlashXipBase*     = 0x5800_0000'u  # 64 MB XIP window
  FlashXip2Base*    = 0x5C00_0000'u  # Second flash XIP window
  FlashRemapBase*   = 0xD800_0000'u  # Remap of flash XIP

# =============================================================================
# MCU peripheral base addresses (M0/LP accessible)
# =============================================================================
const
  GlbBase*          = 0x2000_0000'u  # Global control
  MixBase*          = 0x2000_1000'u  # RF / Mixed signal
  RfBase*           = 0x2000_1000'u  # RF (alias of MixBase)
  GpipBase*         = 0x2000_2000'u  # General Purpose I/P
  PhyBase*          = 0x2000_2800'u  # WiFi/BLE PHY registers
  AgcBase*          = 0x2000_2C00'u  # AGC (Automatic Gain Control)
  SecDbgBase*       = 0x2000_3000'u  # Secure debug
  SecEngBase*       = 0x2000_4000'u  # Security engine (AES/SHA/TRNG)
  TzcSecBase*       = 0x2000_5000'u  # TrustZone secure
  TzcNsecBase*      = 0x2000_6000'u  # TrustZone non-secure
  CciBase*          = 0x2000_8000'u  # Cache Coherency Interface
  McuMiscBase*      = 0x2000_9000'u  # MCU misc / L1C

  Uart0Base*        = 0x2000_A000'u
  Uart1Base*        = 0x2000_A100'u
  Spi0Base*         = 0x2000_A200'u
  I2c0Base*         = 0x2000_A300'u
  PwmBase*          = 0x2000_A400'u
  Timer0Base*       = 0x2000_A500'u
  IrBase*           = 0x2000_A600'u
  CksBase*          = 0x2000_A700'u
  Ipc0Base*         = 0x2000_A800'u  # IPC M0 mailbox
  Ipc1Base*         = 0x2000_A840'u  # IPC LP mailbox
  I2c1Base*         = 0x2000_A900'u
  Uart2Base*        = 0x2000_AA00'u
  I2sBase*          = 0x2000_AB00'u
  AuadcBase*        = 0x2000_AC00'u  # Audio ADC / PDM
  Lz4dBase*         = 0x2000_AD00'u

  SfCtrlBase*       = 0x2000_B000'u  # Serial flash controller
  SfCtrlBufBase*    = 0x2000_B600'u

  Dma0Base*         = 0x2000_C000'u  # DMA0 (8 channels)
  PdsBase*          = 0x2000_E000'u  # Power Down Sleep
  HbnBase*          = 0x2000_F000'u  # Hibernate / Always-On

  EmiMiscBase*      = 0x2005_0000'u  # XRAM/EMI control
  PsramCtrlBase*    = 0x2005_2000'u  # PSRAM controller
  AudioBase*        = 0x2005_5000'u  # Audio codec (AUDAC)
  AudacBase*        = AudioBase      # Audio DAC alias
  EfCtrlBase*       = 0x2005_6000'u  # eFuse control
  SdhBase*          = 0x2006_0000'u  # SD Host
  EmacBase*         = 0x2007_0000'u  # Ethernet MAC
  Dma1Base*         = 0x2007_1000'u  # DMA1
  UsbBase*          = 0x2007_2000'u  # USB 2.0 OTG

# =============================================================================
# MM (Multimedia) peripheral base addresses (D0 accessible)
# =============================================================================
const
  MmMiscBase*       = 0x3000_0000'u  # MM Miscellaneous
  Dma2Base*         = 0x3000_1000'u  # DMA2 (8 channels, D0)
  Uart3Base*        = 0x3000_2000'u  # UART3 (D0)
  I2c2Base*         = 0x3000_3000'u  # I2C2 (D0)
  I2c3Base*         = 0x3000_4000'u  # I2C3 (D0)
  Ipc2Base*         = 0x3000_5000'u  # IPC D0 mailbox
  Dma2dBase*        = 0x3000_6000'u  # 2D DMA
  MmGlbBase*        = 0x3000_7000'u  # MM Global / Clock Reset
  Spi1Base*         = 0x3000_8000'u  # SPI1 (D0)
  Timer1Base*       = 0x3000_9000'u  # Timer1 (D0)
  PsramUhsBase*     = 0x3000_F000'u  # PSRAM UHS controller

  CamFrontBase*     = 0x3001_0000'u  # Camera front-end / sub-misc mux
  SubMiscBase*      = 0x3001_0000'u  # Alias for CamFrontBase
  MmSubsysBase*     = 0x3001_1000'u  # MM subsystem control
  Dvp0Base*         = 0x3001_2000'u  # DVP camera 0
  Dvp1Base*         = 0x3001_2100'u  # DVP camera 1
  Dvp2Base*         = 0x3001_2200'u  # DVP camera 2
  Dvp3Base*         = 0x3001_2300'u  # DVP camera 3
  Dvp4Base*         = 0x3001_2400'u  # DVP camera 4
  Dvp5Base*         = 0x3001_2500'u  # DVP camera 5
  Dvp6Base*         = 0x3001_2600'u  # DVP camera 6
  Dvp7Base*         = 0x3001_2700'u  # DVP camera 7
  DvpTsrc0Base*     = 0x3001_2800'u  # DVP timing source 0
  DvpTsrc1Base*     = 0x3001_2900'u  # DVP timing source 1
  AxiCtrlNr3dBase*  = 0x3001_2A00'u  # AXI NR3D control
  OsdProbeBase*     = 0x3001_2B00'u  # OSD probe
  OsdABase*         = 0x3001_3000'u  # OSD layer A
  OsdBBase*         = 0x3001_4000'u  # OSD layer B
  OsdDpBase*        = 0x3001_5000'u  # OSD display pipeline
  MipiBase*         = 0x3001_A000'u  # MIPI base (CSI)
  MipiCsiBase*      = 0x3001_A000'u  # MIPI CSI
  MipiDsiBase*      = 0x3001_A100'u  # MIPI DSI
  DbiBase*          = 0x3001_B000'u  # DBI display
  CodecMiscBase*    = 0x3002_0000'u  # Codec misc
  MjpegBase*        = 0x3002_1000'u  # MJPEG encoder
  VideoBase*        = 0x3002_2000'u  # H.264/video encoder
  H264Base*         = 0x3002_2000'u  # Alias for VideoBase
  MjpegDecBase*     = 0x3002_3000'u  # MJPEG decoder
  BlCnnBase*        = 0x3002_4000'u  # NPU (BLAI/CNN)
  BlaiBase*         = 0x3002_4000'u  # Alias for BlCnnBase

# =============================================================================
# Interrupt controllers
# =============================================================================
#
# Real hardware per-CPU address space (private bus at 0xE0000000):
#
#   M0 (hart 0): CLINT at 0xE0000000, CLIC at 0xE0800000
#     MSIP=0xE0000000, mtimecmp=0xE0004000, mtime=0xE000BFF8
#     CLIC cfg at 0xE0800000, per-IRQ regs at 0xE0801000+4*i
#       +0: intip  +1: intie  +2: intattr  +3: intctl
#
#   LP (hart 2): Separate CLINT+CLIC at 0xE0000000/0xE0800000 (same layout)
#     mtimecmp=0xE0004000, mtime=0xE000BFF8 (shared clock with M0)
#
#   D0 (hart 1): PLIC at 0xE0000000, D0 CLINT at 0xE4000000
#     PLIC: priority=+0x4, pending=+0x1000, enable=+0x2000, ctx=+0x200000
#     D0 CLINT: mtimecmp=0xE4004000, mtime=0xE400BFF8
#
# QEMU now uses per-CPU address spaces, so all cores see the same
# addresses as real hardware. No address overrides needed.

const
  # D0 PLIC at 0xE0000000 (D0 private bus view)
  PlicBase*         = 0xE000_0000'u
  PlicPriorityBase* = 0xE000_0004'u
  PlicPendingBase*  = 0xE000_1000'u
  PlicEnableBase*   = 0xE000_2000'u
  PlicSEnableBase*  = 0xE000_2080'u
  PlicThresholdM*   = 0xE020_0000'u
  PlicClaimM*       = 0xE020_0004'u
  PlicThresholdS*   = 0xE020_1000'u
  PlicClaimS*       = 0xE020_1004'u

const
  # D0 CLINT at 0xE4000000 (D0 private bus view)
  D0ClintMtimecmpBase* = 0xE400_4000'u  # mtimecmp at +0x4000
  D0ClintMtimeBase*    = 0xE400_BFF8'u  # mtime at +0xBFF8

const
  # LP CLINT at 0xE0000000 (LP private bus view, own instance)
  LpClintMtimecmpBase* = 0xE000_4000'u  # mtimecmp at +0x4000
  LpClintMtimeBase*    = 0xE000_BFF8'u  # mtime (shared clock with M0)

const
  # M0 CLIC/CLINT at 0xE0000000 (M0 private bus view)
  ClicBase*         = 0xE000_0000'u  # E907 CLINT base
  ClicMsipBase*     = 0xE000_0000'u
  ClicMtimeBase*    = 0xE000_BFF8'u
  ClicMtimecmpBase* = 0xE000_4000'u

  # T-Head CLIC interrupt controller at 0xE0800000
  # Per-IRQ registers at base+0x1000, packed as 4-byte structs:
  #   byte +0: intip (pending), +1: intie (enable),
  #   byte +2: intattr (attribute), +3: intctl (priority/level)
  ClicCtrlBase*     = 0xE080_0000'u  # CLIC config register (cliccfg)
  ClicInfoBase*     = 0xE080_0004'u  # CLIC info register (clicinfo)
  ClicMintThresh*   = 0xE080_0008'u  # Machine interrupt threshold
  ClicIntBase*      = 0xE080_1000'u  # Per-IRQ register array
  ClicIntStride*    = 4'u            # Bytes per IRQ entry

# =============================================================================
# GPIO configuration base (inside GLB)
# =============================================================================
const
  GpioConfigBase*   = GlbBase + 0x8C4  # GPIO_CFG0 (pin 0)
  GpioPinCount*     = 46               # BL808 has GPIO0..GPIO45

# =============================================================================
# Ox64 flash layout (128 Mbit = 16 MB)
# =============================================================================
const
  Ox64FlashSize*        = 16 * 1024 * 1024  # 16 MB
  Ox64M0FwOffset*       = 0x00_0000'u       # M0 firmware
  Ox64LPBootOffset*     = 0x08_0000'u       # LP firmware XIP image
  Ox64D0BootOffset*     = 0x10_0000'u       # D0 low-load bootloader
  Ox64MainImageOffset*  = 0x80_0000'u       # Main image

  # Flash-resident WASM executable cache. Keep this below the LittleFS region
  # while the top-of-flash protection state is still being characterized.
  Ox64WasmStoreSize*    = 1 * 1024 * 1024
  Ox64WasmStoreOffset*  = 0x70_0000'u
  Ox64WasmSlotSize*     = 64 * 1024
  Ox64WasmSlotCount*    = Ox64WasmStoreSize div Ox64WasmSlotSize

# =============================================================================
# IPC synchronization addresses (in XRAM)
# =============================================================================
const
  IpcSyncAddr1*     = 0x4000_0000'u
  IpcSyncAddr2*     = 0x4000_0004'u
  IpcSyncFlag*      = 0x1234_5678'u32
  IpcDataBase*      = 0x4000_0008'u  # Start of IPC message buffers

# =============================================================================
# Clock configuration storage (in HBN RAM)
# =============================================================================
const
  ClkCfgAddr*       = HbnRamBase + 4 * 1024 - 512  # 0x20010E00
  ClkCfgMagic*      = 0x1234_5678'u32
