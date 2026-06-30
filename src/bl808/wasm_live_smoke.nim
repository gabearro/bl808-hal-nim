## Shared constants for the all-core live WASM+CPS smoke.

import ./memmap
import ./wasm_slot_smoke

const
  WasmLiveAddSlot* = WasmSlotSmokeSlot
  WasmLiveSumSlot* = 5'u32

  WasmLiveOk* = 0x574C_5600'u32
  WasmLiveInstallFailed* = 0x574C_5601'u32
  WasmLiveAddFailed* = 0x574C_5602'u32
  WasmLiveSumFailed* = 0x574C_5603'u32
  WasmLiveHeartbeatStarved* = 0x574C_5604'u32
  WasmLiveEnclaveFailed* = 0x574C_5605'u32
  WasmLiveTimeout* = 0x574C_5606'u32
  WasmLiveProbeOnly* = 0x574C_5607'u32

  WasmLiveD0StatusAddr* = XramBase + 0x3C00'u
  WasmLiveD0HeartbeatAddr* = XramBase + 0x3C04'u
  WasmLiveD0AddValueAddr* = XramBase + 0x3C08'u
  WasmLiveD0SumValueAddr* = XramBase + 0x3C0C'u
  WasmLiveD0Probe2Addr* = XramBase + 0x3C10'u
  WasmLiveD0Probe3Addr* = XramBase + 0x3C14'u

  WasmLiveLpStatusAddr* = 0x40002C00'u
  WasmLiveLpHeartbeatAddr* = 0x40002C04'u
  WasmLiveLpAddValueAddr* = 0x40002C08'u
  WasmLiveLpSumValueAddr* = 0x40002C0C'u
  WasmLiveLpStartAddr* = WramBase + 0x20000'u
  WasmLiveLpStartMagic* = 0x574C_5354'u32

  WasmLiveMinHeartbeat* = 4'u32
