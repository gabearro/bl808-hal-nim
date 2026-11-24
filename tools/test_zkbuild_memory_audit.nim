## Full RAM constraint checks, including reuse provenance and chronology.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_memory_audit BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  var modes: seq[string]
  for depth in 0..5: modes.add "fresh-" & $depth
  modes.add @["cached-3","literal-3","mixed-3","word-3","wide-3","module","full"]
  for mode in modes:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let path = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,path])
    doAssert readFile(before) == readFile(after),"RAM audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[path])
    stdout.flushFile()
  let detached = directory / "detached.audit"
  discard run(audited,["detached-3",directory / "detached.meta",detached])
  discard run(checker,[detached],false)
  let original = readFile(directory / "fresh-3.audit").splitLines()
  let header = original[0].splitWhitespace()
  let gates = parseInt(header[3])
  let memoryStart = 1+3*gates
  let memory = original[memoryStart].splitWhitespace()
  let a = parseInt(memory[1])
  let t = parseInt(memory[2])
  let n = parseInt(memory[4])
  let inputStart = memoryStart+1
  let rowStart = inputStart+7*n
  let rowSecond = rowStart+10
  let networkStart = rowStart+10*n
  doAssert original[rowStart].startsWith("S ") and original[networkStart].startsWith("P ")
  let input = original[inputStart].splitWhitespace()
  let row = original[rowStart].splitWhitespace()
  let second = original[rowSecond].splitWhitespace()
  let clockRange = original[rowStart+9].splitWhitespace()
  let network = original[networkStart].splitWhitespace()
  let edge = parseInt(second[3])+1
  let zero = edge+a+t+2
  var rejected = 1
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for test in [("active-bit",parseInt(input[1])),("write-bit",parseInt(input[1])+1),
               ("inactive-write",parseInt(input[2])-3),("inactive-address",parseInt(input[2])-2),
               ("inactive-value",parseInt(input[2])-1),("clock-range",parseInt(clockRange[4])),
               ("packed-binding",parseInt(row[3])),("first-read",parseInt(row[3])+1),
               ("sort-delta",edge),("address-zero",zero),("read-address",zero+2),("read-value",zero+3),
               ("permutation",parseInt(network[4]))]:
    var changed = original
    let index = 1+3*test[1]
    changed[index] = if changed[index] == "1 0:" & repeat('0',64):
        "1 0:" & repeat('0',63) & "1" else: "1 0:" & repeat('0',64)
    reject(test[0],changed)
  for test in [("address-width",1),("time-width",2),("value-width",3),("input-count",4),("row-count",5)]:
    var changed = original
    var fields = memory
    fields[test[1]] = $(parseInt(fields[test[1]])+1)
    changed[memoryStart] = fields.join(" ")
    reject(test[0],changed)
  for test in [("input-address",inputStart+3),("input-value",inputStart+4),
               ("sorted-active",rowStart+2),("sorted-write",rowStart+3),("sorted-address",rowStart+4),
               ("sorted-value",rowStart+5),("clock-wire",rowStart+8),
               ("network-input",networkStart+1),("network-output",networkStart+1+n)]:
    var changed = original
    changed[test[1]] = original[inputStart+1]
    reject(test[0],changed)
  var changed = original
  var fields = original[inputStart+5].splitWhitespace()
  fields[1] = "10"
  changed[inputStart+5] = fields.join(" ")
  reject("range-kind",changed)
  changed = original
  fields = original[inputStart+5].splitWhitespace()
  fields[4] = $(parseInt(fields[4])+1)
  changed[inputStart+5] = fields.join(" ")
  reject("range-origin",changed)
  changed = original
  fields = header
  fields[4] = "0"
  changed[0] = fields.join(" ")
  reject("missing-memory",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "RAM audit regression PASS: 13 full matrices; identical fingerprints; ",rejected," forgeries rejected"

main()
