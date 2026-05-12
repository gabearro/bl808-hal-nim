## Wall-clock time for the BL808 kernel.
##
## Uses the monotonic tick counter (CLIC mtime) with a user-set epoch
## offset. Call `rtcSetTime` at boot (e.g., from NTP or stored value).
##
##   rtcSetTime(DateTime(year: 2026, month: 3, day: 31,
##                        hour: 12, minute: 0, second: 0))
##   let now = rtcGetTime()
##   let unix = rtcGetUnix()

import ./clock

# =============================================================================
# Types
# =============================================================================

type
  DateTime* = object
    year*: uint16    ## 1970-2099
    month*: uint8    ## 1-12
    day*: uint8      ## 1-31
    hour*: uint8     ## 0-23
    minute*: uint8   ## 0-59
    second*: uint8   ## 0-59

# =============================================================================
# Calendar conversions
# =============================================================================

const
  DaysPerMonth = [0'i32, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  SecsPerDay = 86400'i64
  SecsPerHour = 3600'i64
  SecsPerMin = 60'i64

proc isLeapYear(y: int): bool {.inline.} =
  (y mod 4 == 0) and ((y mod 100 != 0) or (y mod 400 == 0))

proc daysInMonth(y: int, m: int): int {.inline.} =
  if m == 2 and isLeapYear(y): 29
  else: DaysPerMonth[m]

proc dateTimeToUnix*(dt: DateTime): int64 =
  ## Convert DateTime to Unix timestamp (seconds since 1970-01-01 00:00 UTC).
  var days: int64 = 0
  # Count complete years
  for y in 1970 ..< dt.year.int:
    days += (if isLeapYear(y): 366 else: 365)
  # Count complete months in current year
  for m in 1 ..< dt.month.int:
    days += daysInMonth(dt.year.int, m)
  # Add days in current month (1-based, so subtract 1)
  days += dt.day.int64 - 1
  # Convert to seconds and add time-of-day
  days * SecsPerDay +
    dt.hour.int64 * SecsPerHour +
    dt.minute.int64 * SecsPerMin +
    dt.second.int64

proc unixToDateTime*(ts: int64): DateTime =
  ## Convert Unix timestamp to DateTime.
  var remaining = ts
  # Extract time of day
  let daysSinceEpoch = remaining div SecsPerDay
  remaining = remaining mod SecsPerDay
  if remaining < 0:
    remaining += SecsPerDay
  result.hour = (remaining div SecsPerHour).uint8
  remaining = remaining mod SecsPerHour
  result.minute = (remaining div SecsPerMin).uint8
  result.second = (remaining mod SecsPerMin).uint8
  # Extract year
  var days = daysSinceEpoch
  var year = 1970
  while true:
    let diy = if isLeapYear(year): 366'i64 else: 365'i64
    if days < diy: break
    days -= diy
    year.inc
  result.year = year.uint16
  # Extract month
  var month = 1
  while month <= 12:
    let dim = daysInMonth(year, month).int64
    if days < dim: break
    days -= dim
    month.inc
  result.month = month.uint8
  result.day = (days + 1).uint8  # 1-based

# =============================================================================
# RTC state — epoch offset
# =============================================================================

var epochOffset: int64 = 0  ## Unix timestamp when tick counter was 0

proc rtcSetTime*(dt: DateTime) =
  ## Set the wall clock. Computes epoch offset from current monotonic ticks.
  let unixNow = dateTimeToUnix(dt)
  let bootSecs = (ticksToMs(readTick()) div 1000).int64
  epochOffset = unixNow - bootSecs

proc rtcSetUnix*(ts: int64) =
  ## Set the wall clock from a Unix timestamp.
  let bootSecs = (ticksToMs(readTick()) div 1000).int64
  epochOffset = ts - bootSecs

proc rtcGetUnix*(): int64 =
  ## Current Unix timestamp (seconds since 1970-01-01 00:00 UTC).
  let bootSecs = (ticksToMs(readTick()) div 1000).int64
  epochOffset + bootSecs

proc rtcGetTime*(): DateTime =
  ## Current wall-clock time.
  unixToDateTime(rtcGetUnix())

# =============================================================================
# FatFs integration — called by ff.c when FF_FS_NORTC=0
# =============================================================================

proc get_fattime*(): uint32 {.exportc, cdecl.} =
  ## Return packed FAT timestamp for FatFs.
  ## Format: year-1980[31:25] month[24:21] day[20:16]
  ##         hour[15:11] minute[10:5] second/2[4:0]
  let dt = rtcGetTime()
  let y = if dt.year >= 1980: dt.year.uint32 - 1980 else: 0'u32
  (y shl 25) or
    (dt.month.uint32 shl 21) or (dt.day.uint32 shl 16) or
    (dt.hour.uint32 shl 11) or (dt.minute.uint32 shl 5) or
    (dt.second.uint32 div 2)
