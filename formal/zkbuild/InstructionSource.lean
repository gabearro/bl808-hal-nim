import BinarySource
import BinaryEnvelope
import SignatureLists
import BranchLists
import CatchLists

namespace ZkBuild.InstructionSource

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

structure Instruction where
  opcode : Fin (2^16)
  primary : Fin (2^32)
  secondary : Fin (2^32)
  pad : Fin (2^33)
  deriving DecidableEq

def info (instruction : Instruction) : Nat := instruction.opcode.val+2^16*instruction.pad.val
def immediates (instruction : Instruction) : Nat := instruction.primary.val+2^32*instruction.secondary.val

theorem info_bound (instruction : Instruction) : info instruction < 2^49 := by
  have := instruction.opcode.isLt
  have := instruction.pad.isLt
  unfold info
  omega

theorem immediate_bound (instruction : Instruction) : immediates instruction < 2^64 := by
  have := instruction.primary.isLt
  have := instruction.secondary.isLt
  unfold immediates
  omega

theorem record_injective (a b : Instruction) (header : info a = info b)
    (operands : immediates a = immediates b) : a = b := by
  have head := radix_injective (2^16) a.opcode.val a.pad.val b.opcode.val b.pad.val
    a.opcode.isLt b.opcode.isLt header
  have fields := radix_injective (2^32) a.primary.val a.secondary.val b.primary.val b.secondary.val
    a.primary.isLt b.primary.isLt operands
  cases a; cases b
  simp only [Instruction.mk.injEq]
  exact ⟨Fin.ext head.1, Fin.ext fields.1, Fin.ext fields.2, Fin.ext head.2⟩

theorem field_record_injective {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Instruction) (header : (info a : F) = (info b : F))
    (operands : (immediates a : F) = (immediates b : F)) : a = b := by
  apply record_injective a b
  · exact NumericEvents.nat_eq (F := F) _ _
      (by have := info_bound a; simp [NumericEvents.countBound]; omega)
      (by have := info_bound b; simp [NumericEvents.countBound]; omega) header
  · exact NumericEvents.nat_eq (F := F) _ _ (immediate_bound a) (immediate_bound b) operands

theorem program_refinement (source validated : List Instruction)
    (lengths : source.length = validated.length)
    (bound : ∀ i (a : i < source.length) (b : i < validated.length),
      info (source[i]'a) = info (validated[i]'b) ∧
      immediates (source[i]'a) = immediates (validated[i]'b)) : source = validated := by
  apply List.ext_getElem lengths
  intro i a b
  exact record_injective _ _ (bound i a b).1 (bound i a b).2

theorem validated_source (Valid : List Instruction → Prop) (source validated : List Instruction)
    (lengths : source.length = validated.length)
    (bound : ∀ i (a : i < source.length) (b : i < validated.length),
      info (source[i]'a) = info (validated[i]'b) ∧
      immediates (source[i]'a) = immediates (validated[i]'b))
    (checked : Valid validated) : Valid source := by
  rwa [program_refinement source validated lengths bound]

theorem source_key_injective (function pc otherFunction otherPc : Nat)
    (pcBound : pc < 2^32) (otherBound : otherPc < 2^32)
    (same : pc+2^32*function = otherPc+2^32*otherFunction) :
    pc = otherPc ∧ function = otherFunction :=
  radix_injective (2^32) pc function otherPc otherFunction pcBound otherBound same

theorem complete_instruction_bytes (first last position : Nat)
    (spans : List BinaryEnvelope.Section) (partition : BinaryEnvelope.Chain first spans last)
    (low : first ≤ position) (high : position < last) :
    ∃ span ∈ spans, span.first ≤ position ∧ position < span.finish :=
  BinaryEnvelope.full_coverage first last position spans partition low high

theorem byte_bound_branch (store : BranchLists.Store) (head : Nat) (declared source : List Nat)
    (list : BranchLists.Follows store head declared)
    (reads : BranchLists.Consumes store head source 0) : source = declared :=
  BranchLists.complete_consumption store head declared source list reads

theorem byte_bound_catches (store : CatchLists.Table) (head : Nat) (declared source : List CatchLists.Clause)
    (list : CatchLists.Represents store head declared)
    (reads : CatchLists.Walk store head source 0) : source = declared :=
  CatchLists.closed_walk store head declared source list reads

#print axioms field_record_injective
#print axioms program_refinement
#print axioms validated_source
#print axioms source_key_injective
#print axioms complete_instruction_bytes
#print axioms byte_bound_branch
#print axioms byte_bound_catches

end ZkBuild.InstructionSource
