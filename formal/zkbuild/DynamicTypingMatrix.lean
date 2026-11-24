import ValidationEventCheck
set_option autoImplicit false
namespace ZkBuild.DynamicTypingMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix
structure Stage where
  kind : Nat
  rows : List Fields
  flags : List Fields
  selectors : List Fields
  inputs : List Fields
  outputs : List Fields
  auxiliary : List Fields
  banks : List Nat
  program : Program
  deriving Inhabited
structure Record where
  stages : List Stage
  deriving Inhabited

def bank (tables : List ReadOnlyMatrix.Record) (s : Stage) (i : Nat) := tables.getD (s.banks.getD i 0) default
def entry (e : ReadOnlyMatrix.Entry) : Fields := [e.active,e.address,e.value]
def query (active address value : Linear) : Fields := [active,address,value]
def singles (xs : List Linear) := xs.map fun x => [x]
def same (xs ys : List Fields) := decide (normalized xs = normalized ys)
def eventAt (s : Stage) (i : Nat) := rowAt s.rows i
def flagsAt (s : Stage) (i : Nat) := rowAt s.flags i
def selectorsAt (s : Stage) (i : Nat) := rowAt s.selectors i

def replaySelectors (matrix : Shape) (s : Stage) : Eval (List Fields) := do
  let p := s.program
  let mut outputs := []
  for row in s.rows do
    let mut tags := []
    for code in ([32,33,34,35,36,37,38,271,272,273] : List Nat) do
      let value ← zero matrix p (sub (f row 8) (n code))
      tags := tags++[value]
    let localTags := f tags 0++f tags 1++f tags 2
    let globalTags := f tags 3++f tags 4
    let table := f tags 5++f tags 6++f tags 7++f tags 8++f tags 9
    outputs := outputs++[tags++[localTags,globalTags,table,localTags++globalTags++table]]
  pure outputs

def replayEnvironment (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (s : Stage) : Eval (List Fields × List Fields × List Fields) := do
  let p := s.program
  for item in (bank tables s 0).entries do
    let invalid ← zero matrix p (sub item.value (n 7))
    eq matrix p invalid z
  for i in List.range (bank tables s 1).entries.length do
    let item := ((bank tables s 1).entries.getD i default)
    let bits ← range matrix p item.value 4
    let tag := f bits 0++scale (f bits 1) 2++scale (f bits 2) 4
    let invalid ← zero matrix p (sub tag (n 7))
    eq matrix p invalid z
    let category ← bit matrix p
    let aux := rowAt s.auxiliary i
    require (decide (ModuleProgram.sameInputs [category] [f aux 0])) "object category bit rejected"
    let half := f aux 1
    let _ ← range matrix p half 32
    eq matrix p item.address (scale half 2++category)
    raw matrix (gate category (f bits 3))
    let reference ← mul matrix p (sub tag (n 5)) (sub tag (n 6))
    raw matrix (gate category reference)
  let mut declared := z
  let mut outputs := []
  let mut locals := []
  let mut objects := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let tags := selectorsAt s i
    let immediate := f (rowAt s.inputs i) 0
    let _ ← range matrix p immediate 32
    raw matrix (gate (sub o (f flags 1)) immediate)
    let localQuery ← mul matrix p (f flags 1) (f tags 10)
    let objectQuery ← mul matrix p (f flags 1) (f tags 11++f tags 12)
    let tableQuery ← mul matrix p (f flags 1) (f tags 12)
    let localValue := ((bank tables s 0).queries.getD i default).value
    let objectValue := ((bank tables s 1).queries.getD i default).value
    let localAddress ← mul matrix p localQuery (scale (f row 1) (Int.ofNat (2^32))++immediate)
    let objectAddress ← mul matrix p objectQuery (scale immediate 2++f tags 12)
    locals := locals++[query localQuery localAddress localValue]
    objects := objects++[query objectQuery objectAddress objectValue]
    let bits ← range matrix p (localValue++objectValue) 4
    let tag := f bits 0++scale (f bits 1) 2++scale (f bits 2) 4
    let invalid ← zero matrix p (sub tag (n 7))
    eq matrix p invalid z
    raw matrix (gate (localQuery++tableQuery) (f bits 3))
    let setter ← mul matrix p (f flags 1) (f tags 4)
    raw matrix (gate setter (sub o (f bits 3)))
    let reference ← mul matrix p (sub tag (n 5)) (sub tag (n 6))
    raw matrix (gate tableQuery reference)
    declared ← select matrix p (f flags 0++f flags 1) tag declared
    outputs := outputs++[[declared]]
  pure (outputs,locals,objects)

def replayVariables (matrix : Shape) (s : Stage) : Eval Unit := do
  let p := s.program
  let mut pops := z
  let mut pushes := z
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let tags := selectorsAt s i
    let declared := f (rowAt s.inputs i) 0
    let reset := f flags 0++f flags 1
    let beforePops ← select matrix p reset z pops
    let beforePushes ← select matrix p reset z pushes
    let inputs := f tags 1++f tags 2++f tags 4++f tags 5++scale (f tags 6++f tags 7) 2++scale (f tags 9) 3
    let outputs := f tags 0++f tags 2++f tags 3++f tags 5++f tags 7++f tags 8
    let contextOutput := f tags 0++f tags 2++f tags 3++f tags 5
    let outputType ← mul matrix p contextOutput declared
    let first ← zero matrix p beforePops
    let second ← zero matrix p (sub beforePops o)
    let left ← mul matrix p first (f tags 1++f tags 2++f tags 4++f tags 6)
    let right ← mul matrix p second (f tags 7++f tags 9)
    let inputType ← mul matrix p (left++right) declared
    let actual := f row 4
    let matched ← zero matrix p (sub actual inputType)
    let unknown ← zero matrix p (sub actual (n 7))
    let typedPop ← mul matrix p (f tags 13) (f flags 3)
    let typedPush ← mul matrix p (f tags 13) (f flags 2)
    raw matrix (gate typedPop (sub o (matched++unknown)))
    raw matrix (gate typedPop beforePushes)
    raw matrix (gate typedPush (sub actual outputType))
    raw matrix (gate typedPush (sub o outputs))
    raw matrix (gate typedPush (sub beforePops inputs))
    raw matrix (gate typedPush beforePushes)
    raw matrix (gate (f tags 13) (f flags 4++f flags 5++f flags 6))
    let finish ← mul matrix p (f tags 13) (f flags 7)
    raw matrix (gate finish (sub beforePops inputs))
    raw matrix (gate finish (sub beforePushes outputs))
    pops ← materialize matrix p (beforePops++f flags 3)
    pushes ← materialize matrix p (beforePushes++f flags 2)
end ZkBuild.DynamicTypingMatrix
