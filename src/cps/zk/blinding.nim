## Keep proof A/B within the verifier's non-infinity encoding policy. A
## nonzero scalar can still cancel the unblinded point, so check the result.
import groups

proc sampleBlinding*[P: Point1 | Point2](base, delta: P,
    draw: proc(): Scalar {.closure.}): tuple[point: P, nonce: Scalar] =
  # Honest uniform sampling almost always succeeds on the first draw. The cap
  # also makes a broken source or a malformed key fail instead of hanging.
  for _ in 0..<128:
    let nonce = draw()
    if nonce.zero(): continue
    let point = base.add(delta.multiply(nonce))
    if not bool(point.isNeutral()): return (point, nonce)
  raise newException(ValueError, "unable to sample non-infinite proof blinding")
