import InstructionRowCheck
import OperandRepresentationUnique
import ControlRowSound
set_option autoImplicit false
namespace ZkBuild.InstructionRowSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Tags {F : Type} [Field F] (values : Nat → F) (r : InstructionRowCheck.Record) (kind : OperandEvents.Kind) : Prop :=
  ∀ i, E values (f r.tags i) =
    (EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode kind)))).getD i 0

theorem selected_code {F : Type} [CommRing F] (a b : OperandEvents.Kind) :
    OperandEvents.flag (F := F) (decide (OperandEvents.kindCode a = OperandEvents.kindCode b)) = ControlEvents.selected b a := by
  have same : (OperandEvents.kindCode a = OperandEvents.kindCode b) ↔ b = a :=
    ⟨fun h => (OperandRepresentationUnique.kind_injective a b h).symm,fun h => congrArg _ h.symm⟩
  simp only [ControlEvents.selected,same]

theorem selectors {F : Type} [Field F] (values : Nat → F) (r : InstructionRowCheck.Record)
    (kind : OperandEvents.Kind) (images : Tags values r kind) :
    E values (f r.tags 0) = ControlEvents.selected kind .functionBegin ∧
    E values (f r.tags 1) = ControlEvents.selected kind .instructionBegin ∧
    E values (f r.tags 2) = ControlEvents.selected kind .push ∧
    E values (f r.tags 3) = ControlEvents.selected kind .pop ∧
    E values (f r.tags 4) = ControlEvents.selected kind .controlPush ∧
    E values (f r.tags 5) = ControlEvents.selected kind .controlPop ∧
    E values (f r.tags 6) = ControlEvents.selected kind .clear ∧
    E values (f r.tags 7) = ControlEvents.selected kind .instructionEnd ∧
    E values (f r.tags 8) = ControlEvents.selected kind .functionEnd ∧
    E values (f r.tags 9) = ControlEvents.selected kind .labelCheck ∧
    E values (f r.tags 10) = ControlEvents.selected kind .padding := by
  have get (i : Nat) (k : OperandEvents.Kind)
      (h : (EventSelectors.codes.map (fun code => OperandEvents.flag (F := F) (decide (code = OperandEvents.kindCode kind)))).getD i 0 =
        OperandEvents.flag (decide (OperandEvents.kindCode k = OperandEvents.kindCode kind))) :
      E values (f r.tags i) = ControlEvents.selected kind k :=
    (images i).trans (h.trans (selected_code k kind))
  exact ⟨get 0 .functionBegin rfl,get 1 .instructionBegin rfl,get 2 .push rfl,get 3 .pop rfl,
    get 4 .controlPush rfl,get 5 .controlPop rfl,get 6 .clear rfl,get 7 .instructionEnd rfl,
    get 8 .functionEnd rfl,get 9 .labelCheck rfl,get 10 .padding rfl⟩

def Facts {F : Type} [Field F] (values : Nat → F) (r : InstructionRowCheck.Record) : Prop :=
  AllHold values (InstructionRowCheck.modeGates r++InstructionRowCheck.bindingGates r++InstructionRowCheck.labelGates r++InstructionRowCheck.resets r) ∧
  AllHold values (InstructionRowCheck.staticGates r++InstructionRowCheck.updates r) ∧
  (∃ pc : Nat, pc < 2^32 ∧ E values (f r.row 9) = (pc : F)) ∧
  (∃ opcode : Nat, opcode < 2^16 ∧ E values (f r.row 8) = (opcode : F)) ∧
  (∀ i, E values ([f r.row 8,f r.after 5,f r.row 4].getD i []) = E values (r.rule.inputs.getD i []))

theorem facts {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Facts values r := by
  have parts := checked
  simp only [InstructionRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at parts
  rcases parts with ⟨_,_,_,_,_,headGates,tailGates,pcRange,opRange,inputs⟩
  have pcCert := RangeUse.checked_certificate matrix _ _ _ pcRange values one satisfied
  obtain ⟨pc,pb,pi,_⟩ := TokenInteger.certificate_nat values one _ _ _ pcCert
  have opCert := RangeUse.checked_certificate matrix _ _ _ opRange values one satisfied
  obtain ⟨opcode,ob,oi,_⟩ := TokenInteger.certificate_nat values one _ _ _ opCert
  have inputImage := SourceProgramSound.normalized_inputs values _ _ inputs
  have point (i : Nat) := congrArg (fun xs : List F => xs.getD i 0) inputImage
  have equal (i : Nat) : E values ([f r.row 8,f r.after 5,f r.row 4].getD i []) = E values (r.rule.inputs.getD i []) := by
    have eq := point i
    have zero : E values ([] : Linear) = 0 := rfl
    rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at eq
    exact eq
  refine ⟨OperandRowSound.includes_sound matrix _ _ _ headGates values satisfied,
    OperandRowSound.includes_sound matrix _ _ _ tailGates values satisfied,⟨pc,pb,pi⟩,
    ⟨opcode,ob,(equal 0).trans oi⟩,equal⟩

theorem mode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind) (opened pending : Bool)
    (openImage : E values (f r.before 0) = OperandEvents.flag opened)
    (pendingImage : E values (f r.before 1) = OperandEvents.flag pending) :
    InstructionSchedule.allowed opened pending kind = true ∧
      E values (f r.after 15) = OperandEvents.flag (InstructionSchedule.afterOpen opened kind) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10⟩ := selectors values r kind tags
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have h0 := raw (f r.before 1) (sub o (f r.tags 4)) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h1 := raw (f r.before 1) (f r.before 0) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h2 := raw (f r.tags 1) (f r.before 0) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h3 := raw (f r.tags 7) (sub o (f r.before 0)) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h4 := raw (f r.tags 0++f r.tags 8++f r.tags 10) (f r.before 0) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h5 := raw (sub (f r.tags 2++f r.tags 3++f r.tags 4++f r.tags 5++f r.tags 6++f r.tags 9) (f r.before 1))
    (sub o (f r.before 0)) (fs.1 _ (by simp [InstructionRowCheck.modeGates]))
  have h6 := equality_sound values one (f r.after 15) (sub (f r.before 0++f r.tags 1) (f r.tags 7))
    (fs.2.1 _ (by simp [InstructionRowCheck.updates]))
  have gates : InstructionSchedule.ModeGates opened pending kind (E values (f r.after 15)) := by
    simp only [eval_sub,eval_append,o,eval_constant values one,Ring.intCast_one,openImage,pendingImage,
      t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10] at h0 h1 h2 h3 h4 h5 h6
    constructor <;> grind only
  exact InstructionSchedule.mode_sound opened pending kind _ gates

theorem binding {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind) (previousPc previousOpcode : Nat)
    (pcBound : previousPc ≤ 2^32) (opBound : previousOpcode < 2^16)
    (pcImage : E values (f r.before 2) = (previousPc : F)) (opImage : E values (f r.before 3) = (previousOpcode : F)) :
    ∃ pc opcode : Nat, pc < 2^32 ∧ opcode < 2^16 ∧ E values (f r.row 9) = (pc : F) ∧
      E values (f r.row 8) = (opcode : F) ∧ InstructionSchedule.BindingSpec previousPc previousOpcode pc opcode kind ∧
      InstructionSchedule.nextPc previousPc kind ≤ 2^32 ∧
      E values (f r.after 3) = (InstructionSchedule.nextPc previousPc kind : F) ∧
      E values (f r.after 4) = (InstructionSchedule.chosenOpcode previousOpcode opcode kind : F) := by
  have fs := facts matrix r checked values one satisfied
  obtain ⟨pc,pb,pi⟩ := fs.2.2.1
  obtain ⟨opcode,ob,oi⟩ := fs.2.2.2.1
  obtain ⟨t0,t1,_,_,_,_,_,t7,t8,_,t10⟩ := selectors values r kind tags
  have raw (a b : Linear) (h : Holds values (gate a b)) : E values a * E values b = 0 := by
    change E values a * E values b = E values z at h
    simpa [z,eval_constant values one,Ring.intCast_zero] using h
  have h0 := select_sound values (f r.tags 0) z (f r.before 2) (f r.after 2) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h1 := raw (sub o (f r.tags 10)) (sub (f r.row 9) (f r.after 2)++f r.tags 8) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h2 := raw (f r.tags 10) (f r.row 9) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h3 := equality_sound values one (f r.after 3) (f r.after 2++f r.tags 7) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h4 := select_sound values (f r.tags 0++f r.tags 1) (f r.row 8) (f r.before 3) (f r.after 4) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h5 := raw (sub o (f r.tags 10)) (sub (f r.row 8) (f r.after 4)) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h6 := raw (f r.tags 0) (sub (f r.row 8) (n 2)) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h7 := raw (f r.tags 8) (sub (f r.row 8) (n 11)) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have h8 := raw (f r.tags 10) (f r.row 8) (fs.1 _ (by simp [InstructionRowCheck.bindingGates]))
  have gates : InstructionSchedule.BindingGates previousPc previousOpcode pc opcode kind
      (E values (f r.after 2)) (E values (f r.after 4)) (E values (f r.after 3)) := by
    simp only [eval_sub,eval_append,o,z,n,eval_constant values one,Ring.intCast_one,Ring.intCast_zero,
      show ((Int.ofNat 2 : Int) : F) = 2 from Ring.intCast_ofNat 2,
      show ((Int.ofNat 11 : Int) : F) = 11 from Ring.intCast_ofNat 11,pcImage,opImage,pi,oi,t0,t1,t7,t8,t10]
      at h0 h1 h2 h3 h4 h5 h6 h7 h8
    exact ⟨h0,h1,h2,h3,h4,h5,h6,h7,h8⟩
  have spec := InstructionSchedule.binding_sound _ _ _ _ kind _ _ _ pcBound pb opBound ob gates
  have fields := InstructionSchedule.chosen_field _ _ _ _ kind _ _ _ gates
  exact ⟨pc,opcode,pb,ob,pi,oi,spec.1,spec.2,fields.2.2,fields.2.1⟩

theorem label {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : Tags values r kind)
    (opcode : Nat) (ob : opcode < 2^16) (opImage : E values (f r.row 8) = (opcode : F)) :
    kind = .labelCheck → opcode = 14 ∨ opcode = 31 := by
  classical
  intro kindEq
  have fs := facts matrix r checked values one satisfied
  have allLabels : AllHold values (InstructionRowCheck.labelGates r) := by
    intro g member
    exact fs.1 g (by simp only [List.mem_append]; exact Or.inl (Or.inr member))
  have branch := zero_sound values one (sub (f r.row 8) (n 14)) (f r.after 0) (f r.after 16)
    (fun g member => allLabels g (by simp only [InstructionRowCheck.labelGates,List.mem_append]; exact Or.inl (Or.inl member)))
  have catching := zero_sound values one (sub (f r.row 8) (n 31)) (f r.after 1) (f r.after 17)
    (fun g member => allLabels g (by simp only [InstructionRowCheck.labelGates,List.mem_append]; exact Or.inl (Or.inr member)))
  have guard := fs.1 (gate (f r.tags 9) (sub (sub o (f r.after 0)) (f r.after 1)))
    (by simp [InstructionRowCheck.labelGates])
  have selected := (selectors values r kind tags).2.2.2.2.2.2.2.2.2.1
  have field14 : ((Int.ofNat 14 : Int) : F) = ((14 : Nat) : F) := (Ring.intCast_ofNat 14).trans (Semiring.natCast_eq_ofNat 14).symm
  have field31 : ((Int.ofNat 31 : Int) : F) = ((31 : Nat) : F) := (Ring.intCast_ofNat 31).trans (Semiring.natCast_eq_ofNat 31).symm
  simp only [eval_sub,n,eval_constant values one,opImage,field14,field31] at branch catching
  by_cases a : (opcode : F)-(14 : Nat) = 0
  · left
    apply OperandEvents.natural_eq (F := F) opcode 14 (by unfold OperandEvents.bound; omega) (by decide)
    grind only
  · by_cases b : (opcode : F)-(31 : Nat) = 0
    · right
      apply OperandEvents.natural_eq (F := F) opcode 31 (by unfold OperandEvents.bound; omega) (by decide)
      grind only
    · simp only [a,b,ite_false] at branch catching
      change E values (f r.tags 9)*E values (sub (sub o (f r.after 0)) (f r.after 1)) = E values z at guard
      simp only [eval_sub,o,z,eval_constant values one,Ring.intCast_zero,Ring.intCast_one,
        selected,kindEq,ControlEvents.selected,OperandEvents.flag,↓reduceIte,branch,catching] at guard
      have bad : (1 : F) = 0 := by grind only
      exact False.elim (Field.zero_ne_one bad.symm)

#print axioms label

#print axioms facts
#print axioms mode
#print axioms binding
end ZkBuild.InstructionRowSound
