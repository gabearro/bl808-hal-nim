import InstructionCounts
import StaticEvents
import StaticLookupSound
set_option autoImplicit false
namespace ZkBuild.InstructionStaticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure RuleImage {F : Type} [Field F] (values : Nat → F) (r : InstructionRowCheck.Record)
    (rule : StaticTyping.Rule) (index : Fin 4) (actual : Fin 8) : Prop where
  present : E values (f r.rule.outputs 0) = 1
  arity : E values (f r.rule.outputs 1) = (rule.inputs.length : F)
  outputCount : E values (f r.rule.outputs 2) = (StaticEvents.outputCount rule : F)
  outputType : E values (f r.rule.outputs 3) = (rule.output.getD 0 : F)
  clearCount : E values (f r.rule.outputs 4) = OperandEvents.flag rule.clears
  allowed : E values (f r.rule.outputs 5) = OperandEvents.flag (StaticTyping.popAllowed rule index.val actual.val)
  position : E values (f r.rule.outputs 6) = (index.val : F)

theorem gates {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : InstructionRowSound.Tags values r kind)
    (rule : StaticTyping.Rule) (index : Fin 4) (actual : Fin 8) (ri : RuleImage values r rule index actual)
    (actualImage : E values (f r.row 4) = (actual.val : F)) (counts : InstructionCounts.Counts)
    (pops : E values (f r.after 5) = (counts.pops : F))
    (pushes : E values (f r.after 6) = (counts.pushes : F))
    (clears : E values (f r.after 7) = (counts.clears : F)) :
    StaticEvents.Gates (F := F) rule kind actual index counts.pops counts.pushes counts.clears := by
  have fs := InstructionRowSound.facts matrix r checked values one satisfied
  have all : AllHold values (InstructionRowCheck.staticGates r) := by
    intro g member
    exact fs.2.1 g (List.mem_append_left _ member)
  have rawEq (a b : Linear) : Holds values (gate a b) ↔ E values a * E values b = 0 := by
    change E values a * E values b = E values z ↔ _
    rw [show z = constant 0 from rfl,eval_constant values one,Ring.intCast_zero]
  have mulEq (a b c : Linear) : Holds values (mulGate a b c) ↔ E values c = E values a * E values b := by
    exact eq_comm
  simp only [AllHold,InstructionRowCheck.staticGates,List.mem_cons,List.not_mem_nil,or_false,forall_eq_or_imp,forall_eq,rawEq,mulEq] at all
  rcases all with ⟨pop,push,h0,h1,h2,h3,h4,h5,h6,h7,clear,h8,h9,finish,h10,h11,h12⟩
  obtain ⟨_,_,t2,t3,t4,t5,t6,t7,_,_,_⟩ := InstructionRowSound.selectors values r kind tags
  simp only [eval_sub,eval_append,o,eval_constant values one,Ring.intCast_one,
    ri.present,ri.arity,ri.outputCount,ri.outputType,ri.clearCount,ri.allowed,ri.position,
    actualImage,pops,pushes,clears,t2,t3,t4,t5,t6,t7,Semiring.one_mul] at pop push clear finish h0 h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 h11 h12
  rw [pop] at h0 h1 h2
  rw [push] at h3 h4 h5 h6
  rw [clear] at h8 h9
  rw [finish] at h10 h11 h12
  exact ⟨h0,h1,h2,h3,h4,h5,h6,by simpa only [Semiring.one_mul] using h7,h8,h9,h10,h11,h12⟩

theorem lookup {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (ruleChecked : StaticLookupEmbedded.check matrix r.rule = true) (table : StaticLookupEmbedded.checkTable r.rule = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (opcode : Nat) (ob : opcode < 65536) (admitted : OpcodeCatalog.admitted opcode = true)
    (opImage : E values (f r.row 8) = (opcode : F))
    (rule : StaticTyping.Rule) (signature : StaticTyping.signature opcode = some rule) :
    ∃ (index : Fin 4) (actual : Fin 8), RuleImage values r rule index actual ∧ E values (f r.row 4) = (actual.val : F) := by
  have fs := InstructionRowSound.facts matrix r checked values one satisfied
  obtain ⟨op,idx,ty,opBound,indexBound,typeBound,oi,ii,ti,bits⟩ := StaticLookupSound.decoded_bits matrix r.rule ruleChecked values one satisfied
  have input0 := fs.2.2.2.2 0
  have same : op = opcode := OperandEvents.natural_eq _ _
    (by unfold OperandEvents.bound; omega) (by unfold OperandEvents.bound; omega) (oi.symm.trans (input0.symm.trans opImage))
  subst op
  have output := StaticLookupSound.output matrix r.rule ruleChecked table values one satisfied opcode idx ty ob admitted indexBound typeBound bits
  have outputLength : r.rule.outputs.length = 7 := by
    have shape := checked
    simp only [InstructionRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at shape
    exact shape.2.2.2.2.1
  have outputAt (i : Nat) (ib : i < 7) : E values (f r.rule.outputs i) = E values (r.rule.outputs.getD i []) := by
    change E values (r.rule.outputs.getD i z) = _
    rw [← List.getElem_eq_getD (h := by omega) z,← List.getElem_eq_getD (h := by omega) ([] : Linear)]
  have fieldAt (i : Nat) (ib : i < 6) : E values (f r.rule.outputs i) = (StaticLookupEmbedded.expected opcode idx ty i : F) := by
    have h := congrArg (fun xs : List F => xs.getD i 0) output
    have zero : E values ([] : Linear) = 0 := rfl
    rw [← zero,TokenInteger.map_getD] at h
    rw [outputAt i (by omega)]
    simpa only [List.getD,List.getElem?_take,ib,ite_true,List.getElem?_map,List.getElem?_range,Option.map_some,Option.getD_some] using h

  have field0 := fieldAt 0 (by decide)
  have field1 := fieldAt 1 (by decide)
  have field2 := fieldAt 2 (by decide)
  have field3 := fieldAt 3 (by decide)
  have field4 := fieldAt 4 (by decide)
  have field5 := fieldAt 5 (by decide)
  refine ⟨⟨idx,indexBound⟩,⟨ty,typeBound⟩,?_,(fs.2.2.2.2 2).trans ti⟩
  constructor
  · simp only [StaticLookupEmbedded.expected,signature] at field0
    change E values (f r.rule.outputs 0) = ((1 : Int) : F) at field0
    simpa only [Ring.intCast_one] using field0
  · simpa [StaticLookupEmbedded.expected,signature,Ring.intCast_natCast] using field1
  · simpa [StaticLookupEmbedded.expected,signature,Ring.intCast_natCast,StaticEvents.outputCount] using field2
  · simpa [StaticLookupEmbedded.expected,signature,Ring.intCast_natCast] using field3
  · simpa [StaticLookupEmbedded.expected,signature,Ring.intCast_natCast,ControlEvents.flag_nat] using field4
  · simpa [StaticLookupEmbedded.expected,signature,Ring.intCast_natCast,ControlEvents.flag_nat] using field5
  · exact (outputAt 6 (by decide)).trans ii

#print axioms gates
#print axioms lookup
end ZkBuild.InstructionStaticSound
