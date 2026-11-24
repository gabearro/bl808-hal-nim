import BinaryDeclarations
import InstructionSource
import SourceControl

namespace ZkBuild.FlatInstructionSource

structure Counter where
  function : Nat
  pc : Nat
  deriving DecidableEq

def step (counter : Counter) (rootEnd : Bool) : Counter :=
  if rootEnd then ⟨counter.function+1,0⟩ else ⟨counter.function,counter.pc+1⟩

def run (counter : Counter) (ends : List Bool) : Counter := ends.foldl step counter

def endCount (ends : List Bool) : Nat := (ends.filter id).length

theorem step_function (counter : Counter) (ending : Bool) :
    (step counter ending).function = counter.function+ending.toNat := by
  cases ending <;> simp [step]

theorem function_count (ends : List Bool) (counter : Counter) :
    (run counter ends).function = counter.function+endCount ends := by
  induction ends generalizing counter with
  | nil => simp [run,endCount]
  | cons head tail ih =>
    cases head with
    | false => simpa [run,List.foldl_cons,step_function,endCount,Nat.add_assoc] using ih (step counter false)
    | true => simpa [run,List.foldl_cons,step_function,endCount,Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using ih (step counter true)

theorem completed_functions (ends : List Bool) (first total : Nat)
    (closed : (run ⟨first,0⟩ ends).function = first+total) : endCount ends = total := by
  rw [function_count] at closed
  change first+endCount ends = first+total at closed
  omega

theorem first_pc (counter : Counter) : (step counter true).pc = 0 := rfl
theorem next_pc (counter : Counter) : (step counter false).pc = counter.pc+1 := rfl

theorem no_skipped_function (counter : Counter) (ending : Bool) :
    counter.function ≤ (step counter ending).function ∧
      (step counter ending).function ≤ counter.function+1 := by
  cases ending <;> simp [step]

-- The global auxiliary streams have distinct (owner, ordinal) keys. Every key
-- lies in the corresponding instruction's declared range, and the total
-- number of rows equals the sum of those ranges. No instruction's auxiliary
-- payload may be omitted, even when instruction rows are padded.
theorem auxiliary_complete (counts : List Nat) (actual : List (Nat × Nat))
    (unique : actual.Nodup) (bounded : actual ⊆ BinaryDeclarations.vectorKeys 0 counts)
    (total : actual.length = counts.sum) :
    BinaryDeclarations.vectorKeys 0 counts ⊆ actual :=
  BinaryDeclarations.complete_vectors counts 0 actual unique bounded total

theorem owner_key_injective (owner ordinal otherOwner otherOrdinal : Nat)
    (first : ordinal < 2^32) (second : otherOrdinal < 2^32)
    (same : owner*2^32+ordinal = otherOwner*2^32+otherOrdinal) :
    owner = otherOwner ∧ ordinal = otherOrdinal := by
  have split := RangeConstraints.radix_injective (2^32) ordinal owner otherOrdinal otherOwner
    first second (by omega)
  exact ⟨split.2,split.1⟩

theorem branch_stream_binding (table : BranchLists.Store) (head : Nat)
    (declared source : List Nat) (members : BranchLists.Follows table head declared)
    (consumed : BranchLists.Consumes table head source 0) : source = declared :=
  BranchLists.complete_consumption table head declared source members consumed

theorem catch_stream_binding (table : CatchLists.Table) (head : Nat)
    (declared source : List CatchLists.Clause) (members : CatchLists.Represents table head declared)
    (consumed : CatchLists.Walk table head source 0) : source = declared :=
  CatchLists.closed_walk table head declared source members consumed

-- The no-auxiliary case must also end at the fixed-field cursor; otherwise a
-- zero-length catch vector could hide bytes between consecutive instructions.
theorem empty_payload_cursor (fixed finish : Nat) (bound : fixed = finish) :
    finish-fixed = 0 := by omega

theorem ordinal_successor (previous current count : Nat)
    (next : current = previous+1) (inside : current < count) : previous < count := by omega

theorem last_ordinal_closes (ordinal count : Nat) (_inside : ordinal < count)
    (last : ordinal+1 = count) : ordinal = count-1 := by omega

theorem source_record_binding (a b : InstructionSource.Instruction)
    (header : InstructionSource.info a = InstructionSource.info b)
    (immediates : InstructionSource.immediates a = InstructionSource.immediates b) : a = b :=
  InstructionSource.record_injective a b header immediates

#print axioms function_count
#print axioms completed_functions
#print axioms no_skipped_function
#print axioms auxiliary_complete
#print axioms owner_key_injective
#print axioms branch_stream_binding
#print axioms catch_stream_binding
#print axioms source_record_binding

end ZkBuild.FlatInstructionSource
