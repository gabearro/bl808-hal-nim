## Complete scalar section loops and hostile, source-untrusted audit metadata.
import std/[os,osproc,strutils]
proc run(executable: string, args: openArray[string], success = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == success,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() notin 4..5 or (paramCount() == 5 and paramStr(5) != "--reuse-fixtures"):
    quit("usage: test_scalar_payload BASELINE AUDITED CHECKER DIRECTORY [--reuse-fixtures]",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  let reuse = paramCount() == 5
  var accepted = 0
  for mode in ["scalar","scalar-nonminimal","module","full","full-legacy","padded","legacy","empty","imports","constant-v128"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    if not reuse:
      discard run(baseline,[mode,before,"-"])
      discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"instrumentation changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
    inc accepted
  let scalar = directory / "scalar.audit"
  let lines = readFile(scalar).splitLines()
  var start = -1
  for i,line in lines:
    if line.startsWith("P ") and line.splitWhitespace().len == 13: start = i
  doAssert start >= 0
  var original = lines[start..^1]
  while original.len > 0 and original[^1].len == 0: original.setLen(original.len-1)
  let caseDir = directory / "payload-cases"
  createDir(caseDir)
  var manifest,expected: seq[string]
  proc save(label: string, candidate: seq[string], accept = false) =
    let path = caseDir / (label & ".payload")
    writeFile(path,candidate.join("\n") & "\n")
    manifest.add path
    expected.add (if accept: "ACCEPT " else: "REJECT ") & path
  proc numberMutation(label: string,index,field: int) =
    var changed = original
    var words = changed[index].splitWhitespace()
    words[field] = $(parseInt(words[field])+1)
    changed[index] = words.join(" ")
    save(label,changed)
  proc fieldMutation(label: string,index: int) =
    var changed = original
    changed[index] = "1 0:" & repeat('0',64)
    if changed[index] == original[index]: changed[index] = "1 0:" & repeat('0',63) & "1"
    save(label,changed)
  save("unchanged",original,true)
  for i in 1..12: numberMutation("payload-header-" & $i,0,i)
  var rowStarts: seq[int]
  for i,line in original:
    if line.startsWith("L "): rowStarts.add i
  rowStarts.add original.len
  let counts = original[0].splitWhitespace()
  var firstRow = 0
  for kind in 0..3:
    let count = parseInt(counts[kind+1])
    doAssert count > 0
    let a = rowStarts[firstRow]
    let b = rowStarts[firstRow+1]
    for f in [1,2]: numberMutation("row-" & $kind & "-span-" & $f,a,f)
    if kind in [0,2]: numberMutation("row-" & $kind & "-type",a,3)
    if kind == 2: numberMutation("row-global-constant",a,4)
    if kind in [0,1]: numberMutation("row-" & $kind & "-limits",a,5)
    fieldMutation("row-" & $kind & "-active",a+1)
    if kind in [0,2]:
      for j in 2..4: fieldMutation("row-" & $kind & "-object-" & $j,a+j)
    if kind in [0,1]:
      for j in 5..16: fieldMutation("row-" & $kind & "-limit-field-" & $j,a+j)
    if kind == 3:
      for j in [5,6,8,9,10,11]: fieldMutation("export-field-" & $j,a+j)
      numberMutation("export-name-heads",a+7,1)
    for j in a+5..<b:
      let words = original[j].splitWhitespace()
      if words[0] == "R" and words.len == 2:
        numberMutation("row-" & $kind & "-token-" & $j,j,1)
        fieldMutation("row-" & $kind & "-cursor-" & $j,j+1)
      elif words[0] == "R" and words.len == 10:
        numberMutation("global-range-width-" & $j,j,2)
    var dropped = original[0..<a] & original[b..^1]
    var header = dropped[0].splitWhitespace()
    header[kind+1] = $(count-1)
    dropped[0] = header.join(" ")
    save("missing-row-" & $kind,dropped)
    var duplicated = original[0..<a] & original[a..<b] & original[a..^1]
    header[kind+1] = $(count+1)
    duplicated[0] = header.join(" ")
    save("duplicate-row-" & $kind,duplicated)
    let afterKind = rowStarts[firstRow+count]
    var omitted = original[0..<a] & original[afterKind..^1]
    header[kind+1] = "0"
    omitted[0] = header.join(" ")
    save("omitted-section-" & $kind,omitted)
    firstRow += count
  save("truncated",original[0..^2])
  save("trailing",original & @["trailing"])
  var oversized = original
  oversized[0] = "P 1048577 0 0 0 0 0 0 0 0 0 0 0"
  save("oversized",oversized)
  let manifestPath = caseDir / "manifest.txt"
  writeFile(manifestPath,manifest.join("\n") & "\n")
  let checked = run(checker,[scalar,"--payload-cases",manifestPath]).splitLines()
  var results: seq[string]
  for line in checked:
    if line.startsWith("ACCEPT ") or line.startsWith("REJECT "): results.add line
  doAssert results == expected,"unexpected payload acceptance\n" & checked.join("\n")
  echo "scalar payload audit PASS: ",accepted," matrices; ",expected.len-1," forged payloads rejected"
main()
