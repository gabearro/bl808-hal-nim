import MemoryTrace
set_option autoImplicit false
namespace ZkBuild.MemoryPriorWrite
open MemoryTrace

def zero : Entry := ⟨false,false,0,0,0⟩

-- A successful read is supplied by initial memory or by an earlier write.
-- The index witness is chronological, rather than a sorted-trace position.
theorem origin (entries : List Entry) (memory : Memory)
    (reads : Reads memory entries) (i : Nat) (bound : i < entries.length)
    (active : (entries.getD i zero).active = true)
    (read : (entries.getD i zero).write = false) :
    memory (entries.getD i zero).address = some (entries.getD i zero).value ∨
    ∃ j, j < i ∧ (entries.getD j zero).active = true ∧
      (entries.getD j zero).write = true ∧
      (entries.getD j zero).address = (entries.getD i zero).address ∧
      (entries.getD j zero).value = (entries.getD i zero).value := by
  induction entries generalizing memory i with
  | nil => simp at bound
  | cons head tail ih =>
    cases i with
    | zero => exact Or.inl (reads.1 active read)
    | succ i =>
      have prior := ih (advance memory head) reads.2 i (by simpa using bound) active read
      rcases prior with initial | ⟨j,jb,ja,jw,jaddr,jvalue⟩
      · by_cases ha : head.active = true
        · by_cases hw : head.write = true
          · by_cases same : (tail.getD i zero).address = head.address
            · have value : head.value = (tail.getD i zero).value := by
                simpa only [advance,ha,hw,Bool.true_and,ite_true,same,Option.some.injEq] using initial
              exact Or.inr ⟨0,by omega,ha,hw,same.symm,value⟩
            · exact Or.inl (by simpa only [advance,ha,hw,Bool.true_and,ite_true,ite_false,same,List.getD_cons_succ] using initial)
          · have hf : head.write = false := by
              cases h : head.write
              · rfl
              · exact False.elim (hw h)
            exact Or.inl (by simpa [advance,hf] using initial)
        · have hf : head.active = false := by
            cases h : head.active
            · rfl
            · exact False.elim (ha h)
          exact Or.inl (by simpa [advance,hf] using initial)
      · exact Or.inr ⟨j+1,by omega,ja,jw,jaddr,jvalue⟩

theorem empty_origin (entries : List Entry) (reads : Reads (fun _ => none) entries)
    (i : Nat) (bound : i < entries.length)
    (active : (entries.getD i zero).active = true)
    (read : (entries.getD i zero).write = false) :
    ∃ j, j < i ∧ (entries.getD j zero).active = true ∧
      (entries.getD j zero).write = true ∧
      (entries.getD j zero).address = (entries.getD i zero).address ∧
      (entries.getD j zero).value = (entries.getD i zero).value := by
  rcases origin entries (fun _ => none) reads i bound active read with impossible | found
  · cases impossible
  · exact found

#print axioms origin
#print axioms empty_origin
end ZkBuild.MemoryPriorWrite
