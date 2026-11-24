import GadgetShape
import Sha256

namespace ZkBuild.ShaWordMatrix

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Bits := Fin 32 → Bool

structure Word where
  bits : Fin 32 → Linear
  value : Linear

structure Fragment where
  word : Word
  gates : List Gate
  next : Nat

def packed (bits : Bits) : Nat := BitPacking.packBits (List.ofFn bits)
def pack (bits : Fin 32 → Linear) : Linear :=
  constant 0 ++ GadgetShape.pack (BitPacking.bitWeights 32) (List.ofFn bits)

def BitsRep {F : Type} [CommRing F] (values : Nat → F) (word : Word) (bits : Bits) : Prop :=
  ∀ i, E values (word.bits i) = ((bits i).toNat : F)

def Rep {F : Type} [CommRing F] (values : Nat → F) (word : Word) (bits : Bits) : Prop :=
  BitsRep values word bits ∧ E values word.value = (packed bits : F)

def xorExpr (a b product : Linear) : Linear := sub (a++b) (scale product 2)

def xor3 (start : Nat) (a b c : Word) : Fragment :=
  let ab i := xorExpr (a.bits i) (b.bits i) (wire (start+2*i.val))
  let bits i := xorExpr (ab i) (c.bits i) (wire (start+2*i.val+1))
  ⟨⟨bits,wire (start+64)⟩,
    (List.ofFn fun i : Fin 32 =>
      [mulGate (a.bits i) (b.bits i) (wire (start+2*i.val)),
       mulGate (ab i) (c.bits i) (wire (start+2*i.val+1))]).flatten ++
      [eqGate (wire (start+64)) (pack bits)],start+65⟩

def choose (start : Nat) (a b c : Word) : Fragment :=
  let bits i := c.bits i ++ wire (start+i.val)
  ⟨⟨bits,wire (start+32)⟩,
    (List.ofFn fun i : Fin 32 =>
      mulGate (a.bits i) (sub (b.bits i) (c.bits i)) (wire (start+i.val))) ++
      [eqGate (wire (start+32)) (pack bits)],start+33⟩

def majority (start : Nat) (a b c : Word) : Fragment :=
  let ab i := wire (start+2*i.val)
  let bits i := ab i ++ wire (start+2*i.val+1)
  ⟨⟨bits,wire (start+64)⟩,
    (List.ofFn fun i : Fin 32 =>
      [mulGate (a.bits i) (b.bits i) (ab i),
       mulGate (c.bits i) (xorExpr (a.bits i) (b.bits i) (ab i)) (wire (start+2*i.val+1))]).flatten ++
      [eqGate (wire (start+64)) (pack bits)],start+65⟩

def rotate (start amount : Nat) (a : Word) : Fragment :=
  ⟨⟨fun i => a.bits ⟨(i.val+amount)%32,Nat.mod_lt _ (by decide)⟩,[]⟩,[],start⟩

def shift (start amount : Nat) (a : Word) : Fragment :=
  ⟨⟨fun i => if h : i.val+amount < 32 then a.bits ⟨i.val+amount,h⟩ else constant 0,[]⟩,[],start⟩

def literal (start value : Nat) : Fragment :=
  ⟨⟨fun i => constant (Int.ofNat ((value / 2^i.val)%2)),constant (Int.ofNat value)⟩,[],start⟩

def materialize (start : Nat) (a : Word) : Fragment :=
  ⟨⟨a.bits,wire start⟩,[eqGate (wire start) (pack a.bits)],start+1⟩

def carryBits (count : Nat) : Nat := if count ≤ 1 then 0 else if count ≤ 2 then 1 else if count ≤ 4 then 2 else 3

def add (start : Nat) (words : List Word) : Fragment :=
  let width := 32+carryBits words.length
  let sum := words.foldl (fun total w => total++w.value) (constant 0)
  let bits := fun i : Fin 32 => wire (start+i.val)
  ⟨⟨bits,wire (start+width)⟩,
    rangeGates sum start width ++ [eqGate (wire (start+width)) (pack bits)],start+width+1⟩

def input (index : Nat) : Word :=
  ⟨fun i => wire (4+32*index+i.val),wire (index+1)⟩

def inputGates : List Gate :=
  (List.range 3).flatMap fun i => rangeGates (wire (i+1)) (4+32*i) 32

def operation (kind parameter : Nat) : Fragment :=
  let a := input 0; let b := input 1; let c := input 2
  match kind with
  | 0 => xor3 100 a b c
  | 1 => choose 100 a b c
  | 2 => majority 100 a b c
  | 3 => add 100 ((List.range parameter).map fun i => input (i%3))
  | 4 => rotate 100 parameter a
  | 5 => shift 100 parameter a
  | 6 => literal 100 parameter
  | _ => materialize 100 a

def artifact (kind parameter : Nat) : Artifact :=
  let f := operation kind parameter
  ⟨{ wires := f.next,publicCount := 3,gates := (inputGates++f.gates).toArray },
    f.word.value :: List.ofFn f.word.bits⟩

def literalValues : List Nat := [0,1,128,2147483647,2147483648,4294967295] ++
  (Sha256.initial++Sha256.constants).map BitVec.toNat

def cases : List (Nat × Nat) :=
  [(0,0),(1,0),(2,0)] ++ (List.range 5).map (fun i => (3,i+1)) ++
    (List.range 32).map (fun i => (4,i)) ++ (List.range 33).map (fun i => (5,i)) ++
    literalValues.map (fun i => (6,i)) ++ [(7,0)]

theorem packed_rep {F : Type} [CommRing F] (values : Nat → F) (bits : Fin 32 → Linear)
    (meaning : Bits) (represented : ∀ i, E values (bits i) = ((meaning i).toNat : F)) :
    E values (pack bits) = (packed meaning : F) := by
  have mapped : (List.ofFn bits).map (E values) = (List.ofFn meaning).map (R1CS.boolValue (F := F)) := by
    simp only [List.map_ofFn]
    congr 1
    funext i
    cases h : meaning i <;>
      simpa [R1CS.boolValue,h,Semiring.natCast_zero,Semiring.natCast_one] using represented i
  have zero : E values (constant 0) = 0 := by
    simp [E,evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,Semiring.add_zero]
  rw [pack,show E values (constant 0 ++ GadgetShape.pack (BitPacking.bitWeights 32) (List.ofFn bits)) =
      E values (constant 0) + E values (GadgetShape.pack (BitPacking.bitWeights 32) (List.ofFn bits)) from FullMatrix.eval_append ..,
    zero,AddCommMonoid.zero_add,eval_pack,mapped,R1CS.weighted_booleans]
  have length : (List.ofFn meaning).length = 32 := by simp
  simpa [packed,← length] using congrArg (fun n : Nat => (n : F))
    (BitPacking.binary_weights_encode_bits (List.ofFn meaning))

theorem finish_rep {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (word : Word) (meaning : Bits) (bits : BitsRep values word meaning)
    (binding : Holds values (eqGate word.value (pack word.bits))) : Rep values word meaning := by
  exact ⟨bits,(equality_sound values one _ _ binding).trans (packed_rep values word.bits meaning bits)⟩

theorem eval_xorExpr {F : Type} [CommRing F] (values : Nat → F) (a b p : Linear) :
    E values (xorExpr a b p) = E values a+E values b-2*E values p := by
  simp only [xorExpr,eval_sub,E,FullMatrix.eval_append,FullMatrix.eval_scale]
  grind

private theorem flatten_gate {F : Type} [CommRing F] (values : Nat → F)
    (rows : Fin 32 → List Gate) (tail : List Gate)
    (holds : AllHold values ((List.ofFn rows).flatten++tail)) (i : Fin 32) (gate : Gate)
    (member : gate ∈ rows i) : Holds values gate := by
  apply holds
  apply List.mem_append_left
  apply List.mem_flatten.mpr
  exact ⟨rows i,List.mem_ofFn.mpr ⟨i,rfl⟩,member⟩

theorem xor3_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (start : Nat) (a b c : Word) (x y z : Bits)
    (ha : BitsRep values a x) (hb : BitsRep values b y) (hc : BitsRep values c z)
    (holds : AllHold values (xor3 start a b c).gates) :
    Rep values (xor3 start a b c).word (fun i => Bool.xor (Bool.xor (x i) (y i)) (z i)) := by
  apply finish_rep values one
  · intro i
    have first := flatten_gate values _ _ holds i
      (mulGate (a.bits i) (b.bits i) (wire (start+2*i.val))) (by simp)
    have second := flatten_gate values _ _ holds i
      (mulGate (xorExpr (a.bits i) (b.bits i) (wire (start+2*i.val))) (c.bits i)
        (wire (start+2*i.val+1))) (by simp)
    have product := multiply_sound values _ _ _ first
    have ab : E values (xorExpr (a.bits i) (b.bits i) (wire (start+2*i.val))) =
        ((Bool.xor (x i) (y i)).toNat : F) := by
      rw [eval_xorExpr,product,ha i,hb i]
      have formula := Sha256.xor_formula (F := F) (x i) (y i)
      grind
    change E values (xorExpr _ _ _) = _
    rw [eval_xorExpr,multiply_sound values _ _ _ second,ab,hc i]
    have formula := Sha256.xor_formula (F := F) (Bool.xor (x i) (y i)) (z i)
    grind
  · apply holds
    simp [xor3]

theorem choose_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (start : Nat) (a b c : Word) (x y z : Bits)
    (ha : BitsRep values a x) (hb : BitsRep values b y) (hc : BitsRep values c z)
    (holds : AllHold values (choose start a b c).gates) :
    Rep values (choose start a b c).word (fun i => if x i then y i else z i) := by
  apply finish_rep values one
  · intro i
    have gate := holds (mulGate (a.bits i) (sub (b.bits i) (c.bits i)) (wire (start+i.val)))
      (List.mem_append_left _ (List.mem_ofFn.mpr ⟨i,rfl⟩))
    change E values (c.bits i++wire (start+i.val)) = _
    rw [show E values (c.bits i++wire (start+i.val)) = E values (c.bits i)+E values (wire (start+i.val)) from FullMatrix.eval_append ..]
    rw [multiply_sound values _ _ _ gate,eval_sub,ha i,hb i,hc i]
    exact Sha256.choose_formula _ _ _
  · apply holds
    simp [choose]

theorem majority_sound {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (start : Nat) (a b c : Word) (x y z : Bits)
    (ha : BitsRep values a x) (hb : BitsRep values b y) (hc : BitsRep values c z)
    (holds : AllHold values (majority start a b c).gates) :
    Rep values (majority start a b c).word (fun i => (x i && y i) || (x i && z i) || (y i && z i)) := by
  apply finish_rep values one
  · intro i
    have first := flatten_gate values _ _ holds i
      (mulGate (a.bits i) (b.bits i) (wire (start+2*i.val))) (by simp)
    have second := flatten_gate values _ _ holds i
      (mulGate (c.bits i) (xorExpr (a.bits i) (b.bits i) (wire (start+2*i.val)))
        (wire (start+2*i.val+1))) (by simp)
    have product := multiply_sound values _ _ _ first
    change E values (wire (start+2*i.val)++wire (start+2*i.val+1)) = _
    rw [show E values (wire (start+2*i.val)++wire (start+2*i.val+1)) =
      E values (wire (start+2*i.val))+E values (wire (start+2*i.val+1)) from FullMatrix.eval_append ..]
    rw [multiply_sound values _ _ _ second,eval_xorExpr,product,ha i,hb i,hc i]
    have formula := Sha256.majority_formula (F := F) (x i) (y i) (z i)
    grind
  · apply holds
    simp [majority]

theorem rotate_sound {F : Type} [CommRing F] (values : Nat → F) (start amount : Nat)
    (a : Word) (x : Bits) (ha : BitsRep values a x) :
    BitsRep values (rotate start amount a).word (fun i => x ⟨(i.val+amount)%32,Nat.mod_lt _ (by decide)⟩) := by
  intro i
  exact ha _

theorem shift_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (start amount : Nat) (a : Word) (x : Bits) (ha : BitsRep values a x) :
    BitsRep values (shift start amount a).word
      (fun i => if h : i.val+amount < 32 then x ⟨i.val+amount,h⟩ else false) := by
  intro i
  simp only [shift]
  split
  · exact ha _
  · simp [eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]

theorem materialize_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (start : Nat) (a : Word) (x : Bits) (ha : BitsRep values a x)
    (holds : AllHold values (materialize start a).gates) : Rep values (materialize start a).word x := by
  apply finish_rep values one (materialize start a).word x (by simpa [BitsRep,materialize] using ha)
  apply holds
  simp [materialize]

theorem packed_bound (bits : Bits) : packed bits < 2^32 := by
  simpa [packed] using BitPacking.packed_bits_bounded (List.ofFn bits)

theorem packed_injective (a b : Bits) (same : packed a = packed b) : a = b := by
  have lists := BitPacking.packed_bits_injective (List.ofFn a) (List.ofFn b) (by simp) same
  funext i
  have equal := congrArg (fun l : List Bool => l[i.val]?) lists
  simpa only [List.getElem?_ofFn,dite_eq_left i.isLt,Option.some.injEq] using equal

private theorem pack_append (a b : List Bool) :
    BitPacking.packBits (a++b) = BitPacking.packBits a + 2^a.length * BitPacking.packBits b := by
  induction a with
  | nil => simp [BitPacking.packBits]
  | cons x xs ih =>
    simp only [List.cons_append,BitPacking.packBits,List.length_cons,Nat.pow_succ,ih]
    simp only [Nat.mul_add]
    ac_rfl

private theorem low_mod (bits : List Bool) (wide : 32 ≤ bits.length) :
    BitPacking.packBits (bits.take 32) = BitPacking.packBits bits % 2^32 := by
  have len : (bits.take 32).length = 32 := by simp [List.length_take,Nat.min_eq_left wide]
  have lowBound : BitPacking.packBits (bits.take 32) < 2^32 := by
    simpa [len] using BitPacking.packed_bits_bounded (bits.take 32)
  have decomposition := pack_append (bits.take 32) (bits.drop 32)
  rw [List.take_append_drop,len] at decomposition
  rw [decomposition]
  simp [Nat.add_mod,Nat.mod_eq_of_lt lowBound]

private theorem low_list (bits : List Bool) (wide : 32 ≤ bits.length) :
    List.ofFn (fun i : Fin 32 => bits.getD i.val false) = bits.take 32 := by
  apply List.ext_getElem
  · simp [List.length_take,Nat.min_eq_left wide]
  · intro i h₁ h₂
    have bound : i < bits.length := by simp only [List.length_ofFn] at h₁; omega
    rw [List.getElem_ofFn,List.getElem_take]
    exact (List.getElem_eq_getD false).symm

private theorem sum_eval {F : Type} [CommRing F] (values : Nat → F) (words : List Word) (base : Linear) :
    E values (words.foldl (fun total w => total++w.value) base) =
      E values base + (words.map (fun w => E values w.value)).sum := by
  induction words generalizing base with
  | nil => simp [AddCommMonoid.add_zero]
  | cons w ws ih =>
    simp only [List.foldl_cons,List.map_cons,List.sum_cons,ih]
    rw [show E values (base++w.value) = E values base+E values w.value from FullMatrix.eval_append ..]
    grind

private theorem sum_bound (entries : List (Word × Bits)) :
    (entries.map (fun entry => packed entry.2)).sum ≤ entries.length*(2^32-1) := by
  induction entries with
  | nil => simp
  | cons entry rest ih =>
    have bound := packed_bound entry.2
    simp only [List.map_cons,List.sum_cons,List.length_cons]
    omega

private theorem sum_width (entries : List (Word × Bits)) (small : entries.length ≤ 8) :
    (entries.map (fun entry => packed entry.2)).sum < 2^(32+carryBits entries.length) := by
  have bound := sum_bound entries
  unfold carryBits
  split <;> (try split) <;> (try split) <;> omega

private theorem cast_sum {F : Type} [CommRing F] (ns : List Nat) :
    (ns.map (fun (n : Nat) => (n : F))).sum = (ns.sum : F) := by
  induction ns with
  | nil => simp [Semiring.natCast_zero]
  | cons n ns ih => simp [ih,Semiring.natCast_add]

private theorem getD_boolValues {F : Type} [CommRing F] (bits : List Bool) (i : Nat) :
    (bits.map (R1CS.boolValue (F := F))).getD i 0 = ((bits.getD i false).toNat : F) := by
  cases h : bits[i]? with
  | none => simp [List.getD_eq_getElem?_getD,h,Semiring.natCast_zero]
  | some bit => cases bit <;> simp [List.getD_eq_getElem?_getD,h,R1CS.boolValue,Semiring.natCast_zero,Semiring.natCast_one]

theorem add_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (start : Nat) (entries : List (Word × Bits))
    (small : entries.length ≤ 8) (inputs : ∀ entry ∈ entries, Rep values entry.1 entry.2)
    (holds : AllHold values (add start (entries.map Prod.fst)).gates) :
    ∃ bits : Bits, Rep values (add start (entries.map Prod.fst)).word bits ∧
      packed bits = (entries.map (fun entry => packed entry.2)).sum % 2^32 := by
  let words := entries.map Prod.fst
  let width := 32+carryBits entries.length
  let expression := words.foldl (fun total w => total++w.value) (constant 0)
  let total := (entries.map (fun entry => packed entry.2)).sum
  have sumImage : E values expression = (total : F) := by
    rw [sum_eval,eval_constant values one]
    have mapped : words.map (fun w => E values w.value) = entries.map (fun entry => (packed entry.2 : F)) := by
      simp only [words,List.map_map]
      apply List.map_congr_left
      intro entry member
      exact (inputs entry member).2
    rw [mapped]
    simp only [Ring.intCast_zero,AddCommMonoid.zero_add,total]
    simpa only [List.map_map,Function.comp_def] using cast_sum (F := F) (entries.map (fun entry => packed entry.2))
  have rangeHolds : AllHold values (rangeGates expression start width) := by
    intro gate member
    apply holds
    exact List.mem_append_left _ (by simpa [add,words,width,expression] using member)
  have cert := range_certificate values one expression start width rangeHolds
  obtain ⟨decoded,decode⟩ := R1CS.constrained_bits_are_booleans _ cert.2.1
  have decodedLength : decoded.length = width := by simpa [decode] using cert.1
  have image : (BitPacking.packBits decoded : F) = (total : F) := by
    have binding := cert.2.2
    rw [decode,R1CS.weighted_booleans,← decodedLength,BitPacking.binary_weights_encode_bits,sumImage] at binding
    exact binding
  have widthBound : width ≤ 248 := by simp only [width,carryBits]; split <;> (try split) <;> (try split) <;> omega
  have upper := RangeConstraints.power_below_modulus width widthBound
  have decodedBound : BitPacking.packBits decoded < 2^width := by
    simpa [decodedLength] using BitPacking.packed_bits_bounded decoded
  have totalBound : total < 2^width := sum_width entries small
  have equal : BitPacking.packBits decoded = total :=
    (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans decodedBound upper) (Nat.lt_trans totalBound upper)).mp image
  have wide : 32 ≤ decoded.length := by rw [decodedLength]; exact Nat.le_add_right 32 _
  let low : Bits := fun i => decoded.getD i.val false
  have bitsRep : BitsRep values (add start words).word low := by
    intro i
    have index : i.val < width := by have := i.isLt; dsimp [width]; omega
    have read := congrArg (fun bits : List F => bits.getD i.val 0) decode
    rw [getD_boolValues] at read
    simpa [rangeBits,index,low,add,words,width] using read
  refine ⟨low,?_,?_⟩
  · apply finish_rep values one _ _ bitsRep
    apply holds
    simp [add,words]
  · change BitPacking.packBits (List.ofFn low) = total % 2^32
    rw [low_list decoded wide,low_mod decoded wide,equal]

theorem range_rep {F : Type} [Field F] (values : Nat → F) (one : values 0 = 1)
    (start : Nat) (value : Linear) (holds : AllHold values (rangeGates value start 32)) :
    ∃ bits : Bits, Rep values ⟨fun i => wire (start+i.val),value⟩ bits := by
  have cert := range_certificate values one value start 32 holds
  obtain ⟨decoded,decode⟩ := R1CS.constrained_bits_are_booleans _ cert.2.1
  have length : decoded.length = 32 := by simpa [decode] using cert.1
  let bits : Bits := fun i => decoded.getD i.val false
  have list : List.ofFn bits = decoded := by
    have low := low_list decoded (by omega)
    have taken : decoded.take 32 = decoded := List.take_of_length_le (by omega)
    rw [taken] at low
    exact low
  refine ⟨bits,?_,?_⟩
  · intro i
    have read := congrArg (fun bs : List F => bs.getD i.val 0) decode
    rw [getD_boolValues] at read
    simpa [rangeBits,i.isLt,bits] using read
  · have binding := cert.2.2
    rw [decode,R1CS.weighted_booleans,← length,BitPacking.binary_weights_encode_bits] at binding
    change E values value = (BitPacking.packBits (List.ofFn bits) : F)
    rw [list]
    exact binding.symm

def encoded (F : Type) [CommRing F] (bits : Bits) : List F :=
  (packed bits : F) :: List.ofFn (fun i => ((bits i).toNat : F))

theorem rep_outputs {F : Type} [CommRing F] (values : Nat → F) (word : Word) (bits : Bits)
    (represented : Rep values word bits) :
    (word.value :: List.ofFn word.bits).map (E values) = encoded F bits := by
  simp only [List.map_cons,List.map_ofFn,encoded,represented.2]
  congr 1
  apply congrArg List.ofFn
  funext i
  exact represented.1 i

theorem checked_model {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (actual : Artifact) (kind parameter : Nat)
    (checked : conforms actual (artifact kind parameter) = true)
    (values : Nat → F) (satisfied : Satisfied actual.shape values) :
    Satisfied (artifact kind parameter).shape values ∧
      actual.outputs.map (E values) =
        ((operation kind parameter).word.value :: List.ofFn (operation kind parameter).word.bits).map (E values) := by
  have relation := conformance_relation actual (artifact kind parameter) checked values
  exact ⟨relation.1.mp satisfied,relation.2⟩

theorem checked_operation {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (actual : Artifact) (kind parameter : Nat)
    (checked : conforms actual (artifact kind parameter) = true)
    (values : Nat → F) (satisfied : Satisfied actual.shape values) :
    AllHold values (operation kind parameter).gates := by
  have model := (checked_model actual kind parameter checked values satisfied).1
  intro gate member
  exact model gate (by simp only [artifact,List.toList_toArray,List.mem_append]; exact Or.inr member)

theorem checked_input_rep {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (kind parameter : Nat)
    (checked : conforms actual (artifact kind parameter) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (index : Nat) (inside : index < 3) (bits : Bits) (image : values (index+1) = (packed bits : F)) :
    Rep values (input index) bits := by
  have model := (checked_model actual kind parameter checked values satisfied).1
  have rangeHolds : AllHold values (rangeGates (wire (index+1)) (4+32*index) 32) := by
    intro gate member
    apply model
    simp only [artifact,List.toList_toArray,List.mem_append,inputGates,List.mem_flatMap]
    exact Or.inl ⟨index,List.mem_range.mpr inside,member⟩
  obtain ⟨decoded,rep⟩ := range_rep values one (4+32*index) (wire (index+1)) rangeHolds
  have fieldEq : (packed decoded : F) = (packed bits : F) := by
    simpa [input] using rep.2.symm.trans (by simpa using image)
  have aBound := Nat.lt_trans (packed_bound decoded) (RangeConstraints.power_below_modulus 32 (by decide))
  have bBound := Nat.lt_trans (packed_bound bits) (RangeConstraints.power_below_modulus 32 (by decide))
  have same := packed_injective decoded bits
    ((IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp fieldEq)
  simpa [input,same] using rep

theorem checked_xor3 {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual (artifact 0 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (x y z : Bits) (hx : values 1 = (packed x : F)) (hy : values 2 = (packed y : F))
    (hz : values 3 = (packed z : F)) :
    actual.outputs.map (E values) = encoded F (fun i => Bool.xor (Bool.xor (x i) (y i)) (z i)) := by
  have a := checked_input_rep actual 0 0 checked values one satisfied 0 (by decide) x hx
  have b := checked_input_rep actual 0 0 checked values one satisfied 1 (by decide) y hy
  have c := checked_input_rep actual 0 0 checked values one satisfied 2 (by decide) z hz
  have gates := checked_operation actual 0 0 checked values satisfied
  have rep := xor3_sound values one 100 (input 0) (input 1) (input 2) x y z a.1 b.1 c.1 gates
  exact (checked_model actual 0 0 checked values satisfied).2.trans (rep_outputs values _ _ rep)

theorem checked_choose {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual (artifact 1 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (x y z : Bits) (hx : values 1 = (packed x : F)) (hy : values 2 = (packed y : F))
    (hz : values 3 = (packed z : F)) :
    actual.outputs.map (E values) = encoded F (fun i => if x i then y i else z i) := by
  have a := checked_input_rep actual 1 0 checked values one satisfied 0 (by decide) x hx
  have b := checked_input_rep actual 1 0 checked values one satisfied 1 (by decide) y hy
  have c := checked_input_rep actual 1 0 checked values one satisfied 2 (by decide) z hz
  have gates := checked_operation actual 1 0 checked values satisfied
  have rep := choose_sound values one 100 (input 0) (input 1) (input 2) x y z a.1 b.1 c.1 gates
  exact (checked_model actual 1 0 checked values satisfied).2.trans (rep_outputs values _ _ rep)

theorem checked_majority {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual (artifact 2 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (x y z : Bits) (hx : values 1 = (packed x : F)) (hy : values 2 = (packed y : F))
    (hz : values 3 = (packed z : F)) :
    actual.outputs.map (E values) = encoded F (fun i => (x i && y i) || (x i && z i) || (y i && z i)) := by
  have a := checked_input_rep actual 2 0 checked values one satisfied 0 (by decide) x hx
  have b := checked_input_rep actual 2 0 checked values one satisfied 1 (by decide) y hy
  have c := checked_input_rep actual 2 0 checked values one satisfied 2 (by decide) z hz
  have gates := checked_operation actual 2 0 checked values satisfied
  have rep := majority_sound values one 100 (input 0) (input 1) (input 2) x y z a.1 b.1 c.1 gates
  exact (checked_model actual 2 0 checked values satisfied).2.trans (rep_outputs values _ _ rep)

theorem checked_add {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (count : Nat) (small : count ≤ 8)
    (checked : conforms actual (artifact 3 count) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (inputs : Fin 3 → Bits) (images : ∀ i, values (i.val+1) = (packed (inputs i) : F)) :
    ∃ bits : Bits, actual.outputs.map (E values) = encoded F bits ∧
      packed bits = ((List.range count).map (fun i => packed (inputs ⟨i%3,Nat.mod_lt _ (by decide)⟩))).sum % 2^32 := by
  let entries := (List.range count).map fun i =>
    (input (i%3),inputs ⟨i%3,Nat.mod_lt _ (by decide)⟩)
  have represented : ∀ entry ∈ entries, Rep values entry.1 entry.2 := by
    intro entry member
    obtain ⟨i,_,same⟩ := List.mem_map.mp member
    subst entry
    exact checked_input_rep actual 3 count checked values one satisfied (i%3)
      (Nat.mod_lt _ (by decide)) (inputs ⟨i%3,Nat.mod_lt _ (by decide)⟩)
      (images ⟨i%3,Nat.mod_lt _ (by decide)⟩)
  have gates := checked_operation actual 3 count checked values satisfied
  have operationHolds : AllHold values (add 100 (entries.map Prod.fst)).gates := by
    simpa [operation,entries,List.map_map,Function.comp_def] using gates
  obtain ⟨bits,rep,result⟩ := add_sound values one 100 entries (by simpa [entries] using small) represented operationHolds
  have returns := (checked_model actual 3 count checked values satisfied).2
  have sameWord : (operation 3 count).word = (add 100 (entries.map Prod.fst)).word := by
    simp [operation,entries,List.map_map,Function.comp_def]
  refine ⟨bits,?_,?_⟩
  · rw [sameWord] at returns
    exact returns.trans (rep_outputs values _ _ rep)
  · simpa [entries,List.map_map,Function.comp_def] using result

def natBits (value : Nat) : Bits := fun i => decide ((value / 2^i.val)%2 = 1)

set_option maxRecDepth 10000 in
set_option maxHeartbeats 0 in
theorem literal_packed : literalValues.all (fun n => packed (natBits n) == n) = true := by decide

theorem literal_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (start value : Nat) (member : value ∈ literalValues) :
    Rep values (literal start value).word (natBits value) := by
  constructor
  · intro i
    change E values (constant (Int.ofNat ((value / 2^i.val)%2))) =
      ((decide ((value / 2^i.val)%2 = 1)).toNat : F)
    rw [eval_constant values one]
    have bound := Nat.mod_lt (value / 2^i.val) (by decide : 0 < 2)
    have cases : (value / 2^i.val)%2 = 0 ∨ (value / 2^i.val)%2 = 1 := by omega
    rcases cases with digit | digit <;>
      simp [digit,Ring.intCast_zero,Ring.intCast_one,Semiring.natCast_zero,Semiring.natCast_one]
  · have same : packed (natBits value) = value := by
      simpa using List.all_eq_true.mp literal_packed value member
    simp [literal,same,eval_constant values one,Ring.intCast_natCast]

theorem checked_literal {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (value : Nat) (member : value ∈ literalValues)
    (checked : conforms actual (artifact 6 value) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values) :
    actual.outputs.map (E values) = encoded F (natBits value) := by
  have rep := literal_sound values one 100 value member
  exact (checked_model actual 6 value checked values satisfied).2.trans (rep_outputs values _ _ rep)

theorem view_outputs {F : Type} [CommRing F] (values : Nat → F) (word : Word) (bits : Bits)
    (empty : word.value = []) (represented : BitsRep values word bits) :
    (word.value :: List.ofFn word.bits).map (E values) =
      0 :: List.ofFn (fun i => ((bits i).toNat : F)) := by
  rw [List.map_cons,List.map_ofFn,empty]
  have zero : E values [] = 0 := rfl
  rw [zero]
  congr 1
  apply congrArg List.ofFn
  funext i
  exact represented i

theorem checked_rotate {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (amount : Nat) (checked : conforms actual (artifact 4 amount) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (bits : Bits) (image : values 1 = (packed bits : F)) :
    actual.outputs.map (E values) = 0 :: List.ofFn
      (fun i : Fin 32 => ((bits ⟨(i.val+amount)%32,Nat.mod_lt _ (by decide)⟩).toNat : F)) := by
  have represented := checked_input_rep actual 4 amount checked values one satisfied 0 (by decide) bits image
  have rotated := rotate_sound values 100 amount (input 0) bits represented.1
  exact (checked_model actual 4 amount checked values satisfied).2.trans
    (view_outputs values _ _ rfl rotated)

theorem checked_shift {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (amount : Nat) (checked : conforms actual (artifact 5 amount) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (bits : Bits) (image : values 1 = (packed bits : F)) :
    actual.outputs.map (E values) = 0 :: List.ofFn
      (fun i : Fin 32 => ((if h : i.val+amount < 32 then bits ⟨i.val+amount,h⟩ else false).toNat : F)) := by
  have represented := checked_input_rep actual 5 amount checked values one satisfied 0 (by decide) bits image
  have shifted := shift_sound values one 100 amount (input 0) bits represented.1
  exact (checked_model actual 5 amount checked values satisfied).2.trans
    (view_outputs values _ _ rfl shifted)

theorem checked_materialize {F : Type} [Field F] [IsCharP F scalarModulus]
    (actual : Artifact) (checked : conforms actual (artifact 7 0) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied actual.shape values)
    (bits : Bits) (image : values 1 = (packed bits : F)) :
    actual.outputs.map (E values) = encoded F bits := by
  have represented := checked_input_rep actual 7 0 checked values one satisfied 0 (by decide) bits image
  have gates := checked_operation actual 7 0 checked values satisfied
  have rep := materialize_sound values one 100 (input 0) bits represented.1 gates
  exact (checked_model actual 7 0 checked values satisfied).2.trans (rep_outputs values _ _ rep)

#print axioms xor3_sound
#print axioms choose_sound
#print axioms majority_sound
#print axioms rotate_sound
#print axioms shift_sound
#print axioms materialize_sound
#print axioms add_sound
#print axioms checked_input_rep
#print axioms checked_xor3
#print axioms checked_choose
#print axioms checked_majority
#print axioms checked_add
#print axioms literal_sound
#print axioms checked_literal
#print axioms checked_rotate
#print axioms checked_shift
#print axioms checked_materialize

end ZkBuild.ShaWordMatrix
