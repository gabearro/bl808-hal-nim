import InstructionMetadata

open ZkBuild.InstructionMetadata

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let handle ← IO.FS.Handle.mk path IO.FS.Mode.write
    handle.putStrLn "ZKMETA1 65536"
    for code in List.range 65536 do
      handle.putStrLn (String.intercalate " " ((code :: payload code).map toString))
    return 0
  | _ =>
    IO.eprintln "usage: export_instruction_metadata OUTPUT"
    return 1
