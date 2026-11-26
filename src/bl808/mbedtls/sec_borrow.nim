## What the SEC_ENG and PKA borrowers (the *_alt.nim providers) share on the M0.

import ../[core, memmap]

proc secIrqSave*(): uint32 {.inline.} =
  ## Mask interrupts for one engine operation; returns the previous MIE bit.
  result = csrReadMstatus().uint32 and 8'u32
  disableInterrupts()

proc secIrqRestore*(saved: uint32) {.inline.} =
  if (saved and 8) != 0: enableInterrupts()

proc dmaVisible*(address, size: uint): bool {.inline.} =
  ## The engine's DMA reads and writes physical memory behind the M0 data
  ## cache. Only uncached WRAM is used, as by the Wi-Fi SHA-1 provider.
  address >= WramBase and address <= WramBase + WramSize.uint - size

var pkaClaimed*: bool
  ## The RSA provider is running a program on the PKA (rsa_engine.nim claims
  ## it with interrupts off; the P-256 provider stays away meanwhile).
