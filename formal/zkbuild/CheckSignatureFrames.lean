import RuntimeContextCli
import FrameMutations
import FrameDepthMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithStructuredIndexed args fun matrix splits tables _ _ events _ structured _ => do
    let stage := StructuredMatrix.stage structured 3
    if !FrameRowCheck.checkStage matrix structured.frames stage then
      for i in List.range stage.rows.length do
        let r := FrameRowCheck.record structured.frames stage i
        if !FrameRowCheck.check matrix r then
          let links := decide (FrameRowCheck.links r)
          let gates := OperandRowCheck.includes matrix r.first r.last (FrameRowCheck.gates r)
          for g in (FrameRowCheck.gates r).zipIdx do
            if !OperandRowCheck.includes matrix r.first r.last [g.1] then
              IO.eprintln s!"missing frame gate {g.2}: {repr g.1}"
          throw (IO.userError s!"signature frame row {i} rejected: links={links} gates={gates}, operations={stage.program.base.operations.length}, rows={stage.rows.length}")
      throw (IO.userError s!"signature frame stage rejected: operations={stage.program.base.operations.length}, rows={stage.rows.length}")
    if !FrameCertificate.check matrix events structured then
      throw (IO.userError "signature frame canonical-event certificate rejected")
    if !FrameDepthCheck.checkStage matrix splits tables structured then
      for i in List.range stage.rows.length do
        if !FrameDepthCheck.check matrix (FrameDepthCheck.record splits tables structured i) then
          throw (IO.userError s!"signature frame depth certificate rejected: row={i}")
      throw (IO.userError "signature frame depth stage rejected")
    let depthRejected ← if testing then FrameDepthMutations.run matrix splits tables structured else pure 0
    IO.println s!"signature frame depth PASS: rows={stage.rows.length} rejected={depthRejected}"
    let rejected ← if testing then FrameMutations.run matrix events structured else pure 0
    IO.println s!"signature frame matrix PASS: rows={stage.rows.length} rejected={rejected}"
    pure true
