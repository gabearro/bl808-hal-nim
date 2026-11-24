import StaticEvents
import ReadOnlyMemory

namespace ZkBuild.VariableTyping

open StaticTyping Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

def environment (code : Nat) : Nat :=
  if code = 0x20 ∨ code = 0x21 ∨ code = 0x22 then 1
  else if code = 0x23 ∨ code = 0x24 then 2
  else if code = 0x25 ∨ code = 0x26 ∨ code = 0x10f ∨ code = 0x110 ∨ code = 0x111 then 3
  else 0

def signature (code declared : Nat) : Option Rule :=
  if declared ≥ 7 then none
  else if environment code = 3 ∧ declared ≠ 5 ∧ declared ≠ 6 then none
  else if code = 0x20 ∨ code = 0x23 then mk [] (some declared)
  else if code = 0x21 ∨ code = 0x24 then mk [declared]
  else if code = 0x22 then mk [declared] (some declared)
  else if code = 0x25 then mk [0] (some declared)
  else if code = 0x26 then mk [declared, 0]
  else if code = 0x10f then mk [0, declared] (some 0)
  else if code = 0x110 then mk [] (some 0)
  else if code = 0x111 then mk [0, declared, 0]
  else none

def rules : List Rule := (List.range 1024).flatMap fun code =>
  (List.range 7).filterMap fun declared => signature code declared

set_option maxRecDepth 16384 in
theorem signature_shapes : rules.all validShape = true := by decide

set_option maxRecDepth 16384 in
theorem signature_count : rules.length = 45 := by decide

theorem exact_type (expected : Fin 7) (actual : Fin 8) :
    allowed expected.val actual.val ↔ actual.val = expected.val ∨ actual.val = 7 := by
  have eb := expected.isLt
  have ab := actual.isLt
  simp [allowed]
  omega

def localAddress (functionIndex localIndex : Nat) : Nat := functionIndex*2^32+localIndex
def objectAddress (isTable : Bool) (index : Nat) : Nat := index*2+isTable.toNat

theorem local_address_injective (f g i j : Nat) (ib : i < 2^32) (jb : j < 2^32)
    (same : localAddress f i = localAddress g j) : f = g ∧ i = j := by
  have result := radix_injective (2^32) i f j g ib jb (by simpa [localAddress, Nat.add_comm, Nat.mul_comm] using same)
  exact ⟨result.2, result.1⟩

theorem object_address_injective (a b : Bool) (i j : Nat)
    (same : objectAddress a i = objectAddress b j) : a = b ∧ i = j := by
  cases a <;> cases b <;> simp [objectAddress, Bool.toNat] at same ⊢ <;> omega

theorem local_address_bound (f i : Nat) (fb : f < 2^32) (ib : i < 2^32) :
    localAddress f i < 2^64 := by simp [localAddress]; omega

theorem object_address_bound (table : Bool) (i : Nat) (ib : i < 2^32) :
    objectAddress table i < 2^33 := by cases table <;> simp [objectAddress, Bool.toNat] <;> omega

def globalValue (tag : Nat) (mutable : Bool) : Nat := tag+8*mutable.toNat

theorem global_value_injective (a b : Fin 7) (m n : Bool)
    (same : globalValue a.val m = globalValue b.val n) : a = b ∧ m = n := by
  have ab := a.isLt
  have bb := b.isLt
  have tags : a.val = b.val := by cases m <;> cases n <;> simp [globalValue, Bool.toNat] at same <;> omega
  refine ⟨Fin.ext tags, ?_⟩
  cases m <;> cases n <;> simp_all [globalValue, Bool.toNat]

theorem mutation_gate {F : Type} [Field F] (mutable : Bool)
    (gate : 1-(if mutable then 1 else 0 : F) = 0) : mutable = true := by
  cases mutable with
  | true => rfl
  | false =>
    change (1 : F)-0 = 0 at gate
    have bad : (1 : F) = 0 := by grind
    exact False.elim (Field.zero_ne_one bad.symm)

theorem table_type_gate {F : Type} [Field F] [IsCharP F scalarModulus]
    (tag : Fin 7) (mutable : Bool)
    (typed : ((tag.val : F)-5)*((tag.val : F)-6) = 0)
    (immutable : (if mutable then 1 else 0 : F) = 0) :
    (tag.val = 5 ∨ tag.val = 6) ∧ mutable = false := by
  have bound : tag.val < NumericEvents.countBound := by have := tag.isLt; simp [NumericEvents.countBound]; omega
  constructor
  · by_cases five : (tag.val : F) = (5 : F)
    · apply Or.inl
      apply NumericEvents.nat_eq (F := F) _ _ bound (by decide)
      have eq : ((5 : Nat) : F) = (5 : F) := Semiring.natCast_eq_ofNat 5
      rw [eq]
      exact five
    · have six : (tag.val : F) = (6 : F) := by grind
      apply Or.inr
      apply NumericEvents.nat_eq (F := F) _ _ bound (by decide)
      have eq : ((6 : Nat) : F) = (6 : F) := Semiring.natCast_eq_ofNat 6
      rw [eq]
      exact six
  · cases mutable with
    | false => rfl
    | true => exact False.elim (Field.zero_ne_one immutable.symm)

#print axioms signature_shapes
#print axioms signature_count
#print axioms exact_type
#print axioms local_address_injective
#print axioms object_address_injective
#print axioms global_value_injective
#print axioms mutation_gate
#print axioms table_type_gate

end ZkBuild.VariableTyping
