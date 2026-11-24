import OperandMemorySound
set_option autoImplicit false
namespace ZkBuild.OperandStackRefinement
open OperandEvents

-- Bottom-first stack: slot i always names the i-th surviving stack type.
def Matches (stack : List (Fin 8)) (base : Nat) (mem : MemoryTrace.Memory) : Prop :=
  ∀ i (ib : i < stack.length), mem (base+i) = some stack[i].val

def next (stack : List (Fin 8)) (row : Row) : List (Fin 8) :=
  match row.kind with
  | .push => stack ++ [row.valueType]
  | .pop => if row.polymorphic then stack else stack.take (stack.length-1)
  | .clear => stack.take row.floor
  | _ => stack

def PopSpec (stack : List (Fin 8)) (row : Row) : Prop :=
  row.kind = .pop → if row.polymorphic then
    stack.length = row.floor ∧ row.unreachable = true ∧ row.valueType.val = 7
  else ∃ rest, stack = rest ++ [row.valueType] ∧ row.floor ≤ rest.length

theorem step (stack : List (Fin 8)) (mem : MemoryTrace.Memory) (row : Row) (time : Nat)
    (matched : Matches stack (row.functionIndex*bound) mem)
    (spec : StepSpec stack.length row)
    (read : MemoryTrace.ReadOk mem (OperandMemorySound.entry row time)) :
    PopSpec stack row ∧ (next stack row).length = row.height ∧
      Matches (next stack row) (row.functionIndex*bound) (MemoryTrace.advance mem (OperandMemorySound.entry row time)) := by
  have poly := spec.1
  have transition := spec.2.2
  have pop : PopSpec stack row := by
    intro k
    cases p : row.polymorphic with
    | true =>
      have facts := poly p
      simp only [p,ite_true]
      exact ⟨facts.2.2.1,facts.2.2.2,facts.2.1⟩
    | false =>
      have height : row.floor < stack.length ∧ row.height+1 = stack.length := by simpa [k,p] using transition
      have rb : row.height < stack.length := by omega
      have actual := read (by simp [OperandMemorySound.entry,project,active,isPush,isPop,k,p])
        (by simp [OperandMemorySound.entry,project,isPush,k])
      have actualValue : mem (row.functionIndex*bound+row.height) = some row.valueType.val := by
        simpa [OperandMemorySound.entry,project,active,isPush,isPop,k,p] using actual
      have equal : stack[row.height] = row.valueType := by
        apply Fin.ext
        exact Option.some.inj ((matched row.height rb).symm.trans actualValue)
      have last : stack = stack.take row.height ++ [row.valueType] := by
        have suffix : stack.drop row.height = [row.valueType] := by
          rw [List.drop_eq_getElem_cons rb,equal]
          have endDrop : stack.drop (row.height+1) = [] := by rw [height.2]; simp
          rw [endDrop]
        rw [← suffix,List.take_append_drop]
      exact ⟨stack.take row.height,last,by simp; omega⟩
  refine ⟨pop,?_,?_⟩
  · cases k : row.kind <;> simp only [k] at transition <;> simp [next,k]
    case push => omega
    case pop => cases p : row.polymorphic <;> simp [p] at transition ⊢ <;> omega
    case clear => omega
    all_goals exact transition.symm
  · intro i ib
    cases k : row.kind
    case push =>
      have height : row.height = stack.length+1 := by simpa [k] using transition
      have before : i < stack.length ∨ i = stack.length := by simp [next,k] at ib; omega
      rcases before with small | last
      · have neq : row.functionIndex*bound+i ≠ row.functionIndex*bound+stack.length := by omega
        simpa [next,k,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop,height,
          neq,Nat.ne_of_lt small,List.getElem_append_left small] using matched i small
      · subst i
        simp [next,k,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop,height]
    case pop =>
      cases p : row.polymorphic
      · have small : i < stack.length := by simp [next,k,p] at ib; omega
        simpa [next,k,p,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop] using matched i small
      · have small : i < stack.length := by simpa [next,k,p] using ib
        simpa [next,k,p,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop] using matched i small
    case clear =>
      have small : i < stack.length := by simp [next,k] at ib; omega
      simpa [next,k,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop] using matched i small
    all_goals
      have small : i < stack.length := by simpa [next,k] using ib
      simpa [next,k,OperandMemorySound.entry,MemoryTrace.advance,project,active,isPush,isPop] using matched i small

#print axioms step
end ZkBuild.OperandStackRefinement
