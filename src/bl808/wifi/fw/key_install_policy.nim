## Pure key-install policy helpers shared by firmware and host fuzzers.

proc wifiCipherIsBip*(cipherType: uint8): bool {.inline.} =
  ## BIP is software-managed and uses the VIF's separate management-key pointer.
  cipherType == 5'u8

proc wifiKeyUsesDirectReplayPn*(cipherType, pairwise: uint8): bool {.inline.} =
  ## Pairwise data keys use the replay window; group data and BIP store next PN.
  pairwise == 0'u8 or wifiCipherIsBip(cipherType)
