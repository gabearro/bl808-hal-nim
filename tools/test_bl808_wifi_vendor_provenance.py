"""Exercise the reference pins and final-link evidence, not Nim source text."""

import sys

import pytest

import validate_rf_symbol_provenance as provenance


def invoke(monkeypatch, *args):
    monkeypatch.setattr(sys, "argv", ["provenance", *map(str, args)])
    return provenance.main()


def test_pin_both_repo_copies_and_actual_comparison_inputs(tmp_path, monkeypatch):
    # Known Git blob ID of b"hello\n"; a raw file SHA-1 is not a Git blob ID.
    rf = tmp_path / "demo.a"
    rf.write_bytes(b"hello\n")
    monkeypatch.setattr(provenance, "DEMO_RF_BLOB", "ce013625030ba8dba906f756967f9e9ca394464a")
    mac1, mac2 = provenance.REPO_MAC_ARCHIVES
    args = ("--bl808-demo-rf-archive", rf, "--bl808-demo-mac-archive")
    assert invoke(monkeypatch, *args, mac2) == 0
    assert invoke(monkeypatch, *args, rf) == 1
    assert invoke(monkeypatch, "--bl808-demo-rf-archive", mac1) == 1
    for pair in ((rf, mac2), (mac1, rf)):
        monkeypatch.setattr(provenance, "REPO_MAC_ARCHIVES", pair)
        assert invoke(monkeypatch, *args, mac2) == 1


def test_legacy_agc_only_is_not_native_proof(monkeypatch):
    with pytest.raises(SystemExit) as error:
        invoke(monkeypatch, "--bl808-demo-rf-archive", "demo.a", "--check-wifi-phy-memory-init")
    assert error.value.code == 2


def test_map_rejects_extracted_vendor_members_not_archive_mentions(tmp_path):
    path = tmp_path / "kernel.map"
    archive = provenance.DEMO_RF_BLOB + ".libbl606p_phyrf.a"
    lines = [
        "LOAD ref/libwifi_fw.a",
        "libwifi_fw_nim.a(module.o)       libwifi.a",
        "LOAD sdk/libbl606p_phyrf.a   other.a(helper.o)",
        "repo/libwifi_fw.a(mm.o)    init.o (mm_init)",
        " .text.scan 0x1234 0x10 src/libwifi_bl808.a(scan.o)",
        f" .text.phy_init 0x45 0x10 /tmp/{archive}(phy.o)",
        "sdk/libwifi.a(tx.o)",
        "src/librf_bl808.a(rf_pri.o)",
        "sdk/bl606p_phyrf/lib/renamed.a(phy.o)",
    ]
    path.write_text("\n".join(lines))
    assert provenance.check_link_map(path) == [line.strip() for line in lines[3:]]
    path.write_text("foo/renamed.a(mm.o)")
    assert provenance.check_link_map_members(path, {"renamed.a": "MAC"})


NIM_OBJECT = "build/cache/@pbl808@swifi_fw.nim.c.o"
SYMBOLS = (
    ("00001000", "t", "runBl808WlanFullCal__differentModule_u123"),
    ("00002000", "T", "initializeBl808Phy"),
    ("00003000", "T", "mm_start_req_handler"),
    ("00004000", "T", "scan_start_req_handler"),
)


@pytest.fixture()
def linked(tmp_path, monkeypatch):
    elf = tmp_path / "kernel.elf"
    elf.touch()
    link_map = elf.with_suffix(".map")
    rows = [f" .text.{symbol}\n   0x{address} 0x12 {NIM_OBJECT}"
            for address, _, symbol in SYMBOLS]
    # Both one-line and wrapped function sections are emitted by GNU ld.
    rows[1] = rows[1].replace("\n", "")
    link_map.write_text("Linker script and memory map\n" + "\n".join(rows) + "\n")
    nm = "\n".join(" ".join(item) + "  " for item in SYMBOLS)
    monkeypatch.setattr(provenance, "nm", lambda *_: nm)
    return elf, link_map


def test_native_markers_from_live_nim_text(linked):
    assert provenance.check_native_wifi_link(*linked) == []


@pytest.mark.parametrize(("old", "new"), [
    ("00001000", "00001004"),                     # wrong ELF/map pairing
    ("initializeBl808Phy", "initializeBl808PhyLegacy"),
    (f"00003000 0x12 {NIM_OBJECT}", "00003000 0x12 /vendor/mm.o"),
    ("00004000 0x12", "00004000 0x00"),          # no contributed scan code
    ("Linker script and memory map", "Discarded input sections"),
])
def test_native_link_requires_each_marker_at_live_nim_address(linked, old, new):
    elf, link_map = linked
    text = link_map.read_text()
    link_map.write_text(text.replace(old, new))
    assert provenance.check_native_wifi_link(elf, link_map)


def test_native_cli_requires_map_and_retained_elf_code(linked, monkeypatch):
    elf, link_map = linked
    monkeypatch.setattr(provenance, "check_archive_pin", lambda *_: [])
    args = ("--bl808-demo-rf-archive", "demo.a", "--elf", elf)
    assert invoke(monkeypatch, *args) == 0
    monkeypatch.setattr(provenance, "nm", lambda *_: "")
    assert invoke(monkeypatch, *args) == 1
    link_map.unlink()
    with pytest.raises(SystemExit, match="native ELF link map"):
        invoke(monkeypatch, *args)
