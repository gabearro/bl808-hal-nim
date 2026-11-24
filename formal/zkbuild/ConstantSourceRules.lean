import ConstantSourceSound
set_option autoImplicit false
namespace ZkBuild.ConstantSourceRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem metadata (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true) : shape tokens splits r :=
  _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1

theorem holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) : AllHold values (gates tokens splits r) :=
  MemoryEvidence.span_sound matrix r.firstGate r.lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem part_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (all : AllHold values (gates tokens splits r)) (i : Nat) (bound : i < 12) :
    AllHold values ((parts tokens splits r).getD i []) := by
  have inside : i < (parts tokens splits r).length := by simpa [parts] using bound
  have member : (parts tokens splits r).getD i [] ∈ parts tokens splits r := by
    rw [← List.getElem_eq_getD []]; exact List.getElem_mem inside
  intro g gm
  exact all g (List.mem_flatten.mpr ⟨_,member,gm⟩)

theorem read_shape (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (sh : shape tokens splits r) (i : Nat) (bound : i < 6) :
    readShape tokens r i (layout r i).1 (layout r i).2.1 (layout r i).2.2 := by
  rcases sh with ⟨_,_,_,_,_,_,_,a,b,c,d,e,f⟩
  have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl
  · exact a
  · exact b
  · exact c
  · exact d
  · exact e
  · exact f

theorem reader_holds {F : Type} [Field F] (values : Nat → F) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (all : AllHold values (gates tokens splits r)) (i : Nat) (bound : i < 6) :
    AllHold values (readGates tokens r i) := by
  have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 ∨ i = 5 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 3 (by decide)
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 4 (by decide)
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 6 (by decide)
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 7 (by decide)
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 9 (by decide)
  · simpa only [parts,List.getD_cons_zero,List.getD_cons_succ] using part_holds values tokens splits r all 11 (by decide)

theorem selector_value {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (inside : i < 8) :
    E values (selected r i) = E values (field r 8) * (if E values (field r 5) = (opcodes.getD i 0 : F) then 1 else 0) := by
  have all := holds matrix tokens splits r checked values satisfied
  have sels := part_holds values tokens splits r all 1 (by decide)
  have use : AllHold values (selectorGates r i) := by
    intro g gm
    apply sels
    simp only [parts,List.getD_cons_zero,List.getD_cons_succ]
    exact List.mem_flatMap.mpr ⟨i,List.mem_range.mpr inside,gm⟩
  let start := r.zeroStarts.getD i 0
  have zs := zero_sound values oneValue (sub (field r 5) (n (opcodes.getD i 0))) (wire start) (wire (start+1))
    (by intro g gm; exact use g (List.mem_append_left _ gm))
  have product := multiply_sound values (field r 8) (wire start) (selected r i)
    (use _ (List.mem_append_right _ (by simp [start])))
  have lit : E values (n (opcodes.getD i 0)) = (opcodes.getD i 0 : F) :=
    (eval_constant values oneValue _).trans (Ring.intCast_natCast _)
  have eq : E values (sub (field r 5) (n (opcodes.getD i 0))) = 0 ↔ E values (field r 5) = (opcodes.getD i 0 : F) := by
    rw [eval_sub,lit]; constructor <;> intro h <;> grind
  rw [product,zs]
  simp only [eq]

theorem reader_semantics {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (r : ConstantSourceMatrix.Record)
    (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l)
    (i : Nat) (inside : i < 6) :
    ∃ p l, BinaryTokenSound.Result values (EnvelopeMatrix.token tokens (readAt r i).token) message p l ∧
      E values (cursor r i) = (p : F) ∧ E values (readAt r i).cursor = ((p+l : Nat) : F) ∧
      E values (layout r i).2.2 = E values (EnvelopeMatrix.token tokens (readAt r i).token).value := by
  have sh := read_shape tokens splits r (metadata matrix tokens splits r checked) i inside
  have tm : EnvelopeMatrix.token tokens (readAt r i).token ∈ tokens := by
    rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  obtain ⟨p,l,result⟩ := decoded _ tm
  have pos := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.1
  have val := NameGraphRoots.normalized_eval values _ _ sh.2.2.2.2
  have reads := reader_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) i inside
  have endEq := equality_sound values oneValue (readAt r i).cursor (cursor r i ++ (EnvelopeMatrix.token tokens (readAt r i).token).length)
    (reads _ (by simp [readGates]))
  have start : E values (cursor r i) = (p : F) := pos.symm.trans result.2.2.1
  refine ⟨p,l,result,start,?_,val.symm⟩
  have add : E values (cursor r i ++ (EnvelopeMatrix.token tokens (readAt r i).token).length) = E values (cursor r i)+E values (EnvelopeMatrix.token tokens (readAt r i).token).length := eval_append values _ _
  rw [endEq,add,start,result.2.2.2.1,Semiring.natCast_add]

#print axioms selector_value
#print axioms reader_semantics
end ZkBuild.ConstantSourceRules
