import InstructionInfoCheck
set_option autoImplicit false
namespace ZkBuild.InstructionEventMutations
open CircuitShape DeclarationMatrix

def events (matrix : Shape) (r : InstructionEventCheck.Record) : List InstructionEventCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  (List.range 7).map (fun k => {r with row := r.row.set k bad}) ++
  [{r with begin := bad},{r with ending := bad},{r with beginInverse := bad},{r with endInverse := bad},
   {r with info := {r.info with active := bad}},{r with info := {r.info with address := bad}},{r with info := {r.info with value := bad}},
   {r with immediate := {r.immediate with active := bad}},{r with immediate := {r.immediate with address := bad}},{r with immediate := {r.immediate with value := bad}},
   {r with finish := {r.finish with active := bad}},{r with finish := {r.finish with address := bad}},{r with finish := {r.finish with value := bad}}] ++
  (List.range 6).flatMap (fun i => let range := r.ranges.getD i default
    [{r with ranges := r.ranges.set i {range with call := {range.call with width := 255}}},
     {r with ranges := r.ranges.set i {range with call := {range.call with inputs := [bad]}}},
     {r with ranges := r.ranges.set i {range with call := {range.call with outputs := range.call.outputs.set 0 bad}}}]) ++
  [{r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},{r with row := []},{r with ranges := []}]

def source (matrix : Shape) (r : InstructionInfoCheck.Record) : List InstructionInfoCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [3,4,5,6].map (fun k => {r with fields := r.fields.set k bad}) ++
  [{r with opcode := {r.opcode with call := {r.opcode.call with width := 255}}},
   {r with opcode := {r.opcode with call := {r.opcode.call with inputs := [bad]}}},
   {r with opcode := {r.opcode with call := {r.opcode.call with outputs := r.opcode.call.outputs.set 0 bad}}},
   {r with primary := {r.primary with call := {r.primary.call with width := 255}}},
   {r with primary := {r.primary with call := {r.primary.call with inputs := [bad]}}},
   {r with primary := {r.primary with call := {r.primary.call with outputs := r.primary.call.outputs.set 0 bad}}},
   {r with secondary := {r.secondary with call := {r.secondary.call with width := 255}}},
   {r with secondary := {r.secondary with call := {r.secondary.call with inputs := [bad]}}},
   {r with secondary := {r.secondary with call := {r.secondary.call with outputs := r.secondary.call.outputs.set 0 bad}}},
   {r with pad := {r.pad with call := {r.pad.call with width := 255}}},
   {r with pad := {r.pad with call := {r.pad.call with inputs := [bad]}}},
   {r with pad := {r.pad with call := {r.pad.call with outputs := r.pad.call.outputs.set 0 bad}}},
   {r with fields := []},
   {r with fields := r.fields.set 3 bad,opcode := {r.opcode with call := {r.opcode.call with inputs := [bad]}}},
   {r with fields := r.fields.set 4 bad,primary := {r.primary with call := {r.primary.call with inputs := [bad]}}},
   {r with fields := r.fields.set 5 bad,secondary := {r.secondary with call := {r.secondary.call with inputs := [bad]}}},
   {r with fields := r.fields.set 6 bad,pad := {r.pad with call := {r.pad.call with inputs := [bad]}}}]

def run (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : InstructionStreamMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record) : IO (Nat × Nat) := do
  let mut eventCount := 0
  let mut sourceCount := 0
  for i in List.range s.events.length do
    let changes := events matrix (InstructionEventCheck.record tables s i)
    if changes.length != 42 then throw (IO.userError "instruction event mutation coverage drift")
    for j in List.range changes.length do
      if InstructionEventCheck.check matrix (changes.getD j default) then
        throw (IO.userError s!"instruction event mutation accepted: row={i} change={j}")
      eventCount := eventCount+1
  for i in List.range s.rows.length do
    let changes := source matrix (InstructionInfoCheck.record catalog decoders s i)
    if changes.length != 21 then throw (IO.userError "instruction source mutation coverage drift")
    for j in List.range changes.length do
      if InstructionInfoCheck.check matrix (changes.getD j default) then
        throw (IO.userError s!"instruction source mutation accepted: row={i} change={j}")
      sourceCount := sourceCount+1
    let bad : Linear := [(matrix.wires+1,1)]
    for family in [11,12] do
      let index := s.banks.getD (if s.flat then family else if family=11 then 6 else 7) 0
      let bank := tables.getD index default
      let entry := bank.entries.getD i default
      for changed in [{entry with address := bad},{entry with value := bad}] do
        let altered := tables.set index {bank with entries := bank.entries.set i changed}
        if InstructionInfoCheck.checkStage matrix altered catalog decoders s then
          throw (IO.userError s!"instruction initializer mutation accepted: row={i} family={family}")
        sourceCount := sourceCount+1
  pure (eventCount,sourceCount)
end ZkBuild.InstructionEventMutations
