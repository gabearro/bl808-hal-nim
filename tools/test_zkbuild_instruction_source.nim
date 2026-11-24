## Audit instruction-event source binding against complete Nim-emitted matrices.
import std/[os, osproc, strutils]

proc main() =
  doAssert paramCount() in [3, 4],
    "usage: test_instruction_source CHECKER RETAINED_DIRECTORY BINDING_DIRECTORY [RESULTS_LOG]"
  let checker = absolutePath(paramStr(1))
  let retained = absolutePath(paramStr(2))
  let fixtures = absolutePath(paramStr(3))
  let base = parentDir(retained)
  var requests: seq[string]
  var modes = @["module"]
  for kind in ["local", "global", "table", "direct", "indirect", "tail-direct", "tail-indirect", "multi"]:
    modes.add "typing-" & kind
  for mode in modes:
    let paths = [base / "dynamic-typing-tests" / (mode & ".audit"),
      base / "structured-control-tests" / (mode & ".control"), retained / (mode & ".context")]
    for path in paths: doAssert fileExists(path), "missing retained certificate: " & path
    requests.add paths.join("\t")
  for name in ["memory", "bulk", "reference", "lanes"]:
    let path = fixtures / (name & ".audit")
    doAssert fileExists(path), "missing complete fixture: " & path
    requests.add path
  for name in ["instructions-branch", "instructions-branch-legacy", "instructions-control", "instructions-control-legacy"]:
    let paths = [base / "validation-event-tests" / (name & ".audit"),
      base / "structured-control-tests" / (name & ".control"), retained / (name & ".context")]
    for path in paths: doAssert fileExists(path), "missing branch/control fixture: " & path
    requests.add paths.join("\t")
  let output = base / "instruction-source-tests"
  createDir(output)
  let manifest = output / "batch.txt"
  writeFile(manifest, requests.join("\n") & "\n")
  var resultText: string
  if paramCount() == 4: resultText = readFile(paramStr(4))
  else:
    let run = execCmdEx(quoteShell(checker) & " --mutations --batch " & quoteShell(manifest))
    doAssert run.exitCode == 0, run.output
    resultText = run.output
  writeFile(output / "results.log", resultText)
  var accepted, contexts, rows, instructions, eventMutations, sourceMutations: int
  var flat, legacy: int
  for line in resultText.splitLines():
    doAssert not line.contains("uncaught exception") and not line.contains("mutation accepted:"), line
    if line.startsWith("instruction event source PASS:"):
      let fields = line.splitWhitespace()
      let count = parseInt(fields[4].split('=')[1])
      let sourceCount = parseInt(fields[5].split('=')[1])
      let eventsRejected = parseInt(fields[6].split('=')[1])
      let sourcesRejected = parseInt(fields[7].split('=')[1])
      doAssert count > 0 and sourceCount > 0
      doAssert eventsRejected == 42*count and sourcesRejected == 25*sourceCount
      if fields[8] == "flat=true": inc flat
      else:
        doAssert fields[8] == "flat=false"
        inc legacy
      inc accepted
      rows += count
      instructions += sourceCount
      eventMutations += eventsRejected
      sourceMutations += sourcesRejected
    elif line.startsWith("runtime context PASS:"): inc contexts
  doAssert accepted == requests.len and contexts == accepted and flat > 0 and legacy > 0
  echo "instruction source: PASS (", accepted, " complete modules; ", rows, " event rows; ",
    instructions, " instruction rows; ", eventMutations, " event mutations; ",
    sourceMutations, " source mutations; ", eventMutations+sourceMutations, " mutations rejected)"

main()
