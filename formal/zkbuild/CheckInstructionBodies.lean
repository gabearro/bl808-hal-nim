import InstructionBodyDecision
import VariableTyping
set_option autoImplicit false
open ZkBuild ZkBuild.StaticEvents

/-- Test-corpus framing. This is an offline semantic oracle, not a proof verifier. -/
def parseBody (code : Nat) : List Nat → Option (List Token)
  | [] => some []
  | kind :: opcode :: tag :: rest => do
      if opcode != code || tag >= 8 then none else do
        let token ← match kind with
          | 2 => some (Token.push tag)
          | 3 => some (Token.pop tag)
          | 6 => some Token.clear
          | _ => none
        let suffix ← parseBody code rest
        some (token :: suffix)
  | _ => none

def checkBody (fields : List Nat) : Bool := Id.run do
  let family := fields.getD 0 2
  let code := fields.getD 1 0
  let declared := fields.getD 2 7
  let count := fields.getD 3 0
  if count < 2 || count > 64 || fields.length != 4+3*count then return false
  let rows := fields.drop 4
  if rows.getD 0 0 != 1 || rows.getD 1 0 != code || rows.getD 2 8 >= 8 then return false
  let last := 3*(count-1)
  if rows.getD last 0 != 7 || rows.getD (last+1) 0 != code || rows.getD (last+2) 8 >= 8 then return false
  let some tokens := parseBody code ((rows.drop 3).take (3*(count-2))) | return false
  if family == 0 then
    let some rule := StaticTyping.signature code | return false
    return InstructionBodyDecision.fixed rule 0 0 0 tokens
  if family == 1 then
    let some rule := VariableTyping.signature code declared | return false
    return InstructionBodyDecision.dependent rule 0 0 tokens
  return false

def main (args : List String) : IO UInt32 := do
  let [path] := args | throw (IO.userError "usage: check_instruction_bodies CORPUS")
  let input ← IO.FS.Handle.mk path .read
  if (← input.getLine).trimAscii.toString != "ZKINSTRUCTIONBODIES1" then
    throw (IO.userError "instruction body corpus header")
  let mut accepted := 0
  let mut rejected := 0
  let mut lineNumber := 1
  while true do
    let raw ← input.getLine
    if raw.isEmpty then break
    lineNumber := lineNumber+1
    if lineNumber > 100001 then throw (IO.userError "instruction body corpus limit")
    let line := raw.trimAscii.toString
    let some numbers := ((line.splitOn " ").filter (· != "")).mapM String.toNat?
      | throw (IO.userError s!"invalid integer at line {lineNumber}")
    let expected := numbers.headD 2
    if expected > 1 then throw (IO.userError s!"invalid expectation at line {lineNumber}")
    let actual := checkBody (numbers.drop 1)
    if actual != (expected == 1) then throw (IO.userError s!"body mismatch at line {lineNumber}: expected {expected}")
    if actual then accepted := accepted+1 else rejected := rejected+1
  if accepted == 0 || rejected == 0 then throw (IO.userError "corpus lacks positive/negative controls")
  IO.println s!"instruction bodies PASS: accepted={accepted} rejected={rejected}"
  return 0
