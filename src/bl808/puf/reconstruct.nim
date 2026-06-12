## Device-side SRAM-PUF root reconstruction.
##
## Reads the pristine OCRAM PUF window (the BootROM provably never touches
## OCRAM), majority-vote decodes via the public helper data, then HKDFs the
## recovered bits into a 32-byte vault root. Must run at cold boot, BEFORE the
## OCRAM bss for that window is initialised — the secure stage calls this first
## and the linker marks the window NOLOAD.
##
## Cold-boot only: on warm/HBN wake the SRAM is already initialised and invalid;
## the secure stage detects warm boot and reuses the cached root instead.

import helper
import ../memmap
import ../enclave/sha256
import ../enclave/vault

const
  PufWindowAddr* = OcramBase          # 0x2202_0000, confirmed BootROM-avoided
  PufWindowLen*  = 4096               # 4 KB sub-window (>= 256*r stable bits)
  # Warm-boot root cache: OCRAM outside the PUF window. Lost on a cold power
  # cycle (-> reconstruct), retained across a warm SWRST (-> reuse, since after
  # the first boot the SRAM PUF source is no longer pristine).
  PufRootCacheAddr* = OcramBase + 0x8000'u   # 0x2202_8000
  PufRootCacheMagic = 0x50554652'u32         # "PUFR"

const PufInfo = ['b'.byte, 'l'.byte, '8'.byte, '0'.byte, '8'.byte, '-'.byte,
                'p'.byte, 'u'.byte, 'f'.byte, '-'.byte, 'r'.byte, 'o'.byte,
                'o'.byte, 't'.byte]

proc reconstructRoot*(windowAddr: uint, helperData: PufHelper,
                      root: var array[32, uint8]) =
  ## Recover the 32-byte device root from the raw SRAM window + helper data.
  let win = cast[ptr UncheckedArray[uint8]](windowAddr)
  var bits: array[PufKeyBits, uint8]
  reconstructBits(toOpenArray(win, 0, PufWindowLen - 1), helperData, bits)
  var packed: array[32, uint8]
  packBits(bits, packed)
  # HKDF mixes the (public-helper-exposed) raw bits into a uniform root, salted
  # by a hash of the helper indices so distinct enrollments yield distinct roots.
  var salt: Sha256Ctx
  sha256Init(salt)
  for i in 0 ..< (PufKeyBits * helperData.r):
    let idx = helperData.indices[i]
    sha256Update(salt, [ (idx and 0xFF).uint8, ((idx shr 8) and 0xFF).uint8 ])
  let saltDigest = sha256Final(salt)
  var okm: array[32, uint8]
  hkdf(saltDigest, packed, PufInfo, 32, okm)
  for i in 0 ..< 32: root[i] = okm[i]

proc vaultInitPufRoot*(helperData: PufHelper, windowAddr: uint,
                       rootSha: var array[32, uint8], warmBoot: var bool): bool =
  ## Make the SRAM-PUF-derived device root THE enclave vault root.
  ##   cold boot: reconstruct from the pristine PUF window, cache the root, install it;
  ##   warm boot: the cache magic is present, so reuse the cached root (the PUF
  ##              source is no longer pristine after the first boot).
  ## Returns SHA-256(root) (one-way, safe to surface) so a test can confirm the
  ## installed root is identical across cold boots and across a warm reset.
  let magicP = cast[ptr uint32](PufRootCacheAddr)
  let rootP  = cast[ptr array[32, uint8]](PufRootCacheAddr + 4)
  var root: array[32, uint8]
  warmBoot = magicP[] == PufRootCacheMagic
  if warmBoot:
    root = rootP[]
  else:
    reconstructRoot(windowAddr, helperData, root)
    rootP[] = root
    magicP[] = PufRootCacheMagic
  rootSha = sha256(root)
  result = vaultInstallPufRoot(root) != InvalidHandle
  for i in 0 ..< 32: root[i] = 0       # wipe the stack copy
