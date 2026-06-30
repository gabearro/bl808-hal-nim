## CPS HTTP server adapter for the BL808 WASM manager.
##
## The BL808 build still owns the lwIP TCP listener. This module converts each
## received HTTP/1 request buffer into the cps/http server request/response
## model, dispatches through a CPS HttpHandler, and serializes with the CPS
## HTTP/1 response builder.

import std/strutils
import cps/http/server/embedded_dsl
import ./wasm_http

const
  DefaultMaxRequestLine = 1024
  DefaultMaxHeaderLine = 1024
  DefaultMaxHeaderBytes = 4096
  DefaultMaxBodyBytes = 64 * 1024

type
  CpsHttpParseResult = object
    ok: bool
    req: HttpRequest
    statusCode: int
    body: string

proc startsWithAt(data: openArray[byte], prefix: string, at: int): bool =
  if at < 0 or at + prefix.len > data.len:
    return false
  for i in 0 ..< prefix.len:
    if data[at + i] != byte(prefix[i]):
      return false
  true

proc findHeaderEnd(data: openArray[byte]): int =
  if data.len < 4:
    return -1
  for i in 0 .. data.len - 4:
    if data[i] == byte('\r') and data[i + 1] == byte('\n') and
        data[i + 2] == byte('\r') and data[i + 3] == byte('\n'):
      return i
  -1

proc asciiSlice(data: openArray[byte], start, stop: int): string =
  if start < 0 or stop < start or stop > data.len:
    return ""
  result = newString(stop - start)
  for i in start ..< stop:
    result[i - start] = char(data[i])

proc parsePositiveInt(s: string, value: var int): bool =
  if s.len == 0:
    return false
  var n = 0
  for ch in s:
    if ch < '0' or ch > '9':
      return false
    let digit = ord(ch) - ord('0')
    if n > (int.high - digit) div 10:
      return false
    n = n * 10 + digit
  value = n
  true

proc trimAscii(s: string): string =
  var first = 0
  var last = s.len
  while first < last and (s[first] == ' ' or s[first] == '\t'):
    inc first
  while last > first and (s[last - 1] == ' ' or s[last - 1] == '\t'):
    dec last
  s[first ..< last]

proc badRequest(code: int, body: string): CpsHttpParseResult =
  CpsHttpParseResult(ok: false, statusCode: code, body: body)

proc parseCpsHttpRequest*(data: openArray[byte],
                          maxRequestLine = DefaultMaxRequestLine,
                          maxHeaderLine = DefaultMaxHeaderLine,
                          maxHeaderBytes = DefaultMaxHeaderBytes,
                          maxBodyBytes = DefaultMaxBodyBytes):
                            CpsHttpParseResult =
  ## Parse a complete HTTP/1.x request buffer into the CPS server request type.
  let headerEnd = findHeaderEnd(data)
  if headerEnd < 0:
    return badRequest(400, "bad request")
  if headerEnd > maxHeaderBytes:
    return badRequest(431, "request headers too large")

  var lineStop = 0
  while lineStop < headerEnd and not (data[lineStop] == byte('\r') and
      lineStop + 1 < headerEnd and data[lineStop + 1] == byte('\n')):
    inc lineStop
  if lineStop == 0 or lineStop > maxRequestLine:
    return badRequest(414, "request line too large")

  let requestLine = asciiSlice(data, 0, lineStop)
  let firstSpace = requestLine.find(' ')
  let lastSpace = requestLine.rfind(' ')
  if firstSpace <= 0 or lastSpace <= firstSpace + 1 or lastSpace >= requestLine.len - 1:
    return badRequest(400, "bad request line")

  let meth = requestLine[0 ..< firstSpace]
  let path = requestLine[firstSpace + 1 ..< lastSpace]
  let version = requestLine[lastSpace + 1 ..< requestLine.len]
  if version != "HTTP/1.0" and version != "HTTP/1.1":
    return badRequest(505, "unsupported http version")

  var headers: seq[(string, string)] = @[]
  var contentLen = 0
  var sawContentLen = false
  var line = lineStop + 2
  while line < headerEnd:
    var lineEnd = line
    while lineEnd < headerEnd and not (data[lineEnd] == byte('\r') and
        lineEnd + 1 < headerEnd and data[lineEnd + 1] == byte('\n')):
      inc lineEnd
    if lineEnd - line > maxHeaderLine:
      return badRequest(431, "request header line too large")
    if lineEnd > line:
      let headerLine = asciiSlice(data, line, lineEnd)
      let colon = headerLine.find(':')
      if colon <= 0:
        return badRequest(400, "bad header")
      let name = headerLine[0 ..< colon]
      let value = trimAscii(headerLine[colon + 1 ..< headerLine.len])
      if not isValidHeaderName(name) or not isValidHeaderValue(value):
        return badRequest(400, "bad header")
      if eqCaseInsensitive(name, "content-length"):
        var parsed = 0
        if not parsePositiveInt(value, parsed):
          return badRequest(400, "bad content length")
        if sawContentLen and parsed != contentLen:
          return badRequest(400, "conflicting content length")
        sawContentLen = true
        contentLen = parsed
      elif eqCaseInsensitive(name, "transfer-encoding") and
          not eqCaseInsensitive(value, "identity"):
        return badRequest(501, "transfer encoding unsupported")
      headers.add((name, value))
    line = lineEnd + 2

  if contentLen > maxBodyBytes:
    return badRequest(413, "request body too large")
  let bodyStart = headerEnd + 4
  if bodyStart + contentLen > data.len:
    return badRequest(400, "incomplete body")

  result.ok = true
  result.req = HttpRequest(
    meth: meth,
    path: path,
    httpVersion: version,
    headers: headers,
    body: asciiSlice(data, bodyStart, bodyStart + contentLen),
  )

proc wasmMethodFromCps(meth: string, parsed: var WasmHttpMethod): bool =
  if meth == "GET":
    parsed = wasmHttpGet
    return true
  if meth == "POST":
    parsed = wasmHttpPost
    return true
  if meth == "DELETE":
    parsed = wasmHttpDelete
    return true
  false

proc bodyBytes(body: string): seq[byte] =
  result = newSeq[byte](body.len)
  for i, ch in body:
    result[i] = byte(ch)

proc wasmResponseToCps(r: WasmHttpResponse): HttpResponseBuilder =
  newResponse(
    r.statusCode.int,
    r.body,
    @[
      ("Content-Type", r.contentType),
      ("Connection", "close"),
    ],
  )

proc wasmManagerCpsHandler*(req: HttpRequest): HttpResponseBuilder =
  var httpMethod: WasmHttpMethod
  if not wasmMethodFromCps(req.meth, httpMethod):
    return newResponse(
      405,
      "method not allowed",
      @[("Content-Type", "text/plain"), ("Connection", "close")],
    )

  let bytes = bodyBytes(req.body)
  let response =
    if bytes.len == 0:
      handleWasmHttpRequest(httpMethod, req.path, [])
    else:
      handleWasmHttpRequest(httpMethod, req.path, bytes)
  wasmResponseToCps(response)

proc allcoreWasmManagerApp(rootBody: string): HttpHandler =
  embeddedRouter:
    get "/":
      discard req
      newResponse(
        200,
        rootBody,
        @[("Content-Type", "text/plain"), ("Connection", "close")],
      )
    any "/wasm":
      wasmManagerCpsHandler(req)
    any "/wasm/*":
      wasmManagerCpsHandler(req)
    notFound:
      discard req
      # Keep the legacy embedded manager behavior: unknown paths show the
      # manager root instead of an HTML 404.
      newResponse(
        200,
        rootBody,
        @[("Content-Type", "text/plain"), ("Connection", "close")],
      )

proc dispatchCpsHttpRequest(req: HttpRequest, rootBody: string):
                            HttpResponseBuilder =
  allcoreWasmManagerApp(rootBody)(req)

proc handleWasmCpsHttpTransport*(request: openArray[byte], rootBody: string,
                                 write: proc(data: string): bool {.closure.},
                                 close: proc() {.closure.} = nil): HttpResponseBuilder =
  ## Dispatch one HTTP/1 request with a transport writer available to embedded
  ## route helpers. Streaming/SSE/WebSocket handlers may write directly and
  ## return rcHandled; ordinary handlers still return a normal response.
  let parsed = parseCpsHttpRequest(request)
  if parsed.ok:
    var req = parsed.req
    req.transportWrite = write
    req.transportClose = close
    dispatchCpsHttpRequest(req, rootBody)
  else:
    newResponse(
      parsed.statusCode,
      parsed.body,
      @[("Content-Type", "text/plain"), ("Connection", "close")],
    )

proc handleWasmCpsWebSocketMessage*(path: string, payload: string,
                                    rootBody: string,
                                    write: proc(data: string): bool {.closure.},
                                    close: proc() {.closure.} = nil): HttpResponseBuilder =
  var req = HttpRequest(
    meth: "GET",
    path: path,
    httpVersion: "HTTP/1.1",
    headers: @[],
    body: payload,
    transportWrite: write,
    transportClose: close,
    transportUpgraded: true,
    webSocketMessage: true,
  )
  dispatchCpsHttpRequest(req, rootBody)

proc handleWasmCpsHttpBytes*(request: openArray[byte], rootBody: string): string =
  ## Handle one complete raw HTTP request using CPS HTTP server abstractions.
  let parsed = parseCpsHttpRequest(request)
  let response =
    if parsed.ok:
      dispatchCpsHttpRequest(parsed.req, rootBody)
    else:
      newResponse(
        parsed.statusCode,
        parsed.body,
        @[("Content-Type", "text/plain"), ("Connection", "close")],
      )
  buildResponseString(response)
