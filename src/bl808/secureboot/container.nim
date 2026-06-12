## NSB1 ("Nim Secure Boot v1") image container — pure parsing/layout, no I/O
## and no hardware deps, so it compiles and tests identically on host and
## device. The crypto (SHA-256 of payload, ECDSA over the header) lives in
## verify.nim; this module only describes and validates the fixed layout.
##
## Fixed 256-byte header, little-endian. The signed region is bytes [0, 160).
##
##   off  size  field
##   0    4     magic "NSB1"
##   4    2     header version (=1)
##   6    2     image type (1=m0app 2=d0 3=lp 4=enclave)
##   8    4     payload length
##   12   4     load address (0 = XIP in place)
##   16   4     entry address
##   20   4     security version (rollback)
##   24   4     flags (bit0 = payload AES-CTR encrypted)
##   28   4     pubkey id (first 4 bytes of SHA-256(pubkey X||Y))
##   32   32    SHA-256 of plaintext payload
##   64   16    AES-CTR nonce (zero if unencrypted)
##   80   80    reserved (zero)
##   160  64    ECDSA-P256 signature r||s over SHA-256(header[0..159])
##   224  32    pad

const
  Nsb1HeaderSize* = 256
  Nsb1SignedLen*  = 160          ## bytes covered by the signature
  Nsb1Magic*      = ['N'.byte, 'S'.byte, 'B'.byte, '1'.byte]

  # field offsets
  OffMagic*      = 0
  OffHdrVer*     = 4
  OffImgType*    = 6
  OffPayloadLen* = 8
  OffLoadAddr*   = 12
  OffEntry*      = 16
  OffSecVer*     = 20
  OffFlags*      = 24
  OffPubkeyId*   = 28
  OffPayloadHash* = 32
  OffNonce*      = 64
  OffReserved*   = 80
  OffSignature*  = 160
  OffPad*        = 224

  FlagEncrypted* = 0x1'u32

type
  Nsb1ImageType* = enum
    nsbM0App = 1, nsbD0 = 2, nsbLp = 3, nsbEnclave = 4

  Nsb1Header* = object
    hdrVersion*: uint16
    imageType*: uint16
    payloadLen*: uint32
    loadAddr*: uint32
    entry*: uint32
    secVersion*: uint32
    flags*: uint32
    pubkeyId*: uint32
    payloadHash*: array[32, uint8]
    nonce*: array[16, uint8]
    signature*: array[64, uint8]

  Nsb1Error* = enum
    nsbOk, nsbBadMagic, nsbBadVersion, nsbBadLength, nsbBadType

proc rd16(b: openArray[uint8], o: int): uint16 {.inline.} =
  b[o].uint16 or (b[o+1].uint16 shl 8)
proc rd32(b: openArray[uint8], o: int): uint32 {.inline.} =
  b[o].uint32 or (b[o+1].uint32 shl 8) or (b[o+2].uint32 shl 16) or (b[o+3].uint32 shl 24)

proc parseNsb1*(raw: openArray[uint8], hdr: var Nsb1Header): Nsb1Error =
  ## Validate magic/version/structure and fill `hdr`. Does NOT verify crypto.
  if raw.len < Nsb1HeaderSize: return nsbBadLength
  for i in 0 ..< 4:
    if raw[OffMagic + i] != Nsb1Magic[i]: return nsbBadMagic
  hdr.hdrVersion = rd16(raw, OffHdrVer)
  if hdr.hdrVersion != 1: return nsbBadVersion
  hdr.imageType = rd16(raw, OffImgType)
  if hdr.imageType < 1 or hdr.imageType > 4: return nsbBadType
  hdr.payloadLen = rd32(raw, OffPayloadLen)
  hdr.loadAddr = rd32(raw, OffLoadAddr)
  hdr.entry = rd32(raw, OffEntry)
  hdr.secVersion = rd32(raw, OffSecVer)
  hdr.flags = rd32(raw, OffFlags)
  hdr.pubkeyId = rd32(raw, OffPubkeyId)
  for i in 0 ..< 32: hdr.payloadHash[i] = raw[OffPayloadHash + i]
  for i in 0 ..< 16: hdr.nonce[i] = raw[OffNonce + i]
  for i in 0 ..< 64: hdr.signature[i] = raw[OffSignature + i]
  nsbOk

proc isEncrypted*(hdr: Nsb1Header): bool {.inline.} =
  (hdr.flags and FlagEncrypted) != 0
