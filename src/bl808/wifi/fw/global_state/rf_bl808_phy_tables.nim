## Native table-loading phases of the BL808 WiFi demo phy_init.
## The demo images match the shared radio data, not the legacy WiFi agcmem.
import ../../../blerfdata as radioTables

type Bl808PhyLdpcRam = array[190, uint32]

const Bl808PhyLdpcImage = block:
  # ldpcmem has 375 words; phy_init stops at base + 0x2F8.
  var image: Bl808PhyLdpcRam
  for i in 0 ..< image.len:
    image[i] = radioTables.BleLdpcMem[i]
  image

static:
  doAssert WifiAgcMemoryBase == radioTables.BleAgcMemBase.uint
  doAssert WifiAgcMemoryWords == radioTables.BleAgcMemWords
  doAssert sizeof(WifiAgcMemoryRam) == 0x800
  doAssert radioTables.BleAgcMemPrefix.len == 290
  doAssert radioTables.BleAgcMemLastWordOffset == WifiAgcMemoryWords - 1
  doAssert radioTables.BleLdpcMemBase == 0x24C09000'u32
  doAssert sizeof(Bl808PhyLdpcRam) == 0x2F8

proc programBl808PhyAgcTable() =
  ## phy_init+0x13a..0x1a2, immediately after agc_config returns.
  let bba = bbaAgcRegs()
  let mdm = wifiModemRegs()
  let dst = wifiAgcMemoryRegs()
  updateReg32(addr bba.pdGain390, not 0'u32, 0x1000'u32)
  updateReg32(addr mdm.bandwidth20MGate874, not 0'u32, 0x20000000'u32)
  for i, word in radioTables.BleAgcMemPrefix:
    volatileStore(addr dst.memoryWords[i], word)
  for i in radioTables.BleAgcMemPrefix.len ..< radioTables.BleAgcMemLastWordOffset:
    volatileStore(addr dst.memoryWords[i], 0'u32)
  volatileStore(addr dst.memoryWords[radioTables.BleAgcMemLastWordOffset],
                radioTables.BleAgcMemLastWord)
  updateReg32(addr mdm.bandwidth20MGate874, not 0x20000000'u32, 0'u32)
  updateReg32(addr bba.pdGain390, not 0x1000'u32, 0'u32)

proc programBl808PhyLdpcTable() =
  ## phy_init+0x20e..0x23c, after the intervening modem setup (+0x1a6..0x20a).
  let bba = bbaAgcRegs()
  let mdm = wifiModemRegs()
  let dst = cast[ptr Bl808PhyLdpcRam](radioTables.BleLdpcMemBase.uint)
  volatileStore(addr bba.macActiveB340, 0'u32)
  volatileStore(addr bba.macActiveB344, 0'u32)
  volatileStore(addr bba.channelProfile348, 0'u32)
  updateReg32(addr mdm.channelTypeCtrl824, not 0x03000000'u32, 0'u32)
  for i, word in Bl808PhyLdpcImage:
    volatileStore(addr dst[i], word)
