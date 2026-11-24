import SharedNodeRead
import CallNodeSource
set_option autoImplicit false
namespace ZkBuild.CallReadSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents CallState
attribute [local instance] Ring.intCast Semiring.natCast

theorem query {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (s : State) (kind : Kind) (code : Nat) (image : Image values (ready r) s)
    (masks : Masks values r s kind code) :
    (argument s kind code = true → E values r.node.active = 1 ∧ E values r.node.address = (s.params.val : F)) ∧
    (pushing kind code = true → E values r.node.active = 1 ∧ E values r.node.address = (s.results.val : F)) := by
  have links := (CallRowSound.links matrix r checked).2.2.2.2.2.2.2.2.2
  have active := VariableSelectorCheck.point values _ _ links 3
  have address := VariableSelectorCheck.point values _ _ links 4
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero,List.getD_cons_succ] at active address
  change E values r.node.active = E values (CallRowCheck.argument r ++ f r.after 20) at active
  change E values r.node.address = E values (f r.after 24 ++ f r.after 25) at address
  have eqs := CallRowEquations.meaning matrix r checked values one satisfied
  have pi : E values (f r.after 12) = (s.params.val : F) := image.1
  have ri : E values (f r.after 13) = (s.results.val : F) := image.2.1
  simp only [eval_append,masks.2.2.1,masks.2.2.2.1] at active
  simp only [eval_append,eqs.argumentAddress,eqs.resultAddress,masks.2.2.1,masks.2.2.2.1,pi,ri] at address
  constructor
  · intro enabled
    have disabled : pushing kind code = false := by
      cases kind <;> simp_all [argument,popping,pushing]
    simp [enabled,disabled,flag] at active address
    constructor <;> grind only
  · intro enabled
    have disabled : argument s kind code = false := by
      cases kind <;> simp_all [argument,popping,pushing]
    simp [enabled,disabled,flag] at active address
    constructor <;> grind only

def ListRead (table : SignatureLists.Table) (cursor : Fin (2^32)) (tag : Fin 8) (next : Fin (2^32)) : Prop :=
  ∀ items, SignatureLists.Represents table cursor.val items →
    ∃ rest, items = tag.val :: rest ∧ SignatureLists.Represents table next.val rest

def Reads (table : SignatureLists.Table) (s : State) (kind : Kind) (code : Nat) (data : CallTraceSound.Inputs) : Prop :=
  (argument s kind code = true → ListRead table s.params data.tag data.next) ∧
  (pushing kind code = true → ListRead table s.results data.tag data.next)

theorem consume {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (checked : SignatureMatrix.check matrix splits tables declaration indexed signature = true)
    (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (sourceCheck : ReadOnlyMatrix.check matrix (IndexedLengths.banks tables indexed).nodes = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (origins : CallNodeSource.Origins values signature)
    (q : ReadOnlyMatrix.Entry) (member : q ∈ signature.extraOperands) (active : E values q.active = 1)
    (cursor : Fin (2^32)) (address : E values q.address = (cursor.val : F))
    (tag : Fin 8) (next : Fin (2^32)) (payload : E values q.value = ((tag.val+8*next.val : Nat) : F)) :
    ListRead (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) cursor tag next := by
  have parts := checked
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true parts.2
  let bank := SignatureMatrix.table tables signature 1
  have bm : bank ∈ tables := by
    have im : signature.tables.getD 1 0 ∈ signature.tables := by
      rw [← List.getElem_eq_getD 0]
      exact List.getElem_mem (by rw [links.1]; decide)
    change tables.getD (signature.tables.getD 1 0) default ∈ tables
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (links.2.1 _ im)
  have qm : q ∈ bank.queries := by
    change q ∈ (SignatureMatrix.table tables signature 1).queries
    rw [links.2.2.2.2.2.1]
    exact List.mem_append_right _ member
  have shared : (IndexedLengths.banks tables indexed).nodes.entries = bank.entries :=
    links.2.2.2.2.2.2.2.1.symm
  obtain ⟨_,id,descending,ai⟩ := CallNodeSource.payload values signature q (origins q member active) tag next payload
  have same := DeclarationLocations.natural_equal (F := F) cursor.val id.val
    (by have := cursor.isLt; omega) (by have := id.isLt; omega) (address.symm.trans ai)
  have nonzero : cursor.val ≠ 0 := by omega
  exact fun items rep => SharedNodeRead.uncons matrix _ bank sourceCheck (List.all_eq_true.mp tableChecks _ bm) shared
    values one satisfied cursor.val nonzero items rep q qm active address tag next payload

#print axioms query
#print axioms consume
end ZkBuild.CallReadSound
