## Native BL808 rf_pri.o gain rows and rf_pri_gain_table_WR2REG.
## Uses the containing RF module's rfTxPowerCompTableRegs and volatile MMIO.

type Bl808TxGainRow = array[7, int16]

# RF calibration reads these before NimMain. Keep literal initializers so
# the writable rows and selectors are present in the loadable data section.
var
  bl808TxGainRows: array[17, Bl808TxGainRow] = [
    [0'i16, 0, 0, 0, 0, 0, 0],
    [0'i16, 0, 0, 0, 0, 0, 0],
    [0'i16, 0, 0, 0, 0, 0, 0],
    [0'i16, 0, 0, 0, 0, 0, 0],
    [0'i16, 1, 7, 26, 0, -8, 200],
    [0'i16, 1, 7, 22, 0, -8, 190],
    [0'i16, 1, 7, 17, 0, -4, 180],
    [0'i16, 1, 7, 17, 0, -8, 170],
    [0'i16, 1, 7, 12, 0, -2, 160],
    [0'i16, 1, 7, 12, 0, -6, 150],
    [0'i16, 1, 7,  9, 0, -2, 140],
    [0'i16, 1, 7,  9, 0, -6, 130],
    [0'i16, 1, 7,  7, 0, -2, 120],
    [0'i16, 1, 7,  7, 0, -6, 110],
    [0'i16, 1, 6,  7, 0, -6, 100],
    [0'i16, 0, 0, 0, 0, 0, 0],
    [0'i16, 0, 0, 0, 0, 0, 0]]
  bl808TxGainIndices: array[8, int16] = [4'i16, 5, 6, 7, 8, 9, 10, 14]

proc bl808TxGainRow(slot: int): Bl808TxGainRow {.inline.} =
  bl808TxGainRows[bl808TxGainIndices[slot].int]

proc bl808TxGainDb(slot: int): int32 =
  bl808TxGainRow(slot)[6].int32 div 10

proc programBl808TxGainTable() =
  let table = rfTxPowerCompTableRegs()
  for header in countdown(1, 0):
    let reg = addr table.txPowerCompWords700[header]
    var word = volatileLoad(reg)
    for field in countdown(3, 0):
      let shift = 6 * field
      let gain = bl808TxGainDb(4 * header + field)
      word = (word and not (0x3F'u32 shl shift)) or (cast[uint32](gain) shl shift)
    volatileStore(reg, word)

  for slot in countdown(7, 0):
    let row = bl808TxGainRow(slot)
    let reg = addr table.txPowerCompWords700[2 + 2 * slot]
    var word = volatileLoad(reg)
    # LH sign-extends before each shift. Clear the destination, not the input:
    # a negative column 5 sets bits 31:30 even after the remaining fields.
    template put(column, shift: int; mask: uint32) =
      word = (word and not (mask shl shift)) or
             (cast[uint32](row[column].int32) shl shift)
    put(5, 11, 0x7F'u32)
    put(3, 21, 0x1F'u32)
    put(2, 18, 0x07'u32)
    put(1, 28, 0x03'u32)
    put(0, 26, 0x03'u32)
    volatileStore(reg, word)
