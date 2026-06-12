# Vendor ke_event.o .rodata.ke_evt_hdlr table. The scheduler indexes this table
# with __clz(event_field), so index 0 handles bit 31 and index 25 handles bit 6.
# Nim stores function-pointer aggregate initializers in module init code for this
# target, so populate this explicitly before the first scheduler pass.
var keEvtHandlers* {.wifiCtrlExport.}: array[KE_EVT_MAX, KeEvtEntry]
var wifiFwRuntimeInited* {.wifiCtrl.}: uint8

proc ke_evt_handlers_init*() {.exportc, cdecl.} =
  keEvtHandlers[0] = KeEvtEntry(handler: cast[pointer](bl_reset_evt), param: nil)
  keEvtHandlers[1] = KeEvtEntry(handler: cast[pointer](mm_timer_schedule), param: nil)
  keEvtHandlers[2] = KeEvtEntry(handler: cast[pointer](ke_timer_schedule), param: nil)
  keEvtHandlers[3] = KeEvtEntry(handler: cast[pointer](ipc_emb_msg_evt), param: nil)
  keEvtHandlers[4] = KeEvtEntry(handler: cast[pointer](ke_task_schedule), param: nil)
  keEvtHandlers[5] = KeEvtEntry(handler: cast[pointer](mm_hw_idle_evt), param: nil)
  keEvtHandlers[6] = KeEvtEntry(handler: cast[pointer](mm_tbtt_evt), param: nil)
  keEvtHandlers[7] = KeEvtEntry(handler: cast[pointer](mm_tbtt_evt), param: nil)
  keEvtHandlers[8] = KeEvtEntry(handler: cast[pointer](rxu_swdesc_upload_evt), param: nil)
  keEvtHandlers[9] = KeEvtEntry(handler: cast[pointer](rxl_dma_evt), param: nil)
  keEvtHandlers[10] = KeEvtEntry(handler: cast[pointer](rxu_cntrl_evt), param: nil)
  keEvtHandlers[11] = KeEvtEntry(handler: cast[pointer](rxl_cntrl_evt), param: nil)
  keEvtHandlers[12] = KeEvtEntry(handler: cast[pointer](txl_frame_evt), param: nil)
  keEvtHandlers[13] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](4'u))
  keEvtHandlers[14] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](3'u))
  keEvtHandlers[15] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](2'u))
  keEvtHandlers[16] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: cast[pointer](1'u))
  keEvtHandlers[17] = KeEvtEntry(handler: cast[pointer](txl_cfm_evt), param: nil)
  keEvtHandlers[18] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](4'u))
  keEvtHandlers[19] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](3'u))
  keEvtHandlers[20] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](2'u))
  keEvtHandlers[21] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: cast[pointer](1'u))
  keEvtHandlers[22] = KeEvtEntry(handler: cast[pointer](ipc_emb_tx_evt), param: nil)
  keEvtHandlers[23] = KeEvtEntry(handler: cast[pointer](bl_event_handle), param: cast[pointer](1'u))
  keEvtHandlers[24] = KeEvtEntry(handler: cast[pointer](bl_event_handle), param: nil)
  keEvtHandlers[25] = KeEvtEntry(handler: cast[pointer](bl_fw_statistic_dump), param: nil)

proc wifi_fw_runtime_init*() {.exportc, cdecl.} =
  ## Initialize wifi_fw runtime state once.
  ##
  ## CRITICAL: do NOT call NimMain() here. `_start` jumps directly to
  ## user `main()`, so NimMain has never been called. NimMain itself
  ## ends with `jal main`, so calling it here would recursively re-enter
  ## main → infinite recursion. Instead, call PreMain — it runs all the
  ## Nim global var initializers (which is what populates dispatch
  ## tables like mm_default_handler) and returns. ke_evt_handlers_init
  ## then wires up the per-event handler table.
  if wifiFwRuntimeInited != 0:
    return
  {.emit: """
  extern void PreMain(void);
  PreMain();
  """.}
  ke_evt_handlers_init()
  wifiFwRuntimeInited = 1
