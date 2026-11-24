import NameFrameBody
import LookupAuditIO
import Utf8Suffix
set_option autoImplicit false
namespace ZkBuild.NameGraphMatrix
open CircuitShape GadgetShape DeclarationMatrix

structure Node where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  entry : Entry
  query : Entry
  canonical : Entry
  fields : List Linear
  ranges : List RangeUse.Record
  lookup : LookupEmbedded.Record
  deriving Inhabited
structure Root where
  firstGate : Nat
  lastGate : Nat
  zeroStart : Nat
  head : Linear
  state : Linear
  query : Entry
  ranges : List RangeUse.Record
  deriving Inhabited
structure Record where
  tables : List Nat
  nodes : List Node
  roots : List Root
  deriving Inhabited

def field (r : Node) (i : Nat) := get r.fields i
def nodeRange (r : Node) (i : Nat) := r.ranges.getD i default
def slice (r : RangeUse.Record) (offset width : Nat) : Linear :=
  pack (BitPacking.bitWeights width) (((RangeUse.bits r).drop offset).take width)
def table (tables : List ReadOnlyMatrix.Record) (r : Record) (i : Nat) := tables.getD (r.tables.getD i 0) default

def nodeParts (r : Node) (i : Nat) : List (List Gate) :=
  [[gate r.entry.active (sub r.entry.address (n (i+1)))],
   RangeUse.gates (nodeRange r 0) ++ [eqGate (field r 0) (slice (nodeRange r 0) 0 8),
     eqGate (field r 1) (slice (nodeRange r 0) 8 32),eqGate (field r 2) (slice (nodeRange r 0) 40 2)],
   zeroGates (field r 1) (wire r.zeroStart) (wire (r.zeroStart+1)) ++
     [mulGate r.entry.active (sub o (wire r.zeroStart)) (field r 3),mulGate (field r 3) (field r 1) r.query.address],
   RangeUse.gates (nodeRange r 1) ++ [eqGate (field r 4) (slice (nodeRange r 1) 40 2),eqGate (field r 5) (slice (nodeRange r 1) 4 4)],
   RangeUse.gates r.lookup.range ++ (LookupEmbedded.program r.lookup).gates,
   [gate r.entry.active (sub (get r.lookup.outputs 0) o),gate r.entry.active (sub (field r 2) (get r.lookup.outputs 1)),
     mulGate r.entry.active (sub (sub r.entry.address (field r 1)) o) (field r 6)] ++
   RangeUse.gates (nodeRange r 2) ++ [mulGate r.entry.active (field r 0 ++ scale (field r 1) 256) r.canonical.address]]
def nodeGates (r : Node) (i : Nat) := (nodeParts r i).flatten

def nodeShape (r : Node) : Prop :=
  r.fields.length = 7 ∧ r.ranges.length = 3 ∧ r.lookup.columns = 2 ∧ r.lookup.outputs.length = 2 ∧
  r.lookup.input = field r 0 ++ scale (field r 4) 256 ++ scale (field r 5) 1024 ∧
  r.query.active = field r 3 ∧ r.canonical.active = r.entry.active ∧ r.canonical.value = r.entry.address
instance (r : Node) : Decidable (nodeShape r) := by unfold nodeShape; infer_instance

def checkNode (matrix : Shape) (r : Node) (i : Nat) : Bool :=
  decide (nodeShape r) && RangeUse.check matrix (nodeRange r 0) r.entry.value 42 &&
    RangeUse.check matrix (nodeRange r 1) r.query.value 42 && RangeUse.check matrix (nodeRange r 2) (field r 6) 32 &&
    LookupEmbedded.check matrix r.lookup && MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (nodeGates r i)

def rootGates (r : Root) : List Gate :=
  RangeUse.gates (r.ranges.getD 0 default) ++ zeroGates r.head (wire r.zeroStart) (wire (r.zeroStart+1)) ++
  RangeUse.gates (r.ranges.getD 1 default) ++ [eqGate r.state (slice (r.ranges.getD 1 default) 40 2),eqGate r.state z]
def checkRoot (matrix : Shape) (r : Root) : Bool :=
  decide (r.ranges.length = 2 ∧ normalizeLinear r.query.active = normalizeLinear (sub o (wire r.zeroStart)) ∧ r.query.address = r.head) &&
  RangeUse.check matrix (r.ranges.getD 0 default) r.head 32 && RangeUse.check matrix (r.ranges.getD 1 default) r.query.value 42 &&
  MemoryEvidence.checkSpan matrix r.firstGate r.lastGate (rootGates r)

def links (tables : List ReadOnlyMatrix.Record) (r : Record) : Prop :=
  r.tables.length = 2 ∧ (∀ i ∈ r.tables, i < tables.length) ∧ r.nodes.length < 2^32-1 ∧
  (table tables r 0).entries = r.nodes.map Node.entry ∧
  (table tables r 0).queries = r.nodes.map Node.query ++ r.roots.map Root.query ∧
  (table tables r 1).queries = r.nodes.map Node.canonical ∧
  (table tables r 0).memory.addressBits = 32 ∧ (table tables r 0).memory.valueBits = 42 ∧
  (table tables r 1).memory.addressBits = 40 ∧ (table tables r 1).memory.valueBits = 32
instance (tables : List ReadOnlyMatrix.Record) (r : Record) : Decidable (links tables r) := by unfold links; infer_instance

def sameTable (a b : LookupEmbedded.Record) : Prop := a.columns = b.columns ∧ a.root = b.root ∧ a.nodes = b.nodes
instance (a b : LookupEmbedded.Record) : Decidable (sameTable a b) := by unfold sameTable; infer_instance

def checkTables (nodes : List Node) : Bool := match nodes with
  | [] => true
  | first::rest => LookupEmbedded.checkTable first.lookup 14 Utf8Suffix.expected && rest.all (fun r => decide (sameTable r.lookup first.lookup))

def check (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : Record) : Bool :=
  decide (links tables r) && (r.nodes.zipIdx.all (fun (node,i) => checkNode matrix node i)) &&
    r.roots.all (checkRoot matrix) && checkTables r.nodes
end ZkBuild.NameGraphMatrix
