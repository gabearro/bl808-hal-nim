import ReadOnlyMatrix

namespace ZkBuild.ReadOnlySound
open Lean.Grind CircuitShape FullMatrix GadgetShape ReadOnlyMatrix ShaProgram BinaryReadMemory
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

private theorem step_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (width : Nat) (widthBound : width ≤ 64) (prior current : ReadOnlyMatrix.Entry) (step : Step)
    (checked : RangeUse.check matrix step.range step.delta width = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (p c : MemoryTrace.Entry) (pi : Image values (ReadOnlyMatrix.initializer prior) p)
    (ci : Image values (ReadOnlyMatrix.initializer current) c)
    (pb : p.address < 2^width) (cb : c.address < 2^width)
    (holds : AllHold values (stepGates prior current step)) :
    c.active = true → p.active = true ∧ p.address < c.address := by
  intro active
  have ca : E values current.active = 1 := by simpa [ReadOnlyMatrix.initializer,active] using ci.1
  have prefixGate := holds ⟨current.active,sub (constant 1) prior.active,constant 0⟩ (by simp [stepGates])
  change E values current.active*E values (sub (constant 1) prior.active) = E values (constant 0) at prefixGate
  rw [ca,eval_sub,eval_constant values oneValue,eval_constant values oneValue] at prefixGate
  have pa : p.active = true := by
    have image : E values prior.active = (p.active.toNat : F) := pi.1
    rw [image] at prefixGate
    cases flag : p.active with
    | true => rfl
    | false =>
      have impossible : (1 : F) = 0 := by
        simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at prefixGate
        grind
      exact False.elim (Field.zero_ne_one impossible.symm)
  have select := select_sound values current.active (sub (sub current.address prior.address) (constant 1)) (constant 0) step.delta
    (holds _ (by simp [stepGates]))
  obtain ⟨delta,db,di⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix step.range step.delta width checked values oneValue satisfied)
  have caa : E values current.address = (c.address : F) := ci.2.2.1
  have paa : E values prior.address = (p.address : F) := pi.2.2.1
  have orderEquation : (c.address : F)-(p.address : F)-1 = (delta : F) := by
    rw [ca,eval_sub,eval_sub,eval_constant values oneValue,eval_constant values oneValue,caa,paa,di] at select
    grind
  have small : 2*2^width < scalarModulus := by
    have power : 2^width ≤ 2^64 := Nat.pow_le_pow_right (by decide) widthBound
    have large : 2*2^64 < scalarModulus := by decide
    omega
  exact ⟨pa,ReadOnlyMemory.order_gate (F := F) (2^width) p.address c.address delta pb cb db small orderEquation⟩

theorem tail_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (width : Nat) (widthBound : width ≤ 64) (values : Nat → F)
    (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List ReadOnlyMatrix.Entry) (decoded : List MemoryTrace.Entry)
    (images : Related (Image values) (rows.map ReadOnlyMatrix.initializer) decoded)
    (prior : ReadOnlyMatrix.Entry) (p : MemoryTrace.Entry) (pi : Image values (ReadOnlyMatrix.initializer prior) p)
    (pb : p.address < 2^width) (bounds : ∀ e ∈ decoded, e.address < 2^width)
    (steps : List Step) (count : steps.length = rows.length)
    (checks : steps.all (fun s => RangeUse.check matrix s.range s.delta width) = true)
    (holds : AllHold values (orderGates (prior::rows) steps)) :
    ReadOnlyMemory.InitializerOrder (some p) decoded := by
  induction rows generalizing prior p decoded steps with
  | nil => cases images; trivial
  | cons row rows ih =>
    cases images with
    | cons image tail =>
      cases steps with
      | nil => simp at count
      | cons step steps =>
        have checked := List.all_eq_true.mp checks step (by simp)
        have restChecks : steps.all (fun s => RangeUse.check matrix s.range s.delta width) = true := by
          apply List.all_eq_true.mpr
          intro s sm; exact List.all_eq_true.mp checks s (by simp [sm])
        have head : AllHold values (stepGates prior row step) := by
          intro g gm; exact holds g (List.mem_append_left _ gm)
        have after : AllHold values (orderGates (row::rows) steps) := by
          intro g gm; exact holds g (List.mem_append_right _ gm)
        have first := step_order matrix width widthBound prior row step checked values oneValue satisfied p _ pi image pb (bounds _ (by simp)) head
        refine ⟨?_,?_⟩
        · intro earlier same active
          cases same
          exact first active
        · exact ih _ tail row _ image (bounds _ (by simp))
            (by intro e em; exact bounds e (by simp [em])) steps (by simpa using count) restChecks after

theorem initializer_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (width : Nat) (widthBound : width ≤ 64) (values : Nat → F)
    (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List ReadOnlyMatrix.Entry) (decoded : List MemoryTrace.Entry)
    (images : Related (Image values) (rows.map ReadOnlyMatrix.initializer) decoded)
    (bounds : ∀ e ∈ decoded, e.address < 2^width) (steps : List Step) (count : steps.length = rows.length-1)
    (checks : steps.all (fun s => RangeUse.check matrix s.range s.delta width) = true)
    (holds : AllHold values (orderGates rows steps)) : ReadOnlyMemory.InitializerOrder none decoded := by
  cases rows with
  | nil => cases images; trivial
  | cons prior rows =>
    cases images with
    | cons pi images =>
      refine ⟨?_,?_⟩
      · intro p same; cases same
      · exact tail_order matrix width widthBound values oneValue satisfied rows _ images prior _ pi (bounds _ (by simp))
          (by intro e em; exact bounds e (by simp [em])) steps (by simpa using count) checks holds

/-- Every active query returns the unique active initializer at its address.
    Table meaning (for example, signature membership) is a separate binding. -/
theorem checked_membership {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (accepted : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ initializers queries : List MemoryTrace.Entry,
      Related (Image values) (r.entries.map ReadOnlyMatrix.initializer) initializers ∧
      Related (Image values) (r.queries.map readAccess) queries ∧
      ReadOnlyMemory.InitializerOrder none initializers ∧ ReadOnlyMemory.Unique initializers ∧
      (∀ q ∈ queries, q.active = true → ∃ entry ∈ initializers,
        entry.active = true ∧ entry.address = q.address ∧ entry.value = q.value) ∧
      (∀ e ∈ initializers++queries, MemoryConstraints.Bounded (2^r.memory.addressBits) (2^r.memory.timeBits) (2^r.memory.valueBits) e) ∧
      (∀ q ∈ r.queries, E values q.active = 1 → ∃ entry ∈ r.entries,
        E values entry.active = 1 ∧ E values entry.address = E values q.address ∧ E values entry.value = E values q.value) := by
  have parts :
      (r.steps.length = r.entries.length-1 ∧ r.entries.length+r.queries.length ≤ r.memory.inputs.length ∧
        (r.memory.inputs.map (fun x => normalizedPayload x.fields)) =
          (ReadOnlyMatrix.expected r.entries r.queries r.memory.inputs.length).map normalizedPayload) ∧
      r.steps.all (fun step => RangeUse.check matrix step.range step.delta r.memory.addressBits) = true ∧
      MemoryEvidence.checkSpan matrix r.firstGate r.preludeEnd (orderGates r.entries r.steps) = true ∧
      MemoryEmbedded.check matrix r.memory = true := by
    simpa only [ReadOnlyMatrix.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  have memoryShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.2.2.2).1).1).1
  obtain ⟨chronological,sorted,images,_,_,reads,bounds,_,_⟩ := MemoryEmbedded.checked_memory matrix r.memory parts.2.2.2 values oneValue satisfied
  have payloads := payload_images values _ _ chronological (by simpa only [List.map_map,Function.comp_def] using parts.1.2.2) images
  obtain ⟨initializers,rest,chrono,initImages,restImages⟩ := related_split (Image values) (r.entries.map ReadOnlyMatrix.initializer)
    (r.queries.map readAccess ++ List.replicate (r.memory.inputs.length-r.entries.length-r.queries.length) padding) chronological
    (by simpa only [ReadOnlyMatrix.expected,List.append_assoc] using payloads)
  obtain ⟨queries,padded,restSame,queryImages,padImages⟩ := related_split (Image values) (r.queries.map readAccess)
    (List.replicate (r.memory.inputs.length-r.entries.length-r.queries.length) padding) rest restImages
  have noWrites : ∀ q ∈ rest, q.write = false := by
    intro q member
    obtain ⟨a,am,image⟩ := right_member (Image values) _ _ restImages q member
    have writeZero : a.write = constant 0 := by
      rcases List.mem_append.mp am with query | pad
      · obtain ⟨q,_,rfl⟩ := List.mem_map.mp query; rfl
      · have eq : a = padding := List.eq_of_mem_replicate pad; simp [eq,padding]
    have zero : (q.write.toNat : F) = 0 := by
      have eq := image.2.1.symm
      rw [writeZero,eval_constant values oneValue] at eq
      simpa using eq
    cases h : q.write with
    | false => rfl
    | true => simp [h] at zero; exact False.elim (Field.zero_ne_one zero.symm)
  have initBounds : ∀ e ∈ initializers, e.address < 2^r.memory.addressBits := by
    intro e em
    exact (bounds e (by rw [chrono]; exact List.mem_append_left _ em)).1
  have order := initializer_order matrix r.memory.addressBits memoryShape.2.1 values oneValue satisfied r.entries initializers initImages initBounds r.steps parts.1.1 parts.2.1
    (ReadOnlyMatrix.checked_holds matrix r accepted values satisfied)
  have unique := ReadOnlyMemory.strict_unique initializers (ReadOnlyMemory.ordered_initializers initializers none order)
  have membership := ReadOnlyMemory.membership initializers rest noWrites (by simpa only [← chrono] using reads)
  have queryMembership : ∀ q ∈ queries, q.active = true → ∃ entry ∈ initializers,
      entry.active = true ∧ entry.address = q.address ∧ entry.value = q.value := by
    intro q qm qa
    obtain ⟨entry,em,ea,_,address,value⟩ := membership q (by rw [restSame]; exact List.mem_append_left _ qm) qa
    exact ⟨entry,em,ea,address,value⟩
  have boundResult : ∀ e ∈ initializers++queries, MemoryConstraints.Bounded (2^r.memory.addressBits) (2^r.memory.timeBits) (2^r.memory.valueBits) e := by
    intro e member
    apply bounds e
    rw [chrono,restSame]
    rcases List.mem_append.mp member with init | query
    · exact List.mem_append_left _ init
    · exact List.mem_append_right _ (List.mem_append_left _ query)
  refine ⟨initializers,queries,initImages,queryImages,order,unique,queryMembership,boundResult,?_⟩
  intro q qm qa
  obtain ⟨decoded,dm,di⟩ := left_member (Image values) _ _ queryImages (readAccess q) (List.mem_map.mpr ⟨q,qm,rfl⟩)
  have da : decoded.active = true := by
    have a : (decoded.active.toNat : F) = 1 := di.1.symm.trans qa
    cases active : decoded.active with
    | true => rfl
    | false => simp [active] at a; exact False.elim (Field.zero_ne_one a)
  obtain ⟨entry,em,ea,address,value⟩ := queryMembership decoded dm da
  obtain ⟨actual,am,ai⟩ := right_member (Image values) _ _ initImages entry em
  obtain ⟨original,om,rfl⟩ := List.mem_map.mp am
  refine ⟨original,om,?_,?_,?_⟩
  · simpa [ReadOnlyMatrix.initializer,ea] using ai.1
  · exact ai.2.2.1.trans (by rw [address]; exact di.2.2.1.symm)
  · exact ai.2.2.2.trans (by rw [value]; exact di.2.2.2.symm)

/-- A caller that identifies an active expected entry by key gets that
    entry's value; it need not trust a separate host-side table lookup. -/
theorem checked_expected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (accepted : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (query expected : ReadOnlyMatrix.Entry) (qm : query ∈ r.queries) (em : expected ∈ r.entries)
    (qa : E values query.active = 1) (ea : E values expected.active = 1)
    (address : E values expected.address = E values query.address) :
    E values query.value = E values expected.value := by
  obtain ⟨initializers,queries,initImages,queryImages,_,unique,membership,bounds,_⟩ := checked_membership matrix r accepted values oneValue satisfied
  obtain ⟨q,qmem,qi⟩ := left_member (Image values) _ _ queryImages (readAccess query) (List.mem_map.mpr ⟨query,qm,rfl⟩)
  obtain ⟨e,emem,ei⟩ := left_member (Image values) _ _ initImages (ReadOnlyMatrix.initializer expected) (List.mem_map.mpr ⟨expected,em,rfl⟩)
  have active_from_image (b : Bool) (image : (b.toNat : F) = 1) : b = true := by
    cases flag : b with
    | true => rfl
    | false => simp [flag] at image; exact False.elim (Field.zero_ne_one image)
  have qactive := active_from_image q.active (qi.1.symm.trans qa)
  have eactive := active_from_image e.active (ei.1.symm.trans ea)
  have memoryCheck := (Bool.and_eq_true_iff.mp accepted).2
  have memoryShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp memoryCheck).1).1).1
  have small : 2^r.memory.addressBits < scalarModulus := RangeConstraints.power_below_modulus _ (by have bound := memoryShape.2.1; omega)
  have eb := (bounds e (List.mem_append_left _ emem)).1
  have qb := (bounds q (List.mem_append_right _ qmem)).1
  have sameAddress : e.address = q.address := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans eb small) (Nat.lt_trans qb small)).mp (ei.2.2.1.symm.trans (address.trans qi.2.2.1))
  obtain ⟨actual,am,aa,ak,av⟩ := membership q qmem qactive
  have sameEntry := ReadOnlyMemory.member_unique initializers unique actual e am emem aa eactive (ak.trans sameAddress.symm)
  have value : q.value = e.value := by simpa [sameEntry] using av.symm
  exact qi.2.2.2.trans (by rw [value]; exact ei.2.2.2.symm)

#print axioms initializer_order
#print axioms checked_membership
#print axioms checked_expected
end ZkBuild.ReadOnlySound
