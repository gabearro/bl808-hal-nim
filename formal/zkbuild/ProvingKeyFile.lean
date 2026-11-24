import Init.Omega

/- Framing and publication obligations for the streaming host key codec.
   This model does not assert cryptographic setup correctness or a refinement
   theorem for Nim/File I/O. Rename/flush semantics remain platform assumptions. -/
namespace ZkBuild.ProvingKeyFile

def profileWords : Nat := 23
def headerBytes : Nat := 4 + 4*profileWords + 488 + 12
def pointBytes (wires domain : Nat) : Nat :=
  96 + wires*192 + (wires-3)*48 + (domain-1)*48

theorem header_size : headerBytes = 596 := by decide

theorem point_array_size (wires domain : Nat) (hasPublic : 3 ≤ wires) (positive : 1 ≤ domain) :
    pointBytes wires domain + 96 = 240*wires + 48*domain := by
  unfold pointBytes
  omega

theorem read_within_frame (cursor size count : Nat)
    (inside : cursor ≤ size) (fits : count ≤ size-cursor) : cursor+count ≤ size := by omega

theorem term_array_before_allocation (cursor size count : Nat)
    (inside : cursor ≤ size) (fits : count*36 ≤ size-cursor) :
    cursor+count*36 ≤ size := by omega

theorem matrix_minimum (cursor size rows points : Nat)
    (inside : cursor ≤ size) (fits : rows*12+points ≤ size-cursor) :
    cursor+rows*12+points ≤ size := by omega

theorem no_trailing_data (cursor size : Nat) (exact : cursor = size) : size-cursor = 0 := by omega

-- Publication changes the old file only after the staged encoding is complete.
def publish {α : Type} (old staged : List α) (closed : Bool) : List α :=
  if closed then staged else old

theorem failed_write_preserves {α : Type} (old staged : List α) :
    publish old staged false = old := rfl

theorem completed_write_publishes {α : Type} (old staged : List α) :
    publish old staged true = staged := rfl

#print axioms point_array_size
#print axioms term_array_before_allocation
#print axioms matrix_minimum
#print axioms failed_write_preserves

end ZkBuild.ProvingKeyFile
