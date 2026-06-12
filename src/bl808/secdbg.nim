## BL808 secure-debug controller (SEC_DBG @ 0x20003000).
##
## Exposes the unique chip id and the tiered debug-password mechanism that
## gates JTAG access once a chip is provisioned. On an unprovisioned chip the
## debug mode reads "open"; burning eFuse `dbg_mode` switches it to password or
## closed, after which `secDbgLoadPassword` must present the matching word pair.
##
## Register map verified against the vendored `sec_dbg_reg.h` and read back on
## real silicon (chip id and status fields confirmed).

import mmio, memmap

const
  SdBase*        = SecDbgBase           # 0x20003000
  SdChipIdLow*   = SdBase + 0x00'u      # unique chip id, low word
  SdChipIdHigh*  = SdBase + 0x04'u      # unique chip id, high word
  SdDbgPwdLow*   = SdBase + 0x08'u      # debug password word 0
  SdDbgPwdHigh*  = SdBase + 0x0C'u      # debug password word 1
  SdDbgPwd2Low*  = SdBase + 0x10'u      # debug password 2 word 0
  SdDbgPwd2High* = SdBase + 0x14'u      # debug password 2 word 1
  SdStatus*      = SdBase + 0x18'u      # status / control

  # Status register fields
  SdBusy*        = 0                    # password compare busy
  SdTrig*        = 1                    # trigger password compare (write 1)
  SdCciReadEn*   = 2
  SdCciClkSel*   = 3
  SdPwdCntShift* = 4                    # [23:4] failed-attempt counter (RO)
  SdPwdCntMask*  = 0xFFFFF'u32 shl SdPwdCntShift
  SdDbgModeShift* = 24                  # [27:24] active debug mode (RO)
  SdDbgModeMask* = 0xF'u32 shl SdDbgModeShift
  SdDbgEnaShift* = 28                   # [31:28] debug-enable lanes (RO)
  SdDbgEnaMask*  = 0xF'u32 shl SdDbgEnaShift

type
  SecDbgMode* = enum
    ## Active debug policy reported in the status register.
    sdModeOpen     = 0   ## JTAG/debug fully open (unprovisioned)
    sdModePassword = 1   ## password required to unlock
    sdModeClosed   = 4   ## debug permanently closed

proc secDbgChipId*(): uint64 =
  ## Read the 64-bit unique chip id. Reliable even when eFuse chip-id words
  ## read back zero, so prefer this as the device identity source.
  (regRead(SdChipIdHigh).uint64 shl 32) or regRead(SdChipIdLow).uint64

proc secDbgModeRaw*(): uint32 {.inline.} =
  (regRead(SdStatus) and SdDbgModeMask) shr SdDbgModeShift

proc secDbgMode*(): SecDbgMode =
  ## Decode the active debug mode (open / password / closed).
  case secDbgModeRaw()
  of 1: sdModePassword
  of 4: sdModeClosed
  else: sdModeOpen

proc secDbgEnableLanes*(): uint32 {.inline.} =
  ## The [31:28] debug-enable field (0xF = all lanes enabled / fully open).
  (regRead(SdStatus) and SdDbgEnaMask) shr SdDbgEnaShift

proc secDbgFailedAttempts*(): uint32 {.inline.} =
  (regRead(SdStatus) and SdPwdCntMask) shr SdPwdCntShift

proc secDbgLoadPassword*(pwd, pwd2: array[2, uint32],
                         timeout: uint32 = 100_000): bool =
  ## Present a debug password pair and trigger the compare. Returns false on
  ## timeout. A successful compare unlocks debug for a password-mode chip; the
  ## actual unlock result is observed via the platform debug enable lanes.
  regWrite(SdDbgPwdLow, pwd[0])
  regWrite(SdDbgPwdHigh, pwd[1])
  regWrite(SdDbgPwd2Low, pwd2[0])
  regWrite(SdDbgPwd2High, pwd2[1])
  regSet(SdStatus, 1'u32 shl SdTrig)
  var countdown = timeout
  while (regRead(SdStatus) and (1'u32 shl SdBusy)) != 0:
    if countdown == 0:
      return false
    countdown.dec
  true
