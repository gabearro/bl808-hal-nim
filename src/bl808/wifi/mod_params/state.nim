const
  RwnxTxLifetimeMs = 100'i32
  NxTxPayloadMax = 6'i32

type
  BlModParams {.bycopy.} = object
    ht_on: uint8
    vht_on: uint8
    htVhtAlignmentPadding: array[2, uint8]
    mcs_map: int32
    phy_cfg: int32
    uapsd_timeout: int32
    sgi: uint8
    sgi80: uint8
    use_2040: uint8
    use2040AlignmentPadding: uint8
    listen_itv: int32
    listen_bcmc: uint8
    listenBcmcAlignmentPadding: array[3, uint8]
    lp_clk_ppm: int32
    ps_on: uint8
    psOnAlignmentPadding: array[3, uint8]
    tx_lft: int32
    amsdu_maxnb: int32
    uapsd_queues: int32

static:
  doAssert offsetof(BlModParams, ht_on) == 0
  doAssert offsetof(BlModParams, vht_on) == 1
  doAssert offsetof(BlModParams, htVhtAlignmentPadding) == 2
  doAssert offsetof(BlModParams, mcs_map) == 4
  doAssert offsetof(BlModParams, phy_cfg) == 8
  doAssert offsetof(BlModParams, sgi) == 16
  doAssert offsetof(BlModParams, use2040AlignmentPadding) == 19
  doAssert offsetof(BlModParams, listen_itv) == 20
  doAssert offsetof(BlModParams, listenBcmcAlignmentPadding) == 25
  doAssert offsetof(BlModParams, lp_clk_ppm) == 28
  doAssert offsetof(BlModParams, psOnAlignmentPadding) == 33
  doAssert offsetof(BlModParams, tx_lft) == 36
  doAssert offsetof(BlModParams, uapsd_queues) == 44

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
