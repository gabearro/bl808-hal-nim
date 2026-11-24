## Complete source-linked dynamic typing replay and hostile evidence.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let outcome = execCmdEx(command)
  doAssert outcome.exitCode == 0,command & "\n" & outcome.output
  outcome.output
proc main() =
  doAssert paramCount() == 5,"usage: test_dynamic_typing BASELINE AUDITED CHECKER DIRECTORY RETAINED"
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  let retained = absolutePath(paramStr(5))
  createDir(directory)
  let reuse = getEnv("ZKBUILD_AUDIT_REUSE") == "1"
  let casesOnly = getEnv("ZKBUILD_AUDIT_CASES_ONLY") == "1"
  var accepted,forgeries = 0
  var requests,allExpected: seq[string]
  var modes = @["module","body-legacy","body-locals","body-locals-legacy","empty","full"]
  for kind in ["control","branch","catch","catch-all","catch-ref","catch-all-ref","values","simd","bulk"]:
    modes.add "instructions-" & kind
    modes.add "instructions-" & kind & "-legacy"
  for kind in ["local","global","table","direct","indirect","tail-direct","tail-indirect","multi"]:
    modes.add "typing-" & kind
  for mode in modes:
    let before = directory / (mode & "-baseline.meta")
    let after = directory / (mode & ".meta")
    let suffix = directory / (mode & ".typing")
    var source = retained / (mode & ".audit")
    if fileExists(retained / (mode & ".meta")):
      copyFile(retained / (mode & ".meta"),before)
      if not (reuse and fileExists(after) and fileExists(suffix)):
        putEnv("ZKBUILD_TYPING_SUFFIX","1")
        discard run(audited,[mode,after,suffix])
        delEnv("ZKBUILD_TYPING_SUFFIX")
    else:
      source = directory / (mode & ".audit")
      if not (reuse and fileExists(before)): discard run(baseline,[mode,before,"-"])
      if not (reuse and fileExists(after) and fileExists(source)): discard run(audited,[mode,after,source])
      var contents: seq[string]
      for line in lines(source):
        if line.startsWith("H "): contents = @[line]
        elif contents.len > 0: contents.add line
      writeFile(suffix,contents.join("\n") & "\n")
    doAssert readFile(before) == readFile(after),"instrumentation changed matrix or assignment: " & mode
    if not casesOnly: requests.add source & "\t" & suffix
    echo mode & ": matrix and witness match"
    inc accepted
  for mode in ["module","typing-table","typing-multi"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".typing")): original.add line
    doAssert original[0] == "H 4"
    let caseDir = directory / (mode & "-cases")
    createDir(caseDir)
    var manifest,expected: seq[string]
    proc save(label: string,candidate: seq[string],accept = false) =
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
    proc header(pos: int,label: string) =
      let words = original[pos].splitWhitespace()
      for j in 1..<words.len: numberMutation(label & "-" & $pos & "-" & $j,pos,j)
    proc rows(pos: var int,label: string,change: bool) =
      let count = parseInt(original[pos].splitWhitespace()[1])
      if change: header(pos,label & "-rows")
      inc pos
      for row in 0..<count:
        let width = parseInt(original[pos].splitWhitespace()[1])
        if change and row in [0,count-1,count div 2]:
          header(pos,label & "-width")
          for j in 0..<width: fieldMutation(label & "-field-" & $(pos+j+1),pos+j+1)
        pos += 1+width
    proc primitive(pos: var int,label: string,change: bool) =
      let words = original[pos].splitWhitespace()
      if change:
        for j in 1..9:
          if not (words[1] == "9" and j == 7): numberMutation(label & "-" & $pos & "-" & $j,pos,j)
        for j in 0..<parseInt(words[8])+parseInt(words[9]): fieldMutation(label & "-arg-" & $(pos+j+1),pos+j+1)
      pos += 1+parseInt(words[8])+parseInt(words[9])
    proc operation(pos: var int,label: string,change: bool) =
      let reused = original[pos].splitWhitespace()[1] == "1"
      if change: header(pos,label & "-use")
      inc pos
      primitive(pos,label,change)
      if reused: primitive(pos,label & "-prior",change)
    header(0,"stage-count")
    var pos = 1
    for stage in 0..<4:
      header(pos,"stage-kind")
      inc pos
      for part in 0..<6: rows(pos,"stage-" & $stage & "-" & $part,true)
      header(pos,"banks")
      inc pos
      let words = original[pos].splitWhitespace()
      let operations = parseInt(words[3]); let helpers = parseInt(words[4])
      header(pos,"program")
      inc pos
      var kinds: HashSet[string]
      for _ in 0..<operations:
        let kind = original[pos+1].splitWhitespace()[1]
        operation(pos,"primitive",kind notin kinds)
        kinds.incl kind
      var helperKinds: HashSet[string]
      for _ in 0..<helpers:
        let kind = original[pos].splitWhitespace()[1]
        if kind notin helperKinds: header(pos,"helper")
        helperKinds.incl kind
        inc pos
    doAssert pos == original.len
    save("truncated",original[0..<original.len-1])
    save("trailing",original & @["unexpected"])
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    let source = if mode == "module": retained / (mode & ".audit") else: directory / (mode & ".audit")
    requests.add source & "\t" & directory / (mode & ".typing") & "\t" & caseDir / "manifest.txt"
    allExpected.add expected
    for line in expected:
      if line.startsWith("REJECT "): inc forgeries
    echo mode & ": " & $expected.len & " evidence cases queued"
  let workers = parseInt(getEnv("ZKBUILD_AUDIT_JOBS","2"))
  doAssert workers in 1..8,"ZKBUILD_AUDIT_JOBS must be between 1 and 8"
  var expanded: seq[string]
  for request in requests:
    let fields = request.split('\t')
    if fields.len == 2:
      expanded.add request
    else:
      var parts = newSeq[seq[string]](workers)
      var index = 0
      for path in lines(fields[2]):
        if path.len != 0:
          parts[index mod workers].add path
          inc index
      for worker,paths in parts:
        let chunk = fields[2] & "." & $worker
        writeFile(chunk,paths.join("\n") & "\n")
        expanded.add fields[0] & "\t" & fields[1] & "\t" & chunk
  var batches = newSeq[seq[string]](workers)
  for i,request in expanded: batches[i mod workers].add request
  var processes: seq[Process]
  var logs: seq[string]
  for worker,requests in batches:
    let batch = directory / ("batch-" & $worker & ".txt")
    let log = directory / ("batch-" & $worker & ".log")
    writeFile(batch,requests.join("\n") & "\n")
    logs.add log
    let command = quoteShell(checker) & " --batch " & quoteShell(batch) & " > " & quoteShell(log) & " 2>&1"
    processes.add startProcess(command,options = {poEvalCommand})
  var response: string
  var failures: seq[string]
  for worker,process in processes:
    let code = process.waitForExit()
    process.close()
    let output = readFile(logs[worker])
    if code != 0: failures.add "dynamic typing worker " & $worker & " failed: " & output
    response.add output
  writeFile(directory / "batch-results.log",response)
  doAssert failures.len == 0,failures.join("\n")
  for line in allExpected: doAssert line in response,line & "\n" & response
  for line in response.splitLines():
    if line.startsWith("dynamic typing PASS:"): echo line
  echo "dynamic typing audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()
