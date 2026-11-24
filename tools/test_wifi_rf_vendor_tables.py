"""Compare RF power and TXCAL parameter tables with the pinned BL808 archive."""

import json
import re
import shutil
import struct
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
RF_SOURCE = ROOT / "src/bl808/wifi/fw/global_state/rf_bl808_core.nim"
RF_ARCHIVE = ROOT / "src/bl808/librf_bl808.a"


def nim_table(name: str, signed: bool) -> list[int]:
    source = RF_SOURCE.read_text()
    match = re.search(
        rf"(?ms)^  {re.escape(name)}: array\[[^\n]+ = \[\n(.*?)^  \]",
        source,
    )
    assert match is not None, f"missing Nim table {name}"
    suffix = "i16" if signed else "u32"
    rows = re.findall(r"^    \[([^\[\]]+)\],?$", match.group(1), re.MULTILINE)
    assert rows, f"missing rows in {name}"
    values = []
    for row in rows:
        literals = re.findall(rf"(-?(?:0x[0-9A-Fa-f]+|\d+))'{suffix}\b", row)
        assert len(literals) == (9 if signed else 7), name
        values.extend(int(literal, 0) for literal in literals)
    return values


def nim_channel_table(name: str, suffix: str, count: int) -> list[int]:
    source = RF_SOURCE.read_text()
    match = re.search(
        rf"(?ms)^  {re.escape(name)}: array\[[^\n]+ = \[\n(.*?)^  \]",
        source,
    )
    assert match is not None, f"missing Nim table {name}"
    values = [
        int(value, 0) for value in re.findall(
            rf"\b(0x[0-9A-Fa-f]+|\d+)'{suffix}\b", match.group(1)
        )
    ]
    assert len(values) == count, name
    return values


def nim_flat_table(name: str, suffix: str | None, count: int) -> list[int]:
    source = RF_SOURCE.read_text()
    match = re.search(
        rf"(?ms)^  {re.escape(name)}: array\[[^\n]+? = \[(.*?)\]",
        source,
    )
    assert match is not None, f"missing Nim table {name}"
    body = "\n".join(line.split("#", 1)[0] for line in match.group(1).splitlines())
    literal = r"-?(?:0x[0-9A-Fa-f]+|\d+)"
    pattern = rf"({literal})'{suffix}\b" if suffix else rf"\b({literal})\b"
    values = [int(value, 0) for value in re.findall(pattern, body)]
    assert len(values) == count, name
    return values


def nim_exported_array(name: str, suffix: str, count: int) -> list[int]:
    source = RF_SOURCE.read_text()
    match = re.search(
        rf"(?s)^var {re.escape(name)}\* .*?: array\[{count}, [^\]]+\] = \[(.*?)\]",
        source,
        re.MULTILINE,
    )
    assert match is not None, f"missing Nim array {name}"
    values = [
        int(value, 0) for value in re.findall(
            rf"\b(0x[0-9A-Fa-f]+|\d+)'{suffix}\b", match.group(1)
        )
    ]
    assert len(values) == count, name
    return values


def vendor_table(tmp_path: Path, symbol: str, format_char: str, count: int,
                 object_name: str = "rf_pri.c.o") -> list[int]:
    ar = shutil.which("llvm-ar")
    r2 = shutil.which("r2")
    if ar is None or r2 is None:
        pytest.skip("llvm-ar and radare2 are required for vendor-table comparison")
    subprocess.run([ar, "x", str(RF_ARCHIVE), object_name], cwd=tmp_path, check=True)
    width = struct.calcsize("<" + format_char)
    output = subprocess.check_output(
        [r2, "-q", "-c", f"pxj {count * width} @ obj.{symbol}",
         str(tmp_path / object_name)],
        text=True,
    )
    return list(struct.unpack("<" + format_char * count, bytes(json.loads(output))))


@pytest.mark.parametrize(
    "nim_name,vendor_name,rows,columns,signed",
    [
        ("RfPriTxPowerTableDefault", "tx_pwr_table", 18, 9, True),
        ("RfPriBzTxPowerTableDefault", "bz_tx_pwr_table", 9, 9, True),
        ("RfPriTxcalParams", "txcal_para", 18, 7, False),
        ("RfPriBzTxcalParams", "bz_txcal_para", 9, 7, False),
    ],
)
def test_rf_tables_match_vendor(
    tmp_path: Path, nim_name: str, vendor_name: str,
    rows: int, columns: int, signed: bool,
) -> None:
    vendor = vendor_table(tmp_path, vendor_name, "h" if signed else "I",
                          rows * columns)
    nim = nim_table(nim_name, signed)
    assert len(nim) == rows * columns
    assert nim == vendor


@pytest.mark.parametrize(
    "nim_name,vendor_name,columns,suffix,format_char",
    [
        ("RfChannelDivTables", "channel_div_table_list", 21, "u32", "I"),
        ("RfChannelCntTables", "channel_cnt_table_list", 21, "u16", "H"),
        ("RfChannelCntRanges", "channel_cnt_range_list", 3, "u16", "H"),
    ],
)
def test_rf_lo_channel_tables_match_vendor(
    tmp_path: Path, nim_name: str, vendor_name: str,
    columns: int, suffix: str, format_char: str,
) -> None:
    count = 6 * columns
    vendor = vendor_table(tmp_path, vendor_name, format_char, count)
    assert nim_channel_table(nim_name, suffix, count) == vendor


@pytest.mark.parametrize(
    "nim_name,vendor_name,count,suffix,format_char",
    [
        ("RfPriTxPowerTableIndexDefault", "tx_pwr_table_idx_origin", 13, "i16", "h"),
        ("RfPriBzTargetPowerDefaultRecords", "bz_tx_pwr_table_idx_origin", 4, None, "h"),
        ("RfPriCwPowerAmplitudeTable", "cw_pwr_table", 31, "u16", "I"),
    ],
)
def test_rf_selection_tables_match_vendor(
    tmp_path: Path, nim_name: str, vendor_name: str,
    count: int, suffix: str | None, format_char: str,
) -> None:
    vendor = vendor_table(tmp_path, vendor_name, format_char, count)
    assert nim_flat_table(nim_name, suffix, count) == vendor


def test_rfc_xtal_config_rows_match_vendor(tmp_path: Path) -> None:
    source = RF_SOURCE.read_text()
    frequencies = {
        name: int(value.replace("_", ""))
        for name, value in re.findall(
            r"\b(WlXtal\w+) = ([\d_]+)'u32", source
        )
    }
    rows = re.findall(r"RfcXtalConfig\((.*?)\)", source, re.DOTALL)
    assert len(rows) == 6
    fields = (
        "xtalHz", "xtalCountWindowMin", "xtalCountWindowMax",
        "xtalDividerConfig", "xtalControlCode",
    )
    nim_words = []
    for row in rows:
        values = dict(re.findall(r"(\w+): (\w+)(?:'u32)?", row))
        assert set(values) == set(fields)
        nim_words.extend(
            frequencies[values[field]] if field == "xtalHz" else int(values[field], 0)
            for field in fields
        )
    assert nim_words == vendor_table(
        tmp_path, "rfc_xtal_cfg", "I", 30, object_name="rfc.c.o"
    )


@pytest.mark.parametrize(
    "nim_name,object_name,symbol,count,suffix,format_char",
    [
        ("agcmem", "agcmem.c.o", "agcmem", 512, "u32", "I"),
        ("trpcTxpwrVsRateTable", "phy_trpc.c.o", "txpwr_vs_rate_table",
         50, "u8", "B"),
    ],
)
def test_phy_runtime_tables_match_vendor(
    tmp_path: Path, nim_name: str, object_name: str, symbol: str,
    count: int, suffix: str, format_char: str,
) -> None:
    vendor = vendor_table(tmp_path, symbol, format_char, count, object_name)
    assert nim_exported_array(nim_name, suffix, count) == vendor
