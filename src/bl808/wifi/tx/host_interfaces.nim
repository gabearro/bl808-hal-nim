proc c_memset(s: pointer; c: cint; n: csize_t): pointer
  {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc c_memcmp(a, b: pointer; n: csize_t): cint
  {.importc: "memcmp", header: "<string.h>", cdecl.}
proc bl_os_printf(fmt: cstring)
  {.importc, header: "bl_os_private.h", cdecl, varargs.}
proc bl_os_enter_critical()
  {.importc, header: "bl_os_private.h", cdecl.}
proc bl_os_exit_critical()
  {.importc, header: "bl_os_private.h", cdecl.}
proc bl_irq_handler() {.importc, cdecl, header: "bl_irqs.h".}
proc ipc_host_txdesc_get(env: pointer): pointer {.importc, cdecl, header: "ipc_host.h".}
proc ipc_host_txdesc_push(env, hostId: pointer) {.importc, cdecl, header: "ipc_host.h".}
proc ipc_host_txbuf_get(env: pointer): pointer {.importc, cdecl, header: "ipc_host.h".}
proc ipc_host_txbuf_free(buf: pointer) {.importc, cdecl, header: "ipc_host.h".}
proc pbuf_header(p: ptr Pbuf; headerSizeIncrement: int16): uint8
  {.importc, cdecl, header: "<lwip/pbuf.h>".}
proc pbuf_ref(p: ptr Pbuf) {.importc, cdecl, header: "<lwip/pbuf.h>".}
proc pbuf_free(p: ptr Pbuf): uint8 {.importc, cdecl, header: "<lwip/pbuf.h>".}
