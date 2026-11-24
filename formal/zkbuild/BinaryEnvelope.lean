import BinarySource
import BulkContext

namespace ZkBuild.BinaryEnvelope

structure Section where
  first : Nat
  body : Nat
  size : Nat
  finish : Nat

def WellFormed (record : Section) : Prop :=
  record.first < record.body ∧ record.finish = record.body+record.size

inductive Chain : Nat → List Section → Nat → Prop where
  | nil (position : Nat) : Chain position [] position
  | cons {first finish : Nat} {record : Section} {rest : List Section} :
      record.first = first → WellFormed record → Chain record.finish rest finish →
      Chain first (record :: rest) finish

theorem chain_monotone (first last : Nat) (sections : List Section)
    (chain : Chain first sections last) : first ≤ last := by
  induction chain with
  | nil => omega
  | cons head formed _ ih => rcases formed with ⟨positive, size⟩; omega

theorem full_coverage (first last position : Nat) (sections : List Section)
    (chain : Chain first sections last) (lower : first ≤ position) (upper : position < last) :
    ∃ record ∈ sections, record.first ≤ position ∧ position < record.finish := by
  induction chain with
  | nil => omega
  | @cons first last record rest head formed tail ih =>
    by_cases inside : position < record.finish
    · exact ⟨record, by simp, by omega, inside⟩
    · obtain ⟨other, member, bounds⟩ := ih (by omega) upper
      exact ⟨other, by simp [member], bounds⟩

theorem member_after_start (first last : Nat) (sections : List Section)
    (chain : Chain first sections last) (record : Section) (member : record ∈ sections) :
    first ≤ record.first := by
  induction chain with
  | nil => simp at member
  | @cons first last head rest same formed tail ih =>
    rcases List.mem_cons.mp member with rfl | later
    · omega
    · have bound := ih later
      rcases formed with ⟨positive, size⟩
      omega

theorem disjoint_sections (first last : Nat) (sections : List Section)
    (chain : Chain first sections last) :
    sections.Pairwise fun a b => a.finish ≤ b.first := by
  induction chain with
  | nil => exact .nil
  | @cons first last head rest same formed tail ih =>
    exact .cons (fun other member => member_after_start head.finish last rest tail other member) ih

#print axioms chain_monotone
#print axioms full_coverage
#print axioms member_after_start
#print axioms disjoint_sections

end ZkBuild.BinaryEnvelope
