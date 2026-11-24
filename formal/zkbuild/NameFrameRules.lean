import NameFrameSound
import OwnedUnit
set_option autoImplicit false
namespace ZkBuild.NameFrameRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameFrameMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem header_shape (matrix : Shape) (tokens : Tokens) (flat : Bool) (h : Header)
    (checked : checkHeader matrix tokens flat h = true) : headerShape tokens flat h := by
  simp only [checkHeader,Bool.and_eq_true_iff,decide_eq_true_eq] at checked
  exact checked.1.1

theorem byte_shape (matrix : Shape) (tokens : Tokens) (flat : Bool) (b : ByteRow)
    (checked : checkByte matrix tokens flat b = true) : byteShape tokens b := by
  exact of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1

theorem header_step {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (flat : Bool) (h : Header)
    (checked : checkHeader matrix tokens flat h = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (hget h 3) = E values (hget h 2)+E values (EnvelopeMatrix.token tokens h.token).length := by
  have holds := MemoryEvidence.span_sound matrix h.firstGate h.lastGate (headerGates tokens h)
    (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have eqn := equality_sound values oneValue (hget h 3) (hget h 2 ++ (EnvelopeMatrix.token tokens h.token).length) (holds _ (by simp [headerGates]))
  exact eqn.trans (eval_append values _ _)

theorem byte_step {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (flat : Bool) (b : ByteRow) (checked : checkByte matrix tokens flat b = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values (bget b 0) = 1) : E values (bget b 4) = E values (bget b 3)+1 := by
  have shape := byte_shape matrix tokens flat b checked
  have holds := MemoryEvidence.span_sound matrix b.firstGate b.lastGate (byteGates tokens flat b)
    (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have eqn := equality_sound values oneValue (bget b 4) (bget b 3 ++ if flat then (EnvelopeMatrix.token tokens b.token).length else o) (holds _ (by simp [byteGates]))
  have sum := eval_append values (bget b 3) (if flat then (EnvelopeMatrix.token tokens b.token).length else o)
  change E values _ = E values (bget b 3)+_ at sum
  rw [eqn,sum]
  cases flat with
  | false => simp [o,eval_constant values oneValue]
  | true =>
    obtain ⟨n,bound,ni,activity,_⟩ := BinaryTokenSchedule.checked_length matrix (EnvelopeMatrix.token tokens b.token)
      (EnvelopeChain.token_checked matrix tokens tokenChecks b.token shape.2.1) values oneValue satisfied
    have a : E values (BinaryTokenMatrix.active (EnvelopeMatrix.token tokens b.token)) = 1 := by
      simpa [BinaryTokenMatrix.active,shape.2.2.1,shape.2.2.2.1] using enabled
    have positive : n ≠ 0 := by
      intro zero
      have bad : (1 : F) = 0 := by simpa [zero,a] using activity
      exact Field.zero_ne_one bad.symm
    have nb : n ≤ 1 := by simpa [shape.2.2.1,BinaryTokenMatrix.capacity] using bound
    have n1 : n = 1 := by omega
    simp [ni,n1]

theorem header_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (flat : Bool) (h : Header) (checked : checkHeader matrix tokens flat h = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values (hget h 0) = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∃ p length, p < 2^32 ∧ 0 < length ∧ length ≤ 5 ∧ p+length ≤ message.length ∧
      E values (hget h 2) = (p : F) ∧ E values (hget h 3) = ((p+length : Nat) : F) ∧
      E values (hget h 1) = (TokenInteger.decode 1 length (fun i => (message.getD (p+i) 0).toNat) : F) := by
  have sh := header_shape matrix tokens flat h checked
  have member : EnvelopeMatrix.token tokens h.token ∈ tokens := by
    rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.2.1
  obtain ⟨p,l,pb,positive,lb,inside,pi,li,vi⟩ := TokenApplications.active_value matrix _
    (EnvelopeChain.token_checked matrix tokens tokenChecks h.token sh.2.1) values oneValue satisfied
    1 (by decide) sh.2.2.1 (by rw [sh.2.2.2.1]; exact enabled) message (decoded _ member)
  have pos : E values (hget h 2) = (p : F) := by rw [← sh.2.2.2.2.1]; exact pi
  refine ⟨p,l,pb,positive,by simpa [BinaryTokenMatrix.capacity] using lb,inside,pos,?_,?_⟩
  · rw [header_step matrix tokens flat h checked values oneValue satisfied,pos,li,Semiring.natCast_add]
  · rw [← sh.2.2.2.2.2.1]; exact vi

theorem byte_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (flat : Bool) (b : ByteRow) (checked : checkByte matrix tokens flat b = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values (bget b 0) = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ p length, BinaryTokenSound.Result values t message p length) :
    ∃ p, p < 2^32 ∧ p < message.length ∧ E values (bget b 3) = (p : F) ∧
      E values (bget b 4) = ((p+1 : Nat) : F) ∧
      E values (EnvelopeMatrix.token tokens b.token).value = ((message.getD p 0).toNat : F) := by
  have sh := byte_shape matrix tokens flat b checked
  have member : EnvelopeMatrix.token tokens b.token ∈ tokens := by
    rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem sh.2.1
  obtain ⟨p,l,pb,positive,lb,inside,pi,_,vi⟩ := TokenApplications.active_value matrix _
    (EnvelopeChain.token_checked matrix tokens tokenChecks b.token sh.2.1) values oneValue satisfied
    0 (by decide) sh.2.2.1 (by rw [sh.2.2.2.1]; exact enabled) message (decoded _ member)
  have len : l = 1 := by simp [BinaryTokenMatrix.capacity] at lb; omega
  have pos : E values (bget b 3) = (p : F) := by rw [← sh.2.2.2.2]; exact pi
  refine ⟨p,pb,by omega,pos,?_,?_⟩
  · rw [byte_step matrix tokens tokenChecks flat b checked values oneValue satisfied enabled,pos,Semiring.natCast_add,Semiring.natCast_one]
  · rw [len,EnvelopeSound.decode_byte (fun i => (message.getD (p+i) 0).toNat) (by simpa using (message.getD p 0).isLt)] at vi
    simpa only [Nat.add_zero] using vi

#print axioms header_step
#print axioms byte_step
#print axioms header_read
#print axioms byte_read
end ZkBuild.NameFrameRules
