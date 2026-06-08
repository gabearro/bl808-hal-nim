## Firmware table limits and kernel event bit masks.

const
  MAX_VIFS* = 2
  MAX_STAS* = 10
  STA_INFO_TAB_ENTRIES* = 7
  STA_MGMT_FREE_STAS* = 5
  MAX_CHAN_CTXT* = 3
  NUM_AC* = 4
  NUM_TX_QUEUES* = 5  # 4 AC + 1 BCN
  MAX_SCAN_RESULTS* = 32
  TX_BUFFER_POOL_SIZE* = 5
  RX_BUFFER_POOL_SIZE* = 12
  IPC_TX_AC_DESC_BASE* = 0x24A00080'u32
  IPC_TX_AC_DESC_STRIDE* = 16'u32
  KE_EVT_MAX* = 26
  KE_TIMER_MAX_DELAY* = 0x11E1A2FF'u32  # ~300s in MAC ticks

  # Event bit constants from blob (lui encoding: value << 12)
  KE_EVT_PRIM_TBTT*    = 0x02000000'u32   # blob: lui a0, 0x2000 -- primary TBTT
  KE_EVT_SEC_TBTT*     = 0x01000000'u32   # blob: lui a0, 0x1000 -- secondary TBTT
  KE_EVT_IDLE*         = 0x04000000'u32   # blob: lui a0, 0x4000 -- MAC idle event
  KE_EVT_KE_MESSAGE*   = 0x08000000'u32   # blob: lui a0, 0x8000
  KE_EVT_KE_TIMER*     = 0x20000000'u32   # blob: lui a0, 0x20000
  KE_EVT_MM_TIMER*     = 0x40000000'u32   # blob: lui a0, 0x40000
  KE_EVT_RXUPLOADED*   = 0x00800000'u32
  KE_EVT_RXDMA*        = 0x00400000'u32
  KE_EVT_RXUREADY*     = 0x00200000'u32
  KE_EVT_RXREADY*      = 0x00100000'u32
  KE_EVT_RX*           = KE_EVT_RXREADY   # compatibility alias
