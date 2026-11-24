## Complete source-linked runtime context replay and hostile evidence.
import std/[os,osproc,strutils,sets]
proc run(executable: string,args: openArray[string]): string =
  var command = quoteShell(executable)
  for arg in args: command.add " " & quoteShell(arg)
  let outcome = execCmdEx(command)
  doAssert outcome.exitCode == 0,command & "\n" & outcome.output
  outcome.output
proc main() =
  doAssert paramCount() == 5,"usage: test_runtime_context BASELINE AUDITED CHECKER DIRECTORY RETAINED"
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
    let suffix = directory / (mode & ".context")
    var source = parentDir(retained) / "dynamic-typing-tests" / (mode & ".audit")
    if not fileExists(source): source = parentDir(retained) / "validation-event-tests" / (mode & ".audit")
    doAssert fileExists(source),"missing retained source certificate: " & source
    doAssert fileExists(retained / (mode & ".control")),"missing retained control certificate: " & mode
    copyFile(retained / (mode & ".meta"),before)
    if not (reuse and fileExists(after) and fileExists(suffix)):
      putEnv("ZKBUILD_CONTEXT_SUFFIX","1")
      discard run(audited,[mode,after,suffix])
      delEnv("ZKBUILD_CONTEXT_SUFFIX")
    doAssert readFile(before) == readFile(after),"instrumentation changed matrix or assignment: " & mode
    if not casesOnly: requests.add source & "\t" & retained / (mode & ".control") & "\t" & suffix
    echo mode & ": matrix and witness match"
    inc accepted
  for mode in ["module","instructions-bulk","instructions-simd"]:
    var original: seq[string]
    for line in lines(directory / (mode & ".context")): original.add line
    doAssert original[0].startsWith("K ")
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
      writeFile(path,"ZKCONTEXTPATCH1\n" & $candidate.len & "\n" & $index & "\n" & candidate[index] & "\n")
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
    header(0,"catalog-count")
    var pos = 1
    let count = parseInt(original[0].splitWhitespace()[1])
    var changedTree = false
    for index in 0..<count:
      if index in [0,count-1]: header(pos,"catalog-id")
      inc pos
      let fields = original[pos].splitWhitespace()
      let width = parseInt(fields[6])
      let nodes = parseInt(fields[7])
      let change = index in [0,count-1]
      if change: header(pos,"lookup")
      inc pos
      for field in 0..width:
        if change: fieldMutation("lookup-field-" & $pos,pos)
        inc pos
      operation(pos,"lookup-range",change)
      if not changedTree:
        for node in 0..<nodes:
          let words = original[pos+node].splitWhitespace()
          # Leaf edges and branch payloads do not affect lookup semantics.
          # Mutate only the fields consumed by the decision DAG.
          for field in (if words[1] == "0": @[1,4,5,6,7,8,9,10] else: @[1,2,3]):
            numberMutation("lookup-node-" & $(pos+node) & "-" & $field,pos+node,field)
        changedTree = true
      pos += nodes
    header(pos,"stage-count")
    inc pos
    for stage in 0..<3:
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
    header(pos,"data-binding")
    inc pos
    doAssert pos == original.len,"incomplete context mutation traversal"
    save("truncated",original[0..<original.len-1])
    save("trailing",original & @["unexpected"])
    writeFile(caseDir / "manifest.txt",manifest.join("\n") & "\n")
    var source = parentDir(retained) / "dynamic-typing-tests" / (mode & ".audit")
    if not fileExists(source): source = parentDir(retained) / "validation-event-tests" / (mode & ".audit")
    requests.add source & "\t" & retained / (mode & ".control") & "\t" & directory / (mode & ".context") & "\t" & caseDir / "manifest.txt"
    allExpected.add expected
    for line in expected:
      if line.startsWith("REJECT "): inc forgeries
    echo mode & ": " & $expected.len & " evidence cases queued"
  let workers = parseInt(getEnv("ZKBUILD_AUDIT_JOBS","2"))
  doAssert workers in 1..8,"ZKBUILD_AUDIT_JOBS must be between 1 and 8"
  var expanded: seq[string]
  for request in requests:
    let fields = request.split('\t')
    if fields.len == 3:
      expanded.add request
    else:
      var parts = newSeq[seq[string]](workers)
      var index = 0
      for path in lines(fields[3]):
        if path.len != 0:
          parts[index mod workers].add path
          inc index
      for worker,paths in parts:
        let chunk = fields[3] & "." & $worker
        writeFile(chunk,paths.join("\n") & "\n")
        expanded.add fields[0] & "\t" & fields[1] & "\t" & fields[2] & "\t" & chunk
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
    if code != 0: failures.add "runtime context worker " & $worker & " failed: " & output
    response.add output
  writeFile(directory / "batch-results.log",response)
  doAssert failures.len == 0,failures.join("\n")
  for line in allExpected: doAssert line in response,line & "\n" & response
  for line in response.splitLines():
    if line.startsWith("runtime context PASS:"): echo line
  echo "runtime context audit: " & $accepted & " fixtures; " & $forgeries & " hostile records rejected"
main()
