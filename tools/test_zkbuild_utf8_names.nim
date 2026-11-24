## Exhaustive scalar encodings and malformed boundary classes, compared with
## the runtime parser. This complements the circuit and Lean framing checks.
import cps/wasm/utf8_names
import cps/zk/wasm_names

proc check(name: string, expected: bool, count: var int) =
  var accepted = true
  try: discard buildNameEnvironment([name])
  except ValueError: accepted = false
  doAssert accepted == expected, "prover UTF-8 classification mismatch"
  doAssert validWasmName(name) == expected, "runtime UTF-8 classification mismatch"
  inc count

proc main() =
  var count = 0
  check("",true,count)
  for a in 0..255:
    check($char(a),a < 128,count)
    for b in 0..255:
      let expected = (a < 128 and b < 128) or (a in 0xc2..0xdf and b in 0x80..0xbf)
      check($char(a) & $char(b),expected,count)
  for a in 0xe0..0xef:
    for b in 0x80..0xbf:
      for c in 0x80..0xbf:
        check($char(a) & $char(b) & $char(c),
          (a != 0xe0 or b >= 0xa0) and (a != 0xed or b < 0xa0),count)
  for a in 0xf0..0xf4:
    for b in 0x80..0xbf:
      for c in 0x80..0xbf:
        for d in 0x80..0xbf:
          check($char(a) & $char(b) & $char(c) & $char(d),
            (a != 0xf0 or b >= 0x90) and (a != 0xf4 or b < 0x90),count)
  # Every byte substitution in representative scalar boundaries, including
  # truncated tails, embedded NUL, excess continuations, and illegal leads.
  for valid in ["\0", "\x7f", "\xc2\x80", "\xdf\xbf", "\xe0\xa0\x80", "\xed\x9f\xbf",
      "\xee\x80\x80", "\xef\xbf\xbf", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf"]:
    check("left" & valid & "right",true,count)
    for i in 0..<valid.len:
      for b in 0..255:
        var candidate = valid
        candidate[i] = char(b)
        check(candidate,validWasmName(candidate),count)
    for i in 1..<valid.len: check(valid[0..<i],false,count)
    check(valid & "\x80",false,count)
  echo "UTF-8 name agreement PASS: ",count," exhaustive/boundary cases"
main()
