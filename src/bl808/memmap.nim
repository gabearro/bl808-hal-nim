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
  GpipBase*         = 0x2000_2000'u  # General Purpose I/P
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
  Lz4dBase*         = 0x2000_AD00'u

  SfCtrlBase*       = 0x2000_B000'u  # Serial flash controller
  SfCtrlBufBase*    = 0x2000_B600'u

  Dma0Base*         = 0x2000_C000'u  # DMA0 (8 channels)
  PdsBase*          = 0x2000_E000'u  # Power Down Sleep
  HbnBase*          = 0x2000_F000'u  # Hibernate / Always-On

  EmiMiscBase*      = 0x2005_0000'u  # XRAM/EMI control
  PsramCtrlBase*    = 0x2005_2000'u  # PSRAM controller
  AuadcBase*        = 0x2000_AC00'u  # Audio ADC (AUADC)
  AudacBase*        = 0x2005_5000'u  # Audio DAC (AUDAC)
  AudioBase*        = AudacBase      # Alias for backwards compat
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

  SubMiscBase*      = 0x3001_0000'u  # Sub-system misc
  Dvp0Base*         = 0x3001_2000'u  # DVP camera (8 instances, stride 0x100)
  OsdABase*         = 0x3001_3000'u  # OSD layer A
  OsdBBase*         = 0x3001_4000'u  # OSD layer B
  OsdDpBase*        = 0x3001_5000'u  # OSD display pipeline
  MipiCsiBase*      = 0x3001_A000'u  # MIPI CSI
  MipiDsiBase*      = 0x3001_A100'u  # MIPI DSI
  DbiBase*          = 0x3001_B000'u  # DBI display
  CodecMiscBase*    = 0x3002_0000'u  # Codec misc
  MjpegBase*        = 0x3002_1000'u  # MJPEG encoder
  H264Base*         = 0x3002_2000'u  # H.264 encoder
  MjpegDecBase*     = 0x3002_3000'u  # MJPEG decoder
  BlaiBase*         = 0x3002_4000'u  # NPU (BLAI)

# =============================================================================
# Interrupt controllers
# =============================================================================
const
  # D0 PLIC (T-Head modified)
  PlicBase*         = 0xE000_0000'u
  PlicPriorityBase* = 0xE000_0004'u  # IRQ 1 priority (4 bytes each)
  PlicPendingBase*  = 0xE000_1000'u
  PlicEnableBase*   = 0xE000_2000'u  # M-mode enable base
  PlicSEnableBase*  = 0xE000_2080'u  # S-mode enable base
  PlicThresholdM*   = 0xE020_0000'u  # M-mode threshold
  PlicClaimM*       = 0xE020_0004'u  # M-mode claim/complete
  PlicThresholdS*   = 0xE020_1000'u  # S-mode threshold
  PlicClaimS*       = 0xE020_1004'u  # S-mode claim/complete

  # M0 CLIC
  ClicBase*         = 0xE000_0000'u  # E907 CLIC base
  ClicMsipBase*     = 0xE000_0000'u
  ClicMtimeBase*    = 0xE000_BFF8'u
  ClicMtimecmpBase* = 0xE000_4000'u
  ClicIntipBase*    = 0xE800_0000'u
  ClicIntieBase*    = 0xE800_0400'u
  ClicIntcfgBase*   = 0xE800_0800'u
  ClicCfgBase*      = 0xE800_0C00'u

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
  Ox64D0BootOffset*     = 0x10_0000'u       # D0 low-load bootloader
  Ox64MainImageOffset*  = 0x80_0000'u       # Main image

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
