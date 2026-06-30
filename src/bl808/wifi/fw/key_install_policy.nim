## Pure key-install policy helpers shared by firmware and host fuzzers.

proc wifiCipherIsCcmpGroup*(cipherType: uint8): bool {.inline.} =
  ## The supplicant set_key path translates 16-byte CCMP keys to cipher 2.
  ## Some recovered vendor comments/paths label the same group-key role as 5.
  cipherType == 2'u8 or cipherType == 5'u8

proc wifiCipherUsesGroupReplayPn*(cipherType, hasRxPn: uint8): bool {.inline.} =
  ## When the host supplies a PN, CCMP group keys must seed the shared group
  ## replay counters even when has_rx_pn is set.
  hasRxPn == 0'u8 or wifiCipherIsCcmpGroup(cipherType)
