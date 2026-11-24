import ParametricEvents

open ZkBuild

def decodeAction (code : Nat) : Option ControlPlans.Action :=
  if code < 8 then some (.pop code)
  else if 16 ≤ code ∧ code < 24 then some (.push (code-16))
  else none

def checkCase : List Nat → Bool
  | opcode :: immediate :: size :: rest =>
    let actions := rest.filterMap decodeAction
    decide (rest.length = size ∧ actions.length = size) && ParametricEvents.check opcode immediate actions
  | _ => false

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let lines ← IO.FS.lines path
    let mut total := 0
    let mut accepted := 0
    for line in lines do
      if !line.isEmpty then
        let mut numbers : List Nat := []
        for word in line.splitOn " " do
          if !word.isEmpty then
            match word.toNat? with
            | none => IO.eprintln "invalid parametric-plan integer"; return 2
            | some n => numbers := numbers ++ [n]
        total := total+1
        if checkCase numbers then accepted := accepted+1
    IO.println s!"ZKPARAM1 {accepted} {total}"
    return if accepted = total then 0 else 1
  | _ =>
    IO.eprintln "usage: check_parametric_plans CASES"
    return 2
