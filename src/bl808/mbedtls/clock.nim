## Mbed TLS's clocks: the wall clock certificate validity is checked against
## (MBEDTLS_HAVE_TIME_DATE), and the millisecond counter TLS takes intervals
## from.
##
## A bare-metal image has no wall clock until something sets one (an RTC, NTP):
## give it to `mbedTlsSetClock`. Until then the time is the Unix epoch, which
## is before every certificate's validity begins, so a session that verifies
## its peer fails instead of accepting a certificate it cannot date. Sessions
## that do not verify are not affected.

import build

when defined(bl808m0):
  import ../kernel/clock
else:
  import std/[times, monotimes]

type
  MbedTlsClock* = proc(): int64 {.nimcall.}
    ## Seconds since 1970-01-01 UTC, or 0 (or less) while the time is unknown.
  TimeT {.importc: "mbedtls_time_t", header: "<mbedtls/platform_time.h>".} = clonglong
  Tm {.importc: "struct tm", header: "<time.h>".} = object
    tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst: cint

var wallClock: MbedTlsClock

proc mbedTlsSetClock*(now: MbedTlsClock) =
  ## The wall clock for certificate validity; `nil` takes it away again.
  wallClock = now

proc mbedTlsNow*(): int64 =
  ## What Mbed TLS takes the time to be: 0 while unknown.
  if wallClock != nil:
    result = max(wallClock(), 0)
  else:
    when defined(bl808m0): result = 0
    else: result = getTime().toUnix      # a host has a clock of its own

proc mbedtlsTime(timer: ptr TimeT): TimeT {.exportc: "bl808_mbedtls_time", cdecl.} =
  result = TimeT(mbedTlsNow())
  if timer != nil: timer[] = result

proc mbedtlsMsTime(): int64 {.exportc: "mbedtls_ms_time", cdecl.} =
  ## Monotonic milliseconds from an arbitrary start.
  when defined(bl808m0): int64(ticksToUs(readTick()) div 1000)
  else: getMonoTime().ticks div 1_000_000

proc mbedtlsGmtime(tt: ptr TimeT; tm: ptr Tm): ptr Tm
    {.exportc: "mbedtls_platform_gmtime_r", cdecl.} =
  ## Seconds since the epoch as a UTC calendar date (the proleptic Gregorian
  ## calendar; "days from civil" run backwards).
  if tt == nil or tm == nil: return nil
  let t = int64(tt[])
  var days = t div 86_400
  var rem = t mod 86_400
  if rem < 0:
    rem += 86_400
    dec days
  tm.tm_hour = cint(rem div 3600)
  tm.tm_min = cint(rem mod 3600 div 60)
  tm.tm_sec = cint(rem mod 60)
  tm.tm_wday = cint(((days mod 7) + 11) mod 7)        # 1970-01-01 was a Thursday
  let z = days + 719_468
  let era = (if z >= 0: z else: z - 146_096) div 146_097
  let doe = z - era * 146_097                           # day of the 400-year era
  let yoe = (doe - doe div 1460 + doe div 36_524 - doe div 146_096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100) # day of the year from 1 March
  let mp = (5 * doy + 2) div 153
  let month = if mp < 10: mp + 3 else: mp - 9          # 1..12
  let year = yoe + era * 400 + (if month <= 2: 1 else: 0)
  tm.tm_mday = cint(doy - (153 * mp + 2) div 5 + 1)
  tm.tm_mon = cint(month - 1)
  tm.tm_year = cint(year - 1900)
  let leap = (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0
  const before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  tm.tm_yday = cint(before[month - 1] + tm.tm_mday - 1 + (if leap and month > 2: 1 else: 0))
  tm.tm_isdst = 0
  tm
