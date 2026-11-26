## Wall-clock time (the pure part of upstream `src/clock.rs`): the last NTP
## sync, the local HH:MM shown in the status bar, EU/UK daylight saving, and
## the NTP packet format. The NTP task (controls package) does the network
## side and calls `setSynced`.
##
## Nothing is shown until the first sync. The time shown is UTC plus the
## chosen offset, plus one hour while DST is enabled and in effect (from
## 01:00 UTC on the last Sunday of March to 01:00 UTC on the last Sunday of
## October).

import ./timebase, ./prefs

const
  NtpServer* = "pool.ntp.org"
  NtpPort* = 123
  NtpPacketLen* = 48
  ResyncMs* = 3_600_000
  RetryMs* = 15_000       ## while no time has been obtained yet
  QueryTimeoutMs* = 2_000
  NtpToUnix = 2_208_988_800'u64

var
  synced: bool
  syncUnix: uint64
  syncAtMs: uint64

func floorDiv(a, b: int64): int64 =
  result = a div b
  if (a mod b != 0) and ((a < 0) != (b < 0)): dec result

func floorMod(a, b: int64): int64 = a - floorDiv(a, b) * b

func daysFromCivil*(year, m, d: int64): int64 =
  ## Days since 1970-01-01 of a proleptic Gregorian date (Hinnant).
  let y = if m <= 2: year - 1 else: year
  let era = floorDiv(y, 400)
  let yoe = y - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146_097 + doe - 719_468

func yearOfDays*(days: int64): int64 =
  ## The year containing day number `days` (days since 1970-01-01).
  let z = days + 719_468
  let era = floorDiv(z, 146_097)
  let doe = z - era * 146_097
  let yoe = (doe - doe div 1460 + doe div 36_524 - doe div 146_096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let m = if mp < 10: mp + 3 else: mp - 9
  yoe + era * 400 + (if m <= 2: 1 else: 0)

func lastSunday(y, m: int64): int64 =
  ## The last Sunday of a 31-day month, as a day number.
  let last = daysFromCivil(y, m, 31)
  last - floorMod(last + 4, 7)     # 1970-01-01 was a Thursday

func euDst*(unix: int64): bool =
  ## Whether EU/UK summer time is in effect at this UTC time.
  let y = yearOfDays(floorDiv(unix, 86_400))
  let first = lastSunday(y, 3) * 86_400 + 3600
  let last = lastSunday(y, 10) * 86_400 + 3600
  unix >= first and unix < last

func localHourMinute*(utc: int64; offsetQh: int; dst: bool): (uint8, uint8) =
  let shifted = utc + offsetQh.int64 * 900 + (if dst and euDst(utc): 3600 else: 0)
  let daySecs = floorMod(shifted, 86_400)
  ((daySecs div 3600).uint8, (daySecs div 60 mod 60).uint8)

proc setSynced*(unix: uint64; atMs: uint64) =
  ## Record a successful NTP answer: Unix seconds valid at `atMs`.
  syncUnix = unix
  syncAtMs = atMs
  synced = true

proc isSynced*(): bool {.inline.} = synced

proc hourMinute*(hm: var (uint8, uint8)): bool =
  ## The local time; false until NTP has succeeded.
  if not synced: return false
  let utc = syncUnix.int64 + int64(elapsedMs(syncAtMs, nowMs()) div 1000)
  hm = localHourMinute(utc, offsetQh(), dstEnabled())
  true

func ntpRequest*(): array[NtpPacketLen, byte] =
  ## LI 0, version 4, mode 3 (client); the rest zero.
  result[0] = 0x23

func ntpParse*(resp: openArray[byte]; unix: var uint64): bool =
  ## Accepts a mode 4 (server) answer of stratum 1..15 with a transmit time.
  if resp.len < NtpPacketLen or (resp[0] and 7) != 4 or resp[1] == 0 or resp[1] > 15:
    return false
  var secs = (resp[40].uint64 shl 24) or (resp[41].uint64 shl 16) or
             (resp[42].uint64 shl 8) or resp[43].uint64
  if secs == 0: return false
  if secs < NtpToUnix:        # the 32-bit field wraps in 2036: era 1
    secs += 1'u64 shl 32
  unix = secs - NtpToUnix
  true

proc wallclockInit*() =
  synced = false
