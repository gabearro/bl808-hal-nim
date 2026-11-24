import RuntimeContextCli

def main (args : List String) : IO Unit := RuntimeContextCli.runWith args (fun _ _ => pure true)
