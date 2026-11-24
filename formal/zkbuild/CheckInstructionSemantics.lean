import RuntimeContextCli
import InstructionSemanticSource
set_option autoImplicit false
open ZkBuild

def main (args : List String) : IO Unit :=
  RuntimeContextCli.runWithStatics args fun matrix statics events => do
    if !InstructionSemanticSound.check matrix statics events then
      throw (IO.userError "operand/control/instruction semantic certificate rejected")
    IO.println s!"instruction semantics PASS: rows={events.rows.length}"
    return true
