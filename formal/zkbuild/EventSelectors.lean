import OperandEvents
set_option autoImplicit false
namespace ZkBuild.EventSelectors
open Lean.Grind R1CS OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def codes : List Nat := [0,1,2,3,4,5,6,7,8,9,15]
def kinds : List Kind := [.functionBegin,.instructionBegin,.push,.pop,.controlPush,.controlPop,
  .clear,.instructionEnd,.functionEnd,.labelCheck,.padding]

theorem kind_codes : kinds.map kindCode = codes := rfl

theorem selection {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : List F) (tag : F) (length : values.length = 11)
    (boolean : ∀ value ∈ values, value*(value-1) = 0)
    (total : sum values = 1) (binding : weightedValues codes values = tag) :
    ∃ kind : Kind, tag = (kindCode kind : F) ∧
      values = codes.map (fun code => flag (decide (code = kindCode kind))) := by
  obtain ⟨bits,same⟩ := constrained_bits_are_booleans values boolean
  have len : bits.length = 11 := by simpa [same] using length
  have count : countTrue bits = 1 := by
    have small : countTrue bits < scalarModulus := by
      have bound := countTrue_bound bits
      have big : 11 < scalarModulus := by decide
      omega
    have value : (countTrue bits : F) = ((1 : Nat) : F) := by
      simpa [same,bool_sum_count,Semiring.natCast_one] using total
    exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus small (by decide)).mp value
  have member := selectedCode_one codes bits (by simp [codes,len]) count
  have present : selectedCode codes bits ∈ kinds.map kindCode := by simpa only [kind_codes] using member
  obtain ⟨kind,km,code⟩ := List.mem_map.mp present
  have selected := one_selection_unique codes bits (kindCode kind) (by simp [codes,len]) (by decide) count code.symm
  refine ⟨kind,?_,?_⟩
  · rw [← binding,same,weighted_booleans,code]
  · simp [same,selected,flag,boolValue,List.map_map,Function.comp_def]

#print axioms selection
end ZkBuild.EventSelectors
