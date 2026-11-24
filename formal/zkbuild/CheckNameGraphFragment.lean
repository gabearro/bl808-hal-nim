import NameGraphSoundness
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape ZkBuild.AuditIO ZkBuild.ReadOnlyAuditIO ZkBuild.NameGraphAuditIO

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "usage: check_name_graph_fragment AUDIT")
  let file ← IO.FS.Handle.mk path .read
  let [magic,wires,publicCount,gates,tables,graphs] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid name graph fragment header")
  let wires ← number wires
  let publicCount ← number publicCount
  let gates ← number gates
  let tables ← number tables
  let graphs ← number graphs
  if magic != "ZKNAMEGRAPHFRAG1" || wires = 0 || wires > 16777216 || publicCount ≥ wires || gates > 16777216 || tables > 65536 || graphs > 65536 then throw (IO.userError "invalid name graph dimensions")
  let mut matrix : Shape := {wires := wires,publicCount := publicCount,gates := Array.mkEmpty gates}
  let mut cache : Std.HashMap String Int := {}
  for _ in [:gates] do
    let (a,next) ← linear file wires cache
    let (b,next) ← linear file wires next
    let (c,next) ← linear file wires next
    cache := next
    matrix := {matrix with gates := matrix.gates.push ⟨a,b,c⟩}
  let mut rs := []
  for _ in [:tables] do
    let (r,next) ← readTable file wires cache
    cache := next
    rs := r::rs
  let mut gs := []
  for _ in [:graphs] do
    let (r,next) ← readNameGraph file wires cache
    cache := next
    gs := r::gs
  if !rs.all (ReadOnlyMatrix.check matrix) then throw (IO.userError "name graph immutable table rejected")
  for graph in gs do
    if !NameGraphMatrix.check matrix rs.reverse graph then
      for (node,i) in graph.nodes.zipIdx do
        if !NameGraphMatrix.checkNode matrix node i then
          let expected := NameGraphMatrix.nodeGates node i
          for j in [:expected.length] do
            if node.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[node.firstGate+j]! != normalizeGate expected[j]! then
              throw (IO.userError s!"name node {i} gate {node.firstGate+j}: actual={reprStr (normalizeGate matrix.gates[node.firstGate+j]!)} expected={reprStr (normalizeGate expected[j]!)}")
          throw (IO.userError s!"name node {i} rejected")
      for (root,i) in graph.roots.zipIdx do
        if !NameGraphMatrix.checkRoot matrix root then
          let expected := NameGraphMatrix.rootGates root
          for j in [:expected.length] do
            if root.firstGate+j < matrix.gates.size && normalizeGate matrix.gates[root.firstGate+j]! != normalizeGate expected[j]! then
              throw (IO.userError s!"name root {i} gate {root.firstGate+j}: actual={reprStr (normalizeGate matrix.gates[root.firstGate+j]!)} expected={reprStr (normalizeGate expected[j]!)}")
          throw (IO.userError s!"name root {i} shape/ranges rejected")
      if !decide (NameGraphMatrix.links rs.reverse graph) then throw (IO.userError "name graph table links rejected")
      throw (IO.userError "name graph UTF-8 lookup table rejected")
  if (← file.getLine) != "" then throw (IO.userError "trailing name graph data")
  IO.println s!"name graph fragment PASS: matrix={gates} graphs={gs.length}"
