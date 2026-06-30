"""Tests for SDK-generated BLAI header inspection."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import inspect_blai_header as blai_header


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "tools/ref/npu_recovery_manifest.json"
MEETKAI_ASR = (
    REPO_ROOT
    / "build/vendor-cache/M1s_BL808_SDK/components/stage/dsp2_cli_demo/include/models/meetkai_asr.h"
)


def load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def generated_header_oracle(name: str) -> dict:
    manifest = load_manifest()
    for oracle in manifest["toolchain_converter_oracle"]["generated_header_oracles"]:
        if oracle["path"].endswith(name):
            return oracle
    raise AssertionError(f"missing generated-header oracle for {name}")


def test_rejects_header_without_blai_model_bin(tmp_path):
    header = tmp_path / "empty.h"
    header.write_text("static const uint8_t other[] = { 0x01 };\n", encoding="utf-8")

    with pytest.raises(ValueError, match="blai_model_bin"):
        blai_header.inspect_blai_header(header)


def test_inspects_small_generated_header_fixture(tmp_path):
    header = tmp_path / "fixture.h"
    header.write_text(
        """
        static const uint8_t blai_model_bin[] = {
          0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
          0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
          0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
          0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
          0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
          0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf
        };
        """,
        encoding="utf-8",
    )

    summary = blai_header.inspect_blai_header(header)

    assert summary["valid"]
    assert summary["has_prefix_directory"]
    assert summary["has_second_size_entry"]
    assert summary["header_bytes"] == 32
    assert summary["array_bytes"] == 80
    assert summary["payload_bytes_expected"] == 80
    assert summary["npu_payload_bytes"] == 16
    assert summary["sections"]["cpu_instruction"]["offset"] == 32
    assert summary["sections"]["cpu_instruction"]["bytes"] == 32
    assert summary["sections"]["npu_instruction"]["offset"] == 64
    assert summary["sections"]["npu_instruction"]["bytes"] == 16
    assert summary["sections"]["npu_bias"]["bytes"] == 0
    assert summary["sections"]["npu_weight"]["bytes"] == 0


def test_emits_nim_const_from_generated_header_fixture(tmp_path):
    header = tmp_path / "fixture.h"
    header.write_text(
        """
        static const uint8_t blai_model_bin[] = {
          0x01, 0x02, 0x0a, 0xff
        };
        """,
        encoding="utf-8",
    )

    source = blai_header.blai_header_nim_const_source(
        header, "FixtureModelBin", values_per_line=2)

    assert source == (
        "const FixtureModelBin*: array[4, uint8] = [\n"
        "  0x01'u8, 0x02'u8,\n"
        "  0x0A'u8, 0xFF'u8\n"
        "]\n"
    )


def test_emits_nim_const_for_generated_section(tmp_path):
    header = tmp_path / "fixture.h"
    header.write_text(
        """
        static const uint8_t blai_model_bin[] = {
          0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
          0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
          0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
          0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
          0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
          0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf
        };
        """,
        encoding="utf-8",
    )

    source = blai_header.blai_header_nim_section_const_source(
        header, "npu_instruction", "FixtureNpuInst", values_per_line=4)

    assert source == (
        "const FixtureNpuInst*: array[16, uint8] = [\n"
        "  0xA0'u8, 0xA1'u8, 0xA2'u8, 0xA3'u8,\n"
        "  0xA4'u8, 0xA5'u8, 0xA6'u8, 0xA7'u8,\n"
        "  0xA8'u8, 0xA9'u8, 0xAA'u8, 0xAB'u8,\n"
        "  0xAC'u8, 0xAD'u8, 0xAE'u8, 0xAF'u8\n"
        "]\n"
    )


def test_rejects_unknown_generated_section(tmp_path):
    header = tmp_path / "fixture.h"
    header.write_text(
        """
        static const uint8_t blai_model_bin[] = {
          0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
          0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10
        };
        """,
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="unknown generated section"):
        blai_header.blai_header_nim_section_const_source(
            header, "missing", "Fixture")


def test_rejects_invalid_nim_const_name():
    with pytest.raises(ValueError, match="invalid Nim const name"):
        blai_header.nim_uint8_array_source(b"\x00", "bad-name")


def test_meetkai_asr_generated_header_matches_recovered_layout_when_present():
    oracle = generated_header_oracle("meetkai_asr.h")
    assert oracle["status"].startswith("real SDK generated instruction-only header")
    assert oracle["sections"]["npu_bias"]["bytes"] == 0
    assert oracle["sections"]["npu_weight"]["bytes"] == 0

    if not MEETKAI_ASR.exists():
        return

    summary = blai_header.inspect_blai_header(MEETKAI_ASR)

    for key in (
        "valid",
        "array_bytes",
        "array_sha256",
        "has_prefix_directory",
        "has_second_size_entry",
        "header_bytes",
        "payload_bytes_expected",
        "payload_fits",
        "payload_total",
        "trailing_bytes",
        "npu_payload_bytes",
    ):
        assert summary[key] == oracle[key]

    assert summary["prefix"] == oracle["prefix"]
    assert summary["cpu"] == oracle["cpu"]
    assert summary["sections"] == oracle["sections"]

    nim_source = blai_header.blai_header_nim_const_source(
        MEETKAI_ASR, "MeetkaiAsrBlaiModelBin")
    assert nim_source.startswith(
        "const MeetkaiAsrBlaiModelBin*: array[26304, uint8] = [\n")
    assert "0x00'u8" in nim_source
    assert nim_source.endswith("]\n")

    npu_source = blai_header.blai_header_nim_section_const_source(
        MEETKAI_ASR, "npu_instruction", "MeetkaiAsrNpuInstructionPayload")
    assert npu_source.startswith(
        "const MeetkaiAsrNpuInstructionPayload*: array[8096, uint8] = [\n")
    assert npu_source.endswith("]\n")
