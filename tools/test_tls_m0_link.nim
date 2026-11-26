## M0 link test for src/bl808/kernel/tls.nim (built by tools/test_tls_m0_link.py,
## never flashed). With -d:tlsLinkWithWifi it is the Wi-Fi HTTP server example
## plus a TLS client in the same image, which must hold one Mbed TLS.
##
##   nim c -d:bl808m0 -d:bl808kernel tools/test_tls_m0_link.nim

import bl808/kernel/tls

var
  linkSession: TlsSession
  linkSink {.volatile.}: int

proc linkSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} = 0
proc linkRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} = 0

proc tlsLinkProbe() {.exportc: "bl808_tls_link_probe".} =
  ## Reaches every entry point so section GC keeps what a real client needs.
  var buffer: array[64, byte]
  var moved: int
  let data = cast[ptr UncheckedArray[byte]](addr buffer[0])
  discard tlsAddTrustAnchor(buffer)
  if tlsOpen(linkSession, TlsIo(ctx: nil, send: linkSend, recv: linkRecv), "example.org"):
    linkSink = tlsHandshakeStep(linkSession).ord
    linkSink = tlsWrite(linkSession, data, buffer.len, moved).ord
    linkSink = tlsRead(linkSession, data, buffer.len, moved).ord
    linkSink = tlsErrorClass(linkSession).ord + tlsLastError(linkSession).int
  tlsClose(linkSession)

{.passL: "-Wl,--undefined=bl808_tls_link_probe".}

when defined(tlsLinkWithWifi):
  include ../examples/m0_wifi_http_server
else:
  import bl808/startup
  import bl808/panicoverride
  import bl808/kernel/alloc

  proc main() {.exportc, cdecl.} =
    heapInit()
    tlsLinkProbe()
    while true: discard
