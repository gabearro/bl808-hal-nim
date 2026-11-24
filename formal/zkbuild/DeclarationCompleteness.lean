import DeclarationLocations

namespace ZkBuild.DeclarationCompleteness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def key (e : MemoryTrace.Entry) : Nat × Nat := (e.address / 2^32,e.address % 2^32)
def keys : List MemoryTrace.Entry → List (Nat × Nat)
  | [] => []
  | e::rest => if e.active then key e::keys rest else keys rest

theorem keys_length (entries : List MemoryTrace.Entry) : (keys entries).length = DeclarationCounts.vectorActive entries := by
  induction entries with
  | nil => rfl
  | cons e rest ih => cases flag : e.active <;> simp [keys,DeclarationCounts.vectorActive,flag,ih,Nat.add_comm]

theorem keys_member (entries : List MemoryTrace.Entry) (k : Nat × Nat) :
    k ∈ keys entries ↔ ∃ e ∈ entries, e.active = true ∧ key e = k := by
  induction entries with
  | nil => simp [keys]
  | cons e rest ih =>
    cases flag : e.active with
    | false =>
      rw [show keys (e::rest) = keys rest from by simp [keys,flag],ih]
      constructor
      · rintro ⟨other,member,active,same⟩
        exact ⟨other,by simp [member],active,same⟩
      · rintro ⟨other,member,active,same⟩
        rcases List.mem_cons.mp member with rfl | later
        · simp [flag] at active
        · exact ⟨other,later,active,same⟩
    | true =>
      rw [show keys (e::rest) = key e::keys rest from by simp [keys,flag]]
      constructor
      · intro member
        rcases List.mem_cons.mp member with first | later
        · exact ⟨e,by simp,flag,first.symm⟩
        · obtain ⟨other,member,active,same⟩ := ih.mp later
          exact ⟨other,by simp [member],active,same⟩
      · rintro ⟨other,member,active,same⟩
        rcases List.mem_cons.mp member with rfl | later
        · exact List.mem_cons.mpr (Or.inl same.symm)
        · exact List.mem_cons.mpr (Or.inr (ih.mpr ⟨other,later,active,same⟩))

theorem key_injective (a b : MemoryTrace.Entry) (same : key a = key b) : a.address = b.address := by
  have high := congrArg Prod.fst same
  have low := congrArg Prod.snd same
  simp only [key] at high low
  have ar := Nat.mod_add_div a.address (2^32)
  have br := Nat.mod_add_div b.address (2^32)
  omega

theorem keys_unique (entries : List MemoryTrace.Entry) (unique : ReadOnlyMemory.Unique entries) : (keys entries).Nodup := by
  induction entries with
  | nil => exact .nil
  | cons e rest ih =>
    obtain ⟨head,tail⟩ := List.pairwise_cons.mp unique
    cases flag : e.active with
    | false => simpa [keys,flag] using ih tail
    | true =>
      simp only [keys,flag,↓reduceIte,List.nodup_cons]
      refine ⟨?_,ih tail⟩
      intro member
      obtain ⟨other,om,oa,same⟩ := (keys_member rest (key e)).mp member
      exact head other om flag oa (key_injective e other same.symm)

theorem vector_keys_at (counts : List Nat) (start i ordinal : Nat) (ib : i < counts.length)
    (ob : ordinal < counts.getD i 0) : (start+i,ordinal) ∈ BinaryDeclarations.vectorKeys start counts := by
  induction counts generalizing start i with
  | nil => simp at ib
  | cons count rest ih =>
    cases i with
    | zero =>
      apply List.mem_append_left
      apply List.mem_map.mpr
      exact ⟨ordinal,List.mem_range.mpr ob,by simp⟩
    | succ i =>
      apply List.mem_append_right
      have later := ih (start+1) i (by simpa using ib) (by simpa using ob)
      simpa [Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using later

theorem arities_sum (types : List DeclarationType.Decoded) (params : Bool) :
    (types.map (arity params)).sum = if params then DeclarationCounts.typeParams types else DeclarationCounts.typeResults types := by
  induction types with
  | nil => cases params <;> rfl
  | cons d rest ih => cases params <;> simp_all [arity,DeclarationCounts.typeParams,DeclarationCounts.typeResults]

theorem active_count_unique {F : Type} [Field F] (values : Nat → F) (rows : List VectorRow)
    (a b : List MemoryTrace.Entry) (ai : Related (DeclarationOrder.Represents values) rows a)
    (bi : Related (DeclarationOrder.Represents values) rows b) :
    DeclarationCounts.vectorActive a = DeclarationCounts.vectorActive b := by
  induction ai generalizing b with
  | nil => cases bi; rfl
  | @cons row ae rows a image images ih =>
    cases bi with
    | @cons _ be _ b other others =>
      have same : ae.active = be.active := by
        have eq := image.1.symm.trans other.1
        cases fa : ae.active <;> cases fb : be.active <;> simp_all
        · exact False.elim (Field.zero_ne_one eq)
        · exact False.elim (Field.zero_ne_one eq.symm)
      simp [DeclarationCounts.vectorActive,same,ih b others]

/-- Each active key is the exact (type index, source ordinal) pair of an
    existing active type declaration. This rules out padding and stray keys. -/
theorem keys_bounded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (ti : Related (DeclarationType.Represents values) r.types types)
    (tb : ∀ d ∈ types, DeclarationType.Bounded d)
    (params : Bool) (entries : List MemoryTrace.Entry)
    (images : Related (DeclarationOrder.Represents values) (vectorRows r params) entries)
    (bounds : ∀ e ∈ entries, DeclarationOrder.Bounded e) :
    keys entries ⊆ BinaryDeclarations.vectorKeys 0 (types.map (arity params)) := by
  have record := (Bool.and_eq_true_iff.mp accepted).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at record
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have checks : checkVectors matrix body.tokens splits params (vectorRows r params) 0 o z z = true := by
    cases params <;> dsimp [vectorRows] <;> grind only
  intro k member
  obtain ⟨e,em,ea,ke⟩ := (keys_member entries k).mp member
  obtain ⟨row,rm,ri⟩ := BinaryReadMemory.right_member _ _ _ images e em
  obtain ⟨index,previous,address,count,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits params (vectorRows r params) 0 o z z checks row rm
  have active : E values (get row.fields 0) = 1 := by simpa [ea] using ri.1
  obtain ⟨typeIndex,ordinal,ib,enabled,ob,addressImage,_⟩ := checked_member matrix body tables splits r accepted values oneValue satisfied types ti tb params row rm index previous address count checked active
  have tl := related_length _ _ _ ti
  have indexSmall : typeIndex < 2^32 := by have bound := shape.1; omega
  have tm : types.getD typeIndex default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have ordinalSmall : ordinal < 2^32 := Nat.lt_trans ob (arity_bound params _ (tb _ tm)).1
  have same : e.address = ordinal+2^32*typeIndex := natural_equal (F := F) _ _ (bounds e em).1 (by omega) (ri.2.1.symm.trans addressImage)
  have pair : key e = (typeIndex,ordinal) := by
    simp only [key,same]
    simp [Nat.add_mul_div_left,Nat.div_eq_of_lt ordinalSmall,Nat.add_mod,Nat.mod_eq_of_lt ordinalSmall]
  rw [← ke,pair]
  have arityAt : (types.map (arity params)).getD typeIndex 0 = arity params (types.getD typeIndex default) := by
    simp only [List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem ib,Option.map_some,Option.getD_some]
  have found := vector_keys_at (types.map (arity params)) 0 typeIndex ordinal (by simpa using ib) (by rw [arityAt]; exact ob)
  simpa using found

theorem complete_group {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (ti : Related (DeclarationType.Represents values) r.types types)
    (tb : ∀ d ∈ types, DeclarationType.Bounded d)
    (params : Bool) (entries : List MemoryTrace.Entry)
    (images : Related (DeclarationOrder.Represents values) (vectorRows r params) entries)
    (bounds : ∀ e ∈ entries, DeclarationOrder.Bounded e) (unique : ReadOnlyMemory.Unique entries)
    (count : DeclarationCounts.vectorActive entries = (types.map (arity params)).sum) :
    (keys entries).Nodup ∧ keys entries ⊆ BinaryDeclarations.vectorKeys 0 (types.map (arity params)) ∧
      BinaryDeclarations.vectorKeys 0 (types.map (arity params)) ⊆ keys entries := by
  have ku := keys_unique entries unique
  have kb := keys_bounded matrix body tables splits r accepted values oneValue satisfied types ti tb params entries images bounds
  exact ⟨ku,kb,BinaryDeclarations.complete_vectors _ 0 _ ku kb (by rw [keys_length,count])⟩

/-- All declared parameter and result positions occur exactly once. The
    count, uniqueness, and membership premises are derived from the complete
    audited production matrix, rather than supplied by the host decoder. -/
theorem checked_complete_vectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ types : List DeclarationType.Decoded, ∃ params results : List MemoryTrace.Entry,
      Related (DeclarationType.Represents values) r.types types ∧
      Related (DeclarationOrder.Represents values) r.params params ∧ Related (DeclarationOrder.Represents values) r.results results ∧
      (∀ d ∈ types, DeclarationType.Bounded d) ∧
      (∀ e ∈ params, DeclarationOrder.Bounded e) ∧ (∀ e ∈ results, DeclarationOrder.Bounded e) ∧
      (keys params).Nodup ∧ (keys results).Nodup ∧
      keys params ⊆ BinaryDeclarations.vectorKeys 0 (types.map (arity true)) ∧
      BinaryDeclarations.vectorKeys 0 (types.map (arity true)) ⊆ keys params ∧
      keys results ⊆ BinaryDeclarations.vectorKeys 0 (types.map (arity false)) ∧
      BinaryDeclarations.vectorKeys 0 (types.map (arity false)) ⊆ keys results := by
  obtain ⟨types,cp,cr,ti,cpi,cri,tb,_,_,pc,rc,_⟩ := DeclarationCounts.checked_counts matrix body.tokens splits tables body.envelope r
    (Bool.and_eq_true_iff.mp accepted).2 values oneValue satisfied
  obtain ⟨params,results,pi,ri,pb,rb,pu,ru⟩ := DeclarationOrder.checked_declaration_order matrix body tables splits r accepted values oneValue satisfied
  have paramCount : DeclarationCounts.vectorActive params = (types.map (arity true)).sum := by
    rw [active_count_unique values r.params params cp pi cpi,pc,arities_sum]; rfl
  have resultCount : DeclarationCounts.vectorActive results = (types.map (arity false)).sum := by
    rw [active_count_unique values r.results results cr ri cri,rc,arities_sum]; rfl
  have paramsFull := complete_group matrix body tables splits r accepted values oneValue satisfied types ti tb true params pi pb pu paramCount
  have resultsFull := complete_group matrix body tables splits r accepted values oneValue satisfied types ti tb false results ri rb ru resultCount
  exact ⟨types,params,results,ti,pi,ri,tb,pb,rb,paramsFull.1,resultsFull.1,paramsFull.2.1,paramsFull.2.2,resultsFull.2.1,resultsFull.2.2⟩

#print axioms keys_bounded
#print axioms checked_complete_vectors
end ZkBuild.DeclarationCompleteness
