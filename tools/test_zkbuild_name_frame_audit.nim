## Audit metadata is untrusted: alter framing and cross-layer links independently.
import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let completed = execCmdEx(command)
  doAssert (completed.exitCode == 0) == succeeds,command & "\n" & completed.output
  completed.output
proc main() =
  if paramCount() notin 4..5 or (paramCount() == 5 and paramStr(5) != "--reuse-fixtures"):
    quit("usage: test_name_frames BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures]",1)
  let reuse = paramCount() == 5
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  var accepted,rejected = 0
  for mode in ["module","padded","nonminimal","multi","empty","tag","alltypes","full","imports","imports-nonminimal",
      "legacy","name-empty","name-unicode","name-long","name-nonminimal"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    if not reuse:
      discard run(baseline,[mode,before,"-"])
      discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"name framing instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & (if reuse: "matching fixture fingerprints reused\n" else: run(checker,[audit]))
    stdout.flushFile()
    inc accepted
  var malformed = 0
  for mode in ["bad-name-overlong","bad-name-surrogate","bad-name-high","bad-name-truncated",
      "bad-name-continuation","bad-name-length","bad-name-uleb-overflow"]:
    for executable in [baseline,audited]:
      let rejection = run(executable,[mode,directory / "bad.meta","-"],false)
      doAssert "unknown declaration audit mode" notin rejection
      inc malformed
  proc reject(label: string, changed: seq[string]) =
    let path = directory / (label & ".audit")
    writeFile(path,changed.join("\n"))
    discard run(checker,[path],false)
    removeFile(path)
    inc rejected
    if rejected mod 16 == 0:
      echo "name framing audit: ",rejected," altered artifacts rejected"
      stdout.flushFile()
  for mode in ["module","legacy"]:
    let original = readFile(directory / (mode & ".audit")).splitLines()
    var header,row,byteRow = -1
    for i,line in original:
      if line.startsWith("N ") and line.splitWhitespace().len == 5:
        header = i
        row = -1
        byteRow = -1
      if header >= 0 and row < 0 and line.startsWith("H "): row = i
      if header >= 0 and byteRow < 0 and line.startsWith("Y "): byteRow = i
    doAssert header >= 0 and row > header and byteRow > row
    proc numberMutation(label: string,index,offset: int) =
      var changed = original
      var fields = changed[index].splitWhitespace()
      fields[offset] = $(parseInt(fields[offset])+1)
      changed[index] = fields.join(" ")
      reject(mode & "-" & label,changed)
    proc fieldMutation(label: string,index: int) =
      var changed = original
      changed[index] = "1 0:" & repeat('0',64)
      if changed[index] == original[index]: changed[index] = "1 0:01" & repeat('0',62)
      reject(mode & "-" & label,changed)
    for i in 1..4: numberMutation("header-" & $i,header,i)
    for i in 1..6: numberMutation("name-header-" & $i,row,i)
    for i in 1..5: fieldMutation("name-field-" & $i,row+i)
    for i in 1..3: numberMutation("byte-header-" & $i,byteRow,i)
    for i in 1..5: fieldMutation("byte-field-" & $i,byteRow+i)
    var trailing = original
    trailing.add "trailing"
    reject(mode & "-trailing",trailing)
    # A whole missing or duplicated byte row must not escape coverage checks.
    var missing = original[0..<byteRow] & original[byteRow+6..^1]
    var fields = missing[header].splitWhitespace()
    fields[4] = $(parseInt(fields[4])-1)
    missing[header] = fields.join(" ")
    reject(mode & "-missing-byte",missing)
    var duplicate = original[0..<byteRow] & original[byteRow..byteRow+5] & original[byteRow..^1]
    fields = duplicate[header].splitWhitespace()
    fields[4] = $(parseInt(fields[4])+1)
    duplicate[header] = fields.join(" ")
    reject(mode & "-duplicate-byte",duplicate)
  echo "name framing audit PASS: ",accepted," full matrices; ",malformed," malformed builds; ",rejected," forgeries rejected"
main()
