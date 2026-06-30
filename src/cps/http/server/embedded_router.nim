## Bare-metal route table for embedded CPS HTTP transports.
##
## This mirrors the useful synchronous surface of cps/http/server/router without
## importing the host async runtime, filesystem, compression, or socket stack.

import std/[strutils, tables]
when not (defined(nimNoLibc) or defined(bl808kernel)):
  import std/json
when defined(bl808kernel):
  import bl808/kernel/fatfs
import ./embedded

when defined(nimNoLibc) or defined(bl808kernel):
  type JsonNode* = string

  proc newJNull*(): JsonNode =
    ""

  proc parseJson*(body: string): JsonNode =
    body

  proc to*[T](node: JsonNode, _: typedesc[T]): T =
    discard node
    default(T)

type
  PathSegmentKind* = enum
    pskLiteral,
    pskParam,
    pskWildcard

  PathSegment* = object
    case kind*: PathSegmentKind
    of pskLiteral:
      value*: string
    of pskParam:
      paramName*: string
      paramType*: string
      optional*: bool
    of pskWildcard:
      discard

  EmbeddedRouteHandler* = proc(req: HttpRequest, pathParams: Table[string, string],
                               queryParams: Table[string, string]): HttpResponseBuilder {.closure.}
  EmbeddedSimpleHandler* = proc(req: HttpRequest): HttpResponseBuilder {.closure.}
  EmbeddedMiddleware* = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder {.closure.}
  Middleware* = EmbeddedMiddleware

  EmbeddedRoute* = object
    meth*: string
    pattern*: string
    segments*: seq[PathSegment]
    handler*: EmbeddedRouteHandler
    middlewares*: seq[EmbeddedMiddleware]
    name*: string

  TrailingSlashBehavior* = enum
    tsbIgnore,
    tsbRedirect,
    tsbStrip

  EmbeddedRouter* = object
    routes*: seq[EmbeddedRoute]
    globalMiddlewares*: seq[EmbeddedMiddleware]
    beforeMiddlewares*: seq[EmbeddedMiddleware]
    afterMiddlewares*: seq[EmbeddedMiddleware]
    notFound*: EmbeddedRouteHandler
    errorHandler*: proc(req: HttpRequest, err: ref CatchableError): HttpResponseBuilder {.closure.}
    trailingSlash*: TrailingSlashBehavior
    methodOverrideEnabled*: bool

  Router* = EmbeddedRouter
  RouteEntry* = EmbeddedRoute

  RequestExtractionError* = object of CatchableError
    statusCode*: int

proc getHeader*(req: HttpRequest, name: string): string =
  for (k, v) in req.headers:
    if eqCaseInsensitive(k, name):
      return v
  ""

proc getResponseHeader*(resp: HttpResponseBuilder, name: string): string =
  for (k, v) in resp.headers:
    if eqCaseInsensitive(k, name):
      return v
  ""

proc passRouteResponse*(headers: seq[(string, string)] = @[]): HttpResponseBuilder =
  HttpResponseBuilder(statusCode: 204, headers: headers, body: "", control: rcPassRoute)

proc continueResponse*(): HttpResponseBuilder =
  HttpResponseBuilder(statusCode: 204, headers: @[], body: "", control: rcContinue)

proc handledResponse*(): HttpResponseBuilder =
  HttpResponseBuilder(statusCode: 200, headers: @[], body: "", control: rcHandled)

proc raiseRequestExtractionError*(statusCode: int, msg: string) {.noreturn.} =
  var err = newException(RequestExtractionError, msg)
  err.statusCode = statusCode
  raise err

proc initEmbeddedRouter*(): EmbeddedRouter =
  result.routes = @[]
  result.globalMiddlewares = @[]
  result.beforeMiddlewares = @[]
  result.afterMiddlewares = @[]
  result.trailingSlash = tsbIgnore
  result.methodOverrideEnabled = false

proc hexValue(c: char): int =
  if c >= '0' and c <= '9':
    ord(c) - ord('0')
  elif c >= 'a' and c <= 'f':
    ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F':
    ord(c) - ord('A') + 10
  else:
    -1

proc decodeUrlComponent*(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let hi = hexValue(s[i + 1])
      let lo = hexValue(s[i + 2])
      if hi >= 0 and lo >= 0:
        result.add char((hi shl 4) or lo)
        i += 3
        continue
    if s[i] == '+':
      result.add ' '
    else:
      result.add s[i]
    inc i

proc encodeUrlComponent*(s: string): string =
  const unreserved = Letters + Digits + {'-', '.', '_', '~'}
  const hex = "0123456789ABCDEF"
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in unreserved:
      result.add ch
    else:
      let b = ord(ch)
      result.add '%'
      result.add hex[(b shr 4) and 0xF]
      result.add hex[b and 0xF]

proc pathWithoutQuery*(path: string): string =
  let idx = path.find('?')
  if idx >= 0: path[0 ..< idx] else: path

proc parseQueryString*(path: string): Table[string, string] =
  result = initTable[string, string]()
  let idx = path.find('?')
  if idx < 0:
    return
  let qs = path[idx + 1 .. ^1]
  if qs.len == 0:
    return
  for pair in qs.split('&'):
    if pair.len == 0:
      continue
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      result[decodeUrlComponent(pair[0 ..< eqIdx])] =
        decodeUrlComponent(pair[eqIdx + 1 .. ^1])
    else:
      result[decodeUrlComponent(pair)] = ""

proc parseFormBody*(body: string): Table[string, string] =
  result = initTable[string, string]()
  if body.len == 0:
    return
  for pair in body.split('&'):
    if pair.len == 0:
      continue
    let eqIdx = pair.find('=')
    if eqIdx >= 0:
      result[decodeUrlComponent(pair[0 ..< eqIdx])] =
        decodeUrlComponent(pair[eqIdx + 1 .. ^1])
    else:
      result[decodeUrlComponent(pair)] = ""

proc parsePath*(pattern: string): seq[PathSegment] =
  let cleaned = pattern.strip(chars = {'/'})
  if cleaned.len == 0:
    return @[]
  let parts = cleaned.split('/')
  for i, part in parts:
    if part.len == 0:
      continue
    if part == "*":
      if i != parts.high:
        raise newException(ValueError, "Wildcard '*' is only allowed as the final route segment: " & pattern)
      result.add PathSegment(kind: pskWildcard)
    elif part.len > 2 and part[0] == '{' and part[^1] == '}':
      var inner = part[1 .. ^2]
      var optional = false
      if inner.endsWith("?"):
        optional = true
        inner = inner[0 .. ^2]
      if optional and i != parts.high:
        raise newException(ValueError, "Optional path params are only allowed as the final segment: " & pattern)
      let colonIdx = inner.find(':')
      var pname = inner
      var ptype = ""
      if colonIdx >= 0:
        pname = inner[0 ..< colonIdx]
        ptype = inner[colonIdx + 1 .. ^1].toLowerAscii
      if pname.len == 0:
        raise newException(ValueError, "Path param name cannot be empty in route: " & pattern)
      if ptype notin ["", "int", "float", "uuid", "alpha", "alnum", "bool"]:
        raise newException(ValueError, "Unsupported path param type '" & ptype & "' in route: " & pattern)
      result.add PathSegment(kind: pskParam, paramName: pname, paramType: ptype, optional: optional)
    else:
      result.add PathSegment(kind: pskLiteral, value: part)

proc segmentsToPattern*(segments: seq[PathSegment]): string =
  if segments.len == 0:
    return "/"
  for seg in segments:
    result.add "/"
    case seg.kind
    of pskLiteral:
      result.add seg.value
    of pskParam:
      result.add "{" & seg.paramName
      if seg.paramType.len > 0:
        result.add ":" & seg.paramType
      if seg.optional:
        result.add "?"
      result.add "}"
    of pskWildcard:
      result.add "*"

proc splitPathParts*(path: string): seq[string] =
  let cleaned = path.strip(chars = {'/'})
  if cleaned.len == 0: @[] else: cleaned.split('/')

proc isValidUuid(s: string): bool =
  if s.len != 36:
    return false
  for i, ch in s:
    if i in {8, 13, 18, 23}:
      if ch != '-': return false
    elif ch notin HexDigits:
      return false
  true

proc parseEmbeddedFloat(value: string, parsed: var float): bool =
  if value.len == 0:
    return false
  var i = 0
  var sign = 1.0
  if value[i] == '-':
    sign = -1.0
    inc i
  elif value[i] == '+':
    inc i
  if i >= value.len:
    return false
  var seenDigit = false
  var whole = 0.0
  while i < value.len and value[i] in Digits:
    seenDigit = true
    whole = whole * 10.0 + float(ord(value[i]) - ord('0'))
    inc i
  var frac = 0.0
  var scale = 1.0
  if i < value.len and value[i] == '.':
    inc i
    while i < value.len and value[i] in Digits:
      seenDigit = true
      frac = frac * 10.0 + float(ord(value[i]) - ord('0'))
      scale = scale * 10.0
      inc i
  if i != value.len or not seenDigit:
    return false
  parsed = sign * (whole + frac / scale)
  true

proc validateParamType(value, paramType: string): bool =
  case paramType
  of "":
    true
  of "int":
    try:
      discard parseInt(value)
      true
    except ValueError:
      false
  of "float":
    var parsed = 0.0
    parseEmbeddedFloat(value, parsed)
  of "bool":
    try:
      discard parseBool(value)
      true
    except ValueError:
      false
  of "uuid":
    isValidUuid(value)
  of "alpha":
    value.len > 0 and value.allCharsInSet(Letters)
  of "alnum":
    value.len > 0 and value.allCharsInSet(Letters + Digits)
  else:
    false

proc matchRouteWithParts*(segments: seq[PathSegment], parts: seq[string],
                          params: var Table[string, string]): bool =
  if segments.len == 0 and parts.len == 0:
    return true

  if segments.len > 0 and segments[^1].kind == pskWildcard:
    if parts.len < segments.len - 1:
      return false
    for i in 0 ..< segments.len - 1:
      if i >= parts.len:
        return false
      let decoded = decodeUrlComponent(parts[i])
      case segments[i].kind
      of pskLiteral:
        if decoded != segments[i].value: return false
      of pskParam:
        if not validateParamType(decoded, segments[i].paramType): return false
        params[segments[i].paramName] = decoded
      of pskWildcard:
        discard
    return true

  let hasOptional = segments.len > 0 and
    segments[^1].kind == pskParam and segments[^1].optional
  if hasOptional:
    if parts.len != segments.len and parts.len != segments.len - 1:
      return false
  elif parts.len != segments.len:
    return false

  for i in 0 ..< segments.len:
    if i >= parts.len:
      return segments[i].kind == pskParam and segments[i].optional
    let decoded = decodeUrlComponent(parts[i])
    case segments[i].kind
    of pskLiteral:
      if decoded != segments[i].value: return false
    of pskParam:
      if not validateParamType(decoded, segments[i].paramType): return false
      params[segments[i].paramName] = decoded
    of pskWildcard:
      return true
  true

proc matchRoute*(segments: seq[PathSegment], path: string): (bool, Table[string, string]) =
  var params = initTable[string, string]()
  let matched = matchRouteWithParts(segments, splitPathParts(pathWithoutQuery(path)), params)
  (matched, params)

proc addRoute*(router: var EmbeddedRouter, meth, pattern: string,
               handler: EmbeddedRouteHandler,
               middlewares: seq[EmbeddedMiddleware] = @[],
               name: string = "") =
  router.routes.add EmbeddedRoute(
    meth: meth,
    pattern: pattern,
    segments: parsePath(pattern),
    handler: handler,
    middlewares: middlewares,
    name: name,
  )

proc addRoute*(router: var EmbeddedRouter, meth, pattern: string,
               handler: EmbeddedSimpleHandler,
               middlewares: seq[EmbeddedMiddleware] = @[],
               name: string = "") =
  let wrapped: EmbeddedRouteHandler =
    proc(req: HttpRequest, pathParams: Table[string, string],
         queryParams: Table[string, string]): HttpResponseBuilder =
      discard pathParams
      discard queryParams
      handler(req)
  router.addRoute(meth, pattern, wrapped, middlewares, name)

proc setNotFound*(router: var EmbeddedRouter, handler: EmbeddedRouteHandler) =
  router.notFound = handler

proc setNotFound*(router: var EmbeddedRouter, handler: EmbeddedSimpleHandler) =
  router.notFound =
    proc(req: HttpRequest, pathParams: Table[string, string],
         queryParams: Table[string, string]): HttpResponseBuilder =
      discard pathParams
      discard queryParams
      handler(req)

proc setErrorHandler*(router: var EmbeddedRouter,
                      handler: proc(req: HttpRequest, err: ref CatchableError): HttpResponseBuilder {.closure.}) =
  router.errorHandler = handler

proc methodMatches(routeMeth, reqMeth: string): bool =
  routeMeth == "*" or routeMeth == reqMeth or (reqMeth == "HEAD" and routeMeth == "GET")

proc chainMiddleware*(middlewares: seq[EmbeddedMiddleware], finalHandler: HttpHandler): HttpHandler =
  if middlewares.len == 0:
    return finalHandler
  var current = finalHandler
  proc wrap(mw: EmbeddedMiddleware, inner: HttpHandler): HttpHandler =
    result = proc(req: HttpRequest): HttpResponseBuilder {.closure.} =
      mw(req, inner)
  for i in countdown(middlewares.len - 1, 0):
    current = wrap(middlewares[i], current)
  current

proc defaultErrorResponse(err: ref CatchableError): HttpResponseBuilder =
  if err of RequestExtractionError:
    let rex = cast[ref RequestExtractionError](err)
    newResponse(rex.statusCode, rex.msg)
  else:
    when not (defined(nimNoLibc) or defined(bl808kernel)):
      if err of JsonParsingError:
        newResponse(400, "Invalid JSON body")
      else:
        newResponse(500, "Internal Server Error")
    else:
      newResponse(500, "Internal Server Error")

proc runWithErrorHandler(router: EmbeddedRouter, req: HttpRequest,
                         fn: proc(): HttpResponseBuilder {.closure.}): HttpResponseBuilder =
  try:
    result = fn()
  except CatchableError as err:
    if router.errorHandler != nil:
      result = router.errorHandler(req, err)
    else:
      result = defaultErrorResponse(err)

proc applyHead(req: HttpRequest, resp: var HttpResponseBuilder) =
  if req.meth == "HEAD":
    resp.body = ""

proc dispatch*(router: EmbeddedRouter, request: HttpRequest): HttpResponseBuilder =
  var req = request
  if router.methodOverrideEnabled:
    let overrideHeader = req.getHeader("x-http-method-override")
    if overrideHeader.len > 0:
      req.meth = overrideHeader.toUpperAscii
    elif req.meth == "POST":
      let form = parseFormBody(req.body)
      let meth = form.getOrDefault("_method")
      if meth.len > 0:
        req.meth = meth.toUpperAscii

  var cleanPath = pathWithoutQuery(req.path)
  if router.trailingSlash == tsbStrip and cleanPath.len > 1 and cleanPath[^1] == '/':
    cleanPath = cleanPath[0 .. ^2]
    req.path = cleanPath
  elif router.trailingSlash == tsbRedirect and cleanPath.len > 1 and cleanPath[^1] == '/':
    return newResponse(301, "", @[("Location", cleanPath[0 .. ^2])])

  let parts = splitPathParts(cleanPath)
  var allowed: seq[string] = @[]
  for route in router.routes:
    var pathParams = initTable[string, string]()
    if matchRouteWithParts(route.segments, parts, pathParams):
      if route.meth notin allowed and route.meth != "*":
        allowed.add route.meth
      if methodMatches(route.meth, req.meth):
        let matchedRoute = route
        let qp = parseQueryString(req.path)
        let finalHandler: HttpHandler =
          proc(r: HttpRequest): HttpResponseBuilder {.closure.} =
            matchedRoute.handler(r, pathParams, qp)
        let allMw = router.beforeMiddlewares & router.globalMiddlewares &
          matchedRoute.middlewares & router.afterMiddlewares
        let chained = chainMiddleware(allMw, finalHandler)
        result = router.runWithErrorHandler(req, proc(): HttpResponseBuilder = chained(req))
        if result.control == rcPassRoute:
          continue
        applyHead(req, result)
        return

  if req.meth == "OPTIONS" and allowed.len > 0:
    if "OPTIONS" notin allowed:
      allowed.add "OPTIONS"
    return newResponse(204, "", @[("Allow", allowed.join(", "))])

  if router.notFound != nil:
    let emptyPp = initTable[string, string]()
    let qp = parseQueryString(req.path)
    result = router.runWithErrorHandler(req, proc(): HttpResponseBuilder =
      router.notFound(req, emptyPp, qp)
    )
    applyHead(req, result)
    return

  if allowed.len > 0:
    return newResponse(405, "method not allowed", @[("Allow", allowed.join(", "))])
  newResponse(404, "not found", @[("Content-Type", "text/plain"), ("Connection", "close")])

proc toHandler*(router: EmbeddedRouter): HttpHandler =
  let captured = router
  result = proc(req: HttpRequest): HttpResponseBuilder {.closure.} =
    captured.dispatch(req)

proc mountRouter*(router: var EmbeddedRouter, prefix: string, child: EmbeddedRouter,
                  middlewares: seq[EmbeddedMiddleware] = @[]) =
  let p = prefix.strip(chars = {'/'})
  let normalized = if p.len == 0: "" else: "/" & p
  for route in child.routes:
    var mounted = route
    mounted.pattern =
      if route.pattern == "/": normalized & "/"
      else: normalized & route.pattern
    mounted.segments = parsePath(mounted.pattern)
    mounted.middlewares = middlewares & route.middlewares
    router.routes.add mounted

proc mountHandler*(router: var EmbeddedRouter, prefix: string, handler: HttpHandler,
                   middlewares: seq[EmbeddedMiddleware] = @[]) =
  let normalized =
    if prefix.len == 0 or prefix == "/": ""
    elif prefix[0] == '/': prefix
    else: "/" & prefix
  let routeHandler: EmbeddedRouteHandler =
    proc(req: HttpRequest, pathParams: Table[string, string],
         queryParams: Table[string, string]): HttpResponseBuilder =
      discard pathParams
      discard queryParams
      handler(req)
  router.addRoute("*", normalized & "/*", routeHandler, middlewares)

proc listRoutes*(router: EmbeddedRouter): string =
  for route in router.routes:
    let meth = if route.meth == "*": "ANY" else: route.meth
    let name = if route.name.len > 0: " [" & route.name & "]" else: ""
    result.add meth & "\t" & route.pattern & name & "\n"

proc urlFor*(router: EmbeddedRouter, name: string,
             params: Table[string, string] = initTable[string, string]()): string =
  for route in router.routes:
    if route.name == name:
      for seg in route.segments:
        result.add "/"
        case seg.kind
        of pskLiteral:
          result.add seg.value
        of pskParam:
          if seg.paramName in params:
            result.add encodeUrlComponent(params[seg.paramName])
          else:
            result.add "{" & seg.paramName & "}"
        of pskWildcard:
          result.add "*"
      if result.len == 0:
        result = "/"
      return
  ""

proc jsonResponse*(code: int, body: string,
                   extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "application/json")]
  for h in extraHeaders: headers.add h
  newResponse(code, body, headers)

proc htmlResponse*(code: int, body: string,
                   extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "text/html; charset=utf-8")]
  for h in extraHeaders: headers.add h
  newResponse(code, body, headers)

proc textResponse*(code: int, body: string,
                   extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", "text/plain; charset=utf-8")]
  for h in extraHeaders: headers.add h
  newResponse(code, body, headers)

proc redirectResponse*(location: string, code: int = 302): HttpResponseBuilder =
  newResponse(code, "", @[("Location", location)])

proc unsupportedEmbeddedResponse*(feature: string): HttpResponseBuilder =
  newResponse(501, feature & " is not available in the embedded HTTP server",
              @[("Content-Type", "text/plain")])

const
  EmbeddedFileReadChunk = 1024
  EmbeddedHttpFileMaxBytes* {.intdefine.} = 2 * 1024 * 1024

type EmbeddedFileReadStatus = enum
  efrOk,
  efrUnsafePath,
  efrUnavailable,
  efrNotFound,
  efrTooLarge,
  efrReadError

proc lastPathSegment(path: string): string =
  var slash = -1
  for i, c in path:
    if c == '/' or c == '\\':
      slash = i
  if slash >= 0 and slash + 1 < path.len:
    path[slash + 1 .. ^1]
  else:
    path

proc fileExtension(path: string): string =
  let name = lastPathSegment(path)
  var dot = -1
  for i, c in name:
    if c == '.':
      dot = i
  if dot >= 0:
    name[dot .. ^1].toLowerAscii
  else:
    ""

proc hasFileExtension(path: string): bool =
  fileExtension(path).len > 0

proc guessEmbeddedContentType*(path: string): string =
  case fileExtension(path)
  of ".html", ".htm": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js", ".mjs": "application/javascript"
  of ".json": "application/json"
  of ".txt", ".log": "text/plain; charset=utf-8"
  of ".wasm": "application/wasm"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  of ".webp": "image/webp"
  of ".avif": "image/avif"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".mp3": "audio/mpeg"
  of ".ogg": "audio/ogg"
  else: "application/octet-stream"

proc isUnsafeEmbeddedPath(path: string): bool =
  if path.len == 0:
    return true
  if path.find('\\') >= 0 or path.find('\0') >= 0:
    return true
  for part in path.split('/'):
    if part == "..":
      return true
  false

proc normalizeEmbeddedFilePath(path: string): string =
  if path.startsWith("0:"):
    path
  elif path.startsWith("/"):
    "0:" & path
  else:
    "0:/" & path

proc joinEmbeddedPath(basePath, relPath: string): string =
  var base = basePath
  while base.len > 0 and base[^1] == '/':
    base.setLen(base.len - 1)
  var rel = relPath
  while rel.len > 0 and rel[0] == '/':
    rel = rel[1 .. ^1]
  if rel.len == 0:
    base
  elif base.len == 0:
    rel
  else:
    base & "/" & rel

proc safeDownloadName(name: string): string =
  let src = if name.len > 0: name else: "download"
  for c in src:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      result.add c
    else:
      result.add '_'
  if result.len == 0:
    result = "download"

proc fileErrorResponse(status: EmbeddedFileReadStatus): HttpResponseBuilder =
  case status
  of efrUnsafePath:
    newResponse(403, "Forbidden", @[("Content-Type", "text/plain")])
  of efrUnavailable:
    newResponse(503, "SD card filesystem is not mounted",
                @[("Content-Type", "text/plain")])
  of efrNotFound:
    newResponse(404, "Not Found", @[("Content-Type", "text/plain")])
  of efrTooLarge:
    newResponse(413, "File is too large for embedded response buffer",
                @[("Content-Type", "text/plain")])
  of efrReadError:
    newResponse(500, "File read failed", @[("Content-Type", "text/plain")])
  of efrOk:
    newResponse(500, "Internal Server Error", @[("Content-Type", "text/plain")])

when defined(bl808kernel):
  var embeddedHttpSdFs: SdFs

  proc ensureEmbeddedHttpSdMounted(): bool =
    if embeddedHttpSdFs.mounted:
      return true
    embeddedHttpSdFs.mount() == frOk

  proc readEmbeddedFile(filePath: string, body: var string): EmbeddedFileReadStatus =
    if isUnsafeEmbeddedPath(filePath):
      return efrUnsafePath
    if not ensureEmbeddedHttpSdMounted():
      return efrUnavailable
    let sdPath = normalizeEmbeddedFilePath(filePath)
    var file: Fil
    let openErr = embeddedHttpSdFs.open(file, sdPath, faRead)
    if openErr == frNoFile or openErr == frNoPath:
      return efrNotFound
    if openErr != frOk:
      return efrReadError
    let fileSize = file.size()
    if fileSize > EmbeddedHttpFileMaxBytes.uint64:
      discard embeddedHttpSdFs.close(file)
      return efrTooLarge
    body = newStringOfCap(fileSize.int)
    var buf: array[EmbeddedFileReadChunk, uint8]
    while true:
      let n = embeddedHttpSdFs.read(file, buf)
      if n < 0:
        discard embeddedHttpSdFs.close(file)
        return efrReadError
      if n == 0:
        break
      for i in 0 ..< n:
        body.add char(buf[i])
    if embeddedHttpSdFs.close(file) != frOk:
      return efrReadError
    efrOk
else:
  proc readEmbeddedFile(filePath: string, body: var string): EmbeddedFileReadStatus =
    discard filePath
    discard body
    efrUnavailable

proc fileResponse*(filePath: string, contentType: string = ""): HttpResponseBuilder =
  var data = ""
  let status = readEmbeddedFile(filePath, data)
  if status != efrOk:
    return fileErrorResponse(status)
  let ct = if contentType.len > 0: contentType else: guessEmbeddedContentType(filePath)
  newResponse(200, data, @[("Content-Type", ct)])

proc downloadResponse*(filePath: string, filename: string = ""): HttpResponseBuilder =
  var resp = fileResponse(filePath)
  if resp.statusCode == 200:
    let fname =
      if filename.len > 0: filename
      else: lastPathSegment(filePath)
    resp.headers.add ("Content-Disposition",
                      "attachment; filename=\"" & safeDownloadName(fname) & "\"")
  resp

proc serveStaticFile*(fsDir: string, urlPrefix: string,
                      reqPath: string, req: HttpRequest = HttpRequest(),
                      maxAge: int = 3600,
                      fallbackFile: string = ""): HttpResponseBuilder =
  discard req
  var prefix = urlPrefix
  if prefix.len == 0:
    prefix = "/"
  if prefix.len > 1 and prefix[^1] == '/':
    prefix.setLen(prefix.len - 1)
  var relPath = reqPath
  if prefix != "/" and relPath.startsWith(prefix):
    relPath = relPath[prefix.len .. ^1]
  while relPath.len > 0 and relPath[0] == '/':
    relPath = relPath[1 .. ^1]
  if relPath.len == 0:
    relPath = "index.html"
  if isUnsafeEmbeddedPath(relPath):
    return fileErrorResponse(efrUnsafePath)

  var filePath = joinEmbeddedPath(fsDir, relPath)
  var data = ""
  var status = readEmbeddedFile(filePath, data)
  if status == efrNotFound and fallbackFile.len > 0 and not hasFileExtension(relPath):
    filePath = joinEmbeddedPath(fsDir, fallbackFile)
    if not isUnsafeEmbeddedPath(fallbackFile):
      status = readEmbeddedFile(filePath, data)
  if status != efrOk:
    return fileErrorResponse(status)
  newResponse(200, data, @[
    ("Content-Type", guessEmbeddedContentType(filePath)),
    ("Cache-Control", "public, max-age=" & $maxAge)
  ])

proc sseEvent*(data: string, event: string = "", id: string = "",
               retry: int = -1): string =
  if event.len > 0:
    result.add "event: " & event & "\n"
  if id.len > 0:
    result.add "id: " & id & "\n"
  if retry >= 0:
    result.add "retry: " & $retry & "\n"
  for line in data.split('\n'):
    result.add "data: " & line & "\n"
  result.add "\n"

proc sseComment*(text: string): string =
  ": " & text & "\n\n"

proc sseResponse*(body: string = "",
                  extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[
    ("Content-Type", "text/event-stream"),
    ("Cache-Control", "no-cache")
  ]
  for h in extraHeaders:
    headers.add h
  newResponse(200, body, headers)

proc embeddedHeaderBlock(statusCode: int, headers: seq[(string, string)],
                         bodyLen: int = -1, chunked = false,
                         connection = "close"): string =
  result = "HTTP/1.1 "
  result.addInt(statusCode)
  result.add ' '
  result.add statusMessage(statusCode)
  result.add "\r\n"
  var hasConnection = false
  for (k, v) in headers:
    if eqCaseInsensitive(k, "content-length") or
        eqCaseInsensitive(k, "transfer-encoding"):
      continue
    result.add k
    result.add ": "
    result.add v
    result.add "\r\n"
    if eqCaseInsensitive(k, "connection"):
      hasConnection = true
  if chunked:
    result.add "Transfer-Encoding: chunked\r\n"
  elif bodyLen >= 0:
    result.add "Content-Length: "
    result.addInt(bodyLen)
    result.add "\r\n"
  if not hasConnection and connection.len > 0:
    result.add "Connection: "
    result.add connection
    result.add "\r\n"
  result.add "\r\n"

proc lowerHexNoPrefix(value: int): string =
  const hex = "0123456789abcdef"
  if value == 0:
    return "0"
  var n = value
  var tmp: array[16, char]
  var pos = tmp.len
  while n > 0 and pos > 0:
    dec pos
    tmp[pos] = hex[n and 0xF]
    n = n shr 4
  for i in pos ..< tmp.len:
    result.add tmp[i]

proc initSse*(req: HttpRequest,
              extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[
    ("Content-Type", "text/event-stream"),
    ("Cache-Control", "no-cache")
  ]
  for h in extraHeaders:
    headers.add h
  if req.writeTransport(embeddedHeaderBlock(200, headers, bodyLen = -1,
                                            chunked = false,
                                            connection = "keep-alive")):
    handledResponse()
  else:
    sseResponse("", extraHeaders)

proc sendSseEvent*(req: HttpRequest, data: string, event: string = "",
                   id: string = "", retry: int = -1): HttpResponseBuilder =
  let payload = sseEvent(data, event, id, retry)
  if req.writeTransport(payload):
    handledResponse()
  else:
    sseResponse(payload)

proc sendSseComment*(req: HttpRequest, text: string): HttpResponseBuilder =
  let payload = sseComment(text)
  if req.writeTransport(payload):
    handledResponse()
  else:
    sseResponse(payload)

proc streamResponse*(body: string = "", contentType: string = "application/octet-stream",
                     extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  var headers = @[("Content-Type", contentType)]
  for h in extraHeaders:
    headers.add h
  newResponse(200, body, headers)

proc initStream*(req: HttpRequest,
                 extraHeaders: seq[(string, string)] = @[],
                 contentType: string = "application/octet-stream"): HttpResponseBuilder =
  var headers = @[("Content-Type", contentType)]
  for h in extraHeaders:
    headers.add h
  if req.writeTransport(embeddedHeaderBlock(200, headers, bodyLen = -1,
                                            chunked = true,
                                            connection = "keep-alive")):
    handledResponse()
  else:
    streamResponse("", contentType, extraHeaders)

proc sendChunk*(req: HttpRequest, data: string): HttpResponseBuilder =
  if data.len == 0:
    return handledResponse()
  let chunk = lowerHexNoPrefix(data.len) & "\r\n" & data & "\r\n"
  if req.writeTransport(chunk):
    handledResponse()
  else:
    streamResponse(data)

proc endStream*(req: HttpRequest): HttpResponseBuilder =
  if req.writeTransport("0\r\n\r\n"):
    req.closeTransport()
    handledResponse()
  else:
    streamResponse("")

proc rol32(x: uint32, n: int): uint32 {.inline.} =
  (x shl n) or (x shr (32 - n))

proc add32(a, b: uint32): uint32 {.inline.} =
  uint32((uint64(a) + uint64(b)) and 0xFFFF_FFFF'u64)

proc sha1Digest(data: string): array[20, uint8] =
  var h0 = 0x67452301'u32
  var h1 = 0xEFCDAB89'u32
  var h2 = 0x98BADCFE'u32
  var h3 = 0x10325476'u32
  var h4 = 0xC3D2E1F0'u32
  var msg = data
  let bitLen = uint64(data.len) * 8'u64
  msg.add char(0x80)
  while (msg.len mod 64) != 56:
    msg.add '\0'
  for shift in countdown(56, 0, 8):
    msg.add char((bitLen shr shift) and 0xFF'u64)

  var offset = 0
  while offset < msg.len:
    var w: array[80, uint32]
    for i in 0 ..< 16:
      let j = offset + i * 4
      w[i] = (uint32(ord(msg[j])) shl 24) or
             (uint32(ord(msg[j + 1])) shl 16) or
             (uint32(ord(msg[j + 2])) shl 8) or
             uint32(ord(msg[j + 3]))
    for i in 16 ..< 80:
      w[i] = rol32(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)

    var a = h0
    var b = h1
    var c = h2
    var d = h3
    var e = h4
    for i in 0 ..< 80:
      var f, k: uint32
      if i < 20:
        f = (b and c) or ((not b) and d)
        k = 0x5A827999'u32
      elif i < 40:
        f = b xor c xor d
        k = 0x6ED9EBA1'u32
      elif i < 60:
        f = (b and c) or (b and d) or (c and d)
        k = 0x8F1BBCDC'u32
      else:
        f = b xor c xor d
        k = 0xCA62C1D6'u32
      let temp = add32(add32(add32(add32(rol32(a, 5), f), e), k), w[i])
      e = d
      d = c
      c = rol32(b, 30)
      b = a
      a = temp
    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
    offset += 64

  let hs = [h0, h1, h2, h3, h4]
  var outIdx = 0
  for h in hs:
    for shift in countdown(24, 0, 8):
      result[outIdx] = uint8((h shr shift) and 0xFF'u32)
      inc outIdx

const EmbeddedBase64Table =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc base64EncodeBytes(data: openArray[uint8]): string =
  var i = 0
  while i < data.len:
    let b0 = data[i]
    let have1 = i + 1 < data.len
    let have2 = i + 2 < data.len
    let b1 = if have1: data[i + 1] else: 0'u8
    let b2 = if have2: data[i + 2] else: 0'u8
    result.add EmbeddedBase64Table[int(b0 shr 2)]
    result.add EmbeddedBase64Table[int(((b0 and 0x03'u8) shl 4) or (b1 shr 4))]
    if have1:
      result.add EmbeddedBase64Table[int(((b1 and 0x0F'u8) shl 2) or (b2 shr 6))]
    else:
      result.add '='
    if have2:
      result.add EmbeddedBase64Table[int(b2 and 0x3F'u8)]
    else:
      result.add '='
    i += 3

proc computeEmbeddedWsAccept(key: string): string =
  const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let digest = sha1Digest(key & magic)
  base64EncodeBytes(digest)

proc webSocketFrame*(payload: string, opcode: uint8 = 0x1'u8): string =
  result.add char(0x80'u8 or (opcode and 0x0F'u8))
  if payload.len < 126:
    result.add char(payload.len)
  elif payload.len <= 0xFFFF:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xFF)
    result.add char(payload.len and 0xFF)
  else:
    result.add char(127)
    for i in countdown(7, 0):
      result.add char((payload.len shr (i * 8)) and 0xFF)
  result.add payload

proc sendWebSocketText*(req: HttpRequest, data: string): HttpResponseBuilder =
  if req.writeTransport(webSocketFrame(data, 0x1'u8)):
    handledResponse()
  else:
    textResponse(200, data)

proc sendWebSocketBinary*(req: HttpRequest, data: string): HttpResponseBuilder =
  if req.writeTransport(webSocketFrame(data, 0x2'u8)):
    handledResponse()
  else:
    streamResponse(data, "application/octet-stream")

proc sendWebSocketPong*(req: HttpRequest, data: string = ""): HttpResponseBuilder =
  discard req.writeTransport(webSocketFrame(data, 0xA'u8))
  handledResponse()

proc closeWebSocket*(req: HttpRequest, code: uint16 = 1000'u16): HttpResponseBuilder =
  var payload = ""
  payload.add char((code shr 8) and 0xFF'u16)
  payload.add char(code and 0xFF'u16)
  discard req.writeTransport(webSocketFrame(payload, 0x8'u8))
  req.closeTransport()
  handledResponse()

proc websocketUpgradeResponse*(req: HttpRequest,
                               extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
  if req.transportUpgraded or req.webSocketMessage:
    return handledResponse()
  let upgrade = req.getHeader("upgrade")
  let connection = req.getHeader("connection")
  let key = req.getHeader("sec-websocket-key")
  if req.meth.toUpperAscii != "GET" or
      upgrade.toLowerAscii != "websocket" or
      connection.toLowerAscii.find("upgrade") < 0 or
      key.len == 0:
    return newResponse(400, "Bad WebSocket upgrade request",
                       @[("Content-Type", "text/plain")])
  var headers = @[
    ("Upgrade", "websocket"),
    ("Connection", "Upgrade"),
    ("Sec-WebSocket-Accept", computeEmbeddedWsAccept(key))
  ]
  for h in extraHeaders:
    headers.add h
  if req.writeTransport(embeddedHeaderBlock(101, headers, bodyLen = -1,
                                            chunked = false,
                                            connection = "")):
    return handledResponse()
  newResponse(101, "", headers)

proc getCookie*(req: HttpRequest, name: string): string =
  let cookieHeader = req.getHeader("cookie")
  if cookieHeader.len == 0:
    return ""
  for pair in cookieHeader.split(';'):
    let trimmed = pair.strip()
    let eqIdx = trimmed.find('=')
    if eqIdx >= 0 and trimmed[0 ..< eqIdx].strip() == name:
      return trimmed[eqIdx + 1 .. ^1].strip()
  ""

proc setCookieHeader*(name: string, value: string,
                      maxAge: int = -1, path: string = "/",
                      httpOnly: bool = false, secure: bool = false,
                      sameSite: string = ""): (string, string) =
  var cookie = name & "=" & value
  if path.len > 0: cookie.add "; Path=" & path
  if maxAge >= 0: cookie.add "; Max-Age=" & $maxAge
  if httpOnly: cookie.add "; HttpOnly"
  if secure: cookie.add "; Secure"
  if sameSite.len > 0: cookie.add "; SameSite=" & sameSite
  ("Set-Cookie", cookie)

proc parseIntParam(value, source, key: string): int =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  try:
    parseInt(value)
  except ValueError:
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc parseFloatParam(value, source, key: string): float =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  if not parseEmbeddedFloat(value, result):
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc parseBoolParam(value, source, key: string): bool =
  if value.len == 0:
    raiseRequestExtractionError(400, "Missing " & source & " parameter: " & key)
  try:
    parseBool(value)
  except ValueError:
    raiseRequestExtractionError(400, "Invalid " & source & " parameter '" & key & "'")

proc pathParamValue*(pp: Table[string, string], key: string): string =
  if key notin pp:
    raiseRequestExtractionError(400, "Missing path parameter: " & key)
  pp[key]

proc pathParamInt*(pp: Table[string, string], key: string): int =
  parseIntParam(pathParamValue(pp, key), "path", key)

proc pathParamFloat*(pp: Table[string, string], key: string): float =
  parseFloatParam(pathParamValue(pp, key), "path", key)

proc pathParamBool*(pp: Table[string, string], key: string): bool =
  parseBoolParam(pathParamValue(pp, key), "path", key)

proc queryParamRequired*(qp: Table[string, string], key: string): string =
  if key notin qp:
    raiseRequestExtractionError(400, "Missing query parameter: " & key)
  qp[key]

proc queryParamInt*(qp: Table[string, string], key: string): int =
  parseIntParam(queryParamRequired(qp, key), "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: int): int =
  if key notin qp or qp[key].len == 0: defaultVal
  else: parseIntParam(qp[key], "query", key)

proc queryParamInt*(qp: Table[string, string], key: string, defaultVal: string): int =
  if key notin qp or qp[key].len == 0: parseIntParam(defaultVal, "query", key)
  else: parseIntParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string): float =
  parseFloatParam(queryParamRequired(qp, key), "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: float): float =
  if key notin qp or qp[key].len == 0: defaultVal
  else: parseFloatParam(qp[key], "query", key)

proc queryParamFloat*(qp: Table[string, string], key: string, defaultVal: string): float =
  if key notin qp or qp[key].len == 0: parseFloatParam(defaultVal, "query", key)
  else: parseFloatParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string): bool =
  parseBoolParam(queryParamRequired(qp, key), "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: bool): bool =
  if key notin qp or qp[key].len == 0: defaultVal
  else: parseBoolParam(qp[key], "query", key)

proc queryParamBool*(qp: Table[string, string], key: string, defaultVal: string): bool =
  if key notin qp or qp[key].len == 0: parseBoolParam(defaultVal, "query", key)
  else: parseBoolParam(qp[key], "query", key)

proc parseJsonBody*(body: string): JsonNode =
  parseJson(body)

when not (defined(nimNoLibc) or defined(bl808kernel)):
  proc jsonResponse*(code: int, body: JsonNode,
                     extraHeaders: seq[(string, string)] = @[]): HttpResponseBuilder =
    jsonResponse(code, $body, extraHeaders)

proc extractClientIp*(req: HttpRequest): string =
  if req.remoteAddr.len > 0: req.remoteAddr else: "unknown"

proc extractBearerToken*(req: HttpRequest): string =
  let auth = req.getHeader("authorization")
  if auth.toLowerAscii.startsWith("bearer "): auth[7 .. ^1].strip() else: ""

proc parseBasicAuth*(req: HttpRequest): (string, string) =
  discard req
  ("", "")

proc escapeHtml*(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add ch

proc checkEtag*(req: HttpRequest, etag: string): bool =
  let inm = req.getHeader("if-none-match")
  if inm.len == 0:
    return false
  for part in inm.split(','):
    let trimmed = part.strip()
    if trimmed == etag or trimmed == "*":
      return true
  false

proc parseAcceptQuality(item: string): float =
  result = 1.0
  for p in item.split(';'):
    let trimmed = p.strip()
    if trimmed.startsWith("q="):
      if not parseEmbeddedFloat(trimmed[2 .. ^1], result):
        result = 1.0

proc negotiateContentType*(acceptHeader: string, available: seq[string]): string =
  if available.len == 0:
    return ""
  if acceptHeader.len == 0:
    return available[0]
  var best = ""
  var bestQ = -1.0
  for item in acceptHeader.split(','):
    let media = item.split(';')[0].strip().toLowerAscii
    let q = parseAcceptQuality(item)
    for avail in available:
      let lower = avail.toLowerAscii
      if media == lower or media == "*/*" or
          (media.endsWith("/*") and lower.startsWith(media[0 ..< media.len - 1])):
        if q > bestQ:
          bestQ = q
          best = avail
  if best.len == 0: "" else: best

proc corsMiddleware*(allowOrigin: string = "*"): EmbeddedMiddleware =
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    result = next(req)
    result.headers.add ("Access-Control-Allow-Origin", allowOrigin)
    if req.meth == "OPTIONS" and result.statusCode == 404:
      result = newResponse(204, "", @[("Access-Control-Allow-Origin", allowOrigin)])

proc securityHeadersMiddleware*(hsts: int = 0, noSniff: bool = true,
                                frameOptions: string = "DENY",
                                xssProtection: bool = true,
                                referrerPolicy: string = "no-referrer"): EmbeddedMiddleware =
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    result = next(req)
    discard req
    if noSniff: result.headers.add ("X-Content-Type-Options", "nosniff")
    if frameOptions.len > 0: result.headers.add ("X-Frame-Options", frameOptions)
    if xssProtection: result.headers.add ("X-XSS-Protection", "1; mode=block")
    if referrerPolicy.len > 0: result.headers.add ("Referrer-Policy", referrerPolicy)
    if hsts > 0: result.headers.add ("Strict-Transport-Security", "max-age=" & $hsts)

proc requestIdMiddleware*(headerName: string = "X-Request-ID"): EmbeddedMiddleware =
  var nextId = 0'u32
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    result = next(req)
    discard req
    inc nextId
    result.headers.add (headerName, $nextId)

proc bodySizeLimitMiddleware*(maxBytes: int): EmbeddedMiddleware =
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    if req.body.len > maxBytes:
      newResponse(413, "payload too large")
    else:
      next(req)

proc timeoutMiddleware*(timeoutMs: int): EmbeddedMiddleware =
  discard timeoutMs
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    next(req)

proc accessLogMiddleware*(format: string = ""): EmbeddedMiddleware =
  discard format
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    next(req)

proc rateLimitMiddleware*(maxRequests: int, windowSeconds: int): EmbeddedMiddleware =
  discard maxRequests
  discard windowSeconds
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    next(req)

proc compressionMiddleware*(minBodySize: int = 1024): EmbeddedMiddleware =
  discard minBodySize
  result = proc(req: HttpRequest, next: HttpHandler): HttpResponseBuilder =
    next(req)

proc extractHeader*(name: string): proc(req: HttpRequest): string {.closure.} =
  result = proc(req: HttpRequest): string = req.getHeader(name)
