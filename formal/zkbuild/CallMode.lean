import CallRowSound
set_option autoImplicit false
namespace ZkBuild.CallMode
open Lean.Grind OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def active (code : Nat) : Bool := decide (code = 16 ∨ code = 17 ∨ code = 18 ∨ code = 19)
def tail (code : Nat) : Bool := decide (code = 18 ∨ code = 19)
def indirect (code : Nat) : Bool := decide (code = 17 ∨ code = 19)
def ordinary (code : Nat) : Bool := decide (code = 16 ∨ code = 17)

theorem sums {F : Type} [Field F] (code : Nat) :
    flag (F := F) (decide (code=16))+flag (decide (code=17))+flag (decide (code=18))+flag (decide (code=19)) = flag (active code) ∧
    flag (F := F) (decide (code=18))+flag (decide (code=19)) = flag (tail code) ∧
    flag (F := F) (decide (code=17))+flag (decide (code=19)) = flag (indirect code) ∧
    flag (F := F) (decide (code=16))+flag (decide (code=17)) = flag (ordinary code) := by
  by_cases a : code = 16
  · subst code; simp [flag,active,tail,indirect,ordinary,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases b : code = 17
  · subst code; simp [flag,active,tail,indirect,ordinary,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases c : code = 18
  · subst code; simp [flag,active,tail,indirect,ordinary,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  by_cases d : code = 19
  · subst code; simp [flag,active,tail,indirect,ordinary,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  simp [flag,active,tail,indirect,ordinary,a,b,c,d,AddCommMonoid.add_zero,AddCommMonoid.zero_add]

open CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix

theorem images {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code : Nat) (bound : code < 2^16) (image : E values (f r.row 8) = (code : F)) :
    E values (CallRowCheck.call r) = flag (active code) ∧
    E values (CallRowCheck.tail r) = flag (tail code) ∧
    E values (CallRowCheck.indexed r) = flag (indirect code) ∧
    E values (f r.after 0++f r.after 1) = flag (ordinary code) := by
  have selectors := CallRowSound.selectors matrix r checked values one satisfied code bound image
  have a := selectors 0 (by decide)
  have b := selectors 1 (by decide)
  have c := selectors 2 (by decide)
  have d := selectors 3 (by decide)
  simpa only [CallRowCheck.call,CallRowCheck.tail,CallRowCheck.indexed,eval_append,a,b,c,d] using sums (F := F) code

#print axioms sums
#print axioms images
end ZkBuild.CallMode
