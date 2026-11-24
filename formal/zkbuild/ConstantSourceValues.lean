import ConstantSourceSelection
set_option autoImplicit false
namespace ZkBuild.ConstantSourceValues
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem modern_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (modern : E values (field r 8) = 1) (i : Nat) (inside : i < 8)
    (choice : ∀ j, j < 8 → E values (selected r j) = (if j = i then 1 else 0)) :
    ∃ value : Nat, value < 2^64 ∧ E values (field r 12) = (value : F) ∧
      E values (field r 6) = (if i = 1 ∨ i = 3 then ((value % 2^32 : Nat) : F) else if i = 4 then 0 else (value : F)) ∧
      E values (field r 7) = (if i = 4 then 1 else 0) := by
  have shape := metadata matrix tokens splits r checked
  have sh : r.heads < splits.length ∧ splitMatches (split splits r.heads) (field r 12) 32 32 := shape.2.2.2.2.2.1 |> fun h => ⟨h,shape.2.2.2.2.2.2.1⟩
  have sm : split splits r.heads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem sh.1
  obtain ⟨value,low,high,vb,lb,hb,vi,li,hi,packed,modulo,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ sm) values oneValue satisfied
  have fields := sh.2
  unfold splitMatches at fields
  simp only [fields.2.1,fields.2.2] at vb modulo
  have vi : E values (field r 12) = (value : F) := by rw [← fields.1]; exact vi
  have lowImage : E values (split splits r.heads).low = ((value % 2^32 : Nat) : F) := by simpa only [modulo] using li
  have part := part_holds values tokens splits r (holds matrix tokens splits r checked values satisfied) 8 (by decide)
  have wp := multiply_sound values (wide r) (split splits r.heads).low (field r 15) (part _ (by simp [parts]))
  have sp := multiply_sound values (sub (sub (field r 8) (wide r)) (vector r)) (field r 12) (field r 16) (part _ (by simp [parts]))
  have immediate := part (gate (field r 8) (sub (sub (field r 6) (field r 15)) (field r 16))) (by simp [parts])
  have vectors := part (gate (field r 8) (sub (field r 7) (vector r))) (by simp [parts])
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  change E values (field r 8)*E values (sub (sub (field r 6) (field r 15)) (field r 16)) = E values z at immediate
  change E values (field r 8)*E values (sub (field r 7) (vector r)) = E values z at vectors
  have one := choice 1 (by decide)
  have three := choice 3 (by decide)
  have four := choice 4 (by decide)
  have add : E values (wide r) = E values (selected r 1)+E values (selected r 3) := eval_append values _ _
  change E values (vector r) = _ at four
  rw [modern,eval_sub,eval_sub,zero,Semiring.one_mul] at immediate
  rw [modern,eval_sub,zero,Semiring.one_mul] at vectors
  rw [wp,sp,eval_sub,eval_sub,modern,vi,lowImage,add,one,three,four] at immediate
  rw [four] at vectors
  refine ⟨value,by omega,vi,?_,?_⟩
  · by_cases first : i = 1
    · subst i; simp at immediate ⊢; grind
    · by_cases third : i = 3
      · subst i; simp at immediate ⊢; grind
      · by_cases fourth : i = 4
        · subst i; simp at immediate ⊢; grind
        · have n1 : 1 ≠ i := Ne.symm first
          have n3 : 3 ≠ i := Ne.symm third
          have n4 : 4 ≠ i := Ne.symm fourth
          simp only [n1,n3,n4,first,third,fourth,ite_false,or_self] at immediate ⊢
          grind
  · by_cases fourth : i = 4
    · subst i; simp at vectors ⊢; grind
    · have n4 : 4 ≠ i := Ne.symm fourth
      simp only [n4,fourth,ite_false] at vectors ⊢
      grind

#print axioms modern_value
end ZkBuild.ConstantSourceValues
