## BL808 interrupt and WiFi MMIO addresses used by the support glue.

const
  Bl808IrqBase = 16'u32
  Bl808IrqWifi = Bl808IrqBase + 54'u32
  Bl808IrqWifiIpcPublic = Bl808IrqBase + 63'u32

  GlbBase = 0x2000_0000'u32
  UartFifoCfg1 = 0x2000_A084'u32
  UartWdata = 0x2000_A088'u32
  MtimeBase = 0xE000_BFF8'u32
  IntcPend = 0x4000_0010'u32
  IpcEmb2AppAck = 0x2480_0008'u32
  IpcEmb2AppRawStatus = 0x2480_0004'u32
  IpcEmb2AppStatus = 0x2480_0104'u32
  IpcApp2EmbAck = 0x2480_010C'u32
  IpcA2eMsgBit = 1'u32 shl 1
  KeEvtIpcEmbMsg = 0x1000_0000'u32
  MacIrqStatus0 = 0x2491_0000'u32
  MacIrqStatus1 = 0x2491_0004'u32
  MachwIrqRaw = 0x24B0_806C'u32
  MachwIrqUnmask = 0x24B0_8074'u32
  BcnStatus = 0x24B0_0400'u32
  CoexCtrl = 0x2492_0004'u32
  RfStatusCtrl = 0x2490_0084'u32
  MacRfStatus = 0x24B0_0120'u32
  MacRfActiveBit = 0x0008_0000'u32
