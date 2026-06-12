## SF_CTRL on-the-fly XIP flash AES decryption (OTFAD).
##
## The serial-flash controller can transparently decrypt encrypted code/data
## as the CPU executes-in-place from flash. Three independent regions each
## carry a 256-bit key, a 128-bit IV, and a [start,end) flash range, with an
## option to source the key from an eFuse slot the CPU never reads.
##
## DANGER: these registers govern *live* XIP. Reconfiguring the region the
## running M0 image executes from will fault or hang the core. The enclave must
## only program regions that cover not-currently-executing flash.
##
## Offsets verified against the vendored sf_ctrl_reg.h / bl808_sf_ctrl.c.

import mmio, memmap

const
  SfAesCfg*       = SfCtrlBase + 0x28'u   # global AES enable/mode

  # SF_AES config fields
  SfAesEn*        = 0          # global enable
  SfAesModeShift* = 1          # [2:1] key type: 0=128, 1=256, 2=192
  SfAesModeMask*  = 0x3'u32 shl SfAesModeShift
  SfAesBlkMode*   = 3          # 0 = CTR, 1 = XTS
  SfAesKeyEndian* = 22
  SfAesIvEndian*  = 23

  # Per-region bank: base 0x200 + region*0x80
  SfAesRegionStride* = 0x80'u
  SfAesKeyOff*    = 0x00'u     # 8 key words
  SfAesIvOff*     = 0x20'u     # 4 IV words
  SfAesStartOff*  = 0x30'u     # start[18:0], hwkey@29, en@30, lock@31
  SfAesEndOff*    = 0x34'u     # end[18:0]

  SfAesStartMask* = 0x7FFFF'u32
  SfAesHwKeyEn*   = 29
  SfAesRegionEn*  = 30
  SfAesRegionLock* = 31

type
  SfAesMode* = enum
    sfAes128 = 0, sfAes256 = 1, sfAes192 = 2

  SfAesBlock* = enum
    sfAesCtr = 0, sfAesXts = 1

  SfAesRegionCfg* = object
    region*: range[0..2]
    startAddr*, endAddr*: uint32   ## byte addresses; encoded as addr/1024
    hwKey*: bool                   ## source key from eFuse slot
    enable*: bool
    lock*: bool

proc sfAesRegionBase(region: int): uint {.inline.} =
  SfCtrlBase + 0x200'u + region.uint * SfAesRegionStride

proc sfAesSetKey*(region: int, key: openArray[uint32]) =
  ## Load up to 8 key words (256-bit) for a region. Endianness is governed by
  ## SF_AES_KEY_ENDIAN; callers must match the producer's byte order.
  let base = sfAesRegionBase(region) + SfAesKeyOff
  for i in 0 ..< min(key.len, 8):
    regWrite(base + i.uint * 4, key[i])

proc sfAesSetIv*(region: int, iv: array[4, uint32]) =
  let base = sfAesRegionBase(region) + SfAesIvOff
  for i in 0 ..< 4:
    regWrite(base + i.uint * 4, iv[i])

proc sfAesSetRegion*(cfg: SfAesRegionCfg) =
  ## Program a region's range and flags. Writes END first, then START with the
  ## enable/lock/hw-key bits, matching the vendor sequence. 1 KB granularity.
  let base = sfAesRegionBase(cfg.region)
  regWrite(base + SfAesEndOff, (cfg.endAddr div 1024) and SfAesStartMask)
  var start = (cfg.startAddr div 1024) and SfAesStartMask
  if cfg.hwKey:  start = start or (1'u32 shl SfAesHwKeyEn)
  if cfg.enable: start = start or (1'u32 shl SfAesRegionEn)
  if cfg.lock:   start = start or (1'u32 shl SfAesRegionLock)
  regWrite(base + SfAesStartOff, start)

proc sfAesRegionLocked*(region: int): bool =
  (regRead(sfAesRegionBase(region) + SfAesStartOff) and
   (1'u32 shl SfAesRegionLock)) != 0

proc sfAesSetMode*(mode: SfAesMode, blk: SfAesBlock) =
  ## Select key size and block mode (CTR or XTS) without enabling yet.
  var v = regRead(SfAesCfg)
  v = (v and not SfAesModeMask) or (mode.uint32 shl SfAesModeShift)
  if blk == sfAesXts: v = v or (1'u32 shl SfAesBlkMode)
  else:               v = v and not (1'u32 shl SfAesBlkMode)
  regWrite(SfAesCfg, v)

proc sfAesEnable*(enable: bool) =
  ## Globally enable/disable on-the-fly flash AES decryption.
  if enable: regSet(SfAesCfg, 1'u32 shl SfAesEn)
  else:      regClear(SfAesCfg, 1'u32 shl SfAesEn)

proc sfAesEnabled*(): bool {.inline.} =
  (regRead(SfAesCfg) and (1'u32 shl SfAesEn)) != 0
