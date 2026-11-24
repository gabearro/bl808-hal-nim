import ShaProgram

namespace ZkBuild.ShaCompression

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaWordMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def input (index : Nat) : ShaWordMatrix.Word :=
  ⟨fun i => wire (25+32*index+i.val),wire (index+1)⟩

def previous : State ShaWordMatrix.Word :=
  ⟨input 0,input 1,input 2,input 3,input 4,input 5,input 6,input 7⟩

def heads : List ShaWordMatrix.Word := (List.range 16).map (fun i => input (i+8))

def inputGates : List Gate :=
  (List.range 24).flatMap (fun i => rangeGates (wire (i+1)) (25+32*i) 32)

def program : Step (List ShaWordMatrix.Word) := compressM previous heads 793

def returned (words : List ShaWordMatrix.Word) : List Linear :=
  words.flatMap (fun w => w.value :: List.ofFn w.bits)

def artifact : Artifact :=
  ⟨{ wires := program.next,publicCount := 24,gates := (inputGates++program.gates).toArray },returned program.value⟩

theorem checked_model {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual artifact = true)
    (values : Nat → F) (satisfied : Satisfied actual.shape values) :
    Satisfied artifact.shape values ∧ actual.outputs.map (E values) = (returned program.value).map (E values) := by
  have transfer := conformance_relation actual artifact checked values
  exact ⟨transfer.1.mp satisfied,transfer.2⟩

theorem checked_input {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual artifact = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (i : Nat) (inside : i < 24) (bits : Bits) (image : values (i+1) = (packed bits : F)) :
    Represents values (input i) (ShaWordFips.word bits) := by
  have model := (checked_model actual checked values satisfied).1
  have rangeHolds : AllHold values (rangeGates (wire (i+1)) (25+32*i) 32) := by
    intro gate member
    apply model
    simp only [artifact,List.toList_toArray,List.mem_append,inputGates,List.mem_flatMap]
    exact Or.inl ⟨i,List.mem_range.mpr inside,member⟩
  obtain ⟨decoded,rep⟩ := range_rep values one (25+32*i) (wire (i+1)) rangeHolds
  have fieldEq : (packed decoded : F) = (packed bits : F) := by
    simpa [input] using rep.2.symm.trans (by simpa using image)
  have aBound := Nat.lt_trans (packed_bound decoded) (RangeConstraints.power_below_modulus 32 (by decide))
  have bBound := Nat.lt_trans (packed_bound bits) (RangeConstraints.power_below_modulus 32 (by decide))
  have same := packed_injective decoded bits
    ((IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp fieldEq)
  exact ⟨bits,by simpa [input,same] using rep,rfl⟩

theorem checked_compression {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual artifact = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (reference : State Sha256.Word) (state : StateRep values previous reference)
    (refs : List Sha256.Word) (message : Related (Represents values) heads refs) :
    Related (Represents values) program.value (compressRef reference refs) ∧
      actual.outputs.map (E values) = (returned program.value).map (E values) := by
  have transfer := checked_model actual checked values satisfied
  have gates : AllHold values program.gates := by
    intro gate member
    exact transfer.1 gate (by simp only [artifact,List.toList_toArray,List.mem_append]; exact Or.inr member)
  exact ⟨(compressM_sound values one previous reference state heads refs message).run 793 gates,transfer.2⟩

theorem checked_fips {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual artifact = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (reference : State Sha256.Word) (state : StateRep values previous reference)
    (block : List Sha256.Byte) (message : Related (Represents values) heads (blockHeads block)) :
    Related (Represents values) program.value (Sha256.compress reference.toList block) := by
  have correct := (checked_compression actual checked values one satisfied reference state _ message).1
  rwa [compressRef_fips] at correct

def inputState (bits : Nat → Bits) : State Sha256.Word :=
  ⟨ShaWordFips.word (bits 0),ShaWordFips.word (bits 1),ShaWordFips.word (bits 2),ShaWordFips.word (bits 3),
   ShaWordFips.word (bits 4),ShaWordFips.word (bits 5),ShaWordFips.word (bits 6),ShaWordFips.word (bits 7)⟩

def inputHeads (bits : Nat → Bits) : List Sha256.Word :=
  (List.range 16).map (fun i => ShaWordFips.word (bits (i+8)))

private theorem related_maps (r : α → β → Prop) (xs : List γ) (f : γ → α) (g : γ → β)
    (h : ∀ i ∈ xs, r (f i) (g i)) : Related r (xs.map f) (xs.map g) := by
  induction xs with
  | nil => exact .nil
  | cons x xs ih => exact .cons (h x (by simp)) (ih (by intro i hi; exact h i (by simp [hi])))

theorem checked_public_inputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual artifact = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (bits : Nat → Bits) (images : ∀ i, i < 24 → values (i+1) = (packed (bits i) : F)) :
    Related (Represents values) program.value (compressRef (inputState bits) (inputHeads bits)) ∧
      actual.outputs.map (E values) = (returned program.value).map (E values) := by
  have represented (i : Nat) (inside : i < 24) :=
    checked_input actual checked values one satisfied i inside (bits i) (images i inside)
  have state : StateRep values previous (inputState bits) :=
    ⟨represented 0 (by decide),represented 1 (by decide),represented 2 (by decide),represented 3 (by decide),
     represented 4 (by decide),represented 5 (by decide),represented 6 (by decide),represented 7 (by decide)⟩
  have message : Related (Represents values) heads (inputHeads bits) := by
    apply related_maps
    intro i member
    exact represented (i+8) (by have bound := List.mem_range.mp member; omega)
  exact checked_compression actual checked values one satisfied _ state _ message

#print axioms checked_input
#print axioms checked_compression
#print axioms checked_fips
#print axioms checked_public_inputs

end ZkBuild.ShaCompression
