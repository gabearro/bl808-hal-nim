import NameLists
import LocalRanges

namespace ZkBuild.ModuleContext

structure Global where
  tag : Fin 7
  mutable : Bool

inductive Constant where
  | numeric (tag : Fin 5)
  | null (external : Bool)
  | function (index : Nat)
  | global (index : Nat)

def constantType (globals : List Global) (functions available : Nat) : Constant → Option Nat
  | .numeric tag => some tag.val
  | .null external => some (if external then 6 else 5)
  | .function index => if index < functions then some 5 else none
  | .global index => if index < available then
      match globals[index]? with
      | some value => if value.mutable then none else some value.tag.val
      | none => none
    else none

theorem initialized_immutable_global (globals : List Global) (functions available index tag : Nat)
    (accepted : constantType globals functions available (.global index) = some tag) :
    index < available ∧ ∃ value, globals[index]? = some value ∧
      value.mutable = false ∧ value.tag.val = tag := by
  simp only [constantType] at accepted
  split at accepted
  next bound =>
    cases found : globals[index]? with
    | none => simp [found] at accepted
    | some value =>
      cases mutable : value.mutable <;> simp [found, mutable] at accepted
      exact ⟨bound, value, rfl, mutable, accepted⟩
  next => simp at accepted

theorem reference_existence (globals : List Global) (functions available index tag : Nat)
    (accepted : constantType globals functions available (.function index) = some tag) :
    index < functions ∧ tag = 5 := by
  simp only [constantType] at accepted
  split at accepted <;> simp_all

theorem declaration_origins (declared sources : Nat → Prop)
    (forward : ∀ index, declared index → sources index)
    (reverse : ∀ index, sources index → declared index) :
    ∀ index, declared index ↔ sources index := by
  intro index
  exact ⟨forward index, reverse index⟩

theorem distinct_exports (table : NameLists.Table) (canonical : NameLists.Canonical table)
    (heads : Nat → Nat) (names : Nat → List Nat)
    (represented : ∀ i, NameLists.Represents table (heads i) (names i))
    (uniqueHeads : Function.Injective heads) : Function.Injective names := by
  intro i j equal
  apply uniqueHeads
  exact NameLists.canonical_heads table canonical (heads i) (heads j) (names i) (names j)
    (represented i) (represented j) equal

#print axioms initialized_immutable_global
#print axioms reference_existence
#print axioms declaration_origins
#print axioms distinct_exports

end ZkBuild.ModuleContext
