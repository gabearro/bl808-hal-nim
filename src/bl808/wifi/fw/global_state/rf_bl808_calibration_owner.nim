type ManagedRfCalibration = enum
  rfCalUntracked, rfCalBl808Wlan, rfCalLegacyFull

var
  managedRfCalibration: ManagedRfCalibration
  bl808WlanCalibrationInProgress: bool

proc isManagedRfCalibrationBank(): bool {.inline.} =
  rfCalibDataGlobal == cast[pointer](addr wifiBl808WlRmem.calib[0])

proc rfBankHasBl808WlanCal(): bool {.inline.} =
  isManagedRfCalibrationBank() and managedRfCalibration == rfCalBl808Wlan

proc rfBankUsesBl808LoCal(): bool {.inline.} =
  isManagedRfCalibrationBank() and
    (bl808WlanCalibrationInProgress or managedRfCalibration == rfCalBl808Wlan)

proc selectBl808WlanCalibration(cold: bool; mode: RadioPhyMode; xtal40: bool): bool =
  isManagedRfCalibrationBank() and mode == wifiOnly and xtal40 and
    (cold or managedRfCalibration != rfCalLegacyFull)

proc beginManagedRfCalibration(format: ManagedRfCalibration) =
  # A warm rebind does not invalidate a completed bank. Only a format switch
  # discards the old records, before any legacy initializer can replay them.
  if managedRfCalibration != rfCalUntracked and managedRfCalibration != format:
    zeroMem(addr wifiBl808WlRmem.calib[0], sizeof(wifiBl808WlRmem.calib))
  managedRfCalibration = rfCalUntracked
