import CallMode
set_option autoImplicit false
namespace ZkBuild.CallRowEquations
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- Complete interpreted call-row equations, extracted from the checked matrix. -/
structure Meaning {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (r : CallRowCheck.Record) : Prop where
  begin : E values (f r.after 4) = E values (CallRowCheck.call r)*E values (f r.flags 1)
  indirectBegin : E values (f r.after 5) = E values (CallRowCheck.indexed r)*E values (f r.flags 1)
  functionAddress : E values (f r.after 8) = E values (f r.flags 0)*E values (scale (f r.row 1) 2)
  calleeAddress : E values (f r.after 9) = E values (f r.after 4)*E values (scale r.primary 2++(CallRowCheck.indexed r))
  returning : E values (f r.after 11) = E values (CallRowCheck.tail r)*E values (f r.flags 1)
  tableAddress : E values (f r.after 17) = E values (f r.after 5)*E values (scale r.secondary 2++o)
  pop : E values (f r.after 18) = E values (CallRowCheck.call r)*E values (f r.flags 3)
  indexPop : E values (f r.after 19) = E values (f r.after 18)*E values (f r.after 14)
  push : E values (f r.after 20) = E values (CallRowCheck.call r)*E values (f r.flags 2)
  clear : E values (f r.after 21) = E values (CallRowCheck.call r)*E values (f r.flags 6)
  argumentAddress : E values (f r.after 24) = E values (CallRowCheck.argument r)*E values (f r.after 12)
  resultAddress : E values (f r.after 25) = E values (f r.after 20)*E values (f r.after 13)
  finish : E values (f r.after 32) = E values (CallRowCheck.call r)*E values (f r.flags 7)
  ordinaryEnd : E values (f r.after 33) = E values ((f r.after 0)++(f r.after 1))*E values (f r.flags 7)
  root : E values (f r.after 10) = E values (f r.before 5)+E values (f r.flags 0)*(E values r.heads.high-E values (f r.before 5))
  params : E values (f r.after 12) = E values (f r.before 0)+E values ((f r.flags 0)++(f r.flags 1))*(E values r.heads.low-E values (f r.before 0))
  results : E values (f r.after 13) = E values (f r.before 1)+E values ((f r.flags 0)++(f r.flags 1))*(E values r.heads.high-E values (f r.before 1))
  pending : E values (f r.after 14) = E values (f r.before 2)+E values ((f r.flags 0)++(f r.flags 1))*(E values (CallRowCheck.indexed r)-E values (f r.before 2))
  pushed : E values (f r.after 15) = E values (f r.before 3)+E values ((f r.flags 0)++(f r.flags 1))*(E values z-E values (f r.before 3))
  cleared : E values (f r.after 16) = E values (f r.before 4)+E values ((f r.flags 0)++(f r.flags 1))*(E values z-E values (f r.before 4))
  nextParams : E values (f r.after 27) = E values (f r.after 12)+E values (CallRowCheck.argument r)*(E values r.payload.high-E values (f r.after 12))
  nextResults : E values (f r.after 28) = E values (f r.after 13)+E values (f r.after 20)*(E values r.payload.high-E values (f r.after 13))
  nextPushed : E values (f r.after 30) = E values (f r.after 15)+E values (f r.after 20)*(E values o-E values (f r.after 15))
  nextPending : E values (f r.after 29) = E values (sub (f r.after 14) (f r.after 19))
  nextCleared : E values (f r.after 31) = E values ((f r.after 16)++(f r.after 21))
  primaryInactive : E values (sub o (f r.flags 1))*E values r.primary = 0
  secondaryInactive : E values (sub o (f r.flags 1))*E values r.secondary = 0
  tailResult : E values (f r.after 11)*E values (sub r.heads.high (f r.after 10)) = 0
  tableType : E values (f r.after 5)*E values (sub r.tableQuery.value (n 5)) = 0
  indexType : E values (f r.after 19)*E values (sub (sub o (f r.after 22)) (f r.after 23)) = 0
  popOrder : E values (f r.after 18)*E values ((f r.after 15)++(f r.after 16)) = 0
  pushOrder : E values (f r.after 20)*E values ((CallRowCheck.tail r)++(f r.after 14)++(f r.after 16)) = 0
  pushEmpty : E values (f r.after 20)*E values (f r.after 12) = 0
  argumentType : E values (CallRowCheck.argument r)*E values (sub (sub o (f r.after 22)) (f r.after 26)) = 0
  resultType : E values (f r.after 20)*E values (sub (f r.row 4) r.payload.low) = 0
  noControl : E values (CallRowCheck.call r)*E values ((f r.flags 4)++(f r.flags 5)) = 0
  clearTail : E values (f r.after 21)*E values (sub o (CallRowCheck.tail r)) = 0
  clearEmpty : E values (f r.after 21)*E values ((f r.after 27)++(f r.after 29)++(f r.after 16)) = 0
  endParams : E values (f r.after 32)*E values (f r.after 27) = 0
  endPending : E values (f r.after 32)*E values (f r.after 29) = 0
  endCleared : E values (f r.after 32)*E values (sub (f r.after 31) (CallRowCheck.tail r)) = 0
  endResults : E values (f r.after 33)*E values (f r.after 28) = 0
  unknown : E values (f r.after 22) = if E values (sub (f r.row 4) (n 7)) = 0 then 1 else 0
  actualZero : E values (f r.after 23) = if E values (f r.row 4) = 0 then 1 else 0
  matched : E values (f r.after 26) = if E values (sub (f r.row 4) r.payload.low) = 0 then 1 else 0

theorem meaning {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : CallRowCheck.Record) (checked : CallRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Meaning values r := by
  have all := CallRowSound.facts matrix r checked values satisfied
  have raw (a b : Linear) (member : gate a b ∈ CallRowCheck.gates r) : E values a*E values b = 0 := by
    have h := all _ member
    change E values a*E values b = E values z at h
    simpa only [z,eval_constant values one,Ring.intCast_zero] using h
  constructor
  · exact (all (mulGate (CallRowCheck.call r) (f r.flags 1) (f r.after 4)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.indexed r) (f r.flags 1) (f r.after 5)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (f r.flags 0) (scale (f r.row 1) 2) (f r.after 8)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (f r.after 4) (scale r.primary 2++(CallRowCheck.indexed r)) (f r.after 9)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.tail r) (f r.flags 1) (f r.after 11)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (f r.after 5) (scale r.secondary 2++o) (f r.after 17)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.call r) (f r.flags 3) (f r.after 18)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (f r.after 18) (f r.after 14) (f r.after 19)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.call r) (f r.flags 2) (f r.after 20)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.call r) (f r.flags 6) (f r.after 21)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.argument r) (f r.after 12) (f r.after 24)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (f r.after 20) (f r.after 13) (f r.after 25)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate (CallRowCheck.call r) (f r.flags 7) (f r.after 32)) (by simp [CallRowCheck.gates])).symm
  · exact (all (mulGate ((f r.after 0)++(f r.after 1)) (f r.flags 7) (f r.after 33)) (by simp [CallRowCheck.gates])).symm
  · exact select_sound values (f r.flags 0) r.heads.high (f r.before 5) (f r.after 10) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values ((f r.flags 0)++(f r.flags 1)) r.heads.low (f r.before 0) (f r.after 12) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values ((f r.flags 0)++(f r.flags 1)) r.heads.high (f r.before 1) (f r.after 13) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values ((f r.flags 0)++(f r.flags 1)) (CallRowCheck.indexed r) (f r.before 2) (f r.after 14) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values ((f r.flags 0)++(f r.flags 1)) z (f r.before 3) (f r.after 15) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values ((f r.flags 0)++(f r.flags 1)) z (f r.before 4) (f r.after 16) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values (CallRowCheck.argument r) r.payload.high (f r.after 12) (f r.after 27) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values (f r.after 20) r.payload.high (f r.after 13) (f r.after 28) (all _ (by simp [CallRowCheck.gates]))
  · exact select_sound values (f r.after 20) o (f r.after 15) (f r.after 30) (all _ (by simp [CallRowCheck.gates]))
  · exact equality_sound values one (f r.after 29) (sub (f r.after 14) (f r.after 19)) (all _ (by simp [CallRowCheck.gates]))
  · exact equality_sound values one (f r.after 31) ((f r.after 16)++(f r.after 21)) (all _ (by simp [CallRowCheck.gates]))
  · exact raw (sub o (f r.flags 1)) r.primary (by simp [CallRowCheck.gates])
  · exact raw (sub o (f r.flags 1)) r.secondary (by simp [CallRowCheck.gates])
  · exact raw (f r.after 11) (sub r.heads.high (f r.after 10)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 5) (sub r.tableQuery.value (n 5)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 19) (sub (sub o (f r.after 22)) (f r.after 23)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 18) ((f r.after 15)++(f r.after 16)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 20) ((CallRowCheck.tail r)++(f r.after 14)++(f r.after 16)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 20) (f r.after 12) (by simp [CallRowCheck.gates])
  · exact raw (CallRowCheck.argument r) (sub (sub o (f r.after 22)) (f r.after 26)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 20) (sub (f r.row 4) r.payload.low) (by simp [CallRowCheck.gates])
  · exact raw (CallRowCheck.call r) ((f r.flags 4)++(f r.flags 5)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 21) (sub o (CallRowCheck.tail r)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 21) ((f r.after 27)++(f r.after 29)++(f r.after 16)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 32) (f r.after 27) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 32) (f r.after 29) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 32) (sub (f r.after 31) (CallRowCheck.tail r)) (by simp [CallRowCheck.gates])
  · exact raw (f r.after 33) (f r.after 28) (by simp [CallRowCheck.gates])
  · apply zero_sound values one (sub (f r.row 4) (n 7)) (f r.after 22) (f r.reciprocals 4)
    intro g member; exact all g (by simp only [CallRowCheck.gates,List.mem_append]; grind only)
  · apply zero_sound values one (f r.row 4) (f r.after 23) (f r.reciprocals 5)
    intro g member; exact all g (by simp only [CallRowCheck.gates,List.mem_append]; grind only)
  · apply zero_sound values one (sub (f r.row 4) r.payload.low) (f r.after 26) (f r.reciprocals 6)
    intro g member; exact all g (by simp only [CallRowCheck.gates,List.mem_append]; grind only)

#print axioms meaning
end ZkBuild.CallRowEquations
