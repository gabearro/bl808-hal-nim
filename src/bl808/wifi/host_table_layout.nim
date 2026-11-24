from fw_constants/limits_events import MAX_VIFS, STA_MGMT_FREE_STAS, STA_INFO_TAB_ENTRIES

const
  WifiHostVifCount* = MAX_VIFS
  WifiHostPeerCount* = STA_MGMT_FREE_STAS
  WifiHostStaTableCount* = WifiHostPeerCount + WifiHostVifCount
  WifiHostStaTableOffset* = 100'u
  WifiHostStaEntrySize* = 40'u
  WifiHostModParamsOffset* = WifiHostStaTableOffset + WifiHostStaTableCount.uint * WifiHostStaEntrySize
  WifiHostHtCapOffset* = WifiHostModParamsOffset + 4'u

static:
  doAssert WifiHostStaTableCount == STA_INFO_TAB_ENTRIES
