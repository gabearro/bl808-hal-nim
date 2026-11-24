import ValidationEventCheck
import InstructionSourceAuditIO
set_option autoImplicit false
namespace ZkBuild.ValidationEventAuditIO
open CircuitShape AuditIO ModuleContextAuditIO SourceProgramIO ValidationEventMatrix

def readStatic (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (StaticLookupEmbedded.Record × Std.HashMap String Int) := do
  let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing static rule")
  if tag != "S" || fields.length != 6 then throw (IO.userError "invalid static header")
  let ns ← fields.mapM number
  let count := ns.getD 5 0
  if count == 0 || count > 131071 then throw (IO.userError "invalid static nodes")
  let (rows,cache) ← readRows file wires cache
  if rows.length != 3 then throw (IO.userError "invalid static fields")
  let (opcode,next) ← TokenAuditIO.readUse file wires cache
  let (actual,next) ← TokenAuditIO.readUse file wires next
  let mut nodes := []
  for _ in [:count] do
    let tag::fields := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing static node")
    if tag != "N" || fields.length != 10 then throw (IO.userError "invalid static node")
    let k ← number (fields.getD 0 "")
    let bit ← number (fields.getD 1 "")
    let zero ← number (fields.getD 2 "")
    let one ← number (fields.getD 3 "")
    let mut payload := []
    for field in fields.drop 4 do
      let some value := field.toInt? | throw (IO.userError "invalid static payload")
      payload := value::payload
    nodes := (⟨k,bit,zero,one,payload.reverse⟩ : StaticLookupMatrix.Node)::nodes
  pure (⟨ns.getD 0 0,ns.getD 1 0,ns.getD 2 0,ns.getD 3 0,ns.getD 4 0,
    opcode,actual,rows.getD 0 [],rows.getD 1 [],rows.getD 2 [],nodes.reverse⟩,next)

def read (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) : IO (StaticCatalog × LookupCatalog × ValidationEventMatrix.Record × Std.HashMap String Int) := do
  let [tag,statics,admission] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "missing validation header")
  let statics ← number statics
  let admission ← number admission
  if tag != "V" || statics > 1048576 || admission > 1048576 then throw (IO.userError "invalid validation dimensions")
  let mut cache := cache
  let mut rules := []
  let mut allowed := []
  for _ in [:statics] do
    let id ← InstructionSourceAuditIO.header file "J" 1048576
    let (r,next) ← readStatic file wires cache
    rules := (id,r)::rules
    cache := next
  for _ in [:admission] do
    let id ← InstructionSourceAuditIO.header file "J" 1048576
    let (r,next) ← LookupAuditIO.readLookup file wires cache
    allowed := (id,r)::allowed
    cache := next
  let count ← InstructionSourceAuditIO.header file "E" 5
  let (firstFunction,next) ← linear file wires cache
  let (rows,next) ← readRows file wires next
  cache := next
  let mut stages := []
  for _ in [:count] do
    let kind ← InstructionSourceAuditIO.header file "G" 4
    let (first,next) ← linear file wires cache
    let (rows,next) ← readRows file wires next
    let (flags,next) ← readRows file wires next
    let (inputs,next) ← readRows file wires next
    let (outputs,next) ← readRows file wires next
    let (program,next) ← readProgram file wires next
    stages := (⟨kind,first,rows,flags,inputs,outputs,program⟩ : Stage)::stages
    cache := next
  let (operand,next) ← readMemory file wires cache
  let (control,next) ← readMemory file wires next
  pure (rules.reverse,allowed.reverse,⟨firstFunction,rows,stages.reverse,operand,control⟩,next)

def staticView (xs : StaticCatalog) := xs.map (fun (id,r) => (id,r.root,r.nodes))
def admissionView (xs : LookupCatalog) := xs.map (fun (id,r) => (id,r.root,r.columns,r.nodes))
def allowed (code field : Nat) : Int := if field = 0 && OpcodeCatalog.admitted code then 1 else 0

def catalogs (statics : StaticCatalog) (admission : LookupCatalog) : Bool :=
  decide ((statics.map Prod.fst).Nodup ∧ (admission.map Prod.fst).Nodup) &&
  (match statics.head? with
  | none => false
  | some (_,first) => StaticLookupEmbedded.checkTable first &&
      statics.all (fun (_,r) => decide (r.root = first.root ∧ r.nodes = first.nodes))) &&
  (match admission.head? with
  | none => false
  | some (_,first) => first.columns == 1 && LookupEmbedded.checkTable first 16 allowed &&
      admission.all (fun (_,r) => decide (r.columns = 1 ∧ r.root = first.root ∧ r.nodes = first.nodes)))
end ZkBuild.ValidationEventAuditIO
