import OperandTraceSound
set_option autoImplicit false
namespace ZkBuild.OperandRepresentationUnique
open Lean.Grind CircuitShape FullMatrix GadgetShape OperandEvents
attribute [local instance] Semiring.natCast

theorem kind_injective (a b : Kind) (same : kindCode a = kindCode b) : a = b := by
  cases a <;> cases b <;> simp_all [kindCode]

theorem flag_injective {F : Type} [Field F] (a b : Bool)
    (same : flag (F := F) a = flag b) : a = b := by
  cases a <;> cases b <;> simp_all [flag]
  all_goals exact False.elim (Field.zero_ne_one (α := F) (by grind))

theorem row {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (r : OperandRowCheck.Record) (a b : Row)
    (ai : OperandRowSound.Represents values r a) (bi : OperandRowSound.Represents values r b)
    (af : a.functionIndex < bound) (bf : b.functionIndex < bound)
    (ah : a.height < bound) (bh : b.height < bound) (al : a.floor < bound) (bl : b.floor < bound) : a = b := by
  have kindBound (kind : Kind) : kindCode kind < 3*bound := by cases kind <;> decide
  have ke : a.kind = b.kind := kind_injective _ _ (natural_eq _ _ (kindBound _) (kindBound _) (ai.kind.symm.trans bi.kind))
  have fe : a.functionIndex = b.functionIndex := natural_eq _ _ (by omega) (by omega) (ai.functionIndex.symm.trans bi.functionIndex)
  have he : a.height = b.height := natural_eq _ _ (by omega) (by omega) (ai.height.symm.trans bi.height)
  have le : a.floor = b.floor := natural_eq _ _ (by omega) (by omega) (ai.floor.symm.trans bi.floor)
  have ve : a.valueType = b.valueType := Fin.ext (natural_eq _ _
    (by have := a.valueType.isLt; unfold bound; omega) (by have := b.valueType.isLt; unfold bound; omega)
    (ai.valueType.symm.trans bi.valueType))
  have pe := flag_injective a.polymorphic b.polymorphic (ai.polymorphic.symm.trans bi.polymorphic)
  have ue := flag_injective a.unreachable b.unreachable (ai.unreachable.symm.trans bi.unreachable)
  cases a; cases b
  simp_all

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (s : ValidationEventMatrix.Stage) (a b : List Row)
    (ai : OperandTraceSound.Represents values s a) (bi : OperandTraceSound.Represents values s b) : a = b := by
  apply List.ext_getElem
  · exact ai.1.trans bi.1.symm
  · intro i ab bb
    have ar := ai.2 i ab
    have br := bi.2 i bb
    have same := row values (OperandRowCheck.record s i) (a.getD i default) (b.getD i default)
      ar.1 br.1 ar.2.1 br.2.1 ar.2.2.1 br.2.2.1 ar.2.2.2 br.2.2.2
    rw [← List.getElem_eq_getD (h := ab) default,← List.getElem_eq_getD (h := bb) default] at same
    exact same

#print axioms row
#print axioms trace
end ZkBuild.OperandRepresentationUnique
