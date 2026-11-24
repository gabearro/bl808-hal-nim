import std/[os, osproc, strutils]
import zkbuild_word_arithmetic_cases

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_word_arithmetic EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let path = work / "word-vectors.txt"
  let generated = execCmdEx(quoteShell(exporter) & " " & quoteShell(path))
  require(generated.exitCode == 0, "word oracle failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKWORD1 21218 24", "word fixture header")
  for index in 0..<21218:
    let values = reference.readLine().splitWhitespace()
    require(values.len == 24, "word fixture arity")
    var row: WordArithmeticCase
    for i in 0..<row.len:
      let value = parseBiggestUInt(values[i])
      require(value <= uint64(high(uint32)), "word fixture exceeds uint32")
      row[i] = uint32(value)
    require(checkWordArithmeticCase(row), "word arithmetic differs from Lean at case " & $index)
  require(reference.endOfFile(), "trailing word fixtures")
  echo "zkbuild RV32 word arithmetic: PASS (21218 cases; carry, borrow, multiply-add, accumulator wrap, 16-product columns and FIPS cancellation)"

main()
