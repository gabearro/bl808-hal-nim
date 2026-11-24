import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let checked = execCmdEx(command)
  doAssert (checked.exitCode == 0) == succeeds,command & "\n" & checked.output
  checked.output

proc main() =
  if paramCount() != 4: quit("usage: test_packed BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["fresh-heads","cached-heads","literal-heads","fresh-node","cached-node","literal-node","fresh-tiny","cached-tiny","literal-tiny"]:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,before,"-"])
    discard run(audited,[mode,after,audit])
    doAssert readFile(before) == readFile(after),"packed evidence changed circuit: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  let original = readFile(directory / "fresh-heads.audit").splitLines()
  let first = 1+3*parseInt(original[0].splitWhitespace()[3])
  doAssert original[first].startsWith("F ")
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  for offset in 1..4:
    var changed = original
    var fields = changed[first].splitWhitespace()
    fields[offset] = $(parseInt(fields[offset])+1)
    changed[first] = fields.join(" ")
    reject("header-" & $offset,changed)
  for offset in 1..3:
    var changed = original
    changed[first+offset] = "1 0:" & repeat('0',64)
    reject("field-" & $offset,changed)
  var changed = original
  swap(changed[first+2],changed[first+3])
  reject("swapped-fields",changed)
  changed = original
  let gate = parseInt(original[first].splitWhitespace()[3])
  changed[1+3*gate] = "1 0:" & repeat('0',64)
  reject("matrix",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "packed-field audit PASS: 9 matrices/45 boundary splits, ",rejected," forgeries rejected"
main()
