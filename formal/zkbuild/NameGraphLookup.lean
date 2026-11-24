import NameGraphRules
set_option autoImplicit false
set_option maxRecDepth 4096
namespace ZkBuild.NameGraphLookup
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameGraphMatrix NameGraphRules
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem shared_table (a b : LookupEmbedded.Record) (same : sameTable a b)
    (checked : LookupEmbedded.checkTable b 14 Utf8Suffix.expected = true) :
    LookupEmbedded.checkTable a 14 Utf8Suffix.expected = true := by
  simpa only [LookupEmbedded.checkTable,same.1,same.2.1,same.2.2] using checked

theorem table_member (nodes : List Node) (checked : checkTables nodes = true)
    (r : Node) (member : r ∈ nodes) : LookupEmbedded.checkTable r.lookup 14 Utf8Suffix.expected = true := by
  cases nodes with
  | nil => simp at member
  | cons first rest =>
    have parts : LookupEmbedded.checkTable first.lookup 14 Utf8Suffix.expected = true ∧
        rest.all (fun r => decide (sameTable r.lookup first.lookup)) = true := by
      simpa only [checkTables,Bool.and_eq_true_iff] using checked
    rcases List.mem_cons.mp member with same | later
    · subst r; exact parts.1
    · exact shared_table r.lookup first.lookup (_root_.of_decide_eq_true (List.all_eq_true.mp parts.2 r later)) parts.1

theorem code_parts (a b : Nat) :
    let code := byteOf a+stateOf b*256+highOf b*1024
    code < 16384 ∧ code%256 = byteOf a ∧ code/256%4 = stateOf b ∧ code/1024%16 = highOf b := by
  have ab : byteOf a < 256 := Nat.mod_lt _ (by decide)
  have sb : stateOf b < 4 := Nat.mod_lt _ (by decide)
  have hb : highOf b < 16 := Nat.mod_lt _ (by decide)
  dsimp
  omega

theorem output_bound (b t h s : Nat) (checked : Utf8Suffix.suffix b t h = some s) : s < 4 := by
  have cases := Utf8Suffix.suffix_cases b t h s checked
  rcases cases with first | second | third | fourth | fifth <;> omega

theorem transition {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true)
    (tableCheck : LookupEmbedded.checkTable r.lookup 14 Utf8Suffix.expected = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (enabled : E values r.entry.active = 1) (current following : Nat)
    (byteImage : E values (field r 0) = (byteOf current : F))
    (stateImage : E values (field r 2) = (stateOf current : F))
    (nextStateImage : E values (field r 4) = (stateOf following : F))
    (nextHighImage : E values (field r 5) = (highOf following : F)) :
    Utf8Suffix.suffix (byteOf current) (stateOf following) (highOf following) = some (stateOf current) := by
  have sh := shape matrix r i checked
  have all := holds matrix r i checked values satisfied
  have checks := checked
  simp only [checkNode,Bool.and_eq_true_iff] at checks
  have lookupCheck : LookupEmbedded.check matrix r.lookup = true := by grind only
  let code := byteOf current+stateOf following*256+highOf following*1024
  have parts := code_parts current following
  change code < 16384 ∧ code%256 = byteOf current ∧ code/256%4 = stateOf following ∧ code/1024%16 = highOf following at parts
  have add (a b : Linear) : E values (a++b) = E values a+E values b := eval_append values a b
  have scale256 (a : Linear) : E values (scale a 256) = ((256 : Int) : F)*E values a := by
    exact eval_scale values a 256
  have scale1024 (a : Linear) : E values (scale a 1024) = ((1024 : Int) : F)*E values a := by
    exact eval_scale values a 1024
  have inputImage : E values r.lookup.input = (code : F) := by
    rw [sh.2.2.2.2.1,add,add,scale256,scale1024,byteImage,nextStateImage,nextHighImage]
    have a : ((256 : Int) : F) = ((256 : Nat) : F) := Ring.intCast_natCast _
    have b : ((1024 : Int) : F) = ((1024 : Nat) : F) := Ring.intCast_natCast _
    rw [a,b]
    simp only [code,Semiring.natCast_add,Semiring.natCast_mul]
    grind
  have outputs := LookupEmbedded.checked_values matrix r.lookup lookupCheck 14 Utf8Suffix.expected tableCheck code parts.1 values oneValue satisfied inputImage
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have mapped (k : Nat) : (r.lookup.outputs.map (E values)).getD k 0 = E values (get r.lookup.outputs k) := by
    have mapping := TokenInteger.map_getD (E values) r.lookup.outputs z k
    simpa only [zero,DeclarationMatrix.get] using mapping
  have out0 := congrArg (fun xs : List F => xs.getD 0 0) outputs
  have out1 := congrArg (fun xs : List F => xs.getD 1 0) outputs
  rw [mapped] at out0 out1
  have cols : r.lookup.columns = 2 := sh.2.2.1
  simp only [cols,List.range_succ,List.range_zero,List.map_append,List.map_cons,List.map_nil,List.nil_append,
    List.getD_cons_zero,List.getD_cons_succ] at out0 out1
  have ending := part values r i all 5 (by decide)
  have validGate := ending (gate r.entry.active (sub (get r.lookup.outputs 0) o)) (by simp [nodeParts])
  have stateGate := ending (gate r.entry.active (sub (field r 2) (get r.lookup.outputs 1))) (by simp [nodeParts])
  change E values r.entry.active*E values (sub (get r.lookup.outputs 0) o) = E values z at validGate
  change E values r.entry.active*E values (sub (field r 2) (get r.lookup.outputs 1)) = E values z at stateGate
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [enabled,eval_sub,one,zero,out0] at validGate
  rw [enabled,eval_sub,stateImage,zero,out1] at stateGate
  cases step : Utf8Suffix.suffix (byteOf current) (stateOf following) (highOf following) with
  | none =>
    have no : Utf8Suffix.expected code 0 = 0 := by simp [Utf8Suffix.expected,parts.1,parts.2.1,parts.2.2.1,parts.2.2.2,step]
    rw [no] at validGate
    have bad : (0 : F) = 1 := by simp only [Ring.intCast_zero] at validGate; grind
    exact False.elim (Field.zero_ne_one bad)
  | some state =>
    have out : Utf8Suffix.expected code 1 = Int.ofNat state := by simp [Utf8Suffix.expected,parts.1,parts.2.1,parts.2.2.1,parts.2.2.2,step]
    rw [out] at stateGate
    have si : ((Int.ofNat state : Int) : F) = (state : F) := Ring.intCast_natCast _
    rw [si] at stateGate
    have sb := output_bound _ _ _ state step
    have cb : stateOf current < 4 := Nat.mod_lt _ (by decide)
    have same : stateOf current = state := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (by grind)
    simpa only [same] using step

#print axioms transition
end ZkBuild.NameGraphLookup
