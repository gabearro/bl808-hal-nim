import ControlSignatureHeads
import ControlSimpleLists
import ControlLengthLists
set_option autoImplicit false
namespace ZkBuild.ControlSignatureLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Origin {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (token : Fin (2^36)) (params results : List Nat) : Prop :=
  if token.val/4%4=0 ∨ token.val/4%4=1 then
    ∃ ph rh : Fin (2^32), ∃ sourceParams : List Nat,
      CallHeadSource.Selected values body tables declaration indexed signature
        (decide (token.val/4%4=0)) (ControlSignatureHeads.index token) ph rh ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) ph.val sourceParams ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) rh.val results ∧
      params=(if token.val/4%4=0 then sourceParams else [])
  else params=[] ∧ results=ControlSimpleLists.types token.val ∧
    (token.val/4%4=2 → token.val/16=0) ∧ (token.val/4%4=3 → token.val/16<7)

theorem identify {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (table : SignatureLists.Table) (expr : Linear)
    (head other : Fin (2^32)) (tags expected : List Nat)
    (image : E values expr=(head.val:F)) (address : E values expr=(other.val:F))
    (rep : SignatureLists.Represents table head.val tags)
    (expectedRep : SignatureLists.Represents table other.val expected) : head=other ∧ tags=expected := by
  have same := DeclarationLocations.natural_equal (F:=F) head.val other.val
    (by have := head.isLt; omega) (by have := other.isLt; omega) (image.symm.trans address)
  have eq : head=other := Fin.ext same
  rw [← eq] at expectedRep
  exact ⟨eq,SignatureLists.represents_unique _ _ tags expected rep expectedRep⟩

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36))
    (image : ControlFrameMetadata.Image values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) token.val)
    (lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1) :
    ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      ControlLengthLists.Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) ph rh params results ∧
      Origin values body tables declaration indexed signature token params results := by
  have indexedChecked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1).1
  obtain ⟨ph,rh,params,results,list⟩ := ControlLengthLists.reset_lists matrix body tables splits declaration indexed indexedChecked
    r lookups i ib checked values one satisfied lookup reset
  refine ⟨ph,rh,params,results,list,?_⟩
  by_cases mode : token.val/4%4=0 ∨ token.val/4%4=1
  · obtain ⟨p,otherResult,pi,ri,selected⟩ := ControlSignatureHeads.selected matrix body splits tables declaration indexed signature space signatureChecked
      events instructions r linked lookups i ib checked values one satisfied token image lookup reset mode
    have copy := selected
    obtain ⟨_,_,_,_,_,_,_,ps,rs,_,_,_,_,_,_,_,pr,rr,_⟩ := copy
    let chosen : Fin (2^32) := if token.val/4%4=0 then p else 0
    let expected := if token.val/4%4=0 then ps else []
    have pimage : E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 7)=(chosen.val:F) := by
      by_cases h : token.val/4%4=0 <;> simpa only [chosen,h,ite_true,ite_false,Fin.val_zero] using pi
    have prep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) chosen.val expected := by
      dsimp only [chosen,expected]
      split
      · exact pr
      · exact .nil
    have pSame := identify values _ _ ph chosen params expected list.1 pimage list.2.2.2.2.2.2.1 prep
    have rSame := identify values _ _ rh otherResult results rs list.2.1 ri list.2.2.2.2.2.2.2 rr
    simp only [Origin,mode,ite_true]
    exact ⟨p,otherResult,ps,selected,pr,by rw [rSame.2]; exact rr,pSame.2⟩
  · have simple : token.val/4%4=2 ∨ token.val/4%4=3 := by omega
    obtain ⟨other,pi,ri,rep,empty,bound⟩ := ControlSimpleLists.selected matrix body tables splits declaration indexed indexedChecked
      r lookups i ib checked values one satisfied token image lookup reset simple
    have pSame := identify values _ _ ph 0 params [] list.1 (by simpa only [Fin.val_zero,Semiring.natCast_zero] using pi) list.2.2.2.2.2.2.1 .nil
    have rSame := identify values _ _ rh other results (ControlSimpleLists.types token.val) list.2.1 ri list.2.2.2.2.2.2.2 rep
    simpa only [Origin,mode,ite_false] using And.intro pSame.2 (And.intro rSame.2 (And.intro empty bound))

#print axioms identify
#print axioms selected
end ZkBuild.ControlSignatureLists
