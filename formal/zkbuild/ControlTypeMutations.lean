import ControlTypeCertificate
set_option autoImplicit false
namespace ZkBuild.ControlTypeMutations
open CircuitShape

def entries (bad : Linear) (e : ReadOnlyMatrix.Entry) : List ReadOnlyMatrix.Entry :=
  [{e with active:=bad},{e with address:=bad},{e with value:=bad}]
def packed (bad : Linear) (r : PackedFields.Record) : List PackedFields.Record :=
  [{r with value:=bad},{r with low:=bad},{r with high:=bad},
   {r with lowWidth:=255},{r with highWidth:=255}]
def rows (matrix : Shape) (r : ControlTypeRowCheck.Record) : List ControlTypeRowCheck.Record :=
  let bad : Linear := [(matrix.wires+1,1)]
  [{r with row:=r.row.set 4 bad}] ++
  (List.range 8).map (fun i => {r with flags:=r.flags.set i bad}) ++
  [1,3,4,5,6,7,10,11,12,14,15,16,17,18,19,20].map (fun i => {r with frame:=r.frame.set i bad}) ++
  (List.range 10).map (fun i => {r with before:=r.before.set i bad}) ++
  ((List.range 63).filter (fun i => !([43,44,51,52].contains i))).map (fun i => {r with after:=r.after.set i bad}) ++
  [19,20,33,34,45].map (fun i => {r with reciprocals:=r.reciprocals.set i bad}) ++
  (entries bad r.metadata).map (fun e => {r with metadata:=e}) ++
  (entries bad r.params).map (fun e => {r with params:=e}) ++
  (entries bad r.member).map (fun e => {r with member:=e}) ++
  (entries bad r.singleton).map (fun e => {r with singleton:=e}) ++
  (entries bad r.results).map (fun e => {r with results:=e}) ++
  (entries bad r.compare).map (fun e => {r with compare:=e}) ++
  (packed bad r.heads).map (fun e => {r with heads:=e}) ++
  (packed bad r.payload).map (fun e => {r with payload:=e}) ++
  (packed bad r.comparison).map (fun e => {r with comparison:=e}) ++
  (List.range 4).map (fun i =>
    let old := r.ranges.getD i default
    {r with ranges:=r.ranges.set i {old with call:={old.call with width:=255}}}) ++
  [{r with row:=[]},{r with flags:=[]},{r with frame:=[]},{r with before:=[]},
   {r with after:=[]},{r with reciprocals:=[]},{r with ranges:=[]},
   {r with first:=matrix.gates.size+1},{r with last:=matrix.gates.size+1}]

def run (matrix : Shape) (splits : DeclarationMatrix.Splits) (events : ValidationEventMatrix.Record)
    (r : StructuredMatrix.Record) : IO Nat := do
  let s := StructuredMatrix.stage r 4
  let bad : Linear := [(matrix.wires+1,1)]
  let mut rejected := 0
  for i in List.range s.rows.length do
    let candidates := rows matrix (ControlTypeRowCheck.record splits s i)
    if candidates.length != 145 then throw (IO.userError s!"control typing mutation coverage drift: {candidates.length}")
    for j in List.range candidates.length do
      if ControlTypeRowCheck.check matrix (candidates.getD j default) then
        throw (IO.userError s!"control type row mutation accepted: row={i} change={j}")
      rejected := rejected+1
    let links := [4,8].map (fun k => {s with rows:=s.rows.set i ((s.rows.getD i []).set k bad)}) ++
      (List.range 11).map (fun k => {s with flags:=s.flags.set i ((s.flags.getD i []).set k bad)}) ++
      [3,20].map (fun k => {s with selectors:=s.selectors.set i ((s.selectors.getD i []).set k bad)})
    for changed in links do
      let altered := {r with stages:=r.stages.map (fun old => if old.kind==4 then changed else old)}
      if ControlTypeCertificate.linked events altered then
        throw (IO.userError s!"control type canonical-link mutation accepted: row={i}")
      rejected := rejected+1
  pure rejected
end ZkBuild.ControlTypeMutations
