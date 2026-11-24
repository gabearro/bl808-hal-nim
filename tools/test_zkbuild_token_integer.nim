## Compare the formally defined integer decoder with the actual Nim reader.
import std/[os,osproc,strutils]
import cps/zk/wasm_binary_source

type Case = object
  kind: BinaryReadKind
  data: seq[byte]
  value: uint64

var seed = 0x8a31c672d04eb95f'u64
proc randomWord(): uint64 =
  seed = seed xor (seed shl 13)
  seed = seed xor (seed shr 7)
  seed = seed xor (seed shl 17)
  seed

proc encodeSigned(value: int64): seq[byte] =
  var n = value
  while true:
    let part = byte(cast[uint64](n) and 127)
    var next = n div 128
    if n < 0 and n mod 128 != 0: dec next
    let done = (next == 0 and (part and 64) == 0) or (next == -1 and (part and 64) != 0)
    result.add(if done: part else: part or 128)
    if done: break
    n = next

proc encodeUnsigned(value: uint64): seq[byte] =
  var n = value
  while true:
    let part = byte(n and 127)
    n = n shr 7
    result.add(if n == 0: part else: part or 128)
    if n == 0: break

proc main() =
  if paramCount() != 2: quit("usage: test_token_integer LEAN_EXPORT DIRECTORY",1)
  let executable = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var cases: seq[Case]
  proc add(kind: BinaryReadKind, word: uint64, extend: bool) =
    let width = readWidth(kind)
    let masked = if width == 64: word else: word and ((1'u64 shl width)-1)
    var data: seq[byte]
    if kind in {brByte,brLittle32,brLittle64}:
      for i in 0..<readCapacity(kind): data.add byte((masked shr (8*i)) and 255)
    elif kind == brU32: data = encodeUnsigned(masked)
    else:
      let signedValue = if width == 64: cast[int64](masked)
        elif (masked and (1'u64 shl (width-1))) != 0: int64(masked)-int64(1'u64 shl width)
        else: int64(masked)
      data = encodeSigned(signedValue)
    if extend and kind in {brU32,brS32,brS33,brS64}:
      while data.len < readCapacity(kind) and (randomWord() and 1) != 0:
        let sign = kind != brU32 and (data[^1] and 64) != 0
        data[^1] = data[^1] or 128
        data.add(if sign: 127'u8 else: 0'u8)
    let offset = (cases.len*7+3) mod 17
    var wrapped = newSeq[byte](offset)
    wrapped.add data
    wrapped.add @[0x80'u8,0x80,0xff]
    let parsed = readBinaryToken(wrapped,uint32(offset),kind)
    doAssert parsed.position == uint32(offset) and int(parsed.length) == data.len and parsed.value == masked
    cases.add Case(kind: kind,data: data,value: masked)
  for kind in BinaryReadKind:
    for value in [0'u64,1,63,64,127,128,255,256,32767,32768,0x7fffffff'u64,
                  0x80000000'u64,0xffffffff'u64,0x100000000'u64,0x7fffffffffffffff'u64,
                  0x8000000000000000'u64,0xffffffffffffffff'u64]:
      add(kind,value,false)
      add(kind,value,true)
    for _ in 0..<160: add(kind,randomWord(),true)
  var text: string
  for item in cases:
    text.add $ord(item.kind) & " " & $item.data.len
    for b in item.data: text.add " " & $b
    text.add "\n"
  let path = directory / "cases.txt"
  writeFile(path,text)
  let run = execCmdEx(quoteShell(executable) & " " & quoteShell(path))
  doAssert run.exitCode == 0,run.output
  let values = run.output.strip().splitLines()
  doAssert values.len == cases.len
  var nonminimal = 0
  for i,item in cases:
    doAssert parseBiggestUInt(values[i]) == item.value,"integer mismatch at case " & $i
    if item.kind in {brU32,brS32,brS33,brS64}:
      let reduced = if item.kind == brU32: encodeUnsigned(item.value).len
        elif readWidth(item.kind) == 64: encodeSigned(cast[int64](item.value)).len
        else:
          block:
            let width = readWidth(item.kind)
            let n = if (item.value and (1'u64 shl (width-1))) != 0: int64(item.value)-int64(1'u64 shl width) else: int64(item.value)
            encodeSigned(n).len
      if item.data.len > reduced: inc nonminimal
  doAssert nonminimal > 0
  echo "token integer PASS: ",cases.len," cases; all 7 kinds; ",nonminimal," nonminimal signed/unsigned LEBs"

main()
