proc bl_pm_init*(): cint {.exportc, cdecl.} = 0
proc bl_pm_deinit*(): cint {.exportc, cdecl.} = 0
proc bl_pm_state_run*(): cint {.exportc, cdecl.} = 0

proc bl_pm_capacity_set*(level: PmLevel): cint {.exportc, cdecl.} =
  discard level; 0

proc bl_pm_event_register*(event: PmEvent; code, capBit: uint32; priority: uint16;
                           ops: PmCb; arg: pointer; enable: PmEventAble): cint
    {.exportc, cdecl.} =
  discard event; discard code; discard capBit; discard priority; discard arg; discard enable
  if ops != nil: discard
  0

proc bl_pm_event_switch*(event: PmEvent; code: uint32; enable: PmEventAble): cint
    {.exportc, cdecl.} =
  discard event; discard code; discard enable; 0

proc pm_post_event*(event: PmEvent; code: uint32; retval: ptr uint32): cint
    {.exportc, cdecl.} =
  discard event; discard code
  if retval != nil: retval[] = 0
  0
