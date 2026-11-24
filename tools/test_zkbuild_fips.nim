import std/[os, osproc, strutils]
import zkbuild_fips_cases

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc values(line, kind: string, count: int): seq[uint32] =
  let parts = line.splitWhitespace()
  require(parts.len == count+1 and parts[0] == kind, "FIPS fixture row")
  for i in 1..<parts.len:
    let number = parseBiggestUInt(parts[i])
    require(number <= uint64(high(uint32)), "FIPS fixture word overflow")
    result.add uint32(number)

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_fips EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let path = work / "fips-vectors.txt"
  let generated = execCmdEx(quoteShell(exporter) & " " & quoteShell(path))
  require(generated.exitCode == 0, "FIPS oracle failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKFIPS1 512 17 13", "FIPS fixture header")
  for index in 0..<512:
    let inputs = values(reference.readLine(), "I", 24)
    var test: FipsCase
    for i in 0..<8:
      test.a[i] = inputs[i]
      test.b[i] = inputs[i+8]
      test.expected[i] = inputs[i+16]
    for row in 0..<17:
      let data = values(reference.readLine(), "T", 13)
      for i in 0..<13: test.trace[row][i] = data[i]
    require(checkFipsCase(test), "FIPS trace/result differs from Lean at case " & $index &
      "; recorded rows=" & $recordedCount)
    if index == 0:
      var changed = test
      changed.trace[0][2] = changed.trace[0][2] xor 1'u32
      require(not checkFipsCase(changed), "changed FIPS trace accepted")
      changed = test
      changed.expected[0] = changed.expected[0] xor 1'u32
      require(not checkFipsCase(changed), "changed FIPS result accepted")
  require(reference.endOfFile(), "trailing FIPS fixtures")
  echo "zkbuild FIPS schedule: PASS (512 products, 8704 complete array/accumulator rows, independent modular results and changed-fixture rejection)"

main()
