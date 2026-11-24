## Source-prefix and hash composition, checked against complete emitted matrices.
import std/[os,osproc,strutils]

proc run(executable: string, args: openArray[string], succeeds = true): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let resultCode = execCmdEx(command)
  doAssert (resultCode.exitCode == 0) == succeeds,command & "\n" & resultCode.output
  resultCode.output

proc main() =
  if paramCount() != 4: quit("usage: test_source_hash BASELINE AUDITED CHECKER DIRECTORY",1)
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  createDir(directory)
  for mode in ["source-0","source-1","source-30","source-31","source-32","source-62",
               "source-63","source-64","empty-64","full-64","module","full"]:
    let oldMeta = directory / (mode & "-baseline.meta")
    let newMeta = directory / (mode & ".meta")
    let audit = directory / (mode & ".audit")
    discard run(baseline,[mode,oldMeta,"-"])
    discard run(audited,[mode,newMeta,audit])
    doAssert readFile(oldMeta) == readFile(newMeta),"source audit changed circuit/witness: " & mode
    stdout.write mode & ": " & run(checker,[audit])
    stdout.flushFile()
  for mode in ["empty-64","full-64"]:
    doAssert readFile(directory / (mode & ".meta")).splitLines()[1] ==
      readFile(directory / "source-64.meta").splitLines()[1],"source matrix depends on private length"
  let detached = directory / "disconnected.audit"
  discard run(audited,["disconnected",directory / "disconnected.meta",detached])
  let rejectedInterface = run(checker,[detached],false)
  doAssert "source/SHA interface rejected" in rejectedInterface,rejectedInterface
  let original = readFile(directory / "source-32.audit").splitLines()
  let header = original[0].splitWhitespace()
  let gates = parseInt(header[3])
  let sourceStart = 1+3*gates
  let source = original[sourceStart].splitWhitespace()
  let limbs = parseInt(source[6])
  let outputs = parseInt(source[7])
  let outputStart = sourceStart+2+limbs
  let rangeStart = outputStart+outputs
  let hashStart = rangeStart+34
  let hash = original[hashStart].splitWhitespace()
  doAssert hash[0] == "S"
  var rejected = 1
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".audit")
    writeFile(path,data.join("\n"))
    discard run(checker,[path],false)
    inc rejected
  let first = parseInt(source[3])
  let last = parseInt(source[4])
  for test in [("byte-bit",first),("byte-range",first+1),("prefix",first+10),
               ("inactive-zero",first+11),("count-step",first+12),
               ("packed-limb",first+13*31),("final-count",last-1),
               ("hash-gate",parseInt(hash[3]))]:
    var changed = original
    let index = 1+3*test[1]
    changed[index] = if changed[index] == "1 0:" & repeat('0',64):
        "1 0:" & repeat('0',63) & "1" else: "1 0:" & repeat('0',64)
    reject(test[0],changed)
  for test in [("source-first-wire",1),("source-last-wire",2),("source-first-gate",3),
               ("source-last-gate",4),("source-capacity",5),("source-limbs",6),("source-output-count",7)]:
    var changed = original
    var fields = source
    fields[test[1]] = $(parseInt(fields[test[1]])+1)
    changed[sourceStart] = fields.join(" ")
    reject(test[0],changed)
  for test in [("source-length",sourceStart+1),("source-limb",sourceStart+2),
               ("source-active",outputStart),("source-address",outputStart+1),
               ("source-value",outputStart+2),("range-input",rangeStart+1),
               ("range-bit",rangeStart+2),("hash-length",hashStart+1),("hash-source",hashStart+4)]:
    var changed = original
    changed[test[1]] = original[outputStart+5]
    reject(test[0],changed)
  var changed = original
  var fields = header
  fields[4] = "0"
  changed[0] = fields.join(" ")
  reject("missing-source",changed)
  changed = original
  changed[1] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-5)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "source/hash regression PASS: 12 full matrices; identical ordinary/audited fingerprints; ",rejected," forgeries rejected"

main()
