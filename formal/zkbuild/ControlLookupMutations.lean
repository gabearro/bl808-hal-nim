import ControlLookupCheck
set_option autoImplicit false
namespace ZkBuild.ControlLookupMutations
open CircuitShape DeclarationMatrix

def run (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) : IO Nat := do
  let bad : Linear := [(matrix.wires+1,1)]
  let mut rejected := 0
  for i in List.range (StructuredMatrix.stage r 4).rows.length do
    for family in List.range 6 do
      for field in List.range 3 do
        let changeStage := fun (kind : Nat) =>
          {r with stages:=r.stages.map (fun s => if s.kind=kind then
            {s with outputs:=s.outputs.set i ((s.outputs.getD i []).set (3*family+field) bad)} else s)}
        if ControlLookupCheck.row matrix tables indexed (changeStage 4) i family then
          throw (IO.userError s!"control lookup producer mutation accepted: row={i} family={family} field={field}")
        rejected := rejected+1
        if family<4 then
          if ControlLookupCheck.row matrix tables indexed (changeStage 6) i family then
            throw (IO.userError s!"control lookup merge mutation accepted: row={i} family={family} field={field}")
          rejected := rejected+1
        let selected := ControlLookupCheck.familyBank family
        let tableIndex := if selected=0 then (StructuredMatrix.stage r 6).banks.getD 0 0 else indexed.tables.getD (selected-1) 0
        let bank := tables.getD tableIndex default
        let pos := ControlLookupCheck.position indexed i family
        let old := bank.queries.getD pos default
        let altered := if field=0 then {old with active:=bad} else if field=1 then {old with address:=bad} else {old with value:=bad}
        let changed := tables.set tableIndex {bank with queries:=bank.queries.set pos altered}
        if ControlLookupCheck.row matrix changed indexed r i family then
          throw (IO.userError s!"control lookup consumer mutation accepted: row={i} family={family} field={field}")
        rejected := rejected+1
  pure rejected
end ZkBuild.ControlLookupMutations
