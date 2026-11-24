import SignatureFunctionSource

namespace ZkBuild.SignatureNodes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix SignatureMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem part_holds {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : NodeRow)
    (all : AllHold values (nodeGates splits r)) (i : Nat) (bound : i < 5) :
    AllHold values ((nodeParts splits r).getD i []) := by
  have b : i < (nodeParts splits r).length := by simpa [nodeParts] using bound
  have m : (nodeParts splits r).getD i [] ∈ nodeParts splits r := by rw [← List.getElem_eq_getD []]; exact List.getElem_mem b
  intro g gm; exact all g (List.mem_flatten.mpr ⟨_,m,gm⟩)

theorem node_structure {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : NodeRow) (checked : SignatureMatrix.checkNode matrix splits r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (ib : id < 2^32) (ii : E values r.entry.address = (id : F)) (active : E values r.entry.active = 1) :
    ∃ tag : Fin 7, ∃ next : Nat, next < 2^32 ∧ next < id ∧
      E values r.entry.value = ((tag.val+8*next : Nat) : F) ∧
      E values r.reference.query.active = (if next = 0 then 0 else 1) ∧ E values r.reference.query.address = (next : F) := by
  have first := (Bool.and_eq_true_iff.mp checked).1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp first).1
  have sm : split splits r.node ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.1
  obtain ⟨v,tag,next,vb,tb,nb,vi,ti,ni,packed,_,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ sm) values oneValue satisfied
  have tagBound : tag < 8 := by simpa [shape.2.2.1] using tb
  have nextBound : next < 2^32 := by simpa [shape.2.2.2] using nb
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have zeroPart := part_holds values splits r all 1 (by decide)
  have zi := zero_sound values oneValue (sub (split splits r.node).low (n 7)) (wire r.tagZero) (wire (r.tagZero+1))
    (by intro g gm; exact zeroPart g (List.mem_append_left _ gm))
  have ze := equality_sound values oneValue (wire r.tagZero) z (zeroPart _ (by simp [nodeParts]))
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have seven : E values (n 7) = ((7 : Nat) : F) := (eval_constant values oneValue (Int.ofNat 7)).trans (Ring.intCast_natCast _)
  have tagSmall : tag < 7 := by
    by_cases same : tag = 7
    · have zt : E values (sub (split splits r.node).low (n 7)) = 0 := by rw [eval_sub,ti,seven,same]; grind
      rw [zt,ite_eq_left rfl] at zi
      rw [zero] at ze
      exact False.elim (Field.zero_ne_one (ze.symm.trans zi))
    · omega
  have range := (Bool.and_eq_true_iff.mp first).2
  obtain ⟨delta,db,di⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix r.deltaRange r.delta 32 range values oneValue satisfied)
  have selected := part_holds values splits r all 2 (by decide)
  have relation := select_sound values r.entry.active (sub (sub r.entry.address (split splits r.node).high) o) z r.delta (selected _ (by simp [nodeParts]))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [di,zero,active,eval_sub,eval_sub,ii,ni,one] at relation
  have less := ReadOnlyMemory.order_gate (F := F) (2^32) next id delta nextBound ib db (by decide) (by grind)
  have refs := part_holds values splits r all 4 (by decide)
  have refMeaning := SignatureRules.reference_meaning values oneValue r.entry.active (split splits r.node).high r.reference refs active next nextBound ni
  have valueImage : E values r.entry.value = ((tag+8*next : Nat) : F) := by rw [shape.2.1] at vi; simpa [packed,shape.2.2.1] using vi
  exact ⟨⟨tag,tagSmall⟩,next,nextBound,less,valueImage,refMeaning⟩

/-- Every active signature node has a supported tag and points either to
    nil or to an active, strictly smaller node in the same immutable table. -/
theorem checked_node {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : NodeRow) (member : row ∈ signature.nodes) (active : E values row.entry.active = 1) :
    ∃ id : Nat, ∃ tag : Fin 7, ∃ next : Nat,
      id < 2^32 ∧ E values row.entry.address = (id : F) ∧ next < id ∧
      E values row.entry.value = ((tag.val+8*next : Nat) : F) ∧
      (next ≠ 0 → ∃ following ∈ signature.nodes, E values following.entry.active = 1 ∧ E values following.entry.address = (next : F)) := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have inner := Bool.and_eq_true_iff.mp outer.1
  have declarationCheck := (Bool.and_eq_true_iff.mp inner.1).1
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).1).2
  have sig := inner.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at sig
  have nodeChecks : signature.nodes.all (SignatureMatrix.checkNode matrix splits) = true := by grind only
  have links : SignatureMatrix.checkLinks tables declaration indexed signature = true := by grind only
  have facts := _root_.of_decide_eq_true links
  let consumer := SignatureMatrix.table tables signature 1
  have cm : consumer ∈ tables := by
    have b : 1 < signature.tables.length := by rw [facts.1]; decide
    have m : signature.tables.getD 1 0 ∈ signature.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold consumer SignatureMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (facts.2.1 _ m)
  have cc := List.all_eq_true.mp tableChecks consumer cm
  have entries : consumer.entries = signature.nodes.map NodeRow.entry := facts.2.2.2.2.1
  have em : row.entry ∈ consumer.entries := by rw [entries]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  obtain ⟨_,id,_,ib,_,_,ii,_⟩ := ReadOnlyFacts.entry_fields matrix consumer cc values oneValue satisfied row.entry em
  have addrWidth : consumer.memory.addressBits = 32 := facts.2.2.2.2.2.2.2.2.2.2.2.1
  have bound : id < 2^32 := by simpa [addrWidth] using ib
  obtain ⟨tag,next,_,less,value,ra,rk⟩ := node_structure matrix splits splitChecks row (List.all_eq_true.mp nodeChecks row member) values oneValue satisfied id bound ii active
  refine ⟨id,tag,next,bound,ii,less,value,?_⟩
  intro nonzero
  have queries : consumer.queries = signature.metadata.flatMap (fun m => [m.params.query,m.results.query])++signature.nodes.map (fun n => n.reference.query)++signature.extraOperands := facts.2.2.2.2.2.1
  have qm : row.reference.query ∈ consumer.queries := by rw [queries]; exact List.mem_append_left _ (List.mem_append_right _ (List.mem_map.mpr ⟨row,member,rfl⟩))
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix consumer cc values oneValue satisfied
  obtain ⟨entry,found,ea,ek,_⟩ := membership row.reference.query qm (by simpa [nonzero] using ra)
  rw [entries] at found
  obtain ⟨following,fm,same⟩ := List.mem_map.mp found
  subst entry
  exact ⟨following,fm,ea,ek.trans rk⟩

#print axioms node_structure
#print axioms checked_node
end ZkBuild.SignatureNodes
