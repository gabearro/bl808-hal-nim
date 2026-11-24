import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let completed = execCmdEx(command)
  doAssert (completed.exitCode == 0) == succeeds,command & "\n" & completed.output
  completed.output
proc main() =
  if paramCount() != 7: quit("usage: test_name_graph BASELINE AUDITED FRAGMENT_BASELINE FRAGMENT_AUDITED CHECKER FRAGMENT_CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let fragmentBase = absolutePath(paramStr(3))
  let fragmentAudit = absolutePath(paramStr(4))
  let checker = absolutePath(paramStr(5))
  let fragmentChecker = absolutePath(paramStr(6))
  let directory = absolutePath(paramStr(7))
  createDir(directory)
  for mode in ["empty","empty-name","ascii","unicode","shared","padded","fresh","literal"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(fragmentBase,[mode,before,"-"])
    discard run(fragmentAudit,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"name graph instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(fragmentChecker,[audit])
    stdout.flushFile()
  var malformed = 0
  for mode in ["bad-id","bad-cycle","bad-state","bad-root","bad-canonical","bad-padding"]:
    for executable in [fragmentBase,fragmentAudit]:
      discard run(executable,[mode,directory / "bad.meta","-"],false)
      inc malformed
  let original = readFile(directory / "unicode.audit").splitLines()
  var graph,node,root,lookup = -1
  for i,line in original:
    if line.startsWith("G "):
      graph = i; node = -1; root = -1; lookup = -1
    if graph >= 0 and node < 0 and line.startsWith("J "): node = i
    if node >= 0 and lookup < 0 and line.startsWith("L "): lookup = i
    if graph >= 0 and root < 0 and line.startsWith("R ") and line.splitWhitespace().len == 4: root = i
  doAssert graph >= 0 and node > graph and lookup > node and root > lookup
  var rejected = 0
  proc reject(label: string, changed: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,changed.join("\n"))
    discard run(fragmentChecker,[path],false)
    removeFile(path)
    inc rejected
  proc numberMutation(label: string,index,offset: int) =
    var changed = original
    var fields = changed[index].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[index] = fields.join(" ")
    reject(label,changed)
  proc fieldMutation(label: string,index: int) =
    var changed = original
    changed[index] = "1 0:" & repeat('0',64)
    if changed[index] == original[index]: changed[index] = "1 0:01" & repeat('0',62)
    reject(label,changed)
  for i in 1..4: numberMutation("graph-" & $i,graph,i)
  for i in 1..3: numberMutation("node-header-" & $i,node,i)
  for i in 1..16: fieldMutation("node-field-" & $i,node+i)
  for i in 1..3: numberMutation("root-header-" & $i,root,i)
  for i in 1..5: fieldMutation("root-field-" & $i,root+i)
  for i in 1..7: numberMutation("lookup-header-" & $i,lookup,i)
  for i in 1..3: fieldMutation("lookup-field-" & $i,lookup+i)
  var leaf,branch = -1
  for i in lookup+1..<root:
    let fields = original[i].splitWhitespace()
    if fields.len == 6 and fields[0] == "N":
      if fields[1] == "0" and leaf < 0: leaf = i
      elif fields[1] != "0" and branch < 0: branch = i
  doAssert leaf >= 0 and branch >= 0
  for i in 4..5: numberMutation("lookup-leaf-" & $i,leaf,i)
  for i in 1..3: numberMutation("lookup-branch-" & $i,branch,i)
  proc afterRange(index: int): int =
    doAssert original[index].startsWith("U ")
    let parts = original[index+1].splitWhitespace()
    doAssert parts.len == 10 and parts[0] == "R"
    result = index+2+parseInt(parts[8])+parseInt(parts[9])
    if original[index] == "U 1":
      let source = original[result].splitWhitespace()
      result += 1+parseInt(source[8])+parseInt(source[9])
  var rangeStart = node+17
  for i in 0..<3:
    numberMutation("node-range-width-" & $i,rangeStart+1,2)
    fieldMutation("node-range-input-" & $i,rangeStart+2)
    rangeStart = afterRange(rangeStart)
  rangeStart = root+6
  for i in 0..<2:
    numberMutation("root-range-width-" & $i,rangeStart+1,2)
    fieldMutation("root-range-input-" & $i,rangeStart+2)
    rangeStart = afterRange(rangeStart)
  var trailing = original; trailing.add "trailing"
  reject("trailing",trailing)
  echo "name graph fragment PASS: 8 matrices; ",malformed," malformed builds; ",rejected," altered audits rejected"
  stdout.flushFile()
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full","imports","imports-nonminimal",
      "legacy","name-empty","name-unicode","name-long","name-nonminimal"]:
    let before = directory / ("module-" & mode & "-baseline.meta")
    let after = directory / ("module-" & mode & ".meta")
    let audit = directory / ("module-" & mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"name graph changed module circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  echo "name graph module PASS: 15 matrices and witnesses unchanged"
main()
