import FftRadix

namespace ZkBuild.FftSplit

open Lean.Grind FftStages FftLayout FftRadix

def liftBlock {blocks : Nat} (upper : Bool) (i : Fin blocks) : Fin (2*blocks) :=
  ⟨i.val + if upper then blocks else 0, by have := i.isLt; cases upper <;> simp <;> omega⟩

def doubleEmbed {blocks half : Nat} (upper : Bool) (i : Fin (blocks*(2*half))) :
    Fin ((2*blocks)*(2*half)) :=
  ⟨i.val + if upper then blocks*(2*half) else 0, by
    have := i.isLt
    rw [Nat.mul_assoc]
    cases upper <;> simp <;> omega⟩

theorem embed_pack {blocks half : Nat} (upper : Bool) (c : Coordinates blocks half) :
    doubleEmbed upper (pack c) = pack ((liftBlock upper c.1.1, c.1.2), c.2) := by
  apply Fin.ext
  simp only [doubleEmbed, pack, linearIndex, liftBlock]
  cases upper <;> simp [Nat.add_mul] <;> omega

theorem forward_double_restrict {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (upper : Bool) (root : F) (nonzero : root ≠ 0)
    (a : Fin ((2*blocks)*(2*half)) → F) (i : Fin (blocks*(2*half))) :
    forward (arrayStage (2*blocks) half positive root nonzero) a (doubleEmbed upper i) =
      forward (arrayStage blocks half positive root nonzero) (fun j => a (doubleEmbed upper j)) i := by
  rw [← pack_unpack positive i]
  simp [embed_pack, forward, arrayStage, arrayPairing, unpack_pack, toggle]

def halfIndex (bits : Nat) (upper : Bool) (i : Fin (2^bits)) : Fin (2^(bits+1)) :=
  ⟨i.val + if upper then 2^bits else 0, by
    have bound := i.isLt
    rw [Nat.pow_succ]
    cases upper <;> simp <;> omega⟩

theorem forward_transport {F : Type} [Field F] {n m : Nat} (equal : n = m)
    (s : Stage (Fin n) F) (a : Fin m → F) (i : Fin n) :
    forward (equal ▸ s) a (Fin.cast equal i) = forward s (fun j => a (Fin.cast equal j)) i := by
  cases equal
  rfl

theorem transport_array_stage {F : Type} [Field F] {first second half size : Nat}
    (same : first = second) (positive : 0 < half) (root : F) (nonzero : root ≠ 0)
    (left : first*(2*half) = size) (right : second*(2*half) = size) :
    left ▸ arrayStage first half positive root nonzero =
      right ▸ arrayStage second half positive root nonzero := by
  cases same
  rfl

theorem radix_forward_restrict {F : Type} [Field F] (bits : Nat) (index : Fin bits)
    (upper : Bool) (root : F) (nonzero : root ≠ 0)
    (a : Fin (2^(bits+1)) → F) (i : Fin (2^bits)) :
    forward (radixStage (bits+1) index.castSucc root nonzero) a (halfIndex bits upper i) =
      forward (radixStage bits index root nonzero) (fun j => a (halfIndex bits upper j)) i := by
  let blocks := 2^(bits-index.val-1)
  let half := 2^index.val
  have positive : 0 < half := Nat.two_pow_pos _
  have small : blocks*(2*half) = 2^bits := stage_size bits index.val index.isLt
  have bigBlocks : 2^(bits+1-index.val-1) = 2*blocks := by
    have exponents : bits+1-index.val-1 = (bits-index.val-1)+1 := by have := index.isLt; omega
    rw [exponents, Nat.pow_succ]
    simp [blocks, Nat.mul_comm]
  have big : (2*blocks)*(2*half) = 2^(bits+1) := by
    rw [Nat.mul_assoc, small, Nat.pow_succ, Nat.mul_comm]
  have smallStage : radixStage bits index root nonzero = small ▸ arrayStage blocks half positive root nonzero := rfl
  have bigStage : radixStage (bits+1) index.castSucc root nonzero =
      big ▸ arrayStage (2*blocks) half positive root nonzero := by
    unfold radixStage
    exact transport_array_stage bigBlocks positive root nonzero _ big
  have embedding (j : Fin (blocks*(2*half))) :
      Fin.cast big (doubleEmbed upper j) = halfIndex bits upper (Fin.cast small j) := by
    apply Fin.ext
    simp only [Fin.val_cast, doubleEmbed, halfIndex]
    exact congrArg (fun size => j.val + if upper then size else 0) small
  let j := Fin.cast small.symm i
  have back : Fin.cast small j = i := by simp [j]
  rw [← back, ← embedding j, bigStage, forward_transport, forward_double_restrict positive]
  have inputs : (fun j => a (Fin.cast big (doubleEmbed upper j))) =
      (fun j => a (halfIndex bits upper (Fin.cast small j))) := by
    funext j
    rw [embedding]
  rw [inputs, smallStage, forward_transport]

theorem run_forward_restrict {F : Type} [Field F] (bits : Nat) (indices : List (Fin bits))
    (roots : Fin (bits+1) → F) (nonzero : ∀ i, roots i ≠ 0) (upper : Bool)
    (a : Fin (2^(bits+1)) → F) :
    (fun i => runForward (indices.map fun index => radixStage (bits+1) index.castSucc
      (roots index.castSucc) (nonzero index.castSucc)) a (halfIndex bits upper i)) =
    runForward (indices.map fun index => radixStage bits index
      (roots index.castSucc) (nonzero index.castSucc)) (fun i => a (halfIndex bits upper i)) := by
  induction indices generalizing a with
  | nil => rfl
  | cons index rest ih =>
    simp only [List.map_cons, runForward]
    rw [ih]
    congr 1
    funext i
    exact radix_forward_restrict bits index upper _ _ a i

def evenOddIndex (bits : Nat) (odd : Bool) (i : Fin (2^bits)) : Fin (2^(bits+1)) :=
  ⟨2*i.val + odd.toNat, by
    have bound := i.isLt
    have bitBound : odd.toNat ≤ 1 := by cases odd <;> decide
    rw [Nat.pow_succ]
    omega⟩

theorem reverse_bool (b : Bool) : (BitVec.ofBool b).reverse = BitVec.ofBool b := by
  cases b <;> decide

theorem reverse_half_index (bits : Nat) (upper : Bool) (i : Fin (2^bits)) :
    reverseIndex (bits+1) (halfIndex bits upper i) = evenOddIndex bits upper (reverseIndex bits i) := by
  have same : BitVec.ofFin (halfIndex bits upper i) =
      ((BitVec.ofBool upper) ++ BitVec.ofFin i).cast (by omega) := by
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_cast, BitVec.toNat_append]
    change (halfIndex bits upper i).val = (BitVec.ofBool upper).toNat <<< bits ||| i.val
    rw [← Nat.shiftLeft_add_eq_or_of_lt i.isLt]
    cases upper <;> simp [halfIndex, Nat.shiftLeft_eq, Nat.add_comm]
  apply Fin.ext
  change (BitVec.ofFin (halfIndex bits upper i)).reverse.toNat = _
  rw [same, BitVec.reverse_cast, BitVec.toNat_cast, BitVec.reverse_append,
    BitVec.toNat_cast, BitVec.toNat_append, reverse_bool]
  rw [BitVec.toNat_ofBool]
  rw [← Nat.shiftLeft_add_eq_or_of_lt (by cases upper <;> decide : upper.toNat < 2^1)]
  simp [evenOddIndex, reverseIndex, Nat.shiftLeft_eq, Nat.mul_comm]

theorem last_stage_formula {F : Type} [Field F] (bits : Nat) (upper : Bool)
    (root : F) (nonzero : root ≠ 0) (a : Fin (2^(bits+1)) → F) (i : Fin (2^bits)) :
    forward (radixStage (bits+1) (Fin.last bits) root nonzero) a (halfIndex bits upper i) =
      if upper then a (halfIndex bits false i) - root^i.val * a (halfIndex bits true i)
      else a (halfIndex bits false i) + root^i.val * a (halfIndex bits true i) := by
  have size : 1*(2*2^bits) = 2^(bits+1) := by simp [Nat.pow_succ, Nat.mul_comm]
  have lastBlocks : 2^(bits+1-bits-1) = 1 := by simp
  have stageEq : radixStage (bits+1) (Fin.last bits) root nonzero =
      size ▸ arrayStage 1 (2^bits) (Nat.two_pow_pos _) root nonzero := by
    unfold radixStage
    exact transport_array_stage lastBlocks (Nat.two_pow_pos _) root nonzero _ size
  have atIndex (side : Bool) :
      Fin.cast size (pack (((0 : Fin 1), i), !side)) = halfIndex bits side i := by
    apply Fin.ext
    cases side <;> simp [pack, linearIndex, halfIndex]
  rw [← atIndex upper, stageEq, forward_transport]
  have leftIndex := atIndex false
  have rightIndex := atIndex true
  simp only [Bool.not_false, Bool.not_true] at leftIndex rightIndex
  cases upper <;>
    simp only [forward, arrayStage, arrayPairing, unpack_pack, toggle, Bool.not_false,
      Bool.not_true, Bool.false_eq_true, ite_true, ite_false] <;>
    rw [leftIndex, rightIndex]

theorem run_forward_append {I F : Type} [Field F] (first second : List (Stage I F)) (a : I → F) :
    runForward (first ++ second) a = runForward second (runForward first a) := by
  induction first generalizing a with
  | nil => rfl
  | cons s rest ih => simp only [List.cons_append, runForward, ih]

theorem forward_fft_recurrence {F : Type} [Field F] (bits : Nat) (roots : Fin (bits+1) → F)
    (nonzero : ∀ i, roots i ≠ 0) (a : Fin (2^(bits+1)) → F) (upper : Bool) (i : Fin (2^bits)) :
    forwardFft (bits+1) roots nonzero a (halfIndex bits upper i) =
      let even := forwardFft bits (fun j => roots j.castSucc) (fun j => nonzero j.castSucc)
        (fun j => a (evenOddIndex bits false j)) i
      let odd := forwardFft bits (fun j => roots j.castSucc) (fun j => nonzero j.castSucc)
        (fun j => a (evenOddIndex bits true j)) i
      if upper then even - roots (Fin.last bits)^i.val * odd else even + roots (Fin.last bits)^i.val * odd := by
  let initial := permute (reverseIndex (bits+1)) a
  let earlier := (List.finRange bits).map fun j => radixStage (bits+1) j.castSucc (roots j.castSucc) (nonzero j.castSucc)
  have stages : radixStages (bits+1) roots nonzero = earlier ++
      [radixStage (bits+1) (Fin.last bits) (roots (Fin.last bits)) (nonzero (Fin.last bits))] := by
    simp [radixStages, earlier, List.finRange_succ_last, List.map_map]
  have part (side : Bool) : (runForward earlier initial) (halfIndex bits side i) =
      forwardFft bits (fun j => roots j.castSucc) (fun j => nonzero j.castSucc)
        (fun j => a (evenOddIndex bits side j)) i := by
    have projected := congrArg (fun f => f i)
      (run_forward_restrict bits (List.finRange bits) roots nonzero side initial)
    change runForward earlier initial (halfIndex bits side i) = _ at projected
    rw [projected]
    have inputEq : (fun j => initial (halfIndex bits side j)) =
        permute (reverseIndex bits) (fun j => a (evenOddIndex bits side j)) := by
      funext j
      change a (reverseIndex (bits+1) (halfIndex bits side j)) = _
      rw [reverse_half_index]
      rfl
    rw [inputEq]
    rfl
  change runForward (radixStages (bits+1) roots nonzero) initial (halfIndex bits upper i) = _
  rw [stages, run_forward_append]
  simp only [runForward]
  rw [last_stage_formula, part false, part true]

#print axioms forward_double_restrict
#print axioms radix_forward_restrict
#print axioms run_forward_restrict
#print axioms reverse_half_index
#print axioms forward_fft_recurrence

end ZkBuild.FftSplit
