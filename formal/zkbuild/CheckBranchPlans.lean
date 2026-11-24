import BranchPlans

open ZkBuild.BranchPlans

def decodeAction (code : Nat) : Option Action :=
  if code < 8 then some (.pop code)
  else if 16 ≤ code ∧ code < 24 then some (.push (code-16))
  else if code = 32 then some .label
  else if code = 33 then some .clear
  else none

def readTargets : Nat → List Nat → Option (List (List Nat) × List Nat)
  | 0, rest => some ([], rest)
  | _+1, [] => none
  | n+1, size :: rest =>
    if size > rest.length then none
    else match readTargets n (rest.drop size) with
    | none => none
    | some (targets, tail) => some (rest.take size :: targets, tail)

def checkCase : List Nat → Bool
  | count :: actions :: rest =>
    match readTargets count rest with
    | none => false
    | some (targets, tokens) =>
      let decoded := tokens.filterMap decodeAction
      decide (tokens.length = actions ∧ decoded.length = actions) &&
        (targets.flatten.all (fun tag => decide (tag < 7))) && check targets decoded
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
            | none => IO.eprintln "invalid branch-plan integer"; return 2
            | some n => numbers := numbers ++ [n]
        total := total+1
        if checkCase numbers then accepted := accepted+1
    IO.println s!"ZKBRANCH1 {accepted} {total}"
    return if accepted = total then 0 else 1
  | _ =>
    IO.eprintln "usage: check_branch_plans CASES"
    return 2
