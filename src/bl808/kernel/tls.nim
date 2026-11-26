## Non-blocking TLS client sessions over caller-supplied transport callbacks.
##
## The transport is whatever the caller wraps in a `TlsIo`: an lwIP raw-API
## TCP connection on the BL808, a socket in host tests. Nothing here blocks,
## sleeps or reads a clock; every call does what it can and reports
## `tlsWantRead` / `tlsWantWrite` when the transport has to move first.
##
## Backed by the vendored Mbed TLS 3.6 (vendor/mbedtls) with the BL808
## configuration in src/bl808/mbedtls: TLS 1.3 with a TLS 1.2 ECDHE fallback,
## SNI, full-size records. TLS_AES_128_GCM_SHA256 and P-256 are offered first
## because the M0 runs them on the chip; AES-256-GCM, ChaCha20-Poly1305,
## X25519 and P-384 follow for servers that insist.
##
## On the BL808 M0 (see bl808/mbedtls/hw, which this module switches on) the
## chip does: the SHA-224/256 and SHA-384/512 compression functions and AES
## block encryption (so the block cipher of GCM) on SEC_ENG; the P-256
## multiplications of ECDHE and of ECDSA signature checks, and the RSA
## public-key operation of RSA signature checks up to 2048 bits, on the PKA;
## entropy from the TRNG. Each of these checks itself against the software
## implementation on first use and falls back to it for good if they differ,
## or just for one call while its engine is in use elsewhere. AES-GCM records
## go to the chip whole (AES in counter mode, GHASH on the GMAC block). In
## software stay: ChaCha20-Poly1305, X25519 and P-384, multiples of the P-256
## base point (the built-in table is faster), RSA keys above 2048 bits, MD5, and
## SHA-1 unless the image is built with the Wi-Fi provider
## (-d:bl808WifiMbedTlsSha1Hardware). TLS handshakes here do not use SHA-1.
##
## Certificates are not verified unless `verifyPeer` is set, and then against
## the anchors given to `tlsAddTrustAnchor`. Validity dates are never checked:
## the build has no wall clock.
##
## Memory comes from the Mbed TLS allocator: the C library's calloc (the
## kernel heap) unless `tlsSetAllocator` redirects it. An open session holds
## about 30 KiB: 21 KiB of record buffers, the cipher state and the server's
## certificate chain. The handshake peaks a few KiB above that, more for a
## long chain, and about 3 KiB of shared random-generator state stays
## allocated between sessions (64-bit host figures from
## tools/tls_host_client.nim; the same run used under 4 KiB of stack).

import ../mbedtls/tls_sources

type
  TlsIo* = object
    ## Transport callbacks. Each returns the bytes moved, 0 for "would block",
    ## or a negative value when the connection is closed or has failed.
    ctx*: pointer
    send*: proc(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.}
    recv*: proc(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.}

  TlsStatus* = enum
    tlsOk, tlsWantRead, tlsWantWrite, tlsClosed, tlsError

  TlsErrorClass* = enum
    tlsErrNone          ## nothing failed; also the peer's orderly close_notify
    tlsErrRefused       ## the peer ended the handshake with a fatal alert
    tlsErrHandshake     ## no common version, suite or group; bad certificate
    tlsErrRecordTooBig  ## a record or handshake message exceeds the buffers
    tlsErrIo            ## the transport ended or failed under the session
    tlsErrOther

  TlsPhase = enum
    phaseIdle, phaseHandshake, phaseOpen, phaseClosed, phaseFailed

  SslContext {.importc: "mbedtls_ssl_context", header: "<mbedtls/ssl.h>".} = object
    inLeft {.importc: "in_left".}: csize_t   # bytes of the record being received
  SslConfig {.importc: "mbedtls_ssl_config", header: "<mbedtls/ssl.h>".} = object
  X509Crt {.importc: "mbedtls_x509_crt", header: "<mbedtls/x509_crt.h>".} = object
  ConstBytes {.importc: "const unsigned char *", nodecl.} = distinct pointer

  TlsState = object
    ## Mbed TLS keeps pointers into this block, so it lives on the heap and
    ## the session that owns it may move freely.
    ssl: SslContext
    conf: SslConfig
    io: TlsIo
    ioFailed: bool

  TlsSession* = object
    ## One TLS client connection. Declare it anywhere; `tlsOpen` allocates the
    ## protocol state and `tlsClose` (or the destructor) releases it.
    state: ptr TlsState
    phase: TlsPhase
    lastError: int32
    pendingWrite: int

  BioSend = proc(ctx: pointer; buf: ConstBytes; len: csize_t): cint {.cdecl.}
  BioRecv = proc(ctx: pointer; buf: ptr uint8; len: csize_t): cint {.cdecl.}
  RngCallback = proc(state: pointer; output: ptr uint8; len: csize_t): cint {.cdecl.}
  TlsCalloc* = proc(count, size: csize_t): pointer {.cdecl.}
  TlsFree* = proc(memory: pointer) {.cdecl.}

{.push importc, cdecl, header: "<mbedtls/ssl.h>".}
proc mbedtls_ssl_init(ssl: ptr SslContext)
proc mbedtls_ssl_free(ssl: ptr SslContext)
proc mbedtls_ssl_setup(ssl: ptr SslContext; conf: ptr SslConfig): cint
proc mbedtls_ssl_set_hostname(ssl: ptr SslContext; hostname: cstring): cint
proc mbedtls_ssl_set_bio(ssl: ptr SslContext; ctx: pointer; send: BioSend; recv: BioRecv;
                         recvTimeout: pointer)
proc mbedtls_ssl_handshake(ssl: ptr SslContext): cint
proc mbedtls_ssl_read(ssl: ptr SslContext; buf: ptr uint8; len: csize_t): cint
proc mbedtls_ssl_write(ssl: ptr SslContext; buf: ConstBytes; len: csize_t): cint
proc mbedtls_ssl_close_notify(ssl: ptr SslContext): cint
proc mbedtls_ssl_get_max_out_record_payload(ssl: ptr SslContext): cint
proc mbedtls_ssl_get_bytes_avail(ssl: ptr SslContext): csize_t
proc mbedtls_ssl_get_version(ssl: ptr SslContext): cstring
proc mbedtls_ssl_get_ciphersuite(ssl: ptr SslContext): cstring
proc mbedtls_ssl_config_init(conf: ptr SslConfig)
proc mbedtls_ssl_config_free(conf: ptr SslConfig)
proc mbedtls_ssl_config_defaults(conf: ptr SslConfig; endpoint, transport, preset: cint): cint
proc mbedtls_ssl_conf_authmode(conf: ptr SslConfig; mode: cint)
proc mbedtls_ssl_conf_rng(conf: ptr SslConfig; rng: RngCallback; state: pointer)
proc mbedtls_ssl_conf_groups(conf: ptr SslConfig; groups: ptr uint16)
proc mbedtls_ssl_conf_ciphersuites(conf: ptr SslConfig; suites: ptr cint)
proc mbedtls_ssl_conf_ca_chain(conf: ptr SslConfig; chain: ptr X509Crt; crl: pointer)
{.pop.}
proc mbedtls_x509_crt_init(chain: ptr X509Crt)
  {.importc, cdecl, header: "<mbedtls/x509_crt.h>".}
proc mbedtls_x509_crt_free(chain: ptr X509Crt)
  {.importc, cdecl, header: "<mbedtls/x509_crt.h>".}
proc mbedtls_x509_crt_parse_der(chain: ptr X509Crt; der: ConstBytes; len: csize_t): cint
  {.importc, cdecl, header: "<mbedtls/x509_crt.h>".}
proc mbedtls_psa_get_random(state: pointer; output: ptr uint8; len: csize_t): cint
  {.importc, cdecl, header: "<mbedtls/psa_util.h>".}
proc psa_crypto_init(): int32 {.importc, cdecl, header: "<psa/crypto.h>".}
proc mbedtls_calloc(count, size: csize_t): pointer
  {.importc, cdecl, header: "<mbedtls/platform.h>".}
proc mbedtls_free(memory: pointer) {.importc, cdecl, header: "<mbedtls/platform.h>".}
proc mbedtls_platform_set_calloc_free(calloc: TlsCalloc; free: TlsFree): cint
  {.importc, cdecl, header: "<mbedtls/platform.h>".}

{.push importc, nodecl, header: "<mbedtls/ssl.h>".}
var
  MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT: cint
  MBEDTLS_SSL_VERIFY_NONE, MBEDTLS_SSL_VERIFY_REQUIRED: cint
  MBEDTLS_SSL_IN_CONTENT_LEN: cint
  MBEDTLS_ERR_SSL_WANT_READ, MBEDTLS_ERR_SSL_WANT_WRITE: cint
  MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY, MBEDTLS_ERR_SSL_CONN_EOF: cint
  MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE: cint
  MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE, MBEDTLS_ERR_SSL_BAD_PROTOCOL_VERSION: cint
  MBEDTLS_ERR_SSL_ILLEGAL_PARAMETER, MBEDTLS_ERR_SSL_UNSUPPORTED_EXTENSION: cint
  MBEDTLS_ERR_SSL_FEATURE_UNAVAILABLE, MBEDTLS_ERR_SSL_BAD_CERTIFICATE: cint
  MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED, MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE: cint
  MBEDTLS_ERR_SSL_BUFFER_TOO_SMALL, MBEDTLS_ERR_SSL_INVALID_RECORD: cint
  MBEDTLS_ERR_SSL_ALLOC_FAILED, MBEDTLS_ERR_SSL_BAD_INPUT_DATA: cint
{.pop.}
var
  MBEDTLS_ERR_X509_CERT_VERIFY_FAILED {.importc, nodecl, header: "<mbedtls/x509.h>".}: cint
  MBEDTLS_ERR_NET_CONN_RESET {.importc, nodecl, header: "<mbedtls/net_sockets.h>".}: cint
  MBEDTLS_ERR_NET_SEND_FAILED {.importc, nodecl, header: "<mbedtls/net_sockets.h>".}: cint
  MBEDTLS_ERR_NET_RECV_FAILED {.importc, nodecl, header: "<mbedtls/net_sockets.h>".}: cint

# Preference lists, zero-terminated IANA ids, hardware-backed choices first.
const
  # secp256r1 (the PKA's curve), x25519, secp384r1.
  tlsGroups {.exportc: "bl808_tls_groups".}: array[4, uint16] =
    [0x0017'u16, 0x001D'u16, 0x0018'u16, 0'u16]
  # AEAD suites only. TLS 1.3: AES-128-GCM-SHA256, AES-256-GCM-SHA384,
  # ChaCha20-Poly1305. TLS 1.2: the same three with ECDHE-ECDSA and ECDHE-RSA.
  tlsSuites {.exportc: "bl808_tls_suites".}: array[10, cint] =
    [0x1301.cint, 0x1302, 0x1303, 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9, 0xCCA8, 0]

var
  trustAnchors: X509Crt
  trustAnchorCount: int

proc `=destroy`*(s: TlsSession) =
  if s.state != nil:
    mbedtls_ssl_free(addr s.state.ssl)
    mbedtls_ssl_config_free(addr s.state.conf)
    mbedtls_free(s.state)

proc `=copy`*(dest: var TlsSession; source: TlsSession) {.error:
  "a TlsSession owns its connection; pass it by var or move it".}

# =============================================================================
# Process-wide settings
# =============================================================================
proc tlsSetAllocator*(calloc: TlsCalloc; free: TlsFree): bool =
  ## Route every Mbed TLS allocation (sessions, handshakes, trust anchors)
  ## through `calloc`/`free`, e.g. a PSRAM pool. Call before the first
  ## `tlsOpen` or `tlsAddTrustAnchor`; memory must come back zeroed.
  calloc != nil and free != nil and mbedtls_platform_set_calloc_free(calloc, free) == 0

proc tlsAddTrustAnchor*(der: openArray[byte]): bool =
  ## Add one DER-encoded CA certificate for sessions opened with
  ## `verifyPeer = true`. Anchors are shared by all sessions and must not be
  ## changed while such a session is open.
  if der.len == 0: return false
  if psa_crypto_init() != 0: return false
  if trustAnchorCount == 0: mbedtls_x509_crt_init(addr trustAnchors)
  if mbedtls_x509_crt_parse_der(addr trustAnchors,
      cast[ConstBytes](unsafeAddr der[0]), der.len.csize_t) != 0:
    if trustAnchorCount == 0: mbedtls_x509_crt_free(addr trustAnchors)
    return false
  inc trustAnchorCount
  true

proc tlsClearTrustAnchors*() =
  if trustAnchorCount > 0:
    mbedtls_x509_crt_free(addr trustAnchors)
    trustAnchorCount = 0

# =============================================================================
# Transport glue
# =============================================================================
proc bioSend(ctx: pointer; buf: ConstBytes; len: csize_t): cint {.cdecl.} =
  let state = cast[ptr TlsState](ctx)
  let moved = state.io.send(state.io.ctx, cast[ptr UncheckedArray[byte]](buf), len.int)
  if moved > 0: return min(moved, len.int).cint
  if moved == 0: return MBEDTLS_ERR_SSL_WANT_WRITE
  state.ioFailed = true
  MBEDTLS_ERR_NET_CONN_RESET

proc bioRecv(ctx: pointer; buf: ptr uint8; len: csize_t): cint {.cdecl.} =
  let state = cast[ptr TlsState](ctx)
  let moved = state.io.recv(state.io.ctx, cast[ptr UncheckedArray[byte]](buf), len.int)
  if moved > 0: return min(moved, len.int).cint
  if moved == 0: return MBEDTLS_ERR_SSL_WANT_READ
  state.ioFailed = true
  MBEDTLS_ERR_NET_CONN_RESET

proc isIpLiteral(host: string): bool =
  ## SNI carries DNS names only (RFC 6066 section 3).
  if host.len == 0: return false
  result = true
  for c in host:
    if c == ':': return true
    if c notin {'0'..'9', '.'}: result = false

# =============================================================================
# Session lifecycle
# =============================================================================
proc release(s: var TlsSession) =
  `=destroy`(s)
  s.state = nil

proc tlsClose*(s: var TlsSession) =
  ## Send close_notify if the transport takes it right now, then free the
  ## session's memory. Safe to call in any state and more than once; call it
  ## after a failure too. The last error stays readable.
  if s.state != nil:
    if s.phase == phaseOpen and not s.state.ioFailed:
      discard mbedtls_ssl_close_notify(addr s.state.ssl)
    release(s)
  s.pendingWrite = 0
  s.phase = if s.phase == phaseFailed: phaseFailed else: phaseClosed

proc fail(s: var TlsSession; code: cint): TlsStatus =
  s.lastError = code.int32
  s.phase = phaseFailed
  tlsError

proc tlsOpen*(s: var TlsSession; io: TlsIo; hostname: string; verifyPeer = false): bool =
  ## Prepare a client session over `io`. `hostname` is sent as SNI (unless it
  ## is an IP literal) and, with `verifyPeer`, matched against the server
  ## certificate. Returns false when memory or configuration fails; see
  ## `tlsLastError`. Any previous session in `s` is closed first.
  tlsClose(s)
  s.lastError = 0
  s.phase = phaseFailed
  if io.send == nil or io.recv == nil:
    s.lastError = MBEDTLS_ERR_SSL_BAD_INPUT_DATA.int32
    return false
  let psaStatus = psa_crypto_init()   # idempotent: seeds the one shared RNG
  if psaStatus != 0:
    s.lastError = psaStatus
    return false
  s.state = cast[ptr TlsState](mbedtls_calloc(1, sizeof(TlsState).csize_t))
  if s.state == nil:
    s.lastError = MBEDTLS_ERR_SSL_ALLOC_FAILED.int32
    return false
  let state = s.state
  state.io = io
  mbedtls_ssl_init(addr state.ssl)
  mbedtls_ssl_config_init(addr state.conf)
  var rc = mbedtls_ssl_config_defaults(addr state.conf, MBEDTLS_SSL_IS_CLIENT,
    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT)
  if rc == 0:
    mbedtls_ssl_conf_rng(addr state.conf, mbedtls_psa_get_random, nil)
    mbedtls_ssl_conf_groups(addr state.conf, unsafeAddr tlsGroups[0])
    mbedtls_ssl_conf_ciphersuites(addr state.conf, unsafeAddr tlsSuites[0])
    if verifyPeer:
      mbedtls_ssl_conf_authmode(addr state.conf, MBEDTLS_SSL_VERIFY_REQUIRED)
      if trustAnchorCount > 0:
        mbedtls_ssl_conf_ca_chain(addr state.conf, addr trustAnchors, nil)
    else:
      mbedtls_ssl_conf_authmode(addr state.conf, MBEDTLS_SSL_VERIFY_NONE)
    rc = mbedtls_ssl_setup(addr state.ssl, addr state.conf)
  if rc == 0:
    # An explicit nil tells Mbed TLS the missing name is deliberate.
    rc = if hostname.len > 0 and (verifyPeer or not isIpLiteral(hostname)):
           mbedtls_ssl_set_hostname(addr state.ssl, hostname.cstring)
         else:
           mbedtls_ssl_set_hostname(addr state.ssl, nil)
  if rc != 0:
    release(s)
    s.lastError = rc.int32
    return false
  mbedtls_ssl_set_bio(addr state.ssl, state, bioSend, bioRecv, nil)
  s.phase = phaseHandshake
  true

# =============================================================================
# Handshake and data
# =============================================================================
proc tlsHandshakeStep*(s: var TlsSession): TlsStatus =
  ## Advance the handshake as far as the transport allows. Call again after
  ## `tlsWantRead` / `tlsWantWrite` until it returns `tlsOk`.
  case s.phase
  of phaseOpen: return tlsOk
  of phaseHandshake: discard
  of phaseClosed: return tlsClosed
  of phaseIdle, phaseFailed: return tlsError
  let rc = mbedtls_ssl_handshake(addr s.state.ssl)
  if rc == 0:
    s.phase = phaseOpen
    tlsOk
  elif rc == MBEDTLS_ERR_SSL_WANT_READ: tlsWantRead
  elif rc == MBEDTLS_ERR_SSL_WANT_WRITE: tlsWantWrite
  else: fail(s, rc)

proc tlsRead*(s: var TlsSession; buf: ptr UncheckedArray[byte]; cap: int;
              got: var int): TlsStatus =
  ## Read decrypted application data. `tlsOk` comes with `got > 0`;
  ## `tlsClosed` means the connection is over: the peer's close_notify, or
  ## the transport ending or failing underneath (a `recv` callback result
  ## below 0). `tlsPeerClosed` and `tlsErrorClass` tell the two apart:
  ## after close_notify the class is `tlsErrNone`, after a transport that
  ## ended or failed (a stream cut off, to be treated as lost) `tlsErrIo`.
  got = 0
  case s.phase
  of phaseOpen: discard
  of phaseClosed: return tlsClosed
  of phaseIdle, phaseHandshake, phaseFailed: return tlsError
  if buf == nil or cap <= 0: return tlsOk
  let rc = mbedtls_ssl_read(addr s.state.ssl, cast[ptr uint8](buf), cap.csize_t)
  if rc > 0:
    got = rc.int
    tlsOk
  elif rc == MBEDTLS_ERR_SSL_WANT_READ: tlsWantRead
  elif rc == MBEDTLS_ERR_SSL_WANT_WRITE: tlsWantWrite
  elif rc == 0 or rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY or
      rc == MBEDTLS_ERR_SSL_CONN_EOF or s.state.ioFailed:
    # A stream that just stops is how most radio servers end; record why.
    s.lastError = (if rc == 0: MBEDTLS_ERR_SSL_CONN_EOF else: rc).int32
    s.phase = phaseClosed
    tlsClosed
  else: fail(s, rc)

proc tlsWrite*(s: var TlsSession; buf: ptr UncheckedArray[byte]; len: int;
               put: var int): TlsStatus =
  ## Encrypt and send application data. `tlsOk` reports in `put` how much of
  ## `buf` was taken, which may be less than `len` (one record at a time).
  ## After `tlsWantWrite` / `tlsWantRead` nothing counts as taken yet: call
  ## again with the same data until `tlsOk`. `tlsClosed` here is always the
  ## transport ending or failing (`tlsErrIo`).
  put = 0
  case s.phase
  of phaseOpen: discard
  of phaseClosed: return tlsClosed
  of phaseIdle, phaseHandshake, phaseFailed: return tlsError
  if buf == nil or len <= 0: return tlsOk
  let limit = mbedtls_ssl_get_max_out_record_payload(addr s.state.ssl)
  if limit < 0: return fail(s, limit)
  let rc = mbedtls_ssl_write(addr s.state.ssl, cast[ConstBytes](buf), len.csize_t)
  if rc >= 0:
    # A record that had to wait for the transport is the one sent now.
    put = if s.pendingWrite > 0: min(s.pendingWrite, len) else: rc.int
    s.pendingWrite = 0
    tlsOk
  elif rc == MBEDTLS_ERR_SSL_WANT_WRITE or rc == MBEDTLS_ERR_SSL_WANT_READ:
    if s.pendingWrite == 0: s.pendingWrite = min(len, limit.int)
    if rc == MBEDTLS_ERR_SSL_WANT_WRITE: tlsWantWrite else: tlsWantRead
  elif s.state.ioFailed:
    s.lastError = rc.int32
    s.phase = phaseClosed
    tlsClosed
  else: fail(s, rc)

# =============================================================================
# Diagnostics
# =============================================================================
proc tlsLastError*(s: TlsSession): int32 =
  ## The raw Mbed TLS (negative) or PSA status of the last failure or close;
  ## 0 if none.
  s.lastError

proc tlsErrorClass*(s: TlsSession): TlsErrorClass =
  ## What the last error means to a user.
  let code = s.lastError.cint
  if code == 0: tlsErrNone
  elif code == MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE: tlsErrRefused
  elif code == MBEDTLS_ERR_NET_CONN_RESET or code == MBEDTLS_ERR_NET_SEND_FAILED or
      code == MBEDTLS_ERR_NET_RECV_FAILED or code == MBEDTLS_ERR_SSL_CONN_EOF: tlsErrIo
  elif code == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY:
    # An orderly end of an open session; in a handshake the peer went away.
    if s.phase == phaseClosed: tlsErrNone else: tlsErrIo
  elif code == MBEDTLS_ERR_SSL_BUFFER_TOO_SMALL or
      (code == MBEDTLS_ERR_SSL_INVALID_RECORD and MBEDTLS_SSL_IN_CONTENT_LEN < 16384):
    # With the default full-size input buffer only the first can happen.
    tlsErrRecordTooBig
  elif code == MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE or
      code == MBEDTLS_ERR_SSL_BAD_PROTOCOL_VERSION or
      code == MBEDTLS_ERR_SSL_ILLEGAL_PARAMETER or
      code == MBEDTLS_ERR_SSL_UNSUPPORTED_EXTENSION or
      code == MBEDTLS_ERR_SSL_FEATURE_UNAVAILABLE or
      code == MBEDTLS_ERR_SSL_BAD_CERTIFICATE or
      code == MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED or
      code == MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE or
      code == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED: tlsErrHandshake
  else: tlsErrOther

proc tlsPeerClosed*(s: TlsSession): bool =
  ## True once the peer ended an open session with close_notify: everything
  ## it sent has been read. False after `tlsClosed` means the transport ended
  ## or failed without one, so the stream may have been cut short.
  s.phase == phaseClosed and s.lastError == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY.int32

proc tlsBuffered*(s: TlsSession): tuple[decoded, pending: int] =
  ## For diagnostics, at any time before `tlsClose` (so also right after a
  ## read that returned `tlsClosed` or `tlsError`): application bytes already
  ## decrypted that `tlsRead` has not handed out, and bytes of the record
  ## being received that have arrived so far. Two field reads; both 0 once
  ## the session's memory is released.
  if s.state == nil: return (0, 0)
  (mbedtls_ssl_get_bytes_avail(addr s.state.ssl).int, s.state.ssl.inLeft.int)

proc tlsIsOpen*(s: TlsSession): bool =
  ## True between a finished handshake and the close or failure.
  s.phase == phaseOpen

proc tlsVersion*(s: TlsSession): cstring =
  ## "TLSv1.3" or "TLSv1.2" once negotiated ("unknown" before); "" when the
  ## session is not open.
  if s.state == nil: "" else: mbedtls_ssl_get_version(addr s.state.ssl)

proc tlsCipherSuite*(s: TlsSession): cstring =
  ## The negotiated suite's IANA name, or "".
  if s.state == nil: return ""
  result = mbedtls_ssl_get_ciphersuite(addr s.state.ssl)
  if result == nil: result = ""
