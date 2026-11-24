import BinarySourceEmbedded
import MemoryEmbedded

namespace ZkBuild.AuditIO

open CircuitShape

def number (text : String) : IO Nat :=
  match text.toNat? with
  | some n => pure n
  | none => throw (IO.userError "invalid audit integer")

def scalar (text : String) : IO Int := do
  if text.length != 64 then throw (IO.userError "invalid scalar encoding")
  let mut n := 0
  for ch in text.toList do
    let c := ch.toNat
    let digit ← if 48 ≤ c && c ≤ 57 then pure (c-48)
      else if 97 ≤ c && c ≤ 102 then pure (c-87)
      else throw (IO.userError "invalid scalar hex")
    n := 16*n+digit
  if n ≥ scalarModulus then throw (IO.userError "noncanonical scalar")
  return Int.ofNat n

def linear (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (Linear × Std.HashMap String Int) := do
  let fields := (← file.getLine).trimAscii.toString.splitOn " "
  let count::terms := fields | throw (IO.userError "missing linear expression")
  let count ← number count
  if count != terms.length || count > 1048576 then throw (IO.userError "invalid linear term count")
  let mut out := []
  let mut cache := cache
  for term in terms do
    let [wire,value] := term.splitOn ":" | throw (IO.userError "invalid matrix term")
    let wire ← number wire
    if wire ≥ wires then throw (IO.userError "matrix wire out of bounds")
    let coefficient ← match cache[value]? with
      | some old => pure old
      | none => scalar value
    cache := cache.insert value coefficient
    out := (wire,coefficient)::out
  return (out.reverse,cache)

def readGadgetRange (file : IO.FS.Handle) (wires : Nat) (oldCache : Std.HashMap String Int) :
    IO (GadgetAudit.Record × Std.HashMap String Int) := do
  let [tag,kind,width,firstWire,lastWire,firstGate,lastGate,reference,inputs,outputs] :=
    (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid range record")
  if tag != "R" then throw (IO.userError "invalid range tag")
  let kind ← number kind
  let width ← number width
  let firstWire ← number firstWire
  let lastWire ← number lastWire
  let firstGate ← number firstGate
  let lastGate ← number lastGate
  let reference ← number reference
  let inputs ← number inputs
  let outputs ← number outputs
  if inputs != 1 || outputs != width || width > 248 then throw (IO.userError "invalid range arity")
  let (input,cache) ← linear file wires oldCache
  let mut cache := cache
  let mut bits := []
  for _ in [:outputs] do
    let (value,next) ← linear file wires cache
    cache := next
    bits := value::bits
  return (⟨kind,width,firstWire,lastWire,firstGate,lastGate,reference,[input],bits.reverse⟩,cache)

def readSource (file : IO.FS.Handle) (wires : Nat) (oldCache : Std.HashMap String Int) :
    IO (BinarySourceEmbedded.Record × Std.HashMap String Int) := do
  let [tag,firstWire,lastWire,firstGate,lastGate,capacity,limbs,outputs] :=
    (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid source record")
  if tag != "B" then throw (IO.userError "invalid source tag")
  let firstWire ← number firstWire
  let lastWire ← number lastWire
  let firstGate ← number firstGate
  let lastGate ← number lastGate
  let capacity ← number capacity
  let limbs ← number limbs
  let outputs ← number outputs
  if capacity > 16384 || limbs != (capacity+30)/31 || outputs != 3*capacity then
    throw (IO.userError "invalid source dimensions")
  let (length,cache) ← linear file wires oldCache
  let mut cache := cache
  let mut packed := []
  let mut returned := []
  for _ in [:limbs] do
    let (value,next) ← linear file wires cache
    cache := next
    packed := value::packed
  for _ in [:outputs] do
    let (value,next) ← linear file wires cache
    cache := next
    returned := value::returned
  let (range,finalCache) ← readGadgetRange file wires cache
  return (⟨range,firstWire,lastWire,firstGate,lastGate,capacity,length,packed.reverse,returned.reverse⟩,finalCache)

def readHash (file : IO.FS.Handle) (wires : Nat) (oldCache : Std.HashMap String Int) :
    IO (ShaEmbedded.Record × Std.HashMap String Int) := do
  let [tag,firstWire,lastWire,firstGate,lastGate,capacity] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid hash record")
  if tag != "S" then throw (IO.userError "invalid hash tag")
  let firstWire ← number firstWire
  let lastWire ← number lastWire
  let firstGate ← number firstGate
  let lastGate ← number lastGate
  let capacity ← number capacity
  if capacity > 16384 then throw (IO.userError "invalid hash capacity")
  let (length,cache) ← linear file wires oldCache
  let mut cache := cache
  let mut digest := []
  let mut source := []
  for _ in [:2] do
    let (value,next) ← linear file wires cache
    cache := next
    digest := value::digest
  for _ in [:capacity] do
    let (value,next) ← linear file wires cache
    cache := next
    source := value::source
  let (range,finalCache) ← readGadgetRange file wires cache
  return (⟨range,firstWire,lastWire,firstGate,lastGate,source.reverse,length,digest.reverse⟩,finalCache)

def readMemoryRange (file : IO.FS.Handle) : IO MemoryEvidence.RangeRef := do
  let [tag,kind,firstWire,lastWire,firstGate,lastGate] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid memory range")
  if tag != "R" then throw (IO.userError "invalid range tag")
  return ⟨← number kind,← number firstWire,← number lastWire,← number firstGate,← number lastGate⟩

def readAccess (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) (clock : Linear) :
    IO (MemoryEvidence.AccessRef × Std.HashMap String Int) := do
  let [tag,firstGate,lastGate] := (← file.getLine).trimAscii.toString.splitOn " " | throw (IO.userError "invalid access header")
  if tag != "A" then throw (IO.userError "invalid access tag")
  let (active,cache) ← linear file wires cache
  let (write,cache) ← linear file wires cache
  let (address,cache) ← linear file wires cache
  let (value,cache) ← linear file wires cache
  let a ← readMemoryRange file
  let v ← readMemoryRange file
  return (⟨← number firstGate,← number lastGate,⟨active,write,address,value,clock⟩,a,v⟩,cache)

def readMemory (file : IO.FS.Handle) (wires : Nat) (cache : Std.HashMap String Int) :
    IO (MemoryEmbedded.Record × Std.HashMap String Int) := do
  let [tag,a,t,v,inputCount,rowCount] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid memory record")
  if tag != "M" then throw (IO.userError "invalid memory tag")
  let a ← number a
  let t ← number t
  let v ← number v
  let inputCount ← number inputCount
  let rowCount ← number rowCount
  if a > 64 || t > 20 || v > 64 || inputCount != 2^t || rowCount != inputCount then
    throw (IO.userError "memory dimensions out of bounds")
  let mut cache := cache
  let mut inputs := []
  for i in [:inputCount] do
    let (access,next) ← readAccess file wires cache (constant (Int.ofNat i))
    cache := next
    inputs := access::inputs
  let mut rows := []
  for _ in [:rowCount] do
    let [tag,firstWire,lastWire,firstGate,lastGate] := (← file.getLine).trimAscii.toString.splitOn " " |
      throw (IO.userError "invalid sorted memory row")
    if tag != "S" then throw (IO.userError "invalid sorted row tag")
    let (access,next) ← readAccess file wires cache (constant 0)
    let (clock,next) ← linear file wires next
    cache := next
    let range ← readMemoryRange file
    rows := ⟨{ access with fields := { access.fields with clock := clock } },range,
      ← number firstWire,← number lastWire,← number firstGate,← number lastGate⟩::rows
  let [tag,depth,firstWire,lastWire,firstGate,lastGate,capacity] := (← file.getLine).trimAscii.toString.splitOn " " |
    throw (IO.userError "invalid memory permutation")
  if tag != "P" then throw (IO.userError "invalid memory permutation tag")
  let depth ← number depth
  let capacity ← number capacity
  if depth != t || capacity != inputCount then throw (IO.userError "memory permutation dimensions differ")
  let mut packed := []
  let mut reordered := []
  for _ in [:capacity] do
    let (value,next) ← linear file wires cache
    cache := next
    packed := value::packed
  for _ in [:capacity] do
    let (value,next) ← linear file wires cache
    cache := next
    reordered := value::reordered
  let network : PermutationEmbedded.Record := ⟨depth,← number firstWire,← number lastWire,← number firstGate,
    ← number lastGate,packed.reverse,reordered.reverse⟩
  return (⟨a,t,v,inputs.reverse,rows.reverse,network⟩,cache)

end ZkBuild.AuditIO
