## Pack 32 big-endian bytes into little-endian 32- or 64-bit words.
## This operation packs all 256 bits; callers enforce scalar canonicality.
import scalar_encoding

func scalarWords*[W: uint32 | uint64](bytes: array[ScalarEncodingSize, byte]):
    array[ScalarEncodingSize div sizeof(W), W] {.inline.} =
  const wordBytes = sizeof(W)
  for i in 0..<result.len:
    var word: W
    for j in 0..<wordBytes:
      word = (word shl 8) + W(bytes[ScalarEncodingSize-(i+1)*wordBytes+j])
    result[i] = word
