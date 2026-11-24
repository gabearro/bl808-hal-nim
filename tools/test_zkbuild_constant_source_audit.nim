## Shared initializer reader matrix and untrusted audit-record conformance.
import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], success = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let resultCode = execCmdEx(command)
  doAssert (resultCode.exitCode == 0) == success,command & "\n" & resultCode.output
  resultCode.output
proc main() =
  if paramCount() notin 4..5 or (paramCount() == 5 and paramStr(5) != "--reuse-fixtures"):
    quit("usage: test_constant_source BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures]",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  let reuse = paramCount() == 5
  createDir(directory)
  var accepted,forgeries = 0
  var sharedConstantMatrix: string
  for mode in ["module","full","full-legacy","padded","legacy","empty","constant-i32","constant-i64","constant-f32",
      "constant-f64","constant-v128","constant-null-func","constant-null-extern","constant-global","constant-function","constant-legacy"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    if not reuse:
      discard run(baseline,[mode,before,"-"])
      discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"constant instrumentation changed circuit/witness: " & mode
    if mode.startsWith("constant-"):
      let matrix = readFile(after).splitLines()[1]
      if sharedConstantMatrix.len == 0: sharedConstantMatrix = matrix
      doAssert matrix == sharedConstantMatrix,"constant form changed the reusable circuit shape: " & mode
    if not reuse:
      stdout.write mode & ": " & run(checker,[audit])
      stdout.flushFile()
    inc accepted
  proc reject(label: string, lines: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,lines.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc forgeries
    if forgeries mod 16 == 0:
      echo "constant source audit: ",forgeries," altered artifacts rejected"
      stdout.flushFile()
  for mode in ["constant-i32","constant-legacy"]:
    let original = readFile(directory / (mode & ".audit")).splitLines()
    var start,record = -1
    for i,line in original:
      if line.startsWith("C ") and line.splitWhitespace().len == 2:
        start = i; record = -1
      if start >= 0 and line.startsWith("K "):
        if record < 0 or mode == "constant-legacy": record = i
    doAssert start >= 0 and record > start
    proc numberMutation(label: string,index,offset: int) =
      var changed = original
      var fields = changed[index].splitWhitespace()
      fields[offset] = $(parseInt(fields[offset])+1)
      changed[index] = fields.join(" ")
      reject(mode & "-" & label,changed)
    proc fieldMutation(label: string,index: int) =
      var changed = original
      changed[index] = "1 0:" & repeat('0',64)
      if changed[index] == original[index]: changed[index] = "1 0:" & repeat('0',63) & "1"
      reject(mode & "-" & label,changed)
    numberMutation("count",start,1)
    for i in 1..11: numberMutation("header-" & $i,record,i)
    for i in 1..26: fieldMutation("field-" & $i,record+i)
    for i in 0..5:
      numberMutation("read-token-" & $i,record+27+2*i,1)
      fieldMutation("read-cursor-" & $i,record+28+2*i)
    var trailing = original
    trailing.add "trailing"
    reject(mode & "-trailing",trailing)
  echo "constant source audit PASS: ",accepted," matrices; ",forgeries," forged artifacts rejected"
main()
