import ControlLookupSound
import IndexedMemberRead
set_option autoImplicit false
namespace ZkBuild.ControlMemberLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i family : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length) (kind : family=2 ∨ family=5)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (active : E values (ControlLookupCheck.control r i family).active=1)
    (head ordinal next : Fin (2^32)) (tag : Fin 8)
    (key : E values (ControlLookupCheck.control r i family).address=((ordinal.val+2^32*head.val:Nat):F))
    (payload : E values (ControlLookupCheck.control r i family).value=((tag.val+8*next.val:Nat):F)) :
    ∃ tags : List Nat,
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags ∧
      ordinal.val<tags.length ∧ tag.val<7 ∧ tags.getD ordinal.val 0=tag.val := by
  have banks := IndexedLengths.checked_banks (F:=F) matrix body tables splits declaration indexed accepted
  have qs := ControlLookupSound.query_selected matrix tables indexed r lookups values one satisfied i family ib (by omega) active
  have qm : ControlLookupCheck.query tables indexed r i family ∈ (IndexedLengths.banks tables indexed).members.queries := by
    rcases kind with rfl | rfl <;>
      simpa [ControlLookupCheck.bank,ControlLookupCheck.familyBank,BranchLookupCheck.bank,IndexedLengths.banks] using qs.1
  obtain ⟨h,o,cursor,t,tags,ki,vi,rep,inside,atIndex⟩ := IndexedMemberRead.queried matrix body tables splits declaration indexed accepted
    _ banks.membersChecked banks.memberEntries _ qm values one satisfied (qs.2.1.trans active)
  have packed := DeclarationLocations.natural_equal (F:=F) (o.val+2^32*h.val) (ordinal.val+2^32*head.val)
    (by have := o.isLt; have := h.isLt; omega) (by have := ordinal.isLt; have := head.isLt; omega)
    (ki.symm.trans (qs.2.2.1.trans key))
  have parts := DeclarationLocations.packed_unique o.val h.val ordinal.val head.val o.isLt ordinal.isLt packed
  have sameHead : h=head := Fin.ext parts.2
  have sameOrdinal : o=ordinal := Fin.ext parts.1
  subst h; subst o
  have encoded := DeclarationLocations.natural_equal (F:=F) (t.val+8*cursor.val) (tag.val+8*next.val)
    (by have := t.isLt; have := cursor.isLt; omega) (by have := tag.isLt; have := next.isLt; omega)
    (vi.symm.trans (qs.2.2.2.trans payload))
  have same : t.val=tag.val := by have := t.isLt; have := tag.isLt; omega
  exact ⟨tags,rep,inside,by have := t.isLt; omega,atIndex.trans same⟩

def family (comparison : Bool) := if comparison then 5 else 2
def headSlot (comparison : Bool) := if comparison then 49 else 41
def ordinalSlot (comparison : Bool) := if comparison then 50 else 42
def packed (row : ControlTypeRowCheck.Record) (comparison : Bool) := if comparison then row.comparison else row.payload

def Image {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (row : ControlTypeRowCheck.Record) (comparison : Bool)
    (head ordinal : Fin (2^32)) (tags : List Nat) : Prop :=
  E values (f row.after (headSlot comparison))=(head.val:F) ∧
    E values (f row.after (ordinalSlot comparison))=(ordinal.val:F) ∧
    SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags ∧
    ordinal.val<tags.length ∧ tags.getD ordinal.val 0<7 ∧
    E values (packed row comparison).low=(tags.getD ordinal.val 0:F)

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) (comparison : Bool)
    (active : E values (ControlLookupCheck.control r i (family comparison)).active=1) :
    ∃ head ordinal : Fin (2^32), ∃ tags : List Nat,
      Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) comparison head ordinal tags := by
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have ranges := ControlTypeRowImages.ranges matrix row checked values one satisfied
  have members := ControlTypeRowImages.members matrix row checked values one satisfied
  have face := ControlTypeRowImages.interface matrix row checked values
  cases comparison
  case false =>
    obtain ⟨head,hi⟩ := ranges 0 (by decide)
    obtain ⟨ordinal,oi⟩ := ranges 1 (by decide)
    obtain ⟨tag,next,ti,_,payload⟩ := members.1
    have key : E values (ControlLookupCheck.control r i 2).address=((ordinal.val+2^32*head.val:Nat):F) := by
      change E values row.member.address=_
      rw [face.memberAddress]
      simp only [eval_append,eval_scale,List.getD_cons_succ,List.getD_cons_zero] at hi oi ⊢
      simp only [E] at hi oi
      rw [hi,oi]
      simp only [Semiring.natCast_add,Semiring.natCast_mul,Int.ofNat_eq_natCast,Ring.intCast_natCast]
      grind only
    obtain ⟨tags,rep,bound,tb,tagEq⟩ := decoded matrix body tables splits declaration indexed accepted r lookups i 2 ib
      (by simp) values one satisfied active head ordinal next tag key payload
    refine ⟨head,ordinal,tags,?_,?_,rep,bound,by omega,?_⟩
    · simpa only [headSlot,Bool.false_eq_true,ite_true,ite_false,List.getD_cons_succ,List.getD_cons_zero] using hi
    · simpa only [ordinalSlot,Bool.false_eq_true,ite_true,ite_false,List.getD_cons_succ,List.getD_cons_zero] using oi
    · simpa only [packed,Bool.false_eq_true,ite_true,ite_false,tagEq] using ti
  case true =>
    obtain ⟨head,hi⟩ := ranges 2 (by decide)
    obtain ⟨ordinal,oi⟩ := ranges 3 (by decide)
    obtain ⟨tag,next,ti,_,payload⟩ := members.2
    have key : E values (ControlLookupCheck.control r i 5).address=((ordinal.val+2^32*head.val:Nat):F) := by
      change E values row.compare.address=_
      rw [face.compareAddress]
      simp only [eval_append,eval_scale,List.getD_cons_succ,List.getD_cons_zero] at hi oi ⊢
      simp only [E] at hi oi
      rw [hi,oi]
      simp only [Semiring.natCast_add,Semiring.natCast_mul,Int.ofNat_eq_natCast,Ring.intCast_natCast]
      grind only
    obtain ⟨tags,rep,bound,tb,tagEq⟩ := decoded matrix body tables splits declaration indexed accepted r lookups i 5 ib
      (by simp) values one satisfied active head ordinal next tag key payload
    refine ⟨head,ordinal,tags,?_,?_,rep,bound,by omega,?_⟩
    · simpa only [headSlot,Bool.false_eq_true,ite_true,ite_false,List.getD_cons_succ,List.getD_cons_zero] using hi
    · simpa only [ordinalSlot,Bool.false_eq_true,ite_true,ite_false,List.getD_cons_succ,List.getD_cons_zero] using oi
    · simpa only [packed,Bool.false_eq_true,ite_true,ite_false,tagEq] using ti

#print axioms decoded
#print axioms selected
end ZkBuild.ControlMemberLists
