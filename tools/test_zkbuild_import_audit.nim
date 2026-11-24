import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let completed = execCmdEx(command)
  doAssert (completed.exitCode == 0) == succeeds,command & "\n" & completed.output
  completed.output

proc main() =
  if paramCount() != 4: quit("usage: test_imports BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full","imports","imports-nonminimal"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"import instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let ordinary = readFile(directory / "imports.meta").splitLines()
  let nonminimal = readFile(directory / "imports-nonminimal.meta").splitLines()
  doAssert ordinary[1] == nonminimal[1] and ordinary[2] != nonminimal[2],"interleaved imports must share a circuit across LEB encodings"
  let original = readFile(directory / "module.audit").splitLines()
  var header,row = -1
  for i,line in original:
    if line.startsWith("I ") and line.splitWhitespace().len == 4:
      header = i
      row = -1
    if header >= 0 and row < 0 and line.startsWith("J "): row = i
  doAssert row > header and original[header+1].startsWith("B ")
  proc afterRange(index: int): int =
    doAssert original[index].startsWith("U ")
    let fields = original[index+1].splitWhitespace()
    doAssert fields.len == 10 and fields[0] == "R"
    result = index+2+parseInt(fields[8])+parseInt(fields[9])
    if original[index] == "U 1":
      let source = original[result].splitWhitespace()
      result += 1+parseInt(source[8])+parseInt(source[9])
  let kindRange = row+4
  let objectRange = afterRange(kindRange)
  let fields = afterRange(objectRange)
  let name = fields+26
  let read = name+10
  doAssert original[name].startsWith("H ") and original[name+5].startsWith("H ") and original[read].startsWith("E ")
  var rejected = 0
  proc reject(label: string, changed: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,changed.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc rejected
    if rejected mod 16 == 0:
      echo "import audit: ",rejected," altered artifacts rejected"
      stdout.flushFile()
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
  for offset in 1..3: numberMutation("header-" & $offset,header,offset)
  for offset in 1..7: numberMutation("table-" & $offset,header+1,offset)
  for offset in 1..8: numberMutation("row-" & $offset,row,offset)
  for offset in 1..3: fieldMutation("row-field-" & $offset,row+offset)
  for offset in 0..<26: fieldMutation("data-field-" & $offset,fields+offset)
  for which in 0..1:
    let start = name+5*which
    numberMutation("name-head-" & $which,start,1)
    for offset in 1..4: fieldMutation("name-field-" & $which & "-" & $offset,start+offset)
  for which in 0..6:
    numberMutation("reader-" & $which,read+2*which,1)
    fieldMutation("reader-cursor-" & $which,read+2*which+1)
  for (label,index) in [("kind",kindRange),("object",objectRange)]:
    numberMutation(label & "-width",index+1,2)
    fieldMutation(label & "-input",index+2)
  var trailing = original
  trailing.add "trailing"
  reject("trailing",trailing)
  echo "import audit PASS: 10 full matrices; ",rejected," forgeries rejected"
main()
