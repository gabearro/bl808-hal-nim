import NameFrameRules
set_option autoImplicit false
namespace ZkBuild.NameFrameLegacy
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem cursor_length {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (items : List ByteRow) (checks : ∀ b ∈ items, checkByte matrix tokens false b = true)
    (owner ordinal : Nat) (cursor : Linear) (linked : legacyLink items owner ordinal cursor = true) :
    E values (finalCursor items cursor) = E values cursor+(items.length : F) := by
  induction items generalizing ordinal cursor with
  | nil => simp [finalCursor,Semiring.add_zero]
  | cons b bs ih =>
    have shape := Bool.and_eq_true_iff.mp linked
    have fields := _root_.of_decide_eq_true shape.1
    have step := NameFrameRules.byte_step matrix tokens tokenChecks false b (checks b (by simp)) values oneValue satisfied
      (by rw [fields.1]; simp [o,eval_constant values oneValue])
    have tail := ih (by intro row member; exact checks row (by simp [member])) (ordinal+1) (bget b 4) shape.2
    simp only [finalCursor,List.length_cons]
    rw [tail,step,fields.2.2.2,Semiring.natCast_add,Semiring.natCast_one]
    grind

theorem spans {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (bytes : List ByteRow) (byteChecks : bytes.all (checkByte matrix tokens false) = true)
    (hs : List Header) (index offset : Nat) (checked : legacyHeaders matrix tokens bytes hs index offset = true) :
    ∀ h ∈ hs, checkHeader matrix tokens false h = true ∧ E values (hget h 4) = E values (hget h 3)+E values (hget h 1) := by
  induction hs generalizing index offset with
  | nil => simp
  | cons h rest ih =>
    have p := checked
    simp only [legacyHeaders,Bool.and_eq_true_iff,decide_eq_true_eq] at p
    have head : checkHeader matrix tokens false h = true := by grind only
    have bounds : h.byteStart = offset ∧ offset+h.byteCount ≤ bytes.length := by grind only
    have linked : legacyLink ((bytes.drop offset).take h.byteCount) index 0 (hget h 3) = true := by grind only
    have closing : MemoryEvidence.checkSpan matrix h.closeGate (h.closeGate+1)
        [eqGate (hget h 4) (finalCursor ((bytes.drop offset).take h.byteCount) (hget h 3))] = true := by grind only
    have next : legacyHeaders matrix tokens bytes rest (index+1) (offset+h.byteCount) = true := by grind only
    have shape := NameFrameRules.header_shape matrix tokens false h head
    have countField : hget h 1 = n h.byteCount := by simpa using shape.2.2.2.2.2.2.2.2
    have eqn := equality_sound values oneValue (hget h 4) (finalCursor ((bytes.drop offset).take h.byteCount) (hget h 3))
      (MemoryEvidence.span_sound matrix h.closeGate (h.closeGate+1) _ closing values satisfied _ (by simp))
    have width := cursor_length matrix tokens tokenChecks values oneValue satisfied ((bytes.drop offset).take h.byteCount)
      (by intro b member; exact List.all_eq_true.mp byteChecks b (List.mem_of_mem_drop (List.mem_of_mem_take member))) index 0 (hget h 3) linked
    have size : ((bytes.drop offset).take h.byteCount).length = h.byteCount := by simp; omega
    have countImage : E values (hget h 1) = (h.byteCount : F) := by rw [countField,n,eval_constant values oneValue]; exact Ring.intCast_natCast _
    intro item member
    rcases List.mem_cons.mp member with same | later
    · subst item
      exact ⟨head,by rw [eqn,width,size,countImage]⟩
    · exact ih (index+1) (offset+h.byteCount) next item later

#print axioms cursor_length
#print axioms spans
end ZkBuild.NameFrameLegacy
