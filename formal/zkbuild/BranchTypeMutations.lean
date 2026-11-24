import BranchLookupSound
set_option autoImplicit false
namespace ZkBuild.BranchTypeMutations
open CircuitShape

def rows (matrix : Shape) (r : BranchTypeRowCheck.Record) : List BranchTypeRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [4,8].map (fun i => {r with row := r.row.set i bad}) ++
  [0,1,2,3,6,7,9].map (fun i => {r with flags := r.flags.set i bad}) ++
  [1,3,4,5,6,7].map (fun i => {r with frame := r.frame.set i bad}) ++
  (List.range 10).map (fun i => {r with before := r.before.set i bad}) ++
  ((List.range 53).filter (fun i => !([41,42,45].contains i))).map (fun i => {r with after := r.after.set i bad}) ++
  [0,19,36,37,43].map (fun i => {r with reciprocals := r.reciprocals.set i bad}) ++
  [{r with terminal := bad},{r with index := r.index+1},
   {r with metadata := {r.metadata with active := bad}},{r with metadata := {r.metadata with address := bad}},
   {r with metadata := {r.metadata with value := bad}},
   {r with size := {r.size with active := bad}},{r with size := {r.size with address := bad}},
   {r with size := {r.size with value := bad}},
   {r with member := {r.member with active := bad}},{r with member := {r.member with address := bad}},
   {r with member := {r.member with value := bad}},
   {r with singleton := {r.singleton with active := bad}},{r with singleton := {r.singleton with address := bad}},
   {r with singleton := {r.singleton with value := bad}},
   {r with heads := {r.heads with value := bad}},{r with heads := {r.heads with low := bad}},
   {r with heads := {r.heads with high := bad}},{r with heads := {r.heads with lowWidth := 31}},
   {r with heads := {r.heads with highWidth := 31}},
   {r with payload := {r.payload with value := bad}},{r with payload := {r.payload with low := bad}},
   {r with payload := {r.payload with high := bad}},{r with payload := {r.payload with lowWidth := 2}},
   {r with payload := {r.payload with highWidth := 31}},
   {r with headRange := {r.headRange with call := {r.headRange.call with width := 255}}},
   {r with ordinalRange := {r.ordinalRange with call := {r.ordinalRange.call with width := 255}}},
   {r with restoreRange := {r.restoreRange with call := {r.restoreRange.call with width := 255}}},
   {r with scratch := {r.scratch with active := bad}},{r with scratch := {r.scratch with write := bad}},
   {r with scratch := {r.scratch with address := bad}},{r with scratch := {r.scratch with value := bad}},
   {r with scratch := {r.scratch with clock := bad}},
   {r with row := []},{r with flags := []},{r with frame := []},{r with before := []},
   {r with after := []},{r with reciprocals := []},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1}]

def addresses (matrix : Shape) (r : InactiveAddress.Record) : List InactiveAddress.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [{r with active := bad},{r with address := bad},{r with terms := []},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1}] ++
  (r.terms.take 1).flatMap (fun t =>
    [{r with terms := r.terms.set 0 {t with input := bad}},
     {r with terms := r.terms.set 0 {t with product := bad}},
     {r with terms := r.terms.set 0 {t with coefficient := t.coefficient+1}}])

def merges (matrix : Shape) (r : BranchMergeCheck.Record) : List BranchMergeCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [{r with control := {r.control with active := bad}},{r with control := {r.control with address := bad}},
   {r with control := {r.control with value := bad}},
   {r with branch := {r.branch with active := bad}},{r with branch := {r.branch with address := bad}},
   {r with branch := {r.branch with value := bad}},
   {r with merged := {r.merged with active := bad}},{r with merged := {r.merged with address := bad}},
   {r with merged := {r.merged with value := bad}},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1}] ++
  (addresses matrix r.controlAddress).map (fun a => {r with controlAddress := a}) ++
  (addresses matrix r.branchAddress).map (fun a => {r with branchAddress := a})

def replace (r : StructuredMatrix.Record) (s : DynamicTypingMatrix.Stage) : StructuredMatrix.Record :=
  {r with stages := r.stages.map (fun old => if old.kind == s.kind then s else old)}

def run (matrix : Shape) (splits : DeclarationMatrix.Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) (indexed : IndexedMatrix.Record) : IO Nat := do
  let typed := StructuredMatrix.stage r 5
  let merged := StructuredMatrix.stage r 6
  let bad : Linear := [(matrix.wires+1,1)]
  let mut rejected := 0
  for i in List.range typed.rows.length do
    let candidates := rows matrix (BranchTypeRowCheck.record splits r.scratch typed i)
    if candidates.length != 120 then throw (IO.userError s!"branch typing mutation coverage drift: {candidates.length}")
    for j in List.range candidates.length do
      if BranchTypeRowCheck.check matrix (candidates.getD j default) then
        throw (IO.userError s!"branch typing row mutation accepted: row={i} change={j}")
      rejected := rejected+1
    let links := [4,8].map (fun k => {typed with rows := typed.rows.set i ((typed.rows.getD i []).set k bad)}) ++
      [0,1,2,3,6,7,9].map (fun k => {typed with flags := typed.flags.set i ((typed.flags.getD i []).set k bad)}) ++
      [{typed with inputs := typed.inputs.set i ((typed.inputs.getD i []).set 0 bad)},
       {typed with selectors := typed.selectors.set i ((typed.selectors.getD i []).set 3 bad)}]
    for changed in links do
      if BranchTypeCertificate.linked events (replace r changed) then
        throw (IO.userError s!"branch typing canonical-link mutation accepted: row={i}")
      rejected := rejected+1
    for family in List.range 4 do
      let candidates := merges matrix (BranchMergeCheck.record r i family)
      if candidates.length != 27 then throw (IO.userError s!"branch merge mutation coverage drift: {candidates.length}")
      for j in List.range candidates.length do
        if BranchMergeCheck.check matrix (candidates.getD j default) then
          throw (IO.userError s!"branch merge mutation accepted: row={i} family={family} change={j}")
        rejected := rejected+1
      for k in List.range 3 do
        let changed := {merged with outputs := merged.outputs.set i ((merged.outputs.getD i []).set (3*family+k) bad)}
        if BranchLookupCheck.row tables indexed (replace r changed) i family then
          throw (IO.userError s!"branch authenticated-query mutation accepted: row={i} family={family} field={k}")
        rejected := rejected+1
  pure rejected
end ZkBuild.BranchTypeMutations
