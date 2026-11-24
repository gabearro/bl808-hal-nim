import MemoryRows

namespace ZkBuild.MemoryEmbedded

open Lean.Grind CircuitShape FullMatrix GadgetShape MemoryEvidence MemoryRows MemoryTrace ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def checkInputs (matrix : Shape) (addressBits valueBits offset : Nat) : List AccessRef → Bool
  | [] => true
  | head::tail => checkAccess matrix head addressBits valueBits &&
    decide (head.fields.clock = constant (Int.ofNat offset)) && checkInputs matrix addressBits valueBits (offset+1) tail

theorem inputs_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (addressBits timeBits valueBits offset : Nat) (inputs : List AccessRef)
    (checked : checkInputs matrix addressBits valueBits offset inputs = true)
    (timeBound : offset+inputs.length ≤ 2^timeBits)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ decoded : List Entry,
      Related (MemoryPacking.Represents values) (inputs.map AccessRef.fields) decoded ∧
      (∀ entry ∈ decoded, MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) entry) ∧
      decoded.map Entry.time = List.range' offset inputs.length := by
  induction inputs generalizing offset with
  | nil => exact ⟨[],.nil,by simp,rfl⟩
  | cons head tail ih =>
    have parts : checkAccess matrix head addressBits valueBits = true ∧
        head.fields.clock = constant (Int.ofNat offset) ∧ checkInputs matrix addressBits valueBits (offset+1) tail = true := by
      simpa only [checkInputs,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using checked
    have clock : E values head.fields.clock = (offset : F) := by
      rw [parts.2.1,eval_constant values one]
      exact Ring.intCast_natCast _
    obtain ⟨entry,image,addressBound,valueBound,time,_⟩ := access_sound matrix head addressBits valueBits offset parts.1 values one satisfied clock
    obtain ⟨decoded,images,bounds,times⟩ := ih (offset+1) parts.2.2 (by simp only [List.length_cons] at timeBound; omega)
    refine ⟨entry::decoded,.cons image images,?_,?_⟩
    · intro row member
      rcases List.mem_cons.mp member with rfl | later
      · exact ⟨addressBound,by simp only [List.length_cons] at timeBound; rw [time]; omega,valueBound⟩
      · exact bounds row later
    · simp only [List.map_cons,List.length_cons,List.range'_succ,time,times]

theorem packed_images {F : Type} [CommRing F] (values : Nat → F) (addressBits timeBits valueBits : Nat)
    (accesses : List MemoryPacking.Access) (entries : List Entry)
    (represented : Related (MemoryPacking.Represents values) accesses entries) :
    (accesses.map (MemoryPacking.pack timeBits valueBits)).map (E values) =
      entries.map (fun entry => (MemoryPacking.encode addressBits timeBits valueBits entry : F)) := by
  induction represented with
  | nil => rfl
  | @cons access entry accesses entries head tail ih =>
    simp only [List.map_cons,MemoryPacking.pack_sound values addressBits timeBits valueBits access entry head,ih]

structure Record where
  addressBits : Nat
  timeBits : Nat
  valueBits : Nat
  inputs : List AccessRef
  rows : List RowRef
  network : PermutationEmbedded.Record
  deriving Inhabited

def check (matrix : Shape) (r : Record) : Bool :=
  decide (1 ≤ r.addressBits ∧ r.addressBits ≤ 64 ∧ 1 ≤ r.valueBits ∧ r.valueBits ≤ 64 ∧ r.timeBits ≤ 64 ∧
    r.valueBits+2+r.timeBits+r.addressBits ≤ 248 ∧ r.inputs.length = 2^r.timeBits ∧
    r.network.depth = r.timeBits ∧ r.network.inputs.map normalizeLinear = ((r.inputs.map AccessRef.fields).map (MemoryPacking.pack r.timeBits r.valueBits)).map normalizeLinear) &&
  checkInputs matrix r.addressBits r.valueBits 0 r.inputs && PermutationEmbedded.check matrix r.network &&
  checkRows matrix r.addressBits r.timeBits r.valueBits none r.rows r.network.outputs

theorem checked_memory {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ chronological sorted : List Entry,
      Related (MemoryPacking.Represents values) (r.inputs.map AccessRef.fields) chronological ∧
      Related (MemoryPacking.Represents values) (r.rows.map (fun row => row.access.fields)) sorted ∧
      chronological.Perm sorted ∧ Reads (fun _ => none) chronological ∧
      (∀ row ∈ chronological, MemoryConstraints.Bounded (2^r.addressBits) (2^r.timeBits) (2^r.valueBits) row) ∧
      (∀ row ∈ sorted, MemoryConstraints.Bounded (2^r.addressBits) (2^r.timeBits) (2^r.valueBits) row) ∧
      chronological.map Entry.time = List.range chronological.length := by
  have parts :
      (1 ≤ r.addressBits ∧ r.addressBits ≤ 64 ∧ 1 ≤ r.valueBits ∧ r.valueBits ≤ 64 ∧ r.timeBits ≤ 64 ∧
        r.valueBits+2+r.timeBits+r.addressBits ≤ 248 ∧ r.inputs.length = 2^r.timeBits ∧
        r.network.depth = r.timeBits ∧ r.network.inputs.map normalizeLinear = ((r.inputs.map AccessRef.fields).map (MemoryPacking.pack r.timeBits r.valueBits)).map normalizeLinear) ∧
      checkInputs matrix r.addressBits r.valueBits 0 r.inputs = true ∧
      PermutationEmbedded.check matrix r.network = true ∧
      checkRows matrix r.addressBits r.timeBits r.valueBits none r.rows r.network.outputs = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using checked
  obtain ⟨_,_,_,_,_,small,size,_,networkInputs⟩ := parts.1
  obtain ⟨chronological,inputs,chronoBounds,times⟩ := inputs_sound matrix r.addressBits r.timeBits r.valueBits 0 r.inputs
    parts.2.1 (by omega) values one satisfied
  obtain ⟨sorted,outputs,sortedBounds,outputImage,gates⟩ := rows_sound matrix r.addressBits r.timeBits r.valueBits none none r.rows
    r.network.outputs parts.2.2.2 values one satisfied True.intro
  have inputImage : r.network.inputs.map (E values) = chronological.map
      (fun entry => (MemoryPacking.encode r.addressBits r.timeBits r.valueBits entry : F)) := by
    have normalized := congrArg (List.map (fun linear => E values (linear : Linear))) networkInputs
    have same : r.network.inputs.map (E values) =
        ((r.inputs.map AccessRef.fields).map (MemoryPacking.pack r.timeBits r.valueBits)).map (E values) := by
      change r.network.inputs.map (fun l => R1CS.eval values (interpretLinear l)) =
        ((r.inputs.map AccessRef.fields).map (MemoryPacking.pack r.timeBits r.valueBits)).map
          (fun l => R1CS.eval values (interpretLinear l))
      simpa only [List.map_map,Function.comp_def,E,FullMatrix.evalLinear,normalized_linear_same_field] using normalized
    exact same.trans (packed_images values _ _ _ _ _ inputs)
  have exactTimes : chronological.map Entry.time = List.range chronological.length := by
    have length : r.inputs.length = chronological.length := by simpa using related_length _ _ _ inputs
    simpa [List.range_eq_range',length] using times
  have permutation := MemoryPermutation.checked_records matrix r.network parts.2.2.1 values one satisfied r.addressBits r.timeBits
    r.valueBits small chronological sorted chronoBounds sortedBounds inputImage outputImage
  have reads := MemoryPermutation.checked_reads matrix r.network parts.2.2.1 values one satisfied r.addressBits r.timeBits r.valueBits
    small chronological sorted chronoBounds sortedBounds exactTimes inputImage outputImage gates
  exact ⟨chronological,sorted,inputs,outputs,permutation,reads,chronoBounds,sortedBounds,exactTimes⟩

#print axioms inputs_sound
#print axioms checked_memory

end ZkBuild.MemoryEmbedded
