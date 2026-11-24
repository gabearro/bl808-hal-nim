import SourceProgram
set_option autoImplicit false
namespace ZkBuild.SourceProgramSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix SourceProgram
attribute [local instance] Ring.intCast Semiring.natCast

theorem normalized_inputs {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (xs ys : List Linear) (same : ModuleProgram.sameInputs xs ys) :
    xs.map (E values) = ys.map (E values) := by
  have h := congrArg (List.map (fun l => R1CS.eval values (interpretLinear (F := F) l))) same
  change xs.map (fun l => R1CS.eval values (interpretLinear l)) = ys.map (fun l => R1CS.eval values (interpretLinear l))
  simpa only [List.map_map,Function.comp_def,normalized_linear_same_field] using h

theorem active_read {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (c : Contract)
    (kind : c.kind = 0) (small : c.first < 7) (checked : checkContract matrix tokens splits c = true)
    (active position expected : Linear) (inputs : c.inputs = [active,position,expected])
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values active = 1) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ∃ start length, start < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity c.first ∧ start+length ≤ message.length ∧
      E values position = (start : F) ∧ E values (tokens.getD c.block.index default).length = (length : F) ∧
      E values expected = (TokenInteger.decode c.first length (fun i => (message.getD (start+i) 0).toNat) : F) := by
  have parts := checked
  simp only [checkContract,kind] at parts
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).1
  have good := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).2
  have image := normalized_inputs values c.inputs _ facts.2.2.2.2.2
  rw [inputs] at image
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at image
  have inside : tokens.getD c.block.index default ∈ tokens := by
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem facts.1
  obtain ⟨start,length,pb,positive,bounded,within,pi,li,vi⟩ :=
    TokenApplications.active_value matrix (tokens.getD c.block.index default) good values oneValue satisfied
      c.first small facts.2.1 (by rw [← image.1]; exact enabled) message (decoded _ inside)
  exact ⟨start,length,pb,positive,bounded,within,image.2.1.trans pi,li,image.2.2.trans vi⟩

theorem active_variant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (c : Contract)
    (kind : c.kind = 0) (format : c.first = 7) (checked : checkContract matrix tokens splits c = true)
    (mode position expected : Linear) (inputs : c.inputs = [mode,position,expected])
    (actual : Nat) (small : actual < 7)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values mode = ((actual+1 : Nat) : F)) (message : List Sha256.Byte)
    (decoded : ∀ t ∈ tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ∃ start length, start < 2^32 ∧ 0 < length ∧ length ≤ BinaryTokenMatrix.capacity actual ∧ start+length ≤ message.length ∧
      E values position = (start : F) ∧ E values (tokens.getD c.block.index default).length = (length : F) ∧
      E values expected = (TokenInteger.decode actual length (fun i => (message.getD (start+i) 0).toNat) : F) := by
  have parts := checked
  simp only [checkContract,kind] at parts
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).1
  have good := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).2
  have image := normalized_inputs values c.inputs _ facts.2.2.2.2.2
  rw [inputs] at image
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at image
  let t := tokens.getD c.block.index default
  have inside : t ∈ tokens := by
    unfold t
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem facts.1
  have tk : t.kind = 7 := facts.2.1.trans format
  have modeImage : E values t.activeMode = ((actual+1 : Nat) : F) := image.1.symm.trans enabled
  obtain ⟨length,positive,short,lengthImage,_⟩ := BinaryVariantFormat.checked_length matrix t good tk actual small values oneValue satisfied modeImage
  obtain ⟨start,len,pb,lb,pi,li,body⟩ := decoded t inside
  have capacity : BinaryTokenMatrix.capacity actual ≤ 10 := by unfold BinaryTokenMatrix.capacity; grind
  have same : length = len := BinaryTokenDecoded.small_nat_unique length len (by omega) (by omega) (lengthImage.symm.trans li)
  subst len
  rcases body with absent | ⟨selected,sb,_,_,within,value,selection⟩
  · omega
  · have selectedEq : selected = actual := by
      rcases selection with variant | normal
      · have n := DeclarationLocations.natural_equal (F := F) (selected+1) (actual+1) (by omega) (by omega) (variant.2.symm.trans modeImage)
        omega
      · omega
    subst selected
    exact ⟨start,length,pb,positive,short,within,image.2.1.trans pi,lengthImage,image.2.2.trans value⟩

theorem active_byte {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (c : Contract)
    (kind : c.kind = 0) (format : c.first = 0) (checked : checkContract matrix tokens splits c = true)
    (active position value : Linear) (inputs : c.inputs = [active,position,value])
    (expected : Nat) (bounded : expected < 256)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values active = 1) (image : E values value = (expected : F))
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ start length, BinaryTokenSound.Result values t message start length) :
    ∃ start, start < 2^32 ∧ start < message.length ∧ (message.getD start 0).toNat = expected ∧
      E values position = (start : F) ∧ E values (tokens.getD c.block.index default).length = 1 := by
  obtain ⟨start,length,pb,positive,short,within,pi,li,vi⟩ := active_read matrix tokens splits c kind
    (by omega) checked active position value inputs values oneValue satisfied enabled message decoded
  have one : length = 1 := by
    have bound : length ≤ 1 := by simpa [format,BinaryTokenMatrix.capacity] using short
    omega
  subst length
  rw [format,EnvelopeSound.decode_byte _ (message.getD start 0).isLt] at vi
  have byte := DeclarationLocations.natural_equal (F := F) _ expected (by have h := (message.getD start 0).isLt; omega) (by omega) (vi.symm.trans image)
  exact ⟨start,pb,by omega,byte,pi,by simpa only [Semiring.natCast_one] using li⟩

theorem packed_split {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (c : Contract)
    (kind : c.kind = 1) (checked : checkContract matrix tokens splits c = true)
    (value : Linear) (inputs : c.inputs = [value])
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ whole low high : Nat, whole < 2^(c.first+c.second) ∧ low < 2^c.first ∧ high < 2^c.second ∧
      E values value = (whole : F) ∧ E values (splits.getD c.block.index default).low = (low : F) ∧
      E values (splits.getD c.block.index default).high = (high : F) ∧ whole = low+2^c.first*high := by
  have parts := checked
  simp only [checkContract,kind] at parts
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).1
  have good := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts).2).2
  have image := normalized_inputs values c.inputs _ facts.2.2.2.2.2
  rw [inputs] at image
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at image
  obtain ⟨whole,low,high,bound,lb,hb,wi,li,hi,representation,_,_⟩ := PackedFields.checked_split matrix _ good values oneValue satisfied
  have lowWidth : (splits.getD c.block.index default).lowWidth = c.first := facts.2.1
  have highWidth : (splits.getD c.block.index default).highWidth = c.second := facts.2.2.1
  rw [lowWidth,highWidth] at bound
  rw [lowWidth] at lb representation
  rw [highWidth] at hb
  exact ⟨whole,low,high,bound,lb,hb,image.trans wi,li,hi,representation⟩

theorem state {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (s : State) (checked : auditState matrix tokens splits s = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ((∀ c ∈ s.base.contracts, ModuleProgramSound.Facts values c) ∧ ∀ r ∈ s.base.raw, Holds values r.value) ∧
      ∀ c ∈ s.contracts, checkContract matrix tokens splits c = true := by
  exact ⟨ModuleProgramSound.state matrix s.base (Bool.and_eq_true_iff.mp checked).1 values oneValue satisfied,
    List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2⟩

#print axioms normalized_inputs
#print axioms active_read
#print axioms active_variant
#print axioms active_byte
#print axioms packed_split
#print axioms state
end ZkBuild.SourceProgramSound
