type
  BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
  BlSta {.importc: "struct bl_sta", header: "bl_defs.h".} = object
  BlTxCfm {.importc: "struct bl_tx_cfm", header: "bl_tx.h".} = object
  Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
  KeTxFc {.importc: "struct ke_tx_fc", header: "bl_tx.h".} = object
