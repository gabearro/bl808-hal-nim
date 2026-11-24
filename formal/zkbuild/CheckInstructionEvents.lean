import RuntimeContextCli
import InstructionEventMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithInstructionSource args fun matrix _ tables _ _ _ _ _ _ instructions catalog decoders => do
    if !InstructionEventCheck.checkStage matrix tables instructions then
      for i in List.range instructions.events.length do
        let row := InstructionEventCheck.record tables instructions i
        if !InstructionEventCheck.check matrix row then
          for g in (InstructionEventCheck.gates row).zipIdx do
            if !OperandRowCheck.includes matrix row.first row.last [g.1] then
              IO.eprintln s!"instruction event gate missing: row={i} gate={g.2}"
          throw (IO.userError s!"instruction event row rejected: {i}, offset={InstructionEventCheck.offset instructions}, count={instructions.events.length}")
      throw (IO.userError "instruction event stage rejected")
    if !InstructionInfoCheck.checkStage matrix tables catalog decoders instructions then
      for i in List.range instructions.rows.length do
        if !InstructionInfoCheck.check matrix (InstructionInfoCheck.record catalog decoders instructions i) then
          throw (IO.userError s!"instruction source field bounds rejected: row={i}")
      throw (IO.userError "instruction source initializer links rejected")
    let (er,sr) ← if testing then InstructionEventMutations.run matrix tables instructions catalog decoders else pure (0,0)
    IO.println s!"instruction event source PASS: rows={instructions.events.length} instructions={instructions.rows.length} eventRejected={er} sourceRejected={sr} flat={instructions.flat}"
    pure true
