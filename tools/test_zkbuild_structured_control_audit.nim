## Complete source-linked structured control replay and hostile evidence.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let outcome = execCmdEx(command)
  doAssert outcome.exitCode == 0,command & "\n" & outcome.output
  outcome.output
proc main() =
  doAssert paramCount() == 5,"usage: test_structured_control BASELINE AUDITED CHECKER DIRECTORY RETAINED"
  let baseline = absolutePath(paramStr(1))
  let audited = absolutePath(paramStr(2))
  let checker = absolutePath(paramStr(3))
  let directory = absolutePath(paramStr(4))
  let retained = absolutePath(paramStr(5))
  createDir(directory)
  let reuse = getEnv("ZKBUILD_AUDIT_REUSE") == "1"
  let casesOnly = getEnv("ZKBUILD_AUDIT_CASES_ONLY") == "1"
  let memoryOnly = getEnv("ZKBUILD_AUDIT_MEMORY_ONLY") == "1"
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
    let suffix = directory / (mode & ".control")
    var source = retained / (mode & ".audit")
    if not fileExists(source): source = parentDir(retained) / "validation-event-tests" / (mode & ".audit")
    if fileExists(retained / (mode & ".meta")):
      copyFile(retained / (mode & ".meta"),before)
      if not (reuse and fileExists(after) and fileExists(suffix)):
        putEnv("ZKBUILD_STRUCTURED_SUFFIX","1")
        discard run(audited,[mode,after,suffix])
        delEnv("ZKBUILD_STRUCTURED_SUFFIX")
    else:
      source = directory / (mode & ".audit")
      if not (reuse and fileExists(before)): discard run(baseline,[mode,before,"-"])
      if not (reuse and fileExists(after) and fileExists(source)): discard run(audited,[mode,after,source])
      var contents: seq[string]
      for line in lines(source):
        if line.startsWith("C "): contents = @[line]
        elif contents.len > 0: contents.add line
      writeFile(suffix,contents.join("\n") & "\n")
    doAssert readFile(before) == readFile(after),"instrumentation changed matrix or assignment: " & mode
    if not casesOnly: requests.add source & "\t" & suffix
    echo mode & ": matrix and witness match"
    inc accepted
  for mode in ["module","instructions-branch","instructions-catch-ref"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".control")): original.add line
    doAssert original[0] == "C 10"
    let caseDir = directory / (mode & "-cases")
    createDir(caseDir)
    var manifest,expected: seq[string]
    proc save(label: string,candidate: seq[string],accept = false) =
      let path = caseDir / (label & ".payload")
      # Store one-line mutations as deltas; the checker reconstructs the full
      # record before parsing. Large module evidence must not be copied once
      # per hostile field (tens of gigabytes for a single fixture).
      var index = 0
      var changed = false
      for i in 0..<min(original.len,candidate.len):
        if original[i] != candidate[i]:
          doAssert not changed,"case has multiple changed lines"
          index = i
          changed = true
      if candidate.len > original.len:
        doAssert not changed and candidate.len == original.len+1
        index = original.len
      doAssert abs(candidate.len-original.len) <= 1
      writeFile(path,"ZKCONTROLPATCH1\n" & $candidate.len & "\n" & $index & "\n" & candidate[index] & "\n")
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
    if not memoryOnly: header(0,"stage-count")
    var pos = 1
    for stage in 0..<10:
      if not memoryOnly: header(pos,"stage-kind")
      inc pos
      for part in 0..<6: rows(pos,"stage-" & $stage & "-" & $part,not memoryOnly)
      if not memoryOnly: header(pos,"banks")
      inc pos
      let words = original[pos].splitWhitespace()
      let operations = parseInt(words[3]); let helpers = parseInt(words[4])
      if not memoryOnly: header(pos,"program")
      inc pos
      var kinds: HashSet[string]
      for _ in 0..<operations:
        let kind = original[pos+1].splitWhitespace()[1]
        operation(pos,"primitive",not memoryOnly and kind notin kinds)
        kinds.incl kind
      var helperKinds: HashSet[string]
      for _ in 0..<helpers:
        let kind = original[pos].splitWhitespace()[1]
        if not memoryOnly and kind notin helperKinds: header(pos,"helper")
        helperKinds.incl kind
        inc pos
    proc access(pos: var int,label: string,change: bool) =
      if change: header(pos,label)
      inc pos
      for field in 0..<4:
        if change: fieldMutation(label & "-field-" & $pos,pos)
        inc pos
      for _ in 0..<2:
        if change: header(pos,label & "-range")
        inc pos
    for memory in 0..<2:
      let name = "memory-" & $memory
      let shape = original[pos].splitWhitespace()
      let inputs = parseInt(shape[4])
      let sorted = parseInt(shape[5])
      header(pos,name)
      inc pos
      for i in 0..<inputs: access(pos,name & "-input",i in [0,inputs div 2,inputs-1])
      for i in 0..<sorted:
        let change = i in [0,sorted div 2,sorted-1]
        if change: header(pos,name & "-sorted")
        inc pos
        access(pos,name & "-sorted-access",change)
        if change: fieldMutation(name & "-clock-" & $pos,pos)
        inc pos
        if change: header(pos,name & "-clock-range")
        inc pos
      let size = parseInt(original[pos].splitWhitespace()[6])
      header(pos,name & "-permutation")
      inc pos
      for i in 0..<2*size:
        if i in [0,size div 2,size-1,size,2*size-1]:
          fieldMutation(name & "-packed-" & $pos,pos)
        inc pos
    doAssert pos == original.len,"incomplete memory mutation traversal"
    save("truncated",original[0..<original.len-1])
    save("trailing",original & @["unexpected"])
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    let source = if fileExists(retained / (mode & ".audit")): retained / (mode & ".audit")
      elif fileExists(parentDir(retained) / "validation-event-tests" / (mode & ".audit")): parentDir(retained) / "validation-event-tests" / (mode & ".audit")
      else: directory / (mode & ".audit")
    requests.add source & "\t" & directory / (mode & ".control") & "\t" & caseDir / "manifest.txt"
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
    if code != 0: failures.add "structured control worker " & $worker & " failed: " & output
    response.add output
  writeFile(directory / "batch-results.log",response)
  doAssert failures.len == 0,failures.join("\n")
  for line in allExpected: doAssert line in response,line & "\n" & response
  for line in response.splitLines():
    if line.startsWith("structured control PASS:"): echo line
  echo "structured control audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()
