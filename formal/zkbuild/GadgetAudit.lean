import GadgetShape
import Init.Data.List.Sublist

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

structure Record where
  kind : Nat
  width : Nat
  firstWire : Nat
  lastWire : Nat
  firstGate : Nat
  lastGate : Nat
  reference : Nat
  inputs : List Linear
  outputs : List Linear
  deriving Inhabited

structure Template where
  gates : List Gate
  outputs : List Linear
  allocated : Nat

-- A constant expression may have multiple wire-zero terms. Canonicalize their
-- sum in the scalar field before deciding whether folding is permitted.
def constantValue (value : Linear) : Option Nat :=
  if value.all (fun t => t.1 == 0) then
    some ((value.map Prod.snd).sum % Int.ofNat scalarModulus).toNat
  else none

def describe (r : Record) (source : Option Record) : Option Template := do
  let out := wire r.firstWire
  match r.kind,r.inputs with
  | 0,[a,b] => return ⟨[eqGate a b],[],0⟩
  | 1,[a,b] => return ⟨[mulGate a b out],[out],1⟩
  | 2,[a] => return ⟨[eqGate out a],[out],1⟩
  | 3,[] => return ⟨[boolGate out],[out],1⟩
  | 4,[a] => return ⟨[boolGate a],[],0⟩
  | 5,[s,yes,no] => return ⟨[mulGate s (sub yes no) out],[no++out,out],1⟩
  | 6,[s,yes,no] => return ⟨[selectGate s yes no out],[out],1⟩
  | 7,[a] =>
    let reciprocal := wire (r.firstWire+1)
    return ⟨zeroGates a out reciprocal,[out,reciprocal],2⟩
  | 8,[a] => return ⟨rangeGates a r.firstWire r.width,rangeBits r.firstWire r.width,r.width⟩
  | 9,[_] =>
    let previous ← source
    if previous.kind != 8 || r.width != previous.width || r.inputs != previous.inputs || r.reference == 0 then none
    else return ⟨[],previous.outputs,0⟩
  | 10,[a] =>
    let value ← constantValue a
    return ⟨literalGates value r.width,literalOutputs (literalBits value r.width),0⟩
  | _,_ => none

def fragment (matrix : Shape) (r : Record) : Artifact :=
  ⟨{ wires := r.lastWire, gates := matrix.gates.extract r.firstGate r.lastGate },r.outputs⟩

def model (r : Record) (t : Template) : Artifact :=
  ⟨{ wires := r.lastWire, gates := t.gates.toArray },t.outputs⟩

def validBounds (matrix : Shape) (r : Record) : Bool :=
  decide (0 < r.firstWire ∧ r.firstWire ≤ r.lastWire ∧ r.lastWire ≤ matrix.wires ∧
    r.firstGate ≤ r.lastGate ∧ r.lastGate ≤ matrix.gates.size ∧ r.width ≤ 248) &&
  r.inputs.all (fun l => l.all (fun t => decide (t.1 < r.firstWire))) &&
  r.outputs.all (fun l => l.all (fun t => decide (t.1 < r.lastWire))) &&
  (r.kind == 9 || r.reference == 0) && (r.kind ≥ 8 || r.width == 0)

def check (matrix : Shape) (r : Record) (source : Option Record) : Bool :=
  validBounds matrix r && match describe r source with
    | none => false
    | some t => r.lastWire == r.firstWire+t.allocated && conforms (fragment matrix r) (model r t)

theorem extracted_gate_member (matrix : Shape) (r : Record) (gate : Gate)
    (inside : gate ∈ (fragment matrix r).shape.gates.toList) : gate ∈ matrix.gates.toList := by
  simp only [fragment,Array.toList_extract,List.extract_eq_take_drop] at inside
  exact List.mem_of_mem_drop (List.mem_of_mem_take inside)

theorem fragment_satisfied {F : Type} [CommRing F] (matrix : Shape) (r : Record)
    (values : Nat → F) (satisfied : Satisfied matrix values) : Satisfied (fragment matrix r).shape values := by
  intro gate inside
  exact satisfied gate (extracted_gate_member matrix r gate inside)

theorem checked_conformance (matrix : Shape) (r : Record) (source : Option Record) (t : Template)
    (description : describe r source = some t) (accepted : check matrix r source = true) :
    conforms (fragment matrix r) (model r t) = true := by
  have parts : validBounds matrix r = true ∧ r.lastWire = r.firstWire+t.allocated ∧
      conforms (fragment matrix r) (model r t) = true := by
    simpa [check,description,Bool.and_eq_true_iff,and_assoc] using accepted
  exact parts.2.2

theorem checked_fragment_relation {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (source : Option Record) (t : Template)
    (description : describe r source = some t) (accepted : check matrix r source = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    Satisfied (model r t).shape values ∧ r.outputs.map (E values) = t.outputs.map (E values) := by
  have same := conformance_relation (fragment matrix r) (model r t)
    (checked_conformance matrix r source t description accepted) values
  exact ⟨same.1.mp (fragment_satisfied matrix r values satisfied),same.2⟩

theorem checked_unsigned {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (value : Linear) (kind : r.kind = 8) (input : r.inputs = [value])
    (accepted : check matrix r none = true) (values : Nat → F) (one : values 0 = 1)
    (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  let t : Template := ⟨rangeGates value r.firstWire r.width,rangeBits r.firstWire r.width,r.width⟩
  have description : describe r none = some t := by simp [describe,kind,input,t]
  have relation := checked_fragment_relation matrix r none t description accepted values satisfied
  rw [relation.2]
  have holds : AllHold values (rangeGates value r.firstWire r.width) := by
    simpa [model,t,Satisfied,AllHold,Holds] using relation.1
  exact range_certificate values one value r.firstWire r.width holds

theorem checked_reused_unsigned {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r previous : Record) (value : Linear)
    (kind : r.kind = 9) (input : r.inputs = [value])
    (source : previous.kind = 8 ∧ r.width = previous.width ∧ r.inputs = previous.inputs ∧ r.reference ≠ 0)
    (accepted : check matrix r (some previous) = true) (values : Nat → F)
    (satisfied : Satisfied matrix values)
    (prior : RangeReuse.Certificate previous.width (E values value) (previous.outputs.map (E values))) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  let t : Template := ⟨[],previous.outputs,0⟩
  have previousInput : previous.inputs = [value] := source.2.2.1.symm.trans input
  have description : describe r (some previous) = some t := by
    simp [describe,kind,input,source.1,source.2.1,previousInput,source.2.2.2,t]
  have relation := checked_fragment_relation matrix r (some previous) t description accepted values satisfied
  simpa [t,relation.2,source.2.1] using prior

#print axioms extracted_gate_member
#print axioms checked_fragment_relation
#print axioms checked_unsigned
#print axioms checked_reused_unsigned

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

def sourceAt (records : Array Record) (r : Record) : Option Record :=
  if r.reference = 0 then none else records[r.reference-1]?

def checkAt (matrix : Shape) (records : Array Record) (index : Nat) : Bool :=
  match records[index]? with
  | none => false
  | some r =>
    decide (r.reference ≤ index) &&
    (if index = 0 then true else match records[index-1]? with
      | none => false
      | some previous => decide (previous.lastGate ≤ r.firstGate ∧ previous.lastWire ≤ r.firstWire)) &&
    check matrix r (sourceAt records r)

def checkAll (matrix : Shape) (records : Array Record) : Bool :=
  (List.range records.size).all (checkAt matrix records)

theorem all_checked_local (matrix : Shape) (records : Array Record)
    (accepted : checkAll matrix records = true) (index : Nat) (r : Record)
    (found : records[index]? = some r) : check matrix r (sourceAt records r) = true := by
  have inside : index < records.size := (Array.getElem?_eq_some_iff.mp found).1
  have atIndex := List.all_eq_true.mp accepted index (List.mem_range.mpr inside)
  simp only [checkAt,found,Bool.and_eq_true_iff,and_assoc] at atIndex
  exact atIndex.2.2

theorem all_checked_unsigned {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 8) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  let source := sourceAt records r
  let t : Template := ⟨rangeGates value r.firstWire r.width,rangeBits r.firstWire r.width,r.width⟩
  have description : describe r source = some t := by simp [describe,kind,input,t]
  have relation := checked_fragment_relation matrix r source t description
    (all_checked_local matrix records accepted index r found) values satisfied
  rw [relation.2]
  have holds : AllHold values (rangeGates value r.firstWire r.width) := by
    simpa [model,t,Satisfied,AllHold,Holds] using relation.1
  exact range_certificate values one value r.firstWire r.width holds

#print axioms all_checked_local
#print axioms all_checked_unsigned

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem reused_source (matrix : Shape) (r : Record) (source : Option Record)
    (value : Linear) (kind : r.kind = 9) (input : r.inputs = [value])
    (accepted : check matrix r source = true) :
    ∃ previous, source = some previous ∧ previous.kind = 8 ∧ r.width = previous.width ∧
      r.inputs = previous.inputs ∧ r.reference ≠ 0 := by
  cases source with
  | none => simp [check,describe,kind,input] at accepted
  | some previous =>
    have pk : previous.kind = 8 := by
      by_cases h : previous.kind = 8
      · exact h
      · simp [check,describe,kind,input,h] at accepted
    have width : r.width = previous.width := by
      by_cases h : r.width = previous.width
      · exact h
      · simp [check,describe,kind,input,h] at accepted
    have inputs : r.inputs = previous.inputs := by
      by_cases h : r.inputs = previous.inputs
      · exact h
      · have bad : [value] ≠ previous.inputs := by simpa [input] using h
        simp [check,describe,kind,input,bad] at accepted
    have ref : r.reference ≠ 0 := by
      intro zero
      simp [check,describe,kind,input,zero] at accepted
    exact ⟨previous,rfl,pk,width,inputs,ref⟩

theorem all_checked_reused_unsigned {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 9) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  have localCheck := all_checked_local matrix records accepted index r found
  obtain ⟨previous,source,pk,width,inputs,nonzero⟩ := reused_source matrix r (sourceAt records r) value kind input localCheck
  have previousFound : records[r.reference-1]? = some previous := by
    simpa [sourceAt,nonzero] using source
  have previousInput : previous.inputs = [value] := inputs.symm.trans input
  have prior := all_checked_unsigned matrix records accepted (r.reference-1) previous value previousFound pk previousInput values one satisfied
  have acceptedPrevious : check matrix r (some previous) = true := by rwa [source] at localCheck
  exact checked_reused_unsigned matrix r previous value kind input ⟨pk,width,inputs,nonzero⟩
    acceptedPrevious values satisfied prior

#print axioms reused_source
#print axioms all_checked_reused_unsigned

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

private theorem constant_sum {F : Type} [CommRing F] (values : Nat → F) (one : values 0 = 1)
    (a : Linear) (only : ∀ t ∈ a, t.1 = 0) : E values a = ((a.map Prod.snd).sum : F) := by
  induction a with
  | nil => simp [E,evalLinear,interpretLinear,R1CS.eval,Ring.intCast_zero]
  | cons term rest ih =>
    obtain ⟨w,c⟩ := term
    have head : w = 0 := only (w,c) (by simp)
    have tail : ∀ t ∈ rest, t.1 = 0 := by intro t ht; exact only t (by simp [ht])
    have previous := ih tail
    simp only [E,evalLinear,interpretLinear,List.map_cons,List.sum_cons,R1CS.eval] at *
    rw [head,one,Semiring.mul_one,previous,Ring.intCast_add]

theorem constant_value_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (values : Nat → F) (one : values 0 = 1) (a : Linear) (n : Nat)
    (decoded : constantValue a = some n) : E values a = (n : F) := by
  unfold constantValue at decoded
  split at decoded
  · rename_i only
    have zeroWires : ∀ t ∈ a, t.1 = 0 := by simpa using List.all_eq_true.mp only
    have same := Option.some.inj decoded
    rw [constant_sum values one a zeroWires]
    rw [← same]
    let sum := (a.map Prod.snd).sum
    have nonnegative : 0 ≤ sum % Int.ofNat scalarModulus := Int.emod_nonneg _ (by decide)
    have lifted : (((sum % Int.ofNat scalarModulus).toNat : Nat) : Int) = sum % Int.ofNat scalarModulus :=
      Int.toNat_of_nonneg nonnegative
    rw [← Ring.intCast_natCast,lifted]
    exact (IsCharP.intCast_emod (α := F) scalarModulus sum).symm
  · contradiction

theorem all_checked_explained {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (found : records[index]? = some r)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    ∃ t, describe r (sourceAt records r) = some t ∧ AllHold values t.gates ∧
      r.outputs.map (E values) = t.outputs.map (E values) := by
  have checked := all_checked_local matrix records accepted index r found
  cases description : describe r (sourceAt records r) with
  | none => simp [check,description] at checked
  | some t =>
    have relation := checked_fragment_relation matrix r (sourceAt records r) t description checked values satisfied
    exact ⟨t,rfl,by simpa [model,Satisfied,AllHold,Holds] using relation.1,relation.2⟩

theorem all_checked_literal {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 10) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  have checked := all_checked_local matrix records accepted index r found
  cases cv : constantValue value with
  | none => simp [check,describe,kind,input,cv] at checked
  | some n =>
    let t : Template := ⟨literalGates n r.width,literalOutputs (literalBits n r.width),0⟩
    have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,cv,t]
    have relation := checked_fragment_relation matrix r (sourceAt records r) t description checked values satisfied
    rw [relation.2,constant_value_sound values one value n cv]
    have holds : AllHold values (literalGates n r.width) := by simpa [model,t,Satisfied,AllHold,Holds] using relation.1
    exact literal_matrix_sound values one n r.width holds

#print axioms constant_value_sound
#print axioms all_checked_explained
#print axioms all_checked_literal

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem all_checked_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 8 ∨ r.kind = 9 ∨ r.kind = 10) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    RangeReuse.Certificate r.width (E values value) (r.outputs.map (E values)) := by
  rcases kind with fresh | reused | literal
  · exact all_checked_unsigned matrix records accepted index r value found fresh input values one satisfied
  · exact all_checked_reused_unsigned matrix records accepted index r value found reused input values one satisfied
  · exact all_checked_literal matrix records accepted index r value found literal input values one satisfied

theorem all_checked_zero {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 7) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ reciprocal : F, r.outputs.map (E values) = [if E values value = 0 then 1 else 0,reciprocal] := by
  let out := wire r.firstWire
  let reciprocal := wire (r.firstWire+1)
  let t : Template := ⟨zeroGates value out reciprocal,[out,reciprocal],2⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t,out,reciprocal]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  have holds : AllHold values (zeroGates value out reciprocal) := by simpa [model,t,Satisfied,AllHold,Holds] using relation.1
  have zero := zero_sound values one value out reciprocal holds
  refine ⟨E values reciprocal,?_⟩
  simpa [t,zero] using relation.2

#print axioms all_checked_range
#print axioms all_checked_zero

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem all_checked_equality {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (a b : Linear) (found : records[index]? = some r)
    (kind : r.kind = 0) (input : r.inputs = [a,b])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values a = E values b := by
  let t : Template := ⟨[eqGate a b],[],0⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  exact equality_sound values one a b (relation.1 _ (by simp [model,t]))

theorem all_checked_multiply {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (a b : Linear) (found : records[index]? = some r)
    (kind : r.kind = 1) (input : r.inputs = [a,b])
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    r.outputs.map (E values) = [E values a * E values b] := by
  let out := wire r.firstWire
  let t : Template := ⟨[mulGate a b out],[out],1⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t,out]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  have product := multiply_sound values a b out (relation.1 _ (by simp [model,t]))
  simpa [t,product] using relation.2

theorem all_checked_materialize {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (a : Linear) (found : records[index]? = some r)
    (kind : r.kind = 2) (input : r.inputs = [a])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    r.outputs.map (E values) = [E values a] := by
  let out := wire r.firstWire
  let t : Template := ⟨[eqGate out a],[out],1⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t,out]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  have equal := equality_sound values one out a (relation.1 _ (by simp [model,t]))
  simpa [t,equal] using relation.2

theorem all_checked_bit {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (found : records[index]? = some r)
    (kind : r.kind = 3) (input : r.inputs = [])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ bit : F, r.outputs.map (E values) = [bit] ∧ (bit = 0 ∨ bit = 1) := by
  let out := wire r.firstWire
  let t : Template := ⟨[boolGate out],[out],1⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t,out]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  exact ⟨E values out,by simpa [t] using relation.2,
    boolean_sound values one out (relation.1 _ (by simp [model,t]))⟩

theorem all_checked_boolean {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (a : Linear) (found : records[index]? = some r)
    (kind : r.kind = 4) (input : r.inputs = [a])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values a = 0 ∨ E values a = 1 := by
  let t : Template := ⟨[boolGate a],[],0⟩
  have description : describe r (sourceAt records r) = some t := by simp [describe,kind,input,t]
  have relation := checked_fragment_relation matrix r (sourceAt records r) t description
    (all_checked_local matrix records accepted index r found) values satisfied
  exact boolean_sound values one a (relation.1 _ (by simp [model,t]))

theorem all_checked_select {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (s yes no : Linear) (found : records[index]? = some r)
    (kind : r.kind = 5 ∨ r.kind = 6) (input : r.inputs = [s,yes,no])
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    (r.outputs.map (E values)).head? = some (E values no + E values s * (E values yes - E values no)) := by
  let out := wire r.firstWire
  rcases kind with affine | fresh
  · let t : Template := ⟨[mulGate s (sub yes no) out],[no++out,out],1⟩
    have description : describe r (sourceAt records r) = some t := by simp [describe,affine,input,t,out]
    have relation := checked_fragment_relation matrix r (sourceAt records r) t description
      (all_checked_local matrix records accepted index r found) values satisfied
    have product := multiply_sound values s (sub yes no) out (relation.1 _ (by simp [model,t]))
    rw [relation.2]
    simp [t,E,FullMatrix.eval_append,product,eval_sub]
  · let t : Template := ⟨[selectGate s yes no out],[out],1⟩
    have description : describe r (sourceAt records r) = some t := by simp [describe,fresh,input,t,out]
    have relation := checked_fragment_relation matrix r (sourceAt records r) t description
      (all_checked_local matrix records accepted index r found) values satisfied
    have selected := select_sound values s yes no out (relation.1 _ (by simp [model,t]))
    rw [relation.2]
    simpa [t] using congrArg some selected

#print axioms all_checked_equality
#print axioms all_checked_multiply
#print axioms all_checked_materialize
#print axioms all_checked_bit
#print axioms all_checked_boolean
#print axioms all_checked_select

end ZkBuild.GadgetAudit

namespace ZkBuild.GadgetAudit

open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem all_checked_width (matrix : Shape) (records : Array Record)
    (accepted : checkAll matrix records = true) (index : Nat) (r : Record)
    (found : records[index]? = some r) : r.width ≤ 248 := by
  have localCheck := all_checked_local matrix records accepted index r found
  have bounds : validBounds matrix r = true := (Bool.and_eq_true_iff.mp localCheck).1
  simp only [validBounds,Bool.and_eq_true_iff,decide_eq_true_eq] at bounds
  omega

theorem all_checked_range_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 8 ∨ r.kind = 9 ∨ r.kind = 10) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ n : Nat, n < 2^r.width ∧ E values value = (n : F) ∧
      ∀ m : Nat, m < 2^r.width → E values value = (m : F) → m = n := by
  have cert := all_checked_range matrix records accepted index r value found kind input values one satisfied
  obtain ⟨n,bound,image⟩ := RangeReuse.certificate_sound r.width (E values value) _ cert
  have below := RangeConstraints.power_below_modulus r.width (all_checked_width matrix records accepted index r found)
  refine ⟨n,bound,image,?_⟩
  intro m small represented
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
    (Nat.lt_trans small below) (Nat.lt_trans bound below)).mp (represented.symm.trans image)

theorem all_checked_canonical_range {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (records : Array Record) (accepted : checkAll matrix records = true)
    (index : Nat) (r : Record) (value : Linear) (found : records[index]? = some r)
    (kind : r.kind = 8 ∨ r.kind = 9 ∨ r.kind = 10) (input : r.inputs = [value])
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (n : Nat) (canonical : n < scalarModulus) (image : E values value = (n : F)) :
    n < 2^r.width := by
  obtain ⟨m,bound,represented,_⟩ :=
    all_checked_range_unique matrix records accepted index r value found kind input values one satisfied
  have below := RangeConstraints.power_below_modulus r.width (all_checked_width matrix records accepted index r found)
  have same := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus canonical
    (Nat.lt_trans bound below)).mp (image.symm.trans represented)
  simpa [same] using bound

#print axioms all_checked_width
#print axioms all_checked_range_unique
#print axioms all_checked_canonical_range

end ZkBuild.GadgetAudit
