## BL808 EMI (External Memory Interface) / XRAM controller driver.
##
## EMI_MISC at 0x20050000 — controls the shared XRAM (16 KB)
## used for inter-processor communication between M0, D0, and LP cores.

import mmio, memmap

# =============================================================================
# EMI register offsets
# =============================================================================
const
  EmiCtrl*          = EmiMiscBase + 0x00'u  # EMI control
  EmiClkCfg*        = EmiMiscBase + 0x04'u  # EMI clock configuration
  EmiRamCfg*        = EmiMiscBase + 0x08'u  # RAM configuration
  EmiProt*          = EmiMiscBase + 0x0C'u  # Protection configuration
  EmiIntSts*        = EmiMiscBase + 0x10'u  # Interrupt status
  EmiIntMask*       = EmiMiscBase + 0x14'u  # Interrupt mask
  EmiIntClr*        = EmiMiscBase + 0x18'u  # Interrupt clear

# =============================================================================
# EMI control fields
# =============================================================================
const
  EmiEn*            = 0       # EMI enable
  EmiArbModeShift*  = 4       # Arbitration mode [5:4]
  EmiArbModeMask*   = 0x03'u32 shl 4

# =============================================================================
# Types
# =============================================================================
type
  EmiArbMode* = enum
    emiArbFixed     = 0  # Fixed priority (M0 > D0 > LP)
    emiArbRoundRobin = 1 # Round-robin

# =============================================================================
# EMI operations
# =============================================================================
proc emiInit*(arbMode: EmiArbMode = emiArbRoundRobin) =
  ## Initialize the EMI/XRAM controller.
  var ctrl = (1'u32 shl EmiEn) or (arbMode.uint32 shl EmiArbModeShift)
  regWrite(EmiCtrl, ctrl)

proc emiSetArbitration*(mode: EmiArbMode) =
  regModify(EmiCtrl, EmiArbModeMask, mode.uint32 shl EmiArbModeShift)

proc emiEnable*() =
  regSet(EmiCtrl, 1'u32 shl EmiEn)

proc emiDisable*() =
  regClear(EmiCtrl, 1'u32 shl EmiEn)
