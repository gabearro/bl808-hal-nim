const
  RwnxTxLifetimeMs = 100'i32
  NxTxPayloadMax = 6'i32

type
  BlModParams {.bycopy.} = object
    ht_on: uint8
    vht_on: uint8
    pad0: array[2, uint8]
    mcs_map: int32
    phy_cfg: int32
    uapsd_timeout: int32
    sgi: uint8
    sgi80: uint8
    use_2040: uint8
    pad1: uint8
    listen_itv: int32
    listen_bcmc: uint8
    pad2: array[3, uint8]
    lp_clk_ppm: int32
    ps_on: uint8
    pad3: array[3, uint8]
    tx_lft: int32
    amsdu_maxnb: int32
    uapsd_queues: int32

var bl_mod_params* {.exportc.}: BlModParams = BlModParams(
  ht_on: 1'u8,
  vht_on: 0'u8,
  mcs_map: 0'i32,
  phy_cfg: 2'i32,
  uapsd_timeout: 3000'i32,
  sgi: 0'u8,
  sgi80: 0'u8,
  use_2040: 0'u8,
  listen_itv: 1'i32,
  listen_bcmc: 1'u8,
  lp_clk_ppm: 20'i32,
  ps_on: 0'u8,
  tx_lft: RwnxTxLifetimeMs,
  amsdu_maxnb: NxTxPayloadMax,
  uapsd_queues: 0'i32
)
