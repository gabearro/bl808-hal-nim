proc aos_post_event*(`type`: uint16; code: uint16; value: culong): cint {.exportc, cdecl.} =
  discard `type`; discard code; discard value; 0

proc aos_register_event_filter*(`type`: uint16; cb, privateData: pointer): cint
    {.exportc, cdecl.} =
  discard `type`; discard cb; discard privateData; 0

proc aos_post_delayed_action*(ms: cint; action, arg: pointer): cint {.exportc, cdecl.} =
  discard ms; discard action; discard arg; 0
