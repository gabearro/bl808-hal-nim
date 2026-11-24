import RuntimeContextCli
import ControlTypeMutations
import ControlSignatureSource
import ControlLookupMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def main (args : List String) : IO Unit := do
  let mutations := args.head? == some "--mutations"
  let args := if mutations then args.drop 1 else args
  RuntimeContextCli.runWithInstructionSource args fun matrix splits tables _ _ events _ structured indexed _ _ _ => do
    let s := StructuredMatrix.stage structured 4
    if !ControlTypeRowCheck.checkStage matrix splits s then
      for i in List.range s.rows.length do
        let r := ControlTypeRowCheck.record splits s i
        if !ControlTypeRowCheck.check matrix r then
          for k in List.range (ControlTypeRowCheck.gates r).length do
            if !OperandRowCheck.includes matrix r.first r.last [(ControlTypeRowCheck.gates r).getD k default] then
              throw (IO.userError s!"control type row gate rejected: row={i} gate={k}")
          throw (IO.userError s!"control type row shape rejected: row={i} links={decide (ControlTypeRowCheck.links r)} heads={PackedFields.check matrix r.heads} payload={PackedFields.check matrix r.payload} comparison={PackedFields.check matrix r.comparison}")
      throw (IO.userError s!"control type stage rejected: rows={s.rows.length} operations={s.program.base.operations.length} blocks={s.program.blocks.length}")
    if !ControlTypeCertificate.check matrix splits events structured then
      throw (IO.userError "control typing canonical certificate rejected")
    if !ControlLookupCheck.check matrix tables indexed structured then
      throw (IO.userError "control typing signature lookup certificate rejected")
    let rejected ← if mutations then ControlTypeMutations.run matrix splits events structured else pure 0
    IO.println s!"control typing certificate PASS: rows={s.rows.length} rejected={rejected}"
    let lookupRejected ← if mutations then ControlLookupMutations.run matrix tables indexed structured else pure 0
    IO.println s!"control signature certificate PASS: rows={s.rows.length} rejected={lookupRejected}"
    (← IO.getStdout).flush
    pure true
