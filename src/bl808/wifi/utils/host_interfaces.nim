proc c_memset(s: pointer; c: cint; n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dst, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc c_memcmp(a, b: pointer; n: csize_t): cint
  {.importc: "memcmp", header: "<string.h>", cdecl.}
proc c_malloc(size: csize_t): pointer
  {.importc: "malloc", header: "<stdlib.h>", cdecl.}
proc ipc_host_init(env, cb, sharedEnv, pthis: pointer)
  {.importc, cdecl, header: "ipc_host.h".}
proc bl_cmd_mgr_init(cmdMgr: pointer)
  {.importc, cdecl, header: "bl_cmds.h".}
proc bl_tx_cfm(pthis, hostid: pointer): cint
  {.importc, cdecl, header: "bl_tx.h".}
proc pbuf_alloc(layer: cint; length: uint16; ptype: cint): ptr Pbuf
  {.importc, cdecl, header: "<lwip/pbuf.h>".}
proc pbuf_take_at(p: ptr Pbuf; dataptr: pointer; length, offset: uint16): ErrT
  {.importc, cdecl, header: "<lwip/pbuf.h>".}
proc pbuf_free(p: ptr Pbuf): uint8
  {.importc, cdecl, header: "<lwip/pbuf.h>".}
proc bl_rx_pkt_cb(pkt: ptr uint8; length: cint; wrapper: pointer; info: ptr BlRxInfo)
  {.importc, cdecl, header: "bl_rx.h".}

{.emit: """
_Static_assert(sizeof(bl_rx_info_t) == 3, "monitor RX info ABI");
_Static_assert(sizeof(struct hw_vect) == 40, "monitor RX vector ABI");
_Static_assert(offsetof(struct hw_rxhdr, pattern) == 52, "monitor RX flags ABI");
""".}

when defined(bl808WifiRxPbufInput):
  proc pbuf_take(p: ptr Pbuf; dataptr: pointer; length: uint16): ErrT
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_cat(head, tail: ptr Pbuf)
    {.importc, cdecl, header: "<lwip/pbuf.h>".}

  {.emit: "extern struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw

{.emit: """
extern void cfg_trace(char *s);
""".}
proc cfgTrace2(s: cstring) {.importc: "cfg_trace", cdecl.}
