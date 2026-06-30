## Bare-metal CPS HTTP route DSL.
##
## This is a synchronous, embedded-safe compatibility layer for the host
## cps/http/server/dsl.nim route syntax. It deliberately avoids async streams,
## sockets, filesystem I/O, timers, and compression while preserving route
## source shape for BL808 firmware.

import std/[macros, strutils, tables]
when not (defined(nimNoLibc) or defined(bl808kernel)):
  import std/json
import ./embedded
import ./embedded_router

export embedded, embedded_router, tables
when not (defined(nimNoLibc) or defined(bl808kernel)):
  export json

proc mkIdent(name: string): NimNode {.compileTime.} =
  parseExpr(name)

proc prefixedPath(prefix: string, pathNode: NimNode): NimNode {.compileTime.} =
  if pathNode.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    newStrLitNode(prefix & pathNode.strVal)
  elif prefix.len == 0:
    pathNode
  else:
    newCall(mkIdent("&"), newStrLitNode(prefix), pathNode)

type
  RewriteCtx = object
    reqId: NimNode
    ppId: NimNode
    qpId: NimNode
    headersId: NimNode
    formParsedId: NimNode
    formBodyId: NimNode
    jsonParsedId: NimNode
    jsonBodyId: NimNode
    sseBodyId: NimNode
    streamBodyId: NimNode
    errorId: NimNode
    responseId: NimNode

var rewriteCtxCounter {.compileTime.}: int

proc newRewriteCtx(reqId, ppId, qpId: NimNode): RewriteCtx {.compileTime.} =
  let id = rewriteCtxCounter
  inc rewriteCtxCounter
  let p = "embeddedDslCtx" & $id & "_"
  result.reqId = reqId
  result.ppId = ppId
  result.qpId = qpId
  result.headersId = mkIdent(p & "headers")
  result.formParsedId = mkIdent(p & "formParsed")
  result.formBodyId = mkIdent(p & "formBody")
  result.jsonParsedId = mkIdent(p & "jsonParsed")
  result.jsonBodyId = mkIdent(p & "jsonBody")
  result.sseBodyId = mkIdent(p & "sseBody")
  result.streamBodyId = mkIdent(p & "streamBody")
  result.errorId = mkIdent(p & "error")
  result.responseId = mkIdent(p & "response")

proc seqStringTupleType(): NimNode {.compileTime.} =
  newNimNode(nnkBracketExpr).add(
    mkIdent("seq"),
    newNimNode(nnkTupleConstr).add(mkIdent("string"), mkIdent("string")),
  )

proc emptyHeaderSeq(): NimNode {.compileTime.} =
  newNimNode(nnkPrefix).add(
    ident("@"),
    newNimNode(nnkBracket),
  )

proc rewriteDsl(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.}

proc rewriteChildren(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  result = copyNimNode(body)
  for child in body:
    result.add rewriteDsl(child, ctx)

proc rewriteBracketCall(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  let bracketExpr = body[0]
  if bracketExpr[0].kind notin {nnkIdent, nnkSym}:
    return nil
  let name = ($bracketExpr[0]).toLowerAscii
  if bracketExpr.len != 2:
    return nil
  let typeNode = bracketExpr[1]
  let typeName = if typeNode.kind in {nnkIdent, nnkSym}: ($typeNode).toLowerAscii else: "string"
  if name == "pathparam" and body.len == 2:
    case typeName
    of "int": newCall(mkIdent("pathParamInt"), ctx.ppId, body[1])
    of "float": newCall(mkIdent("pathParamFloat"), ctx.ppId, body[1])
    of "bool": newCall(mkIdent("pathParamBool"), ctx.ppId, body[1])
    else: newCall(mkIdent("pathParamValue"), ctx.ppId, body[1])
  elif name == "queryparam" and body.len >= 2:
    let key = body[1]
    let defaultVal = if body.len >= 3: rewriteDsl(body[2], ctx) else: nil
    case typeName
    of "int":
      if defaultVal == nil: newCall(mkIdent("queryParamInt"), ctx.qpId, key)
      else: newCall(mkIdent("queryParamInt"), ctx.qpId, key, defaultVal)
    of "float":
      if defaultVal == nil: newCall(mkIdent("queryParamFloat"), ctx.qpId, key)
      else: newCall(mkIdent("queryParamFloat"), ctx.qpId, key, defaultVal)
    of "bool":
      if defaultVal == nil: newCall(mkIdent("queryParamBool"), ctx.qpId, key)
      else: newCall(mkIdent("queryParamBool"), ctx.qpId, key, defaultVal)
    else:
      if defaultVal == nil:
        newCall(newDotExpr(ctx.qpId, mkIdent("getOrDefault")), key)
      else:
        newCall(newDotExpr(ctx.qpId, mkIdent("getOrDefault")), key, defaultVal)
  else:
    nil

proc rewriteAcceptBlock(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  let reqId = ctx.reqId
  let headersId = ctx.headersId
  if body.len != 2 or body[1].kind != nnkStmtList:
    return nil
  var branches: seq[(string, NimNode)]
  for child in body[1]:
    if child.kind in {nnkCall, nnkCommand} and child[0].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      let branch =
        if child.len >= 2 and child[^1].kind == nnkStmtList:
          rewriteDsl(child[^1], ctx)
        elif child.len >= 2:
          rewriteDsl(child[1], ctx)
        else:
          newStmtList()
      branches.add((child[0].strVal, branch))
  if branches.len == 0:
    return quote do:
      return newResponse(406, "Not Acceptable", `headersId`)
  let availableSym = genSym(nskLet, "embeddedAcceptAvailable")
  let negotiatedSym = genSym(nskLet, "embeddedNegotiated")
  let bracket = newNimNode(nnkBracket)
  for (mime, _) in branches:
    bracket.add newStrLitNode(mime)
  let availableSeq = newNimNode(nnkPrefix).add(ident("@"), bracket)
  var caseStmt = newNimNode(nnkCaseStmt).add(negotiatedSym)
  for (mime, branch) in branches:
    let branchStmt = if branch.kind == nnkStmtList: branch else: newStmtList(branch)
    caseStmt.add newNimNode(nnkOfBranch).add(newStrLitNode(mime), branchStmt)
  caseStmt.add newNimNode(nnkElse).add(newStmtList(
    newNimNode(nnkReturnStmt).add(
      newCall(mkIdent("newResponse"), newIntLitNode(406), newStrLitNode("Not Acceptable"), ctx.headersId)
    )
  ))
  quote do:
    let `availableSym` = `availableSeq`
    let `negotiatedSym` = negotiateContentType(`reqId`.getHeader("accept"), `availableSym`)
    `caseStmt`

proc rewriteDsl(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  let reqId = ctx.reqId
  let ppId = ctx.ppId
  let qpId = ctx.qpId
  let headersId = ctx.headersId
  let formParsedId = ctx.formParsedId
  let formBodyId = ctx.formBodyId
  let jsonParsedId = ctx.jsonParsedId
  let jsonBodyId = ctx.jsonBodyId
  let sseBodyId = ctx.sseBodyId
  let streamBodyId = ctx.streamBodyId
  let errorId = ctx.errorId
  let responseId = ctx.responseId

  if body.kind == nnkEmpty:
    return body
  if body.kind in {nnkIdent, nnkSym}:
    let name = ($body)
    case name
    of "req": return ctx.reqId
    of "pathParams": return ctx.ppId
    of "queryParams": return ctx.qpId
    of "response", "resp": return ctx.responseId
    of "error": return ctx.errorId
    of "deprecated": return newStmtList()
    else: discard

  if body.kind == nnkCall and body[0].kind == nnkBracketExpr:
    let rewritten = rewriteBracketCall(body, ctx)
    if rewritten != nil:
      return rewritten

  if body.kind in {nnkCall, nnkCommand} and body[0].kind in {nnkIdent, nnkSym}:
    let name = ($body[0]).toLowerAscii
    case name
    of "respond":
      if body.len == 2:
        let code = body[1]
        return quote do:
          return newResponse(`code`, "", `headersId`)
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return newResponse(`code`, `respBody`, `headersId`)
      if body.len == 4:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        let hdrs = rewriteDsl(body[3], ctx)
        return quote do:
          return newResponse(`code`, `respBody`, `headersId` & `hdrs`)
    of "body":
      if body.len == 1: return newDotExpr(ctx.reqId, mkIdent("body"))
    of "method":
      if body.len == 1: return newDotExpr(ctx.reqId, mkIdent("meth"))
    of "path":
      if body.len == 1: return newDotExpr(ctx.reqId, mkIdent("path"))
    of "header":
      if body.len == 2: return newCall(mkIdent("getHeader"), ctx.reqId, body[1])
    of "queryparam":
      if body.len == 2:
        return newCall(newDotExpr(ctx.qpId, mkIdent("getOrDefault")), body[1])
      if body.len == 3:
        return newCall(newDotExpr(ctx.qpId, mkIdent("getOrDefault")), body[1], rewriteDsl(body[2], ctx))
    of "pathparam":
      if body.len == 2:
        return newCall(mkIdent("pathParamValue"), ctx.ppId, body[1])
    of "pathint":
      if body.len == 2: return newCall(mkIdent("pathParamInt"), ctx.ppId, body[1])
    of "pathfloat":
      if body.len == 2: return newCall(mkIdent("pathParamFloat"), ctx.ppId, body[1])
    of "pathbool":
      if body.len == 2: return newCall(mkIdent("pathParamBool"), ctx.ppId, body[1])
    of "queryint":
      if body.len == 2: return newCall(mkIdent("queryParamInt"), ctx.qpId, body[1])
      if body.len == 3: return newCall(mkIdent("queryParamInt"), ctx.qpId, body[1], rewriteDsl(body[2], ctx))
    of "queryfloat":
      if body.len == 2: return newCall(mkIdent("queryParamFloat"), ctx.qpId, body[1])
      if body.len == 3: return newCall(mkIdent("queryParamFloat"), ctx.qpId, body[1], rewriteDsl(body[2], ctx))
    of "querybool":
      if body.len == 2: return newCall(mkIdent("queryParamBool"), ctx.qpId, body[1])
      if body.len == 3: return newCall(mkIdent("queryParamBool"), ctx.qpId, body[1], rewriteDsl(body[2], ctx))
    of "getcookie":
      if body.len == 2: return newCall(mkIdent("getCookie"), ctx.reqId, body[1])
    of "setcookie":
      var call = newCall(mkIdent("setCookieHeader"))
      for i in 1 ..< body.len:
        call.add rewriteDsl(body[i], ctx)
      return newCall(newDotExpr(ctx.headersId, mkIdent("add")), call)
    of "json":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return jsonResponse(`code`, `respBody`, `headersId`)
    of "html":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return htmlResponse(`code`, `respBody`, `headersId`)
    of "text":
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return textResponse(`code`, `respBody`, `headersId`)
    of "redirect":
      if body.len == 2:
        let location = rewriteDsl(body[1], ctx)
        return quote do:
          return redirectResponse(`location`)
      if body.len == 3:
        let code = body[1]
        let location = rewriteDsl(body[2], ctx)
        return quote do:
          return redirectResponse(`location`, `code`)
    of "created":
      if body.len == 2:
        let location = rewriteDsl(body[1], ctx)
        return quote do:
          return newResponse(201, "", `headersId` & @[("Location", `location`)])
      if body.len == 3:
        let location = rewriteDsl(body[1], ctx)
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return newResponse(201, `respBody`, `headersId` & @[("Location", `location`)])
    of "nocontent":
      return quote do:
        return newResponse(204, "", `headersId`)
    of "notmodified":
      return quote do:
        return newResponse(304, "", `headersId`)
    of "badrequest":
      if body.len == 1:
        return quote do:
          return newResponse(400, "", `headersId`)
      if body.len == 2:
        let respBody = rewriteDsl(body[1], ctx)
        return quote do:
          return newResponse(400, `respBody`, `headersId`)
    of "unauthorized":
      if body.len == 1:
        return quote do:
          return newResponse(401, "", `headersId`)
      if body.len == 2:
        let respBody = rewriteDsl(body[1], ctx)
        return quote do:
          return newResponse(401, `respBody`, `headersId`)
    of "forbidden":
      if body.len == 1:
        return quote do:
          return newResponse(403, "", `headersId`)
      if body.len == 2:
        let respBody = rewriteDsl(body[1], ctx)
        return quote do:
          return newResponse(403, `respBody`, `headersId`)
    of "servererror":
      if body.len == 1:
        return quote do:
          return newResponse(500, "", `headersId`)
      if body.len == 2:
        let respBody = rewriteDsl(body[1], ctx)
        return quote do:
          return newResponse(500, `respBody`, `headersId`)
    of "sendfile":
      if body.len == 2:
        let filePath = rewriteDsl(body[1], ctx)
        return quote do:
          return fileResponse(`filePath`)
    of "download":
      if body.len == 2:
        let filePath = rewriteDsl(body[1], ctx)
        return quote do:
          return downloadResponse(`filePath`)
      if body.len == 3:
        let filePath = rewriteDsl(body[1], ctx)
        let filename = rewriteDsl(body[2], ctx)
        return quote do:
          return downloadResponse(`filePath`, `filename`)
    of "formparam":
      if body.len == 2:
        let key = body[1]
        return quote do:
          block:
            if not `formParsedId`:
              `formBodyId` = parseFormBody(`reqId`.body)
              `formParsedId` = true
            `formBodyId`.getOrDefault(`key`)
      if body.len == 3:
        let key = body[1]
        let defaultVal = rewriteDsl(body[2], ctx)
        return quote do:
          block:
            if not `formParsedId`:
              `formBodyId` = parseFormBody(`reqId`.body)
              `formParsedId` = true
            `formBodyId`.getOrDefault(`key`, `defaultVal`)
    of "formparams":
      return quote do:
        block:
          if not `formParsedId`:
            `formBodyId` = parseFormBody(`reqId`.body)
            `formParsedId` = true
          `formBodyId`
    of "jsonbody":
      return quote do:
        block:
          if not `jsonParsedId`:
            `jsonBodyId` = parseJsonBody(`reqId`.body)
            `jsonParsedId` = true
          `jsonBodyId`
    of "jsonas":
      if body.len == 2:
        let targetType = body[1]
        return quote do:
          block:
            if not `jsonParsedId`:
              `jsonBodyId` = parseJsonBody(`reqId`.body)
              `jsonParsedId` = true
            to(`jsonBodyId`, `targetType`)
    of "clientip":
      return newCall(mkIdent("extractClientIp"), ctx.reqId)
    of "bearertoken":
      return newCall(mkIdent("extractBearerToken"), ctx.reqId)
    of "basicauth":
      return newCall(mkIdent("parseBasicAuth"), ctx.reqId)
    of "escapehtml":
      if body.len == 2: return newCall(mkIdent("escapeHtml"), rewriteDsl(body[1], ctx))
    of "pass":
      return quote do:
        return passRouteResponse(`headersId`)
    of "halt":
      if body.len == 1:
        return quote do:
          return newResponse(200, "", `headersId`)
      if body.len == 2:
        let code = body[1]
        return quote do:
          return newResponse(`code`, "", `headersId`)
      if body.len == 3:
        let code = body[1]
        let respBody = rewriteDsl(body[2], ctx)
        return quote do:
          return newResponse(`code`, `respBody`, `headersId`)
    of "etag":
      if body.len == 2:
        let etagVal = rewriteDsl(body[1], ctx)
        return quote do:
          block:
            let embeddedEtag = `etagVal`
            if checkEtag(`reqId`, embeddedEtag):
              return newResponse(304, "", @[("ETag", embeddedEtag)])
            `headersId`.add ("ETag", embeddedEtag)
    of "cachecontrol":
      if body.len == 2:
        let directive = rewriteDsl(body[1], ctx)
        return quote do:
          `headersId`.add ("Cache-Control", `directive`)
    of "nocache":
      return quote do:
        `headersId`.add ("Cache-Control", "no-store, no-cache, must-revalidate")
    of "accept":
      let acceptNode = rewriteAcceptBlock(body, ctx)
      if acceptNode != nil:
        return acceptNode
    of "render":
      return quote do:
        return unsupportedEmbeddedResponse("render")
    of "summary", "tag", "description", "deprecated":
      return newStmtList()
    of "background":
      return newStmtList()
    of "initsse":
      return quote do:
        discard initSse(`reqId`, `headersId`)
    of "sendevent":
      if body.len >= 2:
        var call = newCall(mkIdent("sseEvent"))
        for i in 1 ..< body.len:
          call.add rewriteDsl(body[i], ctx)
        var sendCall = newCall(mkIdent("sendSseEvent"), reqId)
        for i in 1 ..< body.len:
          sendCall.add rewriteDsl(body[i], ctx)
        return quote do:
          if `reqId`.hasTransport:
            discard `sendCall`
          else:
            `sseBodyId`.add `call`
    of "sendcomment":
      if body.len == 2:
        let text = rewriteDsl(body[1], ctx)
        return quote do:
          if `reqId`.hasTransport:
            discard sendSseComment(`reqId`, `text`)
          else:
            `sseBodyId`.add sseComment(`text`)
    of "closesse":
      return quote do:
        if `reqId`.hasTransport:
          return handledResponse()
        else:
          return sseResponse(`sseBodyId`, `headersId`)
    of "initstream":
      return quote do:
        discard initStream(`reqId`, `headersId`)
    of "sendchunk":
      if body.len == 2:
        let chunk = rewriteDsl(body[1], ctx)
        return quote do:
          if `reqId`.hasTransport:
            discard sendChunk(`reqId`, `chunk`)
          else:
            `streamBodyId`.add `chunk`
    of "endstream":
      return quote do:
        if `reqId`.hasTransport:
          return endStream(`reqId`)
        else:
          return streamResponse(`streamBodyId`, "application/octet-stream", `headersId`)
    of "recvmessage":
      return newDotExpr(ctx.reqId, mkIdent("body"))
    of "sendtext":
      if body.len == 2:
        let data = rewriteDsl(body[1], ctx)
        return quote do:
          if `reqId`.webSocketMessage or `reqId`.transportUpgraded:
            return sendWebSocketText(`reqId`, `data`)
          else:
            return textResponse(200, `data`, `headersId`)
    of "sendbinary":
      if body.len == 2:
        let data = rewriteDsl(body[1], ctx)
        return quote do:
          if `reqId`.webSocketMessage or `reqId`.transportUpgraded:
            return sendWebSocketBinary(`reqId`, `data`)
          else:
            return streamResponse(`data`, "application/octet-stream", `headersId`)
    of "sendping", "sendpong":
      return quote do:
        return sendWebSocketPong(`reqId`)
    of "sendclose", "closews":
      return quote do:
        return closeWebSocket(`reqId`)
    of "upload", "uploads", "formfield":
      let feature = newStrLitNode(name)
      return quote do:
        return unsupportedEmbeddedResponse(`feature`)
    of "errormessage":
      return newDotExpr(ctx.errorId, mkIdent("msg"))
    of "errortype":
      return newCall(mkIdent("$"), newCall(mkIdent("typeof"), ctx.errorId))
    else:
      discard

  rewriteChildren(body, ctx)

proc returnsLastExpr(body: NimNode): NimNode {.compileTime.} =
  result = copyNimTree(body)
  if result.kind != nnkStmtList:
    return newStmtList(newNimNode(nnkReturnStmt).add(result))
  if result.len == 0:
    return newStmtList(newNimNode(nnkReturnStmt).add(
      newCall(mkIdent("newResponse"), newIntLitNode(200), newStrLitNode(""))
    ))
  let lastIdx = result.len - 1
  let last = result[lastIdx]
  if last.kind in {nnkReturnStmt, nnkIfStmt, nnkWhenStmt, nnkCaseStmt, nnkTryStmt}:
    return result
  result[lastIdx] = newNimNode(nnkReturnStmt).add(last)

proc buildHandlerExpr(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  let rewritten = returnsLastExpr(rewriteDsl(body, ctx))
  var stmts = newStmtList()
  let headersId = ctx.headersId
  let formParsedId = ctx.formParsedId
  let formBodyId = ctx.formBodyId
  let jsonParsedId = ctx.jsonParsedId
  let jsonBodyId = ctx.jsonBodyId
  let sseBodyId = ctx.sseBodyId
  let streamBodyId = ctx.streamBodyId
  stmts.add quote do:
    var `headersId`: seq[(string, string)] = @[]
    var `formParsedId` = false
    var `formBodyId` = initTable[string, string]()
    var `jsonParsedId` = false
    var `jsonBodyId` = newJNull()
    var `sseBodyId` = ""
    var `streamBodyId` = ""
  if rewritten.kind == nnkStmtList:
    for child in rewritten:
      stmts.add child
  else:
    stmts.add rewritten
  let reqId = ctx.reqId
  let ppId = ctx.ppId
  let qpId = ctx.qpId
  quote do:
    proc(`reqId`: HttpRequest, `ppId`: Table[string, string],
         `qpId`: Table[string, string]): HttpResponseBuilder {.closure.} =
      `stmts`

proc buildErrorHandlerExpr(body: NimNode, ctx: RewriteCtx): NimNode {.compileTime.} =
  let rewritten = returnsLastExpr(rewriteDsl(body, ctx))
  var stmts = newStmtList()
  let headersId = ctx.headersId
  let formParsedId = ctx.formParsedId
  let formBodyId = ctx.formBodyId
  let jsonParsedId = ctx.jsonParsedId
  let jsonBodyId = ctx.jsonBodyId
  let sseBodyId = ctx.sseBodyId
  let streamBodyId = ctx.streamBodyId
  stmts.add quote do:
    var `headersId`: seq[(string, string)] = @[]
    var `formParsedId` = false
    var `formBodyId` = initTable[string, string]()
    var `jsonParsedId` = false
    var `jsonBodyId` = newJNull()
    var `sseBodyId` = ""
    var `streamBodyId` = ""
  if rewritten.kind == nnkStmtList:
    for child in rewritten:
      stmts.add child
  else:
    stmts.add rewritten
  let reqId = ctx.reqId
  let errId = ctx.errorId
  quote do:
    proc(`reqId`: HttpRequest, `errId`: ref CatchableError): HttpResponseBuilder {.closure.} =
      `stmts`

proc findStmtBody(stmt: NimNode, startIdx: int): int {.compileTime.} =
  result = -1
  for i in countdown(stmt.len - 1, startIdx):
    if stmt[i].kind == nnkStmtList:
      return i

proc routeNameArg(stmt: NimNode): string {.compileTime.} =
  for i in 1 ..< stmt.len:
    if stmt[i].kind == nnkExprEqExpr and stmt[i][0].kind in {nnkIdent, nnkSym} and
        ($stmt[i][0]).toLowerAscii == "name" and
        stmt[i][1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      return stmt[i][1].strVal
  ""

proc addRouteStmt(stmts: var NimNode, routerSym, globalMwSym, groupMwSym: NimNode,
                  meth: string, pathExpr, body: NimNode, routeName: string) {.compileTime.} =
  let reqId = genSym(nskParam, "req")
  let ppId = genSym(nskParam, "pathParams")
  let qpId = genSym(nskParam, "queryParams")
  var ctx = newRewriteCtx(reqId, ppId, qpId)
  let handlerSym = genSym(nskLet, "embeddedRouteHandler")
  let handlerExpr = buildHandlerExpr(body, ctx)
  let methodLit = newStrLitNode(meth)
  let nameLit = newStrLitNode(routeName)
  stmts.add quote do:
    let `handlerSym`: EmbeddedRouteHandler = `handlerExpr`
    addRoute(`routerSym`, `methodLit`, `pathExpr`, `handlerSym`,
             `globalMwSym` & `groupMwSym`, `nameLit`)

proc addMiddlewareFromBody(stmts: var NimNode, targetMwSym: NimNode, body: NimNode,
                           isAfter: bool) {.compileTime.} =
  let reqId = mkIdent("req")
  let ppId =
    if isAfter: genSym(nskLet, "pathParams")
    else: mkIdent("pathParams")
  let qpId =
    if isAfter: genSym(nskLet, "queryParams")
    else: mkIdent("queryParams")
  var ctx = newRewriteCtx(reqId, ppId, qpId)
  let headersId = ctx.headersId
  let formParsedId = ctx.formParsedId
  let formBodyId = ctx.formBodyId
  let jsonParsedId = ctx.jsonParsedId
  let jsonBodyId = ctx.jsonBodyId
  let sseBodyId = ctx.sseBodyId
  let streamBodyId = ctx.streamBodyId
  let mwSym = genSym(nskLet, if isAfter: "embeddedAfterMw" else: "embeddedBeforeMw")
  let nextId = mkIdent("next")
  if isAfter:
    let respId = genSym(nskVar, "resp")
    ctx.responseId = respId
    var rewritten = rewriteDsl(body, ctx)
    if rewritten.kind != nnkStmtList:
      rewritten = newStmtList(rewritten)
    stmts.add quote do:
      let `mwSym`: EmbeddedMiddleware =
        proc(`reqId`: HttpRequest, `nextId`: HttpHandler): HttpResponseBuilder {.closure.} =
          var `respId` = `nextId`(`reqId`)
          let `ppId` = initTable[string, string]()
          let `qpId` = parseQueryString(`reqId`.path)
          var `headersId` = `respId`.headers
          var `formParsedId` = false
          var `formBodyId` = initTable[string, string]()
          var `jsonParsedId` = false
          var `jsonBodyId` = newJNull()
          var `sseBodyId` = ""
          var `streamBodyId` = ""
          `rewritten`
          `respId`
      `targetMwSym`.add `mwSym`
  else:
    let handlerExpr = buildHandlerExpr(body, ctx)
    let checkSym = genSym(nskLet, "embeddedBeforeCheck")
    let localPpId = genSym(nskLet, "pathParams")
    let localQpId = genSym(nskLet, "queryParams")
    stmts.add quote do:
      let `checkSym`: EmbeddedRouteHandler = `handlerExpr`
      let `mwSym`: EmbeddedMiddleware =
        proc(`reqId`: HttpRequest, `nextId`: HttpHandler): HttpResponseBuilder {.closure.} =
          let `localPpId` = initTable[string, string]()
          let `localQpId` = parseQueryString(`reqId`.path)
          let checkResp = `checkSym`(`reqId`, `localPpId`, `localQpId`)
          if checkResp.control == rcContinue or checkResp.statusCode == 0:
            `nextId`(`reqId`)
          else:
            checkResp
      `targetMwSym`.add `mwSym`

proc processStatements(stmts: var NimNode, routerSym, globalMwSym, beforeMwSym,
                       afterMwSym, methodOverrideSym, trailingSlashSym: NimNode,
                       bodyList: NimNode, prefix: string, groupMwSym: NimNode,
                       isRootScope: bool, notFoundNode, errorNode: var NimNode) {.compileTime.} =
  let list = if bodyList.kind == nnkStmtList: bodyList else: newStmtList(bodyList)
  for stmt in list:
    if stmt.kind == nnkDiscardStmt:
      continue
    if stmt.kind == nnkIdent:
      let bare = ($stmt).toLowerAscii
      case bare
      of "secure":
        stmts.add quote do: `globalMwSym`.add securityHeadersMiddleware()
      of "requestid":
        stmts.add quote do: `globalMwSym`.add requestIdMiddleware()
      else:
        stmts.add stmt
      continue
    if stmt.kind notin {nnkCall, nnkCommand}:
      stmts.add stmt
      continue
    let cmdName = if stmt[0].kind in {nnkIdent, nnkSym}: ($stmt[0]).toLowerAscii else: ""
    case cmdName
    of "get", "post", "put", "delete", "patch", "head", "options", "any":
      let bodyIdx = findStmtBody(stmt, 1)
      if bodyIdx < 0:
        error("Route requires a body", stmt)
      let pathNode = if stmt.len >= 3 and stmt[1].kind != nnkStmtList: stmt[1] else: newStrLitNode("/")
      let httpMethod = if cmdName == "any": "*" else: cmdName.toUpperAscii
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, httpMethod,
                   prefixedPath(prefix, pathNode), stmt[bodyIdx], routeNameArg(stmt))
    of "route":
      if stmt.len < 4 or stmt[1].kind != nnkBracket:
        error("route expects: route [\"GET\", ...], \"/path\":", stmt)
      let bodyIdx = findStmtBody(stmt, 3)
      if bodyIdx < 0:
        error("route requires a body", stmt)
      let pathExpr = prefixedPath(prefix, stmt[2])
      for methodNode in stmt[1]:
        if methodNode.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          error("route method entries must be string literals", methodNode)
        var httpMethod = methodNode.strVal.toUpperAscii
        if httpMethod == "ANY": httpMethod = "*"
        addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, httpMethod,
                     pathExpr, stmt[bodyIdx], routeNameArg(stmt))
    of "healthcheck":
      if stmt.len notin {2, 3}:
        error("healthCheck expects: healthCheck <path>[, <body>]", stmt)
      let healthBody = if stmt.len == 3: stmt[2] else: newStrLitNode("OK")
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, "GET",
                   prefixedPath(prefix, stmt[1]), newStmtList(
                     newCall(mkIdent("text"), newIntLitNode(200), healthBody)
                   ), "")
    of "group":
      if stmt.len != 3 or stmt[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        error("group requires a string prefix and a body", stmt)
      let nextGroupMw = genSym(nskVar, "embeddedGroupMw")
      stmts.add quote do:
        var `nextGroupMw`: seq[EmbeddedMiddleware] = `groupMwSym`
      processStatements(stmts, routerSym, globalMwSym, beforeMwSym, afterMwSym,
                        methodOverrideSym, trailingSlashSym, stmt[2],
                        prefix & stmt[1].strVal, nextGroupMw, false,
                        notFoundNode, errorNode)
    of "use":
      if stmt.len != 2:
        error("use expects one middleware", stmt)
      let mwExpr = stmt[1]
      if isRootScope:
        stmts.add quote do:
          `globalMwSym`.add `mwExpr`
      else:
        stmts.add quote do:
          `groupMwSym`.add `mwExpr`
    of "before":
      if stmt.len != 2 or stmt[1].kind != nnkStmtList:
        error("before expects a block", stmt)
      addMiddlewareFromBody(stmts, beforeMwSym, stmt[1], false)
    of "after":
      if stmt.len != 2 or stmt[1].kind != nnkStmtList:
        error("after expects a block", stmt)
      addMiddlewareFromBody(stmts, afterMwSym, stmt[1], true)
    of "notfound":
      if not isRootScope:
        error("notFound must be declared at router root scope", stmt)
      if stmt.len != 2 or stmt[1].kind != nnkStmtList:
        error("notFound expects a block", stmt)
      let reqId = genSym(nskParam, "req")
      let ppId = genSym(nskParam, "pathParams")
      let qpId = genSym(nskParam, "queryParams")
      let ctx = newRewriteCtx(reqId, ppId, qpId)
      let handlerSym = genSym(nskLet, "embeddedNotFound")
      let handlerExpr = buildHandlerExpr(stmt[1], ctx)
      stmts.add quote do:
        let `handlerSym`: EmbeddedRouteHandler = `handlerExpr`
      notFoundNode = handlerSym
    of "onerror":
      if not isRootScope:
        error("onError must be declared at router root scope", stmt)
      if stmt.len != 2 or stmt[1].kind != nnkStmtList:
        error("onError expects a block", stmt)
      let reqId = genSym(nskParam, "req")
      let ppId = genSym(nskLet, "pathParams")
      let qpId = genSym(nskLet, "queryParams")
      let ctx = newRewriteCtx(reqId, ppId, qpId)
      let handlerSym = genSym(nskLet, "embeddedError")
      let handlerExpr = buildErrorHandlerExpr(stmt[1], ctx)
      stmts.add quote do:
        let `handlerSym` = `handlerExpr`
      errorNode = handlerSym
    of "cors":
      if stmt.len == 1:
        stmts.add quote do: `globalMwSym`.add corsMiddleware()
      elif stmt.len == 2 and stmt[1].kind != nnkStmtList:
        let origin = stmt[1]
        stmts.add quote do:
          `globalMwSym`.add corsMiddleware(`origin`)
      else:
        stmts.add quote do: `globalMwSym`.add corsMiddleware()
    of "secure":
      stmts.add quote do: `globalMwSym`.add securityHeadersMiddleware()
    of "requestid":
      if stmt.len == 1:
        stmts.add quote do: `globalMwSym`.add requestIdMiddleware()
      elif stmt.len == 2:
        let headerName = stmt[1]
        stmts.add quote do:
          `globalMwSym`.add requestIdMiddleware(`headerName`)
    of "maxbodysize":
      if stmt.len != 2: error("maxBodySize expects one argument", stmt)
      let maxBytes = stmt[1]
      stmts.add quote do:
        `globalMwSym`.add bodySizeLimitMiddleware(`maxBytes`)
    of "timeout":
      if stmt.len != 2: error("timeout expects one argument", stmt)
      let timeoutMs = stmt[1]
      stmts.add quote do:
        `globalMwSym`.add timeoutMiddleware(`timeoutMs`)
    of "accesslog":
      if stmt.len == 1:
        stmts.add quote do: `globalMwSym`.add accessLogMiddleware()
      elif stmt.len == 2:
        let format = stmt[1]
        stmts.add quote do:
          `globalMwSym`.add accessLogMiddleware(`format`)
    of "ratelimit":
      if stmt.len < 3: error("rateLimit expects maxRequests, windowSeconds", stmt)
      let maxReqs = stmt[1]
      let windowSecs = stmt[2]
      stmts.add quote do:
        `globalMwSym`.add rateLimitMiddleware(`maxReqs`, `windowSecs`)
    of "compress":
      if stmt.len == 1:
        stmts.add quote do: `globalMwSym`.add compressionMiddleware()
      elif stmt.len == 2:
        let minSize = stmt[1]
        stmts.add quote do:
          `globalMwSym`.add compressionMiddleware(`minSize`)
    of "methodoverride":
      stmts.add quote do:
        `methodOverrideSym` = true
    of "trailingslash":
      if stmt.len != 2 or stmt[1].kind notin {nnkIdent, nnkSym}:
        error("trailingSlash expects redirect, strip, or ignore", stmt)
      case ($stmt[1]).toLowerAscii
      of "redirect":
        stmts.add quote do:
          `trailingSlashSym` = tsbRedirect
      of "strip":
        stmts.add quote do:
          `trailingSlashSym` = tsbStrip
      of "ignore":
        stmts.add quote do:
          `trailingSlashSym` = tsbIgnore
      else: error("trailingSlash expects redirect, strip, or ignore", stmt)
    of "mount":
      if stmt.len != 3:
        error("mount expects: mount <prefix>, <Router|HttpHandler>", stmt)
      let mountPrefix = prefixedPath(prefix, stmt[1])
      let mountTarget = stmt[2]
      stmts.add quote do:
        when `mountTarget` is EmbeddedRouter:
          mountRouter(`routerSym`, `mountPrefix`, `mountTarget`, `globalMwSym` & `groupMwSym`)
        elif `mountTarget` is HttpHandler:
          mountHandler(`routerSym`, `mountPrefix`, `mountTarget`, `globalMwSym` & `groupMwSym`)
        else:
          {.error: "mount target must be EmbeddedRouter or HttpHandler".}
    of "sse", "stream":
      let bodyIdx = findStmtBody(stmt, 1)
      let pathNode =
        if stmt.len >= 3 and stmt[1].kind != nnkStmtList: stmt[1]
        else: newStrLitNode("/")
      var routeBody =
        if bodyIdx >= 0: copyNimTree(stmt[bodyIdx])
        else: newStmtList()
      if routeBody.kind != nnkStmtList:
        routeBody = newStmtList(routeBody)
      if cmdName == "sse":
        routeBody.insert(0, newCall(mkIdent("initSse")))
        routeBody.add newCall(mkIdent("closeSse"))
      else:
        routeBody.insert(0, newCall(mkIdent("initStream")))
        routeBody.add newCall(mkIdent("endStream"))
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, "GET",
                   prefixedPath(prefix, pathNode),
                   routeBody, "")
    of "ws":
      let bodyIdx = findStmtBody(stmt, 1)
      let pathNode =
        if stmt.len >= 3 and stmt[1].kind != nnkStmtList: stmt[1]
        else: newStrLitNode("/")
      var routeBody =
        if bodyIdx >= 0: copyNimTree(stmt[bodyIdx])
        else: newStmtList()
      if routeBody.kind != nnkStmtList:
        routeBody = newStmtList(routeBody)
      let wsBody = quote do:
        if not req.transportUpgraded and not req.webSocketMessage:
          return websocketUpgradeResponse(req)
        else:
          `routeBody`
          return handledResponse()
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, "GET",
                   prefixedPath(prefix, pathNode),
                   newStmtList(wsBody), "")
    of "servestatic":
      if stmt.len < 3:
        error("serveStatic requires a URL prefix and directory", stmt)
      if stmt[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        error("serveStatic URL prefix must be a string literal", stmt[1])
      var fallbackFile = ""
      let bodyIdx = findStmtBody(stmt, 3)
      if bodyIdx >= 0:
        for child in stmt[bodyIdx]:
          if child.kind in {nnkCall, nnkCommand} and
              child[0].kind in {nnkIdent, nnkSym} and
              ($child[0]).toLowerAscii == "fallback" and
              child.len == 2 and
              child[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
            fallbackFile = child[1].strVal
      let urlPrefixLit = newStrLitNode(prefix & stmt[1].strVal)
      let fallbackLit = newStrLitNode(fallbackFile)
      let fsDirExpr = stmt[2]
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, "GET",
                   prefixedPath(prefix, newStrLitNode(stmt[1].strVal & "/*")),
                   newStmtList(quote do:
                     return serveStaticFile(`fsDirExpr`, `urlPrefixLit`,
                                            pathWithoutQuery(req.path), req,
                                            fallbackFile = `fallbackLit`)
                   ), "")
    of "openapi":
      let spec = newStrLitNode("{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"embedded\",\"version\":\"1.0.0\"},\"paths\":{}}")
      addRouteStmt(stmts, routerSym, globalMwSym, groupMwSym, "GET",
                   newStrLitNode("/openapi.json"),
                   newStmtList(quote do:
                     return jsonResponse(200, `spec`)
                   ), "")
    of "renderer", "appstate":
      discard
    of "onstart", "onshutdown":
      error("onStart/onShutdown are HttpServer lifecycle hooks and are not supported by embeddedRouter", stmt)
    else:
      stmts.add stmt

proc buildEmbeddedRouter(body: NimNode, returnHandler: bool): NimNode {.compileTime.} =
  let routerSym = genSym(nskVar, "embeddedRouter")
  let globalMwSym = genSym(nskVar, "embeddedGlobalMw")
  let beforeMwSym = genSym(nskVar, "embeddedBeforeMw")
  let afterMwSym = genSym(nskVar, "embeddedAfterMw")
  let rootGroupMwSym = genSym(nskVar, "embeddedRootGroupMw")
  let methodOverrideSym = genSym(nskVar, "embeddedMethodOverride")
  let trailingSlashSym = genSym(nskVar, "embeddedTrailingSlash")
  var notFoundNode: NimNode = nil
  var errorNode: NimNode = nil
  var stmts = newStmtList()
  stmts.add quote do:
    var `routerSym` = initEmbeddedRouter()
    var `globalMwSym`: seq[EmbeddedMiddleware] = @[]
    var `beforeMwSym`: seq[EmbeddedMiddleware] = @[]
    var `afterMwSym`: seq[EmbeddedMiddleware] = @[]
    var `rootGroupMwSym`: seq[EmbeddedMiddleware] = @[]
    var `methodOverrideSym` = false
    var `trailingSlashSym` = tsbIgnore
  processStatements(stmts, routerSym, globalMwSym, beforeMwSym, afterMwSym,
                    methodOverrideSym, trailingSlashSym, body, "", rootGroupMwSym,
                    true, notFoundNode, errorNode)
  stmts.add quote do:
    `routerSym`.globalMiddlewares = `globalMwSym`
    `routerSym`.beforeMiddlewares = `beforeMwSym`
    `routerSym`.afterMiddlewares = `afterMwSym`
    `routerSym`.methodOverrideEnabled = `methodOverrideSym`
    `routerSym`.trailingSlash = `trailingSlashSym`
  if notFoundNode != nil:
    stmts.add quote do:
      setNotFound(`routerSym`, `notFoundNode`)
  if errorNode != nil:
    stmts.add quote do:
      setErrorHandler(`routerSym`, `errorNode`)
  if returnHandler:
    stmts.add quote do:
      toHandler(`routerSym`)
  else:
    stmts.add routerSym
  newBlockStmt(stmts)

macro embeddedRouter*(body: untyped): untyped =
  buildEmbeddedRouter(body, true)

macro router*(body: untyped): untyped =
  buildEmbeddedRouter(body, true)

macro routerObj*(body: untyped): untyped =
  buildEmbeddedRouter(body, false)
