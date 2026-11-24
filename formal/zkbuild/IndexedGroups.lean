import IndexedNodeTable

namespace ZkBuild.IndexedGroups
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix IndexedMatrix IndexedCell
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

structure Banks where
  members : ReadOnlyMatrix.Record
  lengths : ReadOnlyMatrix.Record
  nodes : ReadOnlyMatrix.Record

structure CheckedBanks (matrix : Shape) (b : Banks) (rows : List MemberRow) : Prop where
  membersChecked : ReadOnlyMatrix.check matrix b.members = true
  lengthsChecked : ReadOnlyMatrix.check matrix b.lengths = true
  nodesChecked : ReadOnlyMatrix.check matrix b.nodes = true
  memberEntries : b.members.entries = rows.map MemberRow.entry
  lengthWidth : b.lengths.memory.valueBits = 32
  lengthQueries : ∀ r ∈ rows, r.lengthQuery ∈ b.lengths.queries
  nodeQueries : ∀ r ∈ rows, r.nodeQuery ∈ b.nodes.queries

theorem coordinates {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (r : MemberRow) (index : Nat) (ph po pn : Linear) (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ head ordinal next : Nat, head < 2^32 ∧ ordinal < 2^32 ∧ next < 2^32 ∧
      E values (address splits r).high = (head : F) ∧ E values (address splits r).low = (ordinal : F) ∧ E values (node splits r).high = (next : F) := by
  have shape := metadata matrix splits r index ph po pn checked
  have am : address splits r ∈ splits := by rw [address,split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.1
  have nm : node splits r ∈ splits := by rw [node,split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.1
  obtain ⟨_,ordinal,head,_,ob,hb,_,oi,hi,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ am) values oneValue satisfied
  obtain ⟨_,_,next,_,_,nb,_,_,ni,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ nm) values oneValue satisfied
  exact ⟨head,ordinal,next,by simpa [shape.2.2.2.1.2.2] using hb,by simpa [shape.2.2.2.1.2.1] using ob,
    by simpa [shape.2.2.2.2.2.1.2.2] using nb,hi,oi,ni⟩

theorem inactive_continuation {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (index : Nat) (positive : 0 < index) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) (inactive : E values r.entry.active = 0) : E values r.continuing = 0 := by
  have all := holds matrix splits r index ph po pn checked values satisfied
  have part := part_holds values splits r index ph po pn all 8 (by decide)
  have product := multiply_sound values r.entry.active (wire r.continuationZero) r.continuing
    (part _ (by simp [memberParts,Nat.ne_of_gt positive]))
  simpa only [inactive,Semiring.zero_mul] using product

theorem entry_active {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (b : Banks) (rows : List MemberRow) (banks : CheckedBanks matrix b rows)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (row : MemberRow) (member : row ∈ rows) :
    E values row.entry.active = 0 ∨ E values row.entry.active = 1 := by
  have em : row.entry ∈ b.members.entries := by rw [banks.memberEntries]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  obtain ⟨active,_,_,_,_,image,_,_⟩ := ReadOnlyFacts.entry_fields matrix b.members banks.membersChecked values oneValue satisfied row.entry em
  cases active
  · exact Or.inl (by simpa using image)
  · exact Or.inr (by simpa using image)

theorem length_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (b : Banks) (rows : List MemberRow) (banks : CheckedBanks matrix b rows)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (row : MemberRow) (member : row ∈ rows) :
    ∃ length : Nat, length < 2^32 ∧ E values row.lengthQuery.value = (length : F) := by
  obtain ⟨length,bound,image⟩ := ReadOnlyFacts.query_value matrix b.lengths banks.lengthsChecked values oneValue satisfied row.lengthQuery (banks.lengthQueries row member)
  exact ⟨length,by simpa [banks.lengthWidth] using bound,image⟩

theorem node_found {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (b : Banks) (rows : List MemberRow) (banks : CheckedBanks matrix b rows)
    (r : MemberRow) (member : r ∈ rows) (index : Nat) (ph po pn : Linear)
    (checked : checkMember matrix splits r index ph po pn = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (db : Bounded d) (di : Represents values splits r d) (active : E values r.entry.active = 1) :
    IndexedNodeTable.table values b.nodes d.cursor = some ⟨d.tag,d.next⟩ := by
  have a := (metadata matrix splits r index ph po pn checked).2.2.2.2.2.2.1
  apply IndexedNodeTable.found matrix b.nodes banks.nodesChecked values oneValue satisfied d.cursor ⟨d.tag,d.next⟩
  exact ⟨db.2.2.2,r.nodeQuery,banks.nodeQueries r member,by rw [a]; exact active,di.2.2.2.2.2.2.2.2.1,di.2.2.2.2.2.2.2.2.2.1⟩

theorem last_cell {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (next : Linear) (closing : CloseRow)
    (checked : MemoryEvidence.checkSpan matrix closing.firstGate closing.lastGate (closeGates splits r next) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (db : Bounded d) (di : Represents values splits r d) (active : E values r.entry.active = 1)
    (finished : E values next = 0) (length : Nat) (lb : length < 2^32) (li : E values r.lengthQuery.value = (length : F))
    (table : SignatureLists.Table) (nonzero : d.cursor ≠ 0) (found : table d.cursor = some ⟨d.tag,d.next⟩) :
    ∃ tags : List Nat, SignatureLists.Represents table d.cursor (d.tag.val::tags) ∧ d.ordinal+1+tags.length = length := by
  have last := IndexedStep.close_step matrix splits r next closing checked values oneValue satisfied d di db active finished length lb li
  refine ⟨[],.cons nonzero found ?_,by simpa using last.2⟩
  simpa [last.1] using (SignatureLists.Represents.nil (table := table))

/-- Following the actual adjacent member rows reaches nil at exactly the
    authenticated length; a group cannot omit, reorder, or invent a node. -/
theorem suffix_list {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (b : Banks) (rows : List MemberRow) (banks : CheckedBanks matrix b rows)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rest : List MemberRow) (r : MemberRow) (subset : r::rest ⊆ rows)
    (index : Nat) (ph po pn : Linear) (checked : checkMembers matrix splits (r::rest) index ph po pn = true)
    (closing : List CloseRow) (closed : checkClosing matrix splits (r::rest) closing = true)
    (d : Decoded) (db : Bounded d) (di : Represents values splits r d) (nonzero : d.cursor ≠ 0) (active : E values r.entry.active = 1)
    (length : Nat) (lb : length < 2^32) (li : E values r.lengthQuery.value = (length : F)) :
    ∃ tags : List Nat, SignatureLists.Represents (IndexedNodeTable.table values b.nodes) d.cursor (d.tag.val::tags) ∧
      d.ordinal+1+tags.length = length := by
  induction rest generalizing r index ph po pn closing d length with
  | nil =>
    cases closing with
    | nil => simp [checkClosing] at closed
    | cons c cs =>
      have closeCheck := (Bool.and_eq_true_iff.mp closed).1
      have rowCheck := (Bool.and_eq_true_iff.mp checked).1
      have found := node_found matrix splits b rows banks r (subset (by simp)) index ph po pn rowCheck values oneValue satisfied d db di active
      exact last_cell matrix splits r z c closeCheck values oneValue satisfied d db di active (by simp [z,eval_constant values oneValue]) length lb li _ nonzero found
  | cons next rest ih =>
    cases closing with
    | nil => simp [checkClosing] at closed
    | cons c cs =>
      have checks := Bool.and_eq_true_iff.mp checked
      have closeChecks := Bool.and_eq_true_iff.mp closed
      have nextChecks := Bool.and_eq_true_iff.mp checks.2
      have nextMember : next ∈ rows := subset (by simp)
      have found := node_found matrix splits b rows banks r (subset (by simp)) index ph po pn checks.1 values oneValue satisfied d db di active
      rcases entry_active matrix b rows banks values oneValue satisfied next nextMember with inactive | nextActive
      · have finish := inactive_continuation matrix splits next (index+1) (by omega) _ _ _ nextChecks.1 values satisfied inactive
        exact last_cell matrix splits r next.continuing c closeChecks.1 values oneValue satisfied d db di active finish length lb li _ nonzero found
      · obtain ⟨nd,nb,ni,_,nz⟩ := decode matrix splits splitChecks next (index+1) _ _ _ nextChecks.1 values oneValue satisfied nextActive
        have continuation := IndexedStep.continuation matrix splits next (index+1) _ _ _ nextChecks.1 values oneValue satisfied nd ni nb nextActive d.head db.1 di.1
        by_cases sameHead : nd.head = d.head
        · have continuing : E values next.continuing = 1 := by simpa [sameHead] using continuation
          have step := IndexedStep.continue_step matrix splits next (index+1) (by omega) _ _ _ nextChecks.1 values oneValue satisfied nd ni nb continuing d.ordinal d.next db.2.1 db.2.2.2 di.2.1 di.2.2.2.2.1
          have ca := (metadata matrix splits r index ph po pn checks.1).2.2.2.2.2.2.2.1
          have na := (metadata matrix splits next (index+1) _ _ _ nextChecks.1).2.2.2.2.2.2.2.1
          have nextLength := ReadOnlyFacts.queries_agree matrix b.lengths banks.lengthsChecked values oneValue satisfied next.lengthQuery r.lengthQuery (banks.lengthQueries next nextMember) (banks.lengthQueries r (subset (by simp)))
            (by rw [na]; exact nextActive) (by rw [ca]; exact active)
            (by rw [ni.2.2.2.2.2.2.2.2.2.2,di.2.2.2.2.2.2.2.2.2.2,sameHead])
          obtain ⟨tail,rep,count⟩ := ih next (by intro x xm; exact subset (by simp only [List.mem_cons] at xm ⊢; exact Or.inr xm))
            (index+1) _ _ _ checks.2 cs closeChecks.2 nd nb ni nz nextActive length lb (nextLength.trans li)
          refine ⟨nd.tag.val::tail,.cons nonzero found ?_,?_⟩
          · simpa [step.2] using rep
          · simp only [List.length_cons]; omega
        · have finish : E values next.continuing = 0 := by simpa [sameHead] using continuation
          exact last_cell matrix splits r next.continuing c closeChecks.1 values oneValue satisfied d db di active finish length lb li _ nonzero found

#print axioms coordinates
#print axioms suffix_list

def Recorded {F : Type} [CommRing F] (values : Nat → F) (rows : List MemberRow) (head : Nat) (cells : List IndexedSignatures.Cell) : Prop :=
  ∀ cell ∈ cells, cell.cursor < 2^32 ∧ cell.ordinal < 2^32 ∧ ∃ row ∈ rows, E values row.entry.active = 1 ∧
    E values row.entry.address = ((cell.ordinal+2^32*head : Nat) : F) ∧
    E values row.entry.value = ((cell.tag.val+8*cell.cursor : Nat) : F)

def toCell (d : Decoded) : IndexedSignatures.Cell := ⟨d.ordinal,d.cursor,d.tag,d.next⟩

theorem last_cells {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (r : MemberRow) (next : Linear) (closing : CloseRow)
    (checked : MemoryEvidence.checkSpan matrix closing.firstGate closing.lastGate (closeGates splits r next) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : Decoded) (db : Bounded d) (di : Represents values splits r d) (active : E values r.entry.active = 1)
    (finished : E values next = 0) (length : Nat) (lb : length < 2^32) (li : E values r.lengthQuery.value = (length : F))
    (table : SignatureLists.Table) (nonzero : d.cursor ≠ 0) (found : table d.cursor = some ⟨d.tag,d.next⟩)
    (rows : List MemberRow) (member : r ∈ rows) :
    ∃ cells : List IndexedSignatures.Cell, IndexedSignatures.Rows table d.ordinal d.cursor length cells ∧ Recorded values rows d.head cells := by
  have last := IndexedStep.close_step matrix splits r next closing checked values oneValue satisfied d di db active finished length lb li
  refine ⟨[toCell d],⟨rfl,rfl,nonzero,found,?_,?_⟩,?_⟩
  · exact last.2
  · exact last.1
  · intro c cm
    have same : c = toCell d := by simpa using cm
    subst c
    exact ⟨db.2.2.1,db.2.1,r,member,active,di.2.2.2.2.2.2.1,di.2.2.2.2.2.2.2.1⟩

/-- Besides list semantics, retain the exact immutable-table record for
    every position. This makes later ordinal lookups provably refer to the
    represented list rather than a separate cache. -/
theorem suffix_cells {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (b : Banks) (rows : List MemberRow) (banks : CheckedBanks matrix b rows)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rest : List MemberRow) (r : MemberRow) (subset : r::rest ⊆ rows)
    (index : Nat) (ph po pn : Linear) (checked : checkMembers matrix splits (r::rest) index ph po pn = true)
    (closing : List CloseRow) (closed : checkClosing matrix splits (r::rest) closing = true)
    (d : Decoded) (db : Bounded d) (di : Represents values splits r d) (nonzero : d.cursor ≠ 0) (active : E values r.entry.active = 1)
    (length : Nat) (lb : length < 2^32) (li : E values r.lengthQuery.value = (length : F)) :
    ∃ cells : List IndexedSignatures.Cell,
      IndexedSignatures.Rows (IndexedNodeTable.table values b.nodes) d.ordinal d.cursor length cells ∧ Recorded values rows d.head cells := by
  induction rest generalizing r index ph po pn closing d length with
  | nil =>
    cases closing with
    | nil => simp [checkClosing] at closed
    | cons c cs =>
      have closeCheck := (Bool.and_eq_true_iff.mp closed).1
      have rowCheck := (Bool.and_eq_true_iff.mp checked).1
      have found := node_found matrix splits b rows banks r (subset (by simp)) index ph po pn rowCheck values oneValue satisfied d db di active
      exact last_cells matrix splits r z c closeCheck values oneValue satisfied d db di active (by simp [z,eval_constant values oneValue]) length lb li _ nonzero found rows (subset (by simp))
  | cons next rest ih =>
    cases closing with
    | nil => simp [checkClosing] at closed
    | cons c cs =>
      have checks := Bool.and_eq_true_iff.mp checked
      have closeChecks := Bool.and_eq_true_iff.mp closed
      have nextChecks := Bool.and_eq_true_iff.mp checks.2
      have nextMember : next ∈ rows := subset (by simp)
      have found := node_found matrix splits b rows banks r (subset (by simp)) index ph po pn checks.1 values oneValue satisfied d db di active
      rcases entry_active matrix b rows banks values oneValue satisfied next nextMember with inactive | nextActive
      · have finish := inactive_continuation matrix splits next (index+1) (by omega) _ _ _ nextChecks.1 values satisfied inactive
        exact last_cells matrix splits r next.continuing c closeChecks.1 values oneValue satisfied d db di active finish length lb li _ nonzero found rows (subset (by simp))
      · obtain ⟨nd,nb,ni,_,nz⟩ := decode matrix splits splitChecks next (index+1) _ _ _ nextChecks.1 values oneValue satisfied nextActive
        have continuation := IndexedStep.continuation matrix splits next (index+1) _ _ _ nextChecks.1 values oneValue satisfied nd ni nb nextActive d.head db.1 di.1
        by_cases sameHead : nd.head = d.head
        · have continuing : E values next.continuing = 1 := by simpa [sameHead] using continuation
          have step := IndexedStep.continue_step matrix splits next (index+1) (by omega) _ _ _ nextChecks.1 values oneValue satisfied nd ni nb continuing d.ordinal d.next db.2.1 db.2.2.2 di.2.1 di.2.2.2.2.1
          have ca := (metadata matrix splits r index ph po pn checks.1).2.2.2.2.2.2.2.1
          have na := (metadata matrix splits next (index+1) _ _ _ nextChecks.1).2.2.2.2.2.2.2.1
          have nextLength := ReadOnlyFacts.queries_agree matrix b.lengths banks.lengthsChecked values oneValue satisfied next.lengthQuery r.lengthQuery (banks.lengthQueries next nextMember) (banks.lengthQueries r (subset (by simp)))
            (by rw [na]; exact nextActive) (by rw [ca]; exact active)
            (by rw [ni.2.2.2.2.2.2.2.2.2.2,di.2.2.2.2.2.2.2.2.2.2,sameHead])
          obtain ⟨tail,tailRows,recorded⟩ := ih next (by intro x xm; exact subset (by simp only [List.mem_cons] at xm ⊢; exact Or.inr xm))
            (index+1) _ _ _ checks.2 cs closeChecks.2 nd nb ni nz nextActive length lb (nextLength.trans li)
          refine ⟨toCell d::tail,⟨rfl,rfl,nonzero,found,?_⟩,?_⟩
          · simpa [toCell,step.1,step.2] using tailRows
          · intro cell member
            rcases List.mem_cons.mp member with rfl | later
            · exact ⟨db.2.2.1,db.2.1,r,subset (by simp),active,di.2.2.2.2.2.2.1,di.2.2.2.2.2.2.2.1⟩
            · simpa [sameHead] using recorded cell later
        · have finish : E values next.continuing = 0 := by simpa [sameHead] using continuation
          exact last_cells matrix splits r next.continuing c closeChecks.1 values oneValue satisfied d db di active finish length lb li _ nonzero found rows (subset (by simp))

#print axioms suffix_cells
end ZkBuild.IndexedGroups
