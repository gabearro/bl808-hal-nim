import ControlPlans

open ZkBuild.ControlPlans

def modeForCode : Nat → Option Mode
  | 2 => some .blockOp | 3 => some .loopOp | 4 => some .ifOp | 5 => some .elseOp
  | 11 => some .endOp | 12 => some .brOp | 13 => some .brIfOp | 15 => some .returnOp
  | 31 => some .tryOp | _ => none

def decodeAction (code : Nat) : Option Action :=
  if code < 8 then some (.pop code)
  else if 16 ≤ code ∧ code < 24 then some (.push (code-16))
  else if code = 32 then some .openFrame
  else if code = 33 then some .closeFrame
  else if code = 34 then some .clear
  else none

def checkCase : List Nat → Bool
  | code :: root :: implicitElse :: p :: r :: l :: a :: rest =>
    if root > 1 ∨ implicitElse > 1 ∨ rest.length ≠ p+r+l+a then false
    else match modeForCode code with
    | none => false
    | some mode =>
      let params := rest.take p
      let results := (rest.drop p).take r
      let labels := (rest.drop (p+r)).take l
      let tokens := (rest.drop (p+r+l)).filterMap decodeAction
      let spec := layout mode params results labels (root == 1)
      decide (tokens.length = a) && (params ++ results ++ labels).all (fun t => decide (t < 7)) &&
        (implicitElse == 0 || (mode == .endOp && params == results)) &&
        check (plan spec.inputs spec.frames spec.outputs spec.clears) tokens
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
            | none => IO.eprintln "invalid control-plan integer"; return 2
            | some n => numbers := numbers ++ [n]
        total := total+1
        if checkCase numbers then accepted := accepted+1
    IO.println s!"ZKCONTROL1 {accepted} {total}"
    return if accepted = total then 0 else 1
  | _ =>
    IO.eprintln "usage: check_control_plans CASES"
    return 2
