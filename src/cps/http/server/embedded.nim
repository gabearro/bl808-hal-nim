## Bare-metal HTTP helpers for CPS-style server adapters.
##
## The full CPS HTTP server is copied in this tree under cps/http/server. This
## embedded module is the no-host-runtime surface for device transports such as
## BL808/lwIP: request/response objects, header validation, and HTTP/1 response
## serialization without AsyncStream, native sockets, JSON, tables, or timers.

import std/strutils

type
  ResponseControl* = enum
    rcNone,
    rcPassRoute,
    rcContinue,
    rcHandled

  HttpRequest* = object
    meth*: string
    path*: string
    httpVersion*: string
    headers*: seq[(string, string)]
    body*: string
    remoteAddr*: string
    transportWrite*: proc(data: string): bool {.closure.}
    transportClose*: proc() {.closure.}
    transportUpgraded*: bool
    webSocketMessage*: bool

  HttpResponseBuilder* = object
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string
    control*: ResponseControl

  HttpHandler* = proc(req: HttpRequest): HttpResponseBuilder {.closure.}

proc newResponse*(statusCode: int, body: string = "",
                  headers: seq[(string, string)] = @[]): HttpResponseBuilder =
  HttpResponseBuilder(
    statusCode: statusCode,
    headers: headers,
    body: body,
    control: rcNone,
  )

proc hasTransport*(req: HttpRequest): bool {.inline.} =
  req.transportWrite != nil

proc writeTransport*(req: HttpRequest, data: string): bool =
  if req.transportWrite == nil:
    return false
  req.transportWrite(data)

proc closeTransport*(req: HttpRequest) =
  if req.transportClose != nil:
    req.transportClose()

proc eqCaseInsensitive*(a, b: string): bool {.inline.} =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if toLowerAscii(a[i]) != toLowerAscii(b[i]):
      return false
  true

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.',
                          '^', '_', '`', '|', '~'} + Digits + Letters

proc isValidHeaderName*(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue*(value: string): bool =
  for c in value:
    if c == '\r' or c == '\n' or c == '\0':
      return false
    if ord(c) < 0x20 and c != '\t':
      return false
    if ord(c) == 0x7F:
      return false
  true

proc validateResponseHeaders*(headers: seq[(string, string)]): bool =
  for (k, v) in headers:
    if not isValidHeaderName(k) or not isValidHeaderValue(v):
      return false
  true

proc statusMessage*(code: int): string =
  case code
  of 200: "OK"
  of 101: "Switching Protocols"
  of 201: "Created"
  of 202: "Accepted"
  of 204: "No Content"
  of 205: "Reset Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 406: "Not Acceptable"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 411: "Length Required"
  of 413: "Payload Too Large"
  of 414: "URI Too Long"
  of 415: "Unsupported Media Type"
  of 417: "Expectation Failed"
  of 429: "Too Many Requests"
  of 431: "Request Header Fields Too Large"
  of 500: "Internal Server Error"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 505: "HTTP Version Not Supported"
  else: "Unknown"

proc statusProhibitsBody(statusCode: int): bool {.inline.} =
  (statusCode >= 100 and statusCode < 200) or
    statusCode == 204 or
    statusCode == 304

proc statusLine(code: int): string {.inline.} =
  result = newStringOfCap(32)
  result.add "HTTP/1.1 "
  result.addInt(code)
  result.add ' '
  result.add statusMessage(code)
  result.add "\r\n"

proc buildResponseString*(resp: HttpResponseBuilder): string =
  ## Build an HTTP/1.1 response string from a response builder.
  if not validateResponseHeaders(resp.headers):
    const body = "Internal Server Error"
    result = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: "
    result.addInt(body.len)
    result.add "\r\nConnection: close\r\n\r\n"
    result.add body
    return

  let noBody = statusProhibitsBody(resp.statusCode)
  let resetContentNoPayload = resp.statusCode == 205
  let bodyStr =
    if noBody or resetContentNoPayload: ""
    else: resp.body

  result = newStringOfCap(256 + bodyStr.len)
  result.add statusLine(resp.statusCode)

  var hasConnection = false
  for (k, v) in resp.headers:
    if eqCaseInsensitive(k, "content-length") or
        eqCaseInsensitive(k, "transfer-encoding"):
      continue
    result.add k
    result.add ": "
    result.add v
    result.add "\r\n"
    if eqCaseInsensitive(k, "connection"):
      hasConnection = true

  if resetContentNoPayload:
    result.add "Content-Length: 0\r\n"
  elif not noBody:
    result.add "Content-Length: "
    result.addInt(bodyStr.len)
    result.add "\r\n"

  if not hasConnection:
    result.add "Connection: close\r\n"

  result.add "\r\n"
  result.add bodyStr
