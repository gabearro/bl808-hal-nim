# BL808 demo phy_trpc.o:.data.txpwr_vs_rate_table, three eight-byte groups.
var bl808TrpcPowerByRate: array[3, array[8, uint8]] = [
  [20'u8, 20, 20, 20, 20, 20, 20, 20],
  [18'u8, 18, 18, 18, 18, 18, 16, 16],
  [18'u8, 18, 18, 18, 18, 16, 16, 16]]

proc encodeBl808TrpcPower(power: int32): int8 {.inline.} =
  let encoded =
    if power <= 13: 0xE8 + (max(power, 10) - 10) * 4
    else: power * 4 and 0xFF
  cast[int8](encoded.uint8)

proc bl808DefaultTrpcPowerIndex(rateType: uint32; rate: uint8): int8 =
  let group = min(rateType, 2'u32).int
  let index = min(rate.int, if group == 0: 3 else: 7)
  encodeBl808TrpcPower(cast[int8](bl808TrpcPowerByRate[group][index]).int32)

proc initBl808TrpcEnv() =
  # Demo trpc_init preserves byte 3 between the two sets of fields.
  trpcEnv[0] = (trpcEnv[0] and 0xFF000000'u32) or 0x001E0A19'u32
  trpcEnv[1] = 0x0019098A'u32
