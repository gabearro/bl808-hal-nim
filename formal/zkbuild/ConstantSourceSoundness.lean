import ConstantSourceTrace
set_option autoImplicit false
namespace ZkBuild.ConstantSourceSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ConstantSourceMatrix ConstantSourceRules ConstantSourceModes ConstantSourceRead ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def Extra {F : Type} [Field F] (values : Nat → F) (r : ConstantSourceMatrix.Record) (message : List Sha256.Byte) (i : Nat) : Prop :=
  (if i = 4 then
    (∃ p length, Decoded values r 1 message 1 p length) ∧
      E values (layout r 1).2.2 = ((12 : Nat) : F) ∧
      (∃ p length, Decoded values r 3 message 6 p length)
   else E values (readAt r 1).cursor = E values (cursor r 1) ∧
      E values (readAt r 3).cursor = E values (cursor r 3)) ∧
    E values (readAt r 5).cursor = E values (cursor r 5)

def Modern {F : Type} [Field F] (values : Nat → F) (r : ConstantSourceMatrix.Record) (message : List Sha256.Byte) : Prop :=
  ∃ i value : Nat, i < 8 ∧ value < 2^64 ∧ E values (field r 1) = 1 ∧
    E values (field r 5) = (opcodes.getD i 0 : F) ∧ E values (mode r) = (modes.getD i 0 : F) ∧
    E values (field r 12) = (value : F) ∧
    E values (field r 6) = (if i = 1 ∨ i = 3 then ((value % 2^32 : Nat) : F) else if i = 4 then 0 else (value : F)) ∧
    E values (field r 7) = (if i = 4 then 1 else 0) ∧
    (∃ p, p < message.length ∧ (message.getD p 0).toNat = encodedOpcode i ∧
      E values (cursor r 0) = (p : F) ∧ E values (readAt r 0).cursor = ((p+1 : Nat) : F)) ∧
    (∃ p, p < message.length ∧ (message.getD p 0).toNat = 11 ∧
      E values (cursor r 4) = (p : F) ∧ E values (readAt r 4).cursor = ((p+1 : Nat) : F)) ∧
    (∃ p length, Decoded values r 2 message (modes.getD i 0-1) p length) ∧ Extra values r message i

def Legacy {F : Type} [Field F] (values : Nat → F) (r : ConstantSourceMatrix.Record) (message : List Sha256.Byte) : Prop :=
  E values (field r 1) = 0 ∧ E values (field r 5) = ((0xd2 : Nat) : F) ∧ E values (field r 7) = 0 ∧
  (∀ i, i < 5 → E values (readAt r i).cursor = E values (cursor r i)) ∧
  ∃ p length, Decoded values r 5 message 1 p length ∧ E values (field r 6) = E values (field r 17)

theorem active_constant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : ConstantSourceMatrix.Record) (checked : ConstantSourceMatrix.check matrix tokens splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ p l, BinaryTokenSound.Result values t message p l)
    (active : E values (field r 0) = 1) :
    E values (field r 3) = 1 ∧ E values (field r 4) = 1 ∧ (Modern values r message ∨ Legacy values r message) := by
  have wires := wire_values matrix tokens splits r checked values oneValue satisfied active
  refine ⟨wires.1,wires.2.1,?_⟩
  rcases ConstantSourceSelection.selection matrix tokens tokenChecks splits r checked values oneValue satisfied active with legacy | modern
  · obtain ⟨use,no,on,opcode,vec⟩ := legacy
    obtain ⟨vectorZero,modeZero⟩ := unused_mode matrix tokens splits r checked values oneValue satisfied no
    have disabled (i : Nat) (ib : i < 5) : E values (layout r i).2.1 = 0 := by
      have cases : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 := by omega
      rcases cases with rfl | rfl | rfl | rfl | rfl <;>
        simp only [layout,no,vectorZero,modeZero]
      have scaled := eval_scale values (vector r) 7
      change E values (scale (vector r) 7) = ((7 : Int) : F)*E values (vector r) at scaled
      rw [scaled,vectorZero,Semiring.mul_zero]
    obtain ⟨p,l,result⟩ := active_fixed matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 5 1 (by decide) (by decide) rfl on
    have immediate : E values (field r 6) = E values (field r 17) := by rw [wires.2.2.2.2.2,on,Semiring.one_mul]
    exact Or.inr ⟨use,opcode,vec,fun i ib => (inactive matrix tokens tokenChecks splits r checked values oneValue satisfied i (by omega) (disabled i ib)).1,p,l,result,immediate⟩
  · obtain ⟨use,on,_,i,ib,opcode,choice⟩ := modern
    obtain ⟨value,vb,vi,imm,vec⟩ := ConstantSourceValues.modern_value matrix tokens splits splitChecks r checked values oneValue satisfied on i ib choice
    have modeEq := mode_value values oneValue r i ib choice
    have prefixValue := prefix_value matrix tokens splits r checked values oneValue satisfied active on i ib opcode choice
    have encodedBound : encodedOpcode i < 256 := by
      have all : ∀ i : Fin 8, encodedOpcode i.val < 256 := by decide
      exact all ⟨i,ib⟩
    obtain ⟨p,_,pb,byte,pi,pe⟩ := active_byte matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 0 (encodedOpcode i) (by decide) encodedBound rfl on prefixValue
    have endValue : E values (layout r 4).2.2 = ((11 : Nat) : F) := by
      change E values (scale (field r 8) 11) = _
      have scaled := eval_scale values (field r 8) 11
      change E values (scale (field r 8) 11) = ((11 : Int) : F)*E values (field r 8) at scaled
      rw [scaled,on,Semiring.mul_one]
      exact Ring.intCast_natCast 11
    obtain ⟨e,_,eb,endByte,ei,ee⟩ := active_byte matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 4 11 (by decide) (by decide) rfl on endValue
    have bounds : 0 < modes.getD i 0 ∧ modes.getD i 0 ≤ 7 := by
      have all : ∀ i : Fin 8, 0 < modes.getD i.val 0 ∧ modes.getD i.val 0 ≤ 7 := by decide
      exact all ⟨i,ib⟩
    have format : E values (layout r 2).2.1 = ((modes.getD i 0-1+1 : Nat) : F) := by
      change E values (mode r) = _
      rw [modeEq]; congr 1; omega
    obtain ⟨a,l,operand⟩ := active_variant matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 2 (modes.getD i 0-1) (by decide) (by omega) rfl format
    have off : E values (field r 9) = 0 := by
      have link := NameGraphRoots.normalized_eval values _ _ (metadata matrix tokens splits r checked).2.2.2.2.1
      rw [eval_sub,active,on] at link
      grind
    have last := (inactive matrix tokens tokenChecks splits r checked values oneValue satisfied 5 (by decide) off).1
    have extra : Extra values r message i := by
      refine ⟨?_,last⟩
      by_cases vectorCase : i = 4
      · rw [ite_eq_left vectorCase]
        have vi : E values (vector r) = 1 := by simpa only [vector,vectorCase,ite_true] using choice 4 (by decide)
        obtain ⟨s,sl,subopcode⟩ := active_fixed matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 1 1 (by decide) (by decide) rfl vi
        have scalar (k : Nat) : E values (scale (vector r) (Int.ofNat k)) = (k : F) := by
          have h := eval_scale values (vector r) (Int.ofNat k)
          change E values (scale (vector r) (Int.ofNat k)) = ((Int.ofNat k : Int) : F)*E values (vector r) at h
          rw [h,vi,Semiring.mul_one]
          exact Ring.intCast_natCast _
        obtain ⟨s2,sl2,second⟩ := active_variant matrix tokens tokenChecks splits r checked values oneValue satisfied message decoded 3 6 (by decide) (by decide) rfl (scalar 7)
        exact ⟨⟨s,sl,subopcode⟩,scalar 12,s2,sl2,second⟩
      · rw [ite_eq_right vectorCase]
        have vi : E values (vector r) = 0 := by simpa only [vector,Ne.symm vectorCase,ite_false] using choice 4 (by decide)
        have secondOff : E values (layout r 3).2.1 = 0 := by
          change E values (scale (vector r) 7) = _
          have h := eval_scale values (vector r) 7
          change E values (scale (vector r) 7) = ((7 : Int) : F)*E values (vector r) at h
          rw [h,vi,Semiring.mul_zero]
        exact ⟨(inactive matrix tokens tokenChecks splits r checked values oneValue satisfied 1 (by decide) vi).1,
          (inactive matrix tokens tokenChecks splits r checked values oneValue satisfied 3 (by decide) secondOff).1⟩
    exact Or.inl ⟨i,value,ib,vb,use,opcode,modeEq,vi,imm,vec,⟨p,pb,byte,pi,pe⟩,⟨e,eb,endByte,ei,ee⟩,⟨a,l,operand⟩,extra⟩

theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (constants : List ConstantSourceMatrix.Record)
    (checked : ConstantSourceSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source constants = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      ∀ r ∈ constants, ConstantSourceTrace.Trace values body.tokens r message ∧
        (E values (field r 0) = 1 → E values (field r 3) = 1 ∧ E values (field r 4) = 1 ∧
          (Modern values r message ∨ Legacy values r message)) := by
  have cp := Bool.and_eq_true_iff.mp checked
  have gp := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp cp.1).1
  have fp := Bool.and_eq_true_iff.mp gp.1
  have op := Bool.and_eq_true_iff.mp fp.1
  have signatureCheck := (Bool.and_eq_true_iff.mp op.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have splitChecks := (Bool.and_eq_true_iff.mp moduleCheck).2
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨message,meaning,d0,d1,_,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  refine ⟨message,meaning,d0,d1,?_⟩
  intro r member
  have rc := List.all_eq_true.mp cp.2 r member
  exact ⟨ConstantSourceTrace.checked_trace matrix body.tokens splits r rc values oneValue satisfied message decoded,
    active_constant matrix body.tokens tokenChecks splits splitChecks r rc values oneValue satisfied message decoded⟩

#print axioms active_constant
#print axioms module_verified
end ZkBuild.ConstantSourceSoundness
