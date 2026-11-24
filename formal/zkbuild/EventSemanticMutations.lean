import OperandRowCheck
import ControlRowCheck
set_option autoImplicit false
open ZkBuild ZkBuild.CircuitShape ZkBuild.GadgetShape

def candidates (matrix : Shape) (r : OperandRowCheck.Record) : List OperandRowCheck.Record :=
  let foreign : Linear := [(matrix.wires+1,1)]
  (List.range 7).map (fun i => {r with row := r.row.set i foreign}) ++
  (List.range 11).map (fun i => {r with tags := r.tags.set i foreign}) ++
  (List.range 4).map (fun i => {r with access := r.access.set i foreign}) ++
  (List.range 5).map (fun i => {r with ranges := r.ranges.set i ({(r.ranges.getD i default) with call := {(r.ranges.getD i default).call with width := 255}})}) ++
  [{r with before := foreign},{r with available := foreign},{r with product := foreign},
   {r with discarded := foreign},{r with previousPadding := foreign},
   {r with row := []},{r with tags := []},{r with access := []},{r with ranges := []},
   {r with first := matrix.gates.size+1},{r with last := matrix.gates.size+1},
   {r with stepFirst := matrix.gates.size+1},{r with stepLast := matrix.gates.size+1},
   {r with accessFirst := matrix.gates.size+1},{r with accessLast := matrix.gates.size+1},
   {r with boundaryFirst := matrix.gates.size+1},{r with boundaryLast := matrix.gates.size+1}]
