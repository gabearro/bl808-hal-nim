import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let completed = execCmdEx(command)
  doAssert (completed.exitCode == 0) == succeeds,command & "\n" & completed.output
  completed.output
proc main() =
  if paramCount() notin 4..5 or (paramCount() == 5 and paramStr(5) != "--reuse-fixtures"):
    quit("usage: test_name_source BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures]",1)
  let reuse = paramCount() == 5
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full","imports","imports-nonminimal",
      "legacy","name-empty","name-unicode","name-long","name-nonminimal"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    if not reuse:
      discard run(baseline,[mode,before,"-"])
      discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"source-name instrumentation changed circuit/witness: " & mode
    if not reuse:
      stdout.write mode & ": " & run(checker,[audit])
      stdout.flushFile()
  var malformed = 0
  for mode in ["bad-name-overlong","bad-name-surrogate","bad-name-high","bad-name-truncated","bad-name-continuation","bad-name-length","bad-name-uleb-overflow"]:
    for executable in [baseline,audited]:
      let rejected = run(executable,[mode,directory / "bad.meta","-"],false)
      doAssert "unknown declaration audit mode" notin rejected
      inc malformed
  var forgeries = 0
  proc reject(label: string, lines: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,lines.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc forgeries
    if forgeries mod 16 == 0:
      echo "source-name audit: ",forgeries," altered artifacts rejected"
      stdout.flushFile()
  for mode in ["module","legacy"]:
    let original = readFile(directory / (mode & ".audit")).splitLines()
    var start,header,row,ending = -1
    for i,line in original:
      if line.startsWith("S ") and line.splitWhitespace().len == 5:
        start = i; header = -1; row = -1; ending = -1
      if start >= 0 and header < 0 and line.startsWith("H "): header = i
      if start >= 0 and row < 0 and line.startsWith("J "): row = i
      if start >= 0 and ending < 0 and line.startsWith("E ") and line.splitWhitespace().len == 4: ending = i
    doAssert header > start and row > header
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
    proc afterRange(index: int): int =
      doAssert original[index].startsWith("U ")
      let fields = original[index+1].splitWhitespace()
      result = index+2+parseInt(fields[8])+parseInt(fields[9])
      if original[index] == "U 1":
        let source = original[result].splitWhitespace()
        result += 1+parseInt(source[8])+parseInt(source[9])
    for i in 1..4: numberMutation("dimensions-" & $i,start,i)
    for i in 1..<original[start+1].splitWhitespace().len: numberMutation("table-" & $i,start+1,i)
    for i in 1..4: numberMutation("header-" & $i,header,i)
    for i in 1..2: fieldMutation("header-field-" & $i,header+i)
    for i in 1..4: numberMutation("byte-" & $i,row,i)
    for i in 1..9: fieldMutation("byte-field-" & $i,row+i)
    numberMutation("byte-range-width",row+11,2)
    fieldMutation("byte-range-input",row+12)
    if ending >= 0:
      for i in 1..3: numberMutation("ending-" & $i,ending,i)
      for i in 1..5: fieldMutation("ending-field-" & $i,ending+i)
      numberMutation("ending-range-width",ending+7,2)
      fieldMutation("ending-range-input",ending+8)
    let next = afterRange(row+10)
    var missing = original[0..<row] & original[next..^1]
    var fields = missing[start].splitWhitespace()
    fields[2] = $(parseInt(fields[2])-1)
    missing[start] = fields.join(" ")
    reject(mode & "-missing-byte",missing)
    var duplicate = original[0..<row] & original[row..<next] & original[row..^1]
    fields = duplicate[start].splitWhitespace()
    fields[2] = $(parseInt(fields[2])+1)
    duplicate[start] = fields.join(" ")
    reject(mode & "-duplicate-byte",duplicate)
    var trailing = original; trailing.add "trailing"
    reject(mode & "-trailing",trailing)
  echo "source-name audit PASS: 15 matrices; ",malformed," malformed builds; ",forgeries," forged artifacts rejected"
main()
