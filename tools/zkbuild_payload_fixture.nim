## Shared full-payload fixture for proving and matrix-audit regressions.
proc leb(value: uint32): seq[byte] =
  var v = value
  while true:
    let low = byte(v and 127)
    v = v shr 7
    result.add low or (if v == 0: 0'u8 else: 128'u8)
    if v == 0: return

proc name(value: string): seq[byte] =
  result = leb(uint32(value.len))
  for ch in value: result.add byte(ch)

proc section(data: var seq[byte], id: byte, content: seq[byte]) =
  data.add id
  data.add leb(uint32(content.len))
  data.add content

proc header(): seq[byte] = @[0'u8,97,115,109,1,0,0,0]

proc fullPayloadFixture*(value = 42'u8): seq[byte] =
  result = header()
  result.section(0, name("\0meta") & @[255'u8,0,11])
  result.section(1, @[2'u8,96,0,0,96,0,0])
  var imports = @[6'u8]
  imports.add name("h\xc3\xb4st") & name("f") & @[0'u8,0]
  imports.add name("h") & name("t") & @[1'u8,112,1,0] & leb(high(uint32))
  imports.add name("h") & name("m") & @[2'u8,1,1] & leb(65536)
  imports.add name("h") & name("g") & @[3'u8,127,0]
  imports.add name("h") & name("e") & @[3'u8,111,0]
  imports.add name("h") & name("v") & @[3'u8,126,1]
  result.section(2, imports)
  result.section(3, @[1'u8,0])
  result.section(4, @[2'u8,111,0,0,112,1,0,5])
  result.section(13, @[1'u8,0,0])
  var globals = @[10'u8,
    127,0,65,value,11,                         # i32
    126,0,66,255,255,255,255,255,255,255,255,255,0,11, # i64 positive 2^63-1
    125,0,67,0,0,192,127,11,                  # f32 NaN bits
    124,0,68,0,0,0,0,0,0,248,127,11,         # f64 NaN bits
    123,0,253,12]                              # v128
  globals.add @[0'u8,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,11]
  globals.add @[112'u8,0,208,112,11,           # null funcref
    111,0,208,111,11,                          # null externref
    112,0,210,1,11,                            # defined function reference
    127,0,35,0,11,                             # imported immutable global
    127,0,35,3,11]                             # earlier defined immutable global
  result.section(6, globals)
  var exports = @[6'u8]
  for item in [("run",0'u8,1'u8),("t\xc3\xa9",1'u8,0'u8),("ext",1'u8,1'u8),
               ("memory",2'u8,0'u8),("g\0",3'u8,3'u8),("\xf4\x8f\xbf\xbf",3'u8,4'u8)]:
    exports.add name(item[0]) & @[item[1], item[2]]
  result.section(7, exports)
  result.section(8, @[1'u8])
  result.section(0, name("middle") & @[192'u8,0])
  var elements = @[8'u8]
  for flags in 0'u8..7'u8:
    elements.add flags
    if (flags and 1) == 0:
      if (flags and 2) != 0: elements.add(if flags == 6: 1'u8 else: 0'u8)
      elements.add @[65'u8,0,11]
    if (flags and 3) != 0: elements.add(if flags < 4: 0'u8 elif flags in [5'u8,6]: 111'u8 else: 112'u8)
    elements.add 2
    if flags < 4: elements.add @[0'u8,1]
    elif flags in [5'u8,6]: elements.add @[208'u8,111,11,35,1,11]
    else: elements.add @[210'u8,1,11,208,112,11]
  result.section(9, elements)
  result.section(12, @[3'u8])
  result.section(10, @[1'u8,3,0,1,11])
  result.section(11, @[3'u8,0,65,0,11,3,0,255,11,1,0,2,0,35,0,11,2,192,128])
  result.section(0, name("") & @[255'u8])


proc scalarPayloadFixture*(nonminimal = false): seq[byte] =
  ## Defined table, memory, global and export sections in a small shared profile.
  result = header()
  result.section(4, @[2'u8,111,0,0,112,1,1,4])
  result.section(5, @[1'u8,1,1,3])
  result.section(6, @[2'u8,127,0,65,1,11,126,1,66,2,11])
  var exports = @[4'u8,1,116,1,1,1,109,2,0,1,103,3,0,1,104,3,1]
  if nonminimal:
    exports[^1] = 129
    exports.add 0
  result.section(7, exports)

proc segmentPayloadFixture*(): seq[byte] =
  ## Every element flag and data mode, with both legacy indices and expressions.
  result = header()
  result.section(0, name("\xc2\xa2") & @[255'u8])
  result.section(1, @[1'u8,96,0,0])
  result.section(2, @[1'u8,1,104,1,102,0,0])
  result.section(4, @[1'u8,112,0,0])
  result.section(5, @[1'u8,0,1])
  var elements = @[8'u8]
  for flags in 0'u8..7'u8:
    elements.add flags
    if (flags and 1) == 0:
      if (flags and 2) != 0: elements.add 0
      elements.add @[65'u8,0,11]
    if (flags and 3) != 0: elements.add(if flags < 4: 0'u8 else: 112'u8)
    elements.add 1
    if flags < 4: elements.add 0
    else: elements.add @[210'u8,0,11]
  result.section(9, elements)
  result.section(11, @[3'u8,0,65,0,11,2,0,255,1,1,0,2,0,65,1,11,1,192])
  result.section(0, name("") & @[11'u8])

proc bodySourceFixture*(large = false, nonminimal = false): seq[byte] =
  ## Zero-count groups remain declarations; very large counts stay compressed.
  result = header()
  if large: result.section(1,@[1'u8,96,0,0])
  else: result.section(1,@[1'u8,96,7,127,126,125,124,123,112,111,0])
  result.section(3,@[1'u8,0])
  var body: seq[byte]
  if large:
    body = @[2'u8,0,126]
    body.add leb(0xffff_fffe'u32)
    body.add 127
    body.add 32
    body.add leb(0xffff_fffd'u32)
  else:
    body = if nonminimal: @[0x84'u8,0] else: @[4'u8]
    body.add(if nonminimal: @[0x80'u8,0,126] else: @[0'u8,126])
    body.add @[5'u8,127,0,111,2,123,32,13]
  body.add @[26'u8,11]
  result.section(10,@[1'u8] & leb(uint32(body.len)) & body)

proc instructionStreamFixture*(kind: string): seq[byte] =
  ## Full module fixtures for the source/control matrix certificate.
  result = header()
  var types = @[1'u8,96,0,1,127]
  var code: seq[byte]
  case kind
  of "control": code = @[0'u8,65,1,4,127,65,2,5,65,3,11,11]
  of "branch": code = @[0'u8,2,127,65,42,65,0,14,1,0,0,11,11]
  of "catch":
    types = @[2'u8,96,0,1,127,96,1,127,0]
    code = @[0'u8,2,127,31,64,1,0,0,0,65,42,8,0,11,0,11,11]
  of "catch-ref":
    types = @[3'u8,96,0,1,127,96,1,127,0,96,0,2,127,111]
    code = @[0'u8,2,2,31,64,1,1,0,0,65,42,8,0,11,0,11,26,11]
  of "catch-all-ref":
    types = @[2'u8,96,0,1,127,96,1,127,0]
    code = @[0'u8,2,111,31,64,1,3,0,65,42,8,0,11,0,11,26,65,7,11]
  of "catch-all":
    types = @[1'u8,96,0,0]
    code = @[0'u8,2,64,31,64,1,2,0,11,31,64,1,2,0,11,11,11]
  of "values":
    types = @[1'u8,96,0,0]
    code = @[0'u8,65,0xff,0xff,0xff,0xff,0x7f,26,66]
    for _ in 0..8: code.add 0xff
    code.add @[0x7f'u8,26,67,1,2,3,4,26,68,1,2,3,4,5,6,7,8,26,208,111,26,11]
  of "simd":
    types = @[1'u8,96,0,0]
    code = @[0'u8,253,12]
    for i in 0..15: code.add byte(i)
    code.add @[253'u8,21,15,26,65,1,65,2,65,0,28,1,127,26,11]
  of "bulk":
    types = @[1'u8,96,0,0]
    code = @[0'u8,65,0,65,0,65,0,252,8,0,0,65,0,40,2,0,26,11]
  else: raise newException(ValueError,"unknown instruction fixture")
  result.section(1,types)
  result.section(3,@[1'u8,0])
  if kind == "bulk": result.section(5,@[1'u8,0,1])
  if kind in ["catch","catch-ref","catch-all-ref"]: result.section(13,@[1'u8,0,1])
  if kind == "bulk": result.section(12,@[1'u8])
  result.section(10,@[1'u8] & leb(uint32(code.len)) & code)
  if kind == "bulk": result.section(11,@[1'u8,1,0])

proc dynamicTypingFixture*(kind: string): seq[byte] =
  result = header()
  var types = @[1'u8,96,0,0]
  var bodies: seq[seq[byte]]
  var functions = @[1'u8,0]
  case kind
  of "local":
    bodies = @[@[1'u8,1,126,66,1,33,0,32,0,34,0,26,11]]
  of "global":
    bodies = @[@[0'u8,66,1,36,0,35,0,26,11]]
  of "table":
    bodies = @[@[0'u8,65,0,37,0,26,65,0,208,112,38,0,
      208,112,65,1,252,15,0,26,252,16,0,26,65,0,208,112,65,1,252,17,0,11]]
  of "direct","indirect","tail-direct","tail-indirect":
    types = @[2'u8,96,0,1,127,96,1,126,1,127]
    functions = @[2'u8,0,1]
    var caller = @[0'u8,66,5]
    if kind in ["indirect","tail-indirect"]:
      caller.add @[65'u8,0,(if kind == "indirect": 17'u8 else: 19'u8),1,0]
    else: caller.add @[(if kind == "direct": 16'u8 else: 18'u8),1]
    caller.add 11
    bodies = @[caller,@[0'u8,32,0,26,65,7,11]]
  of "multi":
    types = @[2'u8,96,0,2,127,124,96,2,126,125,2,127,124]
    functions = @[2'u8,0,1]
    bodies = @[@[0'u8,66,5,67,0,0,0,0,16,1,11],
      @[0'u8,32,0,26,32,1,26,65,7,68,0,0,0,0,0,0,0,0,11]]
  else: raise newException(ValueError,"unknown dynamic typing fixture")
  result.section(1,types)
  result.section(3,functions)
  if kind in ["table","indirect","tail-indirect"]: result.section(4,@[1'u8,112,0,1])
  if kind == "global": result.section(6,@[1'u8,126,1,66,0,11])
  var code = leb(uint32(bodies.len))
  for body in bodies: code.add leb(uint32(body.len)) & body
  result.section(10,code)


proc runtimeContextFixture*(kind: string): seq[byte] =
  ## One shared profile exercises the complete context families over source bytes.
  result = header()
  result.section(1,@[1'u8,96,0,0])
  result.section(3,@[1'u8,0])
  result.section(4,@[2'u8,112,0,1,112,0,1])
  result.section(5,@[1'u8,0,1])
  # An export declares function zero for ref.func; passive funcref segment zero.
  result.section(7,@[1'u8,1,102,0,0])
  result.section(9,@[1'u8,1,0,1,0])
  result.section(12,@[1'u8])
  var code = @[0'u8]
  case kind
  of "memory":
    code.add @[63'u8,0,26,65,0,64,0,26,65,0,40,2,0,26,
      65,0,65,0,54,2,0,65,0,253,0,4,0,26,65,0,253,12]
    for i in 0..15: code.add byte(i)
    code.add @[253'u8,11,4,0]
  of "bulk":
    for operation in [8'u8,10,11,12,14]:
      code.add @[65'u8,0,65,0,65,0,252,operation]
      case operation
      of 8: code.add @[0'u8,0]
      of 10: code.add @[0'u8,0]
      of 11: code.add 0
      of 12: code.add @[0'u8,1]
      else: code.add @[1'u8,0]
    code.add @[252'u8,9,0,252,13,0]
  of "reference": code.add @[210'u8,0,26,208,112,26,208,111,209,26]
  of "lanes":
    for operation in [21'u8,24,27,29,31,33]:
      code.add @[253'u8,12]
      for i in 0..15: code.add byte(i)
      code.add @[253'u8,operation,0,26]
  else: raise newException(ValueError,"unknown runtime context fixture")
  code.add 11
  result.section(10,@[1'u8] & leb(uint32(code.len)) & code)
  result.section(11,@[1'u8,1,0])
