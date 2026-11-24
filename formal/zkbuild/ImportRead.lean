import ImportMembers
set_option autoImplicit false

namespace ZkBuild.ImportRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem active_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (checked : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : Read) (kind : Nat) (kindBound : kind < 7) (active expected cursor : Linear)
    (shape : readMatches tokens r kind active cursor)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values active = 1) (holds : AllHold values (readGates tokens r active expected cursor))
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ position length, position < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity kind ∧ position+length ≤ message.length ∧
      E values cursor = (position : F) ∧ E values r.cursor = ((position+length : Nat) : F) ∧
      E values expected = (TokenInteger.decode kind length (fun i => (message.getD (position+i) 0).toNat) : F) := by
  obtain ⟨inside,format,activity,pos⟩ := shape
  have member : EnvelopeMatrix.token tokens r.token ∈ tokens := by rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem inside
  obtain ⟨position,length,pb,positive,short,within,pi,li,vi⟩ := TokenApplications.active_value matrix (EnvelopeMatrix.token tokens r.token)
    (EnvelopeChain.token_checked matrix tokens checked r.token inside) values oneValue satisfied kind kindBound format (by rw [activity]; exact enabled) message (decoded _ member)
  have value := multiply_sound values active expected (EnvelopeMatrix.token tokens r.token).value (holds _ (by simp [readGates]))
  have finish := equality_sound values oneValue r.cursor (cursor++(EnvelopeMatrix.token tokens r.token).length) (holds _ (by simp [readGates]))
  have cursorImage : E values cursor = (position : F) := by rw [← pos]; exact pi
  have endImage : E values r.cursor = ((position+length : Nat) : F) := by
    have cat := eval_append values cursor (EnvelopeMatrix.token tokens r.token).length
    change E values (cursor++(EnvelopeMatrix.token tokens r.token).length) = E values cursor+E values (EnvelopeMatrix.token tokens r.token).length at cat
    rw [finish,cat,cursorImage,li,Semiring.natCast_add]
  have decodedValue : E values expected = (TokenInteger.decode kind length (fun i => (message.getD (position+i) 0).toNat) : F) := by
    rw [enabled,Semiring.one_mul] at value
    exact value.symm.trans vi
  exact ⟨position,length,pb,positive,short,within,cursorImage,endImage,decodedValue⟩

#print axioms active_read
end ZkBuild.ImportRead
