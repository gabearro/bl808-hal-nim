import SourceProgramSound
set_option autoImplicit false
namespace ZkBuild.SourceProgramSemantics
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Ensures {α : Type} (action : SourceProgram.Eval α) (post : α → Prop) : Prop :=
  ∀ before after result, action.run before = .ok (result,after) → post result

theorem pure_ok {α : Type} (a : α) (post : α → Prop) (h : post a) : Ensures (pure a) post := by
  intro before after result run
  have eq : (a,before) = (result,after) := Except.ok.inj run
  have same : a = result := congrArg Prod.fst eq
  exact same ▸ h

theorem bind_ok {α β : Type} (first : SourceProgram.Eval α) (rest : α → SourceProgram.Eval β)
    (p : α → Prop) (q : β → Prop) (h : Ensures first p)
    (next : ∀ a, p a → Ensures (rest a) q) : Ensures (first >>= rest) q := by
  intro before after result run
  change (first.run before >>= fun (a,middle) => (rest a).run middle) = .ok (result,after) at run
  cases step : first.run before with
  | error e => rw [step] at run; contradiction
  | ok pair =>
    rcases pair with ⟨a,middle⟩
    rw [step] at run
    change (rest a).run middle = .ok (result,after) at run
    exact next a (h before middle a step) middle after result run

theorem call_checked (matrix : Shape) (p : ModuleProgram.Program) (kind width : Nat) (inputs : List Linear)
    (before after : ModuleProgram.State) (outputs : List Linear)
    (run : (ModuleProgram.call matrix p kind inputs width).run before = .ok (outputs,after)) :
    ∃ operation ∈ p.operations,
      outputs = operation.call.outputs ∧ ModuleProgram.checkContract matrix ⟨kind,width,inputs,operation⟩ = true := by
  simp [ModuleProgram.call] at run
  split at run
  · contradiction
  · split at run
    · contradiction
    · rename_i available accepted
      have inside : p.operations.getD before.used default ∈ p.operations := by
        rw [← List.getElem_eq_getD default]
        exact List.getElem_mem (by omega)
      refine ⟨_,inside,?_,?_⟩
      · let finalState : ModuleProgram.State := {before with
          gate := (p.operations.getD before.used default).call.lastGate
          used := before.used+1
          contracts := before.contracts++[⟨kind,width,inputs,p.operations.getD before.used default⟩]}
        have pair : ((p.operations.getD before.used default).call.outputs,finalState) = (outputs,after) := Except.ok.inj run
        exact (congrArg Prod.fst pair).symm
      · have checked : ModuleProgram.checkContract matrix ⟨kind,width,inputs,p.operations.getD before.used default⟩ ≠ false := by
          simpa only [List.getD] using (not_or.mp accepted).2
        cases equal : ModuleProgram.checkContract matrix ⟨kind,width,inputs,p.operations.getD before.used default⟩ <;> simp_all

theorem primitive_run {α : Type} (action : ModuleProgram.Eval α)
    (before after : SourceProgram.State) (result : α)
    (run : (SourceProgram.primitive action).run before = .ok (result,after)) :
    (action.run before.base) = .ok (result,after.base) := by
  have reduced : (SourceProgram.primitive action).run before =
      (match action.run before.base with
       | .error e => Except.error e
       | .ok (output,state) => Except.ok (output,{before with base := state})) := by
    simp [SourceProgram.primitive,StateT.run,Bind.bind,Pure.pure,
      MonadState.get,getThe,set,MonadStateOf.get,MonadStateOf.set,StateT.bind,
      StateT.get,Except.bind,Except.pure,
      throw,throwThe,MonadExceptOf.throw]
    split <;> simp_all [StateT.bind,StateT.lift,StateT.set,StateT.pure,Bind.bind,Pure.pure,Except.bind,Except.pure]
  rw [reduced] at run
  cases h : action.run before.base with
  | error e => rw [h] at run; contradiction
  | ok pair =>
    rcases pair with ⟨output,state⟩
    rw [h] at run
    have same := Except.ok.inj run
    have a : output = result := congrArg Prod.fst same
    have b : state = after.base := congrArg (fun pair => pair.2.base) same
    simp [a,b]

def CallHolds {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (kind : Nat)
    (inputs outputs : List Linear) : Prop :=
  let out := E values (outputs.getD 0 [])
  match kind,inputs with
  | 0,[a,b] => E values a = E values b
  | 1,[a,b] => out = E values a * E values b
  | 2,[a] => out = E values a
  | 3,[] => out = 0 ∨ out = 1
  | 4,[a] => E values a = 0 ∨ E values a = 1
  | 6,[s,a,b] => out = E values b + E values s * (E values a-E values b)
  | 7,[a] => out = if E values a = 0 then 1 else 0
  | _,_ => False

theorem call_holds {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (p : ModuleProgram.Program) (kind : Nat) (inputs : List Linear)
    (before after : ModuleProgram.State) (outputs : List Linear)
    (run : (ModuleProgram.call matrix p kind inputs).run before = .ok (outputs,after))
    (small : kind ∈ [0,1,2,3,4,6,7])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    CallHolds values kind inputs outputs := by
  obtain ⟨op,member,output,checked⟩ := call_checked matrix p kind 0 inputs before after outputs run
  have inputSame := ModuleProgram.contract_inputs matrix ⟨kind,0,inputs,op⟩ checked values
  have parts : op.call.kind = kind ∧ op.source = none ∧ GadgetAudit.check matrix op.call op.source = true := by
    have ck := checked
    simp only [ModuleProgram.checkContract,Bool.and_eq_true_iff] at ck
    have different : kind ≠ 8 := by simp only [List.mem_cons,List.not_mem_nil,or_false] at small; omega
    simpa only [different,ite_false,decide_eq_true_eq,and_assoc,Option.isNone_iff_eq_none,Bool.and_eq_true_iff] using ck.2
  have inputShape : inputs.length = op.call.inputs.length := by
    simpa only [List.length_map] using congrArg List.length inputSame
  cases desc : GadgetAudit.describe op.call op.source with
  | none => simp [GadgetAudit.check,desc] at parts
  | some template =>
    have relation := GadgetAudit.checked_fragment_relation matrix op.call op.source template desc parts.2.2 values satisfied
    have holds : AllHold values template.gates := by
      simpa only [GadgetAudit.model,Satisfied,AllHold,Holds,List.toList_toArray] using relation.1
    have outImage : E values (op.call.outputs.getD 0 []) = E values (template.outputs.getD 0 []) := by
      have zero : E values ([] : Linear) = 0 := by simp [E,FullMatrix.evalLinear,interpretLinear,R1CS.eval]
      have h := congrArg (fun xs : List F => xs.getD 0 0) relation.2
      rw [← zero] at h
      simpa only [TokenInteger.map_getD] using h
    -- The template checker fixes argument/output arities and the gate model.
    simp only [GadgetAudit.describe,parts.1] at desc
    simp only [List.mem_cons,List.not_mem_nil,or_false] at small
    rcases small with rfl|rfl|rfl|rfl|rfl|rfl|rfl
    all_goals rcases args : op.call.inputs with _ | ⟨a,_ | ⟨b,_ | ⟨c,_ | ⟨d,rest⟩⟩⟩⟩
    all_goals simp [args] at desc
    all_goals subst template
    all_goals simp only [args,List.map_cons,List.map_nil] at inputSame
    all_goals dsimp only at outImage holds
    all_goals rw [output]
    all_goals rcases inputs with _ | ⟨x,_ | ⟨y,_ | ⟨z,_ | ⟨w,rest⟩⟩⟩⟩
    all_goals simp only [List.length_cons,List.length_nil,args] at inputShape
    all_goals try omega
    all_goals simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at inputSame
    all_goals simp only [CallHolds] at *
    all_goals simp only [AllHold,List.mem_singleton,forall_eq] at holds
    all_goals dsimp only [List.getD] at outImage
    all_goals try { have semantic := equality_sound values one _ _ holds; grind }
    all_goals try { have semantic := multiply_sound values _ _ _ holds; grind }
    all_goals try { have semantic := boolean_sound values one _ holds; grind }
    all_goals try { have semantic := select_sound values _ _ _ _ holds; grind }
    all_goals try { have semantic := zero_sound values one _ _ _ holds; grind }
    all_goals assumption

theorem call_sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (p : SourceProgram.Program) (kind : Nat) (inputs : List Linear)
    (small : kind ∈ [0,1,2,3,4,6,7])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    Ensures (SourceProgram.primitive (ModuleProgram.call matrix p.base kind inputs))
      (CallHolds values kind inputs) := by
  intro before after outputs run
  exact call_holds matrix p.base kind inputs before.base after.base outputs
    (primitive_run _ before after outputs run) small values one satisfied

theorem range_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (p : SourceProgram.Program) (a : Linear) (width : Nat)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    Ensures (SourceProgram.range matrix p a width) (fun bits =>
      RangeReuse.Certificate width (E values a) (bits.map (E values))) := by
  intro before after outputs run
  have step := primitive_run _ before after outputs run
  obtain ⟨op,member,output,checked⟩ := call_checked matrix p.base 8 width [a] before.base after.base outputs step
  have certificate := ModuleProgram.range_certificate matrix ⟨8,width,[a],op⟩ rfl checked values one satisfied
  simpa only [List.getD_cons_zero,output] using certificate

theorem raw_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (g : Gate) (values : Nat → F) (satisfied : Satisfied matrix values) :
    Ensures (SourceProgram.raw matrix g) (fun _ => Holds values g) := by
  intro before after result run
  have step := primitive_run _ before after result run
  simp [ModuleProgram.raw] at step
  split at step
  · contradiction
  · rename_i checked
    have yes : MemoryEvidence.checkSpan matrix before.base.gate (before.base.gate+1) [g] = true := by
      cases h : MemoryEvidence.checkSpan matrix before.base.gate (before.base.gate+1) [g] <;> simp_all
    exact MemoryEvidence.span_sound matrix _ _ [g] yes values satisfied g (by simp)

#print axioms pure_ok
#print axioms bind_ok
#print axioms call_checked
#print axioms primitive_run
#print axioms call_holds
#print axioms call_sound
#print axioms range_sound
#print axioms raw_sound
end ZkBuild.SourceProgramSemantics
