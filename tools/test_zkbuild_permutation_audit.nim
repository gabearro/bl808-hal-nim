## Verify every emitted switch and returned expression in real memory circuits.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let response = execCmdEx(command)
  doAssert (response.exitCode == 0) == succeeds,command & "\n" & response.output
  response.output

proc main() =
  if paramCount() != 4: quit("usage: test_permutation_audit BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  var modes: seq[string]
  for depth in 0..10: modes.add "network-" & $depth
  modes.add @["memory","module","full"]
  for mode in modes:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"permutation auditing changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let original = readFile(directory / "network-2.audit").splitLines()
  let header = original[0].splitWhitespace()
  let gates = parseInt(header[3])
  let recordStart = 1+3*gates
  let record = original[recordStart].splitWhitespace()
  let capacity = parseInt(record[6])
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for test in [("selector",0),("switch-product",1),("last-switch",gates-1)]:
    var changed = original
    changed[1+3*test[1]] = "1 0:" & repeat('0',63) & "1"
    reject(test[0],changed)
  for test in [("depth",1),("first-wire",2),("last-wire",3),("first-gate",4),("last-gate",5),("capacity",6)]:
    var changed = original
    var fields = record
    fields[test[1]] = $(parseInt(fields[test[1]])+1)
    changed[recordStart] = fields.join(" ")
    reject(test[0],changed)
  var changed = original
  swap(changed[recordStart+1],changed[recordStart+2])
  reject("input-order",changed)
  changed = original
  changed[recordStart+1+capacity] = original[recordStart+1]
  reject("output-substitution",changed)
  changed = original
  changed[recordStart+1] = "1 " & record[2] & ":" & repeat('0',63) & "1"
  reject("future-input",changed)
  changed = original
  var fields = header
  fields[4] = "0"
  changed[0] = fields.join(" ")
  reject("missing-record",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-3)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "permutation audit regression PASS: 14 full matrices; identical fingerprints; ",rejected," forgeries rejected"

main()
