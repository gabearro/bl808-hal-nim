## Negative checks for the independent Lean matrix checker.
import std/[os, osproc, strutils]

if paramCount() notin [2, 3]: quit("usage: test_zkbuild_matrix CHECKER MATRIX [MODE]", 1)
let checker = absolutePath(paramStr(1))
let mode = if paramCount() == 3: " " & quoteShell(paramStr(3)) else: ""
let matrixPath = absolutePath(paramStr(2))
let source = readFile(matrixPath)
let records = source.splitLines()
let testDir = matrixPath.parentDir / "matrix-negative"
createDir(testDir)

proc rejected(name, data: string) =
  let path = testDir / (name & ".txt")
  writeFile(path, data)
  let checked = execCmdEx(quoteShell(checker) & mode & " " & quoteShell(path))
  if checked.exitCode == 0:
    raise newException(ValueError, "Lean accepted changed matrix: " & name)

var changed = records
changed[0] = "ZKR1CS1 6097 7 8188"
rejected("dimensions", changed.join("\n"))
changed = records
let firstColon = changed[1].find(':')
changed[1] = "1 9" & changed[1][firstColon..^1]
rejected("wire", changed.join("\n"))
changed = records
changed[1][^1] = '2'
rejected("coefficient", changed.join("\n"))
changed = records
for _ in 0..<3: changed.delete(1)
rejected("missing-gate", changed.join("\n"))
rejected("truncated", source[0..<source.len div 2])
rejected("trailing-data", source & "0\n")
echo "zkbuild matrix mutation checks: PASS (6 rejected variants)"
