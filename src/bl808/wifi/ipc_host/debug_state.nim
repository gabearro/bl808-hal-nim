var nimFwDbgIpcHostIrq* {.exportc: "nimfw_dbg_ipc_host_irq".}: uint32
var nimFwDbgIpcHostIrqStatus* {.exportc: "nimfw_dbg_ipc_host_irq_status".}: uint32
var nimFwDbgIpcHostTxCfmIrq* {.exportc: "nimfw_dbg_ipc_host_txcfm_irq".}: uint32
var nimFwDbgIpcHostTxCfmHandler* {.exportc: "nimfw_dbg_ipc_host_txcfm_handler".}: uint32
var nimFwDbgIpcHostTxCfmDrained* {.exportc: "nimfw_dbg_ipc_host_txcfm_drained".}: uint32
var nimFwDbgIpcHostTxCfmLastHost* {.exportc: "nimfw_dbg_ipc_host_txcfm_host".}: uint32
var nimFwDbgIpcHostTxDescGetNil* {.exportc: "nimfw_dbg_ipc_host_txdesc_nil".}: uint32
var nimFwDbgIpcHostTxDescPush* {.exportc: "nimfw_dbg_ipc_host_txdesc_push".}: uint32
var nimFwDbgIpcMsgAckMismatch* {.exportc: "nimfw_dbg_ipc_msgack_mismatch".}: uint32

# Silent-exit forensics for ipc_host_txdesc_push (the TX-dead break stage:
# tx_push_calls advances while txdesc_push freezes -> one of these exits eats
# every frame; which one names the root cause).
var nimFwDbgIpcTxPushEnvNil* {.exportc: "nimfw_dbg_ipc_txpush_env_nil".}: uint32
var nimFwDbgIpcTxPushPopNil* {.exportc: "nimfw_dbg_ipc_txpush_pop_nil".}: uint32
var nimFwDbgIpcTxPushEnter* {.exportc: "nimfw_dbg_ipc_txpush_enter".}: uint32
var nimFwDbgIpcFreeHead* {.exportc: "nimfw_dbg_ipc_free_head".}: uint32
var nimFwDbgTxFlushPush* {.exportc: "nimfw_dbg_tx_flush_push".}: uint32  # flush waitingList->txPush (host data only)
