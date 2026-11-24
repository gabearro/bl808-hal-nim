import MemoryEvidence

namespace ZkBuild.MemoryRows

open Lean.Grind CircuitShape FullMatrix GadgetShape MemoryEvidence MemoryTrace
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

abbrev Access := MemoryPacking.Access

def read (row : Access) : Linear := sub row.active row.write

def tailGates (addressBits timeBits valueBits start : Nat) (previous : Option Access) (row : Access) (packed : Linear) : List Gate :=
  eqGate packed (MemoryPacking.pack timeBits valueBits row) ::
    match previous with
    | none => [eqGate (read row) (constant 0)]
    | some prior =>
      let delta := sub (sub (MemoryPacking.orderKey addressBits timeBits row)
        (MemoryPacking.orderKey addressBits timeBits prior)) (constant 1)
      let same := wire (start+addressBits+timeBits+1)
      let reciprocal := wire (start+addressBits+timeBits+2)
      rangeGates delta start (addressBits+timeBits+1) ++
        zeroGates (sub row.address prior.address) same reciprocal ++
        [mulGate (read row) (sub (constant 1) same) (constant 0),
         mulGate (read row) (sub row.value prior.value) (constant 0)]

def Previous {F : Type} [CommRing F] (values : Nat → F) : Option Access → Option Entry → Prop
  | none,none => True
  | some access,some row => MemoryPacking.Represents values access row
  | _,_ => False

theorem read_image {F : Type} [CommRing F] (values : Nat → F) (row : Access) (entry : Entry)
    (image : MemoryPacking.Represents values row entry) :
    E values (read row) = MemoryConstraints.readFlag (F := F) entry := by
  simp only [read,eval_sub,image.1,image.2.1,MemoryConstraints.readFlag,MemoryConstraints.flag]
  cases entry.active <;> cases entry.write <;> simp

theorem tail_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (addressBits timeBits valueBits start : Nat)
    (previous : Option Access) (prior : Option Entry) (row : Access) (entry : Entry) (packed : Linear)
    (before : Previous values previous prior) (image : MemoryPacking.Represents values row entry)
    (holds : AllHold values (tailGates addressBits timeBits valueBits start previous row packed)) :
    E values packed = (MemoryPacking.encode addressBits timeBits valueBits entry : F) ∧
      MemoryConstraints.RowGate (F := F) (2^addressBits) (2^timeBits) prior entry := by
  have packEquation := equality_sound values one packed (MemoryPacking.pack timeBits valueBits row)
    (holds _ (by simp [tailGates]))
  refine ⟨packEquation.trans (MemoryPacking.pack_sound values addressBits timeBits valueBits row entry image),?_⟩
  cases previous with
  | none =>
    cases prior with
    | some _ => exact False.elim before
    | none =>
      have first := equality_sound values one (read row) (constant 0) (holds _ (by simp [tailGates]))
      simpa [MemoryConstraints.RowGate,read_image values row entry image,eval_constant values one] using first
  | some previous =>
    cases prior with
    | none => exact False.elim before
    | some prior =>
      have previousImage : MemoryPacking.Represents values previous prior := before
      let delta := sub (sub (MemoryPacking.orderKey addressBits timeBits row)
        (MemoryPacking.orderKey addressBits timeBits previous)) (constant 1)
      let same := wire (start+addressBits+timeBits+1)
      let reciprocal := wire (start+addressBits+timeBits+2)
      have ranges : AllHold values (rangeGates delta start (addressBits+timeBits+1)) := by
        intro gate member
        apply holds
        simp only [tailGates,List.mem_cons,List.mem_append]
        exact Or.inr (Or.inl (Or.inl member))
      obtain ⟨difference,bounded,differenceImage⟩ := GadgetShape.range_sound values one delta start _ ranges
      have order : E values delta = (MemoryConstraints.key (2^addressBits) (2^timeBits) entry : F)-
          (MemoryConstraints.key (2^addressBits) (2^timeBits) prior : F)-1 := by
        simp [delta,eval_sub,eval_constant values one,MemoryPacking.orderKey_sound values one _ _ row entry image,
          MemoryPacking.orderKey_sound values one _ _ previous prior previousImage]
      have sameGate : E values (sub row.address previous.address)*E values same = 0 := by
        have gate := holds (mulGate (sub row.address previous.address) same (constant 0)) (by simp [tailGates,zeroGates,same,mulGate])
        change E values (sub row.address previous.address)*E values same = E values (constant 0) at gate
        simpa [eval_constant values one] using gate
      have inverseGate : E values (sub row.address previous.address)*E values reciprocal = 1-E values same := by
        have gate := holds (mulGate (sub row.address previous.address) reciprocal (sub (constant 1) same))
          (by simp [tailGates,zeroGates,same,reciprocal,mulGate])
        change E values (sub row.address previous.address)*E values reciprocal = E values (sub (constant 1) same) at gate
        simpa [eval_sub,eval_constant values one] using gate
      have addressGate : E values (read row)*(1-E values same) = 0 := by
        have gate := holds (mulGate (read row) (sub (constant 1) same) (constant 0)) (by simp [tailGates,same])
        change E values (read row)*E values (sub (constant 1) same) = E values (constant 0) at gate
        simpa [eval_sub,eval_constant values one] using gate
      have valueGate : E values (read row)*E values (sub row.value previous.value) = 0 := by
        have gate := holds (mulGate (read row) (sub row.value previous.value) (constant 0)) (by simp [tailGates])
        change E values (read row)*E values (sub row.value previous.value) = E values (constant 0) at gate
        simpa [eval_constant values one] using gate
      refine ⟨E values same,E values reciprocal,difference,?_,order.symm.trans differenceImage,?_,?_,?_,?_⟩
      · simpa [Nat.pow_add,Nat.mul_assoc,Nat.mul_comm,Nat.mul_left_comm] using bounded
      · simpa only [eval_sub,image.2.2.1,previousImage.2.2.1] using sameGate
      · simpa only [eval_sub,image.2.2.1,previousImage.2.2.1] using inverseGate
      · simpa only [read_image values row entry image] using addressGate
      · simpa only [read_image values row entry image,eval_sub,image.2.2.2.1,previousImage.2.2.2.1] using valueGate

structure RowRef where
  access : AccessRef
  clock : RangeRef
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  deriving Inhabited

def checkRow (matrix : Shape) (r : RowRef) (addressBits timeBits valueBits : Nat)
    (previous : Option Access) (packed : Linear) : Bool :=
  checkAccess matrix r.access addressBits valueBits &&
  checkRange matrix r.clock r.access.fields.clock timeBits &&
  decide (r.access.lastGate ≤ r.clock.firstGate ∧ r.clock.lastGate = r.firstGate ∧ r.clock.lastWire = r.firstWire ∧
    r.lastWire = r.firstWire+(if previous.isSome then addressBits+timeBits+3 else 0) ∧ r.lastWire ≤ matrix.wires) &&
  checkSpan matrix r.firstGate r.lastGate (tailGates addressBits timeBits valueBits r.firstWire previous r.access.fields packed)

theorem row_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : RowRef) (addressBits timeBits valueBits : Nat)
    (previous : Option Access) (prior : Option Entry) (packed : Linear)
    (checked : checkRow matrix r addressBits timeBits valueBits previous packed = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before : Previous values previous prior) :
    ∃ entry : Entry, MemoryPacking.Represents values r.access.fields entry ∧
      MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) entry ∧
      E values packed = (MemoryPacking.encode addressBits timeBits valueBits entry : F) ∧
      MemoryConstraints.RowGate (F := F) (2^addressBits) (2^timeBits) prior entry := by
  have parts : checkAccess matrix r.access addressBits valueBits = true ∧
      checkRange matrix r.clock r.access.fields.clock timeBits = true ∧
      decide (r.access.lastGate ≤ r.clock.firstGate ∧ r.clock.lastGate = r.firstGate ∧ r.clock.lastWire = r.firstWire ∧
        r.lastWire = r.firstWire+(if previous.isSome then addressBits+timeBits+3 else 0) ∧ r.lastWire ≤ matrix.wires) = true ∧
      checkSpan matrix r.firstGate r.lastGate (tailGates addressBits timeBits valueBits r.firstWire previous r.access.fields packed) = true := by
    simpa only [checkRow,Bool.and_eq_true_iff,and_assoc] using checked
  obtain ⟨time,timeBound,timeImage⟩ := MemoryEvidence.range_sound matrix r.clock r.access.fields.clock timeBits parts.2.1 values one satisfied
  obtain ⟨entry,image,addressBound,valueBound,sameTime,_⟩ := access_sound matrix r.access addressBits valueBits time parts.1 values one satisfied timeImage
  have tail := tail_sound values one addressBits timeBits valueBits r.firstWire previous prior r.access.fields entry packed before image
    (span_sound matrix _ _ _ parts.2.2.2 values satisfied)
  exact ⟨entry,image,⟨addressBound,by simpa only [sameTime] using timeBound,valueBound⟩,tail⟩

def checkRows (matrix : Shape) (addressBits timeBits valueBits : Nat) (previous : Option Access) :
    List RowRef → List Linear → Bool
  | [],[] => true
  | row::rows,packed::packs => checkRow matrix row addressBits timeBits valueBits previous packed &&
      checkRows matrix addressBits timeBits valueBits (some row.access.fields) rows packs
  | _,_ => false

theorem rows_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (addressBits timeBits valueBits : Nat) (previous : Option Access) (prior : Option Entry)
    (rows : List RowRef) (packs : List Linear)
    (checked : checkRows matrix addressBits timeBits valueBits previous rows packs = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (before : Previous values previous prior) :
    ∃ decoded : List Entry,
      ShaProgram.Related (MemoryPacking.Represents values) (rows.map (fun r => r.access.fields)) decoded ∧
      (∀ entry ∈ decoded, MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) entry) ∧
      packs.map (E values) = decoded.map (fun entry => (MemoryPacking.encode addressBits timeBits valueBits entry : F)) ∧
      MemoryConstraints.Gates (F := F) (2^addressBits) (2^timeBits) prior decoded := by
  induction rows generalizing packs previous prior with
  | nil =>
    cases packs with
    | nil => exact ⟨[],.nil,by simp,rfl,True.intro⟩
    | cons _ _ => simp [checkRows] at checked
  | cons row rows ih =>
    cases packs with
    | nil => simp [checkRows] at checked
    | cons packed packs =>
      have checks := Bool.and_eq_true_iff.mp checked
      obtain ⟨entry,image,bound,packedImage,gate⟩ := row_sound matrix row addressBits timeBits valueBits previous prior packed
        checks.1 values one satisfied before
      obtain ⟨tail,tailImage,tailBound,tailPacked,tailGates⟩ := ih (some row.access.fields) (some entry) packs checks.2 image
      refine ⟨entry::tail,.cons image tailImage,?_,?_,⟨gate,tailGates⟩⟩
      · intro e member
        rcases List.mem_cons.mp member with rfl | member
        · exact bound
        · exact tailBound e member
      · simp only [List.map_cons,packedImage,tailPacked]

#print axioms tail_sound
#print axioms row_sound
#print axioms rows_sound

end ZkBuild.MemoryRows
