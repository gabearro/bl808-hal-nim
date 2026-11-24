import FrameCertificate
set_option autoImplicit false
namespace ZkBuild.FrameMutations
open CircuitShape

def candidates (matrix : Shape) (r : FrameRowCheck.Record) : List FrameRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [1,8].map (fun i => {r with row := r.row.set i bad}) ++
  [0,1,4,5,9].map (fun i => {r with flags := r.flags.set i bad}) ++
  (List.range 3).map (fun i => {r with inputs := r.inputs.set i bad}) ++
  (List.range 4).map (fun i => {r with before := r.before.set i bad}) ++
  ((List.range 46).filter (fun i => ![9,10,18,30,37].contains i)).map (fun i => {r with after := r.after.set i bad}) ++
  (List.range 9++[12,21]++(List.range 7).map (·+22)).map (fun i => {r with reciprocals := r.reciprocals.set i bad}) ++
  (List.range 22).map (fun i => {r with outputs := r.outputs.set i bad}) ++
  [{r with read := {r.read with active := bad}}, {r with read := {r.read with write := bad}},
   {r with read := {r.read with address := bad}}, {r with read := {r.read with value := bad}},
   {r with read := {r.read with clock := bad}},
   {r with write := {r.write with active := bad}}, {r with write := {r.write with write := bad}},
   {r with write := {r.write with address := bad}}, {r with write := {r.write with value := bad}},
   {r with write := {r.write with clock := bad}}] ++
  (List.range 5).flatMap (fun i => let range := r.ranges.getD i default
    [{r with ranges := r.ranges.set i {range with call := {range.call with width := 255}}},
     {r with ranges := r.ranges.set i {range with call := {range.call with inputs := [bad]}}},
     {r with ranges := r.ranges.set i {range with call := {range.call with outputs := range.call.outputs.set 0 bad}}}]) ++
  [{r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with row := []},{r with flags := []},{r with inputs := []},{r with before := []},
   {r with after := []},{r with reciprocals := []},{r with ranges := []},{r with outputs := []}]

def run (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : IO Nat := do
  let stage := StructuredMatrix.stage r 3
  let mut rejected := 0
  for i in List.range stage.rows.length do
    let changes := candidates matrix (FrameRowCheck.record r.frames stage i)
    if changes.length != 130 then throw (IO.userError s!"frame mutation coverage drift: {changes.length}")
    for j in List.range changes.length do
      if FrameRowCheck.check matrix (changes.getD j default) then
        throw (IO.userError s!"frame row mutation accepted: row={i} change={j}")
      rejected := rejected+1
    let bad : Linear := [(matrix.wires+1,1)]
    let stages := [1,7,8].map (fun k => {stage with rows := stage.rows.set i ((stage.rows.getD i []).set k bad)}) ++
      [0,1,4,5,9].map (fun k => {stage with flags := stage.flags.set i ((stage.flags.getD i []).set k bad)})
    for changed in stages do
      let altered := {r with stages := r.stages.map (fun s => if s.kind == 3 then changed else s)}
      if FrameCertificate.linked events altered then
        throw (IO.userError s!"frame canonical link mutation accepted: row={i}")
      rejected := rejected+1
  pure rejected
end ZkBuild.FrameMutations
