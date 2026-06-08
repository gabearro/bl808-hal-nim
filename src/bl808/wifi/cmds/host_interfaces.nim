var g_bl_ops_funcs {.importc.}: uint8

proc c_memcpy(dest, src: pointer; n: csize_t): pointer
  {.importc: "memcpy", header: "<string.h>", cdecl.}
proc ipc_host_msg_push(env, msgBuf: pointer; len: uint16): cint {.importc, cdecl.}

when defined(bl808WifiCmdTrace):
  proc c_printf(fmt: cstring): cint
    {.importc: "printf", header: "<stdio.h>", cdecl, varargs, discardable.}
