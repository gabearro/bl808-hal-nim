import RuntimeContextCli
import OperandCertificate
import EventSemanticMutations
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape ZkBuild.GadgetShape


def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWith args fun matrix events => do
    if !OperandCertificate.check matrix events then return false
    let mut rows := 0
    let mut mutations := 0
    for stage in events.stages do
      if stage.kind == 1 then
        if !OperandRowCheck.checkStage matrix stage then return false
        rows := rows+stage.rows.length
        if testing then
          for i in [:stage.rows.length] do
            for (bad,j) in (candidates matrix (OperandRowCheck.record stage i)).zipIdx do
              if OperandRowCheck.check matrix bad then
                throw (IO.userError s!"operand mutation accepted at row {i}, mutation {j}")
              mutations := mutations+1
    IO.println s!"operand semantics PASS: rows={rows} rejected={mutations}"
    return rows == events.rows.length
