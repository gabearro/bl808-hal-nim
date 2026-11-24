import ScalarPayloadCounts
import ImportRead
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ScalarPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def layouts (splits : Splits) (kind : Nat) (r : Row) (start : Linear) : List (Nat × Linear × Linear × Linear) :=
  let maximum := (limitAt r 1).value ++ (limitAt r 3).value
  let low := (split splits r.limitHeads).low
  let high := (split splits r.limitHeads).high
  match kind with
  | 0 => [(0,r.active,typeByte kind r,start),(0,r.active,maximum,(readAt r 0).cursor),
      (1,r.active,low,(readAt r 1).cursor),(1,maximum,high,(readAt r 2).cursor)]
  | 1 => [(0,r.active,maximum,start),(1,r.active,low,(readAt r 0).cursor),
      (1,maximum,high,(readAt r 1).cursor)]
  | 2 => [(0,r.active,typeByte kind r,start),(0,r.active,(RangeUse.bits r.objectRange).getD 3 z,(readAt r 0).cursor)]
  | _ => [(0,r.active,get r.fields 0,r.name.cursor),(1,r.active,get r.fields 1,(readAt r 0).cursor)]
def layout (splits : Splits) (kind : Nat) (r : Row) (start : Linear) (i : Nat) := (layouts splits kind r start).getD i default
def length (kind : Nat) := if kind = 0 then 4 else if kind = 1 then 3 else 2

theorem read_shape (tokens : Tokens) (splits : Splits) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kb : kind < 4) (r : Row) (start : Linear)
    (sh : shape tokens splits constants kind r start) (i : Nat) (ib : i < length kind) :
    ImportMatrix.readMatches tokens (readAt r i) (layout splits kind r start i).1
      (layout splits kind r start i).2.1 (layout splits kind r start i).2.2.2 := by
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 := by omega
  rcases cases with rfl | rfl | rfl | rfl
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [length] at ib; omega
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp [shape,limitShape] at sh <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] <;> grind only
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [length] at ib; omega
    rcases cases with rfl | rfl | rfl <;>
      simp [shape,limitShape] at sh <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] <;> grind only
  · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
    rcases cases with rfl | rfl <;>
      simp [shape] at sh <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] <;> grind only
  · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
    rcases cases with rfl | rfl <;>
      simp [shape] at sh <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] <;> grind only

theorem read_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record) (kind : Nat) (kb : kind < 4)
    (r : Row) (index : Nat) (start previous : Linear)
    (all : AllHold values (rowGates tokens splits imports constants kind r index start previous))
    (i : Nat) (ib : i < length kind) :
    AllHold values (ImportMatrix.readGates tokens (readAt r i) (layout splits kind r start i).2.1
      (layout splits kind r start i).2.2.1 (layout splits kind r start i).2.2.2) := by
  intro g gm
  apply all g
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 := by omega
  rcases cases with rfl | rfl | rfl | rfl
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [length] at ib; omega
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [rowGates,limitGates]
      <;> simp only [List.mem_append]
      <;> grind only
  · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [length] at ib; omega
    rcases cases with rfl | rfl | rfl <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [rowGates,limitGates]
      <;> simp only [List.mem_append]
      <;> grind only
  · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
    rcases cases with rfl | rfl <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [rowGates]
      <;> simp only [List.mem_append]
      <;> grind only
  · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
    rcases cases with rfl | rfl <;>
      simp only [layout,layouts,List.getD_cons_zero,List.getD_cons_succ] at gm <;>
      simp only [rowGates]
      <;> simp only [List.mem_append]
      <;> grind only

def Step {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits)
    (kind : Nat) (r : Row) (start : Linear) (message : List Sha256.Byte) (i p len : Nat) : Prop :=
  BinaryTokenSound.Result values (EnvelopeMatrix.token tokens (readAt r i).token) message p len ∧
    E values (layout splits kind r start i).2.2.2 = (p : F) ∧
    E values (readAt r i).cursor = ((p+len : Nat) : F) ∧
    E values (layout splits kind r start i).2.1 * E values (layout splits kind r start i).2.2.1 =
      E values (EnvelopeMatrix.token tokens (readAt r i).token).value

theorem step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (kb : kind < 4) (r : Row)
    (index : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants kind r index start previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p len, BinaryTokenSound.Result values t message p len)
    (i : Nat) (ib : i < length kind) : ∃ p len, Step values tokens splits kind r start message i p len := by
  have sh := read_shape tokens splits constants kind kb r start
    (ScalarPayloadRules.metadata matrix tokens splits imports constants kind r index start previous checked) i ib
  let t := EnvelopeMatrix.token tokens (readAt r i).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  obtain ⟨p,len,result⟩ := decoded t tm
  have all := read_holds values tokens splits imports constants kind kb r index start previous
    (ScalarPayloadRules.row_holds matrix tokens splits imports constants kind r index start previous checked values satisfied) i ib
  have product := multiply_sound values (layout splits kind r start i).2.1 (layout splits kind r start i).2.2.1 t.value (all _ (by simp [ImportMatrix.readGates,t]))
  have finish := equality_sound values oneValue (readAt r i).cursor ((layout splits kind r start i).2.2.2 ++ t.length)
    (all _ (by simp [ImportMatrix.readGates,t]))
  have pos : E values (layout splits kind r start i).2.2.2 = (p : F) := by rw [← sh.2.2.2]; exact result.2.2.1
  have add : E values ((layout splits kind r start i).2.2.2 ++ t.length) =
      E values (layout splits kind r start i).2.2.2 + E values t.length := eval_append values _ _
  exact ⟨p,len,result,pos,by rw [finish,add,pos,result.2.2.2.1,Semiring.natCast_add],product.symm⟩

def Decoded {F : Type} [Field F] (values : Nat → F) (splits : Splits) (kind : Nat)
    (r : Row) (start : Linear) (message : List Sha256.Byte) (i p len : Nat) : Prop :=
  p < 2^32 ∧ 0 < len ∧ len ≤ BinaryTokenMatrix.capacity (layout splits kind r start i).1 ∧ p+len ≤ message.length ∧
    E values (layout splits kind r start i).2.2.2 = (p : F) ∧ E values (readAt r i).cursor = ((p+len : Nat) : F) ∧
    E values (layout splits kind r start i).2.2.1 =
      (TokenInteger.decode (layout splits kind r start i).1 len (fun j => (message.getD (p+j) 0).toNat) : F)

theorem active_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kb : kind < 4) (r : Row) (index : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants kind r index start previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p len, BinaryTokenSound.Result values t message p len)
    (i : Nat) (ib : i < length kind) (enabled : E values (layout splits kind r start i).2.1 = 1) :
    ∃ p len, Decoded values splits kind r start message i p len := by
  have format : (layout splits kind r start i).1 < 7 := by
    have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 := by omega
    rcases cases with rfl | rfl | rfl | rfl
    · have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 := by simp [length] at ib; omega
      rcases cases with rfl | rfl | rfl | rfl <;> simp [layout,layouts]
    · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [length] at ib; omega
      rcases cases with rfl | rfl | rfl <;> simp [layout,layouts]
    · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
      rcases cases with rfl | rfl <;> simp [layout,layouts]
    · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
      rcases cases with rfl | rfl <;> simp [layout,layouts]
  exact ImportRead.active_read matrix tokens tokenChecks (readAt r i) _ format _ _ _
    (read_shape tokens splits constants kind kb r start
      (ScalarPayloadRules.metadata matrix tokens splits imports constants kind r index start previous checked) i ib)
    values oneValue satisfied enabled
    (read_holds values tokens splits imports constants kind kb r index start previous
      (ScalarPayloadRules.row_holds matrix tokens splits imports constants kind r index start previous checked values satisfied) i ib)
    message decoded

theorem consecutive {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tokens : Tokens) (splits : Splits) (kind : Nat) (kb : kind < 4)
    (r : Row) (start : Linear) (message : List Sha256.Byte) (i p len next nextLen : Nat)
    (ib : i+1 < length kind)
    (a : Step values tokens splits kind r start message i p len)
    (b : Step values tokens splits kind r start message (i+1) next nextLen) : next = p+len := by
  have cursor : (layout splits kind r start (i+1)).2.2.2 = (readAt r i).cursor := by
    have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 := by omega
    rcases cases with rfl | rfl | rfl | rfl
    · have cases : i = 0 ∨ i = 1 ∨ i = 2 := by simp [length] at ib; omega
      rcases cases with rfl | rfl | rfl <;> rfl
    · have cases : i = 0 ∨ i = 1 := by simp [length] at ib; omega
      rcases cases with rfl | rfl <;> rfl
    · have cases : i = 0 := by simp [length] at ib; omega
      rcases cases with rfl <;> rfl
    · have cases : i = 0 := by simp [length] at ib; omega
      rcases cases with rfl <;> rfl

  have equal : (next : F) = ((p+len : Nat) : F) := by rw [← b.2.1,cursor,a.2.2.1]
  exact DeclarationLocations.natural_equal (F := F) _ _ (by have bound := b.1.1; omega)
    (by have pb := a.1.1; have lb := a.1.2.1; omega) equal

#print axioms consecutive
#print axioms step
#print axioms active_read
end ZkBuild.ScalarPayloadRead
