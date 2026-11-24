import ControlEvents
set_option autoImplicit false
namespace ZkBuild.ControlAddressBounds
open OperandEvents ControlEvents

theorem index_bound (fn slot : Nat) (fb : fn < bound) (sb : slot < bound) : fn*bound+slot < 2^64 := by
  have positive : 0 < bound := by decide
  calc
    fn*bound+slot < fn*bound+bound := Nat.add_lt_add_left sb _
    _ = (fn+1)*bound := by rw [Nat.add_mul,Nat.one_mul]
    _ ≤ bound*bound := Nat.mul_le_mul_right bound fb
    _ = 2^64 := by decide

theorem read_bounds (before : Nat) (row : Row) (beforeBound : before < bound)
    (functionBound : row.functionIndex < bound) (floorBound : row.floor < bound) :
    (readProject before row).address < 2^64 ∧ (readProject before row).value < 2^33 := by
  unfold readProject
  split
  · decide
  · constructor
    · apply index_bound _ _ functionBound
      omega
    · cases row.unreachable <;> simp [Bool.toNat] <;> unfold bound at floorBound <;> omega

theorem write_bounds (before height : Nat) (row : Row) (beforeBound : before < bound)
    (heightBound : height < bound) (functionBound : row.functionIndex < bound) (floorBound : row.floor < bound) :
    (writeProject before height row).address < 2^64 ∧ (writeProject before height row).value < 2^33 := by
  cases k : row.kind <;> simp only [writeProject,k]
  all_goals try { exact ⟨by decide,by decide⟩ }
  case controlPush =>
    exact ⟨index_bound _ _ functionBound beforeBound,by unfold bound at heightBound; omega⟩
  case clear =>
    exact ⟨index_bound _ _ functionBound (by omega),by unfold bound at floorBound; omega⟩

#print axioms read_bounds
#print axioms write_bounds
end ZkBuild.ControlAddressBounds
