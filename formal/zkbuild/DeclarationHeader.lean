import DeclarationType
import TokenApplications
namespace ZkBuild.DeclarationHeader
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix DeclarationType
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem type_header {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (checks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (r : TypeRow) (i : Nat) (prior : List Linear) (previous endPos : Linear)
    (accepted : checkType matrix tokens splits r i prior previous endPos = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : DeclarationType.Decoded) (represented : DeclarationType.Represents values r d) (bounded : DeclarationType.Bounded d)
    (enabled : d.active = true) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    d.start < message.length ∧ (message.getD d.start 0).toNat = 96 := by
  have shape := type_metadata matrix tokens splits r i prior previous endPos accepted
  have inside := shape.2.2.2.1
  have header := shape.2.2.2.2.2.2.2.1
  have a : E values (get r.fields 0) = 1 := by simpa [enabled] using represented.1
  have member : token tokens r.headerToken ∈ tokens := by
    rw [token,← List.getElem_eq_getD default]; exact List.getElem_mem inside
  apply TokenApplications.byte_value matrix _ (EnvelopeChain.token_checked matrix tokens checks _ inside) values oneValue satisfied header.1
    (by rw [header.2.1]; exact a) message d.start 96 (bounded _ (by simp [numbers])) (by decide)
    (by rw [header.2.2.1]; exact represented.2.1) ?_ (decoded _ member)
  rw [header.2.2.2]
  calc
    E values (scale (get r.fields 0) 96) = ((96 : Int) : F) := by
      have scaled := FullMatrix.eval_scale values (get r.fields 0) 96
      change E values (scale (get r.fields 0) 96) = ((96 : Int) : F)*E values (get r.fields 0) at scaled
      simpa only [a,Semiring.mul_one] using scaled
    _ = ((96 : Nat) : F) := Ring.intCast_natCast 96

#print axioms type_header
end ZkBuild.DeclarationHeader
