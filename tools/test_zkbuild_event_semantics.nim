## Recheck retained complete source certificates with semantic matrix checks.
import std/[os, osproc, strutils, sets]

proc main() =
  doAssert paramCount() in [3,4],
    "usage: test_event_semantics CHECKER FIXTURE_DIRECTORY BINDING_DIRECTORY [RESULTS_LOG]"
  let checker = absolutePath(paramStr(1))
  doAssert fileExists(checker), "missing semantic checker"
  let fixtures = absolutePath(paramStr(2))
  let binding = absolutePath(paramStr(3))
  var seen: HashSet[string]
  var requests: seq[string]
  for i in 0..<4:
    for line in lines(fixtures / ("batch-" & $i & ".txt")):
      let fields = line.split('\t')
      if fields.len < 3: continue
      let request = fields[0..2].join("\t")
      if request notin seen:
        seen.incl request
        requests.add request
  for name in ["memory", "bulk", "reference", "lanes"]:
    let path = binding / (name & ".audit")
    doAssert fileExists(path), "missing complete fixture: " & path
    requests.add path
  doAssert requests.len == 36
  let output = parentDir(fixtures) / "event-semantics-tests"
  createDir(output)
  let manifest = output / "batch.txt"
  writeFile(manifest, requests.join("\n") & "\n")
  var resultText: string
  if paramCount() == 4:
    resultText = readFile(paramStr(4))
  else:
    let run = execCmdEx(quoteShell(checker) & " --mutations --batch " & quoteShell(manifest))
    doAssert run.exitCode == 0, run.output
    resultText = run.output
  writeFile(output / "results.log", resultText)
  var accepted, rejected, rows = 0
  for line in resultText.splitLines:
    if line.startsWith("event semantics PASS:"):
      inc accepted
      let fields = line.splitWhitespace()
      let count = parseInt(fields[3].split('=')[1])
      let mutations = parseInt(fields[4].split('=')[1])
      doAssert count > 0 and mutations == 143*count
      rows += count
      rejected += mutations
  doAssert accepted == requests.len and rejected > 0
  echo "event semantics: PASS (", accepted, " complete modules; ", rejected, " row mutations rejected; ", rows, " event rows)"

main()
