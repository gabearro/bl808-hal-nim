## Host tests for the DNS message code (`dnsmsg.nim`).
##
##   nim c -r --skipUserCfg --skipParentCfg --skipProjCfg tests/t_dnsmsg.nim

import std/strutils
import ../dnsmsg

# -----------------------------------------------------------------------------
# A small reply builder
# -----------------------------------------------------------------------------

type Reply = object
  data: seq[byte]

proc put16(r: var Reply; v: int) =
  r.data.add byte(v shr 8)
  r.data.add byte(v and 0xFF)

proc name(r: var Reply; dotted: string) =
  ## An uncompressed name.
  if dotted.len > 0:
    for label in dotted.split('.'):
      r.data.add byte(label.len)
      for ch in label: r.data.add byte(ch)
  r.data.add 0

proc pointer(r: var Reply; offset: int) =
  r.put16 0xC000 or offset

proc begin(id: int; flags: int; question: string; answers: int): Reply =
  result.put16 id
  result.put16 flags
  result.put16 1
  result.put16 answers
  result.put16 0
  result.put16 0
  result.name question
  result.put16 1
  result.put16 1

proc record(r: var Reply; kind: int; rdLen: int) =
  ## The fixed part after the owner name; the caller appends the data.
  r.put16 kind
  r.put16 1
  r.put16 0
  r.put16 300
  r.put16 rdLen

proc a(r: var Reply; ip: array[4, int]) =
  r.record(1, 4)
  for b in ip: r.data.add byte(b)

proc ip(a, b, c, d: int): uint32 =
  a.uint32 or (b.uint32 shl 8) or (c.uint32 shl 16) or (d.uint32 shl 24)

const
  Response = 0x8180       # QR, RD, RA, no error
  QName = 12              # offset of the question name

var
  addrs: array[MaxAddrs, uint32]
  count: int

# -----------------------------------------------------------------------------

block: # parseIpv4
  var v: uint32
  doAssert parseIpv4("192.168.1.10", v) and v == ip(192, 168, 1, 10)
  doAssert parseIpv4("0.0.0.0", v) and v == 0
  doAssert parseIpv4("255.255.255.255", v) and v == high(uint32)
  doAssert parseIpv4("1.2.3.4", v) and v == 0x0403_0201'u32
  for bad in ["", "1.2.3", "1.2.3.4.5", "1.2.3.", ".1.2.3", "1..2.3", "256.1.1.1",
              "1.2.3.4 ", " 1.2.3.4", "01.2.3.4", "1.2.3.04", "1.2.3.a", "a.b.c.d",
              "1234.1.1.1", "1.2.3.4.", "example.com", "1e1.2.3.4", "0x1.2.3.4"]:
    doAssert not parseIpv4(bad, v), bad

block: # buildQuery
  var buf: array[64, byte]
  let n = buildQuery(0xABCD, "ice1.somafm.com", buf)
  doAssert n == 12 + 17 + 4 and n == queryLen("ice1.somafm.com")
  const Expect = "\xAB\xCD\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" &
    "\x04ice1\x06somafm\x03com\x00\x00\x01\x00\x01"
  for i in 0 ..< n: doAssert buf[i] == byte(Expect[i]), $i
  # A trailing dot is the same name.
  var buf2: array[64, byte]
  doAssert buildQuery(0xABCD, "ice1.somafm.com.", buf2) == n and buf2 == buf
  doAssert buildQuery(1, "localhost", buf) == 12 + 11 + 4 and buf[12] == 9
  # Names DNS can't carry, and a buffer that is too small.
  var small: array[20, byte]
  doAssert buildQuery(1, "ice1.somafm.com", small) == 0
  var big: array[300, byte]
  for bad in ["", ".", "a..b", ".a", "a.b..", repeat('x', 64) & ".com",
              repeat("abcdefg.", 32)]:
    doAssert queryLen(bad) == 0 and buildQuery(1, bad, big) == 0, bad
  doAssert queryLen(repeat('x', 63) & ".com") == 12 + 68 + 1 + 4
  let longest = repeat("abcdefg.", 31) & "abcde"         # 253 bytes
  doAssert longest.len == 253 and buildQuery(7, longest, big) == 12 + 255 + 4

block: # one address, the owner name compressed
  var r = begin(0x1234, Response, "radio.example", 1)
  r.pointer QName
  r.a [10, 0, 0, 7]
  doAssert parseReply(r.data, 0x1234, addrs, count) == drOk
  doAssert count == 1 and addrs[0] == ip(10, 0, 0, 7)

block: # several addresses, uncompressed owners, case differences; at most four kept
  var r = begin(1, Response, "Radio.Example", 6)
  for i in 1 .. 6:
    r.name(if i mod 2 == 0: "RADIO.example" else: "radio.EXAMPLE")
    r.a [192, 0, 2, i]
  doAssert parseReply(r.data, 1, addrs, count) == drOk and count == MaxAddrs
  for i in 0 ..< MaxAddrs: doAssert addrs[i] == ip(192, 0, 2, i + 1)

block: # a CNAME chain, with compression into the middle of other names
  var r = begin(2, Response, "www.radio.example", 4)
  r.pointer QName                             # www.radio.example CNAME edge.cdn.example
  let rd1 = r.data.len + 10
  r.record(5, 0)
  r.data.add 4; r.data.add byte('e'); r.data.add byte('d'); r.data.add byte('g'); r.data.add byte('e')
  let cdnAt = r.data.len
  r.data.add 3; r.data.add byte('c'); r.data.add byte('d'); r.data.add byte('n')
  r.pointer QName + 10                        # "example" inside the question
  r.data[rd1 - 2] = 0
  r.data[rd1 - 1] = byte(r.data.len - rd1)
  r.pointer rd1                               # edge.cdn.example CNAME pop.cdn.example
  let rd2 = r.data.len + 10
  r.record(5, 0)
  r.data.add 3; r.data.add byte('p'); r.data.add byte('o'); r.data.add byte('p')
  r.pointer cdnAt
  r.data[rd2 - 1] = byte(r.data.len - rd2)
  r.pointer rd2                               # pop.cdn.example A x2
  r.a [203, 0, 113, 1]
  r.name "POP.cdn.example"
  r.a [203, 0, 113, 2]
  doAssert parseReply(r.data, 2, addrs, count) == drOk
  doAssert count == 2 and addrs[0] == ip(203, 0, 113, 1) and addrs[1] == ip(203, 0, 113, 2)

block: # the chain's records in the "wrong" order
  var r = begin(3, Response, "a.example", 3)
  r.name "c.example"
  r.a [1, 1, 1, 1]
  r.name "b.example"
  r.record(5, 11)
  r.name "c.example"
  r.name "a.example"
  r.record(5, 11)
  r.name "b.example"
  doAssert parseReply(r.data, 3, addrs, count) == drOk
  doAssert count == 1 and addrs[0] == ip(1, 1, 1, 1)

block: # records that don't answer the question are ignored
  var r = begin(4, Response, "radio.example", 4)
  r.name "other.example"                      # someone else's address
  r.a [9, 9, 9, 9]
  r.pointer QName                             # AAAA
  r.record(28, 16)
  for i in 0 ..< 16: r.data.add byte(i)
  r.pointer QName                             # an A record of the wrong size
  r.record(1, 3)
  for i in 0 ..< 3: r.data.add 7
  r.pointer QName                             # class CH
  r.put16 1; r.put16 3; r.put16 0; r.put16 0; r.put16 4
  for i in 0 ..< 4: r.data.add 8
  doAssert parseReply(r.data, 4, addrs, count) == drNoAddress and count == 0

block: # no records at all; a CNAME that leads nowhere; a CNAME loop
  var r = begin(5, Response, "radio.example", 0)
  doAssert parseReply(r.data, 5, addrs, count) == drNoAddress
  r = begin(5, Response, "radio.example", 1)
  r.pointer QName
  r.record(5, 14)
  r.name "gone.example"
  doAssert parseReply(r.data, 5, addrs, count) == drNoAddress
  r = begin(5, Response, "a.example", 2)
  r.name "a.example"
  r.record(5, 11)
  r.name "b.example"
  r.name "b.example"
  r.record(5, 11)
  r.name "a.example"
  doAssert parseReply(r.data, 5, addrs, count) == drNoAddress

block: # response codes
  var r = begin(6, 0x8183, "nope.example", 0)
  doAssert parseReply(r.data, 6, addrs, count) == drNameError
  r = begin(6, 0x8182, "radio.example", 0)
  doAssert parseReply(r.data, 6, addrs, count) == drServerError
  r = begin(6, 0x8185, "radio.example", 0)
  doAssert parseReply(r.data, 6, addrs, count) == drServerError

block: # not for us
  var r = begin(7, Response, "radio.example", 1)
  r.pointer QName
  r.a [10, 0, 0, 1]
  doAssert parseReply(r.data, 8, addrs, count) == drNotOurs and count == 0
  var q = begin(7, 0x0100, "radio.example", 0)          # a query, not a reply
  doAssert parseReply(q.data, 7, addrs, count) == drNotOurs

block: # malformed and truncated messages never read out of bounds
  var r = begin(9, Response, "radio.example", 2)
  r.pointer QName
  r.a [10, 0, 0, 1]
  r.pointer QName
  r.a [10, 0, 0, 2]
  let whole = r.data
  for cut in 0 ..< whole.len:
    let res = parseReply(whole.toOpenArray(0, cut - 1), 9, addrs, count)
    if cut < 12: doAssert res == drMalformed
    elif cut < whole.len - 16: doAssert res == drMalformed, $cut
    else: doAssert res == drOk and count == 1 and addrs[0] == ip(10, 0, 0, 1), $cut
  doAssert parseReply(whole, 9, addrs, count) == drOk and count == 2

  var loop = begin(9, Response, "radio.example", 1)     # a pointer to itself
  let at = loop.data.len
  loop.pointer at
  loop.a [1, 2, 3, 4]
  doAssert parseReply(loop.data, 9, addrs, count) == drNoAddress

  var wild = begin(9, Response, "radio.example", 1)     # a pointer past the end
  wild.pointer 0x3FFF
  wild.a [1, 2, 3, 4]
  doAssert parseReply(wild.data, 9, addrs, count) == drNoAddress

  var badLabel = begin(9, Response, "radio.example", 1) # the reserved 0x40 label type
  badLabel.data.add 0x40
  badLabel.a [1, 2, 3, 4]
  doAssert parseReply(badLabel.data, 9, addrs, count) == drMalformed

  var twoQuestions = begin(9, Response, "radio.example", 0)
  twoQuestions.data[5] = 2
  doAssert parseReply(twoQuestions.data, 9, addrs, count) == drMalformed

  # Random bytes behind a valid header: any result, no crash.
  var seed = 12345'u32
  for round in 0 ..< 2000:
    var junk = begin(9, Response, "radio.example", 3).data
    for i in 0 ..< 40:
      seed = seed * 1664525'u32 + 1013904223'u32
      junk.add byte(seed shr 24)
    discard parseReply(junk, 9, addrs, count)
    doAssert count in 0 .. MaxAddrs

echo "t_dnsmsg: ok"
