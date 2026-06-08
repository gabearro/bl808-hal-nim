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

when defined(bl808WifiRxPbufInput):
  proc pbuf_alloc(layer: cint; length: uint16; ptype: cint): ptr Pbuf
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_take(p: ptr Pbuf; dataptr: pointer; length: uint16): ErrT
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_take_at(p: ptr Pbuf; dataptr: pointer; length, offset: uint16): ErrT
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_cat(head, tail: ptr Pbuf)
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_free(p: ptr Pbuf): uint8
    {.importc, cdecl, header: "<lwip/pbuf.h>".}

  {.emit: "extern struct bl_hw wifi_hw;".}
  {.emit: """
static err_t bl808_nim_netif_input_call(struct pbuf *p, struct netif *netif)
{
    if (netif == NULL || netif->input == NULL) {
        return (err_t)-1;
    }
    return netif->input(p, netif);
}
""".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  proc bl808_nim_netif_input_call(p: ptr Pbuf; netif: ptr Netif): ErrT
    {.importc, cdecl.}

{.emit: """
extern void cfg_trace(char *s);
""".}
proc cfgTrace2(s: cstring) {.importc: "cfg_trace", cdecl.}
