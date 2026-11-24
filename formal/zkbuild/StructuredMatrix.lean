import DynamicTypingCheck
set_option autoImplicit false
namespace ZkBuild.StructuredMatrix
open CircuitShape GadgetShape DeclarationMatrix SourceProgram ValidationEventMatrix DynamicTypingMatrix
structure Record where
  stages : List DynamicTypingMatrix.Stage
  frames : MemoryEmbedded.Record
  scratch : MemoryEmbedded.Record
  deriving Inhabited
def stage (r : StructuredMatrix.Record) (kind : Nat) := (r.stages.find? (fun s => s.kind == kind)).getD default
def readQuery (matrix : Shape) (p : Program) (active key : Linear) (q : Fields) : Eval Fields := do
  let address ← mul matrix p active key
  pure [active,address,f q 2]
def pack (matrix : Shape) (p : Program) (bits : List Linear) : Eval Linear := do
  let mut value : Linear := []
  for i in List.range bits.length do value := value++scale (f bits i) (Int.ofNat (2^i))
  materialize matrix p value
def catchSplit (matrix : Shape) (p : Program) (value : Linear) : Eval Fields := do
  let bits ← range matrix p value 34
  let next ← pack matrix p (bits.drop 2)
  pure [f bits 1,f bits 0,next]
def frameSplit (matrix : Shape) (p : Program) (value : Linear) : Eval Fields := do
  let bits ← range matrix p value 36
  let kind := f bits 0++scale (f bits 1) 2
  let descriptor ← pack matrix p (bits.drop 2)
  let index ← pack matrix p (bits.drop 4)
  let both ← mul matrix p (f bits 2) (f bits 3)
  pure [value,kind,descriptor,index,sub (sub o (f bits 2)) (f bits 3)++both,sub (f bits 2) both,sub (f bits 3) both,both]
def memberQuery (matrix : Shape) (p : Program) (active head ordinal : Linear) (q : Fields) : Eval Fields := do
  let h ← mul matrix p active head
  let i ← mul matrix p active ordinal
  let _ ← range matrix p h 32
  let _ ← range matrix p i 32
  pure [active,scale h (Int.ofNat (2^32))++i,f q 2]
def qAt (row : Fields) (offset : Nat) := row.drop offset |>.take 3

def catchEnvironment (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List Fields × List (List Fields)) := do
  let p := s.program
  let b := bank tables s 0
  let l := bank tables s 1
  let c := bank tables s 2
  let mut links := []
  for i in List.range b.entries.length do
    let entry := b.entries.getD i default
    let _ ← range matrix p entry.value 32
    let zero ← zero matrix p entry.value
    let active ← mul matrix p entry.active (sub o zero)
    let q ← readQuery matrix p active entry.value (DynamicTypingMatrix.entry (l.queries.getD i default))
    links := links++[q]
  for i in List.range l.entries.length do
    let entry := l.entries.getD i default
    let data := c.entries.getD i default
    eq matrix p entry.active data.active
    eq matrix p entry.address data.address
    raw matrix (gate entry.active (sub entry.address (n (i+1))))
    let parts ← catchSplit matrix p entry.value
    let (low,_) ← split matrix [] splits p data.value
    let all ← mul matrix p entry.active (f parts 0)
    raw matrix (gate all low)
    let diff ← mul matrix p entry.active (sub (sub entry.address (f parts 2)) o)
    let _ ← range matrix p diff 32
    let isZero ← zero matrix p (f parts 2)
    let active ← mul matrix p entry.active (sub o isZero)
    let q ← readQuery matrix p active (f parts 2) (DynamicTypingMatrix.entry (l.queries.getD (b.entries.length+i) default))
    links := links++[q]
  let mut cursor := z
  let mut pushed := z
  let mut banks := []
  let mut clauses := []
  let mut outputs := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let secondary := f (rowAt s.inputs i) 0
    let trying ← zero matrix p (sub (f row 8) (n 31))
    let _ ← range matrix p (f row 8) 16
    let _ ← range matrix p secondary 32
    raw matrix (gate (sub o (f flags 1)) secondary)
    let active ← mul matrix p (f flags 1) trying
    let bankQuery ← readQuery matrix p active (scale (f row 1) (Int.ofNat (2^32))++secondary) (DynamicTypingMatrix.entry (b.queries.getD i default))
    banks := banks++[bankQuery]
    let reset := f flags 0++f flags 1
    cursor ← select matrix p reset (f bankQuery 2) cursor
    pushed ← select matrix p reset z pushed
    let mark ← mul matrix p (f flags 9) trying
    raw matrix (gate mark pushed)
    let nil ← zero matrix p cursor
    raw matrix (gate mark nil)
    let link ← readQuery matrix p mark cursor (DynamicTypingMatrix.entry (l.queries.getD (b.entries.length+l.entries.length+i) default))
    let clause ← readQuery matrix p mark cursor (DynamicTypingMatrix.entry (c.queries.getD i default))
    links := links++[link]
    clauses := clauses++[clause]
    let parts ← catchSplit matrix p (f link 2)
    let (tag,depth) ← split matrix [] splits p (f clause 2)
    let tagged ← mul matrix p mark (sub o (f parts 0))
    let reference ← mul matrix p mark (f parts 1)
    outputs := outputs++[[mark,depth,tag,tagged,reference]]
    cursor ← select matrix p mark (f parts 2) cursor
    let push ← mul matrix p trying (f flags 4)
    pushed ← materialize matrix p (pushed++push)
    let finish ← mul matrix p trying (f flags 7)
    raw matrix (gate finish cursor)
  eq matrix p cursor z
  pure (outputs,[banks,links,clauses])

def filterLabels (matrix : Shape) (s : DynamicTypingMatrix.Stage) : Eval (List Fields) := do
  let mut outputs := []
  for i in List.range s.rows.length do
    let flags := flagsAt s i
    let table ← zero matrix s.program (sub (f (eventAt s i) 8) (n 14))
    let label ← mul matrix s.program (f flags 9) table
    outputs := outputs++[flags.take 9++[label]++flags.drop 10]
  pure outputs

def branchEnvironment (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage) : Eval (List Fields × List (List Fields)) := do
  let p := s.program
  let b := bank tables s 0
  let ns := bank tables s 1
  let mut nodes := []
  for i in List.range b.entries.length do
    let entry := b.entries.getD i default
    let _ ← range matrix p entry.value 32
    let nil ← zero matrix p entry.value
    raw matrix (gate entry.active nil)
    let q ← readQuery matrix p entry.active entry.value (DynamicTypingMatrix.entry (ns.queries.getD i default))
    nodes := nodes++[q]
  for i in List.range ns.entries.length do
    let entry := ns.entries.getD i default
    let (_,next) ← split matrix [] splits p entry.value
    let delta ← select matrix p entry.active (sub (sub entry.address next) o) z
    let _ ← range matrix p delta 32
    let nil ← zero matrix p next
    let active ← mul matrix p entry.active (sub o nil)
    let q ← readQuery matrix p active next (DynamicTypingMatrix.entry (ns.queries.getD (b.entries.length+i) default))
    nodes := nodes++[q]
  let mut cursor := z
  let mut banks := []
  let mut outputs := []
  for i in List.range s.rows.length do
    let row := eventAt s i
    let flags := flagsAt s i
    let primary := f (rowAt s.inputs i) 0
    let table ← zero matrix p (sub (f row 8) (n 14))
    let begin ← mul matrix p (f flags 1) table
    let _ ← range matrix p primary 32
    let q ← readQuery matrix p begin (scale (f row 1) (Int.ofNat (2^32))++primary) (DynamicTypingMatrix.entry (b.queries.getD i default))
    banks := banks++[q]
    cursor ← select matrix p (f flags 0++f flags 1) (f q 2) cursor
    raw matrix (gate (f flags 9) (sub o table))
    let nil ← zero matrix p cursor
    raw matrix (gate (f flags 9) nil)
    let node ← readQuery matrix p (f flags 9) cursor (DynamicTypingMatrix.entry (ns.queries.getD (b.entries.length+ns.entries.length+i) default))
    nodes := nodes++[node]
    let (depth,next) ← split matrix [] splits p (f node 2)
    let nil ← zero matrix p next
    let last ← mul matrix p (f flags 9) nil
    outputs := outputs++[[depth,last]]
    cursor ← select matrix p (f flags 9) next cursor
    let finish ← mul matrix p (f flags 7) table
    raw matrix (gate finish cursor)
  eq matrix p cursor z
  pure (outputs,[banks,nodes])
end ZkBuild.StructuredMatrix
