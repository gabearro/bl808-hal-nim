import EnvironmentAccessSound
import DynamicTypingSource
set_option autoImplicit false
namespace ZkBuild.EnvironmentOriginSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Origins {F : Type} [Field F] (values : Nat → F) (locals objects : List ReadOnlyMatrix.Entry)
    (r : EnvironmentRowCheck.Record) (code : Nat) (declared : Fin 7) (mutable : Bool) : Prop where
  localSource : VariableTyping.environment code = 1 → ∃ source ∈ locals,
    E values source.active = 1 ∧ E values source.address = E values (f r.row 1)*(2^32 : Nat)+E values r.immediate ∧
    E values source.value = (declared.val : F)
  objectSource : (VariableTyping.environment code = 2 ∨ VariableTyping.environment code = 3) → ∃ source ∈ objects,
    E values source.active = 1 ∧ E values source.address = E values r.immediate*2+
      OperandEvents.flag (decide (VariableTyping.environment code = 3)) ∧
    E values source.value = (VariableTyping.globalValue declared.val mutable : F)

theorem row {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (environment : EnvironmentRowCheck.checkStage matrix tables (DynamicTypingCheck.stage typing 1) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < (DynamicTypingCheck.stage typing 1).rows.length) (code : Nat) (declared : Fin 7) (mutable : Bool)
    (access : EnvironmentAccessSound.Spec values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i) code declared mutable)
    (packed : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.value +
      E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.value =
      (VariableTyping.globalValue declared.val mutable : F)) :
    Origins values locals.locals (ModuleContextMatrix.bank tables context 0).entries
      (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i) code declared mutable := by
  have parts := accepted
  simp only [DynamicTypingCheck.check,DynamicTypingCheck.links,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have kinds : typing.stages.map (·.kind) = [0,1,2,3] := by grind only
  have member : DynamicTypingCheck.stage typing 1 ∈ typing.stages := by
    unfold DynamicTypingCheck.stage
    have found : (typing.stages.find? (fun s => s.kind == 1)).isSome = true := by
      simp only [List.find?_isSome]
      have oneMember : 1 ∈ typing.stages.map (·.kind) := by rw [kinds]; simp
      obtain ⟨s,sm,kind⟩ := List.mem_map.mp oneMember
      exact ⟨s,sm,by simpa only [kind,beq_self_eq_true]⟩
    cases h : typing.stages.find? (fun s => s.kind == 1) with
    | none => simp [h] at found
    | some s => simpa [h] using List.mem_of_find?_eq_some h
  have bankCount : (DynamicTypingCheck.stage typing 1).banks.length = 2 := by grind only
  have tablesMeaning := (DynamicTypingSound.checked matrix splits tables signature context locals events typing accepted values one satisfied).2
  have facts (k : Nat) (kb : k < 2) : DynamicTypingSound.TableFacts values (bank tables (DynamicTypingCheck.stage typing 1) k) := by
    apply tablesMeaning _ member
    rw [← List.getElem_eq_getD 0]
    exact List.getElem_mem (by omega)
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp environment).1
  have lm : (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery ∈
      (bank tables (DynamicTypingCheck.stage typing 1) 0).queries := by
    change (bank tables (DynamicTypingCheck.stage typing 1) 0).queries.getD i default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by omega)
  have om : (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery ∈
      (bank tables (DynamicTypingCheck.stage typing 1) 1).queries := by
    change (bank tables (DynamicTypingCheck.stage typing 1) 1).queries.getD i default ∈ _
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by omega)
  have origins := DynamicTypingSource.environment_origins matrix splits tables signature context locals events typing accepted values one satisfied
  constructor
  · intro localKind
    have active : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.active = 1 := by
      simpa [localKind,OperandEvents.flag] using access.localActive
    have inactive : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.active = 0 := by
      simpa [localKind,OperandEvents.flag,AddCommMonoid.add_zero] using access.objectActive
    have zero := (facts 1 (by decide)).2 _ om inactive
    obtain ⟨source,sm,enabled,address,value⟩ := origins.1 _ lm active
    refine ⟨source,sm,enabled,?_,?_⟩
    · rw [address,access.localAddress,active,Semiring.one_mul]
    · have packedTag : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.value = (declared.val : F) := by
        simpa [zero.2,AddCommMonoid.add_zero,access.localImmutable localKind,VariableTyping.globalValue] using packed
      exact value.trans packedTag
  · intro objectKind
    have active : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).objectQuery.active = 1 := by
      rcases objectKind with globalKind | tableKind
      · simpa [globalKind,OperandEvents.flag,AddCommMonoid.add_zero] using access.objectActive
      · simpa [tableKind,OperandEvents.flag,AddCommMonoid.zero_add] using access.objectActive
    have inactive : E values (EnvironmentRowCheck.record tables (DynamicTypingCheck.stage typing 1) i).localQuery.active = 0 := by
      rcases objectKind with globalKind | tableKind
      · simpa [globalKind,OperandEvents.flag] using access.localActive
      · simpa [tableKind,OperandEvents.flag] using access.localActive
    have zero := (facts 0 (by decide)).2 _ lm inactive
    obtain ⟨source,sm,enabled,address,value⟩ := origins.2.1 _ om active
    refine ⟨source,sm,enabled,?_,?_⟩
    · rw [address,access.objectAddress,active,Semiring.one_mul]
    · exact value.trans (by simpa only [zero.2,AddCommMonoid.zero_add] using packed)

#print axioms row
end ZkBuild.EnvironmentOriginSound
