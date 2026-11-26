## DNS messages for A-record lookups (RFC 1035): build a query, read the
## addresses out of a reply. Pure Nim, no HAL imports; `resolver.nim` does
## the UDP exchange.

const
  DnsPort* = 53'u16
  MaxAddrs* = 4
  HeaderLen = 12
  MaxNameLen = 253
  TypeA = 1
  TypeCname = 5
  ClassIn = 1
  MaxCnameHops = 8

type
  DnsReply* = enum
    drOk            ## at least one address
    drNoAddress     ## the name exists but has no A record
    drNameError     ## NXDOMAIN
    drServerError   ## SERVFAIL, REFUSED, ...: another server may do better
    drMalformed
    drNotOurs       ## not a reply, or not to this query

func parseIpv4*(s: openArray[char]; ip: var uint32): bool =
  ## A dotted quad ("192.168.1.10"), into network byte order as lwIP keeps
  ## it (the first octet in the lowest byte). Strict: four decimal parts of
  ## 0..255 without leading zeros, nothing else.
  var value = 0'u32
  var part = 0
  var i = 0
  while part < 4:
    let start = i
    var octet = 0
    while i < s.len and s[i] in {'0' .. '9'} and i - start < 3:
      octet = octet * 10 + (s[i].ord - '0'.ord)
      inc i
    if i == start or octet > 255 or (i - start > 1 and s[start] == '0'):
      return false
    value = value or (octet.uint32 shl (8 * part))
    inc part
    if part < 4:
      if i >= s.len or s[i] != '.': return false
      inc i
  if i != s.len: return false
  ip = value
  true

func nameLen(host: openArray[char]): int =
  ## Length of `host` without one trailing dot, or 0 if it is not a name
  ## DNS can carry (labels of 1..63 bytes, 253 in all).
  var n = host.len
  if n > 0 and host[n - 1] == '.': dec n
  if n == 0 or n > MaxNameLen: return 0
  var label = 0
  for i in 0 ..< n:
    if host[i] == '.':
      if label == 0: return 0
      label = 0
    else:
      inc label
      if label > 63: return 0
  if label == 0: 0 else: n

func queryLen*(host: openArray[char]): int =
  ## Size of the query for `host`, or 0 if the name is not valid.
  let n = nameLen(host)
  if n == 0: 0 else: HeaderLen + n + 2 + 4

func buildQuery*(id: uint16; host: openArray[char]; dst: var openArray[byte]): int =
  ## Write a recursive A query; returns its length (`queryLen(host)`), or 0
  ## if the name is not valid or `dst` is too small.
  let total = queryLen(host)
  if total == 0 or dst.len < total: return 0
  let n = nameLen(host)
  dst[0] = byte(id shr 8)
  dst[1] = byte(id and 0xFF)
  dst[2] = 0x01                   # recursion desired
  dst[3] = 0
  dst[4] = 0
  dst[5] = 1                      # one question
  for i in 6 ..< HeaderLen: dst[i] = 0
  var lengthAt = HeaderLen
  var pos = HeaderLen + 1
  for i in 0 ..< n:
    if host[i] == '.':
      dst[lengthAt] = byte(pos - lengthAt - 1)
      lengthAt = pos
    else:
      dst[pos] = byte(host[i])
    inc pos
  dst[lengthAt] = byte(pos - lengthAt - 1)
  dst[pos] = 0                    # root
  dst[pos + 1] = 0
  dst[pos + 2] = TypeA
  dst[pos + 3] = 0
  dst[pos + 4] = ClassIn
  total

func be16(msg: openArray[byte]; at: int): int {.inline.} =
  (msg[at].int shl 8) or msg[at + 1].int

func skipName(msg: openArray[byte]; at: int): int =
  ## The offset just past the (possibly compressed) name at `at`, or -1.
  var pos = at
  while pos < msg.len:
    let b = msg[pos].int
    if b == 0: return pos + 1
    if (b and 0xC0) == 0xC0:
      return (if pos + 2 <= msg.len: pos + 2 else: -1)
    if (b and 0xC0) != 0: return -1
    pos += 1 + b
  -1

func nextLabel(msg: openArray[byte]; pos: var int; jumps: var int): int =
  ## Follow compression pointers to the next label of a name. Returns its
  ## length with `pos` at its first byte, 0 at the end of the name, or -1.
  while true:
    if pos >= msg.len: return -1
    let b = msg[pos].int
    if (b and 0xC0) == 0xC0:
      if pos + 1 >= msg.len: return -1
      inc jumps
      if jumps > 64: return -1    # a pointer loop
      pos = ((b and 0x3F) shl 8) or msg[pos + 1].int
    elif (b and 0xC0) != 0:
      return -1
    else:
      inc pos
      if pos + b > msg.len: return -1
      return b

func sameName(msg: openArray[byte]; a, b: int): bool =
  ## Whether the names at offsets `a` and `b` are equal (ASCII case does
  ## not matter in DNS).
  var pa = a
  var pb = b
  var jumps = 0
  while true:
    let la = nextLabel(msg, pa, jumps)
    let lb = nextLabel(msg, pb, jumps)
    if la < 0 or la != lb: return false
    if la == 0: return true
    for i in 0 ..< la:
      var ca = msg[pa + i]
      var cb = msg[pb + i]
      if ca in byte('A') .. byte('Z'): ca += 32
      if cb in byte('A') .. byte('Z'): cb += 32
      if ca != cb: return false
    pa += la
    pb += lb

func parseReply*(msg: openArray[byte]; id: uint16;
                 addrs: var array[MaxAddrs, uint32]; count: var int): DnsReply =
  ## Read the reply to the query `id`: the A records of the name asked
  ## for, following CNAME records in the answer (in any order). Addresses
  ## come out in network byte order, at most `MaxAddrs` of them.
  count = 0
  if msg.len < HeaderLen: return drMalformed
  if be16(msg, 0) != id.int or (msg[2] and 0x80) == 0: return drNotOurs
  case msg[3].int and 0x0F
  of 0: discard
  of 3: return drNameError
  else: return drServerError
  if be16(msg, 4) != 1: return drMalformed
  let answers = be16(msg, 6)
  let answersAt = block:
    let pastName = skipName(msg, HeaderLen)
    if pastName < 0 or pastName + 4 > msg.len: return drMalformed
    pastName + 4

  var name = HeaderLen            # the name asked for, then its aliases
  for hop in 0 .. MaxCnameHops:
    var alias = -1
    var pos = answersAt
    count = 0
    for i in 0 ..< answers:
      let owner = pos
      pos = skipName(msg, pos)
      if pos < 0 or pos + 10 > msg.len:
        # Cut short (a truncated reply): keep what was complete.
        return (if count > 0: drOk else: drMalformed)
      let kind = be16(msg, pos)
      let class = be16(msg, pos + 2)
      let rdLen = be16(msg, pos + 8)
      let rdata = pos + 10
      if rdata + rdLen > msg.len:
        return (if count > 0: drOk else: drMalformed)
      if class == ClassIn and sameName(msg, owner, name):
        if kind == TypeA and rdLen == 4:
          if count < MaxAddrs:
            addrs[count] = msg[rdata].uint32 or (msg[rdata + 1].uint32 shl 8) or
              (msg[rdata + 2].uint32 shl 16) or (msg[rdata + 3].uint32 shl 24)
            inc count
        elif kind == TypeCname and alias < 0:
          alias = rdata
      pos = rdata + rdLen
    if count > 0 or alias < 0: break
    name = alias
  if count > 0: drOk else: drNoAddress
