## Fixed-capacity text (upstream `src/text.rs`).
##
## No heap, appends truncate at the capacity, and a `Text` copies as plain
## bytes with the player status. Shared by every package; pure Nim.

type
  Text*[N: static int] = object
    data: array[N, char]
    n: int32

func len*[N](t: Text[N]): int {.inline.} = t.n.int
func isEmpty*[N](t: Text[N]): bool {.inline.} = t.n == 0
func clear*[N](t: var Text[N]) {.inline.} = t.n = 0
func `[]`*[N](t: Text[N]; i: int): char {.inline.} = t.data[i]

template chars*[N](t: Text[N]): openArray[char] =
  ## The text as a borrowed `openArray[char]` (no copy).
  toOpenArray(t.data, 0, t.n.int - 1)

func add*[N](t: var Text[N]; c: char) =
  if t.n < N:
    t.data[t.n] = c
    inc t.n

func add*[N](t: var Text[N]; s: openArray[char]) =
  ## Append as much of `s` as fits, cutting only at a UTF-8 character
  ## boundary so the contents stay valid UTF-8.
  var take = min(s.len, N - t.n.int)
  while take > 0 and take < s.len and (s[take].ord and 0xC0) == 0x80:
    dec take
  for i in 0 ..< take:
    t.data[t.n.int + i] = s[i]
  t.n += take.int32

func addInt*[N](t: var Text[N]; v: SomeInteger) =
  ## Append `v` in decimal.
  var digits: array[20, char]
  var count = 0
  var rest = if v < 0: (0'u64 - cast[uint64](v.int64)) else: v.uint64
  while true:
    digits[count] = char(ord('0') + int(rest mod 10))
    inc count
    rest = rest div 10
    if rest == 0: break
  if v < 0: t.add '-'
  for i in countdown(count - 1, 0):
    t.add digits[i]

func addSanitized*[N](t: var Text[N]; bytes: openArray[char]) =
  ## Append as printable ASCII for the display's fonts (and safe for JSON
  ## after escaping): control characters become spaces, and each non-ASCII
  ## UTF-8 character (or Latin-1 byte) becomes one '?'.
  for c in bytes:
    if t.n >= N: break
    case c.ord
    of 0x20 .. 0x7E: t.data[t.n] = c
    of 0x80 .. 0xBF: continue          # UTF-8 continuation byte
    of 0xC0 .. 0xFF: t.data[t.n] = '?'
    else: t.data[t.n] = ' '
    inc t.n

func addSanitized*[N](t: var Text[N]; bytes: openArray[byte]) =
  t.addSanitized cast[ptr UncheckedArray[char]](unsafeAddr bytes)
    .toOpenArray(0, bytes.len - 1)

func set*[N](t: var Text[N]; s: openArray[char]) =
  t.n = 0
  t.add s

func toText*(s: openArray[char]; N: static int): Text[N] =
  result.add s

func `$`*[N](t: Text[N]): string =
  result = newString(t.n)
  for i in 0 ..< t.n.int:
    result[i] = t.data[i]

func `==`*[N](a: Text[N]; b: openArray[char]): bool =
  ## Compares the text only (bytes past the length may be left over).
  if a.n.int != b.len: return false
  for i in 0 ..< b.len:
    if a.data[i] != b[i]: return false
  true

func `==`*[N, M](a: Text[N]; b: Text[M]): bool =
  a == b.chars

# -----------------------------------------------------------------------------
# Trimming as Rust's `str::trim` does it
# -----------------------------------------------------------------------------

func isSpaceRune(cp: int): bool =
  ## Unicode White_Space, which is what Rust's `str::trim` removes.
  cp in 0x09 .. 0x0D or cp == 0x20 or cp == 0x85 or cp == 0xA0 or
    cp == 0x1680 or cp in 0x2000 .. 0x200A or cp == 0x2028 or cp == 0x2029 or
    cp == 0x202F or cp == 0x205F or cp == 0x3000

func runeAt(s: openArray[char]; i: int; size: var int): int =
  ## The code point starting at `i` of valid UTF-8 (a sequence cut short by
  ## the end of `s` is read as far as it goes).
  let b = s[i].ord
  if b < 0x80: size = 1; return b
  if b < 0xE0: size = 2; result = b and 0x1F
  elif b < 0xF0: size = 3; result = b and 0x0F
  else: size = 4; result = b and 0x07
  size = min(size, s.len - i)
  for k in 1 ..< size:
    result = (result shl 6) or (s[i + k].ord and 0x3F)

func trimmed*(s: openArray[char]): Slice[int] =
  ## The span of `s` (valid UTF-8) without leading and trailing white space.
  var first = 0
  var size = 0
  while first < s.len and isSpaceRune(runeAt(s, first, size)):
    first += size
  var last = s.len
  while last > first:
    var start = last - 1
    while start > first and (s[start].ord and 0xC0) == 0x80: dec start
    if not isSpaceRune(runeAt(s, start, size)): break
    last = start
  first .. last - 1
