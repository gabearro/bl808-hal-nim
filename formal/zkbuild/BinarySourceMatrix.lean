import ShaEmbedded
import BinarySource

namespace ZkBuild.BinarySourceMatrix

open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Entry where
  active : Linear
  address : Linear
  value : Linear
  deriving Inhabited, DecidableEq

structure Decoded where
  active : Bool
  value : Sha256.Byte
  deriving DecidableEq

def entry (start index : Nat) : Entry :=
  ⟨wire (start+11*index),scale (wire (start+11*index)) (Int.ofNat index),wire (start+11*index+1)⟩

def beforeActive (start index : Nat) : Linear :=
  if index = 0 then constant 1 else (entry start (index-1)).active

def beforeCount (start index : Nat) : Linear :=
  if index = 0 then constant 0 else wire (start+11*(index-1)+10)

def nextCount (start index : Nat) : Linear := wire (start+11*index+10)

def chunk (start index : Nat) : Linear :=
  (List.range' (index/31*31) (index%31+1)).foldl
    (fun acc i => acc ++ scale (entry start i).value (Int.ofNat (256^(i%31)))) (constant 0)

def rowCore (start index : Nat) : List Gate :=
  let row := entry start index
  [boolGate row.active] ++ rangeGates row.value (start+11*index+2) 8 ++
    [mulGate row.active (sub (constant 1) (beforeActive start index)) (constant 0),
     mulGate (sub (constant 1) row.active) row.value (constant 0),
     eqGate (nextCount start index) (beforeCount start index ++ row.active)]

def rowGates (start capacity index : Nat) (limbs : List Linear) : List Gate :=
  rowCore start index ++
    (if index%31 = 30 ∨ index+1 = capacity then
      [eqGate (chunk start index) (limbs.getD (index/31) (constant 0))] else [])

def gates (start capacity : Nat) (length : Linear) (limbs : List Linear) : List Gate :=
  (List.range capacity).flatMap (rowGates start capacity · limbs) ++
    [eqGate (beforeCount start capacity) length]

def entries (start capacity : Nat) : List Entry := (List.range capacity).map (entry start)

def outputs (start capacity : Nat) : List Linear :=
  (entries start capacity).flatMap (fun row => [row.active,row.address,row.value])

def artifact (start capacity : Nat) (length : Linear) (limbs : List Linear) : Artifact :=
  ⟨{ wires := start+11*capacity,gates := (gates start capacity length limbs).toArray },outputs start capacity⟩

def Meaning {F : Type} [CommRing F] (values : Nat → F) (row : Entry) (decoded : Decoded) : Prop :=
  E values row.active = (decoded.active.toNat : F) ∧ E values row.value = (decoded.value.toNat : F)

def Prefix : Bool → List Decoded → Prop
  | _,[] => True
  | previous,row::rest => (row.active = true → previous = true) ∧
    (row.active = false → row.value = 0) ∧ Prefix row.active rest

def activeCount : List Decoded → Nat
  | [] => 0
  | row::rest => row.active.toNat+activeCount rest

theorem row_sound {F : Type} [Field F] [IsCharP F scalarModulus] (values : Nat → F) (one : values 0 = 1)
    (start index : Nat) (previous : Bool)
    (previousImage : E values (beforeActive start index) = (previous.toNat : F))
    (holds : AllHold values (rowCore start index)) :
    ∃ decoded : Decoded, Meaning values (entry start index) decoded ∧
      (decoded.active = true → previous = true) ∧ (decoded.active = false → decoded.value = 0) ∧
      E values (nextCount start index) = E values (beforeCount start index)+(decoded.active.toNat : F) := by
  have boolean : E values (entry start index).active = 0 ∨ E values (entry start index).active = 1 := by
    apply boolean_sound values one
    exact holds _ (by simp [rowCore])
  obtain ⟨bit,bitImage⟩ : ∃ bit : Bool, E values (entry start index).active = (bit.toNat : F) := by
    rcases boolean with zero | unit
    · exact ⟨false,by simpa using zero⟩
    · exact ⟨true,by simpa using unit⟩
  have rangeH : AllHold values (rangeGates (entry start index).value (start+11*index+2) 8) := by
    intro gate member
    exact holds gate (by simp only [rowCore,List.mem_append,List.mem_singleton]; exact Or.inl (Or.inr member))
  obtain ⟨n,bound,image⟩ := range_sound values one _ _ _ rangeH
  let byte : Sha256.Byte := BitVec.ofNat 8 n
  have byteImage : E values (entry start index).value = (byte.toNat : F) := by
    simpa only [byte,BitVec.toNat_ofNat,Nat.mod_eq_of_lt bound] using image
  have prefixGate := holds (mulGate (entry start index).active
    (sub (constant 1) (beforeActive start index)) (constant 0)) (by simp [rowCore])
  have zeroGate := holds (mulGate (sub (constant 1) (entry start index).active)
    (entry start index).value (constant 0)) (by simp [rowCore])
  have countGate := holds (eqGate (nextCount start index)
    (beforeCount start index ++ (entry start index).active)) (by simp [rowCore])
  have count := equality_sound values one _ _ countGate
  refine ⟨⟨bit,byte⟩,⟨bitImage,byteImage⟩,?_,?_,?_⟩
  · intro active
    change bit = true at active
    change E values (entry start index).active * E values (sub (constant 1) (beforeActive start index)) =
      E values (constant 0) at prefixGate
    rw [eval_sub,eval_constant values one,eval_constant values one,previousImage,bitImage,active] at prefixGate
    cases previous <;> simp_all
    grind
  · intro inactive
    change bit = false at inactive
    change E values (sub (constant 1) (entry start index).active) * E values (entry start index).value =
      E values (constant 0) at zeroGate
    rw [eval_sub,eval_constant values one,eval_constant values one,bitImage,inactive] at zeroGate
    simp only [Bool.toNat_false,Semiring.natCast_zero,Ring.intCast_zero,Ring.intCast_one] at zeroGate
    have zero : E values (entry start index).value = 0 := by grind
    have nZero : n = 0 := by
      have castZero : (n : F) = 0 := image.symm.trans zero
      have small : n < scalarModulus := Nat.lt_trans bound (by decide)
      exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small (by decide : 0 < scalarModulus)).mp
        (by simpa using castZero)
    apply BitVec.eq_of_toNat_eq
    simp [byte,nZero]
  · simpa only [E,FullMatrix.eval_append,bitImage] using count


theorem beforeActive_succ (start index : Nat) : beforeActive start (index+1) = (entry start index).active := by
  simp [beforeActive]

theorem beforeCount_succ (start index : Nat) : beforeCount start (index+1) = nextCount start index := by
  simp [beforeCount,nextCount]

theorem row_holds {F : Type} [CommRing F] (values : Nat → F) (start capacity index : Nat)
    (length : Linear) (limbs : List Linear) (inside : index < capacity)
    (holds : AllHold values (gates start capacity length limbs)) :
    AllHold values (rowCore start index) := by
  intro gate member
  apply holds
  apply List.mem_append_left
  apply List.mem_flatMap.mpr
  exact ⟨index,List.mem_range.mpr inside,List.mem_append_left _ member⟩

theorem decode_suffix {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (start capacity : Nat) (length : Linear) (limbs : List Linear)
    (holds : AllHold values (gates start capacity length limbs))
    (remaining offset n : Nat) (previous : Bool) (inside : offset+remaining ≤ capacity)
    (previousImage : E values (beforeActive start offset) = (previous.toNat : F))
    (countImage : E values (beforeCount start offset) = (n : F)) :
    ∃ decoded : List Decoded, decoded.length = remaining ∧ Prefix previous decoded ∧
      Related (Meaning values) ((List.range' offset remaining).map (entry start)) decoded ∧
      E values (beforeCount start (offset+remaining)) = ((n+activeCount decoded : Nat) : F) := by
  induction remaining generalizing offset n previous with
  | zero => exact ⟨[],rfl,True.intro,.nil,by simpa [activeCount] using countImage⟩
  | succ remaining ih =>
    obtain ⟨head,headMeaning,canActivate,zeroInactive,countNext⟩ :=
      row_sound values one start offset previous previousImage
        (row_holds values start capacity offset length limbs (by omega) holds)
    have nextActive : E values (beforeActive start (offset+1)) = (head.active.toNat : F) := by
      simpa only [beforeActive_succ] using headMeaning.1
    have nextCountImage : E values (beforeCount start (offset+1)) = ((n+head.active.toNat : Nat) : F) := by
      rw [beforeCount_succ,countNext,countImage,Semiring.natCast_add]
    obtain ⟨tail,tailLength,tailPrefix,tailMeaning,finalCount⟩ :=
      ih (offset+1) (n+head.active.toNat) head.active (by omega) nextActive nextCountImage
    refine ⟨head::tail,by simp [tailLength],⟨canActivate,zeroInactive,tailPrefix⟩,?_,?_⟩
    · simpa only [List.range'_succ,List.map_cons] using Related.cons headMeaning tailMeaning
    · simpa only [activeCount,Nat.add_assoc,Nat.add_comm 1] using finalCount

def live (message : List Sha256.Byte) : List Decoded := message.map (fun value => ⟨true,value⟩)
def stored (message : List Sha256.Byte) (capacity : Nat) : List Decoded :=
  live message ++ List.replicate (capacity-message.length) ⟨false,0⟩

theorem prefix_message (previous : Bool) (rows : List Decoded) (ordered : Prefix previous rows) :
    ∃ message : List Sha256.Byte, message.length ≤ rows.length ∧
      (previous = false → message = []) ∧ rows = stored message rows.length := by
  induction rows generalizing previous with
  | nil => exact ⟨[],by simp,by simp,rfl⟩
  | cons row rest ih =>
    cases row with
    | mk active value =>
      cases active with
      | false =>
        obtain ⟨message,bound,inactive,reconstruct⟩ := ih false ordered.2.2
        have empty := inactive rfl
        have zeroValue := ordered.2.1 rfl
        change value = 0 at zeroValue
        subst message
        subst value
        refine ⟨[],by simp,by simp,?_⟩
        simp only [stored,live,List.map_nil,List.nil_append,List.length_nil,Nat.sub_zero] at reconstruct ⊢
        simpa only [List.length_cons,List.replicate_succ] using congrArg (List.cons (Decoded.mk false 0)) reconstruct
      | true =>
        obtain ⟨message,bound,inactive,reconstruct⟩ := ih true ordered.2.2
        refine ⟨value::message,by simp; omega,?_,?_⟩
        · intro off
          have on := ordered.1 rfl
          rw [off] at on
          contradiction
        · simp only [stored,live] at reconstruct
          simpa only [stored,live,List.map_cons,List.cons_append,List.length_cons,Nat.add_sub_add_right] using
            congrArg (List.cons (Decoded.mk true value)) reconstruct

theorem activeCount_append (a b : List Decoded) : activeCount (a++b) = activeCount a+activeCount b := by
  induction a with
  | nil => simp [activeCount]
  | cons head tail ih => simp only [List.cons_append,activeCount,ih,Nat.add_assoc]

theorem activeCount_stored (message : List Sha256.Byte) (capacity : Nat) :
    activeCount (stored message capacity) = message.length := by
  have on (xs : List Sha256.Byte) : activeCount (live xs) = xs.length := by
    induction xs with
    | nil => rfl
    | cons x xs ih => simpa [live,activeCount,Nat.add_comm] using ih
  have off (n : Nat) : activeCount (List.replicate n ⟨false,0⟩) = 0 := by
    induction n with
    | zero => rfl
    | succ n ih => simpa [List.replicate_succ,activeCount] using ih
  simp only [stored,activeCount_append,on,off,Nat.add_zero]


theorem stored_getD (message : List Sha256.Byte) (capacity index : Nat) :
    (stored message capacity).getD index ⟨false,0⟩ =
      if index < message.length then ⟨true,message.getD index 0⟩ else ⟨false,0⟩ := by
  by_cases before : index < message.length
  · have inside : index < (live message).length := by simpa [live] using before
    rw [stored,List.getD_eq_getElem?_getD,List.getElem?_append_left inside]
    simp only [live,List.getElem?_map,List.getD_eq_getElem?_getD,ite_eq_left before]
    cases found : message[index]? with
    | none => have bad := List.getElem?_eq_none_iff.mp found; omega
    | some byte => rfl
  · have outside : (live message).length ≤ index := by simp [live]; omega
    simp only [stored,List.getD_eq_getElem?_getD,List.getElem?_append_right outside,List.getElem?_replicate,
      ite_eq_right before]
    split <;> rfl

def emptyEntry : Entry := ⟨constant 0,constant 0,constant 0⟩

theorem emptyMeaning {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1) :
    Meaning values emptyEntry ⟨false,0⟩ := by
  simp [Meaning,emptyEntry,eval_constant values one]


def Message {F : Type} [CommRing F] (values : Nat → F) (start capacity : Nat)
    (length : Linear) (message : List Sha256.Byte) : Prop :=
  message.length ≤ capacity ∧ E values length = (message.length : F) ∧
    ∀ index, index < capacity →
      E values (entry start index).active = (if index < message.length then 1 else 0) ∧
      E values (entry start index).value = ((message.getD index 0).toNat : F) ∧
      E values (entry start index).address = (if index < message.length then (index : F) else 0)

theorem source_message {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (start capacity : Nat) (length : Linear) (limbs : List Linear)
    (holds : AllHold values (gates start capacity length limbs)) :
    ∃ message : List Sha256.Byte, Message values start capacity length message := by
  obtain ⟨decoded,size,prefixRows,representation,count⟩ := decode_suffix values one start capacity length limbs holds
    capacity 0 0 true (by omega) (by simp [beforeActive,eval_constant values one])
      (by simp [beforeCount,eval_constant values one])
  obtain ⟨message,bounded,_,reconstruct⟩ := prefix_message true decoded prefixRows
  have finish := equality_sound values one (beforeCount start capacity) length
    (holds _ (List.mem_append_right _ (by simp)))
  refine ⟨message,by omega,?_,?_⟩
  · have countValue : activeCount decoded = message.length := by rw [reconstruct,activeCount_stored]
    simp only [Nat.zero_add] at count
    simpa only [countValue] using finish.symm.trans count
  · intro index inside
    have represented := related_getD (Meaning values) _ _ representation emptyEntry ⟨false,0⟩ (emptyMeaning values one) index
    have wireAt : ((List.range' 0 capacity).map (entry start)).getD index emptyEntry = entry start index := by
      simp [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_range' (by simpa using inside)]
    rw [wireAt,reconstruct,stored_getD] at represented
    by_cases before : index < message.length
    · rw [ite_eq_left before] at represented
      refine ⟨?_,represented.2,?_⟩
      · simpa [before] using represented.1
      · simp only [entry,E,FullMatrix.eval_scale]
        rw [show ((Int.ofNat index : Int) : F) = (index : F) from Ring.intCast_natCast index]
        have active : E values (wire (start+11*index)) = 1 := by simpa [entry] using represented.1
        simp only [ite_eq_left before]
        change (index : F)*E values (wire (start+11*index)) = (index : F)
        rw [active]
        grind
    · rw [ite_eq_right before] at represented
      have absent : message[index]? = none := List.getElem?_eq_none_iff.mpr (by omega)
      refine ⟨?_,?_,?_⟩
      · simpa [before] using represented.1
      · simpa only [List.getD_eq_getElem?_getD,absent,Option.getD_none] using represented.2
      · simp only [entry,E,FullMatrix.eval_scale]
        rw [show ((Int.ofNat index : Int) : F) = (index : F) from Ring.intCast_natCast index]
        have active : E values (wire (start+11*index)) = 0 := by simpa [entry] using represented.1
        simp only [ite_eq_right before]
        change (index : F)*E values (wire (start+11*index)) = 0
        rw [active]
        grind



theorem source_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (start capacity : Nat) (length : Linear) (capacityBound : capacity < 2^32)
    (a b : List Sha256.Byte) (first : Message values start capacity length a)
    (second : Message values start capacity length b) : a = b := by
  have prime : 2^32 < scalarModulus := by decide
  have aBound : a.length ≤ capacity := first.1
  have bBound : b.length ≤ capacity := second.1
  have lengths : a.length = b.length :=
    (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp
      (first.2.1.symm.trans second.2.1)
  apply List.ext_getElem lengths
  intro i ai bi
  rw [List.getElem_eq_getD (0 : Sha256.Byte),List.getElem_eq_getD (0 : Sha256.Byte)]
  apply BitVec.eq_of_toNat_eq
  have left := (first.2.2 i (by omega)).2.1
  have right := (second.2.2 i (by omega)).2.1
  apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans (a.getD i 0).isLt (by decide)) (Nat.lt_trans (b.getD i 0).isLt (by decide))).mp
  exact left.symm.trans right

theorem unique_source {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (start capacity : Nat) (length : Linear) (limbs : List Linear)
    (capacityBound : capacity < 2^32) (holds : AllHold values (gates start capacity length limbs)) :
    ∃ message : List Sha256.Byte, Message values start capacity length message ∧
      ∀ other, Message values start capacity length other → other = message := by
  obtain ⟨message,meaning⟩ := source_message values one start capacity length limbs holds
  exact ⟨message,meaning,fun other h => source_unique values start capacity length capacityBound other message h meaning⟩

def packedChunk (message : List Sha256.Byte) (index : Nat) : Nat :=
  (List.range' (index/31*31) (index%31+1)).foldl
    (fun acc i => acc+(message.getD i 0).toNat*256^(i%31)) 0

theorem eval_chunk {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (start index : Nat) (message : List Sha256.Byte)
    (images : ∀ i, i ≤ index → E values (entry start i).value = ((message.getD i 0).toNat : F)) :
    E values (chunk start index) = (packedChunk message index : F) := by
  have fold (indices : List Nat) (wireAcc : Linear) (number : Nat)
      (accImage : E values wireAcc = (number : F))
      (bounds : ∀ i ∈ indices, i ≤ index) :
      E values (indices.foldl (fun acc i => acc ++ scale (entry start i).value (Int.ofNat (256^(i%31)))) wireAcc) =
        ((indices.foldl (fun acc i => acc+(message.getD i 0).toNat*256^(i%31)) number : Nat) : F) := by
    induction indices generalizing wireAcc number with
    | nil => exact accImage
    | cons i rest ih =>
      simp only [List.foldl_cons]
      apply ih _ _ ?_ (by intro j member; exact bounds j (by simp [member]))
      have value := images i (bounds i (by simp))
      simp only [E,FullMatrix.eval_append,FullMatrix.eval_scale]
      rw [show ((Int.ofNat (256^(i%31)) : Int) : F) = ((256^(i%31) : Nat) : F) from Ring.intCast_natCast _]
      simpa only [accImage,Semiring.natCast_add,Semiring.natCast_mul,CommSemiring.mul_comm] using
        congrArg (fun x => (number : F)+((256^(i%31) : Nat) : F)*x) value
  unfold chunk packedChunk
  apply fold _ _ 0 (by simp [eval_constant values one])
  intro i member
  have interval := List.mem_range'_1.mp member
  have divide := Nat.mod_add_div index 31
  omega

theorem packed_claim {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (start capacity : Nat) (length : Linear) (limbs : List Linear)
    (holds : AllHold values (gates start capacity length limbs))
    (message : List Sha256.Byte)
    (images : ∀ i, i < capacity → E values (entry start i).value = ((message.getD i 0).toNat : F))
    (index : Nat) (inside : index < capacity) (boundary : index%31 = 30 ∨ index+1 = capacity) :
    E values (limbs.getD (index/31) (constant 0)) = (packedChunk message index : F) := by
  have packedGate : Holds values (eqGate (chunk start index) (limbs.getD (index/31) (constant 0))) := by
    apply holds
    apply List.mem_append_left
    apply List.mem_flatMap.mpr
    refine ⟨index,List.mem_range.mpr inside,?_⟩
    simp only [rowGates,ite_eq_left boundary,List.mem_append,List.mem_singleton]
    exact Or.inr trivial
  have equal := equality_sound values one _ _ packedGate
  exact equal.symm.trans (eval_chunk values one start index message (by intro i bound; exact images i (by omega)))

#print axioms row_sound
#print axioms decode_suffix
#print axioms prefix_message
#print axioms source_message
#print axioms source_unique
#print axioms unique_source
#print axioms packed_claim

end ZkBuild.BinarySourceMatrix
