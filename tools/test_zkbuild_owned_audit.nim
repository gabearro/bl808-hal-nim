import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let completed = execCmdEx(command)
  doAssert (completed.exitCode == 0) == succeeds,command & "\n" & completed.output
  completed.output

proc main() =
  if paramCount() != 7: quit("usage: test_owned BASELINE AUDITED FRAGMENT_BASELINE FRAGMENT_AUDITED CHECKER FRAGMENT_CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let fragmentBaseline = absolutePath(paramStr(3))
  let fragmentAudited = absolutePath(paramStr(4))
  let checker = absolutePath(paramStr(5))
  let fragmentChecker = absolutePath(paramStr(6))
  let directory = absolutePath(paramStr(7))
  createDir(directory)
  for mode in ["empty","empty-parent","one","multi","fresh","reuse","literal","padded","wide"]:
    let stem = directory / ("fragment-" & mode)
    discard run(fragmentBaseline,[mode,stem & "-baseline.meta","-"])
    discard run(fragmentAudited,[mode,stem & ".meta",stem & ".audit"])
    doAssert readFile(stem & "-baseline.meta") == readFile(stem & ".meta"),"owned fragment instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(fragmentChecker,[stem & ".audit"])
    stdout.flushFile()
  for mode in ["bad-missing","bad-duplicate","bad-ordinal","bad-owner","bad-first","bad-gap","bad-last","bad-parent-hole","bad-child-hole","bad-empty"]:
    discard run(fragmentBaseline,[mode,directory / "bad.meta","-"],false)
    discard run(fragmentAudited,[mode,directory / "bad.meta","-"],false)
  let original = readFile(directory / "fragment-multi.audit").splitLines()
  var header,parent,child,nextChild = -1
  for i,line in original:
    if line.startsWith("O ") and line.splitWhitespace().len == 5:
      header = i
      parent = -1
      child = -1
      nextChild = -1
    if header < 0: continue
    if line.startsWith("P ") and parent < 0: parent = i
    if line.startsWith("C "):
      if child < 0: child = i
      elif nextChild < 0: nextChild = i
  doAssert header > 0 and parent > header and child > parent and nextChild > child
  proc afterRange(index: int): int =
    doAssert original[index].startsWith("U ")
    let fields = original[index+1].splitWhitespace()
    doAssert fields.len == 10 and fields[0] == "R"
    result = index+2+parseInt(fields[8])+parseInt(fields[9])
    if original[index] == "U 1":
      let source = original[result].splitWhitespace()
      result += 1+parseInt(source[8])+parseInt(source[9])
  var rejected = 0
  proc reject(label: string, changed: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,changed.join("\n"))
    discard run(fragmentChecker,[path],false)
    removeFile(path)
    inc rejected
  proc numberMutation(label: string, index, offset: int) =
    var changed = original
    var fields = changed[index].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[index] = fields.join(" ")
    reject(label,changed)
  proc fieldMutation(label: string, index: int) =
    var changed = original
    changed[index] = "1 0:" & repeat('0',64)
    if changed[index] == original[index]: changed[index] = "1 0:01" & repeat('0',62)
    reject(label,changed)
  for offset in 1..4: numberMutation("header-" & $offset,header,offset)
  for offset in 1..2: numberMutation("table-" & $offset,header+1,offset)
  for offset in 1..3: numberMutation("parent-" & $offset,parent,offset)
  for offset in 1..4: fieldMutation("parent-field-" & $offset,parent+offset)
  for offset in [1,2,3,5]: numberMutation("child-" & $offset,child,offset)
  for offset in 1..5: numberMutation("next-child-" & $offset,nextChild,offset)
  for base in [child,nextChild]:
    for offset in 1..5: fieldMutation("child-field-" & $base & "-" & $offset,base+offset)
    var cursor = base+6
    for ordinal in 0..<4:
      numberMutation("child-width-" & $base & "-" & $ordinal,cursor+1,2)
      fieldMutation("child-range-" & $base & "-" & $ordinal,cursor+2)
      cursor = afterRange(cursor)
    for offset in 0..<10:
      if base == child and offset == 7: continue # No prior-order wire in row zero.
      fieldMutation("child-result-" & $base & "-" & $offset,cursor+offset)
    cursor += 10
    numberMutation("within-width-" & $base,cursor+1,2)
    fieldMutation("within-input-" & $base,cursor+2)
    if base == nextChild:
      cursor = afterRange(cursor)
      numberMutation("order-width",cursor+1,2)
      fieldMutation("order-input",cursor+2)
  var cursor = parent+5
  for ordinal in 0..<3:
    numberMutation("parent-width-" & $ordinal,cursor+1,2)
    fieldMutation("parent-range-" & $ordinal,cursor+2)
    cursor = afterRange(cursor)
  var trailing = original
  trailing.add "trailing"
  reject("trailing",trailing)
  echo "owned fragments PASS: 9 matrices; 20 malformed builds; ",rejected," audit forgeries rejected"
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full","imports","imports-nonminimal"]:
    let stem = directory / mode
    discard run(baseline,[mode,stem & "-baseline.meta","-"])
    discard run(audited,[mode,stem & ".meta",stem & ".audit"])
    doAssert readFile(stem & "-baseline.meta") == readFile(stem & ".meta"),"owned module instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[stem & ".audit"])
    stdout.flushFile()
  echo "owned module audit PASS: 10 full matrices"
main()
