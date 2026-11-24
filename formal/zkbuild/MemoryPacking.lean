import PermutationMatrix
import MemoryConstraints

namespace ZkBuild.MemoryPacking

open Lean.Grind CircuitShape FullMatrix GadgetShape MemoryTrace RangeConstraints
attribute [local instance] Ring.intCast Semiring.natCast

structure Access where
  active : Linear
  write : Linear
  address : Linear
  value : Linear
  clock : Linear
  deriving Inhabited

def digits (addressBits timeBits valueBits : Nat) (record : Entry) : List (Nat × Nat) :=
  [(valueBits,record.value),(1,record.write.toNat),(1,record.active.toNat),(timeBits,record.time),(addressBits,record.address)]

def encode (addressBits timeBits valueBits : Nat) (record : Entry) : Nat :=
  packDigits (digits addressBits timeBits valueBits record)

def pack (timeBits valueBits : Nat) (access : Access) : Linear :=
  access.value ++ scale access.write (Int.ofNat (2^valueBits)) ++
    scale access.active (Int.ofNat (2^valueBits*2)) ++
    scale access.clock (Int.ofNat (2^valueBits*4)) ++
    scale access.address (Int.ofNat (2^valueBits*4*2^timeBits))

def Represents {F : Type} [CommRing F] (values : Nat → F) (access : Access) (record : Entry) : Prop :=
  E values access.active = (record.active.toNat : F) ∧ E values access.write = (record.write.toNat : F) ∧
  E values access.address = (record.address : F) ∧ E values access.value = (record.value : F) ∧
  E values access.clock = (record.time : F)

theorem bounded_digits (addressBits timeBits valueBits : Nat) (record : Entry)
    (bounded : MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) record) :
    RangeConstraints.Bounded (digits addressBits timeBits valueBits record) := by
  intro digit member
  simp [digits] at member
  rcases member with rfl | rfl | rfl | rfl | rfl
  · exact bounded.2.2
  · cases record.write <;> decide
  · cases record.active <;> decide
  · exact bounded.2.1
  · exact bounded.1

theorem encode_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (addressBits timeBits valueBits : Nat) (small : valueBits+2+timeBits+addressBits ≤ 248)
    (a b : Entry)
    (ha : MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) a)
    (hb : MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) b)
    (equal : (encode addressBits timeBits valueBits a : F) = (encode addressBits timeBits valueBits b : F)) : a = b := by
  have same := packed_field_injective (F := F) _ _ (bounded_digits _ _ _ a ha) (bounded_digits _ _ _ b hb)
    (by rfl) (by simp only [Width,digits,List.map_cons,List.map_nil,List.sum_cons,List.sum_nil]; omega) equal
  have parts : a.value = b.value ∧ a.write.toNat = b.write.toNat ∧ a.active.toNat = b.active.toNat ∧
      a.time = b.time ∧ a.address = b.address := by simpa [digits] using same
  have boolInjective (p q : Bool) (equal : p.toNat = q.toNat) : p = q := by
    cases p <;> cases q <;> simp_all
  have write : a.write = b.write := boolInjective _ _ parts.2.1
  have active : a.active = b.active := boolInjective _ _ parts.2.2.1
  cases a
  cases b
  simp only [Entry.mk.injEq]
  exact ⟨active,write,parts.2.2.2.2,parts.1,parts.2.2.2.1⟩

theorem pack_sound {F : Type} [CommRing F] (values : Nat → F)
    (addressBits timeBits valueBits : Nat) (access : Access) (record : Entry)
    (represented : Represents values access record) :
    E values (pack timeBits valueBits access) = (encode addressBits timeBits valueBits record : F) := by
  rcases represented with ⟨active,write,address,value,clock⟩
  simp only [pack,E,FullMatrix.eval_append,FullMatrix.eval_scale]
  repeat rw [Ring.intCast_natCast]
  simp only [active,write,address,value,clock,encode,digits,packDigits,Nat.mul_zero,Nat.add_zero,
    Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_pow]
  grind




theorem representation_unique {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (values : Nat → F) (addressBits timeBits valueBits : Nat) (small : valueBits+2+timeBits+addressBits ≤ 248)
    (access : Access) (a b : Entry)
    (ha : MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) a)
    (hb : MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) b)
    (aImage : Represents values access a) (bImage : Represents values access b) : a = b :=
  encode_injective addressBits timeBits valueBits small a b ha hb
    ((pack_sound values addressBits timeBits valueBits access a aImage).symm.trans
      (pack_sound values addressBits timeBits valueBits access b bImage))

def orderKey (addressBits timeBits : Nat) (access : Access) : Linear :=
  scale (sub (constant 1) access.active) (Int.ofNat (2^timeBits*2^addressBits)) ++
    scale access.address (Int.ofNat (2^timeBits)) ++ access.clock

theorem orderKey_sound {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (addressBits timeBits : Nat) (access : Access) (record : Entry)
    (represented : Represents values access record) :
    E values (orderKey addressBits timeBits access) =
      (MemoryConstraints.key (2^addressBits) (2^timeBits) record : F) := by
  rcases represented with ⟨active,write,address,value,clock⟩
  simp only [orderKey,E,FullMatrix.eval_append,FullMatrix.eval_scale]
  have complement : E values (sub (constant 1) access.active) = 1-E values access.active := by
    simp [eval_sub,eval_constant values one,Ring.intCast_one]
  have castMul : ((Int.ofNat (2^timeBits*2^addressBits) : Int) : F) = ((2^timeBits*2^addressBits : Nat) : F) :=
    Ring.intCast_natCast _
  have castTime : ((Int.ofNat (2^timeBits) : Int) : F) = ((2^timeBits : Nat) : F) := Ring.intCast_natCast _
  simp only [castMul,castTime,complement,active,address,clock,MemoryConstraints.key,Semiring.natCast_add,Semiring.natCast_mul]
  cases record.active <;> simp <;> grind

def publicAccess : Access := ⟨wire 1,wire 2,wire 3,wire 4,wire 5⟩

def artifact (addressBits timeBits valueBits : Nat) : Artifact :=
  ⟨{ wires := 6,publicCount := 5 },[pack timeBits valueBits publicAccess,orderKey addressBits timeBits publicAccess]⟩

theorem checked_layout {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (actual : Artifact) (addressBits timeBits valueBits : Nat)
    (checked : conforms actual (artifact addressBits timeBits valueBits) = true)
    (values : Nat → F) (one : values 0 = 1) (record : Entry)
    (represented : Represents values publicAccess record) :
    actual.outputs.map (E values) = [(encode addressBits timeBits valueBits record : F),
      (MemoryConstraints.key (2^addressBits) (2^timeBits) record : F)] := by
  have relation := (conformance_relation actual (artifact addressBits timeBits valueBits) checked values).2
  simpa [artifact,pack_sound values addressBits timeBits valueBits publicAccess record represented,
    orderKey_sound values one addressBits timeBits publicAccess record represented] using relation

theorem reflect_perm (f : α → β) (p : α → Prop) (a b : List α)
    (injective : ∀ x, p x → ∀ y, p y → f x = f y → x = y)
    (ha : ∀ x ∈ a, p x) (hb : ∀ y ∈ b, p y)
    (permuted : (a.map f).Perm (b.map f)) : a.Perm b := by
  classical
  let decode : β → Option α := fun value =>
    if h : ∃ x, p x ∧ f x = value then some (Classical.choose h) else none
  have undoOne (x : α) (valid : p x) : decode (f x) = some x := by
    have witnessExists : ∃ y, p y ∧ f y = f x := ⟨x,valid,rfl⟩
    dsimp only [decode]
    rw [dite_eq_left witnessExists]
    apply congrArg some
    exact injective _ (Classical.choose_spec witnessExists).1 x valid (Classical.choose_spec witnessExists).2
  have undo (xs : List α) (valid : ∀ x ∈ xs, p x) : (xs.map f).filterMap decode = xs := by
    induction xs with
    | nil => rfl
    | cons x rest ih =>
      simp only [List.map_cons,List.filterMap_cons,undoOne x (valid x (by simp))]
      exact congrArg (List.cons x) (ih (by intro y member; exact valid y (by simp [member])))
  have reflected := permuted.filterMap decode
  rwa [undo a ha,undo b hb] at reflected

theorem records_perm {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (addressBits timeBits valueBits : Nat) (small : valueBits+2+timeBits+addressBits ≤ 248)
    (a b : List Entry)
    (ha : ∀ row ∈ a, MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (hb : ∀ row ∈ b, MemoryConstraints.Bounded (2^addressBits) (2^timeBits) (2^valueBits) row)
    (permuted : (a.map (fun row => (encode addressBits timeBits valueBits row : F))).Perm
      (b.map (fun row => (encode addressBits timeBits valueBits row : F)))) : a.Perm b := by
  exact reflect_perm _ _ a b (fun x hx y hy equal => encode_injective addressBits timeBits valueBits small x y hx hy equal)
    ha hb permuted


def cases : List (Nat × Nat × Nat) :=
  [1,8,32,64].flatMap (fun a => [0,1,8,32,64].flatMap (fun t => [1,8,32,64].map (fun v => (a,t,v))))

#print axioms encode_injective
#print axioms representation_unique
#print axioms pack_sound
#print axioms records_perm
#print axioms checked_layout

end ZkBuild.MemoryPacking
