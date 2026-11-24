import RuntimeContextCli
import InstructionBodySource
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def candidates (matrix : Shape) (r : VariableRowCheck.Record) : List VariableRowCheck.Record :=
  let foreign : Linear := [(matrix.wires+1,1)]
  [{r with row := r.row.set 4 foreign},{r with declared := foreign}] ++
  (List.range 8).map (fun i => {r with flags := r.flags.set i foreign}) ++
  (List.range 10++[13]).map (fun i => {r with selectors := r.selectors.set i foreign}) ++
  (List.range 2).map (fun i => {r with before := r.before.set i foreign}) ++
  (List.range 15).map (fun i => {r with after := r.after.set i foreign}) ++
  (List.range 4).map (fun i => {r with reciprocals := r.reciprocals.set i foreign}) ++
  [{r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with selectors := []},
   {r with before := []},{r with after := []},{r with reciprocals := []}]

def environmentCandidates (matrix : Shape) (r : EnvironmentRowCheck.Record) : List EnvironmentRowCheck.Record :=
  let foreign : Linear := [(matrix.wires+1,1)]
  [{r with row := r.row.set 1 foreign}] ++
  [0,1].map (fun i => {r with flags := r.flags.set i foreign}) ++
  [4,10,11,12].map (fun i => {r with selectors := r.selectors.set i foreign}) ++
  [1,2,3,4,5,7,9,10,11].map (fun i => {r with after := r.after.set i foreign}) ++
  [{r with immediate := foreign},{r with before := foreign},{r with reciprocal := foreign},
   {r with localQuery := {r.localQuery with active := foreign}},
   {r with localQuery := {r.localQuery with address := foreign}},
   {r with localQuery := {r.localQuery with value := foreign}},
   {r with objectQuery := {r.objectQuery with active := foreign}},
   {r with objectQuery := {r.objectQuery with address := foreign}},
   {r with objectQuery := {r.objectQuery with value := foreign}},
   {r with immediateRange := {r.immediateRange with call := {r.immediateRange.call with width := 255}}},
   {r with packedRange := {r.packedRange with call := {r.packedRange.call with width := 255}}},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with selectors := []},{r with after := []}]

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithEnvironment args fun matrix tables statics events typing => do
    if typing.stages.length != 4 then throw (IO.userError "variable semantics requires the dynamic typing certificate")
    if !InstructionSemanticSound.check matrix statics events then throw (IO.userError "instruction semantic certificate rejected")
    let stage := DynamicTypingCheck.stage typing 2
    if !VariableRowCheck.checkStage matrix stage then
      for i in [:stage.rows.length] do
        if !VariableRowCheck.check matrix (VariableRowCheck.record stage i) then
          throw (IO.userError s!"variable semantic row {i} rejected")
      throw (IO.userError "variable semantic stage rejected")
    let environment := DynamicTypingCheck.stage typing 1
    if !EnvironmentRowCheck.checkStage matrix tables environment then
      for i in [:environment.rows.length] do
        if !EnvironmentRowCheck.check matrix (EnvironmentRowCheck.record tables environment i) then
          throw (IO.userError s!"environment semantic row {i} rejected")
      throw (IO.userError "environment semantic stage rejected")
    if !VariableSemanticCheck.check matrix tables statics events typing then
      throw (IO.userError "variable semantic links rejected")
    let mut rejected := 0
    if testing then
      for i in [:stage.rows.length] do
        for (bad,j) in (candidates matrix (VariableRowCheck.record stage i)).zipIdx do
          if VariableRowCheck.check matrix bad then throw (IO.userError s!"variable mutation {j} accepted at row {i}")
          rejected := rejected+1
      for i in [:stage.rows.length] do
        let env := EnvironmentRowCheck.record tables environment i
        let row := VariableRowCheck.record stage i
        let selectors := DynamicTypingCheck.stage typing 0
        for (bad,j) in (environmentCandidates matrix env).zipIdx do
          if EnvironmentRowCheck.check matrix bad then throw (IO.userError s!"environment mutation {j} accepted at row {i}")
          rejected := rejected+1
        let foreign : Linear := [(matrix.wires+1,1)]
        let selectorCandidates := (List.range 14).map (fun j => {row with selectors := row.selectors.set j foreign}) ++
          [{row with row := row.row.set 8 foreign}]
        for (bad,j) in selectorCandidates.zipIdx do
          if VariableSelectorCheck.check selectors bad i then throw (IO.userError s!"selector link mutation {j} accepted at row {i}")
          rejected := rejected+1
        let rowCandidates := [{row with row := row.row.set 8 foreign},{row with flags := row.flags.set 0 foreign},
          {row with selectors := row.selectors.set 0 foreign},{row with declared := foreign}]
        for (bad,j) in rowCandidates.zipIdx do
          if VariableSemanticCheck.rowLinks events env bad i then throw (IO.userError s!"variable link mutation {j} accepted at row {i}")
          rejected := rejected+1
        let envCandidates := [{env with row := env.row.set 1 foreign},{env with flags := env.flags.set 0 foreign},
          {env with selectors := env.selectors.set 0 foreign},{env with after := env.after.set 11 foreign}]
        for (bad,j) in envCandidates.zipIdx do
          if VariableSemanticCheck.rowLinks events bad row i then throw (IO.userError s!"environment link mutation {j} accepted at row {i}")
          rejected := rejected+1
    IO.println s!"variable matrix PASS: rows={stage.rows.length} rejected={rejected}"
    return true
