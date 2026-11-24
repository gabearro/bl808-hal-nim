import RuntimeContextCli
import ParametricSourceSound
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def candidates (matrix : Shape) (r : ParametricRowCheck.Record) : List ParametricRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [4,8].map (fun i => {r with row := r.row.set i bad}) ++
  [0,1,2,3,4,5,6,7,9].map (fun i => {r with flags := r.flags.set i bad}) ++
  (List.range 5).map (fun i => {r with before := r.before.set i bad}) ++
  ((List.range 46).filter (· != 3)).map (fun i => {r with after := r.after.set i bad}) ++
  [0,1,2,4,5,6,7,8,9,10,21,22,23,25,26,30,31,36].map (fun i => {r with reciprocals := r.reciprocals.set i bad}) ++
  [{r with primary := bad},{r with primaryRange := {r.primaryRange with call := {r.primaryRange.call with width := 255}}},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with before := []},{r with after := []},{r with reciprocals := []}]

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithCalls args fun matrix splits tables signature statics events typing => do
    if !CallCertificate.check matrix splits tables signature statics events typing then
      throw (IO.userError "call prerequisite certificate rejected")
    let stage := ValidationEventCheck.stage events 4
    if !ParametricRowCheck.checkStage matrix stage then
      for i in List.range stage.rows.length do
        let row := ParametricRowCheck.record stage i
        if !ParametricRowCheck.check matrix row then
          throw (IO.userError s!"parametric row {i} rejected: operations={stage.program.base.operations.length}, rows={stage.rows.length}")
      throw (IO.userError "parametric stage shape rejected")
    if !ParametricCertificate.check matrix statics events then throw (IO.userError "parametric cross-stage certificate rejected")
    let mut rejected := 0
    if testing then
      for i in List.range stage.rows.length do
        let row := ParametricRowCheck.record stage i
        let changes := candidates matrix row
        if changes.length != 88 then throw (IO.userError "parametric mutation coverage drift")
        for j in List.range changes.length do
          if ParametricRowCheck.check matrix (changes.getD j default) then throw (IO.userError s!"parametric mutation accepted: row={i} change={j}")
          rejected := rejected+1
        let bad : Linear := [(matrix.wires+1,1)]
        for changed in [
            {stage with rows := stage.rows.set i ((stage.rows.getD i []).set 8 bad)},
            {stage with flags := stage.flags.set i ((stage.flags.getD i []).set 2 bad)},
            {stage with inputs := stage.inputs.set i ((stage.inputs.getD i []).set 0 bad)}] do
          if ParametricCertificate.linked events changed then throw (IO.userError s!"parametric link mutation accepted: row={i}")
          rejected := rejected+1
    IO.println s!"parametric matrix PASS: rows={stage.rows.length} rejected={rejected}"
    pure true
