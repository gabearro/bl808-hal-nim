import ControlLookupSound
import IndexedTypeLists
set_option autoImplicit false
namespace ZkBuild.ControlLengthLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (kind : family=1 ∨ family=4)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (active : E values (ControlLookupCheck.control r i family).active=1) :
    ∃ head : Fin (2^32), ∃ tags : List Nat,
      E values (ControlLookupCheck.control r i family).address=(head.val:F) ∧
      E values (ControlLookupCheck.control r i family).value=(tags.length:F) ∧ tags.length<2^32 ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags := by
  obtain ⟨entry,member,ea,ek,ev⟩ := ControlLookupSound.origin matrix tables indexed r lookups values one satisfied i family ib (by omega) active
  have parts := (Bool.and_eq_true_iff.mp accepted).2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at parts
  have links : IndexedMatrix.checkLinks tables declaration indexed=true := by grind only
  have entries := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1).2.2.1
  have member : entry ∈ (IndexedMatrix.table tables indexed 0).entries := by
    rcases kind with rfl | rfl <;> simpa [ControlLookupCheck.bank,ControlLookupCheck.familyBank,BranchLookupCheck.bank] using member
  rw [entries] at member
  obtain ⟨source,sm,rfl⟩ := List.mem_map.mp member
  obtain ⟨head,len,tags,hb,lb,hi,li,rep,count,_⟩ := IndexedLengths.checked_lengths matrix body tables splits declaration indexed accepted values one satisfied source sm ea
  exact ⟨⟨head,hb⟩,tags,ek.symm.trans hi,by rw [count]; exact ev.symm.trans li,by omega,rep⟩

def Image {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (row : ControlTypeRowCheck.Record)
    (ph rh : Fin (2^32)) (params results : List Nat) : Prop :=
  E values (f row.after 7)=(ph.val:F) ∧ E values (f row.after 8)=(rh.val:F) ∧
    E values (f row.after 11)=(params.length:F) ∧ E values (f row.after 12)=(results.length:F) ∧
    params.length<2^32 ∧ results.length<2^32 ∧
    SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) ph.val params ∧
    SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) rh.val results

theorem reset_lists {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1) :
    ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) ph rh params results := by
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have face := ControlTypeRowImages.interface matrix row checked values
  obtain ⟨ph,params,pk,pv,pb,pr⟩ := decoded matrix body tables splits declaration indexed accepted r lookups i 1 ib (by simp) values one satisfied (face.paramsActive.trans lookup)
  obtain ⟨rh,results,rk,rv,rb,rr⟩ := decoded matrix body tables splits declaration indexed accepted r lookups i 4 ib (by simp) values one satisfied (face.resultsActive.trans lookup)
  have facts := ControlTypeRowSound.meaning matrix row checked values one satisfied
  have p := facts.multiply (ControlTypeRowCheck.lookup row) (f row.after 7) 9 (by simp [ControlTypeRowCheck.multiplies])
  have r := facts.multiply (ControlTypeRowCheck.lookup row) (f row.after 8) 10 (by simp [ControlTypeRowCheck.multiplies])
  have pl := facts.select (ControlTypeRowCheck.reset row) row.params.value (f row.before 2) 11 (by simp [ControlTypeRowCheck.selects])
  have rl := facts.select (ControlTypeRowCheck.reset row) row.results.value (f row.before 3) 12 (by simp [ControlTypeRowCheck.selects])
  change E values row.params.address=(ph.val:F) at pk
  change E values row.results.address=(rh.val:F) at rk
  change E values row.params.value=(params.length:F) at pv
  change E values row.results.value=(results.length:F) at rv
  rw [face.paramsAddress,p,lookup] at pk
  rw [face.resultsAddress,r,lookup] at rk
  simp only [reset,pv,rv] at pl rl
  exact ⟨ph,rh,params,results,by grind only,by grind only,by grind only,by grind only,pb,rb,pr,rr⟩

#print axioms decoded
#print axioms reset_lists
end ZkBuild.ControlLengthLists
