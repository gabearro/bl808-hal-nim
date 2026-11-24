import SignatureMatrix

namespace ZkBuild.SignatureNamespace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix

structure Row where
  firstGate : Nat
  lastGate : Nat
  entry : Entry
  range : RangeUse.Record
  typeEntry : Linear
  index : Linear
  functions : Linear
  types : Linear
  deriving Inhabited

structure Record where
  firstAliasStart : Nat
  firstAliasEnd : Nat
  closeStart : Nat
  closeEnd : Nat
  typeBindStart : Nat
  typeBindEnd : Nat
  functionBindStart : Nat
  functionBindEnd : Nat
  functions : Linear
  types : Linear
  importedFunctions : Linear
  firstFunction : Linear
  importedRange : RangeUse.Record
  rows : List Row
  deriving Inhabited

def parity (r : Row) : Linear := (RangeUse.bits r.range).getD 0 z
def rowGates (r : Row) (functions types : Linear) : List Gate :=
  RangeUse.gates r.range++[mulGate r.entry.active (parity r) r.typeEntry,
    selectGate (parity r) types functions r.index,
    gate r.entry.active (sub (sub r.entry.address (scale r.index 2)) (parity r)),
    eqGate r.functions (functions++sub r.entry.active r.typeEntry),eqGate r.types (types++r.typeEntry)]
def checkRow (matrix : Shape) (r : Row) (functions types : Linear) : Bool :=
  RangeUse.check matrix r.range r.entry.address 33 && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (rowGates r functions types)
def checkRows (matrix : Shape) : List Row → Linear → Linear → Bool
  | [],_,_ => true
  | r::rest,f,t => checkRow matrix r f t && checkRows matrix rest r.functions r.types
def final : List Row → Linear → Linear → Linear × Linear
  | [],f,t => (f,t)
  | r::rest,_,_ => final rest r.functions r.types
def check (matrix : Shape) (declaration : DeclarationMatrix.Record) (signature : SignatureMatrix.Record) (r : Record) : Bool :=
  decide (r.rows.length < 2^32 ∧ r.firstFunction = declaration.firstFunction ∧
    r.rows.map Row.entry = signature.metadata.map SignatureMatrix.MetadataRow.entry) &&
  checkRows matrix r.rows z z &&
  RangeUse.check matrix r.importedRange r.importedFunctions 32 &&
  MemoryEvidence.checkSpan matrix r.firstAliasStart r.firstAliasEnd [eqGate r.firstFunction r.importedFunctions] &&
  MemoryEvidence.checkSpan matrix r.closeStart r.closeEnd [eqGate (final r.rows z z).1 r.functions,eqGate (final r.rows z z).2 r.types] &&
  MemoryEvidence.checkSpan matrix r.typeBindStart r.typeBindEnd [eqGate declaration.typeCount r.types] &&
  MemoryEvidence.checkSpan matrix r.functionBindStart r.functionBindEnd [eqGate declaration.functionCount (sub r.functions r.importedFunctions)]

end ZkBuild.SignatureNamespace
