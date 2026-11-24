import RuntimeContextCli
import ControlTraceSound
set_option autoImplicit false
open ZkBuild

def main (args : List String) : IO Unit :=
  RuntimeContextCli.runWith args fun matrix events => do
    if !ControlCertificate.check matrix events then return false
    let stage := ValidationEventCheck.stage events 2
    if !ControlRowCheck.checkStage matrix stage then
      for i in [:stage.rows.length] do
        if !ControlRowCheck.check matrix (ControlRowCheck.record stage i) then
          throw (IO.userError s!"control semantic row {i} rejected")
      return false
    IO.println s!"control semantics PASS: rows={stage.rows.length}"
    return true
