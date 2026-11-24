## Cooperative M0 application for the resident USB UART anchor.
## It mirrors an interactive UART0 console to the USB app-console PTY.

import bl808/kernel/usb_anchor_app_api
import bl808/kernel/alloc

var anchorApi: ptr UsbAnchorAppApi
var pending: array[32, uint8]
var pendingFirst, pendingEnd: int

const Banner = "App console ready\r\n"

proc NimMain() {.importc: "NimMain", cdecl.}

proc anchorAppInit(api: ptr UsbAnchorAppApi): int32
    {.exportc: "anchor_app_init", cdecl.} =
  if api == nil or api.magic != UsbAnchorAppMagic or
      api.version != UsbAnchorAppVersion or
      api.size < sizeof(UsbAnchorAppApi).uint16:
    return AnchorStatusInvalid
  heapInit()
  NimMain() # Run the application's Nim module initializers once.
  result = api.registerConsole(0, 230_400)
  if result == AnchorStatusOk:
    anchorApi = api
    for i, c in Banner:
      pending[i] = c.uint8
    pendingFirst = 0
    pendingEnd = Banner.len

proc anchorAppPoll() {.exportc: "anchor_app_poll", cdecl.} =
  if anchorApi == nil: return
  if pendingFirst == pendingEnd:
    let count = anchorApi.consoleRead(addr pending[0], pending.len.uint32)
    if count <= 0: return
    pendingFirst = 0
    pendingEnd = count.int
  let written = anchorApi.consoleWrite(addr pending[pendingFirst],
                                       (pendingEnd - pendingFirst).uint32)
  if written > 0:
    pendingFirst += written.int
