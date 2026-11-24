import TokenInteger

private def number (s : String) : IO Nat :=
  match s.toNat? with
  | some n => pure n
  | none => throw (IO.userError "invalid decoder integer")

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: export_token_decode CASES")
  let file ← IO.FS.Handle.mk path .read
  let mut count := 0
  repeat
    let line ← file.getLine
    if line = "" then break
    let kind::length::encoded := line.trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid decoder case")
    let kind ← number kind
    let length ← number length
    if kind > 6 || length = 0 || length > ZkBuild.BinaryTokenMatrix.capacity kind || encoded.length != length then
      throw (IO.userError "invalid decoder dimensions")
    let mut bytes := []
    for item in encoded do
      let byte ← number item
      if byte > 255 then throw (IO.userError "invalid byte")
      bytes := byte::bytes
    let ordered := bytes.reverse
    IO.println (ZkBuild.TokenInteger.decode kind length (fun i => ordered.getD i 0))
    count := count+1
  if count = 0 then throw (IO.userError "no decoder cases")
