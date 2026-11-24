import RuntimeContextCli
import CallRuntimeSource
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape

def candidates (matrix : Shape) (r : CallRowCheck.Record) : List CallRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [1,4,8].map (fun i => {r with row := r.row.set i bad}) ++
  (List.range 8).map (fun i => {r with flags := r.flags.set i bad}) ++
  (List.range 6).map (fun i => {r with before := r.before.set i bad}) ++
  ((List.range 34).filter (fun i => i != 6 && i != 7)).map (fun i => {r with after := r.after.set i bad}) ++
  (List.range 7).map (fun i => {r with reciprocals := r.reciprocals.set i bad}) ++
  [{r with primary := bad},{r with secondary := bad},
   {r with metadata := {r.metadata with active := bad}},{r with metadata := {r.metadata with address := bad}},
   {r with metadata := {r.metadata with value := bad}},
   {r with node := {r.node with active := bad}},{r with node := {r.node with address := bad}},{r with node := {r.node with value := bad}},
   {r with tableQuery := {r.tableQuery with active := bad}},{r with tableQuery := {r.tableQuery with address := bad}},
   {r with tableQuery := {r.tableQuery with value := bad}},
   {r with heads := {r.heads with low := bad}},{r with heads := {r.heads with high := bad}},{r with heads := {r.heads with value := bad}},
   {r with payload := {r.payload with low := bad}},{r with payload := {r.payload with high := bad}},{r with payload := {r.payload with value := bad}},
   {r with primaryRange := {r.primaryRange with call := {r.primaryRange.call with width := 255}}},
   {r with secondaryRange := {r.secondaryRange with call := {r.secondaryRange.call with width := 255}}},
   {r with heads := {r.heads with lowWidth := 31}},{r with heads := {r.heads with highWidth := 31}},
   {r with payload := {r.payload with lowWidth := 2}},{r with payload := {r.payload with highWidth := 31}},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with before := []},{r with after := []},{r with reciprocals := []}]

def main (args : List String) : IO Unit := do
  let testing := args.head? == some "--mutations"
  let args := if testing then args.drop 1 else args
  RuntimeContextCli.runWithCalls args fun matrix splits tables signature statics events typing => do
    if !VariableSemanticCheck.check matrix tables statics events typing then
      throw (IO.userError "variable semantic prerequisite rejected")
    let calls := DynamicTypingCheck.stage typing 3
    if !CallRowCheck.checkStage matrix splits tables signature calls then
      for i in List.range calls.rows.length do
        let row := CallRowCheck.record splits tables signature calls i
        if !CallRowCheck.check matrix row then
          let checks := [decide (CallRowCheck.links row),OperandRowCheck.includes matrix row.first row.last (CallRowCheck.gates row),
            RangeUse.check matrix row.primaryRange row.primary 32,RangeUse.check matrix row.secondaryRange row.secondary 32,
            PackedFields.check matrix row.heads,PackedFields.check matrix row.payload]
          throw (IO.userError s!"call row {i} rejected: checks={checks}")
      throw (IO.userError s!"call stage shape rejected: operations={calls.program.base.operations.length}, blocks={calls.program.blocks.length}, rows={calls.rows.length}")
    if !CallCertificate.check matrix splits tables signature statics events typing then
      throw (IO.userError "call cross-stage certificate rejected")
    let mut rejected := 0
    if testing then
      for i in List.range calls.rows.length do
        let row := CallRowCheck.record splits tables signature calls i
        let changes := candidates matrix row
        if changes.length != 86 then throw (IO.userError "call mutation coverage drift")
        for j in List.range changes.length do
          if CallRowCheck.check matrix (changes.getD j default) then throw (IO.userError s!"call mutation accepted: row={i} change={j}")
          rejected := rejected+1
        let bad : Linear := [(matrix.wires+1,1)]
        let changedRows := calls.rows.set i ((calls.rows.getD i []).set 8 bad)
        let changedFlags := calls.flags.set i ((calls.flags.getD i []).set 2 bad)
        let primary := calls.inputs.set i ((calls.inputs.getD i []).set 0 bad)
        let secondary := calls.inputs.set i ((calls.inputs.getD i []).set 1 bad)
        for changed in [{calls with rows := changedRows},{calls with flags := changedFlags},
            {calls with inputs := primary},{calls with inputs := secondary}] do
          if CallCertificate.linked events changed then throw (IO.userError s!"call link mutation accepted: row={i}")
          rejected := rejected+1
    IO.println s!"call matrix PASS: rows={calls.rows.length} rejected={rejected}"
    pure true
