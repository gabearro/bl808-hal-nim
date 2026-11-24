import ValidationEventAuditIO
import StaticLookupSound
set_option autoImplicit false
set_option maxRecDepth 4096
namespace ZkBuild.ValidationEventSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def StageFacts {F : Type} [Field F] (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (values : Nat → F) (s : Stage) : Prop :=
  ∃ state, (ValidationEventCheck.replay matrix statics admission s).run (SourceProgram.init s.program) = .ok ((),state) ∧
    SourceProgram.finished s.program state ∧ BodySourceTheorems.StateMeaning matrix [] [] values state

def MemoryFacts {F : Type} [Field F] (values : Nat → F) (r : MemoryEmbedded.Record) : Prop :=
  ∃ chronological sorted : List MemoryTrace.Entry,
    ShaProgram.Related (MemoryPacking.Represents values) (r.inputs.map MemoryEvidence.AccessRef.fields) chronological ∧
    ShaProgram.Related (MemoryPacking.Represents values) (r.rows.map (fun row => row.access.fields)) sorted ∧
    chronological.Perm sorted ∧ MemoryTrace.Reads (fun _ => none) chronological ∧
    (∀ row ∈ chronological, MemoryConstraints.Bounded (2^r.addressBits) (2^r.timeBits) (2^r.valueBits) row) ∧
    (∀ row ∈ sorted, MemoryConstraints.Bounded (2^r.addressBits) (2^r.timeBits) (2^r.valueBits) row) ∧
    chronological.map MemoryTrace.Entry.time = List.range chronological.length

theorem stage {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog) (s : Stage)
    (checked : ValidationEventCheck.checkStage matrix statics admission s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    StageFacts matrix statics admission values s := by
  unfold ValidationEventCheck.checkStage at checked
  cases h : (ValidationEventCheck.replay matrix statics admission s).run (SourceProgram.init s.program) with
  | error e => simp [h] at checked
  | ok pair =>
    rcases pair with ⟨result,state⟩
    cases result
    rw [h] at checked
    exact ⟨state,h,_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1,
      SourceProgramSound.state matrix [] [] state (Bool.and_eq_true_iff.mp checked).2 values one satisfied⟩

theorem static_table (statics : StaticCatalog) (admission : LookupCatalog)
    (checked : ValidationEventAuditIO.catalogs statics admission = true)
    (id : Nat) (r : StaticLookupEmbedded.Record) (member : (id,r) ∈ statics) : StaticLookupEmbedded.checkTable r = true := by
  have checks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  cases h : statics with
  | nil => simp [h] at member
  | cons first rest =>
    rcases first with ⟨firstId,first⟩
    simp only [h,List.head?_cons] at checks
    have base := (Bool.and_eq_true_iff.mp checks).1
    have same : r.root = first.root ∧ r.nodes = first.nodes :=
      _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checks).2 (id,r) (by simpa [h] using member))
    simpa only [StaticLookupEmbedded.checkTable,same.1,same.2] using base

theorem admission_table (statics : StaticCatalog) (admission : LookupCatalog)
    (checked : ValidationEventAuditIO.catalogs statics admission = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ admission) :
    r.columns = 1 ∧ LookupEmbedded.checkTable r 16 ValidationEventAuditIO.allowed = true := by
  have checks := (Bool.and_eq_true_iff.mp checked).2
  cases h : admission with
  | nil => simp [h] at member
  | cons first rest =>
    rcases first with ⟨firstId,first⟩
    simp only [h,List.head?_cons] at checks
    have base := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checks).1).2
    have columns : first.columns = 1 := by simpa using (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checks).1).1
    have same : r.columns = 1 ∧ r.root = first.root ∧ r.nodes = first.nodes :=
      _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checks).2 (id,r) (by simpa [h] using member))
    refine ⟨same.1,?_⟩
    unfold LookupEmbedded.checkTable at *
    rw [same.1,same.2.1,same.2.2]
    simpa only [columns] using base

theorem admitted_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (catalogs : ValidationEventAuditIO.catalogs statics admission = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ admission)
    (valid : LookupEmbedded.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (selected : E values (r.outputs.getD 0 []) = 1) :
    ∃ opcode : Nat, opcode < 65536 ∧ E values r.input = (opcode : F) ∧ OpcodeCatalog.admitted opcode = true := by
  obtain ⟨columns,table⟩ := admission_table statics admission catalogs id r member
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp valid).1).2
  have cert := RangeUse.checked_certificate matrix r.range r.input 16 rangeCheck values one satisfied
  obtain ⟨opcode,bound,image,_⟩ := TokenInteger.certificate_nat values one r.input (RangeUse.bits r.range) 16 cert
  have output := LookupEmbedded.checked_values matrix r valid 16 ValidationEventAuditIO.allowed table opcode bound values one satisfied image
  have head := congrArg (fun xs : List F => xs.getD 0 0) output
  have empty : E values ([] : Linear) = 0 := by simp [E,FullMatrix.evalLinear,interpretLinear,R1CS.eval]
  have first : (r.outputs.map (E values)).getD 0 0 = E values (r.outputs.getD 0 []) := by
    rw [← empty]
    exact TokenInteger.map_getD (E values) r.outputs [] 0
  rw [first,selected,columns] at head
  refine ⟨opcode,bound,image,?_⟩
  cases h : OpcodeCatalog.admitted opcode with
  | true => rfl
  | false =>
    have bad : (1 : F) = 0 := by simpa [ValidationEventAuditIO.allowed,h,Ring.intCast_zero] using head
    exact False.elim (Field.zero_ne_one bad.symm)

theorem static_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (catalogs : ValidationEventAuditIO.catalogs statics admission = true)
    (policyId staticId : Nat) (policy : LookupEmbedded.Record) (rule : StaticLookupEmbedded.Record)
    (policyMember : (policyId,policy) ∈ admission) (staticMember : (staticId,rule) ∈ statics)
    (policyValid : LookupEmbedded.check matrix policy = true) (ruleValid : StaticLookupEmbedded.check matrix rule = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (sameOpcode : E values policy.input = E values (rule.inputs.getD 0 []))
    (selected : E values (policy.outputs.getD 0 []) = 1) :
    ∃ opcode index actual : Nat, opcode < 65536 ∧ index < 4 ∧ actual < 8 ∧
      E values (rule.inputs.getD 0 []) = (opcode : F) ∧ E values (rule.outputs.getD 6 []) = (index : F) ∧
      E values (rule.inputs.getD 2 []) = (actual : F) ∧ OpcodeCatalog.admitted opcode = true ∧
      (rule.outputs.take 6).map (E values) = (List.range 6).map (fun field => (StaticLookupEmbedded.expected opcode index actual field : F)) := by
  obtain ⟨admitted,admittedBound,admittedImage,allowed⟩ := admitted_value matrix statics admission catalogs policyId policy policyMember policyValid values one satisfied selected
  obtain ⟨opcode,index,actual,bound,ib,ab,oi,ii,ai,bits⟩ := StaticLookupSound.decoded_bits matrix rule ruleValid values one satisfied
  have equal : opcode = admitted := DeclarationLocations.natural_equal opcode admitted (by omega) (by omega)
    (oi.symm.trans (sameOpcode.symm.trans admittedImage))
  subst admitted
  exact ⟨opcode,index,actual,bound,ib,ab,oi,ii,ai,allowed,
    StaticLookupSound.output matrix rule ruleValid (static_table statics admission catalogs staticId rule staticMember) values one satisfied opcode index actual bound allowed ib ab bits⟩

theorem checked {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (source : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record)
    (accepted : ValidationEventCheck.check matrix statics admission source r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (∀ s ∈ r.stages, StageFacts matrix statics admission values s) ∧
    MemoryFacts values r.operand ∧ MemoryFacts values r.control ∧
    (∀ p ∈ statics, StaticLookupEmbedded.check matrix p.2 = true) ∧
    (∀ p ∈ admission, LookupEmbedded.check matrix p.2 = true) := by
  have checks := accepted
  simp only [ValidationEventCheck.check,Bool.and_eq_true_iff] at checks
  rcases checks with ⟨⟨⟨⟨⟨⟨⟨_,staticChecks⟩,admissionChecks⟩,stages⟩,operand⟩,control⟩,_⟩,_⟩
  refine ⟨?_,?_,?_,List.all_eq_true.mp staticChecks,List.all_eq_true.mp admissionChecks⟩
  · intro s member
    exact stage matrix statics admission s (List.all_eq_true.mp stages s member) values one satisfied
  · exact MemoryEmbedded.checked_memory matrix r.operand (Bool.and_eq_true_iff.mp operand).2 values one satisfied
  · exact MemoryEmbedded.checked_memory matrix r.control (Bool.and_eq_true_iff.mp control).2 values one satisfied

theorem admitted_rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (source : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record)
    (catalogs : ValidationEventAuditIO.catalogs statics admission = true)
    (accepted : ValidationEventCheck.check matrix statics admission source r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (bound : i < r.rows.length) :
    ∃ opcode : Nat, opcode < 65536 ∧ E values (f (rowAt r.rows i) 8) = (opcode : F) ∧
      OpcodeCatalog.admitted opcode = true := by
  have bindings := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  have binding := List.all_eq_true.mp bindings i (List.mem_range.mpr bound)
  unfold ValidationEventCheck.admissionBinding at binding
  cases found : ValidationEventCheck.admissionRecord admission r i with
  | none => simp [found] at binding
  | some pair =>
    rcases pair with ⟨id,rule⟩
    rw [found] at binding
    have member : (id,rule) ∈ admission := List.mem_of_find?_eq_some found
    have input := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp binding).1
    have span := MemoryEvidence.span_sound matrix rule.lastGate (rule.lastGate+1)
      [eqGate (rule.outputs.getD 0 []) o] (Bool.and_eq_true_iff.mp binding).2 values satisfied
    have selected : E values (rule.outputs.getD 0 []) = 1 := by
      have same := equality_sound values one (rule.outputs.getD 0 []) o (span _ (by simp))
      simpa [o,eval_constant values one,Ring.intCast_one] using same
    have valid := (checked matrix statics admission source r accepted values one satisfied).2.2.2.2 (id,rule) member
    obtain ⟨opcode,small,image,allowed⟩ := admitted_value matrix statics admission catalogs id rule member valid values one satisfied selected
    have same := SourceProgramSound.normalized_inputs values _ _ input
    simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at same
    exact ⟨opcode,small,same.trans image,allowed⟩

theorem static_rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (admission : LookupCatalog)
    (source : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record)
    (catalogs : ValidationEventAuditIO.catalogs statics admission = true)
    (accepted : ValidationEventCheck.check matrix statics admission source r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (bound : i < r.rows.length) :
    ∃ (id : Nat) (rule : StaticLookupEmbedded.Record) (opcode index actual : Nat),
      ValidationEventCheck.staticRecord statics r i = some (id,rule) ∧ (id,rule) ∈ statics ∧
      opcode < 65536 ∧ index < 4 ∧ actual < 8 ∧ OpcodeCatalog.admitted opcode = true ∧
      E values (f (rowAt r.rows i) 8) = (opcode : F) ∧
      E values (f (rowAt r.rows i) 4) = (actual : F) ∧ E values (rule.outputs.getD 6 []) = (index : F) ∧
      (rule.outputs.take 6).map (E values) = (List.range 6).map (fun field => (StaticLookupEmbedded.expected opcode index actual field : F)) := by
  have bindings := (Bool.and_eq_true_iff.mp accepted).2
  have binding := List.all_eq_true.mp bindings i (List.mem_range.mpr bound)
  unfold ValidationEventCheck.staticBinding at binding
  cases found : ValidationEventCheck.staticRecord statics r i with
  | none => simp [found] at binding
  | some pair =>
    rcases pair with ⟨id,rule⟩
    rw [found] at binding
    have member : (id,rule) ∈ statics := List.mem_of_find?_eq_some found
    have inputs := SourceProgramSound.normalized_inputs values _ _ (_root_.of_decide_eq_true binding)
    simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at inputs
    have valid := (checked matrix statics admission source r accepted values one satisfied).2.2.2.1 (id,rule) member
    obtain ⟨opcode,index,actual,small,ib,ab,oi,ii,ai,bits⟩ := StaticLookupSound.decoded_bits matrix rule valid values one satisfied
    obtain ⟨admitted,admittedBound,admittedImage,allowed⟩ := admitted_rows matrix statics admission source r catalogs accepted values one satisfied i bound
    have same : opcode = admitted := DeclarationLocations.natural_equal opcode admitted (by omega) (by omega)
      (oi.symm.trans (inputs.1.symm.trans admittedImage))
    subst admitted
    exact ⟨id,rule,opcode,index,actual,rfl,member,small,ib,ab,allowed,inputs.1.trans oi,inputs.2.trans ai,ii,
      StaticLookupSound.output matrix rule valid (static_table statics admission catalogs id rule member) values one satisfied opcode index actual small allowed ib ab bits⟩

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (admission : LookupCatalog) (source : InstructionStreamMatrix.Record) (r : ValidationEventMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (accepted : ValidationEventCheck.check matrix statics admission source r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      (∀ s ∈ r.stages, StageFacts matrix statics admission values s) ∧
      MemoryFacts values r.operand ∧ MemoryFacts values r.control := by
  have envelope := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sourceChecked).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelope).1).1
  obtain ⟨message,sourceBytes,d0,d1,unique,_⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values one satisfied
  obtain ⟨stages,operand,control,_,_⟩ := checked matrix statics admission source r accepted values one satisfied
  exact ⟨message,sourceBytes,d0,d1,unique,stages,operand,control⟩
#print axioms stage
#print axioms static_table
#print axioms admission_table
#print axioms admitted_value
#print axioms static_values
#print axioms checked
#print axioms admitted_rows
#print axioms static_rows
#print axioms source_bound
end ZkBuild.ValidationEventSound
