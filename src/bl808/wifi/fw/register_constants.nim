# =============================================================================
# MAC HW register base addresses (from BL808 vendor WiFi firmware)
# =============================================================================
const
  MACHW_BASE*          = 0x24B00000'u
  MACHW_INTC_BASE      = 0x24B08000'u
  MACHW_CTRL_REG       = MACHW_BASE + 0x000'u
  MACHW_STATE_CNTRL_REG = MACHW_BASE + 0x038'u # State machine control (current/next state)
  MACHW_STATUS_REG     = MACHW_BASE + 0x04C'u  # MAC status / gen_int control
  MACHW_EDCA_CCA_BUSY  = MACHW_BASE + 0x050'u
  MACHW_DOZE_CNTRL2_REG = MACHW_BASE + 0x054'u # Doze/power control register 2
  MACHW_RX_CNTRL_REG  = MACHW_BASE + 0x060'u  # RX control / filter register
  MACHW_RNG_REG        = MACHW_BASE + 0x0A0'u  # TRNG register
  MACHW_TX_POWER_REG   = MACHW_BASE + 0x0A0'u  # TX power control (shared with RNG reg)
  MACHW_TIMLO_REG      = MACHW_BASE + 0x120'u  # MAC timestamp low
  MACHW_ABS_TIMER_REG  = MACHW_BASE + 0x144'u  # Absolute timer target
  MACHW_BCN_STATUS_REG = MACHW_BASE + 0x400'u  # Beacon status
  MACHW_BCN_INT_REG    = MACHW_BASE + 0x064'u  # Beacon interval register (lower 16 bits)
  MACHW_EDCA_AC_BK_REG = MACHW_BASE + 0x200'u  # EDCA AC_BK params register
  MACHW_EDCA_AC_BE_REG = MACHW_BASE + 0x204'u  # EDCA AC_BE params register
  MACHW_EDCA_AC_VI_REG = MACHW_BASE + 0x208'u  # EDCA AC_VI params register
  MACHW_EDCA_AC_VO_REG = MACHW_BASE + 0x20C'u  # EDCA AC_VO params register

  # MAC platform registers (intc)
  MAC_PL_IRQ_STATUS0   = 0x24910000'u  # MAC platform IRQ status reg 0
  MAC_PL_IRQ_STATUS1   = 0x24910004'u  # MAC platform IRQ status reg 1
  MAC_PL_IRQ_HANDLER   = 0x24910040'u  # MAC platform IRQ handler index reg

  # Interrupt controller banked enable registers
  INTC_IRQ_ENABLE_BASE = 0x24910010'u  # Blob-space base for IRQ enable set regs

  IPC_REG_BASE*        = 0x24800000'u
  # Match the BL808 vendor WiFi firmware register map.  The 0x44800000 alias
  # does not expose the IPC magic register on the tested M0 hardware.
  IPC_EMB_MAGIC_REG    = IPC_REG_BASE + 0x140'u  # Must read 0x49504332
  IPC_EMB_STATUS_REG   = IPC_REG_BASE + 0x100'u  # IPC config register
  IPC_EMB_UNMASK_SET   = IPC_REG_BASE + 0x10C'u  # unmask set
  IPC_EMB_UNMASK_CLR   = IPC_REG_BASE + 0x110'u  # unmask clear
  IPC_EMB_RAW_STATUS   = IPC_REG_BASE + 0x114'u
  IPC_EMB_ACK          = IPC_REG_BASE + 0x118'u
  IPC_EMB_STATUS2      = IPC_REG_BASE + 0x11C'u  # TX status

  INTC_BASE            = 0x40000000'u
  INTC_PEND_REG        = INTC_BASE + 0x010'u

  COEX_BASE            = 0x24920000'u  # PTA coex registers
  COEX_CTRL_REG        = COEX_BASE + 0x004'u

  # MAC platform registers.
  MAC_PL_BASE          = 0x24900000'u
  DIAG_SW_REG          = MAC_PL_BASE + 0x070'u  # Diagnostic SW trigger (write 1 then 0)
  MAC_PL_CTRL_REG      = MAC_PL_BASE + 0x084'u  # Platform control (bit 0 = clock enable)

  IPC_IRQ_TX_MASK      = 0x1F00'u32   # bits 8..12 for TX descriptors
  IPC_IRQ_MSG          = 0x01'u32
  IPC_IRQ_TBTT         = 0x02'u32

  IPC_MAGIC_VALUE      = 0x49504332'u32
  SCAN_ACTIVE_RX_FILTER_BITS = 0x2200'u32
  SCAN_PASSIVE_RX_FILTER_BITS = 0x2000'u32
  SCAN_EDCA_RX_FILTER_CLEAR_MASK = 0xFFFFDDFF'u32
  SCAN_DEFAULT_DURATION_US = 0x35B60'u32
  SCAN_STATUS_OK = 0'u8
  SCAN_STATUS_BUSY = 8'u8
  WifiTimerDrainLimit = 8'u32
  WifiIpcMsgDrainLimit = 8'u32
  WifiIpcTxDrainLimit = 16'u32
  WifiSavedMsgDrainLimit = 8'u32
  WifiTxCfmDrainLimit = 16'u32
  WifiTxTriggerDrainLimit = 16'u32
  WifiTxFrameDrainLimit = 16'u32
  WifiRxTimerDrainLimit = 16'u32
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint

when defined(bl808WifiForceTxPwr70):
  const NimFwForcedMgmtTxPower = 0x70'u32
elif defined(bl808WifiForceTxPwr30):
  const NimFwForcedMgmtTxPower = 0x30'u32
elif defined(bl808WifiForceTxPwr20):
  const NimFwForcedMgmtTxPower = 0x20'u32

