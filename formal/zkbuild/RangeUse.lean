import GadgetAudit

/- A range call, including its original fresh certificate when the Nim builder
   reuses bits. This carries no field assignment or asserted numeric bound. -/
namespace ZkBuild.RangeUse

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

structure Record where
  call : GadgetAudit.Record
  source : Option GadgetAudit.Record
  deriving Inhabited

def gates (r : Record) : List Gate :=
  match GadgetAudit.describe r.call r.source with
  | none => []
  | some t => t.gates

def bits (r : Record) : List Linear := r.call.outputs

def check (matrix : Shape) (r : Record) (value : Linear) (width : Nat) : Bool :=
  decide (r.call.width = width ∧ r.call.inputs = [value] ∧
    (r.call.kind = 8 ∨ r.call.kind = 9 ∨ r.call.kind = 10)) &&
  GadgetAudit.check matrix r.call r.source &&
  (if r.call.kind = 9 then match r.source with
    | none => false
    | some prior => GadgetAudit.check matrix prior none &&
      decide (prior.lastWire ≤ r.call.firstWire ∧ prior.lastGate ≤ r.call.firstGate)
   else true)

theorem checked_certificate {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (value : Linear) (width : Nat)
    (accepted : check matrix r value width = true) (values : Nat → F) (one : values 0 = 1)
    (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate width (E values value) ((bits r).map (E values)) := by
  have parts : (r.call.width = width ∧ r.call.inputs = [value] ∧
      (r.call.kind = 8 ∨ r.call.kind = 9 ∨ r.call.kind = 10)) ∧
      GadgetAudit.check matrix r.call r.source = true ∧
      (if r.call.kind = 9 then match r.source with
        | none => false
        | some prior => GadgetAudit.check matrix prior none &&
          decide (prior.lastWire ≤ r.call.firstWire ∧ prior.lastGate ≤ r.call.firstGate)
       else true) = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  have finish (h : RangeReuse.Certificate r.call.width (E values value) (r.call.outputs.map (E values))) :
      RangeReuse.Certificate width (E values value) ((bits r).map (E values)) := by
    simpa [bits,parts.1.1] using h
  rcases parts.1.2.2 with fresh | reused | literal
  · let t : GadgetAudit.Template := ⟨rangeGates value r.call.firstWire r.call.width,
      rangeBits r.call.firstWire r.call.width,r.call.width⟩
    have description : GadgetAudit.describe r.call r.source = some t := by
      simp [GadgetAudit.describe,fresh,parts.1.2.1,t]
    have relation := GadgetAudit.checked_fragment_relation matrix r.call r.source t description parts.2.1 values satisfied
    apply finish
    rw [relation.2]
    exact range_certificate values one value r.call.firstWire r.call.width
      (by simpa [GadgetAudit.model,t,Satisfied,AllHold,Holds] using relation.1)
  · obtain ⟨prior,found,kind,widthSame,inputSame,nonzero⟩ :=
      GadgetAudit.reused_source matrix r.call r.source value reused parts.1.2.1 parts.2.1
    have checkedPrior : GadgetAudit.check matrix prior none = true := by
      have h := parts.2.2
      simp only [reused,↓reduceIte,found,Bool.and_eq_true_iff] at h
      exact h.1
    have priorInput : prior.inputs = [value] := inputSame.symm.trans parts.1.2.1
    have priorCert := GadgetAudit.checked_unsigned matrix prior value kind priorInput checkedPrior values one satisfied
    apply finish
    exact GadgetAudit.checked_reused_unsigned matrix r.call prior value reused parts.1.2.1
      ⟨kind,widthSame,inputSame,nonzero⟩ (by simpa [found] using parts.2.1) values satisfied priorCert
  · cases cv : GadgetAudit.constantValue value with
    | none => simp [GadgetAudit.check,GadgetAudit.describe,literal,parts.1.2.1,cv] at parts
    | some n =>
      let t : GadgetAudit.Template := ⟨literalGates n r.call.width,literalOutputs (literalBits n r.call.width),0⟩
      have description : GadgetAudit.describe r.call r.source = some t := by
        simp [GadgetAudit.describe,literal,parts.1.2.1,cv,t]
      have relation := GadgetAudit.checked_fragment_relation matrix r.call r.source t description parts.2.1 values satisfied
      apply finish
      rw [relation.2,GadgetAudit.constant_value_sound values one value n cv]
      exact literal_matrix_sound values one n r.call.width
        (by simpa [GadgetAudit.model,t,Satisfied,AllHold,Holds] using relation.1)

#print axioms checked_certificate
end ZkBuild.RangeUse
