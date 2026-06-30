"""Tests for BL808 NPU objdump recovery helpers."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import validate_npu_objdump as audit


REPO_ROOT = Path(__file__).resolve().parents[1]


def run_main(monkeypatch, args: list[str]) -> int:
    monkeypatch.setattr(sys, "argv", ["validate_npu_objdump.py", *args])
    monkeypatch.delenv("BL808_M1S_SDK", raising=False)
    monkeypatch.delenv("BLAI_NPU_TOOLCHAIN", raising=False)
    return audit.main()


def test_main_fails_clearly_without_configured_inputs(monkeypatch, capsys):
    assert run_main(monkeypatch, []) == 2

    err = capsys.readouterr().err
    assert "No NPU inputs configured" in err
    assert "BL808_M1S_SDK" in err
    assert "BLAI_NPU_TOOLCHAIN" in err


def test_main_fails_clearly_for_missing_input_path(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(audit, "tool_path", lambda name, env_name=None: name)

    missing = tmp_path / "missing-sdk"
    assert run_main(monkeypatch, [str(missing)]) == 1

    assert f"input path not found: {missing}" in capsys.readouterr().err


def test_main_fails_clearly_when_no_candidate_objects_found(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(audit, "tool_path", lambda name, env_name=None: name)

    assert run_main(monkeypatch, [str(tmp_path)]) == 3

    assert "No candidate NPU/BLAI objects or archives found." in capsys.readouterr().err


def test_iter_inputs_includes_extensionless_blai_executables(tmp_path):
    toolchain = tmp_path / "blai_toolchain"
    toolchain.mkdir()
    exe = toolchain / "blai_toolchain"
    exe.write_text("#!/bin/sh\n", encoding="utf-8")
    exe.chmod(0o755)
    ignored = toolchain / "blai_notes"
    ignored.write_text("not executable\n", encoding="utf-8")

    assert audit.iter_inputs([toolchain], ("blai", "npu")) == [exe]


def test_parse_missing_shared_libraries_from_converter_probe():
    ldd_text = """
        libbuiltin_ops.so => not found
        libframework_lib.so => not found
        libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x1)
        libbuiltin_ops.so => not found
    """

    assert audit.parse_missing_shared_libraries(ldd_text) == [
        "libbuiltin_ops.so",
        "libframework_lib.so",
    ]


def test_parse_disassembly_keeps_real_calls_and_drops_local_labels(monkeypatch, tmp_path):
    disassembly = """
Disassembly of section .text.BLAI_MEM_alloc:

0000000000000000 <BLAI_MEM_alloc>:
   0: 00000097           auipc ra, 0x0
        0000000000000000:  R_RISCV_CALL check_upsample_layer
   4: 000080e7           jalr  ra
   8: a001               j 0x8 <.LVL1>
        0000000000000008:  R_RISCV_RVC_JUMP .Llocal

000000000000000a <.LVL1>:
   a: c501               sw zero, 0x8(a0)
   c: 00000097           auipc ra, 0x0
        000000000000000c:  R_RISCV_CALL memcpy
  10: 000080e7           jalr  ra

Disassembly of section .text.helper:

0000000000000000 <helper>:
   0: 8082               ret
"""

    monkeypatch.setattr(audit, "run", lambda _cmd: disassembly)
    symbols = [
        {"kind": "T", "name": "BLAI_MEM_alloc", "address": "0x0"},
        {"kind": "T", "name": "helper", "address": "0x0"},
    ]

    parsed = audit.parse_disassembly("llvm-objdump", tmp_path / "fake.a", symbols)

    assert parsed["calls"]["BLAI_MEM_alloc"] == [
        "check_upsample_layer",
        "memcpy",
    ]
    assert ".Llocal" not in parsed["calls"]["BLAI_MEM_alloc"]
    assert parsed["store_lines"]["BLAI_MEM_alloc"] == ["a: c501               sw zero, 0x8(a0)"]


def test_npu_recovery_manifest_matches_tracked_nim_register_names():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")

    assert manifest["source_inputs"]["sdk"]["verified_commit"] == "bf7e689"
    assert manifest["execution_status"]["supported_high_level_execution"] is False
    assert "proc npuConfigureConvLayerResult*" in npu_source
    assert "discard npuConfigureConvLayerResult(" in npu_source
    assert "npuConfigureConvLayerResult exposes" in manifest["execution_status"]["reason"]

    for reg in manifest["blai_registers"]:
        assert reg["nim_const"] in npu_source
        assert reg["nim_field"].split(".", 1)[1] in npu_source

    for field in manifest["bitfields"]:
        assert field["nim_mask"] in npu_source

    for overlay in manifest["nim_overlays"]:
        assert overlay["name"] in npu_source
        assert overlay["size"].startswith("0x")

    assert {
        item["symbol"] for item in manifest["instruction_stream_candidates"]
    } >= {
        "instruction_encode",
        "fetch_BLAI_data_general",
        "fetch_BLAI_data_route",
        "Load_NPU_weights",
    }
    assert any(
        item["area"] == "BLAI instruction stream"
        for item in manifest["unresolved_fields"]
    )
    assert all(
        item["area"] != "BLAI_MEM_alloc"
        for item in manifest["unresolved_fields"]
    )
    manifest_text = json.dumps(manifest)
    assert "allocation algorithm still unresolved" not in manifest_text
    assert (
        "The encoder and buffer allocation path are still not reimplemented in pure Nim."
        not in manifest_text
    )
    assert "NPU Load_NPU_weights reordering remains unresolved" not in manifest_text
    assert "NPU completion semantics remain unresolved" not in manifest_text
    assert "completion semantics not proven" not in manifest_text


def test_manifest_recovered_encoder_constants_match_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    constants = manifest["recovered_encoder_wrapper"]["nim_constants"]

    assert "BlaiInstructionScratchSize* =" in npu_source
    expected_constants = {
        "BlaiFetchMaxPatchSlots": "30'u32",
        "BlaiFetchPatchGrowTries": "5",
        "BlaiMemAllocPsramPatchThresholdBytes": "4096'u32",
        "BlaiMemAllocWeightPatchThresholdBytes": "8192'u32",
    }
    for constant, value in expected_constants.items():
        assert constants[constant] == value.split("'", 1)[0]
        assert f"doAssert {constant} == {value}" in npu_source


def test_manifest_recovered_weight_constants_match_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    constants = set(manifest["recovered_weight_buffer_planning"]["nim_constants"])
    expected_constants = {
        "BlaiNpuWeightPack": "4'u32",
        "BlaiNpuTfliteBiasPack": "1'u32",
        "BlaiNpuFixedBiasPack": "4'u32",
        "BlaiNpuTemporaryGroupChannelLimit": "3'u32",
        "BlaiNpuTemporaryWeightElementBytes": "4'u32",
        "BlaiNpuBiasElementBytes": "4'u32",
    }

    assert constants >= set(expected_constants)
    for constant, value in expected_constants.items():
        assert f"doAssert {constant} == {value}" in npu_source
    assert "blaiInt32BufferBytes(biasBuf)" in npu_source
    assert "if not blaiBiasWordCountBytes(count, result):" in npu_source
    assert "count * BlaiNpuBiasElementBytes" not in npu_source
    assert "biasBuf.len.uint32 * BlaiNpuBiasElementBytes" not in npu_source
    assert "blaiCanNpuAppendWeightBytesInto(\n    blaiOpenArrayLenU32(weightBuf)" in npu_source
    assert "blaiCanNpuAppendBiasWordsInto(\n    blaiOpenArrayLenU32(biasBuf)" in npu_source
    assert "weightBuf.len.uint32, weightCursor" not in npu_source
    assert "biasBuf.len.uint32, biasCursor" not in npu_source
    assert "plan, bytes, startIndex, blaiOpenArrayLenU32(weights)" in npu_source
    assert "plan, bytes, startIndex, blaiOpenArrayLenU32(biases)" in npu_source
    assert "plan, bytes, startIndex, weights.len.uint32" not in npu_source
    assert "plan, bytes, startIndex, biases.len.uint32" not in npu_source
    assert "blaiOpenArrayLenU32(cpuWeightBytes)" in npu_source
    assert "blaiOpenArrayLenU32(cpuBiasBytes)" in npu_source
    assert "decodedWeightElements = blaiOpenArrayLenU32(decodedWeights)" in npu_source
    assert "decodedBiasElements = blaiOpenArrayLenU32(decodedBiases)" in npu_source
    assert "scratchAElements = blaiOpenArrayLenU32(scratchA)" in npu_source
    assert "scratchBElements = blaiOpenArrayLenU32(scratchB)" in npu_source
    assert "outputElements = blaiOpenArrayLenU32(output)" in npu_source
    assert "modelInputElements = blaiOpenArrayLenU32(input)" in npu_source


def test_generated_model_directory_parser_tracks_sdk_model_prefixes():
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")

    assert "BlaiGeneratedModelDirectoryEntryBlock* = enum" in npu_source
    assert "BlaiGeneratedModelDirectoryEntry* = object" in npu_source
    assert "entryRangeFits*: bool" in npu_source
    assert "wordsLoaded*: bool" in npu_source
    assert "firstBlock*: BlaiGeneratedModelDirectoryEntryBlock" in npu_source
    assert "BlaiGeneratedModelDirectoryWordCursor* = object" in npu_source
    assert "BlaiGeneratedModelDirectoryBlock* = enum" in npu_source
    assert "BlaiGeneratedModelDirectory* = object" in npu_source
    assert "cpuFirstBlock*: BlaiGeneratedModelDirectoryEntryBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedModelDirectoryBlock" in npu_source
    assert "BlaiGeneratedModelSectionWindowBlock* = enum" in npu_source
    assert "BlaiGeneratedModelSectionWindow* = object" in npu_source
    assert "rangeFits*: bool" in npu_source
    assert "firstBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "BlaiGeneratedModelSectionCopyByteCursor* = object" in npu_source
    assert "BlaiGeneratedModelFixtureByteCursor* = object" in npu_source
    assert "BlaiGeneratedModelSectionPlanBlock* = enum" in npu_source
    assert "BlaiGeneratedModelSectionPlan* = object" in npu_source
    assert "BlaiGeneratedModelSectionCopyBlock* = enum" in npu_source
    assert "BlaiGeneratedModelSectionCopyResult* = object" in npu_source
    assert "windowFirstBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "BlaiGeneratedCpuRecordStreamCursor* = object" in npu_source
    assert "BlaiGeneratedCpuRecordStreamWindow* = object" in npu_source
    assert "BlaiGeneratedCpuRecordStreamCopyBlock* = enum" in npu_source
    assert "BlaiGeneratedCpuRecordStreamCopyResult* = object" in npu_source
    assert "BlaiGeneratedCpuRecordParseBlock* = enum" in npu_source
    assert "BlaiGeneratedCpuRecordParseResult* = object" in npu_source
    assert "copyFirstBlock*: BlaiGeneratedCpuRecordStreamCopyBlock" in npu_source
    assert "BlaiGeneratedNpuPayloadSectionsBlock* = enum" in npu_source
    assert "BlaiGeneratedNpuPayloadSections* = object" in npu_source
    assert "firstBlock*: BlaiGeneratedNpuPayloadSectionsBlock" in npu_source
    assert "BlaiGeneratedNpuPayloadCopyBlock* = enum" in npu_source
    assert "BlaiGeneratedNpuPayloadCopyResult* = object" in npu_source
    assert "firstSectionCopyBlock*: BlaiGeneratedModelSectionCopyBlock" in (
        npu_source
    )
    assert "firstWindowBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "BlaiGeneratedArrayKind* = enum" in npu_source
    assert "BlaiGeneratedPayloadSectionKind* = enum" in npu_source
    assert "BlaiToolchainConverterOutputKind* = enum" in npu_source
    assert "BlaiToolchainConverterDependencyKind* = enum" in npu_source
    assert "BlaiToolchainConverterDependencyClass* = enum" in npu_source
    assert "BlaiToolchainConverterDependency* = object" in npu_source
    assert "BlaiToolchainConverterDependencyPlan* = object" in npu_source
    assert "BlaiToolchainConverterOutputArtifact* = object" in npu_source
    assert "BlaiToolchainConverterOutputContractBlock* = enum" in npu_source
    assert "BlaiToolchainConverterOutputContract* = object" in npu_source
    assert "validArtifactCount*: uint32" in npu_source
    assert "firstBlock*: BlaiToolchainConverterOutputContractBlock" in npu_source
    assert "BlaiGeneratedModelHeaderContractBlock* = enum" in npu_source
    assert "BlaiGeneratedModelHeaderContract* = object" in npu_source
    assert "firstBlock*: BlaiGeneratedModelHeaderContractBlock" in npu_source
    assert "BlaiGeneratedImageSidecarOracleBlock* = enum" in npu_source
    assert "BlaiGeneratedImageSidecarOracle* = object" in npu_source
    assert "firstBlock*: BlaiGeneratedImageSidecarOracleBlock" in npu_source
    assert "BlaiGeneratedModelHeaderValidationBlock* = enum" in npu_source
    assert "BlaiGeneratedModelHeaderValidation* = object" in npu_source
    assert "cpuTerminatorWord*: uint32" in npu_source
    assert "npuTerminatorWord*: uint32" in npu_source
    assert "terminatorWordsZero*: bool" in npu_source
    assert "BlaiGeneratedModelLoadSection* = object" in npu_source
    assert "windowFirstBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "BlaiGeneratedModelLoadPlanBlock* = enum" in npu_source
    assert "BlaiGeneratedModelLoadPlan* = object" in npu_source
    assert "firstSectionWindowBlock*: BlaiGeneratedModelSectionWindowBlock" in (
        npu_source
    )
    assert "BlaiGeneratedModelPackagePreflightBlock* = enum" in npu_source
    assert "BlaiGeneratedModelPackagePreflight* = object" in npu_source
    assert "sectionPlanFirstBlock*: BlaiGeneratedModelSectionPlanBlock" in (
        npu_source
    )
    assert "directoryFirstBlock*: BlaiGeneratedModelDirectoryBlock" in npu_source
    assert "windowFirstBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "headerFirstBlock*: BlaiGeneratedModelHeaderValidationBlock" in (
        npu_source
    )
    assert "loadPlanFirstBlock*: BlaiGeneratedModelLoadPlanBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedModelPackagePreflightBlock" in npu_source
    assert "packageFirstBlock*: BlaiGeneratedModelPackagePreflightBlock" in npu_source
    assert "BlaiSdkStatus* = enum" in npu_source
    assert "blaiSdkInvalidInput = 6" in npu_source
    assert "BlaiSdkOutputBufferBlock* = enum" in npu_source
    assert "BlaiSdkInputBufferPlan* = object" in npu_source
    assert "BlaiSdkNetInfoPlan* = object" in npu_source
    assert "BlaiSdkLoadModelFromFilePlan* = object" in npu_source
    assert "BlaiSdkCreatePlan* = object" in npu_source
    assert "BlaiSdkStartComputePlan* = object" in npu_source
    assert "BlaiSdkFreePlan* = object" in npu_source
    assert "BlaiSdkOutputBufferPlan* = object" in npu_source
    assert "BlaiSdkInputResolutionPlan* = object" in npu_source
    assert "BlaiSdkSourceResolutionState* = object" in npu_source
    assert "BlaiSdkSourceResolutionPlan* = object" in npu_source
    assert "BlaiSdkCallbackState* = object" in npu_source
    assert "BlaiSdkResultCallbackPlan* = object" in npu_source
    assert "BlaiSdkCustomPostprocessCallbackPlan* = object" in npu_source
    assert "BlaiMnistGeneratedPackageContractBlock* = enum" in npu_source
    assert "BlaiMnistGeneratedPackageContract* = object" in npu_source
    assert "firstBlock*: BlaiMnistGeneratedPackageContractBlock" in npu_source
    assert "BlaiMnistToolchainSramReadinessBlock* = enum" in npu_source
    assert "BlaiMnistToolchainSramReadinessEvidence* = object" in npu_source
    assert "packageFirstBlock*: BlaiMnistGeneratedPackageContractBlock" in (
        npu_source
    )
    assert "activePlannerBytes*: uint32" in npu_source
    assert "cfgTotalBytes*: uint32" in npu_source
    assert "sparePatchBytes*: uint32" in npu_source
    assert "persistentTensorPatchSlots*: uint32" in npu_source
    assert "persistentTensorSpareBytes*: uint32" in npu_source
    assert "firstBlock*: BlaiMnistToolchainSramReadinessBlock" in npu_source
    assert "BlaiMnistConverterGenerationBlock* = enum" in npu_source
    assert "BlaiMnistConverterGenerationEvidence* = object" in npu_source
    assert "packageFirstBlock*: BlaiMnistGeneratedPackageContractBlock" in (
        npu_source
    )
    assert "sramReadinessFirstBlock*: BlaiMnistToolchainSramReadinessBlock" in (
        npu_source
    )
    assert "dependencyPlan*: BlaiToolchainConverterDependencyPlan" in npu_source
    assert (
        "artifactRegeneration*: BlaiToolchainConverterArtifactRegenerationPlan"
        in npu_source
    )
    assert "frameworkMissingCount*: uint32" in npu_source
    assert "firstMissingDependency*: BlaiToolchainConverterDependencyKind" in (
        npu_source
    )
    assert "firstBlock*: BlaiMnistConverterGenerationBlock" in npu_source
    assert "BlaiToolchainConverterExecutionBlock* = enum" in npu_source
    assert "BlaiToolchainConverterArtifactRegenerationBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainConverterArtifactRegenerationPlan* = object" in (
        npu_source
    )
    assert "BlaiToolchainConverterMissingSharedLibraryCount* = 14'u32" in npu_source
    assert "BlaiGeneratedModelCpuSectionCount* = 3'u32" in npu_source
    assert "BlaiGeneratedModelNpuSectionCount* = 3'u32" in npu_source
    assert "BlaiGeneratedModelSizeTableWords* = 8'u32" in npu_source
    assert "BlaiGeneratedNpuPayloadAddressBlock* = enum" in npu_source
    assert "BlaiGeneratedNpuPayloadAddressPlan* = object" in npu_source
    assert "BlaiGeneratedNpuStagedPayloadBlock* = enum" in npu_source
    assert "BlaiGeneratedNpuStagedPayloadResult* = object" in npu_source
    assert "payloadCopyBlock*: BlaiGeneratedNpuPayloadCopyBlock" in npu_source
    assert "addressBlock*: BlaiGeneratedNpuPayloadAddressBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedNpuStagedPayloadBlock" in npu_source
    assert "BlaiGeneratedNpuPreparedPayloadBlock* = enum" in npu_source
    assert "BlaiGeneratedNpuPreparedPayloadResult* = object" in npu_source
    assert "stagedFirstBlock*: BlaiGeneratedNpuStagedPayloadBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedNpuPreparedPayloadBlock" in npu_source
    assert "BlaiGeneratedNpuConfigureBlock* = enum" in npu_source
    assert "blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "BlaiGeneratedNpuConfigureResult* = object" in npu_source
    assert "BlaiGeneratedNpuConfigurePlan* = object" in npu_source
    assert "BlaiGeneratedNpuRunPlan* = object" in npu_source
    assert "BlaiGeneratedNpuRunPreflightPlan* = object" in npu_source
    assert "configureBlock*: BlaiGeneratedNpuConfigureBlock" in npu_source
    assert "BlaiGeneratedNpuPipelineBlock* = enum" in npu_source
    assert "blaiGeneratedNpuPipelinePackagePreflight" in npu_source
    assert "BlaiGeneratedNpuPipelinePreflightResult* = object" in npu_source
    assert "preparedBlock*: BlaiGeneratedNpuPreparedPayloadBlock" in npu_source
    assert "packageBlock*: BlaiGeneratedModelPackagePreflightBlock" in npu_source
    assert "stagedBlock*: BlaiGeneratedNpuStagedPayloadBlock" in npu_source
    assert "BlaiGeneratedNpuRunResult* = object" in npu_source
    assert "headerWindow*: BlaiGeneratedModelSectionWindow" in npu_source
    assert "cpuInstructionWindow*: BlaiGeneratedModelSectionWindow" in npu_source
    assert "npuInstructionWindow*: BlaiGeneratedModelSectionWindow" in npu_source
    assert "npuBiasWindow*: BlaiGeneratedModelSectionWindow" in npu_source
    assert "npuWeightWindow*: BlaiGeneratedModelSectionWindow" in npu_source
    assert "cpuInstructionFits*: bool" in npu_source
    assert "npuWeightFits*: bool" in npu_source
    assert "directoryFirstBlock*: BlaiGeneratedModelDirectoryBlock" in npu_source
    assert "firstWindowBlock*: BlaiGeneratedModelSectionWindowBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedModelSectionPlanBlock" in npu_source
    assert "proc blaiGeneratedModelDirectoryWordCursor*(wordIndex: uint32)" in npu_source
    assert "proc blaiGeneratedModelFixtureByteCursor*(\n    sectionOffset: uint32" in npu_source
    assert "proc blaiStoreGeneratedModelFixtureByte*" in npu_source
    assert "blaiStoreGeneratedModelFixtureByte(\n      generatedCompactBlob" in npu_source
    assert "blaiStoreGeneratedModelFixtureByte(\n      generatedStagedBlob" in npu_source
    assert "blaiStoreGeneratedModelFixtureByte(\n      generatedInstructionOnlyBlob" in npu_source
    assert "generatedCompactBlob[0x20 + generatedByteIndex]" not in npu_source
    assert "generatedCompactBlob[0x38 + generatedByteIndex]" not in npu_source
    assert "generatedCompactBlob[0x48 + generatedByteIndex]" not in npu_source
    assert "generatedCompactBlob[0x58 + generatedByteIndex]" not in npu_source
    assert "generatedParsedBlob[0x20 + cursor.absoluteIndex]" not in npu_source
    assert "generatedParsedBlob[0x60] = 0x5A'u8" not in npu_source
    assert "generatedParsedBlob[0x70] = 0xA5'u8" not in npu_source
    assert "generatedStagedBlob[0x38 + generatedByteIndex]" not in npu_source
    assert "generatedStagedBlob[0x48 + generatedByteIndex]" not in npu_source
    assert "generatedStagedBlob[0x58 + generatedByteIndex]" not in npu_source
    assert "generatedInstructionOnlyBlob[0x20 + generatedByteIndex]" not in npu_source
    assert "generatedInstructionOnlyBlob[0x30 + generatedByteIndex]" not in npu_source
    assert "generatedInstructionOnlyBlob[0x40 + generatedByteIndex]" not in npu_source
    assert "proc blaiLoadGeneratedModelDirectoryWord(" in npu_source
    assert "proc blaiGeneratedModelDirectoryEntryInto*" in npu_source
    assert "outEntry.firstBlock = blaiGeneratedModelDirectoryEntryWord0" in (
        npu_source
    )
    assert "outEntry.firstBlock = blaiGeneratedModelDirectoryEntryBlobBounds" in (
        npu_source
    )
    assert "blaiLoadGeneratedModelDirectoryWord(blob, offset, 0'u32, w0)" in npu_source
    assert "blaiLoadGeneratedModelDirectoryWord(blob, offset, 3'u32, w3)" in npu_source
    assert "blaiLoadLe32(blob, offset + 4'u32" not in npu_source
    assert "blaiLoadLe32(blob, offset + 8'u32" not in npu_source
    assert "blaiLoadLe32(blob, offset + 12'u32" not in npu_source
    assert "proc blaiGeneratedModelDirectoryInto*" in npu_source
    assert "proc blaiGeneratedModelSectionWindowInto*" in npu_source
    assert "outWindow.firstBlock = blaiGeneratedModelSectionWindowInactive" in (
        npu_source
    )
    assert "outWindow.firstBlock = blaiGeneratedModelSectionWindowRange" in (
        npu_source
    )
    assert "outWindow.firstBlock = blaiGeneratedModelSectionWindowBlobBounds" in (
        npu_source
    )
    assert "outWindow.offset = offset" in npu_source
    assert "outWindow.bytes = bytes" in npu_source
    assert "proc blaiGeneratedModelSectionPlanInto*" in npu_source
    assert "outPlan.directoryFirstBlock = outPlan.directory.firstBlock" in npu_source
    assert "outPlan.firstWindowBlock = outPlan.npuWeightWindow.firstBlock" in (
        npu_source
    )
    assert "outPlan.firstBlock = blaiGeneratedModelSectionPlanDirectory" in npu_source
    assert "outPlan.firstBlock = blaiGeneratedModelSectionPlanNpuWeight" in npu_source
    assert "proc blaiGeneratedModelHeaderContract*" in npu_source
    assert "result.firstBlock = blaiGeneratedModelHeaderContractSizeTable" in (
        npu_source
    )
    assert "result.firstBlock = blaiGeneratedModelHeaderContractHeaderBytes" in (
        npu_source
    )
    assert "proc blaiToolchainConverterOutputArtifact*" in npu_source
    assert "proc blaiToolchainConverterOutputContract*" in npu_source
    assert "proc blaiToolchainConverterDependencyClass*" in npu_source
    assert "proc blaiToolchainConverterDependency*" in npu_source
    assert "proc blaiToolchainConverterDependencyPlanInto*" in npu_source
    assert "proc blaiToolchainConverterDependencyPlan*" in npu_source
    assert "proc blaiToolchainConverterArtifactRegenerationPlanInto*" in (
        npu_source
    )
    assert "proc blaiToolchainConverterArtifactRegenerationPlan*" in npu_source
    assert "outResult.staticOutputContractUsable =" in npu_source
    assert "result.firstBlock = blaiToolchainConverterOutputContractPayloadOrder" in (
        npu_source
    )
    assert "result.firstBlock = blaiToolchainConverterOutputContractArtifact" in (
        npu_source
    )
    assert "proc blaiGeneratedImageSidecarOracle*" in npu_source
    assert "result.firstBlock = blaiGeneratedImageSidecarSample" in npu_source
    assert "result.firstBlock = blaiGeneratedImageSidecarDigest" in npu_source
    assert "proc blaiValidateGeneratedModelHeaderContractInto*" in npu_source
    assert "outResult.cpuTerminatorWord = plan.directory.prefix.recoveredWord3" in npu_source
    assert "outResult.npuTerminatorWord = plan.directory.cpu.recoveredWord3" in npu_source
    assert "outResult.firstBlock = blaiGeneratedModelHeaderValidationTerminators" in npu_source
    assert "proc blaiGeneratedModelLoadSection*" in npu_source
    assert "result.windowFirstBlock = window.firstBlock" in npu_source
    assert "proc blaiGeneratedModelLoadPlanInto*" in npu_source
    assert "outResult.firstBlock = blaiGeneratedModelLoadPlanSectionPlan" in npu_source
    assert "outResult.firstSectionWindowBlock = outResult.sections[5].windowFirstBlock" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedModelLoadPlanNpuWeight" in npu_source
    assert "proc blaiGeneratedModelLoadPlan*" in npu_source
    assert "proc blaiGeneratedModelPackagePreflightInto*" in npu_source
    assert "outResult.sectionPlanFirstBlock = outResult.sectionPlan.firstBlock" in (
        npu_source
    )
    assert "outResult.headerFirstBlock = outResult.headerValidation.firstBlock" in (
        npu_source
    )
    assert "outResult.loadPlanFirstBlock = outResult.loadPlan.firstBlock" in (
        npu_source
    )
    assert "outResult.headerValid = outResult.headerValidation.valid" in npu_source
    assert "outResult.firstBlock = blaiGeneratedModelPackagePreflightHeader" in npu_source
    assert "outResult.readyToStage =\n    outResult.sectionPlanValid and outResult.headerValid" in npu_source
    assert "proc blaiSdkInputBufferPlanInto*" in npu_source
    assert "proc blaiSdkInputBufferPlan*" in npu_source
    assert "proc blaiSdkNetInfoPlanInto*" in npu_source
    assert "proc blaiSdkNetInfoPlan*" in npu_source
    assert "proc blaiSdkLoadModelFromFilePlanInto*" in npu_source
    assert "proc blaiSdkLoadModelFromFilePlan*" in npu_source
    assert "proc blaiSdkCreatePlanInto*" in npu_source
    assert "proc blaiSdkCreatePlan*" in npu_source
    assert "proc blaiSdkStartComputePlanInto*" in npu_source
    assert "proc blaiSdkStartComputePlan*" in npu_source
    assert "proc blaiSdkFreePlanInto*" in npu_source
    assert "proc blaiSdkFreePlan*" in npu_source
    assert "proc blaiSdkOutputBufferPlanInto*" in npu_source
    assert "proc blaiSdkOutputBufferPlan*" in npu_source
    assert "proc blaiSdkInputResolutionPlanInto*" in npu_source
    assert "proc blaiSdkInputResolutionPlan*" in npu_source
    assert "proc blaiSdkSourceResolutionPlanInto*" in npu_source
    assert "proc blaiSdkSourceResolutionPlan*" in npu_source
    assert "proc blaiSdkCallbackState*" in npu_source
    assert "proc blaiSdkResultCallbackPlanInto*" in npu_source
    assert "proc blaiSdkResultCallbackPlan*" in npu_source
    assert "proc blaiSdkCustomPostprocessCallbackPlanInto*" in npu_source
    assert "proc blaiSdkCustomPostprocessCallbackPlan*" in npu_source
    assert "proc blaiMnistGeneratedPackageContractInto*" in npu_source
    assert "outResult.firstBlock = blaiMnistGeneratedPackageModel" in npu_source
    assert "outResult.firstBlock = blaiMnistGeneratedPackageOutputOracle" in (
        npu_source
    )
    assert "proc blaiMnistToolchainSramReadinessEvidenceInto*" in npu_source
    assert "outResult.packageFirstBlock = package.firstBlock" in npu_source
    assert "outResult.activePlannerBytes = package.cfgMemory.activePlannerBytes" in (
        npu_source
    )
    assert "outResult.cfgTotalBytes = package.cfgMemory.cfgTotalBytes" in npu_source
    assert "outResult.sparePatchBytes = package.cfgMemory.sparePatchBytes" in (
        npu_source
    )
    assert "outResult.persistentTensorPatchSlots =\n    blaiCeilDivU32(\n" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiMnistToolchainSramReadinessPackage" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiMnistToolchainSramReadinessGlobals" in (
        npu_source
    )
    assert "proc blaiMnistConverterGenerationEvidenceInto*" in npu_source
    assert "outResult.packageFirstBlock = package.firstBlock" in npu_source
    assert "outResult.sramReadinessFirstBlock = sram.firstBlock" in npu_source
    assert "outResult.firstBlock = blaiMnistConverterGenerationExecution" in (
        npu_source
    )
    assert "outputValidationStillBlocked*: bool" in npu_source
    assert "outResult.realModelPlannerReady" in npu_source
    assert "proc blaiGeneratedModelSectionByte*" in npu_source
    assert "proc blaiGeneratedModelSectionCopyByteCursor*(\n    byteIndex, count: int)" in npu_source
    assert "proc blaiCopyGeneratedModelSectionInto*" in npu_source
    assert "outResult.windowFirstBlock = section.firstBlock" in npu_source
    assert "blaiGeneratedModelSectionCopyByteCursor(rawByteIndex, sourceWindow.count)" in npu_source
    assert "outResult.firstBlock = blaiGeneratedModelSectionCopySection" in npu_source
    assert "outResult.firstBlock = blaiGeneratedModelSectionCopyDestination" in npu_source
    assert "outResult.firstBlock = blaiGeneratedNpuPayloadCopySections" in npu_source
    assert "outResult.firstSectionCopyBlock = outResult.weight.firstBlock" in (
        npu_source
    )
    assert "outResult.firstWindowBlock = outResult.weight.windowFirstBlock" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuPayloadCopyWeight" in npu_source
    assert "blaiCheckedByteOpenArray(destination, destinationWindow)[byteIndex]" not in npu_source
    assert "blaiCheckedByteOpenArray(blob, sourceWindow)[byteIndex]" not in npu_source
    assert (
        "blaiCheckedByteOpenArray(blob, sourceWindow)[sourceWindow.count - 1]"
        not in npu_source
    )
    assert "proc blaiGeneratedNpuPayloadSectionsInto*" in npu_source
    assert "outSections.instructionFits =\n    plan.npuInstructionFits" in npu_source
    assert "outSections.firstBlock = blaiGeneratedNpuPayloadSectionsPlan" in (
        npu_source
    )
    assert "outSections.firstBlock = blaiGeneratedNpuPayloadSectionsTotal" in (
        npu_source
    )
    assert "proc blaiCopyGeneratedNpuPayloadsInto*" in npu_source
    assert "proc blaiGeneratedNpuPayloadAddressPlanInto*" in npu_source
    assert "firstBlock*: BlaiGeneratedNpuPayloadAddressBlock" in npu_source
    assert "blaiGeneratedNpuPayloadAddressInvalidPayload" in npu_source
    assert "blaiGeneratedNpuPayloadAddressMissingInstruction" in npu_source
    assert "blaiGeneratedNpuPayloadAddressMissingBias" in npu_source
    assert "blaiGeneratedNpuPayloadAddressMissingWeight" in npu_source
    assert "blaiGeneratedNpuPayloadAddressNoInstructionStream" in npu_source
    assert "proc blaiStageGeneratedNpuPayloadsInto*" in npu_source
    assert "proc blaiPrepareGeneratedNpuPayloadsInto*" in npu_source
    assert "outResult.payloadCopyBlock = outResult.payloadCopy.firstBlock" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuStagedPayloadCopy" in npu_source
    assert "outResult.addressBlock = outResult.addressPlan.firstBlock" in npu_source
    assert "outResult.firstBlock = blaiGeneratedNpuStagedPayloadAddress" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuStagedPayloadNoBlock" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuPreparedPayloadPackage" in (
        npu_source
    )
    assert "outResult.stagedFirstBlock = outResult.staged.firstBlock" in npu_source
    assert "outResult.payloadCopyBlock = outResult.staged.payloadCopyBlock" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuPreparedPayloadStage" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuPreparedPayloadNoBlock" in (
        npu_source
    )
    assert "proc blaiGeneratedNpuConfigurePlanInto*" in npu_source
    assert "proc blaiConfigureStagedGeneratedNpuPayloadInto*" in npu_source
    assert "outResult.firstBlock = blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "outResult.firstBlock = blaiGeneratedNpuConfigureConfiguredApply" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuConfigureConfiguredState" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "proc blaiGeneratedNpuRunPlanInto*" in npu_source
    assert "proc blaiGeneratedNpuRunPreflightPlanInto*" in npu_source
    assert "outResult.configureBlock = configure.firstBlock" in npu_source
    assert "proc blaiGeneratedNpuPipelinePreflightInto*" in npu_source
    assert "outResult.configureBlock = plan.configureBlock" in npu_source
    assert "firstBlock*: BlaiGeneratedNpuPipelineBlock" in npu_source
    assert "addressBlock*: BlaiGeneratedNpuPayloadAddressBlock" in npu_source
    assert "runBlock*: NpuLayerRunBlock" in npu_source
    assert "blaiGeneratedNpuPipelineAddressPlan" in npu_source
    assert "outResult.firstBlock = blaiGeneratedNpuPipelinePackagePreflight" in (
        npu_source
    )
    assert "outResult.preparedBlock = outResult.prepared.firstBlock" in npu_source
    assert "outResult.packageBlock = outResult.prepared.packageFirstBlock" in (
        npu_source
    )
    assert "outResult.stagedBlock = outResult.prepared.stagedFirstBlock" in (
        npu_source
    )
    assert "outResult.payloadCopyBlock = outResult.prepared.payloadCopyBlock" in (
        npu_source
    )
    assert "outResult.configureBlock = outResult.configure.firstBlock" in npu_source
    assert "outResult.addressBlock = outResult.prepared.addressBlock" in (
        npu_source
    )
    assert "outResult.runBlock = outResult.run.firstBlock" in npu_source
    assert "proc blaiRunGeneratedNpuPlanInto*" in npu_source
    assert "proc blaiCopyGeneratedCpuRecordStreamInto*" in npu_source
    assert "outResult.windowFirstBlock = section.firstBlock" in npu_source
    assert "outResult.firstBlock = blaiGeneratedCpuRecordStreamCopyAlignment" in npu_source
    assert "outResult.firstBlock = blaiGeneratedCpuRecordStreamCopyStream" in npu_source
    assert "proc blaiGeneratedCpuRecordStreamCursor*(\n    recordIndex, recordCount: int)" in npu_source
    assert "proc blaiGeneratedCpuRecordStreamWindow*(\n    recordCount: uint32" in npu_source
    assert "blaiGeneratedCpuRecordStreamCursor(\n        countCursor.count - 1, countCursor.count)" in npu_source
    assert "decodeBlaiCpuInstructionType(stream[countCursor.count - 1])" not in npu_source
    assert "blaiGeneratedCpuRecordStreamWindow(outResult.copy.recordCount, stream.len)" in npu_source
    assert "outResult.copyFirstBlock = outResult.copy.firstBlock" in npu_source
    assert "outResult.windowFirstBlock = outResult.copy.windowFirstBlock" in npu_source
    assert "outResult.firstBlock = blaiGeneratedCpuRecordParseCopy" in npu_source
    assert "outResult.firstBlock = blaiGeneratedCpuRecordParseInstructions" in npu_source
    assert "blaiZeroBasedOpenArrayStop(\n      outResult.copy.recordCount, stream.len" not in npu_source
    assert "stream.toOpenArray(0, stopIndex)" not in npu_source
    assert "proc blaiParseGeneratedCpuRecordSectionInto*" in npu_source
    assert "outEntry.prefixBytes = w0" in npu_source
    assert "outEntry.prefixWithinBlob = w0 <= blaiBufferLenU32(blob.len)" in npu_source
    assert "let secondEntryLooksCpu =" in npu_source
    assert "outDirectory.hasPrefixDirectory =" in npu_source
    assert "outDirectory.firstBlock = blaiGeneratedModelDirectoryCpuEntry" in (
        npu_source
    )
    assert "outDirectory.firstBlock = blaiGeneratedModelDirectoryPayloadBoundary" in (
        npu_source
    )
    assert "generatedNpuApiDv4Prefix: array[48, uint8]" in npu_source
    assert "generatedNpuApiDv4Directory.firstBlock ==\n    blaiGeneratedModelDirectoryCpuEntry" in npu_source
    assert "generatedNpuApiDv4SizedDirectory.firstBlock ==\n    blaiGeneratedModelDirectoryNoBlock" in npu_source
    assert "generatedNpuApiDv4Directory.prefix.prefixBytes == 0x7B0'u32" in npu_source
    assert "generatedNpuApiDv4Directory.prefix.firstBlock ==\n    blaiGeneratedModelDirectoryEntryBlobBounds" in npu_source
    assert "generatedNpuApiDv4Directory.cpu.prefixBytes == 0x250'u32" in npu_source
    assert "generatedNpuApiDv4Directory.cpu.firstBlock ==\n    blaiGeneratedModelDirectoryEntryBlobBounds" in npu_source
    assert "generatedNpuApiDv4SectionPlan.headerWindow.endExclusive == 0x20'u32" in npu_source
    assert "generatedNpuApiDv4SectionPlan.cpuRecordWindow.offset == 0x20'u32" in npu_source
    assert "generatedNpuApiDv4SectionPlan.npuInstructionWindow.offset ==\n    0x36C76'u32" in npu_source
    assert "generatedPlainMbv2Entry.prefixBytes == 0x4A0'u32" in npu_source
    assert "generatedPlainMbv2Directory.cpu.prefixBytes == 0xB00'u32" in npu_source
    assert "generatedPlainMbv2Directory.firstBlock ==\n    blaiGeneratedModelDirectoryCpuEntry" in npu_source
    assert "generatedPlainMbv2Directory.cpu.firstBlock ==\n    blaiGeneratedModelDirectoryEntryBlobBounds" in npu_source
    assert "generatedPlainMbv2SectionPlan.cpuRecordWindow.offset == 0x20'u32" in npu_source
    assert "generatedPlainMbv2SectionPlan.npuInstructionWindow.offset ==\n    0x4C0'u32" in npu_source
    assert "generatedPlainMbv2SectionPlan.payloadBytesExpected == 0x392170'u32" in npu_source
    assert "generatedCompactSectionPlan.valid" in npu_source
    assert "generatedCompactSectionPlan.directory.cpu.firstBlock ==\n    blaiGeneratedModelDirectoryEntryNoBlock" in npu_source
    assert "generatedCompactSectionPlan.cpuRecordWindow.firstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedInactiveSectionWindow.firstBlock ==\n    blaiGeneratedModelSectionWindowInactive" in npu_source
    assert "generatedOutOfBlobSectionWindow.firstBlock ==\n    blaiGeneratedModelSectionWindowBlobBounds" in npu_source
    assert "generatedOutOfBlobLoadSection.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowBlobBounds" in npu_source
    assert "generatedOverflowSectionWindow.firstBlock ==\n    blaiGeneratedModelSectionWindowRange" in npu_source
    assert "generatedHeaderContract.valid" in npu_source
    assert "generatedHeaderContract.firstBlock ==\n    blaiGeneratedModelHeaderContractNoBlock" in npu_source
    assert "generatedHeaderContract.arrayMatches" in npu_source
    assert "generatedHeaderContract.sizeTableWordsMatch" in npu_source
    assert "generatedHeaderContract.headerBytesMatch" in npu_source
    assert "converterOutputContract.valid" in npu_source
    assert "converterOutputContract.firstBlock ==\n    blaiToolchainConverterOutputContractNoBlock" in npu_source
    assert "converterOutputContract.artifactCount == 6'u32" in npu_source
    assert "converterOutputContract.validArtifactCount == 6'u32" in npu_source
    assert "converterOutputContract.payloadOrderMatchesGenArray" in npu_source
    assert (
        "converterOutputContract.artifacts[0].output ==\n"
        "    blaiToolchainOutputDspInstructionBin"
    ) in npu_source
    assert (
        "converterOutputContract.artifacts[3].output ==\n"
        "    blaiToolchainOutputInstructionBin"
    ) in npu_source
    assert "generatedHeaderValidation.valid" in npu_source
    assert "generatedHeaderValidation.payloadOrderMatches" in npu_source
    assert "generatedHeaderValidation.firstBlock ==\n    blaiGeneratedModelHeaderValidationNoBlock" in npu_source
    assert "generatedHeaderValidation.terminatorWordsZero" in npu_source
    assert "generatedBadTerminatorValidation.firstBlock ==\n    blaiGeneratedModelHeaderValidationTerminators" in npu_source
    assert "generatedBadTerminatorValidation.npuTerminatorWord == 1'u32" in npu_source
    assert "not generatedBadTerminatorValidation.terminatorWordsZero" in npu_source
    assert "generatedLoadPlan.valid" in npu_source
    assert "generatedLoadPlan.firstBlock == blaiGeneratedModelLoadPlanNoBlock" in npu_source
    assert "generatedLoadPlan.firstSectionWindowBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedLoadPlan.cacheCleanSectionCount == 3'u32" in npu_source
    assert "generatedLoadPlan.sections[0].windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedPlainMbv2LoadPlan.firstBlock ==\n    blaiGeneratedModelLoadPlanSectionPlan" in npu_source
    assert "not generatedLoadPlan.sections[0].cacheCleanRequired" in npu_source
    assert "generatedLoadPlan.sections[3].cacheCleanRequired" in npu_source
    assert "not generatedLoadPlan.cpuWeightGuardMismatch" in npu_source
    assert "generatedPackagePreflight.readyToStage" in npu_source
    assert "generatedPackagePreflight.firstBlock ==\n    blaiGeneratedModelPackagePreflightNoBlock" in npu_source
    assert "generatedPackagePreflight.headerFirstBlock ==\n    blaiGeneratedModelHeaderValidationNoBlock" in npu_source
    assert "generatedPackagePreflight.loadPlanFirstBlock ==\n    blaiGeneratedModelLoadPlanNoBlock" in npu_source
    assert "not generatedBadTerminatorPreflight.headerValid" in npu_source
    assert "not generatedBadTerminatorPreflight.readyToStage" in npu_source
    assert "generatedBadTerminatorPreflight.firstBlock ==\n    blaiGeneratedModelPackagePreflightHeader" in npu_source
    assert "generatedBadTerminatorPreflight.headerFirstBlock ==\n    blaiGeneratedModelHeaderValidationTerminators" in npu_source
    assert "generatedPreparedPayload.packagePreflight.readyToStage" in npu_source
    assert "generatedPreparedPayload.packageFirstBlock ==\n    blaiGeneratedModelPackagePreflightNoBlock" in npu_source
    assert "generatedPreparedPayload.firstBlock ==\n    blaiGeneratedNpuPreparedPayloadNoBlock" in npu_source
    assert "generatedPreparedPayload.stagedFirstBlock ==\n    blaiGeneratedNpuStagedPayloadNoBlock" in npu_source
    assert "generatedPreparedPayload.addressBlock ==\n    blaiGeneratedNpuPayloadAddressNoBlock" in npu_source
    assert "not generatedBadPreparedPayload.headerValid" in npu_source
    assert "generatedBadPreparedPayload.packageFirstBlock ==\n    blaiGeneratedModelPackagePreflightHeader" in npu_source
    assert "generatedBadPreparedPayload.firstBlock ==\n    blaiGeneratedNpuPreparedPayloadPackage" in npu_source
    assert "not generatedBadPreparedPayload.payloadStaged" in npu_source
    assert "outResult.bufferToken = bufferToken" in npu_source
    assert "outResult.bufferPresent = bufferToken != 0'u32" in npu_source
    assert "outResult.capacityPresent = bufferBytes != 0'u32" in npu_source
    assert "outResult.netToken = netToken" in npu_source
    assert "outResult.netPresent = netToken != 0'u32" in npu_source
    assert "outResult.status = blaiSdkInvalidInput" in npu_source
    assert "outResult.returnsInvalidInput = true" in npu_source
    assert "outResult.callsHardwareInit = not initialNpuInited" in npu_source
    assert "outResult.freesModelOnNetFailure = true" in npu_source
    assert "outResult.parentLinked = true" in npu_source
    assert "outResult.shareBufferCleared = true" in npu_source
    assert "outResult.callsRuntimeInit = true" in npu_source
    assert "outResult.status = blaiSdkUnavailableDevice" in npu_source
    assert "outResult.delegatesToInference = true" in npu_source
    assert "outResult.status = inferenceStatus" in npu_source
    assert "outResult.callsInstRelease = true" in npu_source
    assert "outResult.freesCpuInstruction = cpuInstructionAllocated" in npu_source
    assert "outResult.freesNpuWeights = npuWeightsAllocated" in npu_source
    assert "outResult.preservesNpuRuntime = true" in npu_source
    assert "outResult.sizeReturned = patchSize" in npu_source
    assert "outResult.slotOffset = blaiPatchSlotOffset(lastLayer.outLayerMem, patchSize)" in npu_source
    assert "blaiDataBufferRangeFitsInto(\n    true, outResult.outputOffset, outResult.outputBytes, bufferBytes" in npu_source
    assert "outResult.widthPresent = width != 0'u32" in npu_source
    assert "outResult.heightPresent = height != 0'u32" in npu_source
    assert "outResult.stateAfter = BlaiSdkSourceResolutionState(" in npu_source
    assert "outResult.stateAfter.resultCallbackToken = callbackToken" in npu_source
    assert "outResult.stateAfter.customPostprocessCallbackToken = callbackToken" in npu_source
    assert "outResult.stateAfter.customPostprocessEnabled = true" in npu_source
    assert "generatedCompactSectionPlan.npuWeightWindow.offset == 0x58'u32" in npu_source
    assert "generatedCompactSectionPlan.firstBlock ==\n    blaiGeneratedModelSectionPlanNoBlock" in npu_source
    assert "generatedNpuApiDv4SectionPlan.firstBlock ==\n    blaiGeneratedModelSectionPlanDirectory" in npu_source
    assert "generatedNpuApiDv4SectionPlan.directoryFirstBlock ==\n    blaiGeneratedModelDirectoryCpuEntry" in npu_source
    assert "generatedCompactSectionPlan.directoryFirstBlock ==\n    blaiGeneratedModelDirectoryNoBlock" in npu_source
    assert "generatedCompactSectionPlan.firstWindowBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedNpuPayloadSections.totalBytes == 0x30'u32" in npu_source
    assert "generatedNpuPayloadSections.firstBlock ==\n    blaiGeneratedNpuPayloadSectionsNoBlock" in npu_source
    assert "generatedInvalidNpuPayloadSections.firstBlock ==\n    blaiGeneratedNpuPayloadSectionsPlan" in npu_source
    assert "generatedNpuPayloadCopy.instruction.firstByte == 0xB0'u8" in npu_source
    assert "generatedNpuPayloadCopy.bias.firstByte == 0xC0'u8" in npu_source
    assert "generatedNpuPayloadCopy.weight.firstByte == 0xD0'u8" in npu_source
    assert "generatedNpuPayloadCopy.firstBlock ==\n    blaiGeneratedNpuPayloadCopyNoBlock" in npu_source
    assert "generatedNpuPayloadCopy.firstSectionCopyBlock ==\n    blaiGeneratedModelSectionCopyNoBlock" in npu_source
    assert "generatedNpuPayloadCopy.firstWindowBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedShortNpuPayloadCopy.firstBlock ==\n    blaiGeneratedNpuPayloadCopyWeight" in npu_source
    assert "generatedShortNpuPayloadCopy.firstSectionCopyBlock ==\n    blaiGeneratedModelSectionCopyDestination" in npu_source
    assert "generatedShortNpuPayloadCopy.firstWindowBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedPreparedPayload.readyToConfigure" in npu_source
    assert "generatedPreparedMissingWeight.staged.copied" in npu_source
    assert "generatedPreparedMissingWeight.firstBlock ==\n    blaiGeneratedNpuPreparedPayloadStage" in npu_source
    assert "generatedPreparedMissingWeight.stagedFirstBlock ==\n    blaiGeneratedNpuStagedPayloadAddress" in npu_source
    assert "generatedPreparedMissingWeight.addressBlock ==\n    blaiGeneratedNpuPayloadAddressMissingWeight" in npu_source
    assert "generatedConfigurePlan.wouldApply" in npu_source
    assert "generatedConfigurePlan.firstBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "not generatedBlockedConfigurePlan.wouldApply" in npu_source
    assert "generatedBlockedConfigurePlan.firstBlock ==\n    blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "generatedRunPreflight.runnableAfterConfigure" in npu_source
    assert "generatedRunPreflight.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "not generatedBlockedRunPreflight.runnableAfterConfigure" in npu_source
    assert "generatedBlockedRunPreflight.configureBlock ==\n    blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "generatedPipeline.readyForHardwareConfigure" in npu_source
    assert "generatedPipeline.firstBlock == blaiGeneratedNpuPipelineNoBlock" in npu_source
    assert "generatedPipeline.preparedBlock ==\n    blaiGeneratedNpuPreparedPayloadNoBlock" in npu_source
    assert "generatedPipeline.packageBlock ==\n    blaiGeneratedModelPackagePreflightNoBlock" in npu_source
    assert "generatedPipeline.stagedBlock ==\n    blaiGeneratedNpuStagedPayloadNoBlock" in npu_source
    assert "generatedPipeline.payloadCopyBlock ==\n    blaiGeneratedNpuPayloadCopyNoBlock" in npu_source
    assert "generatedPipeline.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "generatedPipelineBadHeader.preparedBlock ==\n    blaiGeneratedNpuPreparedPayloadPackage" in npu_source
    assert "generatedPipelineBadHeader.packageBlock ==\n    blaiGeneratedModelPackagePreflightHeader" in npu_source
    assert "generatedPipelineBadHeader.firstBlock ==\n    blaiGeneratedNpuPipelinePackagePreflight" in npu_source
    assert "generatedPipelineBadHeader.configureBlock ==\n    blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "generatedPipelineShortWeight.preparedBlock ==\n    blaiGeneratedNpuPreparedPayloadStage" in npu_source
    assert "generatedPipelineShortWeight.stagedBlock ==\n    blaiGeneratedNpuStagedPayloadCopy" in npu_source
    assert "generatedPipelineShortWeight.payloadCopyBlock ==\n    blaiGeneratedNpuPayloadCopyWeight" in npu_source
    assert "generatedPipelineShortWeight.firstBlock ==\n    blaiGeneratedNpuPipelinePayloadStage" in npu_source
    assert "generatedPipelineShortWeight.configureBlock ==\n    blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "generatedPipelineMissingWeight.prepared.staged.copied" in npu_source
    assert (
        "generatedPipelineMissingWeight.firstBlock ==\n"
        "    blaiGeneratedNpuPipelineAddressPlan"
    ) in npu_source
    assert (
        "generatedPipelineMissingWeight.addressBlock ==\n"
        "    blaiGeneratedNpuPayloadAddressMissingWeight"
    ) in npu_source
    assert "generatedPipelineMissingWeight.preparedBlock ==\n    blaiGeneratedNpuPreparedPayloadStage" in npu_source
    assert "generatedPipelineMissingWeight.packageBlock ==\n    blaiGeneratedModelPackagePreflightNoBlock" in npu_source
    assert "generatedPipelineMissingWeight.stagedBlock ==\n    blaiGeneratedNpuStagedPayloadAddress" in npu_source
    assert "generatedPipelineMissingWeight.payloadCopyBlock ==\n    blaiGeneratedNpuPayloadCopyNoBlock" in npu_source
    assert "generatedPipelineMissingWeight.configureBlock ==\n    blaiGeneratedNpuConfigurePrepared" in npu_source
    assert "generatedConfiguredRunPlan.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "generatedUnconfiguredRunPlan.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "generatedBlockedRun.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert "generatedInstructionOnlyPipeline.readyForHardwareConfigure" in npu_source
    assert "generatedInstructionOnlyPipeline.preparedBlock ==\n    blaiGeneratedNpuPreparedPayloadNoBlock" in npu_source
    assert "generatedInstructionOnlyPipeline.stagedBlock ==\n    blaiGeneratedNpuStagedPayloadNoBlock" in npu_source
    assert "generatedInstructionOnlyPipeline.payloadCopyBlock ==\n    blaiGeneratedNpuPayloadCopyNoBlock" in npu_source
    assert "generatedInstructionOnlyPipeline.configureBlock ==\n    blaiGeneratedNpuConfigureNoBlock" in npu_source
    assert (
        "generatedInstructionOnlyPipeline.addressBlock ==\n"
        "    blaiGeneratedNpuPayloadAddressNoBlock"
    ) in npu_source
    assert "generatedInstructionOnlyPipeline.runBlock == npuLayerRunNoBlock" in (
        npu_source
    )
    assert "generatedInstructionOnlyPipeline.prepared.staged.payloadCopy.biasCopied" in npu_source
    assert "section.bytes == 0'u32 and section.ordered and section.withinBlob" in npu_source
    assert "not generatedShortNpuPayloadCopy.weightCopied" in npu_source
    assert "generatedPayloadAddressPlan.registerPlan.weightAddr ==\n    0x2200_6000'u32" in npu_source
    assert "generatedPayloadAddressPlan.registerPlan.biasAddr ==\n    0x2200_5000'u32" in npu_source
    assert "not generatedPayloadMissingBiasAddress.biasAddressPresent" in npu_source
    assert (
        "generatedPayloadMissingBiasAddress.firstBlock ==\n"
        "    blaiGeneratedNpuPayloadAddressMissingBias"
    ) in npu_source
    assert "generatedPayloadEmptyBiasAddress.biasAddressPresent" in npu_source
    assert (
        "generatedPayloadInvalidAddress.firstBlock ==\n"
        "    blaiGeneratedNpuPayloadAddressInvalidPayload"
    ) in npu_source
    assert "generatedStagedNpuPayload.readyToConfigure" in npu_source
    assert "generatedStagedNpuPayload.firstBlock ==\n    blaiGeneratedNpuStagedPayloadNoBlock" in npu_source
    assert "generatedStagedNpuPayload.payloadCopyBlock ==\n    blaiGeneratedNpuPayloadCopyNoBlock" in npu_source
    assert "generatedStagedNpuPayload.addressBlock ==\n    blaiGeneratedNpuPayloadAddressNoBlock" in npu_source
    assert "generatedStagedNpuPayload.registerPlan.weightAddr == 0x2200_9000'u32" in npu_source
    assert "not generatedStagedMissingWeightAddress.readyToConfigure" in npu_source
    assert "generatedStagedMissingWeightAddress.firstBlock ==\n    blaiGeneratedNpuStagedPayloadAddress" in npu_source
    assert "generatedStagedMissingWeightAddress.addressBlock ==\n    blaiGeneratedNpuPayloadAddressMissingWeight" in npu_source
    assert "if not staged.readyToConfigure:" in npu_source
    assert "npuApplyInstructionStreamRegisterPlan(outResult.registerPlan)" in npu_source
    assert "generatedConfiguredRunPlan.layerRun.waitPlan.timeout == 23" in npu_source
    assert "not generatedUnconfiguredRunPlan.layerRun.waitPlan.configured" in npu_source
    assert "generatedBlockedRun.status == npuUnsupported" in npu_source
    assert "generatedBlockedRun.firstBlock == npuLayerRunInstructionStream" in npu_source
    assert "if not plan.runnable:" in npu_source
    assert "generatedSectionCopyResult.copiedBytes == 0x10'u32" in npu_source
    assert "generatedSectionCopyResult.firstBlock ==\n    blaiGeneratedModelSectionCopyNoBlock" in npu_source
    assert "generatedSectionCopyResult.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedSectionCopyLastCursor.byteIndex == 0x0F" in npu_source
    assert "not generatedShortSectionCopyResult.destinationFits" in npu_source
    assert "generatedShortSectionCopyResult.firstBlock ==\n    blaiGeneratedModelSectionCopyDestination" in npu_source
    assert "generatedShortSectionCopyResult.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedParsedCopy.firstRecordKind == blaiCpuDspHeader" in npu_source
    assert "generatedParsedCopy.lastRecordKind == blaiCpuDspStatus" in npu_source
    assert "generatedParsedCopy.firstBlock ==\n    blaiGeneratedCpuRecordStreamCopyNoBlock" in npu_source
    assert "generatedParsedCopy.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedParsedShortCopy.firstBlock ==\n    blaiGeneratedCpuRecordStreamCopyStream" in npu_source
    assert "generatedParsedShortCopy.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedParsedLastRecordCursor.recordIndex == 3" in npu_source
    assert "generatedParsedRecordWindow.stopIndex == 3" in npu_source
    assert "generatedParsedResult.valid" in npu_source
    assert "generatedParsedResult.parsed.complete" in npu_source
    assert "generatedParsedResult.firstBlock ==\n    blaiGeneratedCpuRecordParseNoBlock" in npu_source
    assert "generatedParsedResult.copyFirstBlock ==\n    blaiGeneratedCpuRecordStreamCopyNoBlock" in npu_source
    assert "generatedParsedResult.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "generatedParsedNoLayerResult.firstBlock ==\n    blaiGeneratedCpuRecordParseInstructions" in npu_source
    assert "generatedParsedNoLayerResult.copyFirstBlock ==\n    blaiGeneratedCpuRecordStreamCopyNoBlock" in npu_source
    assert "generatedParsedNoLayerResult.windowFirstBlock ==\n    blaiGeneratedModelSectionWindowNoBlock" in npu_source
    assert "mnistGeneratedPackage.firstBlock ==\n    blaiMnistGeneratedPackageNoBlock" in npu_source
    assert "mnistGeneratedPackageMissingModel.firstBlock ==\n    blaiMnistGeneratedPackageModel" in npu_source
    assert "mnistGeneratedPackageMissingSample.firstBlock ==\n    blaiMnistGeneratedPackageSample" in npu_source
    assert "mnistGeneratedPackage.imageSidecar.firstBlock ==\n    blaiGeneratedImageSidecarNoBlock" in npu_source
    assert "mnistGeneratedPackageMissingSample.imageSidecar.firstBlock ==\n    blaiGeneratedImageSidecarSample" in npu_source
    assert "mnistSramReadiness.firstBlock ==\n    blaiMnistToolchainSramReadinessNoBlock" in npu_source
    assert "mnistSramReadiness.activePlannerBytes == 10_485_760'u32" in (
        npu_source
    )
    assert "mnistSramReadiness.cfgTotalBytes == 11_796_480'u32" in npu_source
    assert "mnistSramReadiness.sparePatchBytes == 1_310_720'u32" in npu_source
    assert "mnistSramReadiness.persistentTensorPatchSlots == 1'u32" in (
        npu_source
    )
    assert "mnistSramReadiness.persistentTensorSpareBytes == 225_844'u32" in (
        npu_source
    )
    assert "mnistSramReadinessMissingPackage.firstBlock ==\n    blaiMnistToolchainSramReadinessPackage" in npu_source
    assert "mnistSramReadinessMissingGlobals.firstBlock ==\n    blaiMnistToolchainSramReadinessGlobals" in npu_source
    assert "mnistConverterGeneration.firstBlock ==\n    blaiMnistConverterGenerationExecution" in npu_source
    assert "mnistConverterGenerationMissingPackage.firstBlock ==\n    blaiMnistConverterGenerationPackage" in npu_source
    assert "mnistConverterGenerationMissingSram.firstBlock ==\n    blaiMnistConverterGenerationSramReadiness" in npu_source
    assert "mnistGeneratedPackage.valid" in npu_source
    assert "mnistGeneratedPackage.imageSidecar.imageBytes == 1862'u32" in npu_source
    assert "mnistGeneratedPackage.imageSidecar.imageDigest ==\n    BlaiMnistTfliteSampleImageDigest" in npu_source
    assert "mnistGeneratedPackage.imageSidecar.digestMatches" in npu_source
    assert "mnistGeneratedPackage.converterReady" in npu_source
    assert "mnistGeneratedPackage.cfgReady" in npu_source
    assert "mnistConverterGeneration.converterExecutionBlocked" in npu_source
    assert "mnistConverterGeneration.dependencyPlan == converterDependencyPlan" in (
        npu_source
    )
    assert "converterArtifactRegeneration.firstBlock ==\n    blaiToolchainConverterArtifactRegenerationDependencies" in (
        npu_source
    )
    assert "mnistConverterGeneration.artifactRegeneration ==\n    converterArtifactRegeneration" in (
        npu_source
    )
    assert "mnistConverterGeneration.frameworkMissingCount == 5'u32" in npu_source
    assert "mnistConverterGeneration.nnapiMissingCount == 3'u32" in npu_source
    assert "mnistConverterGeneration.openCvMissingCount == 4'u32" in npu_source
    assert "not mnistConverterGeneration.canGenerateArtifacts" in npu_source
    assert "mnistConverterGeneration.generatedArtifactsNotRegenerated" in npu_source
    assert "cpuWeightBytes.len.uint32" not in npu_source
    assert "cpuBiasBytes.len.uint32" not in npu_source
    assert "decodedWeightElements = decodedWeights.len.uint32" not in npu_source
    assert "decodedBiasElements = decodedBiases.len.uint32" not in npu_source
    assert "scratchAElements = scratchA.len.uint32" not in npu_source
    assert "scratchBElements = scratchB.len.uint32" not in npu_source
    assert "    outputElements = output.len.uint32" not in npu_source
    assert "modelInputElements = input.len.uint32" not in npu_source
    assert "blaiOpenArrayLenU32(stream)" in npu_source
    assert "blaiOpenArrayLenU32(instructions)" in npu_source
    assert "blaiOpenArrayLenU32(weightBytes)" in npu_source
    assert "blaiOpenArrayLenU32(weightBytesIn)" in npu_source
    assert "blaiOpenArrayLenU32(biases)" in npu_source
    assert "blaiOpenArrayLenU32(biasInts)" in npu_source
    assert "outResult.expectedElements = blaiOpenArrayLenU32(expected)" in npu_source
    assert "outResult.actualElements = blaiOpenArrayLenU32(actual)" in npu_source
    assert "outResult.outputElements = blaiOpenArrayLenU32(output)" in npu_source
    assert "outResult.comparedElements = blaiBufferLenU32(compared)" in npu_source
    assert "outResult.trailingElements = blaiBufferLenU32(trailing)" in npu_source
    assert "outResult.copiedElements = blaiBufferLenU32(copied)" in npu_source
    assert "outResult.convertedElements = blaiBufferLenU32(converted)" in npu_source
    assert "let layerCapacity = blaiOpenArrayLenU32(layers)" in npu_source
    assert "result.layerCount = blaiOpenArrayLenU32(layers)" in npu_source
    assert "proc blaiRecoveredLayerCursor*(layerIndex: uint32" in npu_source
    assert "let layerCursor = blaiRecoveredLayerCursor(layerIndex, layers.len)" in npu_source
    assert "let parsed = layers[layerCursor.index]" in npu_source
    assert "let layer = layers[layerCursor.index]" in npu_source
    assert "let layer = layers[layerCursor.index].layer" in npu_source
    assert "layers[layerCursor.index], ctrl, stream, modelResources" in npu_source
    assert "layers[layerCursor.index].layer, ctrl, stream, modelResources" in npu_source
    assert "blaiOpenArrayLenU32(layers), outResult)" in npu_source
    assert "result.itemCount = blaiOpenArrayLenU32(schedule)" in npu_source
    assert "BlaiU32ArrayIndexCursor* = object" in npu_source
    assert "BlaiCpuExtraStorageCursor* = object" in npu_source
    assert "BlaiLogicalInputSlotCursor* = object" in npu_source
    assert "BlaiCpuStreamStartCursor* = object" in npu_source
    assert "BlaiYoloBiasPairIndex* = object" in npu_source
    assert "BlaiYoloBiasPairCursor* = object" in npu_source
    assert "BlaiReleaseSlotCursor* = object" in npu_source
    assert "BlaiGraphLayerMapCursor* = object" in npu_source
    assert "proc blaiU32ArrayIndexCursor*(index: uint32" in npu_source
    assert "proc blaiI32ArrayIndexCursor*(index: int32" in npu_source
    assert "proc blaiLogicalInputSlotCursor*(inputIndex, firstInput: uint32" in npu_source
    assert "proc blaiCpuExtraPackedInputCursor*(inputIndex, firstInput: uint32" in npu_source
    assert "proc blaiCpuExtraDecodedInputCursor*(inputIndex: uint32" in npu_source
    assert "proc blaiCpuParsedLayerStorageCursor*(layerIndex: uint32" in npu_source
    assert "proc blaiCpuParsedExtraStorageCursor*(layerIndex: uint32" in npu_source
    assert "proc blaiCpuParsedYoloStorageCursor*(layerIndex: uint32" in npu_source
    assert "proc blaiCpuParsedStateStorageCursor*(layerIndex: uint32" in npu_source
    assert "proc blaiCpuExtraStorageCursor*(inputIndex: uint32" in npu_source
    assert "proc blaiYoloBiasPairIndex*(maskIndex, total: uint32)" in npu_source
    assert "proc blaiYoloActiveMaskCursor*(maskIndex: uint32)" in npu_source
    assert "proc blaiYoloBiasStorageCursor*(biasIndex: uint32)" in npu_source
    assert "proc blaiYoloBiasPairCursor*(maskIndex, total: uint32)" in npu_source
    yolo_cursor_block = re.search(
        r"proc blaiYoloBiasPairCursor\*\(.*?proc blaiStoreYoloBiasPair\*",
        npu_source,
        re.S,
    )
    assert yolo_cursor_block is not None
    assert "let pairIndex = blaiYoloBiasPairIndex(maskIndex, total)" in (
        yolo_cursor_block.group(0)
    )
    assert "maskIndex * 2'u32" not in yolo_cursor_block.group(0)
    assert "widthIndex + 1'u32" not in yolo_cursor_block.group(0)
    assert "proc blaiReleaseSlotCursor*(slot: int32" in npu_source
    assert "proc blaiGraphLayerMapCursor*(graphLayer: int32" in npu_source
    assert "proc blaiRouteDescriptorStepCursor*(index: uint32" in npu_source
    assert "proc blaiWeightPatchCursor*(patchIndex: uint32" in npu_source
    assert "proc blaiReferenceRouteInputCursor*(inputIndex: uint32" in npu_source
    assert "proc blaiForwardInputCursor*(inputIndex: uint32" in npu_source
    assert "proc blaiInstructionStreamCursor*(instructionIndex: uint32" in npu_source
    assert "proc blaiInstructionStreamStartCursor*(instructionIndex: uint32" in npu_source
    assert "proc blaiByteBufferCursor*(byteIndex: uint32" in npu_source
    assert "proc blaiCpuStreamStartCursor*(cursor: BlaiCpuStreamCursor)" in npu_source
    assert "proc blaiCpuStreamLayerCursor*(layerIndex: int32" in npu_source
    assert "proc blaiCpuStreamStartLayerCursor*(cursor: BlaiCpuStreamCursor" in npu_source
    assert "let layerCursor = blaiCpuParsedLayerStorageCursor(index, layers.len)" in npu_source
    assert "let extraCursor = blaiCpuParsedExtraStorageCursor(index, extraInputs.len)" in npu_source
    assert "let yoloCursor = blaiCpuParsedYoloStorageCursor(index, yoloStorage.len)" in npu_source
    assert "let layerCursor = blaiU32ArrayIndexCursor(index, layers.len)" not in npu_source
    assert "let extraCursor = blaiU32ArrayIndexCursor(index, extraInputs.len)" not in npu_source
    assert "let yoloCursor = blaiU32ArrayIndexCursor(index, yoloStorage.len)" not in npu_source
    assert "let layerCursor = blaiCpuStreamLayerCursor(index, layers.len)" in npu_source
    assert "let layerCursor = blaiI32ArrayIndexCursor(index, layers.len)" not in npu_source
    for cursor_name in ("blaiCpuExtraStorageCursor", "blaiLayerCnCursor"):
        cursor_block = re.search(
            rf"proc {cursor_name}\*\(.*?proc ",
            npu_source,
            re.S,
        )
        assert cursor_block is not None
        assert "blaiLogicalInputSlotCursor" in cursor_block.group(0)
        assert "inputIndex - 1'u32" not in cursor_block.group(0)
        assert "inputIndex - 2'u32" not in cursor_block.group(0)
    for cursor_name in ("blaiCpuExtraLayerEntryCursor", "blaiCpuExtraMultiplierEntryCursor"):
        cursor_block = re.search(
            rf"proc {cursor_name}\*\(.*?proc ",
            npu_source,
            re.S,
        )
        assert cursor_block is not None
        assert "blaiCpuExtraPackedInputCursor(inputIndex, firstInput)" in (
            cursor_block.group(0)
        )
        assert "inputIndex - firstInput" not in cursor_block.group(0)
        assert "blaiU32ArrayIndexCursor(packedIndex, BlaiMaxInputNum)" not in (
            cursor_block.group(0)
        )
    extra_layer_decode_block = re.search(
        r"proc decodeBlaiCpuExtraLayer\*\(.*?"
        r"proc blaiCpuExtraMultiplierEntryCursor\*",
        npu_source,
        re.S,
    )
    assert extra_layer_decode_block is not None
    assert "let inputCursor = blaiCpuExtraDecodedInputCursor(inputIndex)" in (
        extra_layer_decode_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, BlaiMaxInputNum)" not in (
        extra_layer_decode_block.group(0)
    )
    extra_multiplier_decode_block = re.search(
        r"proc decodeBlaiCpuExtraMultiplier\*\(.*?"
        r"proc blaiLogicalInputSlotCursor\*",
        npu_source,
        re.S,
    )
    assert extra_multiplier_decode_block is not None
    assert "let inputCursor = blaiCpuExtraDecodedInputCursor(inputIndex)" in (
        extra_multiplier_decode_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, BlaiMaxInputNum)" not in (
        extra_multiplier_decode_block.group(0)
    )
    extra_multiplier_apply_block = re.search(
        r"proc applyBlaiCpuExtraMultiplier\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert extra_multiplier_apply_block is not None
    assert "let inputCursor = blaiCpuExtraDecodedInputCursor(inputIndex)" in (
        extra_multiplier_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, BlaiMaxInputNum)" not in (
        extra_multiplier_apply_block.group(0)
    )
    assert "let startLayer = blaiCpuStreamStartLayerCursor(cursor, layers.len)" in npu_source
    assert "blaiCpuWeightStreamPlanInto(layers, startLayer.index, outResult.plan)" in npu_source
    assert "blaiCpuBiasStreamPlanInto(layers, startLayer.index, useTflite, outResult.plan)" in npu_source
    assert "This handles recovered scalar and graph-bookkeeping records" in npu_source
    assert "of blaiCpuInputLayers:" in npu_source
    assert "of blaiCpuTfliteMultiplier:" in npu_source
    assert "of blaiCpuTfliteFloat:" in npu_source
    assert "of blaiCpuSsdInfo:" in npu_source
    assert "applyBlaiCpuInputLayers(" in npu_source
    assert "applyBlaiCpuTfliteMultiplier(" in npu_source
    assert "applyBlaiCpuTfliteFloat(" in npu_source
    assert "applyBlaiCpuSsdInfo(" in npu_source
    assert "BlaiMemoryPlanApplyPlan* = object" in npu_source
    assert "BlaiMemoryPlanApplyEvidence* = object" in npu_source
    assert "BlaiMemoryPlanState* = object" in npu_source
    assert "BlaiMemoryPlanBufSizeAbi* = object" in npu_source
    assert "BlaiEncodeStartApplyPlan* = object" in npu_source
    assert "BlaiEncodeStartState* = object" in npu_source
    assert "BlaiEncodeFailureApplyPlan* = object" in npu_source
    assert "BlaiEncodeFailureState* = object" in npu_source
    assert "proc blaiMemoryPlanApplyPlan*(" in npu_source
    assert "proc blaiMemoryPlanApplyEvidence*(" in npu_source
    assert "proc blaiMemoryPlanBufSizeAbi*" in npu_source
    assert "proc blaiMemoryPlanState*(" in npu_source
    assert "proc blaiApplyMemoryPlanState*" in npu_source
    assert "proc blaiEncodeStartApplyPlan*()" in npu_source
    assert "proc blaiEncodeStartState*(" in npu_source
    assert "proc blaiApplyEncodeStartState*" in npu_source
    assert "proc blaiEncodeFailureApplyPlan*()" in npu_source
    assert "proc blaiEncodeFailureState*(" in npu_source
    assert "proc blaiApplyEncodeFailureState*" in npu_source
    assert "let applyPlan = blaiMemoryPlanApplyPlan(layer, ctrl)" in npu_source
    assert "blaiApplyMemoryPlanState(layer, blaiMemoryPlanState(applyPlan))" in (
        npu_source
    )
    assert "let applyPlan = blaiEncodeFailureApplyPlan()" in npu_source
    assert "blaiApplyEncodeFailureState(layer, blaiEncodeFailureState(applyPlan))" in (
        npu_source
    )
    assert "let startApply = blaiEncodeStartApplyPlan()" in npu_source
    assert "blaiApplyEncodeStartState(" in npu_source
    memory_plan_evidence_block = re.search(
        r"proc blaiMemoryPlanApplyEvidence\*\(.*?"
        r"proc blaiMemoryPlanApplyPlan\*",
        npu_source,
        re.S,
    )
    assert memory_plan_evidence_block is not None
    assert "let patchSize = blaiAllocatorFieldAbi(" in (
        memory_plan_evidence_block.group(0)
    )
    assert "let bufSize = blaiMemoryPlanBufSizeAbi(bufSize64)" in (
        memory_plan_evidence_block.group(0)
    )
    assert "result.bufSize = bufSize.value" in (
        memory_plan_evidence_block.group(0)
    )
    assert "result.dramPatchSize = patchSize.value" in (
        memory_plan_evidence_block.group(0)
    )
    memory_plan_block = re.search(
        r"proc blaiMemoryPlanApplyPlan\*\(.*?"
        r"proc blaiMemoryPlanState\*\(",
        npu_source,
        re.S,
    )
    assert memory_plan_block is not None
    assert "let evidence = blaiMemoryPlanApplyEvidence(layer, ctrl)" in (
        memory_plan_block.group(0)
    )
    assert "evidence.bufSize" in memory_plan_block.group(0)
    assert "evidence.dramPatchSize" in memory_plan_block.group(0)
    assert "blaiAllocatorFieldAbi(" not in memory_plan_block.group(0)
    assert "blaiMemoryPlanBufSizeAbi(bufSize64)" not in memory_plan_block.group(0)
    assert "bufSize64.int32" not in memory_plan_block.group(0)
    memory_apply_block = re.search(
        r"proc blaiApplyMemoryPlan\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert memory_apply_block is not None
    assert "layer.npuOn = 1" not in memory_apply_block.group(0)
    assert "layer.bufSize = layer.dramPatchNum * ctrl.psramPatchSize" not in (
        memory_apply_block.group(0)
    )
    assert "layer.dramIn = ctrl.sramIn" not in memory_apply_block.group(0)
    assert "layer.dramOut = ctrl.sramOut" not in memory_apply_block.group(0)
    assert "layer.dramPatchSize = ctrl.psramPatchSize" not in (
        memory_apply_block.group(0)
    )
    mark_failed_block = re.search(
        r"proc blaiMarkEncodeFailed\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert mark_failed_block is not None
    assert "layer.npuOn = 0" not in mark_failed_block.group(0)
    encode_wrapper_block = re.search(
        r"proc blaiEncodeCpuLayerInto\*\(.*?"
        r"proc blaiEncodeCpuLayer\*",
        npu_source,
        re.S,
    )
    assert encode_wrapper_block is not None
    assert "let startApply = blaiEncodeStartApplyPlan()" in (
        encode_wrapper_block.group(0)
    )
    assert "blaiEncodeStartState(startApply)" in encode_wrapper_block.group(0)
    assert "outResult.scratchCleared = true" not in encode_wrapper_block.group(0)
    assert "layer.instCnt = 0" not in encode_wrapper_block.group(0)
    assert "BlaiFetchInputPatchCursor* = object" in npu_source
    assert "proc blaiFetchInputPatchCursor*(" in npu_source
    assert "proc blaiFetchInputStorageCursor*" in npu_source
    assert "let inputPatch = blaiFetchInputPatchCursor(" in npu_source
    assert "result.inputPatchCount[inputPatch.slotIndex] = inputPatch.patchCount" in npu_source
    assert "totalInputPatches = inputPatch.nextTotalPatches" in npu_source
    assert "outResult.inputPatchCount[inputCursor.index] = patchCount" not in npu_source
    assert "totalInputPatches += patchCount" not in npu_source
    assert "BlaiFetchInputSlotCursor* = object" in npu_source
    assert "BlaiFetchInputSlotsPlan* = object" in npu_source
    assert "proc blaiFetchInputSlotCursor*(" in npu_source
    assert "proc blaiFetchInputSlotsPlan*(" in npu_source
    assert "let inputSlot = blaiFetchInputSlotCursor(" in npu_source
    assert "result.inputSlots[inputSlot.slotIndex] = inputSlot.slot" in npu_source
    assert "result.inputSlots = inputSlots.inputSlots" in npu_source
    assert "outResult.inputSlots = slotLayout.inputSlots" in npu_source
    assert "cursor = inputSlot.nextSlot" in npu_source
    assert "outResult.inputSlots[inputCursor.index] = cursor" not in npu_source
    assert "cursor += outResult.inputPatchCount[inputCursor.index]" not in npu_source
    fetch_input_patch_block = re.search(
        r"proc blaiFetchInputPatchCursor\*\(.*?"
        r"proc blaiFetchInputSlotCursor\*",
        npu_source,
        re.S,
    )
    assert fetch_input_patch_block is not None
    assert "let inputCursor = blaiFetchMemoryInputSlotCursor(inputIndex)" in (
        fetch_input_patch_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, BlaiMaxInputNum)" not in (
        fetch_input_patch_block.group(0)
    )
    fetch_input_slot_cursor_block = re.search(
        r"proc blaiFetchInputSlotCursor\*\(.*?"
        r"proc blaiFetchInputSlotsPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_input_slot_cursor_block is not None
    assert "blaiFetchInputStorageCursor(inputIndex, inputPatchCount.len)" in (
        fetch_input_slot_cursor_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, inputPatchCount.len)" not in (
        fetch_input_slot_cursor_block.group(0)
    )
    assert "BlaiFetchOutputSlotPlan* = object" in npu_source
    assert "proc blaiFetchOutputSlotPlan*(" in npu_source
    assert "BlaiFetchLayerApplyPlan* = object" in npu_source
    assert "BlaiFetchLayerApplyEvidence* = object" in npu_source
    assert "proc blaiFetchLayerApplyPlan*(" in npu_source
    assert "proc blaiFetchLayerApplyEvidence*(" in npu_source
    assert "BlaiFetchSramSlotsClearApplyPlan* = object" in npu_source
    assert "proc blaiFetchSramSlotsClearApplyPlan*()" in npu_source
    assert "BlaiFetchInputSlotApplyPlan* = object" in npu_source
    assert "proc blaiFetchInputSlotApplyPlan*(" in npu_source
    assert "BlaiFetchInputSlotsApplyPlan* = object" in npu_source
    assert "BlaiFetchInputSlotsApplyEvidence* = object" in npu_source
    assert "proc blaiFetchInputSlotsApplyPlan*(" in npu_source
    assert "proc blaiFetchInputSlotsApplyEvidence*(" in npu_source
    assert "BlaiFetchOutputSlotApplyPlan* = object" in npu_source
    assert "BlaiFetchOutputSlotApplyEvidence* = object" in npu_source
    assert "proc blaiFetchOutputSlotApplyPlan*(" in npu_source
    assert "proc blaiFetchOutputSlotApplyEvidence*(" in npu_source
    assert "BlaiFetchPatchSizeApplyPlan* = object" in npu_source
    assert "proc blaiFetchPatchSizeApplyPlan*(" in npu_source
    assert "let outputSlots = blaiFetchOutputSlotPlan(" in npu_source
    assert "result.midOutputSlot = outputSlots.midOutputSlot" in npu_source
    assert "result.outputSlot = outputSlots.outputSlot" in npu_source
    assert "result.dramPatchCount = outputSlots.dramPatchCount" in npu_source
    assert "outResult.midOutputSlot = slotLayout.midOutputSlot" in npu_source
    assert "outResult.outputSlot = slotLayout.outputSlot" in npu_source
    assert "outResult.dramPatchCount = slotLayout.dramPatchCount" in npu_source
    assert "BlaiFetchLayerState* = object" in npu_source
    assert "BlaiFetchSramSlotsClearState* = object" in npu_source
    assert "BlaiFetchInputSlotState* = object" in npu_source
    assert "BlaiFetchInputSlotsState* = object" in npu_source
    assert "BlaiFetchOutputSlotState* = object" in npu_source
    assert "BlaiFetchPatchSizeState* = object" in npu_source
    assert "proc blaiFetchLayerState*(" in npu_source
    assert "proc blaiFetchSramSlotsClearState*(" in npu_source
    assert "proc blaiFetchInputSlotState*(" in npu_source
    assert "proc blaiFetchInputSlotsState*(" in npu_source
    assert "proc blaiFetchOutputSlotState*(" in npu_source
    assert "proc blaiFetchPatchSizeState*(" in npu_source
    assert "proc blaiApplyFetchLayerState*" in npu_source
    assert "proc blaiApplyFetchSramSlotsClearState*" in npu_source
    assert "proc blaiApplyFetchInputSlotState*" in npu_source
    assert "proc blaiApplyFetchInputSlotsState*" in npu_source
    assert "proc blaiApplyFetchOutputSlotState*" in npu_source
    assert "proc blaiApplyFetchPatchSizeState*" in npu_source
    assert "let clearApply = blaiFetchSramSlotsClearApplyPlan()" in npu_source
    assert "blaiApplyFetchSramSlotsClearState(" in npu_source
    assert "let inputApply = blaiFetchInputSlotApplyPlan(" in npu_source
    assert "blaiApplyFetchInputSlotState(" in npu_source
    assert "let inputSlotsApply = blaiFetchInputSlotsApplyPlan(" in npu_source
    assert "blaiApplyFetchInputSlotsState(" in npu_source
    assert "let outputApply = blaiFetchOutputSlotApplyPlan(" in npu_source
    assert "blaiApplyFetchOutputSlotState(" in npu_source
    assert "let patchSizeApply = blaiFetchPatchSizeApplyPlan(" in npu_source
    assert "blaiApplyFetchPatchSizeState(" in npu_source
    assert "let layerApply = blaiFetchLayerApplyPlan(plan.dramPatchCount)" in npu_source
    assert "blaiApplyFetchLayerState(layer, blaiFetchLayerState(layerApply))" in (
        npu_source
    )
    fetch_layer_evidence_block = re.search(
        r"proc blaiFetchLayerApplyEvidence\*\(.*?"
        r"proc blaiFetchLayerApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_layer_evidence_block is not None
    assert "let dramPatchNum = blaiAllocatorFieldAbi(dramPatchCount)" in (
        fetch_layer_evidence_block.group(0)
    )
    assert "result.dramPatchNum = dramPatchNum.value" in (
        fetch_layer_evidence_block.group(0)
    )
    fetch_layer_apply_block = re.search(
        r"proc blaiFetchLayerApplyPlan\*\(.*?"
        r"proc blaiFetchLayerState\*",
        npu_source,
        re.S,
    )
    assert fetch_layer_apply_block is not None
    assert "let evidence = blaiFetchLayerApplyEvidence(dramPatchCount)" in (
        fetch_layer_apply_block.group(0)
    )
    assert "result.dramPatchNum = evidence.dramPatchNum" in (
        fetch_layer_apply_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(dramPatchCount)" not in (
        fetch_layer_apply_block.group(0)
    )
    fetch_memory_block = re.search(
        r"proc blaiPlanFetchMemoryInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert fetch_memory_block is not None
    assert "outResult.inputSlots[inputSlot.slotIndex]" not in (
        fetch_memory_block.group(0)
    )
    assert "outResult.midOutputSlot + nonNegativeU32(ctrl.psramMidPatchCount)" not in (
        fetch_memory_block.group(0)
    )
    assert "outResult.outputSlot + nonNegativeU32(ctrl.psramPatchCount)" not in (
        fetch_memory_block.group(0)
    )
    fetch_apply_block = re.search(
        r"proc blaiApplyFetchMemoryPlan\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert fetch_apply_block is not None
    assert "layer.dramPatchNum = blaiAllocatorFieldValue(plan.dramPatchCount)" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.sramIn[inputIndex] =\n      blaiAllocatorFieldValue(plan.inputSlots[inputIndex])" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.sramMidOut = blaiAllocatorFieldValue(plan.midOutputSlot)" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.sramOut[0] = blaiAllocatorFieldValue(plan.outputSlot)" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = blaiAllocatorFieldValue(plan.patchSize)" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.sramIn[i] = 0" not in fetch_apply_block.group(0)
    assert "ctrl.sramOut[i] = 0" not in fetch_apply_block.group(0)
    assert "ctrl.sramIn[inputApply.slotIndex] = inputApply.sramSlot" not in (
        fetch_apply_block.group(0)
    )
    assert "blaiFetchInputSlotApplyPlan(" not in fetch_apply_block.group(0)
    assert "blaiApplyFetchInputSlotState(" not in fetch_apply_block.group(0)
    assert "ctrl.sramMidOut = outputApply.sramMidOut" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.sramOut[0] = outputApply.sramOut0" not in (
        fetch_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = patchSizeApply.patchSize" not in (
        fetch_apply_block.group(0)
    )
    fetch_input_slot_apply_plan_block = re.search(
        r"proc blaiFetchInputSlotApplyPlan\*\(.*?"
        r"proc blaiFetchInputSlotsApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_input_slot_apply_plan_block is not None
    assert "blaiFetchInputStorageCursor(inputIndex, inputSlots.len)" in (
        fetch_input_slot_apply_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, inputSlots.len)" not in (
        fetch_input_slot_apply_plan_block.group(0)
    )
    fetch_input_slots_evidence_block = re.search(
        r"proc blaiFetchInputSlotsApplyEvidence\*\(.*?"
        r"proc blaiFetchInputSlotsApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_input_slots_evidence_block is not None
    assert "let inputApply = blaiFetchInputSlotApplyPlan(" in (
        fetch_input_slots_evidence_block.group(0)
    )
    assert "result.slots[inputApply.slotIndex] =" in (
        fetch_input_slots_evidence_block.group(0)
    )
    fetch_input_slots_apply_plan_block = re.search(
        r"proc blaiFetchInputSlotsApplyPlan\*\(.*?"
        r"proc blaiFetchInputSlotsState\*",
        npu_source,
        re.S,
    )
    assert fetch_input_slots_apply_plan_block is not None
    assert "let evidence = blaiFetchInputSlotsApplyEvidence(" in (
        fetch_input_slots_apply_plan_block.group(0)
    )
    assert "result.slots = evidence.slots" in (
        fetch_input_slots_apply_plan_block.group(0)
    )
    assert "let inputApply = blaiFetchInputSlotApplyPlan(" not in (
        fetch_input_slots_apply_plan_block.group(0)
    )
    fetch_output_slot_evidence_block = re.search(
        r"proc blaiFetchOutputSlotApplyEvidence\*\(.*?"
        r"proc blaiFetchOutputSlotApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_output_slot_evidence_block is not None
    assert "midOut = blaiAllocatorFieldAbi(midOutputSlot)" in (
        fetch_output_slot_evidence_block.group(0)
    )
    assert "out0 = blaiAllocatorFieldAbi(outputSlot)" in (
        fetch_output_slot_evidence_block.group(0)
    )
    assert "result.sramMidOut = midOut.value" in (
        fetch_output_slot_evidence_block.group(0)
    )
    fetch_output_slot_apply_plan_block = re.search(
        r"proc blaiFetchOutputSlotApplyPlan\*\(.*?"
        r"proc blaiFetchOutputSlotState\*",
        npu_source,
        re.S,
    )
    assert fetch_output_slot_apply_plan_block is not None
    assert "let evidence =" in fetch_output_slot_apply_plan_block.group(0)
    assert "result.sramMidOut = evidence.sramMidOut" in (
        fetch_output_slot_apply_plan_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(midOutputSlot)" not in (
        fetch_output_slot_apply_plan_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(outputSlot)" not in (
        fetch_output_slot_apply_plan_block.group(0)
    )
    assert "BlaiFetchPatchSizeApplyEvidence* = object" in npu_source
    assert "proc blaiFetchPatchSizeApplyEvidence*(" in npu_source
    fetch_patch_size_evidence_block = re.search(
        r"proc blaiFetchPatchSizeApplyEvidence\*\(.*?"
        r"proc blaiFetchPatchSizeApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_patch_size_evidence_block is not None
    assert "let field = blaiAllocatorFieldAbi(patchSize)" in (
        fetch_patch_size_evidence_block.group(0)
    )
    assert "result.patchSize = field.value" in (
        fetch_patch_size_evidence_block.group(0)
    )
    fetch_patch_size_apply_plan_block = re.search(
        r"proc blaiFetchPatchSizeApplyPlan\*\(.*?"
        r"proc blaiFetchPatchSizeState\*",
        npu_source,
        re.S,
    )
    assert fetch_patch_size_apply_plan_block is not None
    assert (
        "let evidence = blaiFetchPatchSizeApplyEvidence(patchSize)"
        in fetch_patch_size_apply_plan_block.group(0)
    )
    assert "result.patchSize = evidence.patchSize" in (
        fetch_patch_size_apply_plan_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(patchSize)" not in (
        fetch_patch_size_apply_plan_block.group(0)
    )
    assert "layer.dramPatchNum = layerApply.dramPatchNum" not in (
        fetch_apply_block.group(0)
    )
    assert "BlaiRouteDescriptorNextInputCursor* = object" in npu_source
    assert "proc blaiRouteDescriptorNextInputCursor*(" in npu_source
    assert "result.logicalInput = stepIndex + 1'u32" in npu_source
    assert "result.cnSlot = stepCursor.index" in npu_source
    assert "let nextInput = blaiRouteDescriptorNextInputCursor(" in npu_source
    assert "outResult.steps[nextInput.cnSlot] = BlaiRouteDescriptorStep" in npu_source
    assert "layer.cn[nextInput.cnSlot]" in npu_source
    assert "index + 1'u32 < nonNegativeU32(layer.inputNum)" not in npu_source
    assert "BlaiRouteDescriptorLoopCount* = object" in npu_source
    assert "proc blaiRouteDescriptorLoopCount*" in npu_source
    assert "count*: BlaiRouteDescriptorLoopCount" in npu_source
    assert "let loopCount = blaiRouteDescriptorLoopCount(" in npu_source
    assert "outResult.count = loopCount" in npu_source
    assert "outResult.descriptorCount = inputCount - 1'u32" not in npu_source
    assert "BlaiRouteDescriptorStepPosition* = object" in npu_source
    assert "proc blaiRouteDescriptorStepPosition*(" in npu_source
    assert "let stepCursor = blaiRouteDescriptorStepCursor(stepIndex)" in npu_source
    assert "result.stepSlot = stepCursor.index" in npu_source
    assert "result.last = stepIndex == loopCount.lastStepIndex" in npu_source
    assert "result.position =" in npu_source
    assert "blaiRouteDescriptorStepPosition(stepIndex, routeLoop.count)" in npu_source
    assert (
        "blaiRouteDescriptorStepPosition(stepIndex, routeLoop.descriptorCount)"
        not in npu_source
    )
    assert "result.step = routeLoop.steps[result.position.stepSlot]" in npu_source
    assert "descriptorHalt = descriptorHalt and result.position.last" in npu_source
    assert "stepIndex + 1'u32 == routeLoop.descriptorCount" not in npu_source
    assert "let packedCursor = blaiCpuExtraPackedInputCursor(inputIndex, firstInput)" in npu_source
    assert npu_source.count(
        "let packedCursor = blaiCpuExtraPackedInputCursor(inputIndex, firstInput)"
    ) >= 2
    assert "let packedCursor = blaiU32ArrayIndexCursor(packedIndex, BlaiMaxInputNum)" not in npu_source
    assert "result.packedIndex = packedCursor.index" in npu_source
    assert "let storageCursor = blaiCpuExtraStorageCursor(input.inputIndex)" in npu_source
    assert "let storageCursor = blaiCpuExtraStorageCursor(inputIndex)" in npu_source
    assert "storage.inLayerMemN[storageCursor.storageIndex]" in npu_source
    assert "storage.tfInputMultiplierExtra[storageCursor.storageIndex]" in npu_source
    assert "activeIndex*: int" in npu_source
    assert (
        "let activeCursor = blaiYoloActiveMaskCursor(pairIndex.maskIndex)"
        in npu_source
    )
    assert (
        "let widthCursor = blaiYoloBiasStorageCursor(pairIndex.widthIndex)"
        in npu_source
    )
    assert (
        "let heightCursor = blaiYoloBiasStorageCursor(pairIndex.heightIndex)"
        in npu_source
    )
    assert "blaiU32ArrayIndexCursor(pairIndex.maskIndex, BlaiMaxYoloTotal)" not in npu_source
    assert "blaiU32ArrayIndexCursor(pairIndex.widthIndex, BlaiMaxYoloBiasNum)" not in npu_source
    assert "blaiU32ArrayIndexCursor(\n    pairIndex.heightIndex, BlaiMaxYoloBiasNum)" not in npu_source
    assert "result.activeIndex = activeCursor.index" in npu_source
    assert "result.widthIndex = widthCursor.index" in npu_source
    assert "result.heightIndex = heightCursor.index" in npu_source
    assert "storage.biasPairActive[cursor.activeIndex] = true" in npu_source
    assert "result.multipliers[inputCursor.index]" in npu_source
    assert "proc blaiRouteSramSlotCursor*(slot: uint32)" in npu_source
    assert "let cursor = blaiRouteSramSlotCursor(slot)" in npu_source
    assert "let cursor = blaiU32ArrayIndexCursor(slot, BlaiMaxInputNum)" not in npu_source
    assert "result.slotIndex = cursor.index" in npu_source
    assert "BlaiRouteNextSlotIndex* = object" in npu_source
    assert "BlaiRoutePreviousOutputSlotIndex* = object" in npu_source
    assert "BlaiRoutePreviousOutputSlotCursor* = object" in npu_source
    assert "BlaiRouteOutputSlotCursor* = object" in npu_source
    assert "BlaiRouteInputPatchTotalCursor* = object" in npu_source
    assert "BlaiRouteInputPatchTotalPlan* = object" in npu_source
    assert "BlaiRouteFirstOutputSlotPlan* = object" in npu_source
    assert "BlaiRouteIntermediateChannelCursor* = object" in npu_source
    assert "BlaiRouteIntermediateOutputSlotPlan* = object" in npu_source
    assert "BlaiRouteIntermediateOutputSlotsPlan* = object" in npu_source
    assert "BlaiRouteSramLayerApplyPlan* = object" in npu_source
    assert "BlaiRouteSramLayerApplyEvidence* = object" in npu_source
    assert "BlaiRouteSramLayerState* = object" in npu_source
    assert "BlaiRouteOutputSlotApplyPlan* = object" in npu_source
    assert "BlaiRouteOutputSlotApplyEvidence* = object" in npu_source
    assert "BlaiRouteOutputSlotState* = object" in npu_source
    assert "BlaiRouteOutputSlotsApplyPlan* = object" in npu_source
    assert "BlaiRouteOutputSlotsState* = object" in npu_source
    assert "proc blaiRouteNextSlotIndex*(slot: uint32)" in npu_source
    assert "proc blaiRoutePreviousOutputSlotIndex*(" in npu_source
    assert "proc blaiRoutePreviousOutputSlotCursor*(" in npu_source
    assert "proc blaiRouteOutputSlotCursor*(" in npu_source
    assert "proc blaiRouteInputPatchTotalCursor*(" in npu_source
    assert "proc blaiRouteInputPatchTotalPlan*(" in npu_source
    assert "proc blaiRouteFirstOutputSlotPlan*(" in npu_source
    assert "proc blaiRouteIntermediateChannelCursor*(" in npu_source
    assert "proc blaiRouteIntermediateOutputSlotPlan*(" in npu_source
    assert "proc blaiRouteIntermediateOutputSlotsPlan*(" in npu_source
    assert "proc blaiRouteSramLayerApplyEvidence*(" in npu_source
    assert "proc blaiRouteSramLayerApplyPlan*(" in npu_source
    assert "proc blaiRouteSramLayerState*(" in npu_source
    assert "proc blaiApplyRouteSramLayerState*" in npu_source
    assert "proc blaiRouteOutputSlotApplyEvidence*(" in npu_source
    assert "proc blaiRouteOutputSlotApplyPlan*(" in npu_source
    assert "proc blaiRouteOutputSlotState*(" in npu_source
    assert "proc blaiApplyRouteOutputSlotState*" in npu_source
    assert "proc blaiRouteOutputSlotsApplyPlan*(" in npu_source
    assert "proc blaiRouteOutputSlotsState*(" in npu_source
    assert "proc blaiApplyRouteOutputSlotsState*" in npu_source
    assert "let nextSlot = blaiRouteNextSlotIndex(slot)" in npu_source
    assert "let inputTotal = blaiRouteInputPatchTotalCursor(" in npu_source
    assert "totalInputPatches = inputTotal.nextTotalPatches" in npu_source
    assert "let inputTotal = blaiRouteInputPatchTotalPlan(" in npu_source
    assert "inputTotal.totalInputPatches, nonNegativeU32(ctrl.psramPatchCount)" in (
        npu_source
    )
    assert "let firstOutput = blaiRouteFirstOutputSlotPlan(" in npu_source
    assert "result.outputSlots[0] = firstOutputSlot" in npu_source
    assert "var\n    cursor = firstCursor" in npu_source
    assert "let channelCursor = blaiRouteIntermediateChannelCursor(" in npu_source
    assert "cumulativeChannels = channelCursor.nextCumulativeChannels" in npu_source
    assert "let outputCommit = blaiRouteIntermediateOutputSlotPlan(" in npu_source
    assert "let intermediateOutputs = blaiRouteIntermediateOutputSlotsPlan(" in (
        npu_source
    )
    assert "outResult.outputSlots = intermediateOutputs.outputSlots" in npu_source
    route_input_total_block = re.search(
        r"proc blaiRouteInputPatchTotalCursor\*\(.*?"
        r"proc blaiRouteInputPatchTotalPlan\*",
        npu_source,
        re.S,
    )
    assert route_input_total_block is not None
    assert "blaiFetchInputStorageCursor(inputIndex, inputPatchCount.len)" in (
        route_input_total_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, inputPatchCount.len)" not in (
        route_input_total_block.group(0)
    )
    assert "outResult.outputSlotCount = intermediateOutputs.outputSlotCount" in (
        npu_source
    )
    assert "outResult.finalPatchCursor = intermediateOutputs.finalPatchCursor" in (
        npu_source
    )
    assert "result.outputSlots[outputCommit.slotIndex] = outputCommit.outputSlot" in (
        npu_source
    )
    assert "result.outputSlotCount = outputCommit.nextOutputSlotCount" in npu_source
    assert "cursor = outputCommit.nextCursor" in npu_source
    assert "let layerApply = blaiRouteSramLayerApplyPlan(" in npu_source
    assert "blaiApplyRouteSramLayerState(" in npu_source
    assert "let outputApply = blaiRouteOutputSlotApplyPlan(" in npu_source
    assert "blaiApplyRouteOutputSlotState(" in npu_source
    assert "let outputSlotsApply = blaiRouteOutputSlotsApplyPlan(" in npu_source
    assert "blaiApplyRouteOutputSlotsState(" in npu_source
    route_sram_layer_evidence_block = re.search(
        r"proc blaiRouteSramLayerApplyEvidence\*\(.*?"
        r"proc blaiRouteSramLayerApplyPlan\*",
        npu_source,
        re.S,
    )
    assert route_sram_layer_evidence_block is not None
    assert "let dramPatchNum = blaiAllocatorFieldAbi(finalPatchCursor)" in (
        route_sram_layer_evidence_block.group(0)
    )
    assert "result.groups = if groups <= 0: 1'i32 else: groups" in (
        route_sram_layer_evidence_block.group(0)
    )
    assert "result.dramPatchNum = dramPatchNum.value" in (
        route_sram_layer_evidence_block.group(0)
    )
    route_sram_layer_apply_block = re.search(
        r"proc blaiRouteSramLayerApplyPlan\*\(.*?"
        r"proc blaiRouteSramLayerState\*",
        npu_source,
        re.S,
    )
    assert route_sram_layer_apply_block is not None
    assert "let evidence = blaiRouteSramLayerApplyEvidence(" in (
        route_sram_layer_apply_block.group(0)
    )
    assert "result.groups = evidence.groups" in (
        route_sram_layer_apply_block.group(0)
    )
    assert "result.dramPatchNum = evidence.dramPatchNum" in (
        route_sram_layer_apply_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(finalPatchCursor)" not in (
        route_sram_layer_apply_block.group(0)
    )
    assert "if groups <= 0" not in route_sram_layer_apply_block.group(0)
    route_output_slot_evidence_block = re.search(
        r"proc blaiRouteOutputSlotApplyEvidence\*\(.*?"
        r"proc blaiRouteOutputSlotApplyPlan\*",
        npu_source,
        re.S,
    )
    assert route_output_slot_evidence_block is not None
    assert "let outputCursor = blaiRouteSlotCursor(outputIndex)" in (
        route_output_slot_evidence_block.group(0)
    )
    assert "let sramSlot = blaiAllocatorFieldAbi(" in (
        route_output_slot_evidence_block.group(0)
    )
    assert "result.slotIndex = outputCursor.slotIndex" in (
        route_output_slot_evidence_block.group(0)
    )
    route_output_slot_apply_block = re.search(
        r"proc blaiRouteOutputSlotApplyPlan\*\(.*?"
        r"proc blaiRouteOutputSlotState\*",
        npu_source,
        re.S,
    )
    assert route_output_slot_apply_block is not None
    assert "let evidence = blaiRouteOutputSlotApplyEvidence(" in (
        route_output_slot_apply_block.group(0)
    )
    assert "result.sramSlot = evidence.sramSlot" in (
        route_output_slot_apply_block.group(0)
    )
    assert "blaiRouteSlotCursor(outputIndex)" not in (
        route_output_slot_apply_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(" not in (
        route_output_slot_apply_block.group(0)
    )
    route_next_cursor_block = re.search(
        r"proc blaiRouteNextSlotCursor\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_next_cursor_block is not None
    assert "slot + 1'u32" not in route_next_cursor_block.group(0)
    route_previous_cursor_block = re.search(
        r"proc blaiRoutePreviousOutputSlotCursor\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_previous_cursor_block is not None
    assert "let outputSlot = blaiRoutePreviousOutputSlotIndex(" in (
        route_previous_cursor_block.group(0)
    )
    assert "blaiRouteSlotCursor(outputSlot.outputSlot)" in (
        route_previous_cursor_block.group(0)
    )
    assert "stepIndex - 1'u32" not in route_previous_cursor_block.group(0)
    assert "proc blaiFetchMemoryInputSlotCursor*" in npu_source
    route_fetch_block = re.search(
        r"proc blaiRouteStepFetchMemoryPlan\(plan: BlaiFetchMemoryPlan,.*?"
        r"proc blaiRouteStepFetchMemoryPlan\(plan: BlaiRouteSramSlotPlan,",
        npu_source,
        re.S,
    )
    assert route_fetch_block is not None
    assert "let firstInput = blaiFetchMemoryInputSlotCursor(0'u32)" in (
        route_fetch_block.group(0)
    )
    assert "let secondInput = blaiFetchMemoryInputSlotCursor(1'u32)" in (
        route_fetch_block.group(0)
    )
    assert "result.inputSlots[firstInput.index]" in route_fetch_block.group(0)
    assert "result.inputSlots[secondInput.index]" in route_fetch_block.group(0)
    assert "plan.inputSlots[firstInput.index]" in route_fetch_block.group(0)
    assert "result.inputSlots[0]" not in route_fetch_block.group(0)
    assert "result.inputSlots[1]" not in route_fetch_block.group(0)
    assert "plan.inputSlots[0]" not in route_fetch_block.group(0)
    route_sram_fetch_block = re.search(
        r"proc blaiRouteStepFetchMemoryPlan\(plan: BlaiRouteSramSlotPlan,.*?proc ",
        npu_source,
        re.S,
    )
    assert route_sram_fetch_block is not None
    assert "let previousOutput = blaiRoutePreviousOutputSlotCursor" in (
        route_sram_fetch_block.group(0)
    )
    assert "let firstInput = blaiFetchMemoryInputSlotCursor(0'u32)" in (
        route_sram_fetch_block.group(0)
    )
    assert "let secondInput = blaiFetchMemoryInputSlotCursor(1'u32)" in (
        route_sram_fetch_block.group(0)
    )
    assert "result.inputSlots[firstInput.index]" in (
        route_sram_fetch_block.group(0)
    )
    assert "result.inputSlots[secondInput.index]" in (
        route_sram_fetch_block.group(0)
    )
    assert "plan.memory.inputSlots[firstInput.index]" in (
        route_sram_fetch_block.group(0)
    )
    assert "result.inputSlots[0]" not in route_sram_fetch_block.group(0)
    assert "result.inputSlots[1]" not in route_sram_fetch_block.group(0)
    assert "plan.memory.inputSlots[0]" not in route_sram_fetch_block.group(0)
    assert "step.index - 1'u32" not in route_sram_fetch_block.group(0)
    assert "let outputSlot = blaiRouteOutputSlotCursor(" in npu_source
    route_slot_plan_block = re.search(
        r"proc blaiPlanRouteSramSlotsInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_slot_plan_block is not None
    assert "blaiRouteInputPatchTotalCursor(" not in route_slot_plan_block.group(0)
    assert "totalInputPatches +=" not in route_slot_plan_block.group(0)
    assert "outResult.outputSlots[0] = totalInputPatches" not in (
        route_slot_plan_block.group(0)
    )
    assert "cursor = totalInputPatches + nonNegativeU32(ctrl.psramPatchCount)" not in (
        route_slot_plan_block.group(0)
    )
    assert "cumulativeChannels += nonNegativeU32(layer.cn" not in (
        route_slot_plan_block.group(0)
    )
    assert "blaiRouteIntermediateChannelCursor(" not in route_slot_plan_block.group(0)
    assert "outResult.outputSlots[outputCommit.slotIndex]" not in (
        route_slot_plan_block.group(0)
    )
    assert "inc outResult.outputSlotCount" not in route_slot_plan_block.group(0)
    assert "cursor = outputSlot.nextCursor" not in route_slot_plan_block.group(0)
    route_apply_block = re.search(
        r"proc blaiApplyRouteSramSlotPlan\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_apply_block is not None
    assert "ctrl.lineW0 = ctrl.linePatchW[0]" not in route_apply_block.group(0)
    assert "if layer.groups <= 0:" not in route_apply_block.group(0)
    assert "layer.dramPatchNum = blaiAllocatorFieldValue(plan.finalPatchCursor)" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.sramIn[inputIndex] =\n      blaiAllocatorFieldValue(plan.memory.inputSlots[inputIndex])" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.sramOut[outputSlot.slotIndex] =" not in route_apply_block.group(0)
    assert "blaiRouteOutputSlotApplyPlan(" not in route_apply_block.group(0)
    assert "blaiAllocatorFieldValue(plan.outputSlots[outputSlot.slotIndex])" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = blaiAllocatorFieldValue(plan.memory.patchSize)" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.sramIn[i] = 0" not in route_apply_block.group(0)
    assert "ctrl.sramOut[i] = 0" not in route_apply_block.group(0)
    assert "ctrl.psramPatchSize = patchSizeApply.patchSize" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.sramIn[inputApply.slotIndex] = inputApply.sramSlot" not in (
        route_apply_block.group(0)
    )
    assert "blaiFetchInputSlotApplyPlan(" not in route_apply_block.group(0)
    assert "blaiApplyFetchInputSlotState(" not in route_apply_block.group(0)
    assert "ctrl.sramOut[outputApply.slotIndex] = outputApply.sramSlot" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.lineW0 = layerApply.lineW0" not in route_apply_block.group(0)
    assert "layer.groups = layerApply.groups" not in route_apply_block.group(0)
    assert "layer.dramPatchNum = layerApply.dramPatchNum" not in (
        route_apply_block.group(0)
    )
    assert (
        "nonNegativeU32(layer.outW) * nonNegativeU32(layer.outH) *\n"
        "      cumulativeChannels"
    ) not in npu_source
    assert "cursor += blaiCeilDivU32(routeOutputElements, outResult.memory.patchSize)" not in npu_source
    assert "layer.releaseMidLayers[releaseCursor.slotIndex]" in npu_source
    assert "layer.releaseLayers[releaseCursor.slotIndex]" in npu_source
    assert "graphLayerToLayer[graph0Cursor.mapIndex]" in npu_source
    assert "graphLayerToLayer[graph1Cursor.mapIndex]" in npu_source
    assert (
        "blaiLogicalInputSlotCursor(inputIndex, 1'u32, BlaiMaxInputNum - 1)"
        in npu_source
    )
    assert "result.cnIndex = cnCursor.slotIndex" in npu_source
    assert "BlaiMemAllocPatchSegmentPosition* = object" in npu_source
    assert "proc blaiMemAllocPatchSegmentPosition*(" in npu_source
    assert "proc blaiMemAllocFinalPatchSegmentPosition*(" in npu_source
    assert "BlaiMemAllocPatchSegmentCursor* = object" in npu_source
    assert "proc blaiMemAllocPatchSegmentCursor*(" in npu_source
    assert "result.patchSlot = patchCursor.index" in npu_source
    assert "result.last = position.last" in npu_source
    patch_segment_cursor_block = re.search(
        r"proc blaiMemAllocPatchSegmentCursor\*\(.*?"
        r"proc blaiToolchainPatchInitialRequestPlanInto\*",
        npu_source,
        re.S,
    )
    assert patch_segment_cursor_block is not None
    assert "let position = blaiMemAllocPatchSegmentPosition(" in (
        patch_segment_cursor_block.group(0)
    )
    assert "patchIndex == patchCount - 1'u32" not in (
        patch_segment_cursor_block.group(0)
    )
    assert "BlaiToolchainPatchInitialPlan* = object" in npu_source
    assert "BlaiToolchainPatchInitialState* = object" in npu_source
    assert "BlaiToolchainPatchInitialApplyPlan* = object" in npu_source
    assert "BlaiToolchainPatchInitialRequestPlan* = object" in npu_source
    assert "BlaiToolchainPatchInitialStorePlan* = object" in npu_source
    assert "BlaiToolchainPatchInitialStoreState* = object" in npu_source
    assert "BlaiToolchainPatchInitialStoreApplyPlan* = object" in npu_source
    assert "BlaiToolchainPatchPreviousOwnerPlan* = object" in npu_source
    assert "BlaiToolchainPatchOwnerPlan* = object" in npu_source
    assert "BlaiToolchainPatchDispatchPlan* = object" in npu_source
    assert "BlaiToolchainPatchSearchCallPreparePlan* = object" in npu_source
    assert "BlaiToolchainPatchMetadataPlan* = object" in npu_source
    assert "BlaiToolchainPatchDebugMetadataSnapshotState* = object" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugMetadataSnapshotPlan* = object" in npu_source
    assert "BlaiToolchainPatchDebugMetadataSnapshotApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugMetadataSnapshotApplyPlan* = object" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugStartSlotLookupPlan* = object" in npu_source
    assert "BlaiToolchainPatchDebugStartSlotLookupApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugStartSlotLookupApplyPlan* = object" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugSearchSnapshotPlan* = object" in npu_source
    assert "BlaiToolchainPatchDebugSearchSnapshotState* = object" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugSearchSnapshotApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugSearchSnapshotApplyPlan* = object" in (
        npu_source
    )
    assert "BlaiToolchainPatchSearchPlan* = object" in npu_source
    assert "BlaiToolchainPatchApplyPlan* = object" in npu_source
    assert "BlaiToolchainPatchAssignmentState* = object" in npu_source
    assert "BlaiToolchainPatchAssignmentApplyPlan* = object" in npu_source
    assert "BlaiToolchainSramGlobalsEvidence* = object" in npu_source
    assert "BlaiToolchainCfgMemoryEvidence* = object" in npu_source
    assert "BlaiToolchainPsramAllocateScratchPlan* = object" in npu_source
    assert "BlaiToolchainPsramLayerLoopPlan* = object" in npu_source
    assert "BlaiToolchainPsramLayerTransitionPlan* = object" in npu_source
    assert "BlaiToolchainPsramLayerRequestPlan* = object" in npu_source
    assert "BlaiToolchainPsramDspRequestPlan* = object" in npu_source
    assert "BlaiToolchainPsramDspVolumeRequestPlan* = object" in npu_source
    assert "BlaiToolchainPsramGeneralPatchPlan* = object" in npu_source
    assert "BlaiToolchainPsramGeneralPatchState* = object" in npu_source
    assert "BlaiToolchainPsramGeneralPatchApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramGeneralPatchApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramDspPatchPairPlan* = object" in npu_source
    assert "BlaiToolchainPsramDspVolumePatchPairPlan* = object" in npu_source
    assert "BlaiToolchainPsramTfliteRequestPlan* = object" in npu_source
    assert "BlaiToolchainPsramTflitePatchPlan* = object" in npu_source
    assert "BlaiToolchainPsramLayerRequestStorePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchCallPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchCallFramePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchReturnPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchReturnFramePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchReturnBlock* = enum" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchReturnPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerTransitionPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupSweepPlan* = object" in npu_source
    assert "BlaiToolchainPsramCleanupEntryPlan* = object" in npu_source
    assert "BlaiToolchainPsramCleanupEntryApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramCleanupEntryApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramPostSearchSlotPlan* = object" in npu_source
    assert "BlaiToolchainPsramCleanupDebugSlotPlan* = object" in npu_source
    assert "BlaiToolchainPsramCleanupDebugSlotState* = object" in npu_source
    assert "BlaiToolchainPsramCleanupDebugSlotApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramCleanupDebugSlotApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardPlan* = object" in npu_source
    assert "BlaiToolchainPsramFallbackGatePlan* = object" in npu_source
    assert "BlaiToolchainPsramUnassignedMetadataPlan* = object" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataPlan* = object" in npu_source
    assert "BlaiToolchainPsramSplitMetadataPlan* = object" in npu_source
    assert "BlaiToolchainPsramSplitMetadataCursor* = object" in npu_source
    assert "BlaiToolchainPsramRelationAppendPlan* = object" in npu_source
    assert "BlaiToolchainPsramRelationConsumerPlan* = object" in npu_source
    assert "BlaiToolchainPsramRelationConsumerState* = object" in npu_source
    assert "BlaiToolchainPsramRelationConsumerApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramRelationConsumerApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramInputMembershipPlan* = object" in npu_source
    assert "BlaiToolchainPsramInputMembershipResumePlan* = object" in npu_source
    assert "BlaiToolchainPsramInputMembershipResumeApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramInputMembershipResumeApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialInputGatePlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialInputGateState* = object" in npu_source
    assert "BlaiToolchainPsramInitialInputGateApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramInitialInputGateApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialRelationScanPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteRequestPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteRequestState* = object" in npu_source
    assert (
        "BlaiToolchainPsramInitialTfliteRequestApplyBlock* = enum"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTfliteRequestApplyPlan* = object"
        in npu_source
    )
    assert "BlaiToolchainPsramInitialTflitePatchPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTflitePatchState* = object" in npu_source
    assert (
        "BlaiToolchainPsramInitialTflitePatchApplyBlock* = enum"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTflitePatchApplyPlan* = object"
        in npu_source
    )
    assert "BlaiToolchainPsramInitialTfliteLoopPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteLoopApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramInitialTfliteLoopApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteJoinPlan* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteJoinState* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteJoinApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramInitialTfliteJoinApplyPlan* = object" in npu_source
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestPlan* = object"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestState* = object"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestSummaryState* = object"
        in npu_source
    )
    assert (
        "summaryStateAfter*: BlaiToolchainPsramInitialTfliteJoinRequestSummaryState"
        in npu_source
    )
    assert "factorAOffset*: uint32" in npu_source
    assert "selectedCount*: uint32" in npu_source
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestApplyBlock* = enum"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestApplyPlan* = object"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchPagePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteGatePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteSourcePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBaseOffsetPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchDivisorPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchStorePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreSelectPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchPressurePlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLargeFlagPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLargeSplitPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLargeTotalPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLowerFlagPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLowerSplitPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchLowerTotalPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchNoPatchPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchPlan* = object" in npu_source
    assert "proc blaiToolchainPatchSearchPlanInto*" in npu_source
    assert "BlaiToolchainPatchSearchHelperEvidence* = object" in npu_source
    assert "proc blaiToolchainPatchSearchHelperEvidenceInto*" in npu_source
    assert "proc blaiToolchainPatchSearchHelperEvidence*" in npu_source
    assert "outResult.tfliteDefaultOwner = 1'i32" in npu_source
    assert "outResult.normalStoresPatchCount =" in npu_source
    assert "outResult.tfliteStoresOnlyStart =" in npu_source
    assert "patchSearchHelperEvidence.tfliteMetadata.patchCount == 0" in (
        npu_source
    )
    assert "proc blaiToolchainPatchInitialPlanInto*" in npu_source
    assert "proc blaiToolchainPatchInitialRequestPlanInto*" in npu_source
    assert "outResult.smallChannelForced = layer.c == 2 or layer.c == 3" in (
        npu_source
    )
    assert "outResult.requestedPatchCount =\n    outResult.inputBytes div outResult.patchSizeBytes" in (
        npu_source
    )
    assert "BlaiToolchainPatchInitialRequestStoreOffset* = 0xCB70'u32" in (
        npu_source
    )
    assert "proc blaiToolchainPatchInitialStorePlanInto*" in npu_source
    assert "outResult.metadataOffset = BlaiToolchainPatchInitialRequestStoreOffset" in (
        npu_source
    )
    assert "BlaiToolchainPatchRequestCountAbi* = object" in npu_source
    assert "proc blaiToolchainPatchRequestCountAbi*" in npu_source
    assert "let requestCount = blaiToolchainPatchRequestCountAbi(" in npu_source
    assert "outResult.storedRequestCount = requestCount.value" in npu_source
    initial_store_plan_block = re.search(
        r"proc blaiToolchainPatchInitialStorePlanInto\*\(.*?"
        r"proc blaiToolchainPatchInitialStorePlan\*",
        npu_source,
        re.S,
    )
    assert initial_store_plan_block is not None
    assert "request.requestedPatchCount.int32" not in (
        initial_store_plan_block.group(0)
    )
    assert "request.requestedPatchCount > uint32(high(int32))" not in (
        initial_store_plan_block.group(0)
    )
    assert "proc blaiToolchainPatchInitialStoreApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainPatchInitialStoreState(" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialStoreState*" in npu_source
    assert (
        "proc blaiApplyToolchainPatchInitialStoreMetadataState*" in npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialStoreScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialStoreScalars*" in npu_source
    assert "proc blaiApplyToolchainPatchInitialStore*" in npu_source
    initial_store_block = re.search(
        r"proc blaiApplyToolchainPatchInitialStore\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert initial_store_block is not None
    assert (
        "blaiApplyToolchainPatchInitialStoreMetadataState("
        in initial_store_block.group(0)
    )
    assert (
        "requestMetadata = applyPlan.stateAfter.storedRequestCount"
        not in initial_store_block.group(0)
    )
    initial_store_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchInitialStoreScalarState\*\(.*?"
        r"proc blaiApplyToolchainPatchInitialStore\*",
        npu_source,
        re.S,
    )
    assert initial_store_scalar_block is not None
    assert "blaiApplyToolchainPatchInitialStoreScalarState(" in (
        initial_store_scalar_block.group(0)
    )
    assert "metadataOffset = plan.stateAfter.metadataOffset" not in (
        initial_store_scalar_block.group(0)
    )
    assert "requestedPatchCount = plan.stateAfter.requestedPatchCount" not in (
        initial_store_scalar_block.group(0)
    )
    assert "storedRequestCount = plan.stateAfter.storedRequestCount" not in (
        initial_store_scalar_block.group(0)
    )
    assert "writesApplied = plan.stateAfter.writesApplied" not in (
        initial_store_scalar_block.group(0)
    )
    assert "requestMetadata = plan.storedRequestCount" not in npu_source
    assert "proc blaiToolchainPatchInitialApplyPlanInto*" in npu_source
    assert "proc blaiToolchainPatchOccupiedCursor*" in npu_source
    assert "proc blaiToolchainPatchOwnerCursor*" in npu_source
    assert "proc blaiToolchainPatchStateCursor*" in npu_source
    assert "outResult.stateAfter.occupiedAfter[stateCursor.index] = true" in (
        npu_source
    )
    initial_apply_block = re.search(
        r"proc blaiToolchainPatchInitialApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPatchInitialApplyPlan\*",
        npu_source,
        re.S,
    )
    assert initial_apply_block is not None
    assert "blaiToolchainPatchOccupiedCursor(patchIndex, occupied.len)" in (
        initial_apply_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(patchIndex, owners.len)" in (
        initial_apply_block.group(0)
    )
    assert "blaiToolchainPatchStateCursor(patchIndex)" in (
        initial_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, occupied.len)" not in (
        initial_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, owners.len)" not in (
        initial_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(\n      patchIndex, BlaiMaxWeightPatches)" not in (
        initial_apply_block.group(0)
    )
    assert "proc blaiApplyToolchainPatchInitialReservationTableState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialReservationScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialReservationScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchInitialReservation*" in npu_source
    assert (
        "blaiApplyToolchainPatchInitialReservationState(occupied, owners, applyPlan)"
        in npu_source
    )
    initial_reservation_state_block = re.search(
        r"proc blaiApplyToolchainPatchInitialReservationState\*\(.*?"
        r"proc blaiApplyToolchainPatchInitialReservation\*",
        npu_source,
        re.S,
    )
    assert initial_reservation_state_block is not None
    assert "blaiApplyToolchainPatchInitialReservationTableState(" in (
        initial_reservation_state_block.group(0)
    )
    assert "plan.stateAfter.occupiedAfter[stateCursor.index]" not in (
        initial_reservation_state_block.group(0)
    )
    assert "plan.stateAfter.ownerAfter[stateCursor.index]" not in (
        initial_reservation_state_block.group(0)
    )
    initial_reservation_table_block = re.search(
        r"proc blaiApplyToolchainPatchInitialReservationTableState\*\(.*?"
        r"proc blaiApplyToolchainPatchInitialReservationState\*",
        npu_source,
        re.S,
    )
    assert initial_reservation_table_block is not None
    assert "blaiToolchainPatchOccupiedCursor(patchIndex, occupied.len)" in (
        initial_reservation_table_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(patchIndex, owners.len)" in (
        initial_reservation_table_block.group(0)
    )
    assert "blaiToolchainPatchStateCursor(patchIndex)" in (
        initial_reservation_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, occupied.len)" not in (
        initial_reservation_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, owners.len)" not in (
        initial_reservation_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(\n      patchIndex, BlaiMaxWeightPatches)" not in (
        initial_reservation_table_block.group(0)
    )
    initial_reservation_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchInitialReservationScalarState\*\(.*?"
        r"proc blaiApplyToolchainPatchInitialReservation\*",
        npu_source,
        re.S,
    )
    assert initial_reservation_scalar_block is not None
    assert "blaiApplyToolchainPatchInitialReservationScalarState(" in (
        initial_reservation_scalar_block.group(0)
    )
    assert "requestedPatchCount = plan.stateAfter.requestedPatchCount" not in (
        initial_reservation_scalar_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        initial_reservation_scalar_block.group(0)
    )
    assert "writesApplied = plan.stateAfter.writesApplied" not in (
        initial_reservation_scalar_block.group(0)
    )
    initial_reservation_block = re.search(
        r"proc blaiApplyToolchainPatchInitialReservation\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert initial_reservation_block is not None
    assert "owners[ownerCursor.index] = plan.owner" not in (
        initial_reservation_block.group(0)
    )
    assert "proc blaiToolchainPatchPreviousOwnerPlanInto*" in npu_source
    assert "BlaiToolchainPatchPreviousOwnerType* = 0x1B'i32" in npu_source
    assert "layerTypeValue == BlaiToolchainPatchPreviousOwnerType" in npu_source
    assert "inheritedPreviousOwnerFlag or outResult.typeMatchesPreviousOwner" in (
        npu_source
    )
    assert "proc blaiToolchainPatchOwnerPlanInto*" in npu_source
    assert "blaiToolchainPatchOwnerDsp" in npu_source
    assert "outResult.selectedOwner = currentLayerIndex" in npu_source
    assert "proc blaiToolchainPatchDispatchPlanInto*" in npu_source
    assert "outResult.metadataMode = blaiToolchainPatchMetadataGeneral" in npu_source
    assert "outResult.metadataMode = blaiToolchainPatchMetadataDsp" in npu_source
    assert "outResult.metadataMode = blaiToolchainPatchMetadataTflite" in npu_source
    assert "outResult.generalSearchCall = true" in npu_source
    assert "outResult.dspSearchCall = true" in npu_source
    assert "outResult.tfliteSearchCall = true" in npu_source
    assert "proc blaiToolchainPatchSearchCallPreparePlanInto*" in npu_source
    assert "BlaiToolchainPatchSearchCallPrepareBlock* = enum" in npu_source
    assert "outResult.relationConsumerLayerIndex =\n    outResult.relationConsumer.consumerLayerIndex" in (
        npu_source
    )
    assert "outResult.relationConsumerFound = outResult.relationConsumer.found" in (
        npu_source
    )
    assert "outResult.selectedPreviousOwnerFlag =\n    outResult.previousOwner.selectedPreviousOwnerFlag" in (
        npu_source
    )
    assert "proc blaiToolchainPatchMetadataPlanInto*" in npu_source
    assert "blaiToolchainPatchMetadataDsp" in npu_source
    assert "BlaiToolchainPatchStartSlotAbi* = object" in npu_source
    assert "BlaiToolchainPatchCountAbi* = object" in npu_source
    assert "proc blaiToolchainPatchStartSlotAbi*" in npu_source
    assert "proc blaiToolchainPatchCountAbi*" in npu_source
    assert "let startSlot = blaiToolchainPatchStartSlotAbi(" in npu_source
    assert "let patchCount = blaiToolchainPatchCountAbi(" in npu_source
    assert "outResult.startPatchSlot = startSlot.value" in npu_source
    assert "outResult.patchCount = patchCount.value" in npu_source
    assert "outResult.storesPatchCount = true" in npu_source
    assert "outResult.storesPatchCount = false" in npu_source
    assert "outResult.startOffset = BlaiToolchainPatchDebugGeneralStartOffset" in (
        npu_source
    )
    assert "outResult.countOffset = BlaiToolchainPatchDebugGeneralCountOffset" in (
        npu_source
    )
    assert "outResult.startOffset = BlaiToolchainPsramDspDebugStartOffset" in (
        npu_source
    )
    assert "outResult.startOffset = BlaiToolchainPsramTfliteStartOffset" in (
        npu_source
    )
    assert "BlaiToolchainPatchMetadataState* = object" in npu_source
    assert "BlaiToolchainPatchMetadataApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPatchMetadataApplyPlan* = object" in npu_source
    assert "proc blaiToolchainPatchMetadataApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainPatchMetadataState" in (
        npu_source
    )
    patch_metadata_plan_block = re.search(
        r"proc blaiToolchainPatchMetadataPlanInto\*\(.*?"
        r"proc blaiToolchainPatchMetadataPlan\*",
        npu_source,
        re.S,
    )
    assert patch_metadata_plan_block is not None
    assert "search.startPatchSlot.int32" not in (
        patch_metadata_plan_block.group(0)
    )
    assert "search.assignedPatchCount.int32" not in (
        patch_metadata_plan_block.group(0)
    )
    assert "search.startPatchSlot > uint32(high(int32))" not in (
        patch_metadata_plan_block.group(0)
    )
    assert "search.assignedPatchCount > uint32(high(int32))" not in (
        patch_metadata_plan_block.group(0)
    )
    assert "proc blaiApplyToolchainPatchMetadataState*" in npu_source
    assert "proc blaiApplyToolchainPatchMetadataBankState*" in npu_source
    assert "proc blaiApplyToolchainPatchMetadataScalarState*" in npu_source
    assert "proc blaiApplyToolchainPatchMetadataScalars*" in npu_source
    assert "proc blaiApplyToolchainPatchMetadata*" in npu_source
    assert "proc blaiToolchainPsramMetadataBankCursor*" in npu_source
    patch_metadata_bank_block = re.search(
        r"proc blaiApplyToolchainPatchMetadataBankState\*\(.*?"
        r"proc blaiApplyToolchainPatchMetadata\*",
        npu_source,
        re.S,
    )
    assert patch_metadata_bank_block is not None
    assert "blaiToolchainPsramMetadataBankIndexAbi(" in (
        patch_metadata_bank_block.group(0)
    )
    assert "blaiToolchainPsramMetadataBankCursor(" in (
        patch_metadata_bank_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(bankIndex.value" not in (
        patch_metadata_bank_block.group(0)
    )
    assert "state.layerIndex.uint32" not in patch_metadata_bank_block.group(0)
    patch_metadata_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchMetadataScalarState\*\(.*?"
        r"proc blaiApplyToolchainPatchMetadata\*",
        npu_source,
        re.S,
    )
    assert patch_metadata_scalar_block is not None
    assert "blaiApplyToolchainPatchMetadataScalarState(" in (
        patch_metadata_scalar_block.group(0)
    )
    assert "mode = plan.stateAfter.mode" not in (
        patch_metadata_scalar_block.group(0)
    )
    assert "layerIndex = plan.stateAfter.layerIndex" not in (
        patch_metadata_scalar_block.group(0)
    )
    assert "startPatchSlot = plan.stateAfter.startPatchSlot" not in (
        patch_metadata_scalar_block.group(0)
    )
    assert "patchCount = plan.stateAfter.patchCount" not in (
        patch_metadata_scalar_block.group(0)
    )
    patch_metadata_apply_block = re.search(
        r"proc blaiApplyToolchainPatchMetadata\*\(.*?"
        r"proc blaiToolchainPatchDebugMetadataSnapshotPlanInto\*",
        npu_source,
        re.S,
    )
    assert patch_metadata_apply_block is not None
    assert "let applyPlan = blaiToolchainPatchMetadataApplyPlan(plan)" in (
        patch_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPatchMetadataBankState(" in (
        patch_metadata_apply_block.group(0)
    )
    assert (
        "startPatchSlots[startCursor.index] = stateAfter.startPatchSlot"
        not in patch_metadata_apply_block.group(0)
    )
    assert "patchCounts[countIndex] = stateAfter.patchCount" not in (
        patch_metadata_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        patch_metadata_apply_block.group(0)
    )
    assert "plan.startPatchSlot" not in patch_metadata_apply_block.group(0)
    assert "plan.patchCount" not in patch_metadata_apply_block.group(0)
    assert "if plan.storesPatchCount:" not in patch_metadata_apply_block.group(0)
    assert "proc blaiToolchainPatchDebugMetadataSnapshotPlanInto*" in npu_source
    assert "BlaiToolchainPatchDebugGeneralStartOffset* = 0x8CDC'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugGeneralCountOffset* = 0x9C90'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugAuxiliaryStartOffset* = 0xD344'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugSecondaryStartOffset* = 0x4D2B4'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugRequestTableOffset* = 0x8C284'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchDebugMetadataStackBytes* = 16'u32" in (
        npu_source
    )
    assert "outResult.requestTableOffset = BlaiToolchainPatchDebugRequestTableOffset" in (
        npu_source
    )
    assert "outResult.printRequested = debugLogFlag" in npu_source
    assert "outResult.requestTableCount = requestTableCount" in npu_source
    assert "outResult.generalStartPatchSlot = generalStartPatchSlot" in npu_source
    assert "outResult.generalPatchCount = generalPatchCount" in npu_source
    assert "outResult.auxiliaryStartPatchSlot = auxiliaryStartPatchSlot" in (
        npu_source
    )
    assert "outResult.secondaryStartPatchSlot = secondaryStartPatchSlot" in (
        npu_source
    )
    assert "outResult.layerScalar = layerScalar" in npu_source
    assert (
        "proc blaiToolchainPatchDebugMetadataSnapshotApplyPlanInto*"
        in npu_source
    )
    assert "outResult.snapshot = snapshot" in npu_source
    assert "outResult.stateAfter = blaiToolchainPatchDebugMetadataSnapshotState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugMetadataSnapshot*" in npu_source
    assert (
        "proc blaiApplyToolchainPatchDebugMetadataSnapshotScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugMetadataSnapshotScalars*" in (
        npu_source
    )
    patch_debug_snapshot_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchDebugMetadataSnapshotScalarState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert patch_debug_snapshot_scalar_block is not None
    assert "blaiApplyToolchainPatchDebugMetadataSnapshotScalarState(" in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "requestTableCount = plan.stateAfter.requestTableCount" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "generalStartPatchSlot = plan.stateAfter.generalStartPatchSlot" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "generalPatchCount = plan.stateAfter.generalPatchCount" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "auxiliaryStartPatchSlot = plan.stateAfter.auxiliaryStartPatchSlot" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "secondaryStartPatchSlot = plan.stateAfter.secondaryStartPatchSlot" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "layerScalar = plan.stateAfter.layerScalar" not in (
        patch_debug_snapshot_scalar_block.group(0)
    )
    assert "proc blaiToolchainPatchDebugStartSlotLookupPlanInto*" in npu_source
    assert "BlaiToolchainPatchDebugStartSlotIndexAbi* = object" in npu_source
    assert "proc blaiToolchainPatchDebugStartSlotIndexAbi*" in npu_source
    assert "BlaiToolchainPatchDebugStartSlotLookupState* = object" in npu_source
    assert "outResult.lookupRequested = debugLogFlag" in npu_source
    assert "outResult.slotTableCount = blaiOpenArrayLenU32(slotTable)" in (
        npu_source
    )
    assert "if not startIndex.valid:" in npu_source
    assert "outResult.slotTableValue = slotTable[cursor.index]" in npu_source
    patch_debug_start_lookup_plan_block = re.search(
        r"proc blaiToolchainPatchDebugStartSlotLookupPlanInto\*\(.*?"
        r"proc blaiToolchainPatchDebugStartSlotLookupPlan\*",
        npu_source,
        re.S,
    )
    assert patch_debug_start_lookup_plan_block is not None
    assert "blaiToolchainPatchDebugStartSlotIndexAbi(" in (
        patch_debug_start_lookup_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(startIndex.value" in (
        patch_debug_start_lookup_plan_block.group(0)
    )
    assert "generalStartPatchSlot.uint32" not in (
        patch_debug_start_lookup_plan_block.group(0)
    )
    assert (
        "proc blaiToolchainPatchDebugStartSlotLookupApplyPlanInto*"
        in npu_source
    )
    assert "outResult.lookup = lookup" in npu_source
    assert "outResult.slotTableValueAfter = lookup.slotTableValue" in npu_source
    assert "outResult.stateAfter = blaiToolchainPatchDebugStartSlotLookupState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugStartSlotLookupState*" in npu_source
    assert (
        "proc blaiApplyToolchainPatchDebugStartSlotLookupScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugStartSlotLookup*" in npu_source
    patch_debug_start_lookup_apply_block = re.search(
        r"proc blaiApplyToolchainPatchDebugStartSlotLookup\*\(.*?"
        r"proc blaiApplyToolchainPatchDebugStartSlotLookupState\*",
        npu_source,
        re.S,
    )
    assert patch_debug_start_lookup_apply_block is not None
    assert "blaiApplyToolchainPatchDebugStartSlotLookupScalarState(" in (
        patch_debug_start_lookup_apply_block.group(0)
    )
    assert "debugSlotValue = plan.stateAfter.slotTableValueAfter" not in (
        patch_debug_start_lookup_apply_block.group(0)
    )
    assert "proc blaiToolchainPatchDebugSearchSnapshotPlanInto*" in npu_source
    assert "outResult.previousOwnerFlagBit =" in npu_source
    assert "outResult.printRequested = debugLogFlag" in npu_source
    assert "outResult.patchCountScalar = patchCountScalar" in npu_source
    assert "outResult.layerCursorScalar = layerCursorScalar" in npu_source
    assert (
        "proc blaiToolchainPatchDebugSearchSnapshotApplyPlanInto*"
        in npu_source
    )
    assert "outResult.snapshot = snapshot" in npu_source
    assert "outResult.stateAfter = blaiToolchainPatchDebugSearchSnapshotState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugSearchSnapshot*" in npu_source
    assert "proc blaiApplyToolchainPatchDebugSearchSnapshotScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchDebugSearchSnapshotScalars*" in (
        npu_source
    )
    patch_debug_search_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchDebugSearchSnapshotScalarState\*\(.*?"
        r"proc blaiToolchainPatchApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert patch_debug_search_scalar_block is not None
    assert "blaiApplyToolchainPatchDebugSearchSnapshotScalarState(" in (
        patch_debug_search_scalar_block.group(0)
    )
    assert "patchCountScalar = plan.stateAfter.patchCountScalar" not in (
        patch_debug_search_scalar_block.group(0)
    )
    assert "layerCursorScalar = plan.stateAfter.layerCursorScalar" not in (
        patch_debug_search_scalar_block.group(0)
    )
    assert "previousOwnerFlag = plan.stateAfter.previousOwnerFlag" not in (
        patch_debug_search_scalar_block.group(0)
    )
    assert "proc blaiToolchainPatchAssignmentApplyPlanInto*" in npu_source
    assert "outResult.stateAfter.occupiedAfter[stateCursor.index] = true" in (
        npu_source
    )
    patch_assignment_apply_block = re.search(
        r"proc blaiToolchainPatchAssignmentApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPatchAssignmentApplyPlan\*",
        npu_source,
        re.S,
    )
    assert patch_assignment_apply_block is not None
    assert "blaiToolchainPatchOccupiedCursor(patchIndex, occupied.len)" in (
        patch_assignment_apply_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(patchIndex, owners.len)" in (
        patch_assignment_apply_block.group(0)
    )
    assert "blaiToolchainPatchStateCursor(patchOffset)" in (
        patch_assignment_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, occupied.len)" not in (
        patch_assignment_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, owners.len)" not in (
        patch_assignment_apply_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(\n      patchOffset, BlaiMaxWeightPatches)" not in (
        patch_assignment_apply_block.group(0)
    )
    assert "proc blaiApplyToolchainPatchAssignmentTableState*" in npu_source
    assert "proc blaiApplyToolchainPatchAssignmentState*" in npu_source
    assert "proc blaiApplyToolchainPatchAssignmentScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPatchAssignmentScalars*" in npu_source
    assert "proc blaiApplyToolchainPatchAssignment*" in npu_source
    patch_assignment_state_block = re.search(
        r"proc blaiApplyToolchainPatchAssignmentState\*\(.*?"
        r"proc blaiApplyToolchainPatchAssignment\*",
        npu_source,
        re.S,
    )
    assert patch_assignment_state_block is not None
    assert "blaiApplyToolchainPatchAssignmentTableState(" in (
        patch_assignment_state_block.group(0)
    )
    assert "plan.stateAfter.occupiedAfter[stateCursor.index]" not in (
        patch_assignment_state_block.group(0)
    )
    assert "plan.stateAfter.ownerAfter[stateCursor.index]" not in (
        patch_assignment_state_block.group(0)
    )
    patch_assignment_table_block = re.search(
        r"proc blaiApplyToolchainPatchAssignmentTableState\*\(.*?"
        r"proc blaiApplyToolchainPatchAssignmentState\*",
        npu_source,
        re.S,
    )
    assert patch_assignment_table_block is not None
    assert "blaiToolchainPatchOccupiedCursor(patchIndex, occupied.len)" in (
        patch_assignment_table_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(patchIndex, owners.len)" in (
        patch_assignment_table_block.group(0)
    )
    assert "blaiToolchainPatchStateCursor(patchOffset)" in (
        patch_assignment_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, occupied.len)" not in (
        patch_assignment_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, owners.len)" not in (
        patch_assignment_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(\n      patchOffset, BlaiMaxWeightPatches)" not in (
        patch_assignment_table_block.group(0)
    )
    patch_assignment_scalar_block = re.search(
        r"proc blaiApplyToolchainPatchAssignmentScalarState\*\(.*?"
        r"proc blaiApplyToolchainPatchAssignment\*",
        npu_source,
        re.S,
    )
    assert patch_assignment_scalar_block is not None
    assert "blaiApplyToolchainPatchAssignmentScalarState(" in (
        patch_assignment_scalar_block.group(0)
    )
    assert "startPatchSlot = plan.stateAfter.startPatchSlot" not in (
        patch_assignment_scalar_block.group(0)
    )
    assert "assignedPatchCount = plan.stateAfter.assignedPatchCount" not in (
        patch_assignment_scalar_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        patch_assignment_scalar_block.group(0)
    )
    assert "writesApplied = plan.stateAfter.writesApplied" not in (
        patch_assignment_scalar_block.group(0)
    )
    patch_assignment_block = re.search(
        r"proc blaiApplyToolchainPatchAssignment\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert patch_assignment_block is not None
    assert "owners[ownerCursor.index] = plan.owner" not in (
        patch_assignment_block.group(0)
    )
    assert (
        "blaiApplyToolchainPatchAssignmentState(occupied, owners, applyPlan)"
        in patch_assignment_block.group(0)
    )
    assert "proc blaiToolchainSramGlobalsEvidenceInto*" in npu_source
    assert "proc blaiToolchainCfgMemoryEvidenceInto*" in npu_source
    assert "proc blaiToolchainPsramAllocateScratchPlanInto*" in npu_source
    assert (
        "outResult.cfgPatchSizeElements * outResult.cfgPatchElementBytes"
        in npu_source
    )
    assert (
        "outResult.cfgPatchElementBytes == sizeof(int32).uint32"
        in npu_source
    )
    assert (
        "outResult.cfgPatchNum >= outResult.maxPsramPatchSlots"
        in npu_source
    )
    assert "cfgTotalBytes*: uint32" in npu_source
    assert "activePlannerBytes*: uint32" in npu_source
    assert "sparePatchSlots*: uint32" in npu_source
    assert "sparePatchBytes*: uint32" in npu_source
    assert "cfgCapacityCoversPlanner*: bool" in npu_source
    assert "outResult.cfgTotalBytes =" in npu_source
    assert "outResult.activePlannerBytes =" in npu_source
    assert "outResult.sparePatchSlots =" in npu_source
    assert "outResult.cfgCapacityCoversPlanner" in npu_source
    assert "proc blaiToolchainPsramLayerLoopPlanInto*" in npu_source
    assert "layerCount <= 0'i32" in npu_source
    assert "layerIndex < 0'i32 or layerIndex >= layerCount" in npu_source
    assert "BlaiToolchainPsramLayerProcessDecision* = object" in npu_source
    assert "proc blaiToolchainPsramLayerProcessDecision*" in npu_source
    layer_process_decision_block = re.search(
        r"proc blaiToolchainPsramLayerProcessDecision\*\(.*?"
        r"proc blaiToolchainPsramLayerLoopPlanInto\*",
        npu_source,
        re.S,
    )
    assert layer_process_decision_block is not None
    assert "layerTypeValue == BlaiToolchainPsramAllocateSkipLayerType" in (
        layer_process_decision_block.group(0)
    )
    assert "result.processLayer = not result.skippedLayer" in (
        layer_process_decision_block.group(0)
    )
    layer_loop_block = re.search(
        r"proc blaiToolchainPsramLayerLoopPlanInto\*.*?"
        r"proc blaiToolchainPsramLayerLoopPlan\*",
        npu_source,
        re.S,
    )
    assert layer_loop_block is not None
    assert "let processDecision =" in layer_loop_block.group(0)
    assert "blaiToolchainPsramLayerProcessDecision(layerTypeValue)" in (
        layer_loop_block.group(0)
    )
    assert "outResult.skippedLayer = processDecision.skippedLayer" in (
        layer_loop_block.group(0)
    )
    assert "outResult.processLayer = processDecision.processLayer" in (
        layer_loop_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramAllocateSkipLayerType" not in (
        layer_loop_block.group(0)
    )
    assert "outResult.processLayer = not outResult.skippedLayer" not in (
        layer_loop_block.group(0)
    )
    assert "BlaiToolchainPsramLayerStrideBytes* = 0x978'u32" in npu_source
    assert "BlaiToolchainPsramLayerCopyQwords* = 0x12F'u32" in npu_source
    assert "BlaiToolchainPsramSignedAlign4Abi* = object" in npu_source
    assert "proc blaiToolchainPsramSignedAlign4Abi*" in npu_source
    assert "proc blaiToolchainPsramLayerTransitionPlanInto*" in npu_source
    assert "outResult.nextLayerIndex = completedLayerIndex + 1'i32" in (
        npu_source
    )
    assert "outResult.endReached = outResult.nextLayerIndex >= layerCount" in (
        npu_source
    )
    assert "outResult.copyRequested = true" in npu_source
    assert "rawValue and 0x3'i32" in npu_source
    signed_align4_block = re.search(
        r"proc blaiToolchainPsramSignedAlign4Abi\*.*?"
        r"proc blaiToolchainPsramLayerTransitionPlanInto\*",
        npu_source,
        re.S,
    )
    assert signed_align4_block is not None
    assert "result.value = aligned64.int32" in signed_align4_block.group(0)
    assert "outValue = aligned64.int32" not in signed_align4_block.group(0)
    layer_transition_block = re.search(
        r"proc blaiToolchainPsramLayerTransitionPlanInto\*.*?"
        r"proc blaiToolchainPsramLayerTransitionPlan\*",
        npu_source,
        re.S,
    )
    assert layer_transition_block is not None
    assert "let alignedScalar = blaiToolchainPsramSignedAlign4Abi(" in (
        layer_transition_block.group(0)
    )
    assert "outResult.alignedScalar = alignedScalar.value" in (
        layer_transition_block.group(0)
    )
    assert "let processDecision =" in layer_transition_block.group(0)
    assert "blaiToolchainPsramLayerProcessDecision(layerTypeValue)" in (
        layer_transition_block.group(0)
    )
    assert "outResult.skippedLayer = processDecision.skippedLayer" in (
        layer_transition_block.group(0)
    )
    assert "outResult.processLayer = processDecision.processLayer" in (
        layer_transition_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramAllocateSkipLayerType" not in (
        layer_transition_block.group(0)
    )
    assert "outResult.processLayer = not outResult.skippedLayer" not in (
        layer_transition_block.group(0)
    )
    assert "blaiToolchainPsramSignedAlign4Value(" not in (
        layer_transition_block.group(0)
    )
    assert "proc blaiToolchainPsramLayerRequestPlanInto*" in npu_source
    layer_request_block = re.search(
        r"proc blaiToolchainPsramLayerRequestPlanInto\*.*?"
        r"proc blaiToolchainPsramLayerRequestPlan\*",
        npu_source,
        re.S,
    )
    assert layer_request_block is not None
    assert "let processDecision =" in layer_request_block.group(0)
    assert "blaiToolchainPsramLayerProcessDecision(layer.layerType)" in (
        layer_request_block.group(0)
    )
    assert "if processDecision.skippedLayer:" in layer_request_block.group(0)
    assert "layer.layerType == BlaiToolchainPsramAllocateSkipLayerType" not in (
        layer_request_block.group(0)
    )
    assert "proc blaiToolchainPsramDspRequestPlanInto*" in npu_source
    assert "proc blaiToolchainPsramDspVolumeRequestPlanInto*" in npu_source
    assert "BlaiToolchainPsramDspRequestScalarAbi* = object" in npu_source
    assert "proc blaiToolchainPsramDspRequestScalarAbi*" in npu_source
    dsp_request_block = re.search(
        r"proc blaiToolchainPsramDspRequestPlanInto\*.*?"
        r"proc blaiToolchainPsramDspRequestPlan\*",
        npu_source,
        re.S,
    )
    assert dsp_request_block is not None
    assert "let areaAField = blaiToolchainPsramDspRequestScalarAbi(areaA)" in (
        dsp_request_block.group(0)
    )
    assert "let areaBField = blaiToolchainPsramDspRequestScalarAbi(areaB)" in (
        dsp_request_block.group(0)
    )
    assert "blaiToolchainPsramDspRequestScalarAbi(countToAlign)" in (
        dsp_request_block.group(0)
    )
    assert "outResult.areaA = areaA.uint32" not in dsp_request_block.group(0)
    assert "outResult.areaB = areaB.uint32" not in dsp_request_block.group(0)
    assert "outResult.countToAlign = countToAlign.uint32" not in (
        dsp_request_block.group(0)
    )
    dsp_volume_request_block = re.search(
        r"proc blaiToolchainPsramDspVolumeRequestPlanInto\*.*?"
        r"proc blaiToolchainPsramDspVolumeRequestPlan\*",
        npu_source,
        re.S,
    )
    assert dsp_volume_request_block is not None
    assert "let factorAField = blaiToolchainPsramDspRequestScalarAbi(factorA)" in (
        dsp_volume_request_block.group(0)
    )
    assert "let factorBField = blaiToolchainPsramDspRequestScalarAbi(factorB)" in (
        dsp_volume_request_block.group(0)
    )
    assert "let factorCField = blaiToolchainPsramDspRequestScalarAbi(factorC)" in (
        dsp_volume_request_block.group(0)
    )
    assert "outResult.factorA = factorA.uint32" not in (
        dsp_volume_request_block.group(0)
    )
    assert "outResult.factorB = factorB.uint32" not in (
        dsp_volume_request_block.group(0)
    )
    assert "outResult.factorC = factorC.uint32" not in (
        dsp_volume_request_block.group(0)
    )
    assert "outResult.volumeElements div outResult.patchSizeBytes" in npu_source
    assert "proc blaiToolchainPsramGeneralPatchPlanInto*" in npu_source
    assert "blaiToolchainPatchOwnerGeneral, prepare.currentLayerIndex" in (
        npu_source
    )
    assert "outResult.generalSearchCall = outResult.dispatch.generalSearchCall" in (
        npu_source
    )
    assert "proc blaiToolchainPsramGeneralPatchApplyPlanInto*" in npu_source
    assert "outResult.patch = patch" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramGeneralPatchState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramGeneralPatch*" in npu_source
    assert "proc blaiApplyToolchainPsramGeneralPatchScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramGeneralPatchScalars*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramGeneralPatchDispatchState*" in npu_source
    )
    assert "proc blaiApplyToolchainPsramGeneralPatchDispatch*" in npu_source
    general_patch_dispatch_apply_block = re.search(
        r"proc blaiApplyToolchainPsramGeneralPatchDispatchState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert general_patch_dispatch_apply_block is not None
    assert "blaiApplyToolchainPsramGeneralPatchDispatchState(" in (
        general_patch_dispatch_apply_block.group(0)
    )
    assert "generalSearchCall = plan.stateAfter.generalSearchCall" not in (
        general_patch_dispatch_apply_block.group(0)
    )
    assert "metadataMode = plan.stateAfter.metadataMode" not in (
        general_patch_dispatch_apply_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        general_patch_dispatch_apply_block.group(0)
    )
    general_patch_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramGeneralPatchScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramGeneralPatchDispatchState\*",
        npu_source,
        re.S,
    )
    assert general_patch_scalar_block is not None
    assert "blaiApplyToolchainPsramGeneralPatchScalarState(" in (
        general_patch_scalar_block.group(0)
    )
    for direct_assignment in (
        "currentLayerIndex = plan.stateAfter.currentLayerIndex",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
        "debugLogFlag = plan.stateAfter.debugLogFlag",
        "generalSearchCall = plan.stateAfter.generalSearchCall",
        "metadataMode = plan.stateAfter.metadataMode",
        "owner = plan.stateAfter.owner",
    ):
        assert direct_assignment not in general_patch_scalar_block.group(0)
    assert "proc blaiToolchainPsramDspPatchPairPlanInto*" in npu_source
    assert "BlaiToolchainPsramDspPatchPairBlock* = enum" in npu_source
    assert "BlaiToolchainPsramDspPatchPairState* = object" in npu_source
    assert "BlaiToolchainPsramDspPatchPairApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramDspPatchPairApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramDspDebugStartOffset* = 0x94AC'u32" in npu_source
    assert "BlaiToolchainPsramTfliteStartOffset* = 0x9C7C'u32" in npu_source
    assert "BlaiToolchainPsramDspDebugStackBytes* = 16'u32" in npu_source
    assert "blaiToolchainPatchOwnerDsp, prepare.currentLayerIndex" in npu_source
    assert "outResult.generalSearchCall = outResult.dispatch.generalSearchCall" in (
        npu_source
    )
    assert "outResult.dspSearchCall = outResult.dispatch.dspSearchCall" in (
        npu_source
    )
    assert "proc blaiToolchainPsramDspPatchPairApplyPlanInto*" in npu_source
    assert "outResult.pair = pair" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramDspPatchPairState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramDspPatchPair*" in npu_source
    assert "proc blaiApplyToolchainPsramDspPatchPairScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramDspPatchPairScalars*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramDspPatchPairDispatchState*" in npu_source
    )
    assert "proc blaiApplyToolchainPsramDspPatchPairDispatch*" in npu_source
    dsp_patch_dispatch_apply_block = re.search(
        r"proc blaiApplyToolchainPsramDspPatchPairDispatchState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert dsp_patch_dispatch_apply_block is not None
    assert "blaiApplyToolchainPsramDspPatchPairDispatchState(" in (
        dsp_patch_dispatch_apply_block.group(0)
    )
    assert "generalSearchCall = plan.stateAfter.generalSearchCall" not in (
        dsp_patch_dispatch_apply_block.group(0)
    )
    assert "dspSearchCall = plan.stateAfter.dspSearchCall" not in (
        dsp_patch_dispatch_apply_block.group(0)
    )
    assert "metadataMode = plan.stateAfter.metadataMode" not in (
        dsp_patch_dispatch_apply_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        dsp_patch_dispatch_apply_block.group(0)
    )
    dsp_patch_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramDspPatchPairScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramDspPatchPairDispatchState\*",
        npu_source,
        re.S,
    )
    assert dsp_patch_scalar_block is not None
    assert "blaiApplyToolchainPsramDspPatchPairScalarState(" in (
        dsp_patch_scalar_block.group(0)
    )
    for direct_assignment in (
        "currentLayerIndex = plan.stateAfter.currentLayerIndex",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
        "debugLogFlag = plan.stateAfter.debugLogFlag",
        "generalSearchCall = plan.stateAfter.generalSearchCall",
        "dspSearchCall = plan.stateAfter.dspSearchCall",
        "metadataMode = plan.stateAfter.metadataMode",
        "owner = plan.stateAfter.owner",
        "dspDebugStartOffset = plan.stateAfter.dspDebugStartOffset",
        "dspDebugStackBytes = plan.stateAfter.dspDebugStackBytes",
        "dspDebugPrintRequested = plan.stateAfter.dspDebugPrintRequested",
        "previousOwnerFlagPushed = plan.stateAfter.previousOwnerFlagPushed",
    ):
        assert direct_assignment not in dsp_patch_scalar_block.group(0)
    assert "outResult.metadataMode = outResult.dispatch.metadataMode" in npu_source
    assert "outResult.dspDebugStartOffset = BlaiToolchainPsramDspDebugStartOffset" in (
        npu_source
    )
    assert "outResult.dspDebugPrintRequested = debugLogFlag" in npu_source
    assert "outResult.previousOwnerFlagPushed = debugLogFlag" in npu_source
    assert "proc blaiToolchainPsramDspVolumePatchPairPlanInto*" in npu_source
    assert "BlaiToolchainPsramDspVolumePatchPairBlock* = enum" in npu_source
    assert "BlaiToolchainPsramDspVolumePatchPairState* = object" in npu_source
    assert "BlaiToolchainPsramDspVolumePatchPairApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramDspVolumePatchPairApplyPlan* = object" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiToolchainPsramDspVolumePatchPairRequest" in (
        npu_source
    )
    assert "outResult.firstBlock = blaiToolchainPsramDspVolumePatchPairPrepare" in (
        npu_source
    )
    assert "request.requestedPatchCount, prepare.relationConsumerLayerIndex" in (
        npu_source
    )
    assert "proc blaiToolchainPsramDspVolumePatchPairApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramDspVolumePatchPairState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramDspVolumePatchPair*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramDspVolumePatchPairScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramDspVolumePatchPairScalars*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramDspVolumePatchPairDispatchState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramDspVolumePatchPairDispatch*" in npu_source
    )
    dsp_volume_dispatch_apply_block = re.search(
        r"proc blaiApplyToolchainPsramDspVolumePatchPairDispatchState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert dsp_volume_dispatch_apply_block is not None
    assert "blaiApplyToolchainPsramDspVolumePatchPairDispatchState(" in (
        dsp_volume_dispatch_apply_block.group(0)
    )
    assert "generalSearchCall = plan.stateAfter.generalSearchCall" not in (
        dsp_volume_dispatch_apply_block.group(0)
    )
    assert "dspSearchCall = plan.stateAfter.dspSearchCall" not in (
        dsp_volume_dispatch_apply_block.group(0)
    )
    assert "metadataMode = plan.stateAfter.metadataMode" not in (
        dsp_volume_dispatch_apply_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        dsp_volume_dispatch_apply_block.group(0)
    )
    dsp_volume_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramDspVolumePatchPairScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramDspVolumePatchPairDispatchState\*",
        npu_source,
        re.S,
    )
    assert dsp_volume_scalar_block is not None
    assert "blaiApplyToolchainPsramDspVolumePatchPairScalarState(" in (
        dsp_volume_scalar_block.group(0)
    )
    for direct_assignment in (
        "currentLayerIndex = plan.stateAfter.currentLayerIndex",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
        "debugLogFlag = plan.stateAfter.debugLogFlag",
        "generalSearchCall = plan.stateAfter.generalSearchCall",
        "dspSearchCall = plan.stateAfter.dspSearchCall",
        "metadataMode = plan.stateAfter.metadataMode",
        "owner = plan.stateAfter.owner",
        "dspDebugStartOffset = plan.stateAfter.dspDebugStartOffset",
        "dspDebugPrintRequested = plan.stateAfter.dspDebugPrintRequested",
    ):
        assert direct_assignment not in dsp_volume_scalar_block.group(0)
    assert "proc blaiToolchainPsramTfliteRequestPlanInto*" in npu_source
    assert "proc blaiToolchainPsramTflitePatchPlanInto*" in npu_source
    assert "BlaiToolchainPsramTfliteRequestScalarAbi* = object" in npu_source
    assert "proc blaiToolchainPsramTfliteRequestScalarAbi*" in npu_source
    assert "BlaiToolchainPsramTflitePatchBlock* = enum" in npu_source
    assert "BlaiToolchainPsramTflitePatchState* = object" in npu_source
    assert "BlaiToolchainPsramTflitePatchApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramTflitePatchApplyPlan* = object" in npu_source
    assert "blaiToolchainPatchOwnerTflite, prepare.currentLayerIndex" in (
        npu_source
    )
    assert "outResult.tfliteSearchCall = outResult.dispatch.tfliteSearchCall" in (
        npu_source
    )
    assert "proc blaiToolchainPsramTflitePatchApplyPlanInto*" in npu_source
    assert "outResult.patch = patch" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramTflitePatchState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramTflitePatch*" in npu_source
    assert "proc blaiApplyToolchainPsramTflitePatchScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramTflitePatchScalars*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramTflitePatchDispatchState*" in npu_source
    )
    assert "proc blaiApplyToolchainPsramTflitePatchDispatch*" in npu_source
    tflite_patch_dispatch_apply_block = re.search(
        r"proc blaiApplyToolchainPsramTflitePatchDispatchState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert tflite_patch_dispatch_apply_block is not None
    assert "blaiApplyToolchainPsramTflitePatchDispatchState(" in (
        tflite_patch_dispatch_apply_block.group(0)
    )
    assert "tfliteSearchCall = plan.stateAfter.tfliteSearchCall" not in (
        tflite_patch_dispatch_apply_block.group(0)
    )
    assert "metadataMode = plan.stateAfter.metadataMode" not in (
        tflite_patch_dispatch_apply_block.group(0)
    )
    assert "owner = plan.stateAfter.owner" not in (
        tflite_patch_dispatch_apply_block.group(0)
    )
    tflite_patch_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramTflitePatchScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramTflitePatchDispatchState\*",
        npu_source,
        re.S,
    )
    assert tflite_patch_scalar_block is not None
    assert "blaiApplyToolchainPsramTflitePatchScalarState(" in (
        tflite_patch_scalar_block.group(0)
    )
    for direct_assignment in (
        "currentLayerIndex = plan.stateAfter.currentLayerIndex",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
        "debugLogFlag = plan.stateAfter.debugLogFlag",
        "tfliteSearchCall = plan.stateAfter.tfliteSearchCall",
        "metadataMode = plan.stateAfter.metadataMode",
        "owner = plan.stateAfter.owner",
    ):
        assert direct_assignment not in tflite_patch_scalar_block.group(0)
    assert "outResult.owner = outResult.dispatch.owner.selectedOwner" in (
        npu_source
    )
    assert "outResult.alignedCount = blaiAlign4(outResult.countToAlign)" in (
        npu_source
    )
    assert "area64 * outResult.alignedCount.uint64" in npu_source
    tflite_request_block = re.search(
        r"proc blaiToolchainPsramTfliteRequestPlanInto\*.*?"
        r"proc blaiToolchainPsramTfliteRequestPlan\*",
        npu_source,
        re.S,
    )
    assert tflite_request_block is not None
    assert "let areaAField = blaiToolchainPsramTfliteRequestScalarAbi(areaA)" in (
        tflite_request_block.group(0)
    )
    assert "let areaBField = blaiToolchainPsramTfliteRequestScalarAbi(areaB)" in (
        tflite_request_block.group(0)
    )
    assert "blaiToolchainPsramTfliteRequestScalarAbi(countToSelect)" in (
        tflite_request_block.group(0)
    )
    assert "outResult.areaA = areaA.uint32" not in tflite_request_block.group(0)
    assert "outResult.areaB = areaB.uint32" not in tflite_request_block.group(0)
    assert "outResult.countToSelect = countToSelect.uint32" not in (
        tflite_request_block.group(0)
    )
    assert "outResult.smallCountForced =" in npu_source
    assert "outResult.countToSelect == 2'u32 or outResult.countToSelect == 3'u32" in (
        npu_source
    )
    assert "area64 * outResult.selectedCount.uint64" in npu_source
    assert "proc blaiToolchainPsramLayerRequestStorePlanInto*" in npu_source
    assert "BlaiToolchainPsramRequestTableIndexAbi* = object" in npu_source
    assert "proc blaiToolchainPsramRequestTableIndexAbi*" in npu_source
    assert "proc blaiToolchainPsramRequestTableCursor*" in npu_source
    assert "BlaiToolchainPsramLayerRequestStoreState* = object" in npu_source
    assert "BlaiToolchainPsramLayerRequestStoreApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramLayerRequestStoreApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramLayerRequestStoreApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramLayerRequestStoreState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramLayerRequestStoreState*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramLayerRequestStoreTableState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramLayerRequestStoreScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramLayerRequestStoreScalars*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramLayerRequestStore*" in npu_source
    assert "outResult.requestTableOffset = BlaiToolchainPatchDebugRequestTableOffset" in (
        npu_source
    )
    layer_request_store_plan_block = re.search(
        r"proc blaiToolchainPsramLayerRequestStorePlanInto\*.*?"
        r"proc blaiToolchainPsramLayerRequestStorePlan\*",
        npu_source,
        re.S,
    )
    assert layer_request_store_plan_block is not None
    assert (
        "let requestTableIndex = blaiToolchainPsramRequestTableIndexAbi(layerIndex)"
        in layer_request_store_plan_block.group(0)
    )
    assert (
        "blaiToolchainPsramRequestTableCursor(\n      requestTableIndex.value, requestTable.len)"
        in layer_request_store_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(requestTableIndex.value, requestTable.len)" not in (
        layer_request_store_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(layerIndex.uint32, requestTable.len)" not in (
        layer_request_store_plan_block.group(0)
    )
    layer_request_store_apply_plan_block = re.search(
        r"proc blaiToolchainPsramLayerRequestStoreApplyPlanInto\*.*?"
        r"proc blaiToolchainPsramLayerRequestStoreApplyPlan\*",
        npu_source,
        re.S,
    )
    assert layer_request_store_apply_plan_block is not None
    assert (
        "blaiToolchainPsramRequestTableIndexAbi(store.layerIndex)"
        in layer_request_store_apply_plan_block.group(0)
    )
    assert "requestTableIndex.value" in layer_request_store_apply_plan_block.group(0)
    assert "store.layerIndex.uint32" not in layer_request_store_apply_plan_block.group(0)
    assert (
        "let applyPlan = blaiToolchainPsramLayerRequestStoreApplyPlan(plan)"
        in npu_source
    )
    layer_request_store_apply_block = re.search(
        r"proc blaiApplyToolchainPsramLayerRequestStore\*\(.*?"
        r"proc blaiToolchainSetWeiPatchCallPlanInto\*",
        npu_source,
        re.S,
    )
    assert layer_request_store_apply_block is not None
    assert "blaiApplyToolchainPsramLayerRequestStoreTableState(" in (
        layer_request_store_apply_block.group(0)
    )
    layer_request_store_table_block = re.search(
        r"proc blaiApplyToolchainPsramLayerRequestStoreTableState\*\(.*?"
        r"proc blaiApplyToolchainPsramLayerRequestStoreScalarState\*",
        npu_source,
        re.S,
    )
    assert layer_request_store_table_block is not None
    assert (
        "blaiToolchainPsramRequestTableCursor(\n      state.requestTableIndex, requestTable.len)"
        in layer_request_store_table_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.requestTableIndex, requestTable.len)" not in (
        layer_request_store_table_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        layer_request_store_apply_block.group(0)
    )
    assert (
        "requestTable[requestCursor.index] = stateAfter.requestedPatchCount"
        not in layer_request_store_apply_block.group(0)
    )
    layer_request_store_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramLayerRequestStoreScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramLayerRequestStore\*\(",
        npu_source,
        re.S,
    )
    assert layer_request_store_scalar_block is not None
    assert "blaiApplyToolchainPsramLayerRequestStoreScalarState(" in (
        layer_request_store_scalar_block.group(0)
    )
    assert "layerIndex = plan.stateAfter.layerIndex" not in (
        layer_request_store_scalar_block.group(0)
    )
    assert "requestTableIndex = plan.stateAfter.requestTableIndex" not in (
        layer_request_store_scalar_block.group(0)
    )
    assert "requestedPatchCount = plan.stateAfter.requestedPatchCount" not in (
        layer_request_store_scalar_block.group(0)
    )
    assert "proc blaiToolchainSetWeiPatchCallPlanInto*" in npu_source
    assert "outResult.byRefPatchCountInitial = 0'i32" in npu_source
    assert "outResult.requestedPatchCount = request.requestedPatchCount" in npu_source
    assert "BlaiToolchainSetWeiPatchNetworkCopyQwords* = 0x47'u32" in (
        npu_source
    )
    assert "BlaiToolchainSetWeiPatchCallFrameBytes* =" in npu_source
    assert "proc blaiToolchainSetWeiPatchCallFramePlanInto*" in npu_source
    assert "outResult.networkCopyBytes = BlaiToolchainSetWeiPatchNetworkCopyBytes" in (
        npu_source
    )
    assert "outResult.byRefPatchCountPrepared =" in npu_source
    assert "proc blaiToolchainSetWeiPatchReturnPlanInto*" in npu_source
    assert "BlaiToolchainSetWeiPatchReturnState* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchReturnApplyBlock* = enum" in npu_source
    assert "BlaiToolchainSetWeiPatchReturnApplyPlan* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchReturnApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainSetWeiPatchReturnState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchReturnState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchReturnScratchState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchReturnScalarState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchReturnScalars*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchReturn*" in npu_source
    set_wei_return_scalar_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchReturnScalarState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchReturn\*\(",
        npu_source,
        re.S,
    )
    assert set_wei_return_scalar_block is not None
    assert "blaiApplyToolchainSetWeiPatchReturnScalarState(" in (
        set_wei_return_scalar_block.group(0)
    )
    assert "scratchPatchCount = plan.stateAfter.scratchPatchCount" not in (
        set_wei_return_scalar_block.group(0)
    )
    assert "byRefPatchCountInitial = plan.stateAfter.byRefPatchCountInitial" not in (
        set_wei_return_scalar_block.group(0)
    )
    assert "byRefPatchCountAfter = plan.stateAfter.byRefPatchCountAfter" not in (
        set_wei_return_scalar_block.group(0)
    )
    assert "changed = plan.stateAfter.changed" not in (
        set_wei_return_scalar_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchByRefResultFrameOffset* = 0xC7C'u32" in (
        npu_source
    )
    assert "BlaiToolchainSetWeiPatchReturnStoreFrameOffset* = 0xBB0'u32" in (
        npu_source
    )
    assert "proc blaiToolchainSetWeiPatchReturnFramePlanInto*" in npu_source
    assert "outResult.scratchPatchCount = byRefPatchCountAfter" in npu_source
    assert "outResult.resultCopiedToCallerFrame = true" in npu_source
    assert "outResult.frameUnwindMatchesCallFrame =" in npu_source
    set_wei_return_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchReturn\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert set_wei_return_block is not None
    assert "blaiApplyToolchainSetWeiPatchReturnScratchState(" in (
        set_wei_return_block.group(0)
    )
    assert "scratchPatchCount = applyPlan.stateAfter.scratchPatchCount" not in (
        set_wei_return_block.group(0)
    )
    assert "proc blaiToolchainPsramOwnerTransitionPlanInto*" in npu_source
    assert "BlaiToolchainPsramOwnerTransitionState* = object" in npu_source
    assert "BlaiToolchainPsramOwnerTransitionApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramOwnerTransitionApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerTransitionApplyEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramOwnerTransitionApplyEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramOwnerTransitionApplyEvidence*" in npu_source
    assert "proc blaiToolchainPsramOwnerTransitionApplyPlanInto*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramOwnerTransitionTablesState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramOwnerTransitionScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramOwnerTransitionScalars*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerTransitionState*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerTransition*" in npu_source
    assert "let applyPlan = blaiToolchainPsramOwnerTransitionApplyPlan(" in (
        npu_source
    )
    owner_transition_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerTransitionPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerTransitionPlan\*",
        npu_source,
        re.S,
    )
    assert owner_transition_plan_block is not None
    assert "startPatchSlot == BlaiToolchainPatchInvalidStartSlot" in (
        owner_transition_plan_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(slot, owners.len)" in (
        owner_transition_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(slot, owners.len)" not in (
        owner_transition_plan_block.group(0)
    )
    assert "-1'i32" not in owner_transition_plan_block.group(0)
    owner_transition_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramOwnerTransitionApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramOwnerTransitionApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert owner_transition_apply_evidence_block is not None
    assert (
        "result.occupiedCursor =\n    blaiToolchainPatchOccupiedCursor(transition.slot, occupied.len)"
        in owner_transition_apply_evidence_block.group(0)
    )
    assert (
        "result.ownerCursor =\n    blaiToolchainPatchOwnerCursor(transition.slot, owners.len)"
        in owner_transition_apply_evidence_block.group(0)
    )
    assert "result.storageValid =" in owner_transition_apply_evidence_block.group(0)
    assert "result.stateAfter = blaiToolchainPsramOwnerTransitionState(" in (
        owner_transition_apply_evidence_block.group(0)
    )
    owner_transition_apply_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerTransitionApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerTransitionApplyPlan\*",
        npu_source,
        re.S,
    )
    assert owner_transition_apply_plan_block is not None
    assert (
        "let evidence = blaiToolchainPsramOwnerTransitionApplyEvidence("
        in owner_transition_apply_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        owner_transition_apply_plan_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        owner_transition_apply_plan_block.group(0)
    )
    assert "blaiToolchainPsramOwnerTransitionState(" not in (
        owner_transition_apply_plan_block.group(0)
    )
    assert (
        "blaiToolchainPatchOccupiedCursor(transition.slot, occupied.len)"
        not in owner_transition_apply_plan_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(transition.slot, owners.len)" not in (
        owner_transition_apply_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(transition.slot, occupied.len)" not in (
        owner_transition_apply_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(transition.slot, owners.len)" not in (
        owner_transition_apply_plan_block.group(0)
    )
    owner_transition_apply_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerTransitionState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerTransition\*",
        npu_source,
        re.S,
    )
    assert owner_transition_apply_block is not None
    assert "blaiApplyToolchainPsramOwnerTransitionTablesState(" in (
        owner_transition_apply_block.group(0)
    )
    assert "owners[ownerCursor.index] = plan.stateAfter.ownerAfter" not in (
        owner_transition_apply_block.group(0)
    )
    assert "occupied[occupiedCursor.index] = plan.stateAfter.occupiedAfter" not in (
        owner_transition_apply_block.group(0)
    )
    owner_transition_tables_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerTransitionTablesState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerTransitionScalarState\*",
        npu_source,
        re.S,
    )
    assert owner_transition_tables_block is not None
    assert "blaiToolchainPatchOccupiedCursor(state.slot, occupied.len)" in (
        owner_transition_tables_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(state.slot, owners.len)" in (
        owner_transition_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, occupied.len)" not in (
        owner_transition_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, owners.len)" not in (
        owner_transition_tables_block.group(0)
    )
    owner_transition_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerTransitionScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerTransitionState\*",
        npu_source,
        re.S,
    )
    assert owner_transition_scalar_block is not None
    assert "blaiApplyToolchainPsramOwnerTransitionScalarState(" in (
        owner_transition_scalar_block.group(0)
    )
    for direct_assignment in (
        "slot = plan.stateAfter.slot",
        "action = plan.stateAfter.action",
        "ownerBefore = plan.stateAfter.ownerBefore",
        "ownerAfter = plan.stateAfter.ownerAfter",
        "occupiedAfter = plan.stateAfter.occupiedAfter",
        "writesOwner = plan.stateAfter.writesOwner",
        "writesOccupied = plan.stateAfter.writesOccupied",
    ):
        assert direct_assignment not in owner_transition_scalar_block.group(0)
    assert "proc blaiToolchainPsramOwnerCleanupPlanInto*" in npu_source
    assert "BlaiToolchainPsramCleanupRetainPlan* = object" in npu_source
    assert "proc blaiToolchainPsramCleanupRetainPlan*" in npu_source
    cleanup_retain_block = re.search(
        r"proc blaiToolchainPsramCleanupRetainPlan\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupPlanInto\*",
        npu_source,
        re.S,
    )
    assert cleanup_retain_block is not None
    assert "startPatchSlot == BlaiToolchainPatchInvalidStartSlot" in (
        cleanup_retain_block.group(0)
    )
    assert "result.convRouteRetain =" in cleanup_retain_block.group(0)
    assert "result.routeDebugRetain =" in cleanup_retain_block.group(0)
    assert "result.retain = result.convRouteRetain or result.invalidStartRetain" in (
        cleanup_retain_block.group(0)
    )
    assert "BlaiToolchainPsramOwnerCleanupState* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupApplyEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramOwnerCleanupApplyEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramOwnerCleanupApplyEvidence*" in npu_source
    assert "proc blaiToolchainPsramOwnerCleanupApplyPlanInto*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanupTablesState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramOwnerCleanupScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramOwnerCleanupScalars*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanupState*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanup*" in npu_source
    assert "let applyPlan = blaiToolchainPsramOwnerCleanupApplyPlan(" in (
        npu_source
    )
    owner_cleanup_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupPlan\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_plan_block is not None
    assert "let retainPlan =" in owner_cleanup_plan_block.group(0)
    assert "blaiToolchainPsramCleanupRetainPlan(" in (
        owner_cleanup_plan_block.group(0)
    )
    assert "if retainPlan.retain:" in owner_cleanup_plan_block.group(0)
    assert "let retain =\n    if currentLayerTypeValue" not in (
        owner_cleanup_plan_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(slot, owners.len)" in (
        owner_cleanup_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(slot, owners.len)" not in (
        owner_cleanup_plan_block.group(0)
    )
    assert "-1'i32" not in owner_cleanup_plan_block.group(0)
    owner_cleanup_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_apply_evidence_block is not None
    assert (
        "result.occupiedCursor =\n    blaiToolchainPatchOccupiedCursor(cleanup.slot, occupied.len)"
        in owner_cleanup_apply_evidence_block.group(0)
    )
    assert (
        "result.ownerCursor =\n    blaiToolchainPatchOwnerCursor(cleanup.slot, owners.len)"
        in owner_cleanup_apply_evidence_block.group(0)
    )
    assert "result.storageValid =" in owner_cleanup_apply_evidence_block.group(0)
    assert "result.stateAfter = blaiToolchainPsramOwnerCleanupState(" in (
        owner_cleanup_apply_evidence_block.group(0)
    )
    owner_cleanup_apply_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupApplyPlan\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_apply_plan_block is not None
    assert (
        "let evidence = blaiToolchainPsramOwnerCleanupApplyEvidence("
        in
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "blaiToolchainPsramOwnerCleanupState(" not in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "blaiToolchainPatchOccupiedCursor(cleanup.slot, occupied.len)" not in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(cleanup.slot, owners.len)" not in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(cleanup.slot, occupied.len)" not in (
        owner_cleanup_apply_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(cleanup.slot, owners.len)" not in (
        owner_cleanup_apply_plan_block.group(0)
    )
    owner_cleanup_apply_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerCleanupState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerCleanup\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_apply_block is not None
    assert "blaiApplyToolchainPsramOwnerCleanupTablesState(" in (
        owner_cleanup_apply_block.group(0)
    )
    assert "owners[ownerCursor.index] = plan.stateAfter.ownerAfter" not in (
        owner_cleanup_apply_block.group(0)
    )
    assert "occupied[occupiedCursor.index] = plan.stateAfter.occupiedAfter" not in (
        owner_cleanup_apply_block.group(0)
    )
    owner_cleanup_tables_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerCleanupTablesState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerCleanupScalarState\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_tables_block is not None
    assert "blaiToolchainPatchOccupiedCursor(state.slot, occupied.len)" in (
        owner_cleanup_tables_block.group(0)
    )
    assert "blaiToolchainPatchOwnerCursor(state.slot, owners.len)" in (
        owner_cleanup_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, occupied.len)" not in (
        owner_cleanup_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, owners.len)" not in (
        owner_cleanup_tables_block.group(0)
    )
    owner_cleanup_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerCleanupScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerCleanupState\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_scalar_block is not None
    assert "blaiApplyToolchainPsramOwnerCleanupScalarState(" in (
        owner_cleanup_scalar_block.group(0)
    )
    for direct_assignment in (
        "slot = plan.stateAfter.slot",
        "action = plan.stateAfter.action",
        "ownerBefore = plan.stateAfter.ownerBefore",
        "ownerAfter = plan.stateAfter.ownerAfter",
        "occupiedAfter = plan.stateAfter.occupiedAfter",
        "writesOwner = plan.stateAfter.writesOwner",
        "writesOccupied = plan.stateAfter.writesOccupied",
    ):
        assert direct_assignment not in owner_cleanup_scalar_block.group(0)
    assert "proc blaiToolchainPsramOwnerCleanupSweepPlanInto*" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupSweepState* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupSweepApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupSweepApplyPlan* = object" in npu_source
    assert "BlaiToolchainPsramOwnerCleanupSweepApplyEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramOwnerCleanupSweepApplyEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramOwnerCleanupSweepApplyEvidence*" in (
        npu_source
    )
    assert "proc blaiToolchainPsramOwnerCleanupSweepApplyPlanInto*" in (
        npu_source
    )
    cleanup_sweep_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupSweepApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupSweepApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert cleanup_sweep_apply_evidence_block is not None
    assert "result.sweepValid = sweep.valid" in (
        cleanup_sweep_apply_evidence_block.group(0)
    )
    assert "result.storageValid =" in cleanup_sweep_apply_evidence_block.group(0)
    assert "result.stateAfter = blaiToolchainPsramOwnerCleanupSweepState(" in (
        cleanup_sweep_apply_evidence_block.group(0)
    )
    cleanup_sweep_apply_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupSweepApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupSweepApplyPlan\*",
        npu_source,
        re.S,
    )
    assert cleanup_sweep_apply_plan_block is not None
    assert (
        "let evidence = blaiToolchainPsramOwnerCleanupSweepApplyEvidence("
        in cleanup_sweep_apply_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        cleanup_sweep_apply_plan_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        cleanup_sweep_apply_plan_block.group(0)
    )
    assert "blaiToolchainPsramOwnerCleanupSweepState(" not in (
        cleanup_sweep_apply_plan_block.group(0)
    )
    assert "proc blaiApplyToolchainPsramOwnerCleanupSweepState*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanupSweepScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramOwnerCleanupSweepScalars*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanupSweep*" in npu_source
    assert "let slotApplyPlan = blaiToolchainPsramOwnerCleanupApplyPlan(" in (
        npu_source
    )
    cleanup_sweep_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerCleanupSweep\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert cleanup_sweep_block is not None
    assert "blaiApplyToolchainPsramOwnerCleanupSweepState(" in (
        cleanup_sweep_block.group(0)
    )
    assert "for slot in 0'u32 ..< applyPlan.stateAfter.slotCount:" not in (
        cleanup_sweep_block.group(0)
    )
    cleanup_sweep_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramOwnerCleanupSweepScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramOwnerCleanupSweepState\*",
        npu_source,
        re.S,
    )
    assert cleanup_sweep_scalar_block is not None
    assert "blaiApplyToolchainPsramOwnerCleanupSweepScalarState(" in (
        cleanup_sweep_scalar_block.group(0)
    )
    for direct_assignment in (
        "slotCount = plan.stateAfter.slotCount",
        "occupiedStorageCount = plan.stateAfter.occupiedStorageCount",
        "ownerStorageCount = plan.stateAfter.ownerStorageCount",
        "scannedSlots = plan.stateAfter.scannedSlots",
        "ignoredSlots = plan.stateAfter.ignoredSlots",
        "transferredSlots = plan.stateAfter.transferredSlots",
        "releasedSlots = plan.stateAfter.releasedSlots",
    ):
        assert direct_assignment not in cleanup_sweep_scalar_block.group(0)
    assert "BlaiToolchainPsramOwnerCleanupSweepTally* = object" in npu_source
    assert "proc blaiToolchainPsramOwnerCleanupSweepTally*" in npu_source
    assert "outResult.slotCount = BlaiToolchainMaxPsramPatchSlots" in npu_source
    owner_cleanup_sweep_plan_block = re.search(
        r"proc blaiToolchainPsramOwnerCleanupSweepPlanInto\*\(.*?"
        r"proc blaiToolchainPsramOwnerCleanupSweepPlan\*",
        npu_source,
        re.S,
    )
    assert owner_cleanup_sweep_plan_block is not None
    assert "for slot in 0'u32 ..< outResult.slotCount:" in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "let slotTally =" in owner_cleanup_sweep_plan_block.group(0)
    assert "blaiToolchainPsramOwnerCleanupSweepTally(slotPlan.action)" in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "outResult.transferredSlots += slotTally.transferredSlots" in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "outResult.releasedSlots += slotTally.releasedSlots" in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "inc outResult.transferredSlots" not in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "inc outResult.releasedSlots" not in (
        owner_cleanup_sweep_plan_block.group(0)
    )
    assert "proc blaiToolchainPsramCleanupEntryPlanInto*" in npu_source
    assert "maxPatchSlots: int32 = BlaiToolchainMaxPsramPatchSlotsI32" in (
        npu_source
    )
    assert "BlaiToolchainMaxPsramPatchSlots.int32" not in npu_source
    assert "BlaiToolchainPsramCleanupEntryState* = object" in npu_source
    assert "BlaiToolchainPsramCleanupEntryApplyEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramCleanupEntryApplyEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramCleanupEntryApplyEvidence*" in npu_source
    assert "proc blaiToolchainPsramCleanupEntryApplyPlanInto*" in npu_source
    cleanup_entry_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramCleanupEntryApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramCleanupEntryApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert cleanup_entry_apply_evidence_block is not None
    assert "result.entryValid = entry.valid" in (
        cleanup_entry_apply_evidence_block.group(0)
    )
    assert "result.stateAfter = blaiToolchainPsramCleanupEntryState(" in (
        cleanup_entry_apply_evidence_block.group(0)
    )
    cleanup_entry_apply_plan_block = re.search(
        r"proc blaiToolchainPsramCleanupEntryApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramCleanupEntryApplyPlan\*",
        npu_source,
        re.S,
    )
    assert cleanup_entry_apply_plan_block is not None
    assert "let evidence = blaiToolchainPsramCleanupEntryApplyEvidence(" in (
        cleanup_entry_apply_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        cleanup_entry_apply_plan_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        cleanup_entry_apply_plan_block.group(0)
    )
    assert "blaiToolchainPsramCleanupEntryState(" not in (
        cleanup_entry_apply_plan_block.group(0)
    )
    assert "proc blaiApplyToolchainPsramCleanupEntryScalarState*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramCleanupEntrySummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramCleanupEntrySummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramCleanupEntryState*" in npu_source
    assert "proc blaiApplyToolchainPsramCleanupEntry*" in npu_source
    assert "outResult.savedDebugLogFlag = debugLogFlag" in npu_source
    assert "outResult.debugSnapshotPath = debugLogFlag" in npu_source
    assert "outResult.nextLayerIndex = currentLayerIndex + 1'i32" in npu_source
    assert "outResult.cleanupSlotStart = 0'u32" in npu_source
    assert "outResult.entersCleanupSweep = maxPatchSlots > 0" in npu_source
    assert "outResult.jumpsLayerTransition = not outResult.entersCleanupSweep" in (
        npu_source
    )
    cleanup_entry_apply_block = re.search(
        r"proc blaiApplyToolchainPsramCleanupEntry\*\(.*?"
        r"proc blaiApplyToolchainPsramCleanupEntryState\*",
        npu_source,
        re.S,
    )
    assert cleanup_entry_apply_block is not None
    assert "blaiApplyToolchainPsramCleanupEntryScalarState(" in (
        cleanup_entry_apply_block.group(0)
    )
    assert "nextLayerIndex = plan.stateAfter.nextLayerIndex" not in (
        cleanup_entry_apply_block.group(0)
    )
    assert "cleanupSlot = plan.stateAfter.cleanupSlotStart" not in (
        cleanup_entry_apply_block.group(0)
    )
    assert "savedDebugLogFlag = plan.stateAfter.savedDebugLogFlag" not in (
        cleanup_entry_apply_block.group(0)
    )
    cleanup_entry_summary_block = re.search(
        r"proc blaiApplyToolchainPsramCleanupEntrySummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramCleanupEntry\*",
        npu_source,
        re.S,
    )
    assert cleanup_entry_summary_block is not None
    assert "blaiApplyToolchainPsramCleanupEntrySummaryScalarState(" in (
        cleanup_entry_summary_block.group(0)
    )
    for direct_assignment in (
        "nextLayerIndex = plan.stateAfter.nextLayerIndex",
        "cleanupSlot = plan.stateAfter.cleanupSlotStart",
        "savedDebugLogFlag = plan.stateAfter.savedDebugLogFlag",
        "debugSnapshotPath = plan.stateAfter.debugSnapshotPath",
        "entersCleanupSweep = plan.stateAfter.entersCleanupSweep",
        "jumpsLayerTransition = plan.stateAfter.jumpsLayerTransition",
    ):
        assert direct_assignment not in cleanup_entry_summary_block.group(0)
    assert "proc blaiToolchainPsramPostSearchSlotPlanInto*" in npu_source
    assert "proc blaiToolchainPatchSlotValueCursor*" in npu_source
    assert "BlaiToolchainPsramPostSearchSlotState* = object" in npu_source
    assert "BlaiToolchainPsramPostSearchSlotApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramPostSearchSlotApplyPlan* = object" in npu_source
    assert (
        "BlaiToolchainPsramPostSearchSlotApplyEvidence* = object"
        in npu_source
    )
    assert "evidence*: BlaiToolchainPsramPostSearchSlotApplyEvidence" in (
        npu_source
    )
    assert (
        "proc blaiToolchainPsramPostSearchSlotApplyEvidence*" in npu_source
    )
    assert "proc blaiToolchainPsramPostSearchSlotApplyPlanInto*" in npu_source
    post_search_slot_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramPostSearchSlotApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramPostSearchSlotApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_apply_evidence_block is not None
    assert "result.slotPlanValid = slotPlan.valid" in (
        post_search_slot_apply_evidence_block.group(0)
    )
    assert "result.stateAfter = blaiToolchainPsramPostSearchSlotState(" in (
        post_search_slot_apply_evidence_block.group(0)
    )
    post_search_slot_apply_plan_into_block = re.search(
        r"proc blaiToolchainPsramPostSearchSlotApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramPostSearchSlotApplyPlan\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_apply_plan_into_block is not None
    assert "let evidence = blaiToolchainPsramPostSearchSlotApplyEvidence(" in (
        post_search_slot_apply_plan_into_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        post_search_slot_apply_plan_into_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        post_search_slot_apply_plan_into_block.group(0)
    )
    assert "blaiToolchainPsramPostSearchSlotState(" not in (
        post_search_slot_apply_plan_into_block.group(0)
    )
    assert "proc blaiApplyToolchainPsramPostSearchSlotState*" in npu_source
    assert "proc blaiApplyToolchainPsramPostSearchSlotTablesState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramPostSearchSlotScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramPostSearchSlotScalars*" in npu_source
    assert "proc blaiApplyToolchainPsramPostSearchSlot*" in npu_source
    assert "BlaiToolchainPsramPostSearchSlotAction* = enum" in npu_source
    assert "outResult.slotValueBefore = slotValues[slotCursor.index]" in (
        npu_source
    )
    assert "outResult.slotValueAfter = retainedValue" in npu_source
    post_search_slot_plan_block = re.search(
        r"proc blaiToolchainPsramPostSearchSlotPlanInto\*\(.*?"
        r"proc blaiToolchainPsramPostSearchSlotPlan\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_plan_block is not None
    assert "let retainPlan =" in post_search_slot_plan_block.group(0)
    assert "blaiToolchainPsramCleanupRetainPlan(" in (
        post_search_slot_plan_block.group(0)
    )
    assert "if retainPlan.retain:" in post_search_slot_plan_block.group(0)
    assert "let retain =\n    if currentLayerTypeValue" not in (
        post_search_slot_plan_block.group(0)
    )
    assert "blaiToolchainPatchSlotValueCursor(slot, slotValues.len)" in (
        post_search_slot_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(slot, slotValues.len)" not in (
        post_search_slot_plan_block.group(0)
    )
    assert "-1'i32" not in post_search_slot_plan_block.group(0)
    assert "let applyPlan = blaiToolchainPsramPostSearchSlotApplyPlan(plan)" in (
        npu_source
    )
    post_search_slot_apply_block = re.search(
        r"proc blaiApplyToolchainPsramPostSearchSlot\*\(.*?"
        r"proc blaiToolchainPsramCleanupDebugSlotPlanInto\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_apply_block is not None
    assert "blaiApplyToolchainPsramPostSearchSlotTablesState(" in (
        post_search_slot_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        post_search_slot_apply_block.group(0)
    )
    assert "of blaiToolchainPsramPostSearchSlotStoreRetained:" in npu_source
    assert "slotValues[slotCursor.index] = state.slotValueAfter" in (
        npu_source
    )
    post_search_slot_tables_block = re.search(
        r"proc blaiApplyToolchainPsramPostSearchSlotTablesState\*\(.*?"
        r"proc blaiApplyToolchainPsramPostSearchSlotScalarState\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_tables_block is not None
    assert "blaiToolchainPatchOccupiedCursor(state.slot, occupied.len)" in (
        post_search_slot_tables_block.group(0)
    )
    assert "blaiToolchainPatchSlotValueCursor(state.slot, slotValues.len)" in (
        post_search_slot_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, occupied.len)" not in (
        post_search_slot_tables_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(state.slot, slotValues.len)" not in (
        post_search_slot_tables_block.group(0)
    )
    assert "slotValues[slotCursor.index] = stateAfter.slotValueAfter" not in (
        post_search_slot_apply_block.group(0)
    )
    post_search_slot_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramPostSearchSlotScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramPostSearchSlot\*",
        npu_source,
        re.S,
    )
    assert post_search_slot_scalar_block is not None
    assert "blaiApplyToolchainPsramPostSearchSlotScalarState(" in (
        post_search_slot_scalar_block.group(0)
    )
    assert "slot = plan.stateAfter.slot" not in (
        post_search_slot_scalar_block.group(0)
    )
    assert "action = plan.stateAfter.action" not in (
        post_search_slot_scalar_block.group(0)
    )
    assert "proc blaiToolchainPsramCleanupDebugSlotPlanInto*" in npu_source
    assert "outResult.occupiedStorageCount = blaiOpenArrayLenU32(occupied)" in (
        npu_source
    )
    assert "outResult.printRequested = debugLogFlag" in npu_source
    assert "outResult.occupiedValue = occupied[occupiedCursor.index]" in npu_source
    cleanup_debug_slot_block = re.search(
        r"proc blaiToolchainPsramCleanupDebugSlotPlanInto\*\(.*?"
        r"proc blaiToolchainPsramCleanupDebugSlotPlan\*",
        npu_source,
        re.S,
    )
    assert cleanup_debug_slot_block is not None
    assert "blaiToolchainPatchOccupiedCursor(slot, occupied.len)" in (
        cleanup_debug_slot_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(slot, occupied.len)" not in (
        cleanup_debug_slot_block.group(0)
    )
    assert "BlaiToolchainPsramCleanupDebugSlotSummaryState* = object" in (
        npu_source
    )
    assert "summaryStateAfter*: BlaiToolchainPsramCleanupDebugSlotSummaryState" in (
        npu_source
    )
    assert (
        "BlaiToolchainPsramCleanupDebugSlotApplyEvidence* = object"
        in npu_source
    )
    assert (
        "evidence*: BlaiToolchainPsramCleanupDebugSlotApplyEvidence"
        in npu_source
    )
    assert "proc blaiToolchainPsramCleanupDebugSlotSummaryState*" in npu_source
    assert (
        "proc blaiToolchainPsramCleanupDebugSlotApplyEvidence*" in npu_source
    )
    assert "proc blaiToolchainPsramCleanupDebugSlotApplyPlanInto*" in npu_source
    assert "outResult.slot = slot" in npu_source
    cleanup_debug_slot_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramCleanupDebugSlotApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramCleanupDebugSlotApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert cleanup_debug_slot_apply_evidence_block is not None
    assert "result.slotPlanValid = slot.valid" in (
        cleanup_debug_slot_apply_evidence_block.group(0)
    )
    assert (
        "result.summaryStateAfter = blaiToolchainPsramCleanupDebugSlotSummaryState("
        in cleanup_debug_slot_apply_evidence_block.group(0)
    )
    assert "result.stateAfter = blaiToolchainPsramCleanupDebugSlotState" in (
        cleanup_debug_slot_apply_evidence_block.group(0)
    )
    cleanup_debug_slot_apply_plan_into_block = re.search(
        r"proc blaiToolchainPsramCleanupDebugSlotApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramCleanupDebugSlotApplyPlan\*",
        npu_source,
        re.S,
    )
    assert cleanup_debug_slot_apply_plan_into_block is not None
    assert "let evidence = blaiToolchainPsramCleanupDebugSlotApplyEvidence(" in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "outResult.summaryStateAfter = evidence.summaryStateAfter" in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "blaiToolchainPsramCleanupDebugSlotSummaryState(" not in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "blaiToolchainPsramCleanupDebugSlotState(" not in (
        cleanup_debug_slot_apply_plan_into_block.group(0)
    )
    assert "proc blaiApplyToolchainPsramCleanupDebugSlot*" in npu_source
    assert "proc blaiApplyToolchainPsramCleanupDebugSlotScalarState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramCleanupDebugSlotSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramCleanupDebugSlotSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramCleanupDebugSlotScalars*" in (
        npu_source
    )
    cleanup_debug_slot_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramCleanupDebugSlotScalarState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert cleanup_debug_slot_scalar_block is not None
    assert "blaiApplyToolchainPsramCleanupDebugSlotScalarState(" in (
        cleanup_debug_slot_scalar_block.group(0)
    )
    cleanup_debug_slot_summary_block = re.search(
        r"proc blaiApplyToolchainPsramCleanupDebugSlotSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramCleanupDebugSlotScalars\*",
        npu_source,
        re.S,
    )
    assert cleanup_debug_slot_summary_block is not None
    assert "blaiApplyToolchainPsramCleanupDebugSlotSummaryScalarState(" in (
        cleanup_debug_slot_summary_block.group(0)
    )
    for direct_assignment in (
        "printRequested = plan.printRequested",
        "printRequested = plan.summaryStateAfter.printRequested",
        "slot = plan.summaryStateAfter.slot",
        "occupiedValue = plan.summaryStateAfter.occupiedValue",
    ):
        assert direct_assignment not in cleanup_debug_slot_summary_block.group(0)
    assert "slot = plan.stateAfter.slot" not in (
        cleanup_debug_slot_scalar_block.group(0)
    )
    assert "occupiedValue = plan.stateAfter.occupiedValue" not in (
        cleanup_debug_slot_scalar_block.group(0)
    )
    assert "proc blaiToolchainPsramMetadataDiscardPlanInto*" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardGate* = object" in npu_source
    assert "proc blaiToolchainPsramMetadataDiscardGate*" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardState* = object" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardApplyPlan* = object" in npu_source
    assert "proc blaiToolchainPsramMetadataDiscardApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramMetadataDiscardState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramMetadataDiscardState*" in npu_source
    assert "proc blaiApplyToolchainPsramMetadataDiscardScalarState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramMetadataDiscardSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramMetadataDiscardSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramMetadataDiscardBankState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramMetadataDiscard*" in npu_source
    assert "proc blaiApplyToolchainPsramMetadataDiscardBanks*" in npu_source
    assert "BlaiToolchainPsramMetadataBankIndexAbi* = object" in npu_source
    assert "proc blaiToolchainPsramMetadataBankIndexAbi*" in npu_source
    assert "BlaiToolchainPsramMetadataDiscardFieldAOffset* = 0xA40'u32" in (
        npu_source
    )
    assert "BlaiToolchainPsramMetadataDiscardFieldBOffset* = 0xA30'u32" in (
        npu_source
    )
    assert "BlaiToolchainPatchInvalidStartSlot* = -1'i32" in npu_source
    assert "BlaiToolchainPatchInvalidCount* = -1'i32" in npu_source
    assert "outResult.clearGeneralMetadata =" in npu_source
    assert "outResult.generalStartOffset = BlaiToolchainPatchDebugGeneralStartOffset" in (
        npu_source
    )
    assert "outResult.generalCountOffset = BlaiToolchainPatchDebugGeneralCountOffset" in (
        npu_source
    )
    assert (
        "outResult.startPatchSlotAfter = BlaiToolchainPatchInvalidStartSlot"
        in npu_source
    )
    assert (
        "outResult.patchCountAfter = BlaiToolchainPatchInvalidCount" in npu_source
    )
    assert (
        "doAssert metadataDiscardPlan.startPatchSlotAfter ==\n"
        "    BlaiToolchainPatchInvalidStartSlot"
        in npu_source
    )
    assert (
        "doAssert metadataDiscardPlan.patchCountAfter == "
        "BlaiToolchainPatchInvalidCount"
        in npu_source
    )
    metadata_discard_gate_block = re.search(
        r"proc blaiToolchainPsramMetadataDiscardGate\*\(.*?"
        r"proc blaiToolchainPsramMetadataDiscardPlanInto\*",
        npu_source,
        re.S,
    )
    assert metadata_discard_gate_block is not None
    assert (
        "layerInputCount == BlaiToolchainPsramMetadataDiscardInputCount"
        in metadata_discard_gate_block.group(0)
    )
    assert "nextLayerTypeValue == BlaiToolchainPsramOwnerRouteType" in (
        metadata_discard_gate_block.group(0)
    )
    assert "fieldAValue == BlaiToolchainPsramMetadataDiscardFieldValue" in (
        metadata_discard_gate_block.group(0)
    )
    assert "fieldBValue == BlaiToolchainPsramMetadataDiscardFieldValue" in (
        metadata_discard_gate_block.group(0)
    )
    assert "result.noFutureConsumer = not relationConsumerFound" in (
        metadata_discard_gate_block.group(0)
    )
    metadata_discard_plan_block = re.search(
        r"proc blaiToolchainPsramMetadataDiscardPlanInto\*\(.*?"
        r"proc blaiToolchainPsramMetadataDiscardPlan\*",
        npu_source,
        re.S,
    )
    assert metadata_discard_plan_block is not None
    assert "let discardGate =" in metadata_discard_plan_block.group(0)
    assert "blaiToolchainPsramMetadataDiscardGate(" in (
        metadata_discard_plan_block.group(0)
    )
    assert "outResult.clearGeneralMetadata = discardGate.clearGeneralMetadata" in (
        metadata_discard_plan_block.group(0)
    )
    assert (
        "layerInputCount == BlaiToolchainPsramMetadataDiscardInputCount and"
        not in metadata_discard_plan_block.group(0)
    )
    assert "-1'i32" not in metadata_discard_plan_block.group(0)
    metadata_discard_apply_block = re.search(
        r"proc blaiApplyToolchainPsramMetadataDiscard\*\(.*?"
        r"proc blaiToolchainPsramFallbackGatePlanInto\*",
        npu_source,
        re.S,
    )
    assert metadata_discard_apply_block is not None
    assert "let applyPlan = blaiToolchainPsramMetadataDiscardApplyPlan(plan)" in (
        metadata_discard_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramMetadataDiscardScalarState(" in (
        metadata_discard_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramMetadataDiscardBankState(" in (
        metadata_discard_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        metadata_discard_apply_block.group(0)
    )
    assert (
        "startPatchSlot = stateAfter.startPatchSlotAfter"
        not in metadata_discard_apply_block.group(0)
    )
    metadata_discard_bank_block = re.search(
        r"proc blaiApplyToolchainPsramMetadataDiscardBankState\*\(.*?"
        r"proc blaiApplyToolchainPsramMetadataDiscard\*",
        npu_source,
        re.S,
    )
    assert metadata_discard_bank_block is not None
    assert "blaiToolchainPsramMetadataBankIndexAbi(" in (
        metadata_discard_bank_block.group(0)
    )
    assert "blaiToolchainPsramMetadataBankCursor(" in (
        metadata_discard_bank_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(bankIndex.value" not in (
        metadata_discard_bank_block.group(0)
    )
    assert "state.currentLayerIndex.uint32" not in (
        metadata_discard_bank_block.group(0)
    )
    assert "patchCount = stateAfter.patchCountAfter" not in (
        metadata_discard_apply_block.group(0)
    )
    assert (
        "startPatchSlots[startCursor.index] = stateAfter.startPatchSlotAfter"
        not in metadata_discard_apply_block.group(0)
    )
    assert (
        "patchCounts[countCursor.index] = stateAfter.patchCountAfter"
        not in metadata_discard_apply_block.group(0)
    )
    assert "plan.startPatchSlotAfter" not in metadata_discard_apply_block.group(0)
    assert "plan.patchCountAfter" not in metadata_discard_apply_block.group(0)
    metadata_discard_summary_block = re.search(
        r"proc blaiApplyToolchainPsramMetadataDiscardSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramMetadataDiscardBankState\*",
        npu_source,
        re.S,
    )
    assert metadata_discard_summary_block is not None
    assert "blaiApplyToolchainPsramMetadataDiscardSummaryScalarState(" in (
        metadata_discard_summary_block.group(0)
    )
    for direct_assignment in (
        "currentLayerIndex = plan.stateAfter.currentLayerIndex",
        "generalStartOffset = plan.stateAfter.generalStartOffset",
        "generalCountOffset = plan.stateAfter.generalCountOffset",
        "clearGeneralMetadata = plan.stateAfter.clearGeneralMetadata",
        "startPatchSlotAfter = plan.stateAfter.startPatchSlotAfter",
        "patchCountAfter = plan.stateAfter.patchCountAfter",
    ):
        assert direct_assignment not in metadata_discard_summary_block.group(0)
    assert "proc blaiToolchainPsramFallbackGatePlanInto*" in npu_source
    assert "BlaiToolchainPsramFallbackExcludedType* = 0x26'i32" in npu_source
    assert "BlaiToolchainPsramFallbackMaxInputCount* = 2'i32" in npu_source
    assert "BlaiToolchainPsramFallbackTypeExclusion* = object" in npu_source
    assert "proc blaiToolchainPsramFallbackTypeExclusion*" in npu_source
    assert (
        "inputCount <= BlaiToolchainPsramFallbackMaxInputCount"
        in npu_source
    )
    fallback_type_exclusion_block = re.search(
        r"proc blaiToolchainPsramFallbackTypeExclusion\*\(.*?"
        r"proc blaiToolchainPsramFallbackGatePlanInto\*",
        npu_source,
        re.S,
    )
    assert fallback_type_exclusion_block is not None
    assert "layerTypeValue == BlaiToolchainPsramOwnerRouteType" in (
        fallback_type_exclusion_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" in (
        fallback_type_exclusion_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramFallbackExcludedType" in (
        fallback_type_exclusion_block.group(0)
    )
    assert "result.excluded =" in fallback_type_exclusion_block.group(0)
    assert "outResult.fallbackArmed =" in npu_source
    fallback_gate_block = re.search(
        r"proc blaiToolchainPsramFallbackGatePlanInto\*\(.*?"
        r"proc blaiToolchainPsramFallbackGatePlan\*",
        npu_source,
        re.S,
    )
    assert fallback_gate_block is not None
    assert "let typeExclusion =" in fallback_gate_block.group(0)
    assert "blaiToolchainPsramFallbackTypeExclusion(layerTypeValue)" in (
        fallback_gate_block.group(0)
    )
    assert "not typeExclusion.excluded" in fallback_gate_block.group(0)
    assert "layerTypeValue == BlaiToolchainPsramOwnerRouteType" not in (
        fallback_gate_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" not in (
        fallback_gate_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramFallbackExcludedType" not in (
        fallback_gate_block.group(0)
    )
    assert "proc blaiToolchainPsramUnassignedMetadataPlanInto*" in npu_source
    assert "BlaiToolchainPsramUnassignedMetadataGate* = object" in npu_source
    assert "proc blaiToolchainPsramUnassignedMetadataGate*" in npu_source
    assert "BlaiToolchainPsramUnassignedMetadataState* = object" in npu_source
    assert "BlaiToolchainPsramUnassignedMetadataApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramUnassignedMetadataApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramUnassignedMetadataApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramUnassignedMetadataState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramUnassignedMetadataState*" in npu_source
    assert "proc blaiApplyToolchainPsramUnassignedMetadataScalarState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramUnassignedMetadataSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramUnassignedMetadataSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramUnassignedMetadataBankState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramUnassignedMetadata*" in npu_source
    assert "proc blaiApplyToolchainPsramUnassignedMetadataBanks*" in npu_source
    assert "BlaiToolchainPsramUnassignedStartSlot* =" in npu_source
    assert "BlaiToolchainMaxPsramPatchSlots + 1'u32" in npu_source
    assert "BlaiToolchainPsramUnassignedStartSlotAbi* = object" in npu_source
    assert "proc blaiToolchainPsramUnassignedStartSlotAbi*" in npu_source
    assert "let unassignedStartSlot = blaiToolchainPsramUnassignedStartSlotAbi()" in (
        npu_source
    )
    assert "outResult.unassignedStartSlot = unassignedStartSlot.value" in (
        npu_source
    )
    assert "outResult.writeFallbackMetadata =" in npu_source
    assert "outResult.startPatchSlotAfter = outResult.unassignedStartSlot" in npu_source
    unassigned_metadata_gate_block = re.search(
        r"proc blaiToolchainPsramUnassignedMetadataGate\*\(.*?"
        r"proc blaiToolchainPsramUnassignedMetadataPlanInto\*",
        npu_source,
        re.S,
    )
    assert unassigned_metadata_gate_block is not None
    assert "result.noFutureConsumer = not relationConsumerFound" in (
        unassigned_metadata_gate_block.group(0)
    )
    assert "result.fallbackActive = fallbackArmed" in (
        unassigned_metadata_gate_block.group(0)
    )
    assert "result.gateIsZero = gateValue == 0" in (
        unassigned_metadata_gate_block.group(0)
    )
    assert (
        "result.writeFallbackMetadata =\n"
        "    result.noFutureConsumer and result.fallbackActive and result.gateIsZero"
        in unassigned_metadata_gate_block.group(0)
    )
    unassigned_metadata_plan_block = re.search(
        r"proc blaiToolchainPsramUnassignedMetadataPlanInto\*\(.*?"
        r"proc blaiToolchainPsramUnassignedMetadataPlan\*",
        npu_source,
        re.S,
    )
    assert unassigned_metadata_plan_block is not None
    assert "let metadataGate =" in unassigned_metadata_plan_block.group(0)
    assert "blaiToolchainPsramUnassignedMetadataGate(" in (
        unassigned_metadata_plan_block.group(0)
    )
    assert "outResult.writeFallbackMetadata = metadataGate.writeFallbackMetadata" in (
        unassigned_metadata_plan_block.group(0)
    )
    assert "not relationConsumerFound and fallbackArmed and gateValue == 0" not in (
        unassigned_metadata_plan_block.group(0)
    )
    assert "BlaiToolchainPsramUnassignedStartSlot.int32" not in (
        unassigned_metadata_plan_block.group(0)
    )
    assert "BlaiToolchainPsramUnassignedStartSlot > uint32(high(int32))" not in (
        unassigned_metadata_plan_block.group(0)
    )
    unassigned_metadata_apply_block = re.search(
        r"proc blaiApplyToolchainPsramUnassignedMetadata\*\(.*?"
        r"proc blaiToolchainPsramFallbackMetadataPlanInto\*",
        npu_source,
        re.S,
    )
    assert unassigned_metadata_apply_block is not None
    assert (
        "let applyPlan = blaiToolchainPsramUnassignedMetadataApplyPlan(plan)"
        in unassigned_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramUnassignedMetadataScalarState(" in (
        unassigned_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramUnassignedMetadataBankState(" in (
        unassigned_metadata_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        unassigned_metadata_apply_block.group(0)
    )
    assert (
        "startPatchSlot = stateAfter.startPatchSlotAfter"
        not in unassigned_metadata_apply_block.group(0)
    )
    assert "patchCount = stateAfter.patchCountAfter" not in (
        unassigned_metadata_apply_block.group(0)
    )
    assert (
        "startPatchSlots[startCursor.index] = stateAfter.startPatchSlotAfter"
        not in unassigned_metadata_apply_block.group(0)
    )
    assert (
        "patchCounts[countCursor.index] = stateAfter.patchCountAfter"
        not in unassigned_metadata_apply_block.group(0)
    )
    assert "plan.startPatchSlotAfter" not in unassigned_metadata_apply_block.group(0)
    assert "plan.patchCountAfter" not in unassigned_metadata_apply_block.group(0)
    unassigned_metadata_summary_block = re.search(
        r"proc blaiApplyToolchainPsramUnassignedMetadataSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramUnassignedMetadataBankState\*",
        npu_source,
        re.S,
    )
    assert unassigned_metadata_summary_block is not None
    assert "blaiApplyToolchainPsramUnassignedMetadataSummaryScalarState(" in (
        unassigned_metadata_summary_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "generalStartOffset = plan.stateAfter.generalStartOffset",
        "generalCountOffset = plan.stateAfter.generalCountOffset",
        "unassignedStartSlot = plan.stateAfter.unassignedStartSlot",
        "writeFallbackMetadata = plan.stateAfter.writeFallbackMetadata",
        "startPatchSlotAfter = plan.stateAfter.startPatchSlotAfter",
        "patchCountAfter = plan.stateAfter.patchCountAfter",
        "writesApplied = plan.stateAfter.writesApplied",
    ):
        assert direct_assignment not in unassigned_metadata_summary_block.group(0)
    unassigned_metadata_bank_block = re.search(
        r"proc blaiApplyToolchainPsramUnassignedMetadataBankState\*\(.*?"
        r"proc blaiApplyToolchainPsramUnassignedMetadata\*",
        npu_source,
        re.S,
    )
    assert unassigned_metadata_bank_block is not None
    assert "blaiToolchainPsramMetadataBankIndexAbi(" in (
        unassigned_metadata_bank_block.group(0)
    )
    assert "blaiToolchainPsramMetadataBankCursor(" in (
        unassigned_metadata_bank_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(bankIndex.value" not in (
        unassigned_metadata_bank_block.group(0)
    )
    assert "state.layerIndex.uint32" not in unassigned_metadata_bank_block.group(0)
    assert "proc blaiToolchainPsramFallbackMetadataPlanInto*" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataState* = object" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramFallbackMetadataApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramFallbackMetadataApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramFallbackMetadataState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramFallbackMetadataState*" in npu_source
    assert "proc blaiApplyToolchainPsramFallbackMetadataScalarState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramFallbackMetadataSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramFallbackMetadataSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramFallbackMetadataBankState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramFallbackMetadata*" in npu_source
    assert "proc blaiApplyToolchainPsramFallbackMetadataBanks*" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataMode* = enum" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataSelection* = object" in npu_source
    assert "proc blaiToolchainPsramFallbackMetadataSelection*" in npu_source
    assert "BlaiToolchainPsramFallbackMetadataRawType* = object" in npu_source
    assert "proc blaiToolchainPsramFallbackMetadataRawType*" in npu_source
    assert "blaiToolchainPsramFallbackMetadataClearInvalid" in npu_source
    fallback_metadata_raw_type_block = re.search(
        r"proc blaiToolchainPsramFallbackMetadataRawType\*\(.*?"
        r"proc blaiToolchainPsramFallbackMetadataSelection\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_raw_type_block is not None
    assert "layerTypeValue == BlaiToolchainPsramOwnerConvType" in (
        fallback_metadata_raw_type_block.group(0)
    )
    assert "result.selectsClearInvalid = not result.selectsUnassigned" in (
        fallback_metadata_raw_type_block.group(0)
    )
    fallback_metadata_selection_block = re.search(
        r"proc blaiToolchainPsramFallbackMetadataSelection\*\(.*?"
        r"proc blaiToolchainPsramFallbackMetadataPlanInto\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_selection_block is not None
    assert "result.preservesForConsumer = relationConsumerFound" in (
        fallback_metadata_selection_block.group(0)
    )
    assert "result.preservesForInactiveFallback = not fallbackArmed" in (
        fallback_metadata_selection_block.group(0)
    )
    assert "let rawType =" in fallback_metadata_selection_block.group(0)
    assert "blaiToolchainPsramFallbackMetadataRawType(layerTypeValue)" in (
        fallback_metadata_selection_block.group(0)
    )
    assert "rawType.selectsUnassigned" in fallback_metadata_selection_block.group(0)
    assert "rawType.selectsClearInvalid" in fallback_metadata_selection_block.group(0)
    assert "layerTypeValue == BlaiToolchainPsramOwnerConvType" not in (
        fallback_metadata_selection_block.group(0)
    )
    fallback_metadata_plan_block = re.search(
        r"proc blaiToolchainPsramFallbackMetadataPlanInto\*\(.*?"
        r"proc blaiToolchainPsramFallbackMetadataPlan\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_plan_block is not None
    assert "let selection =" in fallback_metadata_plan_block.group(0)
    assert "blaiToolchainPsramFallbackMetadataSelection(" in (
        fallback_metadata_plan_block.group(0)
    )
    assert "outResult.mode = selection.mode" in fallback_metadata_plan_block.group(0)
    assert "case selection.mode" in fallback_metadata_plan_block.group(0)
    assert "elif layerTypeValue == BlaiToolchainPsramOwnerConvType:" not in (
        fallback_metadata_plan_block.group(0)
    )
    assert (
        "outResult.startPatchSlotAfter = BlaiToolchainPatchInvalidStartSlot"
        in fallback_metadata_plan_block.group(0)
    )
    assert (
        "outResult.patchCountAfter = BlaiToolchainPatchInvalidCount"
        in fallback_metadata_plan_block.group(0)
    )
    assert "-1'i32" not in fallback_metadata_plan_block.group(0)
    assert (
        "doAssert fallbackMetadataClearPlan.startPatchSlotAfter ==\n"
        "    BlaiToolchainPatchInvalidStartSlot"
        in npu_source
    )
    assert (
        "doAssert fallbackMetadataClearPlan.patchCountAfter ==\n"
        "    BlaiToolchainPatchInvalidCount"
        in npu_source
    )
    assert "outResult.unassignedStartSlot =\n    BlaiToolchainPsramUnassignedStartSlot.int32" not in (
        npu_source
    )
    assert "BlaiToolchainPsramUnassignedStartSlot > uint32(high(int32))" not in (
        fallback_metadata_plan_block.group(0)
    )
    fallback_metadata_apply_block = re.search(
        r"proc blaiApplyToolchainPsramFallbackMetadata\*\(.*?"
        r"proc blaiToolchainPsramSplitMetadataPlanInto\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_apply_block is not None
    assert (
        "let applyPlan = blaiToolchainPsramFallbackMetadataApplyPlan(plan)"
        in fallback_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramFallbackMetadataScalarState(" in (
        fallback_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramFallbackMetadataBankState(" in (
        fallback_metadata_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        fallback_metadata_apply_block.group(0)
    )
    assert (
        "startPatchSlot = stateAfter.startPatchSlotAfter"
        not in fallback_metadata_apply_block.group(0)
    )
    assert "patchCount = stateAfter.patchCountAfter" not in (
        fallback_metadata_apply_block.group(0)
    )
    assert (
        "startPatchSlots[startCursor.index] = stateAfter.startPatchSlotAfter"
        not in fallback_metadata_apply_block.group(0)
    )
    assert (
        "patchCounts[countCursor.index] = stateAfter.patchCountAfter"
        not in fallback_metadata_apply_block.group(0)
    )
    assert "plan.startPatchSlotAfter" not in fallback_metadata_apply_block.group(0)
    assert "plan.patchCountAfter" not in fallback_metadata_apply_block.group(0)
    fallback_metadata_summary_block = re.search(
        r"proc blaiApplyToolchainPsramFallbackMetadataSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramFallbackMetadataBankState\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_summary_block is not None
    assert "blaiApplyToolchainPsramFallbackMetadataSummaryScalarState(" in (
        fallback_metadata_summary_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "generalStartOffset = plan.stateAfter.generalStartOffset",
        "generalCountOffset = plan.stateAfter.generalCountOffset",
        "mode = plan.stateAfter.mode",
        "unassignedStartSlot = plan.stateAfter.unassignedStartSlot",
        "startPatchSlotAfter = plan.stateAfter.startPatchSlotAfter",
        "patchCountAfter = plan.stateAfter.patchCountAfter",
        "writesApplied = plan.stateAfter.writesApplied",
    ):
        assert direct_assignment not in fallback_metadata_summary_block.group(0)
    fallback_metadata_bank_block = re.search(
        r"proc blaiApplyToolchainPsramFallbackMetadataBankState\*\(.*?"
        r"proc blaiApplyToolchainPsramFallbackMetadata\*",
        npu_source,
        re.S,
    )
    assert fallback_metadata_bank_block is not None
    assert "blaiToolchainPsramMetadataBankIndexAbi(" in (
        fallback_metadata_bank_block.group(0)
    )
    assert "blaiToolchainPsramMetadataBankCursor(" in (
        fallback_metadata_bank_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(bankIndex.value" not in (
        fallback_metadata_bank_block.group(0)
    )
    assert "state.layerIndex.uint32" not in fallback_metadata_bank_block.group(0)
    assert "proc blaiToolchainPsramSplitMetadataPlanInto*" in npu_source
    assert "BlaiToolchainPsramSplitMetadataScalarAbi* = object" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataScalarAbi*" in npu_source
    assert "BlaiToolchainPsramSplitCountAbi* = object" in npu_source
    assert "proc blaiToolchainPsramSplitCountAbi*" in npu_source
    assert "BlaiToolchainPsramSplitDenominatorAbi* = object" in npu_source
    assert "proc blaiToolchainPsramSplitDenominatorAbi*" in npu_source
    assert "let initialRemaining = blaiToolchainPsramSplitMetadataScalarAbi(" in (
        npu_source
    )
    assert "let firstStart = blaiToolchainPsramSplitMetadataScalarAbi(firstStart64)" in (
        npu_source
    )
    assert "BlaiToolchainPsramSplitMetadataState* = object" in npu_source
    assert "BlaiToolchainPsramSplitMetadataPosition* = object" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataPosition*" in npu_source
    assert "BlaiToolchainPsramSplitMetadataDerivedStart* = object" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataDerivedStart*" in npu_source
    assert "BlaiToolchainPsramSplitMetadataCursorStart* = object" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataCursorStart*" in npu_source
    assert "BlaiToolchainPsramSplitMetadataApplyBlock* = enum" in npu_source
    assert "BlaiToolchainPsramSplitMetadataApplyPlan* = object" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramSplitMetadataState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramSplitMetadataState*" in npu_source
    assert "proc blaiApplyToolchainPsramSplitMetadataScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramSplitMetadataScalars*" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataCursorInto*" in npu_source
    assert "proc blaiToolchainPsramSplitMetadataCursor*(\n    state:" in (
        npu_source
    )
    assert "proc blaiToolchainPsramSplitStartSlotCursor*" in npu_source
    assert "proc blaiApplyToolchainPsramSplitMetadata*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramSplitMetadataState*(\n"
        "    splitStartSlots: var openArray[int32],"
        in npu_source
    )
    assert "BlaiToolchainPsramSplitMinCount* = 2'i32" in npu_source
    assert (
        "if rawSplitCount < BlaiToolchainPsramSplitMinCount:"
        in npu_source
    )
    assert "let selected = blaiToolchainPsramSplitCountAbi(rawSplitCount)" in (
        npu_source
    )
    assert "let offsetIndex = splitIndex - 1'u32" not in npu_source
    assert "outResult.last = splitIndex ==" not in npu_source
    split_metadata_derived_block = re.search(
        r"proc blaiToolchainPsramSplitMetadataDerivedStart\*\(.*?"
        r"proc blaiToolchainPsramSplitMetadataPlanInto\*",
        npu_source,
        re.S,
    )
    assert split_metadata_derived_block is not None
    assert "let denominator = blaiToolchainPsramSplitDenominatorAbi(" in (
        split_metadata_derived_block.group(0)
    )
    assert "let quotient = scratchPatchCount div denominator.value" in (
        split_metadata_derived_block.group(0)
    )
    assert "let multiplier = selectedSplitCount - 2'u32" in (
        split_metadata_derived_block.group(0)
    )
    assert "result.initialRemainingPatchCount = initialRemaining.value" in (
        split_metadata_derived_block.group(0)
    )
    assert "result.firstStartPatchSlot = firstStart.value" in (
        split_metadata_derived_block.group(0)
    )
    split_metadata_plan_block = re.search(
        r"proc blaiToolchainPsramSplitMetadataPlanInto\*\(.*?"
        r"proc blaiToolchainPsramSplitMetadataPlan\*",
        npu_source,
        re.S,
    )
    assert split_metadata_plan_block is not None
    assert "let selected = blaiToolchainPsramSplitCountAbi(rawSplitCount)" in (
        split_metadata_plan_block.group(0)
    )
    assert "outResult.selectedSplitCount = selected.value" in (
        split_metadata_plan_block.group(0)
    )
    assert "let derivedStart =" in split_metadata_plan_block.group(0)
    assert "blaiToolchainPsramSplitMetadataDerivedStart(" in (
        split_metadata_plan_block.group(0)
    )
    assert "outResult.quotientPatchCount = derivedStart.quotientPatchCount" in (
        split_metadata_plan_block.group(0)
    )
    assert (
        "outResult.initialRemainingPatchCount =\n"
        "    derivedStart.initialRemainingPatchCount"
        in split_metadata_plan_block.group(0)
    )
    assert (
        "outResult.firstStartPatchSlot = derivedStart.firstStartPatchSlot"
        in split_metadata_plan_block.group(0)
    )
    assert (
        "let quotient = scratchPatchCount div denominator.value"
        not in split_metadata_plan_block.group(0)
    )
    assert "rawSplitCount.uint32" not in split_metadata_plan_block.group(0)
    assert "outResult.splitDenominator.int32" not in (
        split_metadata_plan_block.group(0)
    )
    assert "initialRemaining64.int32" not in split_metadata_plan_block.group(0)
    assert "firstStart64.int32" not in split_metadata_plan_block.group(0)
    split_metadata_cursor_start_block = re.search(
        r"proc blaiToolchainPsramSplitMetadataCursorStart\*\(.*?"
        r"proc blaiToolchainPsramSplitMetadataCursorInto\*",
        npu_source,
        re.S,
    )
    assert split_metadata_cursor_start_block is not None
    assert "quotientPatchCount.int64 * position.offsetIndex.int64" in (
        split_metadata_cursor_start_block.group(0)
    )
    assert "let start64 = firstStartPatchSlot.int64 - decrement64" in (
        split_metadata_cursor_start_block.group(0)
    )
    assert "let startPatchSlot = blaiToolchainPsramSplitMetadataScalarAbi(start64)" in (
        split_metadata_cursor_start_block.group(0)
    )
    assert "result.decrementPatchCount = decrement64" in (
        split_metadata_cursor_start_block.group(0)
    )
    assert "result.startPatchSlot = startPatchSlot.value" in (
        split_metadata_cursor_start_block.group(0)
    )
    split_metadata_cursor_blocks = re.findall(
        r"proc blaiToolchainPsramSplitMetadataCursorInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert len(split_metadata_cursor_blocks) >= 2
    for split_metadata_cursor_block in split_metadata_cursor_blocks:
        assert "let position =" in split_metadata_cursor_block
        assert "blaiToolchainPsramSplitMetadataPosition(" in (
            split_metadata_cursor_block
        )
        assert "let cursorStart =" in split_metadata_cursor_block
        assert "blaiToolchainPsramSplitMetadataCursorStart(" in (
            split_metadata_cursor_block
        )
        assert "outResult.startPatchSlot = cursorStart.startPatchSlot" in (
            split_metadata_cursor_block
        )
        assert "outResult.last = cursorStart.last" in split_metadata_cursor_block
        assert "let decrement64 =" not in split_metadata_cursor_block
        assert "position.offsetIndex.int64" not in split_metadata_cursor_block
        assert "firstStartPatchSlot.int64 - decrement64" not in (
            split_metadata_cursor_block
        )
        assert "start64.int32" not in split_metadata_cursor_block
    assert "for splitIndex in 1'u32 ..< state.selectedSplitCount:" in npu_source
    split_metadata_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramSplitMetadataScalarState\*\(.*?"
        r"proc blaiToolchainPsramSplitMetadataCursorInto\*",
        npu_source,
        re.S,
    )
    assert split_metadata_scalar_block is not None
    assert "blaiApplyToolchainPsramSplitMetadataScalarState(" in (
        split_metadata_scalar_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "selectedSplitCount = plan.stateAfter.selectedSplitCount",
        "splitDenominator = plan.stateAfter.splitDenominator",
        "quotientPatchCount = plan.stateAfter.quotientPatchCount",
        "initialRemainingPatchCount = plan.stateAfter.initialRemainingPatchCount",
        "firstStartPatchSlot = plan.stateAfter.firstStartPatchSlot",
        "lastStartPatchSlot = plan.stateAfter.lastStartPatchSlot",
        "writesApplied = plan.stateAfter.writesApplied",
    ):
        assert direct_assignment not in split_metadata_scalar_block.group(0)
    assert (
        "let cursor = blaiToolchainPsramSplitMetadataCursor(state, splitIndex)"
        in npu_source
    )
    assert "splitStartSlots[splitCursor.index] = cursor.startPatchSlot" in npu_source
    split_metadata_state_block = re.search(
        r"proc blaiApplyToolchainPsramSplitMetadataState\*\(.*?"
        r"proc blaiApplyToolchainPsramSplitMetadata\*",
        npu_source,
        re.S,
    )
    assert split_metadata_state_block is not None
    assert (
        "blaiToolchainPsramSplitStartSlotCursor(\n        splitIndex, splitStartSlots.len)"
        in split_metadata_state_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(splitIndex, splitStartSlots.len)" not in (
        split_metadata_state_block.group(0)
    )
    split_metadata_apply_block = re.search(
        r"proc blaiApplyToolchainPsramSplitMetadata\*\(.*?"
        r"proc blaiToolchainPsramRelationAppendPlanInto\*",
        npu_source,
        re.S,
    )
    assert split_metadata_apply_block is not None
    assert "let applyPlan = blaiToolchainPsramSplitMetadataApplyPlan(plan)" in (
        split_metadata_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramSplitMetadataState(" in (
        split_metadata_apply_block.group(0)
    )
    assert "for splitIndex in 1'u32 ..< plan.selectedSplitCount:" not in (
        split_metadata_apply_block.group(0)
    )
    assert "proc blaiToolchainPsramRelationAppendPlanInto*" in npu_source
    assert "proc blaiToolchainPsramInputListCursor*" in npu_source
    assert "BlaiToolchainPsramRelationAppendInputDecision* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramRelationAppendInputDecision*" in npu_source
    assert "BlaiToolchainPsramRelationAppendEligibility* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramRelationAppendEligibility*" in npu_source
    assert "BlaiToolchainPsramRelationAppendState* = object" in npu_source
    assert "BlaiToolchainPsramRelationAppendApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramRelationAppendApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramRelationAppendApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramRelationAppendState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramRelationAppendState*" in npu_source
    assert "proc blaiApplyToolchainPsramRelationAppendRowState*" in npu_source
    assert "proc blaiApplyToolchainPsramRelationAppendScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramRelationAppendScalars*" in npu_source
    assert "proc blaiApplyToolchainPsramRelationAppend*" in npu_source
    relation_append_plan_block = re.search(
        r"proc blaiToolchainPsramRelationAppendPlanInto\*\(.*?"
        r"proc blaiToolchainPsramRelationAppendPlan\*",
        npu_source,
        re.S,
    )
    assert relation_append_plan_block is not None
    assert "blaiToolchainPsramRelationEntryCursor(relationIndex)" in (
        relation_append_plan_block.group(0)
    )
    assert "blaiToolchainPsramInputListCursor(inputIndex, inputLayers.len)" in (
        relation_append_plan_block.group(0)
    )
    assert "let eligibility =" in relation_append_plan_block.group(0)
    assert (
        "blaiToolchainPsramRelationAppendEligibility(layerTypeValue, tfliteMode)"
        in relation_append_plan_block.group(0)
    )
    assert "outResult.eligibleLayer = eligibility.eligibleLayer" in (
        relation_append_plan_block.group(0)
    )
    assert "let inputDecision =" in relation_append_plan_block.group(0)
    assert "blaiToolchainPsramRelationAppendInputDecision(layerIndex, inputLayer)" in (
        relation_append_plan_block.group(0)
    )
    assert "if inputDecision.skipDirectPredecessor:" in (
        relation_append_plan_block.group(0)
    )
    assert "if not inputDecision.appendRelation:" in (
        relation_append_plan_block.group(0)
    )
    assert (
        "blaiToolchainPsramRelationEntryCursor(outResult.relationCountAfter)"
        in relation_append_plan_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" not in (
        relation_append_plan_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteWType" not in (
        relation_append_plan_block.group(0)
    )
    assert "inputLayer == outResult.directPredecessorIndex" not in (
        relation_append_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(relationIndex, relationRow.len)" not in (
        relation_append_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, inputLayers.len)" not in (
        relation_append_plan_block.group(0)
    )
    assert (
        "blaiU32ArrayIndexCursor(outResult.relationCountAfter, relationRow.len)"
        not in relation_append_plan_block.group(0)
    )
    relation_append_apply_block = re.search(
        r"proc blaiApplyToolchainPsramRelationAppend\*\(.*?"
        r"proc blaiToolchainPsramInputMembershipPlanInto\*",
        npu_source,
        re.S,
    )
    assert relation_append_apply_block is not None
    assert "let applyPlan = blaiToolchainPsramRelationAppendApplyPlan(plan)" in (
        relation_append_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramRelationAppendRowState(" in (
        relation_append_apply_block.group(0)
    )
    relation_append_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramRelationAppendScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramRelationAppend\*",
        npu_source,
        re.S,
    )
    assert relation_append_scalar_block is not None
    assert "blaiApplyToolchainPsramRelationAppendScalarState(" in (
        relation_append_scalar_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "relationCountAfter = plan.stateAfter.relationCountAfter",
        "appendedCount = plan.stateAfter.appendedCount",
        "skippedDirectPredecessorCount = plan.stateAfter.skippedDirectPredecessorCount",
    ):
        assert direct_assignment not in relation_append_scalar_block.group(0)
    assert (
        "let stateAfter = applyPlan.stateAfter"
        not in relation_append_apply_block.group(0)
    )
    assert "relationCount = stateAfter.relationCountAfter" not in (
        relation_append_apply_block.group(0)
    )
    assert (
        "relationRow[cursor.index] = stateAfter.relationValues[cursor.index]"
        not in relation_append_apply_block.group(0)
    )
    relation_append_row_block = re.search(
        r"proc blaiApplyToolchainPsramRelationAppendRowState\*\(.*?"
        r"proc blaiApplyToolchainPsramRelationAppendScalarState\*",
        npu_source,
        re.S,
    )
    assert relation_append_row_block is not None
    assert "blaiToolchainPsramRelationEntryCursor(relationIndex)" in (
        relation_append_row_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(relationIndex, relationRow.len)" not in (
        relation_append_row_block.group(0)
    )
    assert "plan.relationValues" not in relation_append_apply_block.group(0)
    assert "plan.relationCountAfter" not in relation_append_apply_block.group(0)
    assert "proc blaiToolchainPsramRelationConsumerPlanInto*" in npu_source
    assert "let consumerLayer = blaiToolchainPsramRelationLayerIndexAbi(scanLayer)" in (
        npu_source
    )
    assert "BlaiToolchainPsramRelationConsumerSummaryState* = object" in (
        npu_source
    )
    assert (
        "summaryStateAfter*: BlaiToolchainPsramRelationConsumerSummaryState"
        in npu_source
    )
    assert "proc blaiToolchainPsramRelationConsumerSummaryState*" in npu_source
    assert "proc blaiToolchainPsramRelationConsumerApplyPlanInto*" in npu_source
    assert "outResult.consumer = consumer" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramRelationConsumerState" in (
        npu_source
    )
    assert (
        "outResult.summaryStateAfter = blaiToolchainPsramRelationConsumerSummaryState("
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramRelationConsumerScalarState*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramRelationConsumerSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramRelationConsumerSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramRelationConsumer*" in npu_source
    relation_consumer_apply_block = re.search(
        r"proc blaiApplyToolchainPsramRelationConsumerScalarState\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert relation_consumer_apply_block is not None
    assert "blaiApplyToolchainPsramRelationConsumerScalarState(" in (
        relation_consumer_apply_block.group(0)
    )
    assert "found = plan.stateAfter.found" not in relation_consumer_apply_block.group(0)
    assert "consumerLayerIndex = plan.stateAfter.consumerLayerIndex" not in (
        relation_consumer_apply_block.group(0)
    )
    relation_consumer_summary_block = re.search(
        r"proc blaiApplyToolchainPsramRelationConsumerSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramRelationConsumer\*\(",
        npu_source,
        re.S,
    )
    assert relation_consumer_summary_block is not None
    assert "blaiApplyToolchainPsramRelationConsumerSummaryScalarState(" in (
        relation_consumer_summary_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.summaryStateAfter.layerIndex",
        "layerCount = plan.summaryStateAfter.layerCount",
        "scannedRows = plan.summaryStateAfter.scannedRows",
        "scannedEntries = plan.summaryStateAfter.scannedEntries",
        "matchCount = plan.summaryStateAfter.matchCount",
        "consumerLayerIndex = plan.summaryStateAfter.consumerLayerIndex",
        "found = plan.summaryStateAfter.found",
    ):
        assert direct_assignment not in relation_consumer_summary_block.group(0)
    relation_consumer_block = re.search(
        r"proc blaiToolchainPsramRelationConsumerPlanInto\*\(.*?"
        r"proc blaiToolchainPsramRelationConsumerPlan\*",
        npu_source,
        re.S,
    )
    assert relation_consumer_block is not None
    assert "let currentLayerIndex = blaiToolchainPsramScanStartLayerAbi(layerIndex)" in (
        relation_consumer_block.group(0)
    )
    assert "let currentLayer = currentLayerIndex.value" in (
        relation_consumer_block.group(0)
    )
    assert "let currentLayer = layerIndex.uint32" not in (
        relation_consumer_block.group(0)
    )
    assert "outResult.consumerLayerIndex = scanLayer.int32" not in (
        relation_consumer_block.group(0)
    )
    assert "proc blaiToolchainPsramInputMembershipPlanInto*" in npu_source
    assert "BlaiToolchainPsramInputCountAbi* = object" in npu_source
    assert "proc blaiToolchainPsramInputCountAbi*" in npu_source
    assert "BlaiToolchainPsramInputMembershipState* = object" in npu_source
    assert "BlaiToolchainPsramInputMembershipApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramInputMembershipApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInputMembershipApplyPlanInto*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainPsramInputMembershipState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInputMembershipState*" in npu_source
    assert "proc blaiApplyToolchainPsramInputMembershipScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInputMembershipScalars*" in npu_source
    input_membership_plan_block = re.search(
        r"proc blaiToolchainPsramInputMembershipPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInputMembershipPlan\*",
        npu_source,
        re.S,
    )
    assert input_membership_plan_block is not None
    assert "blaiToolchainPsramInputListCursor(inputIndex, inputLayers.len)" in (
        input_membership_plan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(inputIndex, inputLayers.len)" not in (
        input_membership_plan_block.group(0)
    )
    input_membership_scalar_block = re.search(
        r"proc blaiApplyToolchainPsramInputMembershipScalarState\*\(.*?"
        r"proc blaiToolchainPsramInputMembershipResumePlanInto\*",
        npu_source,
        re.S,
    )
    assert input_membership_scalar_block is not None
    assert "blaiApplyToolchainPsramInputMembershipScalarState(" in (
        input_membership_scalar_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "inputCount = plan.stateAfter.inputCount",
        "scannedEntries = plan.stateAfter.scannedEntries",
        "found = plan.stateAfter.found",
    ):
        assert direct_assignment not in input_membership_scalar_block.group(0)
    assert "proc blaiToolchainPsramInputMembershipResumePlanInto*" in npu_source
    assert "BlaiToolchainPsramInputMembershipResumeState* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInputMembershipResumeApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramInputMembershipResumeState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInputMembershipResumeState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInputMembershipResumeScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInputMembershipResumeSummaryScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInputMembershipResumeSummaryScalars*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInputMembershipResume*" in npu_source
    assert "BlaiToolchainPsramInputListElementBytes* = 4'u32" in npu_source
    assert "BlaiToolchainPsramInputResumeBaseFrameOffset* = 0x3988'u32" in (
        npu_source
    )
    assert (
        "BlaiToolchainPsramInputResumeByteOffsetFrameOffset* = 0x88'u32"
        in npu_source
    )
    assert "outResult.foundFlagCleared = true" in npu_source
    assert "outResult.jumpsToMembershipLoop = true" in npu_source
    input_membership_block = re.search(
        r"proc blaiToolchainPsramInputMembershipPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInputMembershipPlan\*",
        npu_source,
        re.S,
    )
    assert input_membership_block is not None
    assert "let countField = blaiToolchainPsramInputCountAbi(inputCount)" in (
        input_membership_block.group(0)
    )
    assert "if countField.value > outResult.inputStorageCount:" in (
        input_membership_block.group(0)
    )
    assert "for inputIndex in 0'u32 ..< countField.value:" in (
        input_membership_block.group(0)
    )
    assert "inputCount.uint32 > outResult.inputStorageCount" not in (
        input_membership_block.group(0)
    )
    assert "0'u32 ..< inputCount.uint32" not in input_membership_block.group(0)
    assert "BlaiToolchainPsramInputMembershipResumeSpan* = object" in npu_source
    assert "proc blaiToolchainPsramInputMembershipResumeSpan*" in npu_source
    input_membership_resume_block = re.search(
        r"proc blaiToolchainPsramInputMembershipResumePlanInto\*\(.*?"
        r"proc blaiToolchainPsramInputMembershipResumePlan\*",
        npu_source,
        re.S,
    )
    assert input_membership_resume_block is not None
    assert "let countField = blaiToolchainPsramInputCountAbi(inputCount)" in (
        input_membership_resume_block.group(0)
    )
    assert "let resumeSpan =" in input_membership_resume_block.group(0)
    assert "blaiToolchainPsramInputMembershipResumeSpan(" in (
        input_membership_resume_block.group(0)
    )
    assert "outResult.scannedByteCount = resumeSpan.scannedByteCount" in (
        input_membership_resume_block.group(0)
    )
    assert "resumeSpan.scannedEntries != countField.value" in (
        input_membership_resume_block.group(0)
    )
    assert "scannedEntries != inputCount.uint32" not in (
        input_membership_resume_block.group(0)
    )
    assert "let lastEntryIndex = inputByteOffset div outResult.inputElementBytes" not in (
        input_membership_resume_block.group(0)
    )
    assert "let scannedEntries = lastEntryIndex + 1'u32" not in (
        input_membership_resume_block.group(0)
    )
    input_membership_resume_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInputMembershipResume\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert input_membership_resume_apply_block is not None
    assert "blaiApplyToolchainPsramInputMembershipResumeScalarState(" in (
        input_membership_resume_apply_block.group(0)
    )
    assert "membershipFound = plan.stateAfter.membershipFound" not in (
        input_membership_resume_apply_block.group(0)
    )
    input_membership_resume_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInputMembershipResumeSummaryScalarState"
        r"\*\(.*?"
        r"proc blaiApplyToolchainPsramInputMembershipResume\*\(",
        npu_source,
        re.S,
    )
    assert input_membership_resume_summary_block is not None
    assert "blaiApplyToolchainPsramInputMembershipResumeSummaryScalarState(" in (
        input_membership_resume_summary_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "membershipFound = plan.stateAfter.membershipFound",
        "foundFlagCleared = plan.stateAfter.foundFlagCleared",
        "jumpsToMembershipLoop = plan.stateAfter.jumpsToMembershipLoop",
        "scannedEntries = plan.stateAfter.scannedEntries",
    ):
        assert direct_assignment not in input_membership_resume_summary_block.group(0)
    assert "membershipFound = plan.foundAfterResume" not in (
        input_membership_resume_apply_block.group(0)
    )
    assert "proc blaiToolchainPsramInitialInputGatePlanInto*" in npu_source
    assert "BlaiToolchainPsramInitialInputFlagOffset* = 0x90180'u32" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialInputCountOffset* = 0x90184'u32" in (
        npu_source
    )
    assert (
        "outResult.action = blaiToolchainPsramInitialInputGateScanInputs"
        in npu_source
    )
    assert "outResult.initializesRelationScan = true" in npu_source
    assert "outResult.resetsScanSentinel = true" in npu_source
    assert "proc blaiToolchainPsramInitialInputGateApplyPlanInto*" in npu_source
    assert "outResult.gate = gate" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramInitialInputGateState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialInputGate*" in npu_source
    assert (
        "proc blaiApplyToolchainPsramInitialInputGateScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialInputGateSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialInputGateSummaryScalars*" in (
        npu_source
    )
    initial_input_gate_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialInputGate\*\(\n"
        r"    savedPreviousMembershipFound: var bool,"
        r".*?(?=^proc blaiToolchainPsramInitialRelationScanPlanInto\*)",
        npu_source,
        re.S | re.M,
    )
    assert initial_input_gate_apply_block is not None
    assert "blaiApplyToolchainPsramInitialInputGateScalarState(" in (
        initial_input_gate_apply_block.group(0)
    )
    assert "savedPreviousMembershipFound = plan.stateAfter" not in (
        initial_input_gate_apply_block.group(0)
    )
    assert "scanSentinel = plan.stateAfter" not in (
        initial_input_gate_apply_block.group(0)
    )
    initial_input_gate_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInitialInputGateSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialInputGate\*\(\n"
        r"    savedPreviousMembershipFound: var bool,",
        npu_source,
        re.S,
    )
    assert initial_input_gate_summary_block is not None
    assert "blaiApplyToolchainPsramInitialInputGateSummaryScalarState(" in (
        initial_input_gate_summary_block.group(0)
    )
    for direct_assignment in (
        "action = plan.stateAfter.action",
        "savedPreviousMembershipFound = plan.stateAfter.savedPreviousMembershipFound",
        "initializesRelationScan = plan.stateAfter.initializesRelationScan",
        "scanSentinelAfter = plan.stateAfter.scanSentinelAfter",
    ):
        assert direct_assignment not in initial_input_gate_summary_block.group(0)
    assert "proc blaiToolchainPsramInitialRelationScanPlanInto*" in npu_source
    assert "BlaiToolchainPsramRelationLayerIndexAbi* = object" in npu_source
    assert "proc blaiToolchainPsramRelationLayerIndexAbi*" in npu_source
    assert "BlaiToolchainPsramScanStartLayerAbi* = object" in npu_source
    assert "proc blaiToolchainPsramScanStartLayerAbi*" in npu_source
    assert "BlaiToolchainPsramInitialRelationScanState* = object" in npu_source
    assert "BlaiToolchainPsramInitialRelationScanApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialRelationScanApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramRelationCountCursor*" in npu_source
    assert "proc blaiToolchainPsramRelationRowCursor*" in npu_source
    assert "proc blaiToolchainPsramRelationEntryCursor*" in npu_source
    assert "proc blaiToolchainPsramInitialRelationScanApplyPlanInto*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialRelationScanSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialRelationScanSummaryScalars*" in (
        npu_source
    )
    assert "let selectedLayer = blaiToolchainPsramRelationLayerIndexAbi(scanLayer)" in (
        npu_source
    )
    initial_relation_scan_block = re.search(
        r"proc blaiToolchainPsramInitialRelationScanPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInitialRelationScanPlan\*",
        npu_source,
        re.S,
    )
    assert initial_relation_scan_block is not None
    assert (
        "let scanStartLayer = blaiToolchainPsramScanStartLayerAbi(gate.layerIndex)"
        in initial_relation_scan_block.group(0)
    )
    assert "outResult.scanStartLayer = scanStartLayer.value" in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiToolchainPsramRelationCountCursor(" in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiToolchainPsramRelationRowCursor(" in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiToolchainPsramRelationEntryCursor(relationIndex)" in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(scanLayer, relationCounts.len)" not in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(scanLayer, relationRows.len)" not in (
        initial_relation_scan_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(relationIndex, relationRows" not in (
        initial_relation_scan_block.group(0)
    )
    initial_relation_scan_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInitialRelationScanSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialRelationScan\*\(",
        npu_source,
        re.S,
    )
    assert initial_relation_scan_summary_block is not None
    assert "blaiApplyToolchainPsramInitialRelationScanSummaryScalarState(" in (
        initial_relation_scan_summary_block.group(0)
    )
    for direct_assignment in (
        "layerIndex = plan.stateAfter.layerIndex",
        "selectedLayerIndex = plan.stateAfter.selectedLayerIndex",
        "relationSentinel = plan.stateAfter.relationSentinel",
        "scannedRows = plan.stateAfter.scannedRows",
        "scannedEntries = plan.stateAfter.scannedEntries",
        "matchCount = plan.stateAfter.matchCount",
        "found = plan.stateAfter.found",
    ):
        assert direct_assignment not in initial_relation_scan_summary_block.group(0)
    assert "outResult.scanStartLayer = gate.layerIndex.uint32" not in (
        initial_relation_scan_block.group(0)
    )
    assert "outResult.selectedLayerIndex = scanLayer.int32" not in (
        initial_relation_scan_block.group(0)
    )
    assert "outResult.stateAfter = blaiToolchainPsramInitialRelationScanState" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialRelationScanState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialRelationScanScalarState*"
        in npu_source
    )
    initial_relation_scan_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialRelationScan\*\(\n"
        r"    selectedLayerIndex: var int32,"
        r".*?(?=^proc blaiToolchainPsramInitialTfliteRequestPlanInto\*)",
        npu_source,
        re.S | re.M,
    )
    assert initial_relation_scan_apply_block is not None
    assert "blaiApplyToolchainPsramInitialRelationScanScalarState(" in (
        initial_relation_scan_apply_block.group(0)
    )
    assert "selectedLayerIndex = plan.stateAfter" not in (
        initial_relation_scan_apply_block.group(0)
    )
    assert "relationConsumerFound = plan.stateAfter" not in (
        initial_relation_scan_apply_block.group(0)
    )
    assert "BlaiToolchainPsramRelationCountElementBytes* = 4'u32" in (
        npu_source
    )
    assert "BlaiToolchainPsramRelationRowStrideBytes* =" in npu_source
    assert "BlaiToolchainPsramInitialRelationSentinel* = -1'i32" in (
        npu_source
    )
    assert "outResult.selectedLayerIndex = selectedLayer.value" in npu_source
    assert "inc outResult.matchCount" in npu_source
    assert "proc blaiToolchainPsramInitialTfliteRequestPlanInto*" in npu_source
    assert "BlaiToolchainPsramInitialTfliteFactorAOffset* = 0x94'u32" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialTfliteFactorBOffset* = 0x90'u32" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialTfliteCountOffset* = 0x98'u32" in (
        npu_source
    )
    assert "blaiToolchainPsramTfliteRequestPlanInto(" in npu_source
    assert "blaiToolchainPatchPreviousOwnerPlanInto(" in npu_source
    assert "outResult.requestedPatchCount = outResult.request.requestedPatchCount" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteRequestState*" in npu_source
    assert "proc blaiToolchainPsramInitialTfliteRequestApplyPlanInto*" in (
        npu_source
    )
    assert "request.request.selectedCount" in npu_source
    assert "proc blaiApplyToolchainPsramInitialTfliteRequestState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteRequestScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteRequestSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteRequestSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTflitePatchPlanInto*" in npu_source
    assert "proc blaiToolchainPsramInitialTflitePatchState*" in npu_source
    assert "proc blaiToolchainPsramInitialTflitePatchApplyPlanInto*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTflitePatchState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTflitePatchScalarState*" in (
        npu_source
    )
    assert "blaiToolchainPsramTflitePatchPlanInto(" in npu_source
    assert "outResult.owner = outResult.patch.owner" in npu_source
    initial_tflite_request_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteRequest\*\(\n"
        r"    selectedLayerIndex: var int32,"
        r".*?(?=^proc blaiToolchainPsramInitialTfliteLoopPlanInto\*)",
        npu_source,
        re.S | re.M,
    )
    assert initial_tflite_request_apply_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteRequestScalarState(" in (
        initial_tflite_request_apply_block.group(0)
    )
    assert "selectedLayerIndex = plan.stateAfter" not in (
        initial_tflite_request_apply_block.group(0)
    )
    assert "requestedPatchCount = plan.stateAfter" not in (
        initial_tflite_request_apply_block.group(0)
    )
    assert "selectedPreviousOwnerFlag = plan.stateAfter" not in (
        initial_tflite_request_apply_block.group(0)
    )
    initial_tflite_request_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteRequestSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialTfliteRequest\*\(",
        npu_source,
        re.S,
    )
    assert initial_tflite_request_summary_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteRequestSummaryScalarState(" in (
        initial_tflite_request_summary_block.group(0)
    )
    for direct_assignment in (
        "selectedLayerIndex = plan.stateAfter.selectedLayerIndex",
        "factorAOffset = plan.stateAfter.factorAOffset",
        "factorBOffset = plan.stateAfter.factorBOffset",
        "countOffset = plan.stateAfter.countOffset",
        "factorA = plan.stateAfter.factorA",
        "factorB = plan.stateAfter.factorB",
        "countToSelect = plan.stateAfter.countToSelect",
        "selectedCount = plan.stateAfter.selectedCount",
        "nextLayerTypeValue = plan.stateAfter.nextLayerTypeValue",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
    ):
        assert direct_assignment not in initial_tflite_request_summary_block.group(0)
    initial_tflite_patch_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTflitePatchScalars\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteLoopPlanInto\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_patch_apply_block is not None
    assert "blaiApplyToolchainPsramInitialTflitePatchScalarState(" in (
        initial_tflite_patch_apply_block.group(0)
    )
    for direct_assignment in (
        "selectedLayerIndex = plan.stateAfter.selectedLayerIndex",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "owner = plan.stateAfter.owner",
    ):
        assert direct_assignment not in initial_tflite_patch_apply_block.group(0)
    assert "proc blaiToolchainPsramInitialTfliteLoopPlanInto*" in npu_source
    assert "BlaiToolchainPsramInitialTfliteLoopEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramInitialTfliteLoopEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteLoopEvidence*" in npu_source
    assert "BlaiToolchainPsramInitialTfliteLoopState* = object" in npu_source
    assert "BlaiToolchainPsramInitialTfliteLoopSentinel* = -1'i32" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialTfliteCallAuxStackBytes* = 16'u32" in (
        npu_source
    )
    assert "result.comparisonOrdinal = -sentinelBefore" in npu_source
    assert "result.sentinelAfter = sentinelBefore - 1'i32" in npu_source
    assert "result.loopAgain = copiedInputCount > result.comparisonOrdinal" in (
        npu_source
    )
    assert "result.restoreSavedMembershipFound = not result.loopAgain" in (
        npu_source
    )
    initial_tflite_loop_evidence_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteLoopEvidence\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteLoopPlanInto\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_loop_evidence_block is not None
    assert "result.requestValid = request.valid" in (
        initial_tflite_loop_evidence_block.group(0)
    )
    assert "result.inputCountValid = copiedInputCount >= 0" in (
        initial_tflite_loop_evidence_block.group(0)
    )
    assert "result.sentinelValid = sentinelBefore != low(int32)" in (
        initial_tflite_loop_evidence_block.group(0)
    )
    assert "result.comparisonOrdinal = -sentinelBefore" in (
        initial_tflite_loop_evidence_block.group(0)
    )
    initial_tflite_loop_plan_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteLoopPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteLoopPlan\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_loop_plan_block is not None
    assert "let evidence = blaiToolchainPsramInitialTfliteLoopEvidence(" in (
        initial_tflite_loop_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        initial_tflite_loop_plan_block.group(0)
    )
    assert "if copiedInputCount < 0:" not in (
        initial_tflite_loop_plan_block.group(0)
    )
    assert "sentinelBefore == low(int32)" not in (
        initial_tflite_loop_plan_block.group(0)
    )
    assert "proc blaiToolchainPsramInitialTfliteLoopApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramInitialTfliteLoopState" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteLoopScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteLoopSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteLoopSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteLoopState*" in npu_source
    assert "proc blaiApplyToolchainPsramInitialTfliteLoop*" in npu_source
    initial_tflite_loop_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteLoop\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialTfliteLoopState\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_loop_apply_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteLoopScalarState(" in (
        initial_tflite_loop_apply_block.group(0)
    )
    assert "sentinel = plan.stateAfter.sentinelAfter" not in (
        initial_tflite_loop_apply_block.group(0)
    )
    assert "membershipFound = plan.stateAfter.membershipFoundAfter" not in (
        initial_tflite_loop_apply_block.group(0)
    )
    initial_tflite_loop_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteLoopSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialTfliteLoop\*\(",
        npu_source,
        re.S,
    )
    assert initial_tflite_loop_summary_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteLoopSummaryScalarState(" in (
        initial_tflite_loop_summary_block.group(0)
    )
    for direct_assignment in (
        "sentinelAfter = plan.stateAfter.sentinelAfter",
        "membershipFoundAfter = plan.stateAfter.membershipFoundAfter",
        "updatesMembershipFound = plan.stateAfter.updatesMembershipFound",
        "loopAgain = plan.stateAfter.loopAgain",
        "callAuxStackBytes = plan.stateAfter.callAuxStackBytes",
    ):
        assert direct_assignment not in initial_tflite_loop_summary_block.group(0)
    assert "BlaiToolchainPsramInitialTfliteSentinelLayerAbi* = object" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteSentinelLayerAbi*" in npu_source
    assert "proc blaiToolchainPsramInitialTfliteJoinPlanInto*" in npu_source
    assert "BlaiToolchainPsramInitialTfliteJoinEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramInitialTfliteJoinEvidence" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteJoinEvidence*" in npu_source
    initial_tflite_join_evidence_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinEvidence\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinPlanInto\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_evidence_block is not None
    assert "result.gateValid = gate.valid" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.scanInputGate =" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.sentinelValid = sentinel < 0 and sentinel != low(int32)" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.selectedLayerAbi =" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.selectedLayerInRange =" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.relationConsumerLayerIndex = 0'i32" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.relationConsumerFound = false" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.clearsRelationScalars = true" in (
        initial_tflite_join_evidence_block.group(0)
    )
    assert "result.joinsRequestPath = true" in (
        initial_tflite_join_evidence_block.group(0)
    )
    initial_tflite_join_plan_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinPlanInto\*.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinPlan\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_plan_block is not None
    assert (
        "let evidence = blaiToolchainPsramInitialTfliteJoinEvidence("
        in initial_tflite_join_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "outResult.selectedLayerIndex = evidence.selectedLayerIndex" in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "outResult.relationConsumerLayerIndex =" in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "evidence.relationConsumerLayerIndex" in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "if sentinel >= 0" not in initial_tflite_join_plan_block.group(0)
    assert "if not gate.valid" not in initial_tflite_join_plan_block.group(0)
    assert "selectedLayer64.int32" not in initial_tflite_join_plan_block.group(0)
    assert "outResult.relationConsumerLayerIndex = 0'i32" not in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "outResult.relationConsumerFound = false" not in (
        initial_tflite_join_plan_block.group(0)
    )
    assert "proc blaiToolchainPsramInitialTfliteJoinState*" in npu_source
    assert "proc blaiToolchainPsramInitialTfliteJoinApplyPlanInto*" in npu_source
    assert "outResult.stateAfter = blaiToolchainPsramInitialTfliteJoinState(" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteJoinScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteJoinControlState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteJoinSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteJoin*" in npu_source
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinControl*" in npu_source
    initial_tflite_join_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteJoin\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialTfliteJoinState\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_apply_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteJoinScalarState(" in (
        initial_tflite_join_apply_block.group(0)
    )
    assert "selectedLayerIndex = plan.stateAfter.selectedLayerIndex" not in (
        initial_tflite_join_apply_block.group(0)
    )
    assert "relationConsumerFound = plan.stateAfter.relationConsumerFound" not in (
        initial_tflite_join_apply_block.group(0)
    )
    assert "blaiApplyToolchainPsramInitialTfliteJoinControlState(" in (
        initial_tflite_join_apply_block.group(0)
    )
    assert "clearsRelationScalars = plan.stateAfter.clearsRelationScalars" not in (
        initial_tflite_join_apply_block.group(0)
    )
    assert "joinsRequestPath = plan.stateAfter.joinsRequestPath" not in (
        initial_tflite_join_apply_block.group(0)
    )
    initial_tflite_join_summary_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteJoinSummaryScalarState\*\(.*?"
        r"proc blaiApplyToolchainPsramInitialTfliteJoin\*\(",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_summary_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteJoinSummaryScalarState(" in (
        initial_tflite_join_summary_block.group(0)
    )
    for direct_assignment in (
        "selectedLayerIndex = plan.stateAfter.selectedLayerIndex",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "clearsRelationScalars = plan.stateAfter.clearsRelationScalars",
        "joinsRequestPath = plan.stateAfter.joinsRequestPath",
    ):
        assert direct_assignment not in initial_tflite_join_summary_block.group(0)
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinState*" in npu_source
    assert "proc blaiToolchainPsramInitialTfliteJoinRequestPlanInto*" in (
        npu_source
    )
    assert "BlaiToolchainPsramInitialTfliteJoinRequestEvidence* = object" in (
        npu_source
    )
    assert "evidence*: BlaiToolchainPsramInitialTfliteJoinRequestEvidence" in (
        npu_source
    )
    assert "syntheticScan*: BlaiToolchainPsramInitialRelationScanPlan" in (
        npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteJoinRequestEvidence*" in (
        npu_source
    )
    initial_tflite_join_request_evidence_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinRequestEvidence\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinRequestPlanInto\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_request_evidence_block is not None
    assert "result.joinValid = join.valid" in (
        initial_tflite_join_request_evidence_block.group(0)
    )
    assert (
        "result.syntheticScan = BlaiToolchainPsramInitialRelationScanPlan("
        in initial_tflite_join_request_evidence_block.group(0)
    )
    assert "result.requestValid = result.request.valid" in (
        initial_tflite_join_request_evidence_block.group(0)
    )
    assert "result.requestedPatchCount = result.request.requestedPatchCount" in (
        initial_tflite_join_request_evidence_block.group(0)
    )
    initial_tflite_join_request_plan_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinRequestPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinRequestPlan\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_request_plan_block is not None
    assert (
        "let evidence = blaiToolchainPsramInitialTfliteJoinRequestEvidence("
        in initial_tflite_join_request_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        initial_tflite_join_request_plan_block.group(0)
    )
    assert "outResult.syntheticScan = evidence.syntheticScan" in (
        initial_tflite_join_request_plan_block.group(0)
    )
    assert "if not join.valid:" not in (
        initial_tflite_join_request_plan_block.group(0)
    )
    assert "BlaiToolchainPsramInitialRelationScanPlan(" not in (
        initial_tflite_join_request_plan_block.group(0)
    )
    assert "blaiToolchainPsramInitialTfliteRequestPlanInto(" in npu_source
    assert "outResult.requestedPatchCount = outResult.request.requestedPatchCount" not in (
        initial_tflite_join_request_plan_block.group(0)
    )
    assert "proc blaiToolchainPsramInitialTfliteJoinRequestState*" in (
        npu_source
    )
    assert (
        "proc blaiToolchainPsramInitialTfliteJoinRequestSummaryState*"
        in npu_source
    )
    assert (
        "BlaiToolchainPsramInitialTfliteJoinRequestApplyEvidence* = object"
        in npu_source
    )
    assert (
        "evidence*: BlaiToolchainPsramInitialTfliteJoinRequestApplyEvidence"
        in npu_source
    )
    assert (
        "proc blaiToolchainPsramInitialTfliteJoinRequestApplyEvidence*"
        in npu_source
    )
    assert "proc blaiToolchainPsramInitialTfliteJoinRequestApplyPlanInto*" in (
        npu_source
    )
    initial_tflite_join_request_apply_evidence_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinRequestApplyEvidence\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinRequestApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_request_apply_evidence_block is not None
    assert "result.requestValid = request.valid" in (
        initial_tflite_join_request_apply_evidence_block.group(0)
    )
    assert (
        "result.stateAfter = blaiToolchainPsramInitialTfliteJoinRequestState("
        in initial_tflite_join_request_apply_evidence_block.group(0)
    )
    assert (
        "result.summaryStateAfter =\n    blaiToolchainPsramInitialTfliteJoinRequestSummaryState("
        in initial_tflite_join_request_apply_evidence_block.group(0)
    )
    initial_tflite_join_request_apply_plan_block = re.search(
        r"proc blaiToolchainPsramInitialTfliteJoinRequestApplyPlanInto\*\(.*?"
        r"proc blaiToolchainPsramInitialTfliteJoinRequestApplyPlan\*",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_request_apply_plan_block is not None
    assert (
        "blaiToolchainPsramInitialTfliteJoinRequestApplyEvidence(request)"
        in initial_tflite_join_request_apply_plan_block.group(0)
    )
    assert "outResult.evidence = evidence" in (
        initial_tflite_join_request_apply_plan_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in (
        initial_tflite_join_request_apply_plan_block.group(0)
    )
    assert (
        "blaiToolchainPsramInitialTfliteJoinRequestState("
        not in initial_tflite_join_request_apply_plan_block.group(0)
    )
    assert (
        "blaiToolchainPsramInitialTfliteJoinRequestSummaryState("
        not in initial_tflite_join_request_apply_plan_block.group(0)
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinRequestState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinRequestScalarState*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteJoinRequestSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainPsramInitialTfliteJoinRequestScalars*" in (
        npu_source
    )
    assert (
        "proc blaiApplyToolchainPsramInitialTfliteJoinRequestSummaryScalars*"
        in npu_source
    )
    initial_tflite_join_request_apply_block = re.search(
        r"proc blaiApplyToolchainPsramInitialTfliteJoinRequestScalars\*\(.*?"
        r"static:",
        npu_source,
        re.S,
    )
    assert initial_tflite_join_request_apply_block is not None
    assert "blaiApplyToolchainPsramInitialTfliteJoinRequestScalarState(" in (
        initial_tflite_join_request_apply_block.group(0)
    )
    assert (
        "blaiApplyToolchainPsramInitialTfliteJoinRequestSummaryScalarState("
        in initial_tflite_join_request_apply_block.group(0)
    )
    assert "plan.summaryStateAfter" in (
        initial_tflite_join_request_apply_block.group(0)
    )
    for direct_assignment in (
        "selectedLayerIndex = plan.stateAfter.selectedLayerIndex",
        "relationConsumerLayerIndex = plan.stateAfter.relationConsumerLayerIndex",
        "relationConsumerFound = plan.stateAfter.relationConsumerFound",
        "requestedPatchCount = plan.stateAfter.requestedPatchCount",
        "selectedPreviousOwnerFlag = plan.stateAfter.selectedPreviousOwnerFlag",
        "joinsRequestPath = plan.stateAfter.joinsRequestPath",
    ):
        assert direct_assignment not in (
            initial_tflite_join_request_apply_block.group(0)
        )
    assert "proc blaiToolchainSetWeiPatchPagePlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchRouteGatePlanInto*" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchRouteGateMultiInputThreshold* = 1'i32"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchRouteGateFieldValue* = 2'i32" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteGateEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchRouteGateEvidence*" in npu_source
    route_gate_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchRouteGateEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchRouteGatePlanInto\*",
        npu_source,
        re.S,
    )
    assert route_gate_evidence_block is not None
    assert (
        "previousInputCount >\n        "
        "BlaiToolchainSetWeiPatchRouteGateMultiInputThreshold"
        in route_gate_evidence_block.group(0)
    )
    assert "previousLayerTypeValue == BlaiToolchainPsramOwnerConvType" in (
        route_gate_evidence_block.group(0)
    )
    assert (
        "currentFieldA != BlaiToolchainSetWeiPatchRouteGateFieldValue or"
        in route_gate_evidence_block.group(0)
    )
    assert (
        "currentFieldB != BlaiToolchainSetWeiPatchRouteGateFieldValue"
        in route_gate_evidence_block.group(0)
    )
    assert "sourceLayerTypeValue == BlaiToolchainPsramOwnerRouteType" in (
        route_gate_evidence_block.group(0)
    )
    assert "result.routeFamilyPath =" in route_gate_evidence_block.group(0)
    route_gate_block = re.search(
        r"proc blaiToolchainSetWeiPatchRouteGatePlanInto\*\(.*?"
        r"proc blaiToolchainSetWeiPatchRouteGatePlan\*",
        npu_source,
        re.S,
    )
    assert route_gate_block is not None
    assert "let evidence =" in route_gate_block.group(0)
    assert "blaiToolchainSetWeiPatchRouteGateEvidence(" in (
        route_gate_block.group(0)
    )
    assert "outResult.routeFamilyPath = evidence.routeFamilyPath" in (
        route_gate_block.group(0)
    )
    assert (
        "previousInputCount >\n        "
        "BlaiToolchainSetWeiPatchRouteGateMultiInputThreshold"
        not in route_gate_block.group(0)
    )
    assert "previousLayerTypeValue == BlaiToolchainPsramOwnerConvType" not in (
        route_gate_block.group(0)
    )
    assert "currentFieldA != BlaiToolchainSetWeiPatchRouteGateFieldValue" not in (
        route_gate_block.group(0)
    )
    assert "sourceLayerTypeValue == BlaiToolchainPsramOwnerRouteType" not in (
        route_gate_block.group(0)
    )
    assert "proc blaiToolchainSetWeiPatchRouteSourcePlanInto*" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteMaxType* = 0x37'i32" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteSourceSelection* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchRouteSourceSelection*" in npu_source
    assert "outResult.selectedCount =" in npu_source
    assert "BlaiToolchainSetWeiPatchRouteSourceScalarAbi* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchRouteSourceScalarAbi*" in npu_source
    route_source_selection_block = re.search(
        r"proc blaiToolchainSetWeiPatchRouteSourceSelection\*\(.*?"
        r"proc blaiToolchainSetWeiPatchRouteSourcePlanInto\*",
        npu_source,
        re.S,
    )
    assert route_source_selection_block is not None
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType or" in (
        route_source_selection_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainSetWeiPatchRouteMaxType" in (
        route_source_selection_block.group(0)
    )
    assert "sourceLayerTypeValue == BlaiToolchainPsramRelationRouteType" in (
        route_source_selection_block.group(0)
    )
    assert "result.useRouteCount =" in route_source_selection_block.group(0)
    set_wei_route_source_block = re.search(
        r"proc blaiToolchainSetWeiPatchRouteSourcePlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchRouteSourcePlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_route_source_block is not None
    assert "let selection =" in set_wei_route_source_block.group(0)
    assert "blaiToolchainSetWeiPatchRouteSourceSelection(" in (
        set_wei_route_source_block.group(0)
    )
    assert "outResult.routeFamily = selection.routeFamily" in (
        set_wei_route_source_block.group(0)
    )
    assert "outResult.routeMax = selection.routeMax" in (
        set_wei_route_source_block.group(0)
    )
    assert "selection.routeMaxUsesRouteCount" in (
        set_wei_route_source_block.group(0)
    )
    assert "if selection.useRouteCount:" in set_wei_route_source_block.group(0)
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" not in (
        set_wei_route_source_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainSetWeiPatchRouteMaxType" not in (
        set_wei_route_source_block.group(0)
    )
    assert "sourceLayerTypeValue == BlaiToolchainPsramRelationRouteType" not in (
        set_wei_route_source_block.group(0)
    )
    assert (
        "blaiToolchainSetWeiPatchRouteSourceScalarAbi(mainCount)"
        in set_wei_route_source_block.group(0)
    )
    assert (
        "blaiToolchainSetWeiPatchRouteSourceScalarAbi(routeCount)"
        in set_wei_route_source_block.group(0)
    )
    assert (
        "blaiToolchainSetWeiPatchRouteSourceScalarAbi(routeNumerator)"
        in set_wei_route_source_block.group(0)
    )
    assert "outResult.mainCount = mainCount.uint32" not in (
        set_wei_route_source_block.group(0)
    )
    assert "outResult.routeCount = routeCount.uint32" not in (
        set_wei_route_source_block.group(0)
    )
    assert "outResult.routeNumerator = routeNumerator.uint32" not in (
        set_wei_route_source_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchBaseOffsetEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchBaseOffsetEvidence*" in npu_source
    assert "proc blaiToolchainSetWeiPatchBaseOffsetPlanInto*" in npu_source
    assert "BlaiToolchainSetWeiPatchLayerMaskShiftAbi* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLayerMaskShiftAbi*" in npu_source
    assert "BlaiToolchainSetWeiPatchBaseOffsetMask* = 0x0000_0040_0000_4200'u64" in (
        npu_source
    )
    assert "BlaiToolchainSetWeiPatchBaseOffsetMaskMaxType* = 0x26'i32" in (
        npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchBaseOffsetCountThreshold* = 1'i32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchBaseOffsetFieldThreshold* = 3'i32"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchBaseOffsetHighValue" in npu_source
    base_offset_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchBaseOffsetEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchBaseOffsetPlanInto\*",
        npu_source,
        re.S,
    )
    assert base_offset_evidence_block is not None
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" in (
        base_offset_evidence_block.group(0)
    )
    assert "result.layerTypeInMaskRange = maskShift.valid" in (
        base_offset_evidence_block.group(0)
    )
    assert "result.mask shr maskShift.value" in (
        base_offset_evidence_block.group(0)
    )
    assert (
        "recoveredCount > BlaiToolchainSetWeiPatchBaseOffsetCountThreshold"
        in base_offset_evidence_block.group(0)
    )
    assert (
        "recoveredField > BlaiToolchainSetWeiPatchBaseOffsetFieldThreshold"
        in base_offset_evidence_block.group(0)
    )
    base_offset_block = re.search(
        r"proc blaiToolchainSetWeiPatchBaseOffsetPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchBaseOffsetPlan\*",
        npu_source,
        re.S,
    )
    assert base_offset_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchBaseOffsetEvidence(" in (
        base_offset_block.group(0)
    )
    assert "outResult.layerTypeInMaskRange = evidence.layerTypeInMaskRange" in (
        base_offset_block.group(0)
    )
    assert "outResult.basePatchOffset = evidence.basePatchOffset" in (
        base_offset_block.group(0)
    )
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" not in (
        base_offset_block.group(0)
    )
    assert "outResult.mask shr maskShift.value" not in base_offset_block.group(0)
    assert (
        "recoveredCount > BlaiToolchainSetWeiPatchBaseOffsetCountThreshold"
        not in base_offset_block.group(0)
    )
    assert (
        "recoveredField > BlaiToolchainSetWeiPatchBaseOffsetFieldThreshold"
        not in base_offset_block.group(0)
    )
    assert "layerTypeValue.int" not in base_offset_block.group(0)
    assert "proc blaiToolchainSetWeiPatchDivisorPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchStorePlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchSplitCursor*" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreState* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreApplyBlock* = enum" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreApplyPlan* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchStoreApplyPlanInto*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchStoreState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchStoreSplitState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchStoreScalarState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchStoreScalars*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchStore*" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreCommitBlock* = enum" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreCommitPlan* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchStoreCommitState* = object" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchStoreCommitSummaryState* = object"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchStoreCommitApplyBlock* = enum" in (
        npu_source
    )
    assert "BlaiToolchainSetWeiPatchStoreCommitApplyPlan* = object" in (
        npu_source
    )
    assert "proc blaiToolchainSetWeiPatchStoreCommitPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchStoreCommitApplyPlanInto*" in (
        npu_source
    )
    assert "proc blaiToolchainSetWeiPatchStoreCommitSummaryState*" in (
        npu_source
    )
    assert "outResult.stateAfter = blaiToolchainSetWeiPatchStoreCommitState" in (
        npu_source
    )
    assert (
        "summaryStateAfter*: BlaiToolchainSetWeiPatchStoreCommitSummaryState"
        in npu_source
    )
    assert (
        "outResult.summaryStateAfter =\n    blaiToolchainSetWeiPatchStoreCommitSummaryState("
        in npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchStoreCommitState*" in npu_source
    assert (
        "proc blaiApplyToolchainSetWeiPatchStoreCommitSplitState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainSetWeiPatchStoreCommitScalarState*"
        in npu_source
    )
    assert (
        "proc blaiApplyToolchainSetWeiPatchStoreCommitSummaryScalarState*"
        in npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchStoreCommitScalars*" in npu_source
    assert (
        "proc blaiApplyToolchainSetWeiPatchStoreCommitSummaryScalars*"
        in npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchStoreCommit*" in npu_source
    assert "select.mode != store.mode" in npu_source
    assert "outResult.firstBlock = blaiToolchainSetWeiPatchStoreCommitModeMismatch" in (
        npu_source
    )
    assert "store.splitCount > outResult.splitStorageCount" in npu_source
    assert "outResult.stateAfter = blaiToolchainSetWeiPatchStoreState" in (
        npu_source
    )
    store_apply_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStore\*\(.*?"
        r"proc blaiToolchainSetWeiPatchStoreCommitPlanInto\*",
        npu_source,
        re.S,
    )
    assert store_apply_block is not None
    assert "blaiApplyToolchainSetWeiPatchStoreSplitState(" in (
        store_apply_block.group(0)
    )
    assert "patchCount = stateAfter.patchCount" not in (
        store_apply_block.group(0)
    )
    assert "splitValues[splitCursor.index] = stateAfter.splitValues[splitCursor.index]" not in (
        store_apply_block.group(0)
    )
    store_split_state_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStoreSplitState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchStoreScalarState\*",
        npu_source,
        re.S,
    )
    assert store_split_state_block is not None
    assert "blaiToolchainSetWeiPatchSplitCursor(splitIndex, splitValues.len)" in (
        store_split_state_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(splitIndex, splitValues.len)" not in (
        store_split_state_block.group(0)
    )
    store_scalar_apply_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStoreScalarState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchStore\*\(",
        npu_source,
        re.S,
    )
    assert store_scalar_apply_block is not None
    assert "blaiApplyToolchainSetWeiPatchStoreScalarState(" in (
        store_scalar_apply_block.group(0)
    )
    assert "mode = plan.stateAfter.mode" not in store_scalar_apply_block.group(0)
    assert "patchCount = plan.stateAfter.patchCount" not in (
        store_scalar_apply_block.group(0)
    )
    assert "splitCount = plan.stateAfter.splitCount" not in (
        store_scalar_apply_block.group(0)
    )
    store_commit_apply_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStoreCommit\*\(.*?"
        r"proc blaiToolchainSetWeiPatchPressurePlanInto\*",
        npu_source,
        re.S,
    )
    assert store_commit_apply_block is not None
    assert (
        "let applyPlan = blaiToolchainSetWeiPatchStoreCommitApplyPlan(plan)"
        in store_commit_apply_block.group(0)
    )
    assert "blaiApplyToolchainSetWeiPatchStoreCommitSplitState(" in (
        store_commit_apply_block.group(0)
    )
    assert "let stateAfter = applyPlan.stateAfter" not in (
        store_commit_apply_block.group(0)
    )
    assert "patchCount = stateAfter.patchCount" not in (
        store_commit_apply_block.group(0)
    )
    assert "blaiApplyToolchainSetWeiPatchStore(" not in (
        store_commit_apply_block.group(0)
    )
    store_commit_split_state_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStoreCommitSplitState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchStoreCommitScalarState\*",
        npu_source,
        re.S,
    )
    assert store_commit_split_state_block is not None
    assert "blaiToolchainSetWeiPatchSplitCursor(splitIndex, splitValues.len)" in (
        store_commit_split_state_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(splitIndex, splitValues.len)" not in (
        store_commit_split_state_block.group(0)
    )
    store_commit_scalar_apply_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchStoreCommitScalarState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchStoreCommit\*\(",
        npu_source,
        re.S,
    )
    assert store_commit_scalar_apply_block is not None
    assert "blaiApplyToolchainSetWeiPatchStoreCommitScalarState(" in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "blaiApplyToolchainSetWeiPatchStoreCommitSummaryScalarState(" in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "plan.summaryStateAfter" in store_commit_scalar_apply_block.group(0)
    assert "mode = plan.stateAfter.mode" not in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "patchCount = plan.stateAfter.patchCount" not in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "splitCount = plan.stateAfter.splitCount" not in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "writesApplied = plan.stateAfter.writesApplied" not in (
        store_commit_scalar_apply_block.group(0)
    )
    assert "proc blaiToolchainSetWeiPatchStoreSelectPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchPressurePlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeFlagPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeSplitPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeTotalPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerFlagPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerSplitPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerTotalPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchNoPatchPlanInto*" in npu_source
    assert "proc blaiToolchainSetWeiPatchBranchPlanInto*" in npu_source
    assert "BlaiToolchainCfgPatchSizeElements* = 65_536'u32" in npu_source
    assert "BlaiToolchainCfgPatchElementBytes* = 4'u32" in npu_source
    assert "BlaiToolchainCfgPatchNum* = 45'u32" in npu_source
    assert "BlaiToolchainPatchSizeBytes* = 262144'u32" in npu_source
    assert "BlaiToolchainCfgTotalBytes*" in npu_source
    assert "BlaiToolchainMaxPsramPatchSlots* = 40'u32" in npu_source
    assert "BlaiToolchainMaxPsramPatchSlotsI32* = 40'i32" in npu_source
    assert "BlaiToolchainMaxPatchStartSlot* = 31'u32" in npu_source
    assert "BlaiToolchainPsramAllocateLayerCapacity* = 500'u32" in npu_source
    assert "BlaiToolchainPsramAllocateRelationSlots* = 5'u32" in npu_source
    assert "BlaiToolchainPsramAllocateRelationInitValue* = -1'i32" in (
        npu_source
    )
    assert "BlaiToolchainPsramAllocateRelationEntryCount* =" in npu_source
    assert "BlaiToolchainPsramAllocateRequestTableCount* =" in npu_source
    assert "BlaiToolchainPsramAllocateBitmapSlotCount* =" in npu_source
    assert "BlaiToolchainPsramAllocateOwnerSlotCount* =" in npu_source
    assert "BlaiToolchainPsramOwnerConvType* = 0x00'i32" in npu_source
    assert "BlaiToolchainPsramOwnerRouteType* = 0x03'i32" in npu_source
    assert "BlaiToolchainPsramRelationRouteType* = 0x09'i32" in npu_source
    assert "BlaiToolchainPsramRelationRouteWType* = 0x0E'i32" in npu_source
    assert "BlaiToolchainPsramAllocateSkipLayerType* = 0x1A'i32" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchLargeLayerMask* = 0x0080_0040_0000_0001'u64"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchLargeMaskMaxType* = 0x37'i32" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchLargeThresholdBytes* =\n"
        "    BlaiMemAllocWeightPatchThresholdBytes"
    ) in npu_source
    assert (
        "BlaiToolchainSetWeiPatchLargePageBytes* =\n"
        "    BlaiToolchainSetWeiPatchLargeThresholdBytes"
    ) in npu_source
    assert "BlaiToolchainSetWeiPatchLowerThresholdBytes* = BlaiNpuLocalBufferBytes" in (
        npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchLowerPageBytes* =\n"
        "    BlaiToolchainSetWeiPatchLowerThresholdBytes"
    ) in npu_source
    assert "BlaiToolchainSetWeiPatchLowerFlagValue* = 2'u32" in npu_source
    assert "BlaiToolchainSetWeiPatchNoPatchFlagValue* = 0'u32" in npu_source
    toolchain_patch_block = re.search(
        r"proc blaiToolchainPatchSearchPlanInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert toolchain_patch_block is not None
    assert "blaiToolchainPatchOccupiedCursor(patchIndex, occupied.len)" in (
        toolchain_patch_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(patchIndex, occupied.len)" not in (
        toolchain_patch_block.group(0)
    )
    assert "runStart > BlaiToolchainMaxPatchStartSlot" in (
        toolchain_patch_block.group(0)
    )
    assert "outResult.owner = 0'i32" in npu_source
    assert "outResult.selectedOwner = currentLayerIndex - 1" in npu_source
    assert "outResult.selectedOwner = relationConsumerLayerIndex" in npu_source
    assert "outResult.selectedOwner = currentLayerIndex + 1" in npu_source
    assert "outResult.selectedOwner = 1'i32" in npu_source
    assert (
        "outResult.stateAfter.occupiedAfter[stateCursor.index] = true"
        in npu_source
    )
    assert "proc blaiApplyToolchainPatchAssignmentTableState*" in npu_source
    assert "owners[ownerCursor.index] = plan.owner" not in npu_source
    assert (
        "outResult.relationEntryCount ==\n"
        "        BlaiToolchainPsramAllocateRelationEntryCount"
    ) in npu_source
    assert (
        "outResult.relationInitValue ==\n"
        "        BlaiToolchainPsramAllocateRelationInitValue"
    ) in npu_source
    assert (
        "outResult.requestTableCount ==\n"
        "        BlaiToolchainPsramAllocateRequestTableCount"
    ) in npu_source
    assert (
        "outResult.bitmapSlotCount ==\n"
        "        BlaiToolchainPsramAllocateBitmapSlotCount"
    ) in npu_source
    assert (
        "outResult.ownerSlotCount == BlaiToolchainPsramAllocateOwnerSlotCount"
        in npu_source
    )
    scratch_block = re.search(
        r"proc blaiToolchainPsramAllocateScratchPlanInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert scratch_block is not None
    assert "2500'u32" not in scratch_block.group(0)
    assert "500'u32" not in scratch_block.group(0)
    assert "40'u32" not in scratch_block.group(0)
    assert "-1'i32" not in scratch_block.group(0)
    assert (
        "outResult.relationInitValue = "
        "BlaiToolchainPsramAllocateRelationInitValue"
    ) in scratch_block.group(0)
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" in npu_source
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteWType" in npu_source
    relation_append_eligibility_block = re.search(
        r"proc blaiToolchainPsramRelationAppendEligibility\*\(.*?"
        r"proc blaiToolchainPsramRelationAppendPlanInto\*",
        npu_source,
        re.S,
    )
    assert relation_append_eligibility_block is not None
    assert "result.tfliteEligible = tfliteMode" in (
        relation_append_eligibility_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteType" in (
        relation_append_eligibility_block.group(0)
    )
    assert "layerTypeValue == BlaiToolchainPsramRelationRouteWType" in (
        relation_append_eligibility_block.group(0)
    )
    assert "result.eligibleLayer =" in relation_append_eligibility_block.group(0)
    relation_append_input_decision_block = re.search(
        r"proc blaiToolchainPsramRelationAppendInputDecision\*\(.*?"
        r"proc blaiToolchainPsramRelationAppendPlanInto\*",
        npu_source,
        re.S,
    )
    assert relation_append_input_decision_block is not None
    assert "result.directPredecessorIndex = layerIndex - 1" in (
        relation_append_input_decision_block.group(0)
    )
    assert "inputLayer == result.directPredecessorIndex" in (
        relation_append_input_decision_block.group(0)
    )
    assert "outResult.firstBlock = blaiToolchainPsramRelationCapacity" in npu_source
    assert "outResult.consumerLayerIndex = -1" in npu_source
    assert "BlaiToolchainPsramRelationConsumerScanStart* = object" in npu_source
    assert "proc blaiToolchainPsramRelationConsumerScanStart*" in npu_source
    assert "let scanStart =" in npu_source
    assert "blaiToolchainPsramRelationConsumerScanStart(currentLayer, layerCount)" in (
        npu_source
    )
    assert "for scanLayer in scanStart.firstFutureLayer ..< layerCount:" in (
        npu_source
    )
    assert "for scanLayer in firstFuture ..< layerCount:" not in npu_source
    relation_consumer_block = re.search(
        r"proc blaiToolchainPsramRelationConsumerPlanInto\*\(.*?"
        r"proc blaiToolchainPsramRelationConsumerPlan\*",
        npu_source,
        re.S,
    )
    assert relation_consumer_block is not None
    assert "let firstFuture = currentLayer + 1'u32" not in (
        relation_consumer_block.group(0)
    )
    assert "scanStart.hasFutureRows" in relation_consumer_block.group(0)
    assert "blaiToolchainPsramRelationCountCursor(" in (
        relation_consumer_block.group(0)
    )
    assert "blaiToolchainPsramRelationRowCursor(" in (
        relation_consumer_block.group(0)
    )
    assert "blaiToolchainPsramRelationEntryCursor(relationIndex)" in (
        relation_consumer_block.group(0)
    )
    assert "relationRows[rowCursor.index][entryCursor.index] == layerIndex" in (
        relation_consumer_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(scanLayer, relationCounts.len)" not in (
        relation_consumer_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(scanLayer, relationRows.len)" not in (
        relation_consumer_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(\n            relationIndex" not in (
        relation_consumer_block.group(0)
    )
    assert "outResult.consumerLayerIndex = consumerLayer.value" in npu_source
    assert "inc outResult.matchCount" in npu_source
    assert "outResult.inputStorageCount = blaiOpenArrayLenU32(inputLayers)" in (
        npu_source
    )
    assert "if countField.value > outResult.inputStorageCount:" in npu_source
    assert "if not outResult.found and inputLayers[inputCursor.index] == layerIndex" in (
        npu_source
    )
    assert "outResult.requestedPatchCount =" in npu_source
    assert "outResult.inputBytes div outResult.patchSizeBytes" in npu_source
    assert "currentLayerType == blaiConvolutional and nextLayerType == blaiRoute" in npu_source
    assert "debugConvMaxPath and currentLayerType == blaiConvMax" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerTransitionTablesState*" in npu_source
    assert "proc blaiApplyToolchainPsramOwnerCleanupTablesState*" in npu_source
    assert "currentLayerTypeValue == BlaiToolchainPsramOwnerConvType" in npu_source
    assert "nextLayerTypeValue == BlaiToolchainPsramOwnerRouteType" in npu_source
    assert "routeDebugFlag and" in npu_source
    assert "currentLayerTypeValue == BlaiToolchainPsramRelationRouteType" in (
        npu_source
    )
    assert "of blaiToolchainPsramOwnerCleanupRelease:" in npu_source
    assert "outResult.routeWDoublePrimary = layerType == blaiRouteW" in npu_source
    assert "outResult.primaryPages =" in npu_source
    assert "outResult.selectedStartPatchCount =" in npu_source
    assert "min(outResult.primaryPages, outResult.auxiliaryPages)" in npu_source
    assert "BlaiToolchainSetWeiPatchSpecialDoubleAuxType* = 0x20'i32" in npu_source
    assert "outResult.maxCandidateCount = BlaiMemAllocSearchSlack" in npu_source
    assert "blaiToolchainRoundEvenSplit(blaiCeilDivU32(primaryNumerator, divisor))" in npu_source
    assert "primaryBytes.value <= BlaiNpuLocalBufferBytes" in npu_source
    set_wei_divisor_block = re.search(
        r"proc blaiToolchainSetWeiPatchDivisorPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchDivisorPlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_divisor_block is not None
    assert "let primaryBytes = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        set_wei_divisor_block.group(0)
    )
    assert "let auxiliaryBytes = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        set_wei_divisor_block.group(0)
    )
    assert "outResult.primaryLocalBytes = primaryBytes.value" in (
        set_wei_divisor_block.group(0)
    )
    assert "outResult.auxiliaryLocalBytes = auxiliaryBytes.value" in (
        set_wei_divisor_block.group(0)
    )
    assert "outResult.primaryLocalBytes = primaryBytes64.uint32" not in (
        set_wei_divisor_block.group(0)
    )
    assert "outResult.auxiliaryLocalBytes = auxiliaryBytes64.uint32" not in (
        set_wei_divisor_block.group(0)
    )
    assert "outResult.firstBlock = blaiToolchainSetWeiPatchDivisorNoFit" in npu_source
    assert "proc blaiToolchainFillPatchSplit(" in npu_source
    assert "splits[patchCursor.index] = value" in npu_source
    fill_patch_split_block = re.search(
        r"proc blaiToolchainFillPatchSplit\(.*?"
        r"proc blaiToolchainSetWeiPatchStoreSelectPlanInto\*",
        npu_source,
        re.S,
    )
    assert fill_patch_split_block is not None
    assert "let patchPosition = blaiMemAllocPatchSegmentPosition(" in (
        fill_patch_split_block.group(0)
    )
    assert "if patchPosition.last:" in fill_patch_split_block.group(0)
    assert "patchIndex + 1'u32 == patchCount" not in (
        fill_patch_split_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchStoreSelectEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchStoreSelectEvidence*" in npu_source
    assert "outResult.splitValues[0] = divisorPlan.primaryNumerator" in npu_source
    assert "outResult.largeKernelFlagSet = largeKernelFlagSet" in npu_source
    store_select_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchStoreSelectEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchStoreSelectPlanInto\*",
        npu_source,
        re.S,
    )
    assert store_select_evidence_block is not None
    assert "result.primaryPressureExceedsLocal =" in (
        store_select_evidence_block.group(0)
    )
    assert "result.divisorRequiresSplit = selectedDivisor > 1'u32" in (
        store_select_evidence_block.group(0)
    )
    assert "result.auxiliaryPressureExceedsLocal =" in (
        store_select_evidence_block.group(0)
    )
    assert "result.mode = blaiToolchainSetWeiPatchStoreAuxiliary" in (
        store_select_evidence_block.group(0)
    )
    assert "result.mode = blaiToolchainSetWeiPatchStoreDivisor" in (
        store_select_evidence_block.group(0)
    )
    store_select_block = re.search(
        r"proc blaiToolchainSetWeiPatchStoreSelectPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchStoreSelectPlan\*",
        npu_source,
        re.S,
    )
    assert store_select_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchStoreSelectEvidence(" in (
        store_select_block.group(0)
    )
    assert "outResult.mode = evidence.mode" in store_select_block.group(0)
    assert "outResult.divisorRequiresSplit = evidence.divisorRequiresSplit" in (
        store_select_block.group(0)
    )
    assert "selectedDivisor > 1'u32" not in store_select_block.group(0)
    assert "primaryBytes > BlaiNpuLocalBufferBytes" not in (
        store_select_block.group(0)
    )
    assert "auxiliaryBytes > BlaiNpuLocalBufferBytes" not in (
        store_select_block.group(0)
    )
    assert "elif result.primaryPressureExceedsLocal or result.divisorRequiresSplit" in (
        store_select_evidence_block.group(0)
    )
    assert "outResult.selectedGroupCount =" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchPressureDefaultGroupCount* = 1'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureOneByOneKernelExtent* = 1'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureLargeKernelExtent* = 3'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureAuxExtentThreshold* = 1'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureMatchedMultiplier* = 4'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureDefaultMultiplier* = 1'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureOneByOneGroupFactor* = 8'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureSpatialGroupFactor* = 9'u32"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureLargeSpatialFactor* = 81'u64"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressurePageRoundingBias* = 1'u64"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureNonDivisibleExtraPages* = 1'u32"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchNoPatchPatchCount* = 1'u32" in npu_source
    assert "BlaiToolchainSetWeiPatchNoPatchSplitCount* = 1'u32" in npu_source
    assert (
        "BlaiToolchainSetWeiPatchNoPatchPsramPatchTotal* = 0'u32"
        in npu_source
    )
    assert (
        "outResult.selectedGroupCount *\n"
        "        BlaiToolchainSetWeiPatchPressureOneByOneGroupFactor"
        in npu_source
    )
    assert (
        "outResult.selectedGroupCount *\n"
        "        BlaiToolchainSetWeiPatchPressureSpatialGroupFactor"
        in npu_source
    )
    assert (
        "BlaiToolchainSetWeiPatchPressureLargeSpatialFactor"
        in npu_source
    )
    assert "BlaiToolchainSetWeiPatchU32ScalarAbi* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchU32ScalarAbi*" in npu_source
    assert "BlaiToolchainSetWeiPatchI32U32Abi* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchI32U32Abi*" in npu_source
    assert "if outResult.largeKernelOrAux:" in npu_source
    assert (
        "outResult.kernelExtent.uint64 * outResult.kernelExtent.uint64"
        in npu_source
    )
    assert "outResult.layerTypeInMaskRange =" in npu_source
    set_wei_pressure_block = re.search(
        r"proc blaiToolchainSetWeiPatchPressurePlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchPressurePlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_pressure_block is not None
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.maskRange = maskShift.valid" in (
        set_wei_pressure_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchLargeLayerMask shr maskShift.value" in (
        set_wei_pressure_block.group(0)
    )
    assert "layerTypeValue.int" not in set_wei_pressure_block.group(0)
    assert "BlaiToolchainSetWeiPatchLargeFlagEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeFlagEvidence*" in npu_source
    large_flag_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeFlagEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLargeFlagPlanInto\*",
        npu_source,
        re.S,
    )
    assert large_flag_evidence_block is not None
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" in (
        large_flag_evidence_block.group(0)
    )
    assert "result.layerTypeInMaskRange = maskShift.valid" in (
        large_flag_evidence_block.group(0)
    )
    assert "result.layerMask shr maskShift.value" in (
        large_flag_evidence_block.group(0)
    )
    assert "result.largeEnough = bytePressure > result.thresholdBytes" in (
        large_flag_evidence_block.group(0)
    )
    assert "result.flagSet = result.largeEnough and result.layerMaskBitSet" in (
        large_flag_evidence_block.group(0)
    )
    large_flag_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeFlagPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLargeFlagPlan\*",
        npu_source,
        re.S,
    )
    assert large_flag_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchLargeFlagEvidence(" in (
        large_flag_block.group(0)
    )
    assert "outResult.layerTypeInMaskRange = evidence.layerTypeInMaskRange" in (
        large_flag_block.group(0)
    )
    assert "outResult.flagSet = evidence.flagSet" in large_flag_block.group(0)
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" not in (
        large_flag_block.group(0)
    )
    assert "outResult.layerMask shr maskShift.value" not in (
        large_flag_block.group(0)
    )
    assert "layerTypeValue.int" not in large_flag_block.group(0)
    assert "proc blaiToolchainFloorPowerOfTwo(value: uint32): uint32 =" in npu_source
    assert "BlaiToolchainSetWeiPatchPressurePagePlan* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchPressurePagePlan*" in npu_source
    assert "result.nonDivisiblePageExtra =" in npu_source
    assert "let roundingBias = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        npu_source
    )
    assert "pageBytes - roundingBias.value" in npu_source
    assert "roundingBias.value.uint64" in npu_source
    pressure_page_block = re.search(
        r"proc blaiToolchainSetWeiPatchPressurePagePlan\*\(.*?"
        r"proc blaiToolchainFillFixedSplit",
        npu_source,
        re.S,
    )
    assert pressure_page_block is not None
    assert "let roundedPressure = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        pressure_page_block.group(0)
    )
    assert "roundedPressure.value div pageBytes" in (
        pressure_page_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchPressurePageRoundingBias.uint32" not in (
        pressure_page_block.group(0)
    )
    assert "result.roundedPressure.uint32" not in pressure_page_block.group(0)
    assert "BlaiToolchainSetWeiPatchPressureNonDivisibleExtraPages" in (
        npu_source
    )
    assert "BlaiToolchainSetWeiPatchLargeSplitEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeSplitEvidence*" in npu_source
    large_split_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeSplitEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLargeSplitPlanInto\*",
        npu_source,
        re.S,
    )
    assert large_split_evidence_block is not None
    assert "let pagePlan = blaiToolchainSetWeiPatchPressurePagePlan(" in (
        large_split_evidence_block.group(0)
    )
    assert "result.nonDivisiblePageExtra = pagePlan.nonDivisiblePageExtra" in (
        large_split_evidence_block.group(0)
    )
    assert "result.pressurePageCount = pagePlan.pressurePageCount" in (
        large_split_evidence_block.group(0)
    )
    assert "splitNumerator div result.pressurePageCount" in (
        large_split_evidence_block.group(0)
    )
    assert "blaiToolchainFloorPowerOfTwo(result.quotientBeforePowerOfTwo)" in (
        large_split_evidence_block.group(0)
    )
    large_split_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeSplitPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLargeSplitPlan\*",
        npu_source,
        re.S,
    )
    assert large_split_block is not None
    assert "let evidence =" in large_split_block.group(0)
    assert "outResult.selectedSplit = evidence.selectedSplit" in (
        large_split_block.group(0)
    )
    assert "if not evidence.valid:" in large_split_block.group(0)
    assert "splitNumerator div outResult.pressurePageCount" not in (
        large_split_block.group(0)
    )
    assert "blaiToolchainFloorPowerOfTwo(outResult.quotientBeforePowerOfTwo)" not in (
        large_split_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchLowerFlagEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerFlagEvidence*" in npu_source
    lower_flag_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerFlagEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLowerFlagPlanInto\*",
        npu_source,
        re.S,
    )
    assert lower_flag_evidence_block is not None
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.layerTypeInMaskRange = maskShift.valid" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.layerMask shr maskShift.value" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.firstBlock = blaiToolchainSetWeiPatchLowerFlagDivisor" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.quotient.uint64 * multiplier.uint64" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.flagValue = BlaiToolchainSetWeiPatchLowerFlagValue" in (
        lower_flag_evidence_block.group(0)
    )
    lower_flag_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerFlagPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLowerFlagPlan\*",
        npu_source,
        re.S,
    )
    assert lower_flag_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchLowerFlagEvidence(" in (
        lower_flag_block.group(0)
    )
    assert "outResult.firstBlock = evidence.firstBlock" in (
        lower_flag_block.group(0)
    )
    assert "outResult.flagValue = evidence.flagValue" in lower_flag_block.group(0)
    assert "let maskShift = blaiToolchainSetWeiPatchLayerMaskShiftAbi(" not in (
        lower_flag_block.group(0)
    )
    assert "outResult.layerMask shr maskShift.value" not in (
        lower_flag_block.group(0)
    )
    assert "outResult.quotient.uint64 * multiplier.uint64" not in (
        lower_flag_block.group(0)
    )
    assert "layerTypeValue.int" not in lower_flag_block.group(0)
    assert "blaiToolchainFillFixedSplit(" in npu_source
    fill_fixed_split_block = re.search(
        r"proc blaiToolchainFillFixedSplit\(.*?"
        r"proc blaiToolchainSetWeiPatchLargeSplitPlanInto\*",
        npu_source,
        re.S,
    )
    assert fill_fixed_split_block is not None
    assert "let patchPosition = blaiMemAllocPatchSegmentPosition(" in (
        fill_fixed_split_block.group(0)
    )
    assert "if patchPosition.last:" in fill_fixed_split_block.group(0)
    assert "patchIndex + 1'u32 == patchCount" not in (
        fill_fixed_split_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchLargeTotalEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLargeTotalEvidence*" in npu_source
    large_total_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeTotalEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLargeTotalPlanInto\*",
        npu_source,
        re.S,
    )
    assert large_total_evidence_block is not None
    assert "result.patchSizeBytes = BlaiToolchainPatchSizeBytes" in (
        large_total_evidence_block.group(0)
    )
    assert "result.finalSplitValue = splitPlan.splitValues[lastCursor.index]" in (
        large_total_evidence_block.group(0)
    )
    set_wei_large_total_block = re.search(
        r"proc blaiToolchainSetWeiPatchLargeTotalPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLargeTotalPlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_large_total_block is not None
    assert "let evidence =" in set_wei_large_total_block.group(0)
    assert "outResult.finalSplitValue = evidence.finalSplitValue" in (
        set_wei_large_total_block.group(0)
    )
    assert "outResult.totalPatchCount = evidence.totalPatchCount" in (
        set_wei_large_total_block.group(0)
    )
    assert "let finalPatchPosition =" in large_total_evidence_block.group(0)
    assert "blaiMemAllocFinalPatchSegmentPosition(splitPlan.patchCount)" in (
        large_total_evidence_block.group(0)
    )
    assert "blaiWeightPatchCursor(finalPatchPosition.patchIndex)" in (
        large_total_evidence_block.group(0)
    )
    assert "splitPlan.patchCount - 1'u32" not in (
        large_total_evidence_block.group(0)
    )
    assert "unitFactor.uint64 * splitPlan.selectedSplit.uint64" in (
        large_total_evidence_block.group(0)
    )
    assert "unitFactor.uint64 * result.finalSplitValue.uint64" in (
        large_total_evidence_block.group(0)
    )
    assert "unitFactor.uint64 * splitPlan.splitNumerator.uint64" in (
        large_total_evidence_block.group(0)
    )
    assert "result.maxLocalBytes =" in large_total_evidence_block.group(0)
    assert "result.perPatchContribution =" in large_total_evidence_block.group(0)
    assert "result.splitCountContribution =" in large_total_evidence_block.group(0)
    assert "let finalPatchPosition =" not in set_wei_large_total_block.group(0)
    assert "unitFactor.uint64 * splitPlan.selectedSplit.uint64" not in (
        set_wei_large_total_block.group(0)
    )
    set_wei_pressure_block = re.search(
        r"proc blaiToolchainSetWeiPatchPressurePlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchPressurePlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_pressure_block is not None
    assert "let countAField = blaiToolchainSetWeiPatchI32U32Abi(countA)" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.countA = countAField.value" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.kernelExtent = kernelExtentField.value" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.countA = countA.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.countB = countB.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.groupCount = groupCount.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.kernelExtent = kernelExtent.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.auxExtent = auxExtent.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "let bytePressure = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.bytePressure = bytePressure.value" in (
        set_wei_pressure_block.group(0)
    )
    assert "outResult.bytePressure = pressure64.uint32" not in (
        set_wei_pressure_block.group(0)
    )
    assert "let selectedBytes = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        large_total_evidence_block.group(0)
    )
    assert "let totalPatchCount = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        large_total_evidence_block.group(0)
    )
    assert "result.selectedLocalBytes = selectedBytes.value" in (
        large_total_evidence_block.group(0)
    )
    assert "result.totalPatchCount = totalPatchCount.value" in (
        large_total_evidence_block.group(0)
    )
    assert "selectedBytes64.uint32" not in large_total_evidence_block.group(0)
    assert "remainderBytes64.uint32" not in large_total_evidence_block.group(0)
    assert "splitCountBytes64.uint32" not in large_total_evidence_block.group(0)
    assert "total64.uint32" not in large_total_evidence_block.group(0)
    assert "result.quotient = numerator div divisor" in (
        lower_flag_evidence_block.group(0)
    )
    set_wei_lower_flag_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerFlagPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLowerFlagPlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_lower_flag_block is not None
    assert "let bytePressure = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        lower_flag_evidence_block.group(0)
    )
    assert "result.bytePressure = bytePressure.value" in (
        lower_flag_evidence_block.group(0)
    )
    assert "outResult.bytePressure = evidence.bytePressure" in (
        set_wei_lower_flag_block.group(0)
    )
    assert "outResult.quotient = evidence.quotient" in (
        set_wei_lower_flag_block.group(0)
    )
    assert "outResult.bytePressure = pressure64.uint32" not in (
        set_wei_lower_flag_block.group(0)
    )
    assert "outResult.lowerEnough = evidence.lowerEnough" in (
        set_wei_lower_flag_block.group(0)
    )
    assert "result.flagValue = BlaiToolchainSetWeiPatchLowerFlagValue" in (
        lower_flag_evidence_block.group(0)
    )
    assert "proc blaiToolchainFillLowerFixedSplit(" in npu_source
    assert "BlaiToolchainSetWeiPatchLowerSplitEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerSplitEvidence*" in npu_source
    lower_split_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerSplitEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLowerSplitPlanInto\*",
        npu_source,
        re.S,
    )
    assert lower_split_evidence_block is not None
    assert "flagPlan.flagValue != BlaiToolchainSetWeiPatchLowerFlagValue" in (
        lower_split_evidence_block.group(0)
    )
    assert "result.pageBytes = BlaiToolchainSetWeiPatchLowerPageBytes" in (
        lower_split_evidence_block.group(0)
    )
    assert "let pagePlan = blaiToolchainSetWeiPatchPressurePagePlan(" in (
        lower_split_evidence_block.group(0)
    )
    assert "result.nonDivisiblePageExtra = pagePlan.nonDivisiblePageExtra" in (
        lower_split_evidence_block.group(0)
    )
    assert "result.pressurePageCount = pagePlan.pressurePageCount" in (
        lower_split_evidence_block.group(0)
    )
    assert "splitNumerator div result.pressurePageCount" in (
        lower_split_evidence_block.group(0)
    )
    assert "blaiToolchainFloorPowerOfTwo(result.quotientBeforePowerOfTwo)" in (
        lower_split_evidence_block.group(0)
    )
    set_wei_lower_split_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerSplitPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLowerSplitPlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_lower_split_block is not None
    assert "let evidence =" in set_wei_lower_split_block.group(0)
    assert "outResult.selectedSplit = evidence.selectedSplit" in (
        set_wei_lower_split_block.group(0)
    )
    assert "if not evidence.valid:" in set_wei_lower_split_block.group(0)
    assert "splitNumerator div outResult.pressurePageCount" not in (
        set_wei_lower_split_block.group(0)
    )
    assert "blaiToolchainFloorPowerOfTwo(outResult.quotientBeforePowerOfTwo)" not in (
        set_wei_lower_split_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchLowerTotalEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchLowerTotalEvidence*" in npu_source
    lower_total_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerTotalEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchLowerTotalPlanInto\*",
        npu_source,
        re.S,
    )
    assert lower_total_evidence_block is not None
    assert "result.patchSizeBytes = BlaiToolchainPatchSizeBytes" in (
        lower_total_evidence_block.group(0)
    )
    assert "let finalPatchPosition =" in lower_total_evidence_block.group(0)
    assert "blaiMemAllocFinalPatchSegmentPosition(splitPlan.patchCount)" in (
        lower_total_evidence_block.group(0)
    )
    assert "blaiWeightPatchCursor(finalPatchPosition.patchIndex)" in (
        lower_total_evidence_block.group(0)
    )
    assert "result.finalSplitValue = splitPlan.splitValues[lastCursor.index]" in (
        lower_total_evidence_block.group(0)
    )
    assert "splitPlan.patchCount - 1'u32" not in (
        lower_total_evidence_block.group(0)
    )
    assert "let selectedBytes = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        lower_total_evidence_block.group(0)
    )
    assert "let totalPatchCount = blaiToolchainSetWeiPatchU32ScalarAbi(" in (
        lower_total_evidence_block.group(0)
    )
    assert "result.selectedLocalBytes = selectedBytes.value" in (
        lower_total_evidence_block.group(0)
    )
    assert "result.totalPatchCount = totalPatchCount.value" in (
        lower_total_evidence_block.group(0)
    )
    assert "selectedBytes64.uint32" not in lower_total_evidence_block.group(0)
    assert "remainderBytes64.uint32" not in lower_total_evidence_block.group(0)
    assert "splitCountBytes64.uint32" not in lower_total_evidence_block.group(0)
    assert "total64.uint32" not in lower_total_evidence_block.group(0)
    set_wei_lower_total_block = re.search(
        r"proc blaiToolchainSetWeiPatchLowerTotalPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchLowerTotalPlan\*",
        npu_source,
        re.S,
    )
    assert set_wei_lower_total_block is not None
    assert "let evidence =" in set_wei_lower_total_block.group(0)
    assert "outResult.finalSplitValue = evidence.finalSplitValue" in (
        set_wei_lower_total_block.group(0)
    )
    assert "outResult.totalPatchCount = evidence.totalPatchCount" in (
        set_wei_lower_total_block.group(0)
    )
    assert "let finalPatchPosition =" not in set_wei_lower_total_block.group(0)
    assert "unitFactor.uint64 * splitPlan.selectedSplit.uint64" not in (
        set_wei_lower_total_block.group(0)
    )
    assert "blaiToolchainFillLowerFixedSplit(" in npu_source
    assert "result.firstBlock = blaiToolchainSetWeiPatchLowerTotalSplitPlan" in (
        lower_total_evidence_block.group(0)
    )
    assert "result.firstBlock = blaiToolchainSetWeiPatchLowerTotalOverflow" in (
        lower_total_evidence_block.group(0)
    )
    fill_lower_fixed_split_block = re.search(
        r"proc blaiToolchainFillLowerFixedSplit\(.*?"
        r"proc blaiToolchainSetWeiPatchLowerSplitPlanInto\*",
        npu_source,
        re.S,
    )
    assert fill_lower_fixed_split_block is not None
    assert "let patchPosition = blaiMemAllocPatchSegmentPosition(" in (
        fill_lower_fixed_split_block.group(0)
    )
    assert "if patchPosition.last:" in fill_lower_fixed_split_block.group(0)
    assert "patchIndex + 1'u32 == patchCount" not in (
        fill_lower_fixed_split_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchNoPatchEvidence* = object" in npu_source
    assert "proc blaiToolchainSetWeiPatchNoPatchEvidence*" in npu_source
    no_patch_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchNoPatchEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchNoPatchPlanInto\*",
        npu_source,
        re.S,
    )
    assert no_patch_evidence_block is not None
    assert (
        "result.patchCount = BlaiToolchainSetWeiPatchNoPatchPatchCount"
        in no_patch_evidence_block.group(0)
    )
    assert (
        "result.splitCount = BlaiToolchainSetWeiPatchNoPatchSplitCount"
        in no_patch_evidence_block.group(0)
    )
    assert "result.splitValues[0] = splitNumerator" in (
        no_patch_evidence_block.group(0)
    )
    assert (
        "result.psramPatchTotal = "
        "BlaiToolchainSetWeiPatchNoPatchPsramPatchTotal"
        in no_patch_evidence_block.group(0)
    )
    assert "result.flagValue = BlaiToolchainSetWeiPatchNoPatchFlagValue" in (
        no_patch_evidence_block.group(0)
    )
    no_patch_block = re.search(
        r"proc blaiToolchainSetWeiPatchNoPatchPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchNoPatchPlan\*",
        npu_source,
        re.S,
    )
    assert no_patch_block is not None
    assert "let evidence =" in no_patch_block.group(0)
    assert "outResult.splitValues = evidence.splitValues" in no_patch_block.group(0)
    assert "outResult.flagValue = evidence.flagValue" in no_patch_block.group(0)
    assert "outResult.splitValues[0] = splitNumerator" not in (
        no_patch_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchBranchSelectionEvidence* = object" in (
        npu_source
    )
    assert "proc blaiToolchainSetWeiPatchBranchSelectionEvidence*" in npu_source
    branch_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchSelectionEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchBranchPlanInto\*",
        npu_source,
        re.S,
    )
    assert branch_evidence_block is not None
    assert "result.largeBranchActive =" in branch_evidence_block.group(0)
    assert "largeTotal.splitPlan.flagPlan.flagSet" in (
        branch_evidence_block.group(0)
    )
    assert "result.lowerBranchActive =" in branch_evidence_block.group(0)
    assert "lowerTotal.splitPlan.flagPlan.flagValue ==" in (
        branch_evidence_block.group(0)
    )
    assert (
        "result.mode = blaiToolchainSetWeiPatchBranchLarge"
        in branch_evidence_block.group(0)
    )
    assert (
        "result.mode = blaiToolchainSetWeiPatchBranchLower"
        in branch_evidence_block.group(0)
    )
    assert (
        "result.mode = blaiToolchainSetWeiPatchBranchNoPatch"
        in branch_evidence_block.group(0)
    )
    assert "result.splitValues = largeTotal.splitPlan.splitValues" in (
        branch_evidence_block.group(0)
    )
    assert "result.splitValues = lowerTotal.splitPlan.splitValues" in (
        branch_evidence_block.group(0)
    )
    assert "result.splitValues = noPatch.splitValues" in (
        branch_evidence_block.group(0)
    )
    branch_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchBranchPlan\*",
        npu_source,
        re.S,
    )
    assert branch_block is not None
    assert "let evidence =" in branch_block.group(0)
    assert "outResult.largeBranchActive = evidence.largeBranchActive" in (
        branch_block.group(0)
    )
    assert "outResult.lowerBranchActive = evidence.lowerBranchActive" in (
        branch_block.group(0)
    )
    assert "outResult.mode = evidence.mode" in branch_block.group(0)
    assert "outResult.patchCount = evidence.patchCount" in branch_block.group(0)
    assert "outResult.returnedPatchCount = evidence.returnedPatchCount" in (
        branch_block.group(0)
    )
    assert "outResult.firstBlock = evidence.firstBlock" in branch_block.group(0)
    assert "outResult.valid = evidence.valid" in branch_block.group(0)
    assert "largeTotal.splitPlan.flagPlan.flagSet" not in branch_block.group(0)
    assert "lowerTotal.splitPlan.flagPlan.flagValue ==" not in (
        branch_block.group(0)
    )
    assert (
        "outResult.mode = blaiToolchainSetWeiPatchBranchLarge"
        not in branch_block.group(0)
    )
    assert (
        "outResult.mode = blaiToolchainSetWeiPatchBranchLower"
        not in branch_block.group(0)
    )
    assert (
        "outResult.mode = blaiToolchainSetWeiPatchBranchNoPatch"
        not in branch_block.group(0)
    )
    assert "BlaiToolchainSetWeiPatchBranchState* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchSummaryState* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchApplyBlock* = enum" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchApplyEvidence* = object" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchApplyPlan* = object" in npu_source
    assert "summaryStateAfter*: BlaiToolchainSetWeiPatchBranchSummaryState" in (
        npu_source
    )
    assert "proc blaiToolchainSetWeiPatchBranchSummaryState*" in npu_source
    assert "proc blaiToolchainSetWeiPatchBranchApplyEvidence*" in npu_source
    assert "proc blaiToolchainSetWeiPatchBranchApplyPlanInto*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchBranchState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchBranchResultState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchBranchScalarState*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchBranchSummaryScalarState*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchBranchScalars*" in npu_source
    assert "proc blaiApplyToolchainSetWeiPatchBranchSummaryScalars*" in (
        npu_source
    )
    assert "proc blaiApplyToolchainSetWeiPatchBranch*" in npu_source
    branch_apply_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchApplyEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchBranchApplyPlanInto\*",
        npu_source,
        re.S,
    )
    assert branch_apply_evidence_block is not None
    assert "if not branch.valid:" in branch_apply_evidence_block.group(0)
    assert "branch.splitCount > splitStorageCount" in (
        branch_apply_evidence_block.group(0)
    )
    assert "result.stateAfter = blaiToolchainSetWeiPatchBranchState" in (
        branch_apply_evidence_block.group(0)
    )
    assert "result.summaryStateAfter = blaiToolchainSetWeiPatchBranchSummaryState" in (
        branch_apply_evidence_block.group(0)
    )
    assert "result.writesApplied = branch.splitCount" in (
        branch_apply_evidence_block.group(0)
    )
    assert "result.firstBlock = blaiToolchainSetWeiPatchBranchApplyNoBlock" in (
        branch_apply_evidence_block.group(0)
    )
    branch_apply_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchApplyPlanInto\*.*?"
        r"proc blaiToolchainSetWeiPatchBranchApplyPlan\*",
        npu_source,
        re.S,
    )
    assert branch_apply_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchBranchApplyEvidence(" in (
        branch_apply_block.group(0)
    )
    assert "outResult.stateAfter = evidence.stateAfter" in branch_apply_block.group(0)
    assert "outResult.summaryStateAfter = evidence.summaryStateAfter" in (
        branch_apply_block.group(0)
    )
    assert "outResult.writesApplied = evidence.writesApplied" in (
        branch_apply_block.group(0)
    )
    assert "if not branch.valid:" not in branch_apply_block.group(0)
    assert "branch.splitCount >" not in branch_apply_block.group(0)
    assert "outResult.stateAfter = blaiToolchainSetWeiPatchBranchState" not in (
        branch_apply_block.group(0)
    )
    branch_apply_public_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchBranch\*\(.*?"
        r"proc blaiMemAllocLinePatchProbe\*",
        npu_source,
        re.S,
    )
    assert branch_apply_public_block is not None
    assert "blaiApplyToolchainSetWeiPatchBranchResultState(" in (
        branch_apply_public_block.group(0)
    )
    assert "let stateAfter = plan.stateAfter" not in (
        branch_apply_public_block.group(0)
    )
    assert "psramPatchTotal = stateAfter.psramPatchTotal" not in (
        branch_apply_public_block.group(0)
    )
    assert "splitValues[splitCursor.index] = stateAfter.splitValues[splitCursor.index]" not in (
        branch_apply_public_block.group(0)
    )
    branch_result_state_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchBranchResultState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchBranchScalarState\*",
        npu_source,
        re.S,
    )
    assert branch_result_state_block is not None
    assert "blaiToolchainSetWeiPatchSplitCursor(splitIndex, splitValues.len)" in (
        branch_result_state_block.group(0)
    )
    assert "blaiU32ArrayIndexCursor(splitIndex, splitValues.len)" not in (
        branch_result_state_block.group(0)
    )
    branch_scalar_apply_block = re.search(
        r"proc blaiApplyToolchainSetWeiPatchBranchScalarState\*\(.*?"
        r"proc blaiApplyToolchainSetWeiPatchBranch\*\(",
        npu_source,
        re.S,
    )
    assert branch_scalar_apply_block is not None
    assert "blaiApplyToolchainSetWeiPatchBranchScalarState(" in (
        branch_scalar_apply_block.group(0)
    )
    assert "blaiApplyToolchainSetWeiPatchBranchSummaryScalarState(" in (
        branch_scalar_apply_block.group(0)
    )
    assert "plan.summaryStateAfter" in branch_scalar_apply_block.group(0)
    assert "mode = plan.stateAfter.mode" not in branch_scalar_apply_block.group(0)
    assert "patchCount = plan.stateAfter.patchCount" not in (
        branch_scalar_apply_block.group(0)
    )
    assert "splitCount = plan.stateAfter.splitCount" not in (
        branch_scalar_apply_block.group(0)
    )
    assert "psramPatchTotal = plan.stateAfter.psramPatchTotal" not in (
        branch_scalar_apply_block.group(0)
    )
    assert "flagValue = plan.stateAfter.flagValue" not in (
        branch_scalar_apply_block.group(0)
    )
    assert "returnedPatchCount = plan.stateAfter.returnedPatchCount" not in (
        branch_scalar_apply_block.group(0)
    )
    assert "proc blaiToolchainSetWeiPatchBranchReturnPlanInto*" in npu_source
    assert "BlaiToolchainSetWeiPatchBranchReturnEvidence* = object" in npu_source
    assert "evidence*: BlaiToolchainSetWeiPatchBranchReturnEvidence" in npu_source
    assert "proc blaiToolchainSetWeiPatchBranchReturnEvidence*" in npu_source
    assert "proc blaiToolchainSetWeiPatchBranchReturnPlan*" in npu_source
    branch_return_evidence_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchReturnEvidence\*\(.*?"
        r"proc blaiToolchainSetWeiPatchBranchReturnPlanInto\*",
        npu_source,
        re.S,
    )
    assert branch_return_evidence_block is not None
    assert "result.callValid = call.valid" in branch_return_evidence_block.group(0)
    assert "result.branchValid = branch.valid" in (
        branch_return_evidence_block.group(0)
    )
    assert "result.returnedPatchCountValid = returnedCount.valid" in (
        branch_return_evidence_block.group(0)
    )
    assert "result.returnPlanValid = result.returnPlan.valid" in (
        branch_return_evidence_block.group(0)
    )
    assert "if not branch.valid:" in branch_return_evidence_block.group(0)
    assert "let returnedCount = blaiToolchainPatchCountAbi(" in (
        branch_return_evidence_block.group(0)
    )
    assert "blaiToolchainSetWeiPatchReturnPlan(" in (
        branch_return_evidence_block.group(0)
    )
    assert "result.byRefPatchCountAfter = returnedCount.value" in (
        branch_return_evidence_block.group(0)
    )
    assert "result.scratchPatchCount = returnedCount.value" in (
        branch_return_evidence_block.group(0)
    )
    branch_return_block = re.search(
        r"proc blaiToolchainSetWeiPatchBranchReturnPlanInto\*\(.*?"
        r"proc blaiToolchainSetWeiPatchBranchReturnPlan\*",
        npu_source,
        re.S,
    )
    assert branch_return_block is not None
    assert "let evidence = blaiToolchainSetWeiPatchBranchReturnEvidence(" in (
        branch_return_block.group(0)
    )
    assert "outResult.evidence = evidence" in branch_return_block.group(0)
    assert "if not call.valid:" not in branch_return_block.group(0)
    assert "if not branch.valid:" not in branch_return_block.group(0)
    assert "let returnedCount = blaiToolchainPatchCountAbi(" not in (
        branch_return_block.group(0)
    )
    assert "branch.returnedPatchCount.int32" not in branch_return_block.group(0)
    assert "outResult.scratchPatchCount = branch.returnedPatchCount" not in (
        branch_return_block.group(0)
    )
    assert (
        "let patchSegment =\n"
        "          blaiMemAllocPatchSegmentCursor(patchIndex, patchCount)"
        in npu_source
    )
    assert "BlaiMemAllocLinePatchProbe* = object" in npu_source
    assert "BlaiMemAllocLinePatchApplyPlan* = object" in npu_source
    assert "BlaiMemAllocLinePatchApplyEvidence* = object" in npu_source
    assert "BlaiMemAllocLinePatchState* = object" in npu_source
    assert "BlaiMemAllocLinePatchSelectionEvidence* = object" in npu_source
    assert "BlaiMemAllocLinePatchUpsampleScale* = 2'u32" in npu_source
    assert "BlaiMemAllocRouteKernelDilationThreshold* = 1'u32" in npu_source
    assert "BlaiMemAllocRouteKernelSmallSizeLimit* = 3'u32" in npu_source
    assert "BlaiMemAllocRouteKernelNoPadding* = 0'u32" in npu_source
    assert "BlaiMemAllocRouteKernelSmallPadding* = 2'u32" in npu_source
    assert "BlaiMemAllocRouteKernelExpandedPadding* = 6'u32" in npu_source
    assert "proc blaiMemAllocRouteKernelPadding*(" in npu_source
    assert "proc blaiMemAllocLinePatchProbe*(" in npu_source
    assert "proc blaiMemAllocLinePatchSelectionEvidence*(" in npu_source
    assert "proc blaiMemAllocLinePatchApplyEvidence*(" in npu_source
    assert "proc blaiMemAllocLinePatchApplyPlan*(" in npu_source
    assert "proc blaiMemAllocLinePatchState*(" in npu_source
    assert "proc blaiApplyLinePatchMemAllocState*" in npu_source
    assert "proc blaiApplyLinePatchMemAllocScalarState*" in npu_source
    assert "proc blaiApplyLinePatchMemAllocScalars*" in npu_source
    assert (
        "let probe = blaiMemAllocLinePatchProbe(\n"
        "      layer, patchCount, routeChannels, routed, upsampleLayer)"
        in npu_source
    )
    line_patch_selection_block = re.search(
        r"proc blaiMemAllocLinePatchSelectionEvidence\*\(.*?"
        r"proc blaiPlanLinePatchMemAllocInto\*",
        npu_source,
        re.S,
    )
    assert line_patch_selection_block is not None
    assert "if probe.fits:" in line_patch_selection_block.group(0)
    assert "result.inputLineBytes = probe.inputLineBytes" in (
        line_patch_selection_block.group(0)
    )
    assert "result.outputLineBytes = probe.outputLineBytes" in (
        line_patch_selection_block.group(0)
    )
    assert "remaining = blaiSaturatingSubU32(remaining, probe.inputLine)" in npu_source
    assert "result.linePatchW[patchSegment.patchSlot] = patchWidth" in (
        line_patch_selection_block.group(0)
    )
    assert "result.inputLine * BlaiMemAllocLinePatchUpsampleScale" in npu_source
    assert "result.routeKernelPadding = blaiMemAllocRouteKernelPadding(" in (
        npu_source
    )
    assert "BlaiMemAllocRouteKernelExpandedPadding" in npu_source
    assert "BlaiMemAllocRouteKernelSmallPadding" in npu_source
    line_patch_block = re.search(
        r"proc blaiPlanLinePatchMemAllocInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert line_patch_block is not None
    assert "routeKernelPadding =" not in line_patch_block.group(0)
    assert "outputLineBase =" not in line_patch_block.group(0)
    assert "let selection = blaiMemAllocLinePatchSelectionEvidence(" in (
        line_patch_block.group(0)
    )
    assert "outResult.linePatchW = selection.linePatchW" in (
        line_patch_block.group(0)
    )
    assert "let probe = blaiMemAllocLinePatchProbe(" not in line_patch_block.group(0)
    assert "outResult.linePatchW[patchSegment.patchSlot] = patchWidth" not in (
        line_patch_block.group(0)
    )
    line_patch_apply_evidence_block = re.search(
        r"proc blaiMemAllocLinePatchApplyEvidence\*\(.*?"
        r"proc blaiMemAllocLinePatchApplyPlan\*",
        npu_source,
        re.S,
    )
    assert line_patch_apply_evidence_block is not None
    assert "if not plan.fits:" in line_patch_apply_evidence_block.group(0)
    assert "let linePatchCount = blaiAllocatorFieldAbi(plan.linePatchCount)" in (
        line_patch_apply_evidence_block.group(0)
    )
    assert "let patchCursor = blaiWeightPatchCursor(patchIndex)" in (
        line_patch_apply_evidence_block.group(0)
    )
    assert "let lineWidth = blaiAllocatorFieldAbi(plan.linePatchW[patchCursor.index])" in (
        line_patch_apply_evidence_block.group(0)
    )
    assert "result.linePatchW[patchCursor.index] = lineWidth.value" in (
        line_patch_apply_evidence_block.group(0)
    )
    line_patch_plan_block = re.search(
        r"proc blaiMemAllocLinePatchApplyPlan\*\(.*?"
        r"proc blaiMemAllocLinePatchState\*\(",
        npu_source,
        re.S,
    )
    assert line_patch_plan_block is not None
    assert "let evidence = blaiMemAllocLinePatchApplyEvidence(plan)" in (
        line_patch_plan_block.group(0)
    )
    assert "result.linePatchW = evidence.linePatchW" in line_patch_plan_block.group(0)
    assert "blaiAllocatorFieldAbi(plan.linePatchCount)" not in (
        line_patch_plan_block.group(0)
    )
    assert "plan.linePatchW[patchCursor.index]" not in line_patch_plan_block.group(0)
    line_patch_state_block = re.search(
        r"proc blaiApplyLinePatchMemAllocState\*\(.*?"
        r"proc blaiApplyLinePatchMemAllocScalarState\*\(",
        npu_source,
        re.S,
    )
    assert line_patch_state_block is not None
    assert "ctrl.linePatchCount = state.linePatchCount" in npu_source
    assert "for patchIndex in 0'u32 ..< BlaiMaxWeightPatchesU32:" in npu_source
    assert "let patchCursor = blaiWeightPatchCursor(patchIndex)" in (
        line_patch_state_block.group(0)
    )
    assert (
        "ctrl.linePatchW[patchCursor.index] =\n"
        "      state.linePatchW[patchCursor.index]"
    ) in npu_source
    assert "ctrl.linePatchW[i] = state.linePatchW[i]" not in npu_source
    line_patch_apply_block = re.search(
        r"proc blaiApplyLinePatchMemAlloc\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert line_patch_apply_block is not None
    assert "let applyPlan = blaiMemAllocLinePatchApplyPlan(plan)" in (
        line_patch_apply_block.group(0)
    )
    assert "blaiApplyLinePatchMemAllocState(" in (
        line_patch_apply_block.group(0)
    )
    assert "ctrl.linePatchCount = applyPlan.linePatchCount" not in (
        line_patch_apply_block.group(0)
    )
    assert "ctrl.linePatchW[i] = applyPlan.linePatchW[i]" not in (
        line_patch_apply_block.group(0)
    )
    line_patch_scalar_block = re.search(
        r"proc blaiApplyLinePatchMemAllocScalarState\*\(.*?"
        r"proc blaiApplyLinePatchMemAlloc\*\(",
        npu_source,
        re.S,
    )
    assert line_patch_scalar_block is not None
    assert "blaiApplyLinePatchMemAllocScalarState(" in (
        line_patch_scalar_block.group(0)
    )
    assert "linePatchCount = plan.linePatchCount" not in (
        line_patch_scalar_block.group(0)
    )
    assert (
        "let patchSegment = blaiMemAllocPatchSegmentCursor(patchIndex, weightPatchCount)"
        in npu_source
    )
    assert "BlaiMemAllocWeightPatchStoreEntry* = object" in npu_source
    assert "BlaiMemAllocPatchCountPlan* = object" in npu_source
    assert "BlaiMemAllocWeightPatchApplyPlan* = object" in npu_source
    assert "BlaiMemAllocWeightPatchApplyEvidence* = object" in npu_source
    assert "BlaiMemAllocWeightPatchState* = object" in npu_source
    assert "BlaiMemAllocPatchBranchPlan* = object" in npu_source
    assert "BlaiMemAllocPatchBranchEvidence* = object" in npu_source
    assert "BlaiMemAllocControlApplyPlan* = object" in npu_source
    assert "BlaiMemAllocControlApplyEvidence* = object" in npu_source
    assert "BlaiMemAllocControlState* = object" in npu_source
    assert "proc blaiMemAllocWeightPatchStoreEntry*(" in npu_source
    assert "proc blaiMemAllocPatchStoreSize*(" in npu_source
    assert "proc blaiMemAllocHighWeightBranchActive*" in npu_source
    assert "proc blaiMemAllocPsramPatchBranchActive*" in npu_source
    assert "proc blaiMemAllocOutputChannelPatchWidth*" in npu_source
    assert "proc blaiMemAllocMidPatchElements*(" in npu_source
    assert "proc blaiMemAllocPsramPatchCount*(" in npu_source
    assert "proc blaiMemAllocPsramMidPatchCount*(" in npu_source
    assert "proc blaiMemAllocPatchCountPlan*(" in npu_source
    assert "proc blaiMemAllocWeightPatchApplyEvidence*(" in npu_source
    assert "proc blaiMemAllocWeightPatchApplyPlan*(" in npu_source
    assert "proc blaiMemAllocWeightPatchState*(" in npu_source
    assert "proc blaiApplyHighWeightPatchMemAllocState*" in npu_source
    assert "proc blaiApplyWeightPatchMemAllocScalarState*" in npu_source
    assert "proc blaiApplyWeightPatchMemAllocScalars*" in npu_source
    assert "proc blaiMemAllocPatchBranchEvidence*(" in npu_source
    assert "proc blaiPlanPatchMemAllocBranchInto*(" in npu_source
    assert "proc blaiPlanPatchMemAllocBranch*(" in npu_source
    assert "proc blaiMemAllocControlApplyEvidence*(" in npu_source
    assert "proc blaiMemAllocControlApplyPlan*(" in npu_source
    assert "proc blaiMemAllocControlState*(" in npu_source
    assert "proc blaiApplyMemAllocControlState*" in npu_source
    assert "proc blaiApplyMemAllocControlBranchState*" in npu_source
    assert "proc blaiApplyMemAllocControlBranch*" in npu_source
    assert "proc blaiApplyMemAllocControlApplyPlan*(" in npu_source
    assert (
        "let patchStore = blaiMemAllocWeightPatchStoreEntry(\n"
        "      patchIndex, result.weightPatchCount, emittedChannels, outputChannels,"
        in npu_source
    )
    assert "result.weightPatchOutC[patchStore.patchSlot] = patchStore.patchOutC" in npu_source
    assert "emittedChannels = patchStore.nextEmittedChannels" in npu_source
    assert (
        "result.psramPatchSize = blaiMemAllocPatchStoreSize(\n"
        "    result.outputPatchBytes, result.fullPatchBytes,"
        in npu_source
    )
    assert (
        "result.midElements = blaiMemAllocMidPatchElements(\n"
        "      layerType, inputElements, outputChannels, routeChannels)"
        in npu_source
    )
    assert (
        "result.psramPatchCount = blaiMemAllocPsramPatchCount(\n"
        "    outputChannels, outputElements, psramPatchSize, weightPatchCount)"
        in npu_source
    )
    assert "result.convMaxMidPatchExtra = layerType == blaiConvMax" in npu_source
    weight_patch_apply_evidence_block = re.search(
        r"proc blaiMemAllocWeightPatchApplyEvidence\*\(.*?"
        r"proc blaiMemAllocWeightPatchApplyPlan\*",
        npu_source,
        re.S,
    )
    assert weight_patch_apply_evidence_block is not None
    assert "if not plan.fits or not plan.active:" in (
        weight_patch_apply_evidence_block.group(0)
    )
    assert "weightPatchCount = blaiAllocatorFieldAbi(plan.weightPatchCount)" in (
        weight_patch_apply_evidence_block.group(0)
    )
    assert "psramPatchSize = blaiAllocatorFieldAbi(plan.psramPatchSize)" in (
        weight_patch_apply_evidence_block.group(0)
    )
    assert "let patchCursor = blaiWeightPatchCursor(patchIndex)" in (
        weight_patch_apply_evidence_block.group(0)
    )
    assert "plan.weightPatchOutC[patchCursor.index]" in (
        weight_patch_apply_evidence_block.group(0)
    )
    assert "result.weightPatchOutC[patchCursor.index] = patchOutC.value" in (
        weight_patch_apply_evidence_block.group(0)
    )
    weight_patch_apply_plan_block = re.search(
        r"proc blaiMemAllocWeightPatchApplyPlan\*\(.*?"
        r"proc blaiMemAllocWeightPatchState\*\(",
        npu_source,
        re.S,
    )
    assert weight_patch_apply_plan_block is not None
    assert "let evidence = blaiMemAllocWeightPatchApplyEvidence(plan)" in (
        weight_patch_apply_plan_block.group(0)
    )
    assert "result.weightPatchOutC = evidence.weightPatchOutC" in (
        weight_patch_apply_plan_block.group(0)
    )
    assert "blaiAllocatorFieldAbi(plan.weightPatchCount)" not in (
        weight_patch_apply_plan_block.group(0)
    )
    assert "plan.weightPatchOutC[patchCursor.index]" not in (
        weight_patch_apply_plan_block.group(0)
    )
    weight_patch_scalar_block = re.search(
        r"proc blaiApplyWeightPatchMemAllocScalarState\*\(.*?"
        r"proc blaiApplyHighWeightPatchMemAlloc\*\(",
        npu_source,
        re.S,
    )
    assert weight_patch_scalar_block is not None
    assert "blaiApplyWeightPatchMemAllocScalarState(" in (
        weight_patch_scalar_block.group(0)
    )
    assert "weightPatchCount = plan.weightPatchCount" not in (
        weight_patch_scalar_block.group(0)
    )
    assert "psramPatchSize = plan.psramPatchSize" not in (
        weight_patch_scalar_block.group(0)
    )
    assert "psramPatchCount = plan.psramPatchCount" not in (
        weight_patch_scalar_block.group(0)
    )
    assert "psramMidPatchCount = plan.psramMidPatchCount" not in (
        weight_patch_scalar_block.group(0)
    )
    weight_patch_state_block = re.search(
        r"proc blaiApplyHighWeightPatchMemAllocState\*\(.*?"
        r"proc blaiApplyWeightPatchMemAllocScalarState\*\(",
        npu_source,
        re.S,
    )
    assert weight_patch_state_block is not None
    assert "let patchCursor = blaiWeightPatchCursor(patchIndex)" in (
        weight_patch_state_block.group(0)
    )
    assert (
        "ctrl.weightPatchOutC[patchCursor.index] =\n"
        "      state.weightPatchOutC[patchCursor.index]"
    ) in npu_source
    assert "ctrl.weightPatchOutC[i] = state.weightPatchOutC[i]" not in npu_source
    assert (
        "result.psramMidPatchCount = blaiMemAllocPsramMidPatchCount(\n"
        "      result.midElements, psramPatchSize, weightPatchCount,"
        in npu_source
    )
    assert "let countPlan = blaiMemAllocPatchCountPlan(" in npu_source
    assert "result.psramPatchCount = countPlan.psramPatchCount" in npu_source
    assert "result.psramMidPatchCount = countPlan.psramMidPatchCount" in npu_source
    patch_branch_evidence_block = re.search(
        r"proc blaiMemAllocPatchBranchEvidence\*\(.*?"
        r"proc blaiPlanPatchMemAllocBranchInto\*",
        npu_source,
        re.S,
    )
    assert patch_branch_evidence_block is not None
    assert "blaiPlanHighWeightPatchMemAllocInto(layer, linePlan, patchPlan)" in (
        patch_branch_evidence_block.group(0)
    )
    assert "result.branch = blaiMemAllocHighWeightPatch" in (
        patch_branch_evidence_block.group(0)
    )
    assert "blaiPlanPsramPatchMemAllocInto(layer, linePlan, patchPlan)" in (
        patch_branch_evidence_block.group(0)
    )
    assert "result.branch = blaiMemAllocPsramPatch" in (
        patch_branch_evidence_block.group(0)
    )
    patch_branch_block = re.search(
        r"proc blaiPlanPatchMemAllocBranchInto\*\(.*?"
        r"proc blaiPlanPatchMemAllocBranch\*",
        npu_source,
        re.S,
    )
    assert patch_branch_block is not None
    assert "let evidence = blaiMemAllocPatchBranchEvidence(layer, linePlan)" in (
        patch_branch_block.group(0)
    )
    assert "outResult.branch = evidence.branch" in patch_branch_block.group(0)
    assert "outResult.patch = evidence.patch" in patch_branch_block.group(0)
    assert "outResult.valid = evidence.valid" in patch_branch_block.group(0)
    assert "blaiPlanHighWeightPatchMemAllocInto(layer, linePlan, patchPlan)" not in (
        patch_branch_block.group(0)
    )
    assert "blaiPlanPsramPatchMemAllocInto(layer, linePlan, patchPlan)" not in (
        patch_branch_block.group(0)
    )
    control_branch_block = re.search(
        r"proc blaiApplyMemAllocControlBranchState\*\(.*?"
        r"proc blaiApplyMemAllocControlApplyPlan\*\(",
        npu_source,
        re.S,
    )
    assert control_branch_block is not None
    assert "blaiApplyMemAllocControlBranchState(" in (
        control_branch_block.group(0)
    )
    assert "branch = applyPlan.branch" not in control_branch_block.group(0)
    assert "branch = state.branch" in control_branch_block.group(0)
    assert "not blaiMemAllocHighWeightBranchActive(outResult.estimatedWeightBytes)" in (
        npu_source
    )
    assert "not blaiMemAllocPsramPatchBranchActive(" in npu_source
    assert (
        "result.outputChannelPatch =\n"
        "    blaiMemAllocOutputChannelPatchWidth(outputChannels, initialPatches)"
        in npu_source
    )
    weight_patch_apply_block = re.search(
        r"proc blaiApplyHighWeightPatchMemAlloc\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert weight_patch_apply_block is not None
    assert "let applyPlan = blaiMemAllocWeightPatchApplyPlan(plan)" in (
        weight_patch_apply_block.group(0)
    )
    assert "blaiApplyHighWeightPatchMemAllocState(" in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchCount = applyPlan.weightPatchCount" not in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchOutC[i] = applyPlan.weightPatchOutC[i]" not in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = applyPlan.psramPatchSize" not in (
        weight_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.weightPatchCount)" not in (
        weight_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.weightPatchOutC[i])" not in (
        weight_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.psramPatchSize)" not in (
        weight_patch_apply_block.group(0)
    )
    mem_alloc_block = re.search(
        r"proc blaiPlanMemAllocInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert mem_alloc_block is not None
    assert "let patchBranch = blaiPlanPatchMemAllocBranch(layer, outResult.line)" in (
        mem_alloc_block.group(0)
    )
    assert "outResult.branch = patchBranch.branch" in mem_alloc_block.group(0)
    assert "outResult.patch = patchBranch.patch" in mem_alloc_block.group(0)
    assert "blaiPlanHighWeightPatchMemAllocInto(layer, outResult.line, outResult.patch)" not in (
        mem_alloc_block.group(0)
    )
    assert "blaiPlanPsramPatchMemAllocInto(layer, outResult.line, outResult.patch)" not in (
        mem_alloc_block.group(0)
    )
    assert "outResult.branch = blaiMemAllocHighWeightPatch" not in mem_alloc_block.group(0)
    assert "outResult.branch = blaiMemAllocPsramPatch" not in mem_alloc_block.group(0)
    control_apply_evidence_block = re.search(
        r"proc blaiMemAllocControlApplyEvidence\*\(.*?"
        r"proc blaiMemAllocControlApplyPlan\*",
        npu_source,
        re.S,
    )
    assert control_apply_evidence_block is not None
    assert "if not plan.fits:" in control_apply_evidence_block.group(0)
    assert "result.single = blaiMemAllocSinglePatchApplyPlan(plan.single)" in (
        control_apply_evidence_block.group(0)
    )
    assert "result.line = blaiMemAllocLinePatchApplyPlan(plan.line)" in (
        control_apply_evidence_block.group(0)
    )
    assert "result.patch = blaiMemAllocWeightPatchApplyPlan(plan.patch)" in (
        control_apply_evidence_block.group(0)
    )
    assert "result.valid = result.line.valid and result.patch.valid" in (
        control_apply_evidence_block.group(0)
    )
    control_apply_plan_projection_block = re.search(
        r"proc blaiMemAllocControlApplyPlan\*\(.*?"
        r"proc blaiMemAllocControlState\*\(",
        npu_source,
        re.S,
    )
    assert control_apply_plan_projection_block is not None
    assert "let evidence = blaiMemAllocControlApplyEvidence(plan)" in (
        control_apply_plan_projection_block.group(0)
    )
    assert "result.line = evidence.line" in (
        control_apply_plan_projection_block.group(0)
    )
    assert "result.patch = evidence.patch" in (
        control_apply_plan_projection_block.group(0)
    )
    assert "blaiMemAllocSinglePatchApplyPlan(plan.single)" not in (
        control_apply_plan_projection_block.group(0)
    )
    assert "blaiMemAllocLinePatchApplyPlan(plan.line)" not in (
        control_apply_plan_projection_block.group(0)
    )
    assert "blaiMemAllocWeightPatchApplyPlan(plan.patch)" not in (
        control_apply_plan_projection_block.group(0)
    )
    control_apply_plan_block = re.search(
        r"proc blaiApplyMemAllocControlApplyPlan\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert control_apply_plan_block is not None
    assert "blaiApplyMemAllocControlState(" in control_apply_plan_block.group(0)
    assert "ctrl.weightPatchCount = applyPlan.single.weightPatchCount" not in (
        control_apply_plan_block.group(0)
    )
    assert "ctrl.linePatchCount = applyPlan.line.linePatchCount" not in (
        control_apply_plan_block.group(0)
    )
    assert "ctrl.weightPatchCount = applyPlan.patch.weightPatchCount" not in (
        control_apply_plan_block.group(0)
    )
    composed_apply_block = re.search(
        r"proc blaiApplyMemAllocPlan\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert composed_apply_block is not None
    assert "let applyPlan = blaiMemAllocControlApplyPlan(plan)" in (
        composed_apply_block.group(0)
    )
    assert "blaiApplyMemAllocControlApplyPlan(ctrl, applyPlan)" in (
        composed_apply_block.group(0)
    )
    assert "blaiApplySinglePatchMemAlloc(ctrl, plan.single)" not in (
        composed_apply_block.group(0)
    )
    assert "blaiApplyLinePatchMemAlloc(ctrl, plan.line)" not in (
        composed_apply_block.group(0)
    )
    assert "blaiApplyHighWeightPatchMemAlloc(ctrl, plan.patch)" not in (
        composed_apply_block.group(0)
    )
    fill_patch_block = re.search(
        r"proc blaiFillPatchStores\(.*?proc ",
        npu_source,
        re.S,
    )
    assert fill_patch_block is not None
    assert "patchOutC =" not in fill_patch_block.group(0)
    assert "outputPatchBytes =" not in fill_patch_block.group(0)
    assert "midChannelBytes =" not in fill_patch_block.group(0)
    assert "midElements =" not in fill_patch_block.group(0)
    assert (
        "(outputChannels * outputElements) div result.psramPatchSize"
        not in fill_patch_block.group(0)
    )
    assert "BlaiMemAllocSinglePatchShape* = object" in npu_source
    assert "BlaiMemAllocSinglePatchMidPlan* = object" in npu_source
    assert "BlaiMemAllocSinglePatchApplyPlan* = object" in npu_source
    assert "BlaiMemAllocSinglePatchState* = object" in npu_source
    assert "BlaiMemAllocSinglePatchWeightPatchCount* = 1'u32" in npu_source
    assert "BlaiMemAllocSinglePatchPsramPatchCount* = 1'u32" in npu_source
    assert "proc blaiMemAllocSinglePatchMidPlan*(" in npu_source
    assert "proc blaiMemAllocSinglePatchShape*(" in npu_source
    assert "proc blaiMemAllocSinglePatchApplyPlan*(" in npu_source
    assert "proc blaiMemAllocSinglePatchState*(" in npu_source
    assert "proc blaiApplySinglePatchMemAllocState*" in npu_source
    assert "proc blaiApplySinglePatchMemAllocScalarState*" in npu_source
    assert "proc blaiApplySinglePatchMemAllocScalars*" in npu_source
    assert "let shape = blaiMemAllocSinglePatchShape(layer)" in npu_source
    assert (
        "outResult.weightPatchCount = BlaiMemAllocSinglePatchWeightPatchCount"
        in npu_source
    )
    assert (
        "outResult.psramPatchCount = BlaiMemAllocSinglePatchPsramPatchCount"
        in npu_source
    )
    assert "outResult.psramPatchSize = shape.psramPatchSize" in npu_source
    assert "outResult.midSource = shape.midSource" in npu_source
    assert "let midPlan = blaiMemAllocSinglePatchMidPlan(" in npu_source
    assert "result.midSource = midPlan.source" in npu_source
    assert "result.midInputElements = midPlan.inputElements" in npu_source
    assert "result.psramMidPatchCount = midPlan.psramMidPatchCount" in npu_source
    assert "let applyPlan = blaiMemAllocSinglePatchApplyPlan(plan)" in npu_source
    assert "ctrl.weightPatchCount = state.weightPatchCount" in npu_source
    single_patch_state_block = re.search(
        r"proc blaiApplySinglePatchMemAllocState\*\(.*?"
        r"proc blaiApplySinglePatchMemAllocScalarState\*\(",
        npu_source,
        re.S,
    )
    assert single_patch_state_block is not None
    assert "let firstPatchCursor = blaiWeightPatchCursor(0'u32)" in (
        single_patch_state_block.group(0)
    )
    assert "ctrl.weightPatchOutC[firstPatchCursor.index] =" in (
        single_patch_state_block.group(0)
    )
    assert "ctrl.weightPatchOutC[0] = state.firstWeightPatchOutC" not in (
        single_patch_state_block.group(0)
    )
    single_patch_block = re.search(
        r"proc blaiPlanSinglePatchMemAllocInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert single_patch_block is not None
    assert "blaiChannelAlign4" not in single_patch_block.group(0)
    assert "w * h * outC" not in single_patch_block.group(0)
    assert "w * h * c" not in single_patch_block.group(0)
    single_patch_apply_block = re.search(
        r"proc blaiApplySinglePatchMemAlloc\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert single_patch_apply_block is not None
    assert "blaiApplySinglePatchMemAllocState(" in (
        single_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchCount = applyPlan.weightPatchCount" not in (
        single_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchOutC[0] = applyPlan.firstWeightPatchOutC" not in (
        single_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.weightPatchCount)" not in (
        single_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.firstWeightPatchOutC)" not in (
        single_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.psramPatchSize)" not in (
        single_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.psramPatchCount)" not in (
        single_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.psramMidPatchCount)" not in (
        single_patch_apply_block.group(0)
    )
    single_patch_scalar_block = re.search(
        r"proc blaiApplySinglePatchMemAllocScalarState\*\(.*?"
        r"proc blaiApplySinglePatchMemAlloc\*\(",
        npu_source,
        re.S,
    )
    assert single_patch_scalar_block is not None
    assert "blaiApplySinglePatchMemAllocScalarState(" in (
        single_patch_scalar_block.group(0)
    )
    assert "weightPatchCount = plan.weightPatchCount" not in (
        single_patch_scalar_block.group(0)
    )
    assert "firstWeightPatchOutC = plan.firstWeightPatchOutC" not in (
        single_patch_scalar_block.group(0)
    )
    assert "psramPatchSize = plan.psramPatchSize" not in (
        single_patch_scalar_block.group(0)
    )
    assert "psramPatchCount = plan.psramPatchCount" not in (
        single_patch_scalar_block.group(0)
    )
    assert "psramMidPatchCount = plan.psramMidPatchCount" not in (
        single_patch_scalar_block.group(0)
    )
    assert "i + 1'u32 == patchCount" not in npu_source
    assert "patchIndex + 1'u32 == result.weightPatchCount" not in npu_source
    assert "BlaiMemAllocWeightPressureMode* = enum" in npu_source
    assert "BlaiMemAllocWeightPatchPressure* = object" in npu_source
    assert "BlaiMemAllocPsramPatchPressure* = object" in npu_source
    assert "BlaiMemAllocWeightPressureOneByOneKernelSize* = 1'u32" in npu_source
    assert "BlaiMemAllocWeightPressureOneByOneGroupFactor* = 8'u32" in npu_source
    assert "BlaiMemAllocWeightPressureDilationThreshold* = 1'u32" in npu_source
    assert "BlaiMemAllocWeightPressureSmallKernelLimit* = 3'u32" in npu_source
    assert "BlaiMemAllocWeightPressureLargeSpatialFactor* = 9'u32" in npu_source
    assert "proc blaiMemAllocWeightPatchPressure*(" in npu_source
    assert "proc blaiMemAllocLineFloorBytes*" in npu_source
    assert "proc blaiMemAllocPsramPatchPressure*(" in npu_source
    assert "result.mode = blaiWeightPressureOneByOne" in npu_source
    assert "result.mode = blaiWeightPressureDilatedOrLarge" in npu_source
    assert "result.mode = blaiWeightPressureSmallKernel" in npu_source
    assert "result.size == BlaiMemAllocWeightPressureOneByOneKernelSize" in (
        npu_source
    )
    assert "BlaiMemAllocWeightPressureOneByOneGroupFactor" in npu_source
    assert "result.dilation > BlaiMemAllocWeightPressureDilationThreshold" in (
        npu_source
    )
    assert "result.size > BlaiMemAllocWeightPressureSmallKernelLimit" in (
        npu_source
    )
    assert "BlaiMemAllocWeightPressureLargeSpatialFactor" in npu_source
    assert (
        "result.baseBytes = blaiMemAllocLineFloorBytes(\n"
        "    result.outputWidth, result.linePatchCount, result.outputChannels)"
        in npu_source
    )
    assert (
        "result.convMaxFloorBytes = blaiMemAllocLineFloorBytes(\n"
        "      result.inputWidth, result.linePatchCount, result.outputWidth)"
        in npu_source
    )
    estimate_weight_block = re.search(
        r"proc blaiEstimateWeightPatchBytes\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert estimate_weight_block is not None
    assert "blaiMemAllocWeightPatchPressure(layer).bytes" in (
        estimate_weight_block.group(0)
    )
    assert "channelProduct div (groups * 8'u32)" not in (
        estimate_weight_block.group(0)
    )
    estimate_psram_block = re.search(
        r"proc blaiEstimatePsramPatchBytes\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert estimate_psram_block is not None
    assert "blaiMemAllocPsramPatchPressure(layer, linePlan).bytes" in (
        estimate_psram_block.group(0)
    )
    assert "nonNegativeU32(layer.w) div linePatchCount" not in (
        estimate_psram_block.group(0)
    )
    assert "BlaiMemAllocRouteInputPosition* = object" in npu_source
    assert "proc blaiMemAllocRouteInputPosition*(" in npu_source
    assert "BlaiMemAllocRouteInputCursor* = object" in npu_source
    assert "proc blaiMemAllocRouteInputCursor*(" in npu_source
    assert "let routeInput = blaiMemAllocRouteInputCursor(i)" in npu_source
    assert "layer.cn[routeInput.cnIndex]" in npu_source
    route_input_cursor_block = re.search(
        r"proc blaiMemAllocRouteInputCursor\*\(.*?"
        r"proc blaiMemAllocRouteChannels",
        npu_source,
        re.S,
    )
    assert route_input_cursor_block is not None
    assert "let position = blaiMemAllocRouteInputPosition(extraInputIndex)" in (
        route_input_cursor_block.group(0)
    )
    assert "blaiLayerCnCursor(position.logicalInput)" in (
        route_input_cursor_block.group(0)
    )
    assert "extraInputIndex + 1'u32" not in route_input_cursor_block.group(0)
    assert "blaiLayerCn(layer, i + 1'u32)" not in npu_source
    assert "BlaiMemAllocStartPatchPressure* = object" in npu_source
    assert "proc blaiMemAllocStartPatchPressure*(" in npu_source
    assert "let pressure = blaiMemAllocStartPatchPressure(layer)" in npu_source
    assert "outResult.inputBytes = pressure.inputBytes" in npu_source
    assert "outResult.startPatchCount = pressure.startPatchCount" in npu_source
    start_patch_block = re.search(
        r"proc blaiPlanMemAllocStartPatchInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert start_patch_block is not None
    assert "outResult.inputWidth * outResult.routeChannels" not in (
        start_patch_block.group(0)
    )
    assert "outResult.outputWidth * outResult.outputChannels" not in (
        start_patch_block.group(0)
    )
    assert "BlaiFetchPatchBudgetPlan* = object" in npu_source
    assert "BlaiFetchPatchGrowDecision* = object" in npu_source
    assert "BlaiFetchPatchGrowEvidence* = object" in npu_source
    assert "BlaiFetchInputSlotsPlan* = object" in npu_source
    assert "BlaiFetchSlotLayoutEvidence* = object" in npu_source
    assert "proc blaiFetchPatchBudgetPlan*(" in npu_source
    assert "proc blaiFetchPatchGrowDecision*(" in npu_source
    assert "proc blaiFetchPatchGrowEvidence*(" in npu_source
    assert "proc blaiFetchInputSlotsPlan*(" in npu_source
    assert "proc blaiFetchSlotLayoutEvidence*(" in npu_source
    fetch_grow_evidence_block = re.search(
        r"proc blaiFetchPatchGrowEvidence\*\(.*?"
        r"proc blaiFetchOutputSlotPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_grow_evidence_block is not None
    assert "let inputPatch = blaiFetchInputPatchCursor(" in (
        fetch_grow_evidence_block.group(0)
    )
    assert "result.inputPatchCount[inputPatch.slotIndex] = inputPatch.patchCount" in (
        fetch_grow_evidence_block.group(0)
    )
    assert "let budgetPlan = blaiFetchPatchBudgetPlan(" in (
        fetch_grow_evidence_block.group(0)
    )
    assert "result.patchBudget = budgetPlan.budget" in (
        fetch_grow_evidence_block.group(0)
    )
    assert "let growDecision = blaiFetchPatchGrowDecision(" in (
        fetch_grow_evidence_block.group(0)
    )
    assert "result.growAttempts = growDecision.growAttempts" in (
        fetch_grow_evidence_block.group(0)
    )
    fetch_plan_block = re.search(
        r"proc blaiPlanFetchMemoryInto\*\(.*?"
        r"proc blaiPlanFetchMemory\*",
        npu_source,
        re.S,
    )
    assert fetch_plan_block is not None
    assert "let growEvidence = blaiFetchPatchGrowEvidence(" in (
        fetch_plan_block.group(0)
    )
    assert "outResult.inputPatchCount = growEvidence.inputPatchCount" in (
        fetch_plan_block.group(0)
    )
    assert "outResult.patchBudget = growEvidence.patchBudget" in (
        fetch_plan_block.group(0)
    )
    assert "outResult.growAttempts = growEvidence.growAttempts" in (
        fetch_plan_block.group(0)
    )
    assert "if growEvidence.fits:" in fetch_plan_block.group(0)
    assert "outResult.patchSize = growEvidence.nextPatchSize" in (
        fetch_plan_block.group(0)
    )
    assert "let budgetPlan = blaiFetchPatchBudgetPlan(" not in (
        fetch_plan_block.group(0)
    )
    assert "let growDecision = blaiFetchPatchGrowDecision(" not in (
        fetch_plan_block.group(0)
    )
    fetch_slot_layout_block = re.search(
        r"proc blaiFetchSlotLayoutEvidence\*\(.*?"
        r"proc blaiPlanFetchMemoryInto\*",
        npu_source,
        re.S,
    )
    assert fetch_slot_layout_block is not None
    assert "let inputSlots = blaiFetchInputSlotsPlan(inputCount, inputPatchCount)" in (
        fetch_slot_layout_block.group(0)
    )
    assert "result.inputSlots = inputSlots.inputSlots" in (
        fetch_slot_layout_block.group(0)
    )
    assert "let outputSlots = blaiFetchOutputSlotPlan(" in (
        fetch_slot_layout_block.group(0)
    )
    assert "inputSlots.nextSlot, psramMidPatchCount, psramPatchCount" in (
        fetch_slot_layout_block.group(0)
    )
    assert "result.dramPatchCount = outputSlots.dramPatchCount" in (
        fetch_slot_layout_block.group(0)
    )
    assert "let slotLayout = blaiFetchSlotLayoutEvidence(" in (
        fetch_plan_block.group(0)
    )
    assert "outResult.inputSlots = slotLayout.inputSlots" in (
        fetch_plan_block.group(0)
    )
    assert "outResult.dramPatchCount = slotLayout.dramPatchCount" in (
        fetch_plan_block.group(0)
    )
    assert "let inputSlots = blaiFetchInputSlotsPlan(" not in (
        fetch_plan_block.group(0)
    )
    assert "let outputSlots = blaiFetchOutputSlotPlan(" not in (
        fetch_plan_block.group(0)
    )
    assert "totalInputPatches <= budgetPlan.budget" not in npu_source
    assert "outResult.patchSize = outResult.patchSize * 2'u32" not in npu_source
    assert "outResult.inputCount - 1'u32" not in npu_source
    assert "rloop * nonNegativeU32(ctrl.psramPatchCount)" not in npu_source
    assert "let inputCursor = blaiReferenceRouteInputCursor(inputIndex)" in npu_source
    assert "result.inputs[inputCursor.index] = blaiReferenceRouteInput" in npu_source
    assert "result.inputs[inputCursor.index] = blaiReferenceTfliteRouteInput" in npu_source
    assert "let inputPlan = plan.inputs[inputCursor.index]" in npu_source
    assert "let currentInputCursor = blaiReferenceRouteInputCursor(currentInputIndex)" in npu_source
    assert "let inputPlan = plan.inputs[currentInputCursor.index]" in npu_source
    assert "let inputCursor = blaiForwardInputCursor(inputIndex)" in npu_source
    assert "let inputCursor = blaiForwardInputCursor(inputIndex.uint32)" in npu_source
    assert "outResult.inputSlot = nonNegativeU32(layer.dramIn[inputCursor.index])" in npu_source
    assert "outResult.transfer = plan.inputs[inputCursor.index]" in npu_source
    assert "let layerInstructionCursor =" in npu_source
    assert "blaiInstructionStreamCursor(outResult.layerInstructionIndex, stream.len)" in npu_source
    assert "decodeBlaiLayer(stream[layerInstructionCursor.index]" in npu_source
    assert "layerInstructionCursor.valid" in npu_source
    assert "let startCursor = blaiInstructionStreamStartCursor(startCount, stream.len)" in npu_source
    assert "var cursor = startCursor.index" in npu_source
    assert "let trailingWorkspaceCursor =" in npu_source
    assert "proc blaiForwardWorkspaceSegmentByteWindow" in npu_source
    assert "let capacityWindow = blaiCheckedIntByteWindow(0'u32, bufferBytes)" in npu_source
    assert "proc blaiForwardWorkspaceSegmentWindowMatches*" in npu_source
    assert "if not blaiU32ExactIntCount(offset, start):" in npu_source
    assert "if not blaiU32ExactIntCount(bytes, count):" in npu_source
    assert "let modelWorkspaceSegmentWindow =" in npu_source
    assert (
        "blaiForwardWorkspaceSegmentByteWindow(\n"
        "      modelWorkspace.data, modelWorkspace.data.bytes, modelWorkspace.totalBytes)"
        in npu_source
    )
    assert (
        "blaiByteBufferCursor(modelWorkspace.totalBytes, modelWorkspaceBytes.len)"
        in npu_source
    )
    assert "modelWorkspaceBytes[trailingWorkspaceCursor.index]" in npu_source
    assert "let temporaryBiasCursor =" in npu_source
    assert (
        "blaiByteBufferCursor(temporaryWeightBias.biasOffset, temporaryWeightBiasBytes.len)"
        in npu_source
    )
    assert "temporaryWeightBiasBytes[temporaryBiasCursor.index]" in npu_source
    assert "let secondTemporaryBiasCursor =" in npu_source
    assert (
        "temporaryWeightBiasBytes[secondTemporaryBiasCursor.index]"
        in npu_source
    )
    assert "let streamStart = blaiCpuStreamStartCursor(weightCursor)" in npu_source
    assert "let streamStart = blaiCpuStreamStartCursor(biasCursor)" in npu_source
    assert "let streamStart = blaiCpuStreamStartCursor(result.weightStream.cursor)" in npu_source
    assert "let streamStart = blaiCpuStreamStartCursor(result.biasStream.cursor)" in npu_source
    assert "let weightStreamStart = blaiCpuStreamStartCursor(outResult.weightStream.cursor)" in npu_source
    assert "let biasStreamStart = blaiCpuStreamStartCursor(outResult.biasStream.cursor)" in npu_source
    assert "if not blaiU32ExactIntCount(cursor.byteOffset, result.startIndex):" in npu_source
    assert "streamStart.startIndex" in npu_source
    assert "weightStreamStart.startIndex" in npu_source
    assert "biasStreamStart.startIndex" in npu_source
    assert "proc blaiNpuWeightBufferCursor*(weightCursor: uint32" in npu_source
    assert "proc blaiNpuWeightSourceCursor*(sourceIndex: uint32" in npu_source
    assert "proc blaiNpuBiasBufferCursor*(biasCursor: uint32" in npu_source
    assert "proc blaiNpuBiasSourceCursor*(sourceIndex: uint32" in npu_source
    assert "proc blaiNpuTemporaryWeightCursor*(destIndex: uint32" in npu_source
    assert "let cursor = blaiNpuWeightBufferCursor(weightCursor, weightBuf.len)" in npu_source
    assert (
        "blaiNpuWeightSourceCursor(sourceProjection.index, weightsIn.len)"
        in npu_source
    )
    assert "let cursor = blaiNpuBiasBufferCursor(biasCursor, biasBuf.len)" in npu_source
    assert (
        "blaiNpuBiasSourceCursor(entryCursor.outChannel, biasesIn.len)"
        in npu_source
    )
    assert "let destCursor = blaiNpuTemporaryWeightCursor(destIndex, temporaryWeights.len)" in npu_source
    assert npu_source.count(
        "let layerCursor = blaiCpuStreamLayerCursor(index, layers.len)"
    ) >= 4
    assert "let layerCursor = blaiI32ArrayIndexCursor(index, layers.len)" not in npu_source
    assert "blaiCpuParsedLayerStorageCursor(result.storedLayerCount, layers.len)" in npu_source
    assert (
        "blaiCpuParsedExtraStorageCursor(\n"
        "              result.storedLayerCount, extraInputs.len)"
        in npu_source
    )
    assert (
        "blaiCpuParsedYoloStorageCursor(\n"
        "              result.storedLayerCount, yoloStorage.len)"
        in npu_source
    )
    assert (
        "blaiCpuParsedStateStorageCursor(\n"
        "            result.storedLayerCount, parsedLayers.len)"
        in npu_source
    )
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, layers.len)" not in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, extraInputs.len)" not in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, yoloStorage.len)" not in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, parsedLayers.len)" not in npu_source
    assert "proc blaiBoundedU32Count*(count: uint32, capacity: int): int" in npu_source
    assert "proc blaiForwardCacheRangeCount*(count: uint32): int" in npu_source
    assert "BlaiTensorRowLayout* = object" in npu_source
    assert "BlaiTensorRowIndex* = object" in npu_source
    assert "proc blaiTensorRowIndex*(row, stride, channel: int)" in npu_source
    assert "proc blaiTensorRowLayout*(plan: BlaiTensorTransferPlan)" in npu_source
    assert "let paddedIndex = blaiTensorRowIndex(row, padded, channel)" in npu_source
    assert "let compactIndex = blaiTensorRowIndex(row, actual, channel)" in npu_source
    assert "result.paddedIndex = row * padded + channel" not in npu_source
    assert "result.compactIndex = row * actual + channel" not in npu_source
    assert "BlaiHwcIndex* = object" in npu_source
    assert "BlaiRowMajorIndex* = object" in npu_source
    assert "proc blaiHwcIndex*(y, x, width, channel, channels: uint32)" in npu_source
    assert "proc blaiHwcIndexWithBase*(base: uint32, hwc: BlaiHwcIndex" in npu_source
    assert "proc blaiHwcStrideIndex*(y, x, width, channel, strideC: uint32)" in npu_source
    assert "proc blaiRowMajorIndex*(row, column, columns: uint32)" in npu_source
    assert "let inputHwc =\n          blaiHwcIndex(y, x, plan.width, localC, inputPlan.channels)" in npu_source
    assert "blaiHwcIndexWithBase(inputPlan.offset, inputHwc, inputIndex)" in npu_source
    assert "inputPlan.offset + y * plan.width * inputPlan.channels" not in npu_source
    assert "blaiHwcIndex(y, x - minusC, inputPlan.channels, outC, plan.outputC)" in npu_source
    assert "blaiHwcIndex(y - minusC, x, plan.outputW, outC, plan.outputC)" in npu_source
    assert "inputPlan.offset + y * inputPlan.channels * plan.outputC" not in npu_source
    assert "inputPlan.offset + (y - minusC) * plan.outputW * plan.outputC" not in npu_source
    assert npu_source.count(
        "let hwc = blaiHwcIndex(y, x, plan.width, channel, plan.channels)"
    ) >= 4
    assert "let inputHwc = blaiHwcIndex(y, x, plan.inputW, channel, plan.inputC)" in npu_source
    assert "blaiHwcIndex(outputY, outputX, result.outputW, channel, result.outputC)" in npu_source
    assert "let inputIndex = y * plan.inputW * plan.inputC + x * plan.inputC + channel" not in npu_source
    assert "let inputHwc = blaiHwcIndex(y, x, plan.width, localChannel, inputC)" in npu_source
    assert "let inputIndex = y * plan.width * inputC + x * inputC + localChannel" not in npu_source
    assert "blaiHwcStrideIndex(y, x, plan.width, channel, result.inputStrideC)" in npu_source
    assert "blaiHwcStrideIndex(y, x, plan.width, channel, result.outputStrideC)" in npu_source
    assert "let inputBase = y * plan.width * result.inputStrideC" not in npu_source
    assert "let outputBase = y * plan.width * result.outputStrideC" not in npu_source
    avgpool_block = re.search(
        r"proc blaiReferenceAvgPool2d\*\(.*?"
        r"proc blaiMeanInputStrideC\(",
        npu_source,
        re.S,
    )
    assert avgpool_block is not None
    assert (
        "blaiHwcStrideIndex(y, x, plan.inputW, channel, result.inputStrideC)"
        in avgpool_block.group(0)
    )
    assert (
        "blaiHwcStrideIndex(0'u32, 0'u32, 1'u32, channel, result.outputStrideC)"
        in avgpool_block.group(0)
    )
    assert "let index = y * plan.inputW * result.inputStrideC" not in (
        avgpool_block.group(0)
    )
    mean_block = re.search(
        r"proc blaiReferenceTfliteMean2d\*\(.*?"
        r"proc blaiSoftmaxInputStrideC\(",
        npu_source,
        re.S,
    )
    assert mean_block is not None
    assert (
        "blaiHwcStrideIndex(y, x, plan.inputW, channel, result.inputStrideC)"
        in mean_block.group(0)
    )
    assert (
        "blaiHwcStrideIndex(0'u32, 0'u32, 1'u32, channel, result.outputC)"
        in mean_block.group(0)
    )
    assert "let index = y * plan.inputW * result.inputStrideC" not in (
        mean_block.group(0)
    )
    assert "blaiHwcIndex(outY, outX, result.outputW, channel, result.outputC)" in npu_source
    assert "blaiHwcIndex(inputY.uint32, inputX.uint32, plan.inputW, channel" in npu_source
    assert "let outputBase = outY * result.outputW * result.outputC" not in npu_source
    assert "let inputBase = inputY.uint32 * plan.inputW * plan.inputC" not in npu_source
    fixed_conv_block = re.search(
        r"proc blaiReferenceConv2d\*\(.*?"
        r"proc blaiReferenceConvMaxSample\(",
        npu_source,
        re.S,
    )
    assert fixed_conv_block is not None
    assert (
        "blaiRowMajorIndex(outC, weightColumn, weightColumns)"
        in fixed_conv_block.group(0)
    )
    assert (
        "let weightIndex = outC * inputPerGroup * plan.kernelSize * plan.kernelSize"
        not in fixed_conv_block.group(0)
    )
    fixed_conv_max_block = re.search(
        r"proc blaiReferenceConvMaxValue\(.*?"
        r"proc blaiReferenceConvMax2d\*",
        npu_source,
        re.S,
    )
    assert fixed_conv_max_block is not None
    assert (
        "blaiRowMajorIndex(outC, weightColumn, weightColumns)"
        in fixed_conv_max_block.group(0)
    )
    assert (
        "let weightIndex = outC * inputPerGroup * plan.kernelSize * plan.kernelSize"
        not in fixed_conv_max_block.group(0)
    )
    matmul_block = re.search(
        r"proc blaiReferenceMatmul2d\*\(.*?"
        r"proc blaiRoundingDivideByPowerOfTwo\*",
        npu_source,
        re.S,
    )
    assert matmul_block is not None
    assert "blaiHwcIndex(y, 0'u32, 1'u32, inC, plan.inputC)" in (
        matmul_block.group(0)
    )
    assert "blaiHwcIndex(y, 0'u32, 1'u32, outC, plan.outputC)" in (
        matmul_block.group(0)
    )
    assert "blaiRowMajorIndex(outC, inC, plan.inputC)" in matmul_block.group(0)
    assert "let inputIndex = y * plan.inputC + inC" not in matmul_block.group(0)
    assert "let weightIndex = outC * plan.inputC + inC" not in (
        matmul_block.group(0)
    )
    assert "let outputIndex = y * plan.outputC + outC" not in (
        matmul_block.group(0)
    )
    assert "let inputHwc = blaiHwcIndex(hin, win, plan.inputW, cin, plan.inputC)" in npu_source
    assert "blaiHwcIndex(outH, outW, result.outputW, outC, result.outputC)" in npu_source
    assert "let inputIndex = hin * plan.inputW * plan.inputC + win * plan.inputC + cin" not in npu_source
    assert "let outputIndex = outH * result.outputW * result.outputC" not in npu_source
    depthwise_conv_block = re.search(
        r"proc blaiReferenceDepthwiseConv2d\*\(.*?"
        r"proc blaiReferenceTfliteConvReadinessInto\*",
        npu_source,
        re.S,
    )
    assert depthwise_conv_block is not None
    assert (
        "blaiHwcIndex(inputY.uint32, inputX.uint32, plan.inputW"
        in depthwise_conv_block.group(0)
    )
    assert (
        "blaiHwcIndex(outY, outX, result.outputW, outC, result.outputC)"
        in depthwise_conv_block.group(0)
    )
    assert (
        "let inputIndex = inputY.uint32 * plan.inputW * plan.inputC"
        not in depthwise_conv_block.group(0)
    )
    assert "blaiRowMajorIndex(ky, kx, plan.kernelW)" in (
        depthwise_conv_block.group(0)
    )
    assert (
        "blaiRowMajorIndex(kernelTap.index, outC, result.outputC)"
        in depthwise_conv_block.group(0)
    )
    assert (
        "let kernelIndex = (ky * plan.kernelW + kx) * result.outputC"
        not in depthwise_conv_block.group(0)
    )
    assert "var outputIndex = 0" not in depthwise_conv_block.group(0)
    tflite_nmsis_conv_block = re.search(
        r"proc blaiReferenceTfliteConv2d\*\(.*?"
        r"proc blaiReferenceTfliteScalarConvSupported\*",
        npu_source,
        re.S,
    )
    assert tflite_nmsis_conv_block is not None
    assert (
        "blaiHwcIndex(inputY.uint32, inputX.uint32, plan.inputW"
        in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "blaiHwcIndex(outY, outX, result.outputW, outC, result.outputC)"
        in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "let inputIndex = inputY.uint32 * plan.inputW * plan.inputC"
        not in tflite_nmsis_conv_block.group(0)
    )
    assert "blaiRowMajorIndex(ky, kx, plan.kernelW)" in (
        tflite_nmsis_conv_block.group(0)
    )
    assert (
        "blaiRowMajorIndex(kernelTap.index, inputC, plan.inputC)"
        in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "blaiRowMajorIndex(outC, kernelColumn.index, kernelColumns)"
        in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "let kernelIndex = outC * plan.inputC * plan.kernelH * plan.kernelW"
        not in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "(ky * plan.kernelW + kx) * plan.inputC + inputC"
        not in tflite_nmsis_conv_block.group(0)
    )
    assert (
        "let outputIndex = outC + (outY * result.outputW + outX) * plan.outputC"
        not in tflite_nmsis_conv_block.group(0)
    )
    tflite_scalar_conv_block = re.search(
        r"proc blaiReferenceTfliteScalarConv2d\*\(.*?"
        r"proc blaiReferenceTfliteScalarConvMaxSupported\*",
        npu_source,
        re.S,
    )
    assert tflite_scalar_conv_block is not None
    assert (
        "blaiHwcIndex(outY, outX, result.outputW, outC, result.outputC)"
        in tflite_scalar_conv_block.group(0)
    )
    assert (
        "blaiRowMajorIndex(outC, kernelColumn, kernelColumns)"
        in tflite_scalar_conv_block.group(0)
    )
    assert (
        "let outputIndex = outY * result.outputW * plan.outputC"
        not in tflite_scalar_conv_block.group(0)
    )
    assert (
        "let kernelIndex = outC * inputPerGroup * plan.kernelSize"
        not in tflite_scalar_conv_block.group(0)
    )
    tflite_scalar_conv_max_block = re.search(
        r"proc blaiReferenceTfliteScalarConvMaxValue\(.*?"
        r"proc blaiReferenceTfliteScalarConvMax2d\*",
        npu_source,
        re.S,
    )
    assert tflite_scalar_conv_max_block is not None
    assert (
        "blaiRowMajorIndex(outC, kernelColumn, kernelColumns)"
        in tflite_scalar_conv_max_block.group(0)
    )
    assert (
        "let kernelIndex = outC * inputPerGroup * plan.kernelSize"
        not in tflite_scalar_conv_max_block.group(0)
    )
    pre_transconv_block = re.search(
        r"proc blaiReferenceTflitePreTransconv2d\*\(.*?"
        r"proc blaiReferenceTfliteDequantizeReadinessInto\*",
        npu_source,
        re.S,
    )
    assert pre_transconv_block is not None
    assert "blaiHwcIndex(hin, win, plan.inputW, channel, plan.channels)" in (
        pre_transconv_block.group(0)
    )
    assert (
        "blaiHwcIndex(hin * 2'u32 + 1'u32, win * 2'u32 + 1'u32"
        in pre_transconv_block.group(0)
    )
    assert "blaiHwcIndex(padRow, x, plan.outputW, channel, plan.channels)" in (
        pre_transconv_block.group(0)
    )
    assert "let dataIndex = hin * plan.inputW * plan.channels" not in (
        pre_transconv_block.group(0)
    )
    assert "let padRowIndex = (hin * 2'u32) * plan.outputW * plan.channels" not in (
        pre_transconv_block.group(0)
    )
    tflite_reshape_block = re.search(
        r"proc blaiReferenceTfliteReshape2d\*\(.*?"
        r"proc blaiReferenceRouteConcatFits\*",
        npu_source,
        re.S,
    )
    assert tflite_reshape_block is not None
    assert (
        "blaiHwcStrideIndex(y, x, plan.width, cin, plan.inputStrideC)"
        in tflite_reshape_block.group(0)
    )
    assert (
        "blaiHwcStrideIndex(\n"
        "            outputGroup, 0'u32, 1'u32, outputChannel, plan.outputStrideC)"
    ) in tflite_reshape_block.group(0)
    assert "var outIndex = 0'u32" not in tflite_reshape_block.group(0)
    assert "let inputIndex = y * plan.width * plan.inputStrideC" not in (
        tflite_reshape_block.group(0)
    )
    assert "blaiHwcIndex(inputY.uint32, inputX.uint32, plan.inputW, channel" in npu_source
    assert "blaiHwcIndex(outY, outX, result.outputW, channel, result.outputC)" in npu_source
    assert (
        "let inputIndex = inputY.uint32 * plan.inputW * plan.inputC +\n"
        "              inputX.uint32 * plan.inputC + channel"
    ) not in npu_source
    assert "let outputIndex = channel + (outY * result.outputW + outX) * plan.inputC" not in npu_source
    assert "blaiHwcIndex(y.uint32, x.uint32, plan.inputW, channel, plan.inputC)" in npu_source
    assert "blaiHwcIndex(y.uint32, x.uint32, plan.inputW, c.uint32, plan.inputC)" in npu_source
    assert "blaiHwcIndex(outY, outX, result.outputW, outC, plan.outputC)" in npu_source
    assert "let index = (y.uint32 * plan.inputW * plan.inputC) + (x.uint32 * plan.inputC) + c.uint32" not in npu_source
    assert "let outputIndex = outY * result.outputW * plan.outputC + outX * plan.outputC + outC" not in npu_source
    assert "blaiHwcIndex(windowY div 2'u32, windowX div 2'u32" in npu_source
    assert "input[(y.uint32 * plan.inputW * plan.inputC" not in npu_source
    tflite_conv_max_sample = re.search(
        r"proc blaiReferenceTfliteScalarConvMaxSample\(.*?"
        r"proc blaiReferenceTfliteScalarConvMaxValue\(",
        npu_source,
        re.S,
    )
    assert tflite_conv_max_sample is not None
    assert (
        "blaiHwcIndex(y.uint32, x.uint32, plan.inputW, channel, plan.inputC)"
        in tflite_conv_max_sample.group(0)
    )
    assert (
        "let inputIndex = y.uint32 * plan.inputW * plan.inputC"
        not in tflite_conv_max_sample.group(0)
    )
    assert (
        "blaiHwcIndex(windowY div 2'u32, windowX div 2'u32,\n"
        "            result.outputW, outC, plan.outputC)"
    ) in npu_source
    assert (
        "let outputIndex = (windowY div 2'u32) * result.outputW * plan.outputC"
        not in npu_source
    )
    assert "output[outputIndex.int] = maxValue" not in npu_source
    assert "output[outputIndex.int] = clamped" not in npu_source
    assert "proc blaiU32ExactIntCount*(count: uint32" in npu_source
    assert "proc blaiU64ExactU32Count*(count: uint64" in npu_source
    assert "proc blaiU64ExactI32Count*(count: uint64" in npu_source
    assert "proc blaiU64SaturatedU32Count*(count: uint64" in npu_source
    assert "proc blaiU64MaxExactU32Count*(count: uint64" in npu_source
    assert "if not blaiU32ExactIntCount(offset, result.start):" in npu_source
    assert "if not blaiU32ExactIntCount(bytes, result.count):" in npu_source
    assert "if not blaiU32ExactIntCount(fit.requiredElements, result.elements):" in npu_source
    assert "outResult.startIndex = blaiU64SaturatedU32Count(start)" in npu_source
    assert "outResult.requiredBytes = blaiU64SaturatedU32Count(required)" in npu_source
    assert npu_source.count(
        "outResult.startIndex = blaiU64SaturatedU32Count(startIndex.uint64)"
    ) >= 2
    assert "proc blaiNpuKernelTapCountInto*(kernelSize: uint32" in npu_source
    assert "proc blaiNpuKernelTapCount*(kernelSize: uint32): uint32" in npu_source
    assert "blaiNpuKernelTapCount(nonNegativeU32(layer.size))" in npu_source
    assert "blaiNpuKernelTapCountInto(\n      nonNegativeU32(layer.size), outResult.kernelTaps)" in npu_source
    assert "let units = kernelSize.uint64 * kernelSize.uint64" not in npu_source
    assert "let taps = kernelSize.uint64 * kernelSize.uint64" not in npu_source
    assert "proc blaiNpuPackTileBytes*(pack: uint32, outBytes: var uint32): bool" in npu_source
    assert "let tileBytesFit = blaiNpuPackTileBytes(pack, outResult.tileBytes)" in npu_source
    assert (
        "proc blaiNpuPackedWeightGroupBytes*(\n"
        "    inputTileCount, tileUnits, tileBytes: uint32): uint64"
        in npu_source
    )
    assert (
        "blaiNpuPackedWeightGroupBytes(\n"
        "          inputTileCount, outResult.tileUnits, outResult.tileBytes)"
        in npu_source
    )
    assert "proc blaiNpuTemporaryWeightBytes*(elements: uint32" in npu_source
    assert "if not blaiNpuTemporaryWeightBytes(\n          outResult.temporaryWeightElements" in npu_source
    assert "outResult.temporaryWeightElements * BlaiNpuTemporaryWeightElementBytes" not in npu_source
    assert "9 * BlaiNpuTemporaryWeightElementBytes" not in npu_source
    assert "288 * BlaiNpuTemporaryWeightElementBytes" not in npu_source
    assert "pack.uint64 * pack.uint64, outBytes" in npu_source
    assert "let tileBytes = pack.uint64 * pack.uint64" not in npu_source
    assert "blaiU64ExactU32Count(tileBytes, outResult.tileBytes)" not in npu_source
    assert (
        "total += inputTileCount.uint64 * outResult.tileUnits.uint64 *"
        not in npu_source
    )
    assert "outResult.totalBytes = blaiU64SaturatedU32Count(total)" in npu_source
    assert "blaiChannelAlign4(nonNegativeU32(blaiLayerCn(layer, 1'u32)))" in npu_source
    assert "alignedKernel = blaiChannelAlign4(kernelSize)" in npu_source
    assert "blaiChannelAlign4(plan.kernelSize)" in npu_source
    assert "((nonNegativeU32(blaiLayerCn(layer, 1'u32)) + 3'u32) div 4'u32) * 4'u32" not in npu_source
    assert "((kernelSize + 3'u32) div 4'u32) * 4'u32" not in npu_source
    assert "((plan.kernelSize + 3'u32) div 4'u32) * 4'u32" not in npu_source
    assert (
        "proc blaiInstructionCountBytes*(instructionCount: uint32"
        in npu_source
    )
    assert (
        "blaiU64ExactU32Count(\n    instructionCount.uint64 * BlaiInstructionSize.uint64, outBytes)"
        in npu_source
    )
    assert "let instructionCount = blaiOpenArrayLenU32(stream)" in npu_source
    assert "if blaiInstructionCountBytes(instructionCount, bytes):" in npu_source
    assert "let cursor = blaiInstructionByteCursor(instIndex, byteIndex)" in npu_source
    assert "blaiInstructionByte(instructions, cursor)" in npu_source
    assert "instIndex * BlaiInstructionSize + byteIndex" not in npu_source
    assert "workspaceInstructionPrepared.instructionCount * BlaiInstructionSize.uint32" not in npu_source
    assert "proc blaiBiasWordCountBytes*(biasCount: uint32" in npu_source
    assert (
        "blaiU64ExactU32Count(\n    biasCount.uint64 * BlaiNpuBiasElementBytes.uint64, outBytes)"
        in npu_source
    )
    assert "stream.len.uint64 * BlaiInstructionSize.uint64" not in npu_source
    assert "let outputCFits = blaiU64ExactU32Count(outputCNeed, outResult.outputC)" in npu_source
    assert "let routeCFits = blaiU64ExactU32Count(routeC, outResult.routeC)" in npu_source
    assert "proc blaiU64SaturatedMul*(left, right: uint64): uint64" in npu_source
    assert "proc blaiU64SaturatedAdd*(left, right: uint64): uint64" in npu_source
    assert "proc blaiReferenceHwcElementCount*(w, h, c: uint32): uint64" in npu_source
    assert "proc blaiReferenceHwcElementCount*(w, h: uint32, c: uint64): uint64" in npu_source
    assert (
        "let count = blaiReferenceHwcElementCount(w, h, c)"
        in npu_source
    )
    assert "proc blaiReferenceHwcStrideExtent*(w, h, channels, strideC: uint32): uint64" in npu_source
    assert "proc blaiReferenceRouteInputExtent*(\n    offset, w, h, channels: uint32): uint64" in npu_source
    assert "proc blaiReferenceScaledDimExtent*(dim, stride: uint32): uint64" in npu_source
    assert (
        "proc blaiReferenceUpsampleOutputExtent*(\n"
        "    inputW, inputH, writtenC, stride, outputW, outputC: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceTfliteRouteWSegmentExtent*(\n"
        "    offset, axis, height, outputW, outputC, channels: uint32): uint64"
        in npu_source
    )
    assert "BlaiReferenceTfliteRouteWEasyCopyCursor* = object" in npu_source
    assert (
        "proc blaiReferenceTfliteRouteWEasyCopyCursor*(\n"
        "    outputBase, inputBase, relativeIndex, slice: uint32"
        in npu_source
    )
    assert (
        "let copyCursor = blaiReferenceTfliteRouteWEasyCopyCursor(\n"
        "            outputCursor, inputBase, offset, slice, input.len, output.len)"
        in npu_source
    )
    assert "output[(outputCursor + offset).int]" not in npu_source
    assert "input[(inputBase + offset).int]" not in npu_source
    assert "tfliteRouteWEasyCursor.outputIndex == 2" in npu_source
    assert (
        "proc blaiReferenceMatmulActivationElements*(height, channels: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceMatmulWeightElements*(inputC, outputC: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceDepthwiseOutputChannels*(\n"
        "    inputC, channelMultiplier: uint32): uint64"
        in npu_source
    )
    assert "proc blaiReferencePaddedDim*(before, core, after: uint32): uint32" in npu_source
    assert (
        "proc blaiReferenceTransposeLkInputElements*(\n"
        "    sequenceLength, channels: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceTransposeLkOutputChannels*(\n"
        "    channels, alignedKernelSize: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceTransposeLkOutputElements*(\n"
        "    windowCount, channels, alignedKernelSize: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceGroupedKernelElementCount*(\n"
        "    outputC, inputPerGroup, kernelSize: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceKernelElementCount*(\n"
        "    outputC, inputC, kernelW, kernelH: uint32): uint64"
        in npu_source
    )
    assert (
        "proc blaiReferenceKernelElementCount*(\n"
        "    outputC: uint64, kernelW, kernelH: uint32): uint64"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.inputW, plan.inputH, plan.inputC)"
        in npu_source
    )
    assert (
        "let sampleCount = blaiReferenceHwcElementCount(width, height, inputC)"
        in npu_source
    )
    assert (
        "blaiReferenceTransposeLkInputElements(\n"
        "      outResult.sequenceLength, plan.channels)"
        in npu_source
    )
    assert (
        "blaiReferenceTransposeLkOutputChannels(channels, alignedKernel)"
        in npu_source
    )
    assert (
        "blaiReferenceTransposeLkOutputElements(\n"
        "      outResult.windowCount, plan.channels, outResult.alignedKernelSize)"
        in npu_source
    )
    transpose_lk_direct_block = re.search(
        r"proc blaiReferenceTfliteTransposeLk1d\*\(.*?"
        r"proc blaiReferenceTfliteTransposeLkV2Fits\*",
        npu_source,
        re.S,
    )
    assert transpose_lk_direct_block is not None
    assert (
        "blaiHwcIndex(window, channel, plan.channels, wt,\n"
        "            result.alignedKernelSize)"
    ) in transpose_lk_direct_block.group(0)
    assert (
        "blaiHwcIndex(sourceOffset, 0'u32, 1'u32, channel, plan.channels)"
        in transpose_lk_direct_block.group(0)
    )
    assert "window * plan.channels * result.alignedKernelSize" not in (
        transpose_lk_direct_block.group(0)
    )
    assert "sourceOffset * plan.channels + channel" not in (
        transpose_lk_direct_block.group(0)
    )
    transpose_lk_v2_block = re.search(
        r"proc blaiReferenceTfliteTransposeLkV2_1d\*\(.*?"
        r"proc blaiReferenceTflitePreTransconvReadinessInto\*",
        npu_source,
        re.S,
    )
    assert transpose_lk_v2_block is not None
    assert (
        "blaiHwcIndex(window - 1'u32, channel, plan.channels,\n"
        "              plan.stride + wt, result.alignedKernelSize)"
    ) in transpose_lk_v2_block.group(0)
    assert (
        "blaiHwcIndex(sourceOffset, 0'u32, 1'u32, channel, plan.channels)"
        in transpose_lk_v2_block.group(0)
    )
    assert "let channelBase = window * plan.channels * result.alignedKernelSize" not in (
        transpose_lk_v2_block.group(0)
    )
    assert "let prevBase = (window - 1'u32) * plan.channels" not in (
        transpose_lk_v2_block.group(0)
    )
    assert (
        "blaiReferenceGroupedKernelElementCount(\n"
        "      plan.outputC, inputPerGroup, plan.kernelSize)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(\n"
        "      outResult.outputW, outResult.outputH, plan.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceKernelElementCount(outputCNeed, plan.kernelW, plan.kernelH)"
        in npu_source
    )
    assert (
        "blaiReferenceDepthwiseOutputChannels(plan.inputC, plan.channelMultiplier)"
        in npu_source
    )
    assert (
        "blaiReferenceKernelElementCount(\n"
        "      plan.outputC, plan.inputC, plan.kernelW, plan.kernelH)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(outResult.outputW, outResult.outputH,\n"
        "                                 outputCNeed)"
        in npu_source
    )
    assert npu_source.count(
        "blaiReferenceHwcElementCount(\n"
        "      outResult.outputW, outResult.outputH, plan.inputC)"
    ) >= 3
    assert (
        "blaiReferenceHwcElementCount(plan.width, plan.height, plan.channels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.inputW, plan.inputH, plan.channels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.outputW, plan.outputH, plan.channels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(\n"
        "      outResult.outputW, outResult.outputH, outResult.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcStrideExtent(\n"
        "      plan.inputW, plan.inputH, plan.inputC, outResult.inputStrideC)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcStrideExtent(\n"
        "      plan.width, plan.height, plan.channels, outResult.inputStrideC)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcStrideExtent(\n"
        "          plan.width, plan.height, plan.inputC, plan.inputStrideC)"
        in npu_source
    )
    assert npu_source.count(
        "blaiReferenceRouteInputExtent(\n"
        "        inputPlan.offset, plan.width, plan.height, inputPlan.channels)"
    ) >= 4
    assert (
        "blaiReferenceHwcElementCount(plan.outputW, plan.outputH, outputChannels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.width, plan.height, outputChannels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.outputW, plan.outputH, plan.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceUpsampleOutputExtent(\n"
        "        plan.inputW, plan.inputH, plan.inputC, plan.stride,\n"
        "        outResult.outputW, outResult.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceUpsampleOutputExtent(\n"
        "        plan.width, plan.height, outResult.outputC, plan.stride,\n"
        "        outResult.outputW, outResult.outputC)"
        in npu_source
    )
    assert (
        "let minimumOutputW = blaiReferenceScaledDimExtent(plan.width, plan.stride)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.width, plan.height, plan.route1C)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.width, plan.height, plan.route2C)"
        in npu_source
    )
    assert (
        "blaiReferenceTfliteRouteWSegmentExtent(\n"
        "            inputPlan.offset, plan.axis, plan.height, plan.outputW,\n"
        "            plan.outputC, inputPlan.channels)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.outputW, plan.height, plan.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceMatmulActivationElements(plan.height, plan.inputC)"
        in npu_source
    )
    assert (
        "blaiReferenceMatmulWeightElements(plan.inputC, plan.outputC)"
        in npu_source
    )
    assert (
        "blaiReferenceMatmulActivationElements(plan.height, plan.outputC)"
        in npu_source
    )
    assert (
        "blaiReferencePaddedDim(plan.leftPadW, plan.inputW, plan.rightPadW)"
        in npu_source
    )
    assert (
        "blaiReferencePaddedDim(plan.leftPadH, plan.inputH, plan.rightPadH)"
        in npu_source
    )
    assert (
        "blaiReferencePaddedDim(plan.leftPadC, plan.inputC, plan.rightPadC)"
        in npu_source
    )
    assert (
        "blaiReferenceHwcElementCount(plan.inputW, plan.inputH, plan.inputC)"
        in npu_source
    )
    assert (
        "let elements = plan.width.uint64 * plan.height.uint64 * plan.channels.uint64"
        not in npu_source
    )
    assert (
        "let inputElements =\n"
        "    plan.inputW.uint64 * plan.inputH.uint64 * plan.inputC.uint64"
        not in npu_source
    )
    assert (
        "let outputElements =\n"
        "    outResult.outputH.uint64 * outResult.outputW.uint64 *\n"
        "    outResult.outputC.uint64"
        not in npu_source
    )
    assert (
        "let inputNeed = plan.inputW.uint64 * plan.inputH.uint64 * plan.channels.uint64"
        not in npu_source
    )
    assert (
        "plan.outputW.uint64 * plan.outputH.uint64 * plan.channels.uint64"
        not in npu_source
    )
    assert (
        "plan.inputW.uint64 * plan.inputH.uint64 * outResult.inputStrideC.uint64"
        not in npu_source
    )
    assert (
        "let spatialElements64 = plan.inputW.uint64 * plan.inputH.uint64"
        not in npu_source
    )
    assert (
        "let sampleCount = plan.width.uint64 * plan.height.uint64 * plan.inputC.uint64"
        not in npu_source
    )
    assert (
        "let inputNeed = inputPlan.offset.uint64 +\n"
        "        pixels * inputPlan.channels.uint64"
        not in npu_source
    )
    assert (
        "let outputNeed = pixels * outputChannels"
        not in npu_source
    )
    assert (
        "let outputNeed = pixels * plan.outputC.uint64"
        not in npu_source
    )
    assert (
        "plan.outputH.uint64 * plan.outputW.uint64 * outputChannels"
        not in npu_source
    )
    assert (
        "plan.outputH.uint64 * plan.outputW.uint64 * plan.outputC.uint64"
        not in npu_source
    )
    assert (
        "let input1Need = pixels * plan.route1C.uint64"
        not in npu_source
    )
    assert (
        "let input2Need = pixels * plan.route2C.uint64"
        not in npu_source
    )
    assert (
        "let minimumOutputW = plan.width.uint64 * plan.stride.uint64"
        not in npu_source
    )
    assert (
        "let minimumOutputH = plan.height.uint64 * plan.stride.uint64"
        not in npu_source
    )
    assert (
        "outputNeed = maxOutputY.uint64 * outResult.outputW.uint64 *\n"
        "      outResult.outputC.uint64 +\n"
        "      maxOutputX.uint64 * outResult.outputC.uint64"
        not in npu_source
    )
    assert "var segmentNeed = 0'u64" not in npu_source
    assert (
        "plan.height.uint64 * inputPlan.channels.uint64 *\n"
        "              plan.outputC.uint64"
        not in npu_source
    )
    assert (
        "inputPlan.channels.uint64 * plan.outputW.uint64 *\n"
        "              plan.outputC.uint64"
        not in npu_source
    )
    assert "let inputNeed = inputPlan.offset.uint64 + segmentNeed" not in npu_source
    assert (
        "let outputNeed = plan.height.uint64 * plan.outputW.uint64 * plan.outputC.uint64"
        not in npu_source
    )
    assert "let inputNeed = plan.height.uint64 * plan.inputC.uint64" not in npu_source
    assert "let weightNeed = plan.outputC.uint64 * plan.inputC.uint64" not in npu_source
    assert "let outputNeed = plan.height.uint64 * plan.outputC.uint64" not in npu_source
    assert "let outputW = plan.leftPadW.uint64 + plan.inputW.uint64 + plan.rightPadW.uint64" not in npu_source
    assert "let outputH = plan.leftPadH.uint64 + plan.inputH.uint64 + plan.rightPadH.uint64" not in npu_source
    assert "let outputC = plan.leftPadC.uint64 + plan.inputC.uint64 + plan.rightPadC.uint64" not in npu_source
    assert "let inputNeed = plan.inputW.uint64 * plan.inputH.uint64 * plan.inputC.uint64" not in npu_source
    assert "let inputNeed = outResult.sequenceLength.uint64 * plan.channels.uint64" not in npu_source
    assert (
        "let outputNeed =\n"
        "    outResult.windowCount.uint64 * plan.channels.uint64 *\n"
        "    outResult.alignedKernelSize.uint64"
        not in npu_source
    )
    assert (
        "let weightNeed = plan.outputC.uint64 * inputPerGroup.uint64 *\n"
        "    plan.kernelSize.uint64 * plan.kernelSize.uint64"
        not in npu_source
    )
    assert "let kernelNeed = plan.outputC.uint64 * plan.inputC.uint64 *" not in npu_source
    assert "let kernelNeed = plan.kernelW.uint64 * plan.kernelH.uint64 * outputCNeed" not in npu_source
    assert "let outputCNeed = plan.inputC.uint64 * plan.channelMultiplier.uint64" not in npu_source
    assert "let count = w.uint64 * h.uint64 * c.uint64" not in npu_source
    assert "let sampleCount = width.uint64 * height.uint64 * inputC.uint64" not in npu_source
    assert "let outputChannels = channels.uint64 * alignedKernel.uint64" not in npu_source
    assert (
        "let outputNeed = outResult.outputW.uint64 * outResult.outputH.uint64 *\n"
        "    plan.inputC.uint64"
        not in npu_source
    )
    assert (
        "let outputNeed =\n"
        "    outResult.outputH.uint64 * outResult.outputW.uint64 * plan.inputC.uint64"
        not in npu_source
    )
    assert npu_source.count(
        "discard blaiU64ExactU32Count(inputNeed, outResult.inputElements)"
    ) >= 10
    assert npu_source.count(
        "discard blaiU64ExactU32Count(weightNeed, outResult.weightElements)"
    ) >= 3
    assert npu_source.count(
        "discard blaiU64ExactU32Count(kernelNeed, outResult.kernelElements)"
    ) >= 4
    assert npu_source.count(
        "discard blaiU64ExactU32Count(biasNeed, outResult.biasElements)"
    ) >= 7
    assert npu_source.count(
        "discard blaiU64ExactU32Count(outputNeed, outResult.requiredOutputElements)"
    ) >= 15
    assert "discard blaiU64ExactU32Count(input1Need, outResult.input1Elements)" in npu_source
    assert "discard blaiU64ExactU32Count(input2Need, outResult.input2Elements)" in npu_source
    assert npu_source.count(
        "discard blaiU64ExactU32Count(elements, outResult.elements)"
    ) >= 2
    assert npu_source.count(
        "discard blaiU64ExactU32Count(elements, outResult.requiredElements)"
    ) >= 2
    assert "blaiU64ExactU32Count(sampleCount, sampleCountElements)" in npu_source
    assert "blaiU64ExactI32Count(spatialElements64, outResult.spatialElements)" in npu_source
    assert "spatialElements64 <= high(int32).uint64" not in npu_source
    assert "discard blaiU64ExactU32Count(outputNeed, outResult.outputElements)" in npu_source
    assert "let outputElementsFit =\n    blaiU64ExactU32Count(outputNeed, outResult.outputElements)" in npu_source
    assert "outputElementsFit and outputNeed <= outputLen.uint64" in npu_source
    assert npu_source.count(
        "discard blaiU64ExactU32Count(\n          inputNeed, outResult.firstBlockedInputElements)"
    ) >= 5
    assert npu_source.count(
        "discard blaiU64MaxExactU32Count(\n    maxInputNeed, outResult.firstBlockedInputElements)"
    ) >= 5
    assert "discard blaiU64ExactU32Count(inputExtent, outResult.inputExtent)" in npu_source
    assert "let bounded = min(count, blaiBufferLenU32(capacity))" in npu_source
    assert "discard blaiU32ExactIntCount(bounded, result)" in npu_source
    assert "if not blaiU32ExactIntCount(index, result.index):" in npu_source
    assert "proc blaiCpuBiasElementWidth*(plan: BlaiCpuBiasStreamPlan" in npu_source
    assert "if not blaiU32ExactIntCount(plan.bytesPerElement, outWidth):" in npu_source
    assert "if not blaiCpuBiasElementWidth(plan, width):" in npu_source
    assert "BlaiCpuBiasElementByteCursor* = object" in npu_source
    assert (
        "proc blaiCpuBiasElementByteCursor*(elementIndex, laneIndex, elementWidth: int)"
        in npu_source
    )
    assert "let cursor = blaiCpuBiasElementByteCursor(i, k, width)" in npu_source
    assert "blaiCpuStreamOpenArray(bytes, window)[cursor.byteIndex]" in npu_source
    assert "blaiCpuStreamOpenArray(bytes, window)[base + k]" not in npu_source
    assert "proc blaiNpuBiasWordByteCount*(outCount: var int): bool" in npu_source
    assert "if not blaiNpuBiasWordByteCount(byteCount):" in npu_source
    assert (
        "proc blaiForwardBiasWordByteOffset*(biasIndex: uint32,"
        in npu_source
    )
    assert "blaiBiasWordCountBytes(biasIndex, outOffset)" in npu_source
    assert "blaiForwardBiasWordByteOffset(biasIndex.uint32, byteOffset)" in npu_source
    assert "result.byteOffset = biasIndex.uint32 * BlaiNpuBiasElementBytes" not in npu_source
    assert "proc blaiInstructionBitCursor*(index: uint32" in npu_source
    assert "blaiInstructionBitCursor(uint32(index))" in npu_source
    assert "blaiInstructionBitCursor(uint32(base + bit))" in npu_source
    assert "BlaiInstructionFieldStrideCursor* = object" in npu_source
    assert (
        "proc blaiInstructionFieldStrideCursor*(slotIndex, baseBit, strideBits,"
        in npu_source
    )
    for cursor_name in (
        "blaiCpuInputLayerEntryCursor",
        "blaiCpuYoloInfoEntryCursor",
        "blaiCpuExtraLayerEntryCursor",
        "blaiCpuExtraMultiplierEntryCursor",
    ):
        cursor_block = re.search(
            rf"proc {cursor_name}\*\(.*?proc ",
            npu_source,
            re.S,
        )
        assert cursor_block is not None
        assert "BaseBit +" not in cursor_block.group(0)
        assert "* BlaiCpu" not in cursor_block.group(0)
        assert "blaiInstructionFieldStrideCursor" in cursor_block.group(0)
    assert "blaiInstructionBitCursor(index.int)" not in npu_source
    assert "blaiInstructionBitCursor(base.int + bit)" not in npu_source
    assert "BlaiSdkConvolutionalType* = 0'i32" in npu_source
    assert "of BlaiSdkConvolutionalType: blaiConvolutional" in npu_source
    assert "of BlaiSdkPreTransconvType: blaiPreTransconv" in npu_source
    assert "of ord(blaiConvolutional).int32: blaiConvolutional" not in npu_source
    assert "of ord(blaiPreTransconv).int32: blaiPreTransconv" not in npu_source
    assert "BlaiSdkActLinear* = 2'i32" in npu_source
    assert "of BlaiSdkActLeaky: blaiActLeaky" in npu_source
    assert "of BlaiSdkActReluN: blaiActReluN" in npu_source
    assert "value > ord(high(BlaiActivation)).int32" not in npu_source
    assert "BlaiActivation(value)" not in npu_source
    assert "BlaiSdkCpuDspHeaderRecord* = 0'u32" in npu_source
    assert "of BlaiSdkCpuDspHeaderRecord: blaiCpuDspHeader" in npu_source
    assert "of BlaiSdkCpuDetailGeneralFormRecord: blaiCpuDetailGeneralForm" in npu_source
    assert "of ord(blaiCpuDspHeader).uint32: blaiCpuDspHeader" not in npu_source
    assert "of ord(blaiCpuDetailGeneralForm).uint32: blaiCpuDetailGeneralForm" not in npu_source
    assert "BlaiMaxInputNumU32*   = 8'u32" in npu_source
    assert "BlaiMaxRouteInputNumU32* = BlaiMaxInputNumU32 - 1'u32" in npu_source
    assert "BlaiMaxYoloMaskNumU32* = 3'u32" in npu_source
    assert "BlaiMaxWeightPatchesU32* = 64'u32" in npu_source
    assert "min(inputCount, BlaiMaxInputNumU32)" in npu_source
    assert "maskCount > BlaiMaxYoloMaskNumU32" in npu_source
    assert "descriptorCount > BlaiMaxRouteInputNumU32" in npu_source
    assert "min(patchCount, BlaiMaxWeightPatchesU32)" in npu_source
    assert "BlaiMaxInputNum.uint32" not in npu_source
    assert "BlaiMaxYoloMaskNum.uint32" not in npu_source
    assert "BlaiMaxYoloTotal.uint32" not in npu_source
    assert "BlaiMaxWeightPatches.uint32" not in npu_source
    assert "for byteIndex in 0 ..< byteCount:" in npu_source
    assert "word.count != byteCount" in npu_source
    assert "doAssert blaiNpuBiasWordByteCount(biasWordByteCount)" in npu_source
    assert "proc blaiForwardWorkspaceRelativeByteOffset*(relativeOffset: uint32" in npu_source
    assert "proc blaiForwardWorkspaceLe32LaneOffset*(relativeOffset: uint32" in npu_source
    assert "blaiForwardWorkspaceLe32LaneOffset(\n        relativeOffset, cursor, laneOffset)" in npu_source
    assert "relativeOffset + cursor.byteIndex.uint32" not in npu_source
    assert "proc blaiForwardWorkspaceAbsoluteOffset*(baseOffset: uint32" in npu_source
    assert "workspace.instruction.offset, outResult.instructionBytes.uint64" in npu_source
    assert (
        "blaiPatchSlotOffset(outResult.inputSlot, outResult.patchSize)"
        in npu_source
    )
    assert (
        "blaiPatchSlotOffset(outResult.outputSlot, outResult.patchSize)"
        in npu_source
    )
    assert "BlaiPatchSlotIndexAbi* = object" in npu_source
    assert "proc blaiPatchSlotIndexAbi*" in npu_source
    signed_patch_slot_block = re.search(
        r"proc blaiPatchSlotOffset\*\(slot: int32,.*?"
        r"proc blaiTensorBufferOffset\*",
        npu_source,
        re.S,
    )
    assert signed_patch_slot_block is not None
    assert "let slotIndex = blaiPatchSlotIndexAbi(slot)" in (
        signed_patch_slot_block.group(0)
    )
    assert "blaiPatchSlotOffset(slotIndex.value, patchSize)" in (
        signed_patch_slot_block.group(0)
    )
    assert "slot.uint32" not in signed_patch_slot_block.group(0)
    assert "workspace.data.offset, inputRelative, outResult.inputOffset" in npu_source
    assert "workspace.data.offset, outputRelative, outResult.outputOffset" in npu_source
    assert "workspace.instruction.offset.uint64 + outResult.instructionBytes.uint64" not in npu_source
    assert "workspace.data.offset.uint64 + inputRelative" not in npu_source
    assert "workspace.data.offset.uint64 + outputRelative" not in npu_source
    assert "workspace.data.offset + inputRelative.uint32" not in npu_source
    assert "workspace.data.offset + outputRelative.uint32" not in npu_source
    assert "outResult.inputSlot.uint64 * outResult.patchSize.uint64" not in npu_source
    assert "outResult.outputSlot.uint64 * outResult.patchSize.uint64" not in npu_source
    assert "blaiForwardWorkspaceRelativeByteOffset(relativeOffset, offsetIndex)" in npu_source
    assert "index = window.start + offsetIndex" in npu_source
    assert "let layout = blaiTensorRowLayout(plan)" in npu_source
    assert "for row in 0 ..< layout.rows:" in npu_source
    assert "for c in 0 ..< layout.actualChannels:" in npu_source
    assert "for c in layout.actualChannels ..< layout.paddedChannels:" in npu_source
    assert (
        "proc blaiTensorRowPatternValue*(row, rowStride, channel: uint32,"
        in npu_source
    )
    assert "blaiTensorRowPatternValue(row.uint32, rowStride, c.uint32, value)" in npu_source
    assert "let value = row.uint64 * rowStride.uint64 + c.uint64" not in npu_source
    assert "BlaiParsedForwardReadinessLayerWindow* = object" in npu_source
    assert "BlaiParsedForwardReadinessLayerCursor* = object" in npu_source
    assert "blaiParsedForwardReadinessLayerWindow(parsed.storedLayerCount, layers.len)" in npu_source
    assert "blaiBoundedU32Count(parsed.storedLayerCount, layers.len)" not in npu_source
    assert "let layerCount = blaiBoundedU32Count(outResult.readiness.layerCount, layers.len)" in npu_source
    assert "let layerCount = blaiBoundedU32Count(currentReadiness.layerCount, layers.len)" in npu_source
    assert "let layerCount = blaiBoundedU32Count(plan.readiness.layerCount, layers.len)" in npu_source
    assert "BlaiParsedForwardLayerWindow* = object" in npu_source
    assert "BlaiParsedForwardLayerCursor* = object" in npu_source
    assert "proc blaiParsedForwardLayerWindow*(\n    layerCount: uint32" in npu_source
    assert "proc blaiParsedForwardLayerCursor*(\n    window: BlaiParsedForwardLayerWindow" in npu_source
    assert "parsedForwardLayerWindow.stopIndex == 2" in npu_source
    assert "parsedForwardLayerCursor.layerIndex == 2" in npu_source
    parsed_workspace_blocks = re.findall(
        r"proc blaiPlanParsedForwardModelWorkspaceInto\*\(.*?"
        r"(?=^proc blaiPlanParsedForwardModelWorkspace)",
        npu_source,
        re.S | re.M,
    )
    assert len(parsed_workspace_blocks) >= 2
    for block in parsed_workspace_blocks[:2]:
        assert "blaiParsedForwardLayerWindow(" in block
        assert "layers.toOpenArray(layerWindow.startIndex, layerWindow.stopIndex)" in block
        assert "layers.toOpenArray(0, layerCount - 1)" not in block
    parsed_match_blocks = re.findall(
        r"proc blaiParsedForwardPlanMatchesLayers\(\n.*?"
        r"(?=^proc blaiParsedForwardPlanMatchesLayers|^proc blaiFinalizeParsedForwardExecuteReadiness)",
        npu_source,
        re.S | re.M,
    )
    assert len(parsed_match_blocks) >= 2
    for block in parsed_match_blocks[:2]:
        assert "blaiParsedForwardLayerWindow(" in block
        assert "layers.toOpenArray(layerWindow.startIndex, layerWindow.stopIndex)" in block
        assert "layers.toOpenArray(0, layerCount - 1)" not in block
    assert "blaiBoundedU32Count(\n      state.inputCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(\n      state.outputSlotCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(inputCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(count, BlaiMaxInputNum - 1)" in npu_source
    assert "blaiBoundedU32Count(\n      result.inputCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(\n      decoded.inputCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(\n      result.maskCount, BlaiMaxYoloMaskNum)" in npu_source
    assert "blaiBoundedU32Count(\n      decoded.maskCount, BlaiMaxYoloMaskNum)" in npu_source
    assert "blaiBoundedU32Count(inputCount, BlaiMaxInputNum)" in npu_source
    assert "proc blaiRouteConvExtraInputCount*(inputNum: int32" in npu_source
    assert "blaiBoundedU32Count(extraCount, BlaiMaxInputNum - 1)" in npu_source
    assert "let cacheIndex = blaiForwardCacheRangeCount(plan.cacheRangeCount)" in npu_source
    assert "0 ..< blaiForwardCacheRangeCount(plan.cacheRangeCount)" in npu_source
    assert (
        "0 ..< blaiForwardCacheRangeCount(execution.cache.cacheRangeCount)"
        in npu_source
    )
    assert "proc blaiUintAddressInRange*" in npu_source
    assert "blaiUintAddressInRange(address, cachedBase.uint, size.uint)" in npu_source
    assert "blaiUintAddressInRange(address, base.uint, size.uint)" in npu_source
    assert "blaiUintAddressInRange(address.uint, WramBase.uint, WramSize.uint)" in npu_source
    assert "doAssert blaiUintAddressInRange(high(uint), high(uint) - 3'u, 4'u)" in npu_source
    assert "proc blaiUint32AddressEndExclusive*(address, bytes: uint32): uint64" in npu_source
    assert "proc blaiUint32AddressRangeEndFits*(address, bytes: uint32): bool" in npu_source
    assert "outResult.endExclusive = blaiUint32AddressEndExclusive(address, bytes)" in npu_source
    assert "outResult.fits = blaiUint32AddressRangeEndFits(address, bytes)" in npu_source
    assert "outResult.endExclusive = address.uint64 + bytes.uint64" not in npu_source
    assert "bytes.uint64 <= high(uint32).uint64 - address.uint64 + 1'u64" not in npu_source
    assert "address < cachedBase.uint + size.uint" not in npu_source
    assert "address < base.uint + size.uint" not in npu_source
    assert "address < (WramBase + WramSize.uint).uint32" not in npu_source
    assert "stream.len.uint32" not in npu_source
    assert "instructions.len.uint32" not in npu_source
    assert "weightBytes.len.uint32" not in npu_source
    assert "weightBytesIn.len.uint32" not in npu_source
    assert "biases.len.uint32" not in npu_source
    assert "biasInts.len.uint32" not in npu_source
    assert "expected.len.uint32" not in npu_source
    assert "actual.len.uint32" not in npu_source
    assert "output.len.uint32" not in npu_source
    assert "compared.uint32" not in npu_source
    assert "copied.uint32" not in npu_source
    assert "converted.uint32" not in npu_source
    assert "trailing.uint32" not in npu_source
    assert "index >= layers.len.uint32" not in npu_source
    assert "index >= extraInputs.len.uint32" not in npu_source
    assert "index >= yoloStorage.len.uint32" not in npu_source
    assert "layer: layers[index.int]" not in npu_source
    assert "extraInputs: extraInputs[index.int]" not in npu_source
    assert "yolo: yoloStorage[index.int]" not in npu_source
    assert "layers[index.int]" not in npu_source
    assert "result.storedLayerCount < layers.len.uint32" not in npu_source
    assert "result.storedLayerCount < extraInputs.len.uint32" not in npu_source
    assert "result.storedLayerCount < yoloStorage.len.uint32" not in npu_source
    assert "result.storedLayerCount < parsedLayers.len.uint32" not in npu_source
    assert "layerStorageFits = layers.len.uint32" not in npu_source
    assert "missingLayerCount = parsed.storedLayerCount - layers.len.uint32" not in npu_source
    assert "layers.len.uint32" not in npu_source
    assert "schedule.len.uint32" not in npu_source
    assert ".len.uint32" not in npu_source
    assert "min(parsed.storedLayerCount.int, layers.len)" not in npu_source
    assert "min(outResult.readiness.layerCount.int, layers.len)" not in npu_source
    assert "min(currentReadiness.layerCount.int, layers.len)" not in npu_source
    assert "min(plan.readiness.layerCount.int, layers.len)" not in npu_source
    assert "min(plan.memory.inputCount.int, BlaiMaxInputNum)" not in npu_source
    assert "min(plan.outputSlotCount.int, BlaiMaxInputNum)" not in npu_source
    assert "min(plan.inputCount.int, BlaiMaxInputNum)" not in npu_source
    assert "min(count.int, BlaiMaxInputNum - 1)" not in npu_source
    assert "inputCount.int" not in npu_source
    assert "maskCount.int" not in npu_source
    assert "extraCount.int" not in npu_source
    assert "let extraCount = min(layer.inputNum - 1, BlaiMaxInputNum.int32)" not in npu_source
    assert "nonNegativeU32(extraCount)" not in npu_source
    assert "cacheRangeCount.int" not in npu_source
    assert "storedLayerCount.int" not in npu_source
    assert "cursor.layerIndex.int" not in npu_source
    assert "if layerIndex >= blaiOpenArrayLenU32(layers)" not in npu_source
    assert "layers[layerIndex.int]" not in npu_source
    assert "inputPatchCount[inputIndex.int]" not in npu_source
    assert "inputSlots[inputIndex.int]" not in npu_source
    assert "outResult.steps[index.int]" not in npu_source
    assert "routeLoop.steps[stepIndex.int]" not in npu_source
    assert "layer.cn[index.int]" not in npu_source
    assert "blaiCpuExtraStorageIndex" not in npu_source
    assert "storageIndex.int" not in npu_source
    assert "biasPairActive[cursor.maskIndex.int]" not in npu_source
    assert "multipliers[inputIndex.int]" not in npu_source
    assert "let slot = inputIndex.int" not in npu_source
    assert "releaseMidLayers[layer.releaseMidNum.int]" not in npu_source
    assert "releaseLayers[layer.releaseNum.int]" not in npu_source
    assert "graphLayerToLayer[graph0.int]" not in npu_source
    assert "graphLayerToLayer[graph1.int]" not in npu_source
    assert "graph0 < 0 or graph0 >= graphLayerToLayer.len.int32" not in npu_source
    assert "graph1 < 0 or graph1 >= graphLayerToLayer.len.int32" not in npu_source
    assert "layer.cn[i.int]" not in npu_source
    assert "linePatchW[i.int]" not in npu_source
    assert "weightPatchOutC[patchIndex.int]" not in npu_source
    assert "result.inputs[inputIndex.int]" not in npu_source
    assert "let inputPlan = plan.inputs[inputIndex.int]" not in npu_source
    assert "plan.inputs[currentInputIndex.int]" not in npu_source
    assert "layer.dramIn[inputIndex.int]" not in npu_source
    assert "outResult.transfer = plan.inputs[inputIndex.int]" not in npu_source
    assert "layerInstructionIndex.int" not in npu_source
    assert "stream[outResult.layerInstructionIndex.int]" not in npu_source
    assert "var cursor = startCount.int" not in npu_source
    assert "actual = plan.actualChannels.int" not in npu_source
    assert "padded = plan.paddedChannels.int" not in npu_source
    assert "(plan.elements div plan.paddedChannels).int" not in npu_source
    assert "result.start = offset.int" not in npu_source
    assert "result.count = bytes.int" not in npu_source
    assert "fit.requiredElements.int" not in npu_source
    assert "let width = plan.bytesPerElement.int" not in npu_source
    assert "BlaiNpuBiasElementBytes.int" not in npu_source
    assert "relativeOffset.int" not in npu_source
    assert "min(count, blaiBufferLenU32(capacity)).int" not in npu_source
    assert "result.index = index.int" not in npu_source
    assert (
        "modelWorkspace.data, modelWorkspace.data.bytes, modelWorkspace.totalBytes.int"
        not in npu_source
    )
    assert "(modelWorkspace.totalBytes - 1).int" not in npu_source
    assert "modelWorkspaceBytes[modelWorkspace.totalBytes.int]" not in npu_source
    assert (
        "temporaryWeightBiasBytes[temporaryWeightBias.biasOffset.int]"
        not in npu_source
    )
    assert (
        "temporaryWeightBias.biasOffset.int + BlaiNpuBiasElementBytes.int"
        not in npu_source
    )
    assert "weightCursor.byteOffset.int" not in npu_source
    assert "biasCursor.byteOffset.int" not in npu_source
    assert "result.weightStream.cursor.byteOffset.int" not in npu_source
    assert "result.biasStream.cursor.byteOffset.int" not in npu_source
    assert "outResult.weightStream.cursor.byteOffset.int" not in npu_source
    assert "outResult.biasStream.cursor.byteOffset.int" not in npu_source
    assert "result.startIndex = cursor.byteOffset.int" not in npu_source
    assert "result.activeIndex = maskIndex.int" not in npu_source
    assert "result.widthIndex = widthIndex.int" not in npu_source
    assert "result.heightIndex = heightIndex.int" not in npu_source
    assert "result.packedIndex = packedIndex.int" not in npu_source
    assert "result.cnIndex = (inputIndex - 1'u32).int" not in npu_source
    assert "result.slotIndex = slot.int" not in npu_source
    assert "modelWorkspaceSegmentWindow.start == modelWorkspace.data.offset.int" not in npu_source
    assert "modelWorkspaceSegmentWindow.count == modelWorkspace.data.bytes.int" not in npu_source
    assert "proc blaiU32CountCursor*(count: uint32" in npu_source
    assert "proc blaiZeroBasedOpenArrayStop*(count: uint32" in npu_source
    assert "proc blaiStartedOpenArrayStop*(startIndex: int" in npu_source
    assert "BlaiReferenceFixedParsedDecodedWindow* = object" in npu_source
    assert "proc blaiReferenceFixedParsedDecodedWindow*(\n    elementCount: uint32" in npu_source
    assert "fixedParsedDecodedWindow.stopIndex == 2" in npu_source
    assert "BlaiReferenceTfliteParsedWeightWindow* = object" in npu_source
    assert "BlaiReferenceTfliteParsedBiasWindow* = object" in npu_source
    assert "proc blaiReferenceTfliteParsedWeightWindow*(\n    startIndex: int" in npu_source
    assert "proc blaiReferenceTfliteParsedBiasWindow*(\n    elementCount: uint32" in npu_source
    assert "tfliteParsedWeightWindow.stopIndex == 4" in npu_source
    assert "tfliteParsedBiasWindow.stopIndex == 2" in npu_source
    tflite_parsed_single_layer_block = re.search(
        r"proc blaiReferenceTfliteParsedSingleLayer2d\*\(.*?"
        r"proc blaiReferenceTfliteParsedLayer2d",
        npu_source,
        re.S,
    )
    assert tflite_parsed_single_layer_block is not None
    assert "blaiReferenceTfliteParsedWeightWindow(" in (
        tflite_parsed_single_layer_block.group(0)
    )
    assert "blaiReferenceTfliteParsedBiasWindow(" in (
        tflite_parsed_single_layer_block.group(0)
    )
    assert "blaiStartedOpenArrayStop(" not in (
        tflite_parsed_single_layer_block.group(0)
    )
    assert "blaiZeroBasedOpenArrayStop(" not in (
        tflite_parsed_single_layer_block.group(0)
    )
    assert "var weightStop" not in tflite_parsed_single_layer_block.group(0)
    assert "var biasStop" not in tflite_parsed_single_layer_block.group(0)
    tflite_parsed_layer_block = re.search(
        r"proc blaiReferenceTfliteParsedLayer2d\*\(.*?"
        r"proc blaiLastActiveParsedLayerIndex",
        npu_source,
        re.S,
    )
    assert tflite_parsed_layer_block is not None
    assert "blaiReferenceTfliteParsedWeightWindow(" in (
        tflite_parsed_layer_block.group(0)
    )
    assert "blaiReferenceTfliteParsedBiasWindow(" in (
        tflite_parsed_layer_block.group(0)
    )
    assert "blaiStartedOpenArrayStop(" not in tflite_parsed_layer_block.group(0)
    assert "blaiZeroBasedOpenArrayStop(" not in tflite_parsed_layer_block.group(0)
    assert "var weightStop" not in tflite_parsed_layer_block.group(0)
    assert "var biasStop" not in tflite_parsed_layer_block.group(0)
    fixed_parsed_single_layer_block = re.search(
        r"proc blaiReferenceFixedParsedSingleLayer2d\*\(.*?"
        r"proc blaiReferenceFixedParsedLayer2d",
        npu_source,
        re.S,
    )
    assert fixed_parsed_single_layer_block is not None
    assert "blaiReferenceFixedParsedDecodedWindow(" in (
        fixed_parsed_single_layer_block.group(0)
    )
    assert "blaiZeroBasedOpenArrayStop(" not in (
        fixed_parsed_single_layer_block.group(0)
    )
    assert "var weightStop" not in fixed_parsed_single_layer_block.group(0)
    assert "var biasStop" not in fixed_parsed_single_layer_block.group(0)
    fixed_parsed_layer_block = re.search(
        r"proc blaiReferenceFixedParsedLayer2d\*\(.*?"
        r"proc blaiLastActiveParsedLayerIndex",
        npu_source,
        re.S,
    )
    assert fixed_parsed_layer_block is not None
    assert "blaiReferenceFixedParsedDecodedWindow(" in fixed_parsed_layer_block.group(0)
    assert "blaiZeroBasedOpenArrayStop(" not in fixed_parsed_layer_block.group(0)
    assert "var weightStop" not in fixed_parsed_layer_block.group(0)
    assert "var biasStop" not in fixed_parsed_layer_block.group(0)
    assert "proc npuResetSettleReadCountCursor*(settleReadCount: uint32" in npu_source
    assert "proc blaiInstructionStreamCountCursor*(instructionCount: uint32" in npu_source
    assert "BlaiSdkInt32Field* = object" in npu_source
    assert "proc blaiSdkInt32Field*(value: uint32): BlaiSdkInt32Field" in npu_source
    assert "let field = blaiSdkInt32Field(channels)" in npu_source
    assert "let field = blaiSdkInt32Field(count)" in npu_source
    assert "let field = blaiSdkInt32Field(u32Value)" in npu_source
    assert "let field = blaiSdkInt32Field(index)" in npu_source
    assert "let indexField = blaiSdkInt32Field(layerIndex)" in npu_source
    assert "proc blaiRouteDescriptorChannelAbi*(channels: uint32" in npu_source
    assert "proc blaiInstructionCountAbi*(count: uint32" in npu_source
    assert "proc blaiAllocatorFieldAbi*(u32Value: uint32" in npu_source
    assert "proc blaiLayerIndexAbi*(index: uint32" in npu_source
    assert "proc blaiLayerIndexValue(index: uint32" in npu_source
    assert "proc blaiCpuRecordIndexAbi*(index: int" in npu_source
    assert "proc blaiOutputMismatchIndexAbi*(index: int" in npu_source
    assert "proc blaiOutputShapeDimAbi*(dim: uint32" in npu_source
    assert "proc blaiKernelSizeAbi*(kernelSize: uint32" in npu_source
    assert "proc blaiCpuExtraLayerFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuYoloInfoFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuSsdInfoFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuTfliteRouteMultiplierAbi*(highHalf: int32" in npu_source
    assert "proc blaiCpuLayerInfoFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuGeneralFormFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuTfliteRouteMultiplierHighAbi*(highBits: uint32" in npu_source
    assert "proc blaiCpuDetailGeneralFormFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuDspStatusInputNumAbi*(inputNum: uint32" in npu_source
    assert "proc blaiCpuInputLayerFieldAbi*(field: uint32" in npu_source
    assert "proc blaiCpuGraphLayerAbi*(layerIndex: uint32" in npu_source
    assert "proc blaiCpuTfliteMultiplierBitsAbi*(bits: uint32" in npu_source
    assert "proc blaiCpuBiasBitsAbi*(bits: uint32" in npu_source
    assert "if channels > high(int32).uint32:" not in npu_source
    assert "if count > high(int32).uint32:" not in npu_source
    assert "if u32Value > high(int32).uint32:" not in npu_source
    assert "if dim > high(int32).uint32:" not in npu_source
    assert "if kernelSize > high(int32).uint32:" not in npu_source
    assert "if field > high(int32).uint32:" not in npu_source
    assert "if inputNum > high(int32).uint32:" not in npu_source
    assert "if layerIndex > high(int32).uint32:" not in npu_source
    assert (
        "(blaiUint32FromInt32Bits(highHalf) and 0xFFFF_0000'u32) or lowHalf"
        in npu_source
    )
    assert "result.value = blaiInt32FromBits(encoded)" in npu_source
    assert "result.value = blaiInt32FromBits(highBits shl 16)" in npu_source
    assert "result.value = blaiInt32FromBits(bits)" in npu_source
    assert "cast[uint32](highHalf)" not in npu_source
    assert "result.value = cast[int32](encoded)" not in npu_source
    assert "result.value = cast[int32](highBits shl 16)" not in npu_source
    assert "proc blaiSignedFieldBits*(value: int32): uint32" in npu_source
    assert "blaiPutBits(result, 85, 6, blaiSignedFieldBits(desc.tfOutputShift))" in npu_source
    assert "blaiPutBits(result, 1, 6, blaiSignedFieldBits(desc.tfInput1Shift))" in npu_source
    assert "blaiPutBits(result, 7, 6, blaiSignedFieldBits(desc.tfInput2Shift))" in npu_source
    assert "blaiPutBits(result, 91, 6, blaiSignedFieldBits(desc.leftShift))" in npu_source
    assert "result.tfInput1Multiplier = blaiUint32FromInt32Bits(layer.tfInput1Multiplier)" in npu_source
    assert "quant.tfInput1Multiplier == blaiUint32FromInt32Bits(layer.tfInput1Multiplier)" in npu_source
    assert "outResult.widthMatches = decoded.w == nonNegativeU32(layer.w)" in npu_source
    assert "decoded.inLayer1Mem == nonNegativeU32(layer.dramIn[0])" in npu_source
    assert "decoded.activation == nonNegativeU32(layer.activation)" in npu_source
    assert "quant.quantizedActivationMin == nonNegativeU32(layer.quantizedActivationMin)" in npu_source
    assert "cast[uint32](desc.tfOutputShift)" not in npu_source
    assert "cast[uint32](desc.tfInput1Shift)" not in npu_source
    assert "cast[uint32](desc.tfInput2Shift)" not in npu_source
    assert "cast[uint32](desc.leftShift)" not in npu_source
    assert "cast[uint32](layer.tfInput1Multiplier)" not in npu_source
    assert "outResult.widthMatches = decoded.w == layer.w.uint32" not in npu_source
    assert "decoded.inLayer1Mem == layer.dramIn[0].uint32" not in npu_source
    assert "decoded.activation == layer.activation.uint32" not in npu_source
    assert "quant.quantizedActivationMin == layer.quantizedActivationMin.uint32" not in npu_source
    assert "outResult.encode.endCount.int" not in npu_source
    assert "instructionCount.int" not in npu_source
    assert "npuHasStarted = plan.resultingStarted" not in npu_source
    assert "npuHasConfiguredInstructionStream = plan.streamConfigured" not in npu_source
    assert "npuHasConfiguredInstructionStream = true" not in npu_source
    assert "BlaiInstructionCountApplyPlan* = object" in npu_source
    assert "BlaiInstructionCountState* = object" in npu_source
    assert "BlaiInstructionAppendEvidence* = object" in npu_source
    assert "BlaiInstructionStreamCommitEvidence* = object" in npu_source
    assert "BlaiInstructionEmittedCountEvidence* = object" in npu_source
    assert "proc blaiInstructionCountApplyPlan*(" in npu_source
    assert "proc blaiInstructionCountState*(" in npu_source
    assert "proc blaiApplyInstructionCountState*" in npu_source
    assert "proc blaiInstructionAppendEvidence*(" in npu_source
    assert "proc blaiInstructionStreamCommitEvidence*(" in npu_source
    assert "proc blaiInstructionEmittedCountEvidence*(" in npu_source
    assert "let endCountApply = blaiInstructionCountApplyPlan(" in npu_source
    assert "let appendEvidence = blaiInstructionAppendEvidence(" in npu_source
    assert "let commitEvidence = blaiInstructionStreamCommitEvidence(" in npu_source
    assert "let emittedEvidence =" in npu_source
    assert "blaiApplyInstructionCountState(" in npu_source
    assert "BlaiRouteDescriptorLayerState* = object" in npu_source
    assert "BlaiRouteDescriptorLayerApplyPlan* = object" in npu_source
    assert "BlaiRouteInstructionStepEvidence* = object" in npu_source
    assert "BlaiRouteInstructionStepCoreEvidence* = object" in npu_source
    assert "proc blaiRouteDescriptorLayerApplyPlan*(" in npu_source
    assert "proc blaiRouteInstructionStepEvidence*(" in npu_source
    assert "proc blaiRouteInstructionStepCoreEvidence*(" in npu_source
    assert "proc blaiRouteDescriptorLayerState*(" in npu_source
    assert "proc blaiApplyRouteDescriptorLayerState*" in npu_source
    assert (
        "result.stepLayerApply = blaiRouteDescriptorLayerApplyPlan(result.step)"
        in npu_source
    )
    assert "let stepEvidence = blaiRouteInstructionStepEvidence(" in npu_source
    assert "blaiApplyRouteDescriptorLayerState(" in npu_source
    assert "BlaiNpuCommonMemorySlots* = object" in npu_source
    assert "proc blaiNpuCommonInputSlotCursor*" in npu_source
    assert "proc blaiNpuCommonMemorySlots*(" in npu_source
    assert "proc blaiApplyCommonMemorySlots*" in npu_source
    assert "let slots = blaiNpuCommonMemorySlots(plan)" in npu_source
    assert "blaiApplyCommonMemorySlots(result, slots)" in npu_source
    common_memory_slots_block = re.search(
        r"proc blaiNpuCommonMemorySlots\*\(.*?"
        r"proc blaiApplyCommonMemorySlots\*\(",
        npu_source,
        re.S,
    )
    assert common_memory_slots_block is not None
    assert "let firstInput = blaiNpuCommonInputSlotCursor(0'u32)" in (
        common_memory_slots_block.group(0)
    )
    assert "let secondInput = blaiNpuCommonInputSlotCursor(1'u32)" in (
        common_memory_slots_block.group(0)
    )
    assert "plan.inputSlots[firstInput.index]" in (
        common_memory_slots_block.group(0)
    )
    assert "plan.inputSlots[secondInput.index]" in (
        common_memory_slots_block.group(0)
    )
    assert "plan.inputSlots[0]" not in common_memory_slots_block.group(0)
    assert "plan.inputSlots[1]" not in common_memory_slots_block.group(0)
    common_descriptor_block = re.search(
        r"proc blaiCommonDescriptor\*\(.*?proc blaiFetchDescriptorC2\*",
        npu_source,
        re.S,
    )
    assert common_descriptor_block is not None
    assert "result.inLayer1Mem = plan.inputSlots[0]" not in (
        common_descriptor_block.group(0)
    )
    assert "result.inLayer2Mem = plan.inputSlots[1]" not in (
        common_descriptor_block.group(0)
    )
    assert "result.outLayerMem = plan.outputSlot" not in (
        common_descriptor_block.group(0)
    )
    assert "result.midLayerMem = plan.midOutputSlot" not in (
        common_descriptor_block.group(0)
    )
    assert "BlaiFetchEmitCommitState* = object" in npu_source
    assert "BlaiFetchEmitCommitEvidence* = object" in npu_source
    assert "BlaiFetchEmitCommitApplyPlan* = object" in npu_source
    assert "proc blaiFetchEmitCommitEvidence*(" in npu_source
    assert "proc blaiFetchEmitCommitApplyPlan*(" in npu_source
    assert "proc blaiFetchEmitCommitState*(" in npu_source
    assert "proc blaiApplyFetchEmitCommitState*" in npu_source
    assert "let commitApply = blaiFetchEmitCommitApplyPlan(" in npu_source
    assert "blaiApplyFetchEmitCommitState(" in npu_source
    fetch_emit_commit_evidence_block = re.search(
        r"proc blaiFetchEmitCommitEvidence\*\(.*?"
        r"proc blaiFetchEmitCommitApplyPlan\*",
        npu_source,
        re.S,
    )
    assert fetch_emit_commit_evidence_block is not None
    assert "if not fits:" in fetch_emit_commit_evidence_block.group(0)
    assert "result.stateAfter = blaiFetchEmitCommitState(layer, ctrl)" in (
        fetch_emit_commit_evidence_block.group(0)
    )
    fetch_emit_commit_apply_block = re.search(
        r"proc blaiFetchEmitCommitApplyPlan\*\(.*?"
        r"proc blaiFetchEmitCommitState\*\(plan:",
        npu_source,
        re.S,
    )
    assert fetch_emit_commit_apply_block is not None
    assert "let evidence = blaiFetchEmitCommitEvidence(" in (
        fetch_emit_commit_apply_block.group(0)
    )
    assert "result.stateAfter = evidence.stateAfter" in (
        fetch_emit_commit_apply_block.group(0)
    )
    assert "result.valid = evidence.valid" in fetch_emit_commit_apply_block.group(0)
    assert "if not fits:" not in fetch_emit_commit_apply_block.group(0)
    assert "NpuWrapperStartedState* = object" in npu_source
    assert "NpuWrapperStartedApplyPlan* = object" in npu_source
    assert "proc npuWrapperStartedApplyPlan*(plan: NpuStartTransitionPlan)" in npu_source
    assert "proc npuWrapperStartedApplyPlan*(plan: NpuStopTransitionPlan)" in npu_source
    assert "proc npuWrapperStartedState*(plan: NpuWrapperStartedApplyPlan)" in npu_source
    assert "proc npuApplyWrapperStartedState*" in npu_source
    assert "let startedApply = npuWrapperStartedApplyPlan(plan)" in npu_source
    assert "npuApplyWrapperStartedState(npuWrapperStartedState(startedApply))" in npu_source
    assert "NpuInstructionStreamConfiguredState* = object" in npu_source
    assert "NpuInstructionStreamConfiguredApplyPlan* = object" in npu_source
    assert (
        "proc npuInstructionStreamConfiguredApplyPlan*(\n"
        "    plan: NpuInstructionStreamRegisterPlan)"
        in npu_source
    )
    assert (
        "proc npuInstructionStreamConfiguredApplyPlan*(\n"
        "    plan: NpuLayerBufferRegisterPlan)"
        in npu_source
    )
    assert "proc npuApplyInstructionStreamConfiguredState*" in npu_source
    assert "let configuredApply = npuInstructionStreamConfiguredApplyPlan(plan)" in npu_source
    assert (
        "npuApplyInstructionStreamConfiguredState(\n"
        "    npuInstructionStreamConfiguredState(configuredApply))"
        in npu_source
    )
    conv_compat_apply_block = re.search(
        r"proc npuApplyConvLayerCompatibilityInto\*\(.*?"
        r"proc npuApplyConvLayerCompatibility\*",
        npu_source,
        re.S,
    )
    assert conv_compat_apply_block is not None
    assert "let configuredApply = npuInstructionStreamConfiguredApplyPlan(false)" in (
        conv_compat_apply_block.group(0)
    )
    assert (
        "npuApplyInstructionStreamConfiguredState(\n"
        "      npuInstructionStreamConfiguredState(configuredApply))"
        in conv_compat_apply_block.group(0)
    )
    assert "npuHasConfiguredInstructionStream = false" not in (
        conv_compat_apply_block.group(0)
    )
    emit_layer_block = re.search(
        r"proc blaiEmitLayerInstructionsInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert emit_layer_block is not None
    assert "let appendEvidence = blaiInstructionAppendEvidence(" in (
        emit_layer_block.group(0)
    )
    assert "appendEvidence.endCountApply" in emit_layer_block.group(0)
    assert "var required: BlaiInstructionEncodeCountResult" not in (
        emit_layer_block.group(0)
    )
    assert "blaiUint32AppendFitInto(" not in emit_layer_block.group(0)
    assert "blaiInstructionCountApplyPlan(fit.requiredCount)" not in (
        emit_layer_block.group(0)
    )
    assert "layer.instCnt =" not in emit_layer_block.group(0)
    append_evidence_block = re.search(
        r"proc blaiInstructionAppendEvidence\*\(.*?"
        r"proc blaiEncodeInstructionsInto\*",
        npu_source,
        re.S,
    )
    assert append_evidence_block is not None
    assert "blaiInstructionEncodeRequiredInto(bundle, required)" in (
        append_evidence_block.group(0)
    )
    assert "blaiUint32AppendFitInto(streamLen, startCount, result.emitted, fit)" in (
        append_evidence_block.group(0)
    )
    assert "let endCountApply = blaiInstructionCountApplyPlan(fit.requiredCount)" in (
        append_evidence_block.group(0)
    )
    emitted_count_evidence_block = re.search(
        r"proc blaiInstructionEmittedCountEvidence\*\(\n"
        r"    bundle: BlaiNpuInstructionBundle,\n"
        r"    emitted: uint32\): BlaiInstructionEmittedCountEvidence =.*?"
        r"proc blaiInstructionStreamCommitEvidence\*",
        npu_source,
        re.S,
    )
    assert emitted_count_evidence_block is not None
    assert "blaiInstructionEncodeRequiredInto(bundle, count)" in (
        emitted_count_evidence_block.group(0)
    )
    assert "blaiUint32AppendFitInto(high(uint32), emitted, count.emitted, emittedFit)" in (
        emitted_count_evidence_block.group(0)
    )
    assert "result.emitted = emittedFit.requiredCount" in (
        emitted_count_evidence_block.group(0)
    )
    stream_commit_evidence_block = re.search(
        r"proc blaiInstructionStreamCommitEvidence\*\(\n"
        r"    streamLen, startCount, emitted: uint32\): "
        r"BlaiInstructionStreamCommitEvidence =.*?"
        r"proc blaiEncodeInstructionsInto\*",
        npu_source,
        re.S,
    )
    assert stream_commit_evidence_block is not None
    assert "blaiUint32AppendFitInto(streamLen, startCount, emitted, streamFit)" in (
        stream_commit_evidence_block.group(0)
    )
    assert "startCountApply = blaiInstructionCountApplyPlan(startCount)" in (
        stream_commit_evidence_block.group(0)
    )
    assert "endCountApply = blaiInstructionCountApplyPlan(result.endCount)" in (
        stream_commit_evidence_block.group(0)
    )
    route_step_core_block = re.search(
        r"proc blaiRouteInstructionStepCoreEvidence\*\(.*?"
        r"proc blaiRouteInstructionStepEvidence\*\(\n"
        r"    core: BlaiRouteInstructionStepCoreEvidence",
        npu_source,
        re.S,
    )
    assert route_step_core_block is not None
    assert "result.position =" in route_step_core_block.group(0)
    assert "result.step = routeLoop.steps[result.position.stepSlot]" in (
        route_step_core_block.group(0)
    )
    assert "result.stepLayerApply = blaiRouteDescriptorLayerApplyPlan(result.step)" in (
        route_step_core_block.group(0)
    )
    assert "result.stagedLayer = layer" in route_step_core_block.group(0)
    route_step_evidence_block = re.search(
        r"proc blaiRouteInstructionStepEvidence\*\(\n"
        r"    core: BlaiRouteInstructionStepCoreEvidence.*?"
        r"proc blaiEmitRouteLayerInstructionsInto\*",
        npu_source,
        re.S,
    )
    assert route_step_evidence_block is not None
    assert "result.bundle = blaiLayerInstructionBundle(" in (
        route_step_evidence_block.group(0)
    )
    assert "let core = blaiRouteInstructionStepCoreEvidence(" in (
        route_step_evidence_block.group(0)
    )
    assert "let stepPlan = blaiRouteStepFetchMemoryPlan(plan, core.step)" in (
        route_step_evidence_block.group(0)
    )
    assert "blaiRouteDescriptorStepPosition(stepIndex, routeLoop.count)" not in (
        route_step_evidence_block.group(0)
    )
    assert "blaiRouteDescriptorLayerApplyPlan(result.step)" not in (
        route_step_evidence_block.group(0)
    )
    emit_route_blocks = re.findall(
        r"proc blaiEmitRouteLayerInstructionsInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert len(emit_route_blocks) >= 2
    for emit_route_block in emit_route_blocks:
        assert "let commitEvidence = blaiInstructionStreamCommitEvidence(" in (
            emit_route_block
        )
        assert "let emittedEvidence =" in emit_route_block
        assert "blaiInstructionEmittedCountEvidence(stepEvidence.bundle, outResult.emitted)" in (
            emit_route_block
        )
        assert "blaiEncodeInstructionsInto(stepEvidence.bundle, stream, count, encoded)" in (
            emit_route_block
        )
        assert "commitEvidence.startCountApply" in emit_route_block
        assert "commitEvidence.endCountApply" in emit_route_block
        assert "let stepPosition =" not in emit_route_block
        assert "let step = routeLoop.steps" not in emit_route_block
        assert "let stepLayerApply = blaiRouteDescriptorLayerApplyPlan" not in (
            emit_route_block
        )
        assert "var stagedLayer = layer" not in emit_route_block
        assert "var emittedFit: BlaiUint32AppendFitResult" not in emit_route_block
        assert "blaiUint32AppendFitInto(high(uint32), outResult.emitted" not in (
            emit_route_block
        )
        assert "var streamFit: BlaiUint32AppendFitResult" not in emit_route_block
        assert "startCountApply = blaiInstructionCountApplyPlan" not in emit_route_block
        assert "endCountApply = blaiInstructionCountApplyPlan" not in emit_route_block
        assert "layer.instCnt =" not in emit_route_block
        assert "stagedLayer.c =" not in emit_route_block
    fetch_emit_block = re.search(
        r"proc blaiEmitFetchLayerInstructionsInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert fetch_emit_block is not None
    assert "layer = stagedLayer" not in fetch_emit_block.group(0)
    assert "ctrl = stagedCtrl" not in fetch_emit_block.group(0)
    assert "layer.instCnt = outResult.startCount.int32" not in npu_source
    assert "layer.instCnt = outResult.endCount.int32" not in npu_source
    assert "layer.instCnt = count.int32" not in npu_source
    assert "ctrl.weightPatchCount = plan.weightPatchCount.int32" not in npu_source
    assert "ctrl.psramPatchSize = plan.psramPatchSize.int32" not in npu_source
    assert "ctrl.psramPatchSize = plan.patchSize.int32" not in npu_source
    assert "layer.dramPatchNum = plan.dramPatchCount.int32" not in npu_source
    assert "layer.dramPatchNum = plan.finalPatchCursor.int32" not in npu_source
    assert "layer.releaseMidLayers[releaseCursor.slotIndex] = releasedLayer.int32" not in npu_source
    assert "layer.releaseLayers[releaseCursor.slotIndex] = releasedLayer.int32" not in npu_source
    assert "BlaiLayerCursorIndexAbi* = object" in npu_source
    assert "proc blaiLayerCursorIndexAbi*(index: int): BlaiLayerCursorIndexAbi" in npu_source
    assert "BlaiParsedForwardReadinessLayerWindow* = object" in npu_source
    assert "BlaiParsedForwardReadinessLayerCursor* = object" in npu_source
    assert "proc blaiParsedForwardReadinessLayerWindow*(\n    layerCount: uint32" in npu_source
    assert "proc blaiParsedForwardReadinessLayerCursor*(\n    window: BlaiParsedForwardReadinessLayerWindow" in npu_source
    assert "parsedReadinessLayerCursor.layerIndex == 1" in npu_source
    raw_parsed_forward_readiness_block = re.search(
        r"^proc blaiParsedForwardModelReadinessInto\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiParsedForwardModelReadiness\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\])",
        npu_source,
        re.S | re.M,
    )
    parsed_state_forward_readiness_block = re.search(
        r"^proc blaiParsedForwardModelReadinessInto\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiParsedForwardModelReadiness\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\])",
        npu_source,
        re.S | re.M,
    )
    assert raw_parsed_forward_readiness_block is not None
    assert parsed_state_forward_readiness_block is not None
    for parsed_forward_readiness_block in (
        raw_parsed_forward_readiness_block.group(0),
        parsed_state_forward_readiness_block.group(0),
    ):
        assert "let layerWindow =\n    blaiParsedForwardReadinessLayerWindow(" in (
            parsed_forward_readiness_block
        )
        assert "let layerCursor =\n      blaiParsedForwardReadinessLayerCursor(" in (
            parsed_forward_readiness_block
        )
        assert "layers[layerIndex]" not in parsed_forward_readiness_block
    fixed_reference_model_block = re.search(
        r"^proc blaiReferenceFixedParsedModel2d\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],\n"
        r"    useTflite: bool,\n"
        r"    input: openArray\[int8\],\n"
        r"    layerInputs: openArray\[BlaiReferenceFixedParsedModelInput\],"
        r".*?(?=^proc blaiReferenceFixedParsedModel2d\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],\n"
        r"    useTflite: bool,\n"
        r"    input: openArray\[int8\],\n"
        r"    cpuWeightBytes: openArray\[uint8\],)",
        npu_source,
        re.S | re.M,
    )
    assert fixed_reference_model_block is not None
    assert "let layerCursor = blaiRecoveredLayerCursor(layerIndex.uint32, layers.len)" in (
        fixed_reference_model_block.group(0)
    )
    assert "let layerState = layers[layerCursor.index]" in fixed_reference_model_block.group(0)
    assert "let referenceLayerIndex = blaiLayerCursorIndexAbi(layerCursor.index)" in (
        fixed_reference_model_block.group(0)
    )
    assert "layerInputs[layerCursor.index].secondInput" in (
        fixed_reference_model_block.group(0)
    )
    assert "referenceLayerIndex.value" in fixed_reference_model_block.group(0)
    assert "layers[layerIndex]" not in fixed_reference_model_block.group(0)
    assert "layerInputs[layerIndex]" not in fixed_reference_model_block.group(0)
    tflite_reference_model_block = re.search(
        r"^proc blaiReferenceTfliteParsedModel2d\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],\n"
        r"    useTflite: bool,\n"
        r"    input: openArray\[uint8\],\n"
        r"    layerInputs: openArray\[BlaiReferenceTfliteParsedModelInput\],"
        r".*?(?=^proc blaiReferenceTfliteParsedModel2d\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],\n"
        r"    useTflite: bool,\n"
        r"    input: openArray\[uint8\],\n"
        r"    cpuWeightBytes: openArray\[uint8\],)",
        npu_source,
        re.S | re.M,
    )
    assert tflite_reference_model_block is not None
    assert "let layerCursor = blaiRecoveredLayerCursor(layerIndex.uint32, layers.len)" in (
        tflite_reference_model_block.group(0)
    )
    assert "let layerState = layers[layerCursor.index]" in (
        tflite_reference_model_block.group(0)
    )
    assert "let referenceLayerIndex = blaiLayerCursorIndexAbi(layerCursor.index)" in (
        tflite_reference_model_block.group(0)
    )
    assert "layerInputs[layerCursor.index].secondInput" in (
        tflite_reference_model_block.group(0)
    )
    assert "referenceLayerIndex.value" in tflite_reference_model_block.group(0)
    assert "layers[layerIndex]" not in tflite_reference_model_block.group(0)
    assert "layerInputs[layerIndex]" not in tflite_reference_model_block.group(0)
    parsed_cpu_stream_totals_block = re.search(
        r"^proc blaiCpuStreamTotalsInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiCpuStreamTotals\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    fixed_buffer_plan_block = re.search(
        r"^proc blaiReferenceFixedParsedBufferPlanInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiReferenceFixedParsedBufferPlan\*\()",
        npu_source,
        re.S | re.M,
    )
    tflite_buffer_plan_block = re.search(
        r"^proc blaiReferenceTfliteParsedBufferPlanInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiReferenceTfliteParsedBufferPlan\*\()",
        npu_source,
        re.S | re.M,
    )
    assert parsed_cpu_stream_totals_block is not None
    assert fixed_buffer_plan_block is not None
    assert tflite_buffer_plan_block is not None
    for parsed_layer_scan_block in (
        parsed_cpu_stream_totals_block.group(0),
        fixed_buffer_plan_block.group(0),
        tflite_buffer_plan_block.group(0),
    ):
        assert "let layerCursor = blaiRecoveredLayerCursor(layerIndex.uint32, layers.len)" in (
            parsed_layer_scan_block
        )
        assert "let layerState = layers[layerCursor.index]" in parsed_layer_scan_block
        assert "layers[layerIndex]" not in parsed_layer_scan_block
    for buffer_plan_block in (
        fixed_buffer_plan_block.group(0),
        tflite_buffer_plan_block.group(0),
    ):
        assert "let firstActiveCursor =" in buffer_plan_block
        assert "blaiRecoveredLayerCursor(firstActive.uint32, layers.len)" in (
            buffer_plan_block
        )
        assert "let firstLayer = layers[firstActiveCursor.index].layer" in (
            buffer_plan_block
        )
        assert "layers[firstActive]" not in buffer_plan_block
        assert "layers[i]" not in buffer_plan_block
    cpu_layer_search_blocks = re.findall(
        r"^proc blaiFindNextCpu(?:Weight|Bias)Layer\*\(.*?(?=^proc )",
        npu_source,
        re.S | re.M,
    )
    assert len(cpu_layer_search_blocks) >= 4
    for cpu_layer_search_block in cpu_layer_search_blocks[:4]:
        assert "let layerCursor = blaiRecoveredLayerCursor(i.uint32, layers.len)" in (
            cpu_layer_search_block
        )
        assert "layers[layerCursor.index]" in cpu_layer_search_block
        assert "layers[i]" not in cpu_layer_search_block
    last_active_layer_block = re.search(
        r"^proc blaiLastActiveParsedLayerIndex\(layers: openArray\[BlaiCpuParsedLayerState\]\): int32 ="
        r".*?(?=^proc blaiParsedModelFailure\()",
        npu_source,
        re.S | re.M,
    )
    assert last_active_layer_block is not None
    assert "let layerCursor = blaiRecoveredLayerCursor(i.uint32, layers.len)" in (
        last_active_layer_block.group(0)
    )
    assert "layers[layerCursor.index]" in last_active_layer_block.group(0)
    assert "layers[i]" not in last_active_layer_block.group(0)
    forward_model_resources_block = re.search(
        r"^proc blaiPlanForwardModelResourcesInto\*\(layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiPlanForwardModelResources\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_forward_model_resources_block = re.search(
        r"^proc blaiPlanForwardModelResourcesInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiPlanForwardModelResources\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert forward_model_resources_block is not None
    assert parsed_forward_model_resources_block is not None
    assert "BlaiForwardModelLayerWindow* = object" in npu_source
    assert "BlaiForwardModelLayerCursor* = object" in npu_source
    assert "proc blaiForwardModelLayerWindow*(capacity: int)" in npu_source
    assert "proc blaiForwardModelLayerCursor*(\n    window: BlaiForwardModelLayerWindow" in npu_source
    assert "forwardModelLayerCursor.layerIndex == 2" in npu_source
    for forward_model_resource_block in (
        forward_model_resources_block.group(0),
        parsed_forward_model_resources_block.group(0),
    ):
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            forward_model_resource_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            forward_model_resource_block
        )
        assert "forwardLayerIndex.value" in forward_model_resource_block or (
            "layerState.index" in forward_model_resource_block
        )
        assert "layers[layerIndex]" not in forward_model_resource_block
        assert "layerIndex.uint32" not in forward_model_resource_block
    assert "let forwardLayerIndex = blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
        forward_model_resources_block.group(0)
    )
    weight_workspace_blocks = re.findall(
        r"^proc blaiMaterializeForwardModelWeightsInWorkspaceInto\*\(.*?"
        r"(?=^proc blaiMaterializeForwardModelWeightsInWorkspace\*)",
        npu_source,
        re.S | re.M,
    )
    assert len(weight_workspace_blocks) >= 2
    for weight_workspace_block in weight_workspace_blocks[:2]:
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            weight_workspace_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            weight_workspace_block
        )
        assert "blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in weight_workspace_block
        assert "workspaceLayerIndex.value" in weight_workspace_block
        assert "layerIndex.uint32" not in weight_workspace_block
        assert "layers[layerIndex]" not in weight_workspace_block
    workspace_materialize_blocks = re.findall(
        r"^proc blaiMaterializeForwardModelWorkspaceInto\*\(.*?"
        r"(?=^proc blaiMaterializeForwardModelWorkspace\*)",
        npu_source,
        re.S | re.M,
    )
    assert len(workspace_materialize_blocks) >= 2
    for workspace_materialize_block in workspace_materialize_blocks[:2]:
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            workspace_materialize_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            workspace_materialize_block
        )
        assert "blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in workspace_materialize_block
        assert "materializeLayerIndex.value" in workspace_materialize_block
        assert "layerIndex.uint32" not in workspace_materialize_block
        assert "layers[layerIndex]" not in workspace_materialize_block
    raw_workspace_prepare_block = re.search(
        r"^proc blaiPrepareForwardModelInWorkspaceInto\*\(\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiPrepareForwardModelInWorkspaceInto\*\(\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_workspace_prepare_block = re.search(
        r"^proc blaiPrepareForwardModelInWorkspaceInto\*\(\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiPrepareForwardModelInWorkspace\*\(\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    assert raw_workspace_prepare_block is not None
    assert parsed_workspace_prepare_block is not None
    for workspace_prepare_block in (
        raw_workspace_prepare_block.group(0),
        parsed_workspace_prepare_block.group(0),
    ):
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            workspace_prepare_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            workspace_prepare_block
        )
        assert "let prepareLayerIndex = blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
            workspace_prepare_block
        )
        assert "prepareLayerIndex.value" in workspace_prepare_block
        assert "layerIndex.uint32" not in workspace_prepare_block
        assert "layers[layerIndex]" not in workspace_prepare_block
    raw_run_sequence_block = re.search(
        r"^proc blaiPlanForwardModelRunSequenceInto\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiPlanForwardModelRunSequence\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_run_sequence_block = re.search(
        r"^proc blaiPlanForwardModelRunSequenceInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiPlanForwardModelRunSequence\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert raw_run_sequence_block is not None
    assert parsed_run_sequence_block is not None
    for run_sequence_block in (
        raw_run_sequence_block.group(0),
        parsed_run_sequence_block.group(0),
    ):
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            run_sequence_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            run_sequence_block
        )
        assert "layerIndex.uint32" not in run_sequence_block
        assert "layers[layerIndex]" not in run_sequence_block
    assert "let runSequenceLayerIndex =\n      blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
        raw_run_sequence_block.group(0)
    )
    assert "runSequenceLayerIndex.value" in raw_run_sequence_block.group(0)
    assert "let layerState = layers[layerCursor.layerIndex]" in (
        parsed_run_sequence_block.group(0)
    )
    assert "layerState.index" in parsed_run_sequence_block.group(0)
    raw_execute_sequence_block = re.search(
        r"^proc blaiExecuteForwardModelRunSequenceInto\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiExecuteForwardModelRunSequence\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_execute_sequence_block = re.search(
        r"^proc blaiExecuteForwardModelRunSequenceInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiExecuteForwardModelRunSequence\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert raw_execute_sequence_block is not None
    assert parsed_execute_sequence_block is not None
    for execute_sequence_block in (
        raw_execute_sequence_block.group(0),
        parsed_execute_sequence_block.group(0),
    ):
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            execute_sequence_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            execute_sequence_block
        )
        assert "let executeLayerIndex = blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
            execute_sequence_block
        )
        assert "executor(runPlan, executeLayerIndex.value)" in execute_sequence_block
        assert "executor(runPlan, layerIndex.uint32)" not in execute_sequence_block
        assert "layers[layerIndex]" not in execute_sequence_block
    assert "layers[layerIndex], layerIndex.uint32" not in (
        raw_execute_sequence_block.group(0)
    )
    raw_configured_execute_block = re.search(
        r"^proc blaiExecuteForwardModelConfiguredInto\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiExecuteForwardModelConfigured\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_configured_execute_block = re.search(
        r"^proc blaiExecuteForwardModelConfiguredInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiExecuteForwardModelConfigured\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert raw_configured_execute_block is not None
    assert parsed_configured_execute_block is not None
    for configured_execute_block in (
        raw_configured_execute_block.group(0),
        parsed_configured_execute_block.group(0),
    ):
        assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
            configured_execute_block
        )
        assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
            configured_execute_block
        )
        assert "layers[layerIndex]" not in configured_execute_block
        assert "layerIndex.uint32" not in configured_execute_block
    assert "let configuredLayerIndex =\n      blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
        raw_configured_execute_block.group(0)
    )
    assert "configuredLayerIndex.value" in raw_configured_execute_block.group(0)
    assert "let layerState = layers[layerCursor.layerIndex]" in (
        parsed_configured_execute_block.group(0)
    )
    assert "layerState.index" in parsed_configured_execute_block.group(0)
    explicit_buffer_configured_execute_block = re.search(
        r"^proc blaiExecuteForwardModelConfiguredWithLayerBuffersInto\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiExecuteForwardModelConfiguredWithLayerBuffers\*\(\n"
        r"    layers: openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert explicit_buffer_configured_execute_block is not None
    assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
        explicit_buffer_configured_execute_block.group(0)
    )
    assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
        explicit_buffer_configured_execute_block.group(0)
    )
    assert "let layerState = layers[layerCursor.layerIndex]" in (
        explicit_buffer_configured_execute_block.group(0)
    )
    assert "layerState.index" in explicit_buffer_configured_execute_block.group(0)
    assert "layers[layerIndex]" not in explicit_buffer_configured_execute_block.group(0)
    raw_materialize_execute_block = re.search(
        r"^proc blaiMaterializeAndExecuteForwardModelWorkspaceInto\*\(\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiMaterializeAndExecuteForwardModelWorkspace\*\(\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    parsed_materialize_execute_block = re.search(
        r"^proc blaiMaterializeAndExecuteParsedForwardModelWorkspaceInto\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiMaterializeAndExecuteParsedForwardModelWorkspace\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert raw_materialize_execute_block is not None
    assert parsed_materialize_execute_block is not None
    assert "let layerWindow = blaiForwardModelLayerWindow(layers.len)" in (
        raw_materialize_execute_block.group(0)
    )
    assert "let layerCursor = blaiForwardModelLayerCursor(layerWindow, layerIndex)" in (
        raw_materialize_execute_block.group(0)
    )
    assert "blaiLayerCursorIndexAbi(layerCursor.layerIndex)" in (
        raw_materialize_execute_block.group(0)
    )
    assert "layers[layerIndex]" not in raw_materialize_execute_block.group(0)
    parsed_raw_materialize_wrapper = re.search(
        r"^proc blaiMaterializeAndExecuteParsedForwardModelWorkspaceInto\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiMaterializeAndExecuteParsedForwardModelWorkspace\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    assert parsed_raw_materialize_wrapper is not None
    assert "blaiParsedForwardLayerWindow(" in parsed_raw_materialize_wrapper.group(0)
    assert (
        "layers.toOpenArray(layerWindow.startIndex, layerWindow.stopIndex)"
        in parsed_raw_materialize_wrapper.group(0)
    )
    assert "layers.toOpenArray(0, layerCount - 1)" not in (
        parsed_raw_materialize_wrapper.group(0)
    )
    parsed_state_materialize_wrapper = re.search(
        r"^proc blaiMaterializeAndExecuteParsedForwardModelWorkspaceInto\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],"
        r".*?(?=^proc blaiMaterializeAndExecuteParsedForwardModelWorkspace\*\(\n"
        r"    parsed: BlaiCpuModelParseResult,\n"
        r"    layers: var openArray\[BlaiCpuParsedLayerState\],)",
        npu_source,
        re.S | re.M,
    )
    assert parsed_state_materialize_wrapper is not None
    assert "let layerWindow = blaiParsedForwardLayerWindow(" in (
        parsed_state_materialize_wrapper.group(0)
    )
    assert "let layerCursor = blaiParsedForwardLayerCursor(" in (
        parsed_state_materialize_wrapper.group(0)
    )
    assert "let layerState = layers[layerCursor.layerIndex]" in (
        parsed_state_materialize_wrapper.group(0)
    )
    assert "layers[layerIndex]" not in parsed_state_materialize_wrapper.group(0)
    for materialize_execute_cursor_block in (
        raw_materialize_execute_block.group(0),
        parsed_materialize_execute_block.group(0),
    ):
        assert (
            "let materializeExecuteLayerIndex =\n"
            "      blaiLayerCursorIndexAbi(layerCursor.layerIndex)"
            in materialize_execute_cursor_block
        )
    for materialize_execute_block in (
        raw_materialize_execute_block.group(0),
        parsed_materialize_execute_block.group(0),
    ):
        assert "materializeExecuteLayerIndex.value" in materialize_execute_block
        assert "executor(runPlan, materializeExecuteLayerIndex.value)" in (
            materialize_execute_block
        )
        assert "executor(runPlan, layerIndex.uint32)" not in materialize_execute_block
        assert "layers, layerIndex.uint32" not in materialize_execute_block
    assert "proc blaiAppendReleaseLayer(layer: var BlaiCpuInstLayer64,\n                            releasedLayer: int," in npu_source
    assert "BlaiReleaseLayerTableWindow* = object" in npu_source
    assert "BlaiReleaseLayerTableCursor* = object" in npu_source
    assert "proc blaiReleaseLayerTableWindow*(\n    layerCount: int)" in npu_source
    assert "proc blaiReleaseLayerTableCursor*(\n    window: BlaiReleaseLayerTableWindow" in npu_source
    assert "releaseLayerCursor.layerIndex == 2" in npu_source
    release_assignment_blocks = re.findall(
        r"^proc blaiAssignReleaseLayers\*\(.*?(?=^proc )",
        npu_source,
        re.S | re.M,
    )
    assert len(release_assignment_blocks) >= 2
    for release_assignment_block in release_assignment_blocks[:2]:
        assert "layerIndex.uint32" not in release_assignment_block
        assert "let layerWindow = blaiReleaseLayerTableWindow(layers.len)" in (
            release_assignment_block
        )
        assert "let layerCursor = blaiReleaseLayerTableCursor(layerWindow, layerIndex)" in (
            release_assignment_block
        )
        assert "let releaseCursor = blaiReleaseLayerTableCursor(layerWindow, releaseLayer)" in (
            release_assignment_block
        )
        assert "layers[layerIndex]" not in release_assignment_block
        assert "layers.high" not in release_assignment_block
    npu_release_plan_block = re.search(
        r"^proc blaiNpuReleasePlanInto\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],"
        r".*?(?=^proc blaiNpuReleasePlan\*\(\n"
        r"    layers: openArray\[BlaiCpuInstLayer64\],)",
        npu_source,
        re.S | re.M,
    )
    assert npu_release_plan_block is not None
    assert "let layerWindow = blaiReleaseLayerTableWindow(layerCount.count)" in (
        npu_release_plan_block.group(0)
    )
    assert "let layerCursor = blaiReleaseLayerTableCursor(layerWindow, layerIndex)" in (
        npu_release_plan_block.group(0)
    )
    assert "layers[layerCursor.layerIndex]" in npu_release_plan_block.group(0)
    assert "cnAllocated[layerCursor.layerIndex]" in npu_release_plan_block.group(0)
    assert "layers[layerIndex]" not in npu_release_plan_block.group(0)
    assert "result.firstReleaseOverflowLayer = releaseLayer.int32" not in npu_source
    assert "result.firstReleaseOverflowLayer = releaseMidLayer.int32" not in npu_source
    assert "result.firstGraphMapOverflowLayer = layerIndex.int32" not in npu_source
    assert "graphLayerToLayer[graph0Cursor.mapIndex] = layerIndex.int32" not in npu_source
    assert "graphLayerToLayer[graph1Cursor.mapIndex] = layerIndex.int32" not in npu_source
    assert "stagedLayer.c = step.descriptorC1.int32" not in npu_source
    assert "stagedLayer.c = blaiRouteDescriptorChannelValue(" not in npu_source
    assert "outResult.lastReadyLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstUnencodedLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstBlockedLayer = layerIndex.int32" not in npu_source
    assert "outResult.lastStoredLayer = layerIndex.int32" not in npu_source
    assert "outResult.lastConfigurableLayer = layerIndex.int32" not in npu_source
    assert "outResult.lastMaterializedLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstFailedLayer = layerIndex.int32" not in npu_source
    assert "outResult.lastCompletedLayer = layerIndex.int32" not in npu_source
    assert "outResult.execution.firstBlockedLayer = layerIndex.int32" not in npu_source
    assert "outResult.execution.lastMaterializedLayer = layerIndex.int32" not in npu_source
    assert "outResult.execution.firstFailedLayer = layerIndex.int32" not in npu_source
    assert "outResult.execution.lastCompletedLayer = layerIndex.int32" not in npu_source
    assert "result.firstFailedLayer = layerIndex.int32" not in npu_source
    assert "result.lastCompletedLayer = layerIndex.int32" not in npu_source
    assert "weightPlan.layerIndex = layerIndex.int32" not in npu_source
    assert "biasPlan.layerIndex = layerIndex.int32" not in npu_source
    assert "weightCursor.layerIndex <= layerIndex.int32" not in npu_source
    assert "biasCursor.layerIndex <= layerIndex.int32" not in npu_source
    assert "nextWeightCursor.layerIndex = layerIndex.int32" not in npu_source
    assert "nextBiasCursor.layerIndex = layerIndex.int32" not in npu_source
    assert "plan.layerIndex == layerIndex.int32" not in npu_source
    assert "layerIndex.int32 == lastActive" not in npu_source
    assert "outResult.firstMismatch = index.int32" not in npu_source
    assert "outResult.firstMismatch = compared.int32" not in npu_source
    assert "layer.layerType == ord(blaiConvMax).int32" not in npu_source
    assert "layer.layerType == ord(blaiRouteMax).int32" not in npu_source
    assert "layer.layerType == ord(blaiRouteConv).int32" not in npu_source
    assert "layer.layerType == ord(blaiRouteUpsample).int32" not in npu_source
    assert "layer.activation == ord(blaiActLinear).int32" not in npu_source
    assert "biases[i] = cast[int32](value)" not in npu_source
    assert "outResult.firstWeightLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstBiasLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstUnsupportedActivationShapeLayer = firstActive.int32" not in npu_source
    assert "outResult.firstUnsupportedActivationShapeLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstUnsupportedWeightStorageLayer = layerIndex.int32" not in npu_source
    assert "outResult.firstMalformedRecord = recordIndex.int32" not in npu_source
    assert "outResult.firstUnsupportedRecord = recordIndex.int32" not in npu_source
    assert "layer.outW = outputW.int32" not in npu_source
    assert "layer.outH = outputH.int32" not in npu_source
    assert "layer.outC = outputC.int32" not in npu_source
    assert "layer.size = kernelSize.int32" not in npu_source
    assert "let classesAbi = blaiCpuYoloInfoFieldAbi(decoded.classes)" in npu_source
    assert "let totalAbi = blaiCpuYoloInfoFieldAbi(decoded.total)" in npu_source
    assert "layer.classes = classesAbi.value" in npu_source
    assert "layer.total = totalAbi.value" in npu_source
    assert "storage.mask[entryIndex] = entry.mask.int32" not in npu_source
    assert "entry.biasW.int32" not in npu_source
    assert "entry.biasH.int32" not in npu_source
    assert "let maxClassesAbi = blaiCpuSsdInfoFieldAbi(decoded.maxClassesPerDetection)" in npu_source
    assert "layer.maxClassesPerDetection = maxClassesAbi.value" in npu_source
    assert "layer.classes = decoded.classes.int32" not in npu_source
    assert "layer.maxClassesPerDetection = decoded.maxClassesPerDetection.int32" not in npu_source
    assert "layer.maxDetections = decoded.maxDetections.int32" not in npu_source
    assert "layer.anchorsOffset = decoded.anchorsOffset.int32" not in npu_source
    assert "let routeMultiplierAbi = blaiCpuTfliteRouteMultiplierAbi(" in npu_source
    assert "decoded.routeInputMultiplierLow.int32" not in npu_source
    assert "layer.w = blaiBits(inst, 5, 14).int32" not in npu_source
    assert "layer.h = blaiBits(inst, 19, 14).int32" not in npu_source
    assert "layer.c = blaiBits(inst, 33, 13).int32" not in npu_source
    assert "layer.outC = blaiBits(inst, 59, 13).int32" not in npu_source
    assert "layer.inputNum = blaiBits(inst, 94, 4).int32" not in npu_source
    assert "layer.outW = blaiBits(inst, 98, 14).int32" not in npu_source
    assert "layer.cn[0] = if layer.inputNum > 1: blaiBits(inst, 46, 13).int32 else: 0" not in npu_source
    assert "layer.layerType = blaiBits(inst, 5, 5).int32" not in npu_source
    assert "layer.stride = (blaiBits(inst, 20, 3) + 1).int32" not in npu_source
    assert "layer.groups = blaiBits(inst, 26, 12).int32" not in npu_source
    assert "layer.fdata = blaiBits(inst, 38, 5).int32" not in npu_source
    assert "layer.tfInput1Offset = blaiBits(inst, 38, 8).int32" not in npu_source
    assert "layer.quantizedActivationMin = blaiBits(inst, 80, 8).int32" not in npu_source
    assert "layer.tfRouteInputMultiplier = (blaiBits(inst, 103, 16) shl 16).int32" not in npu_source
    assert "layer.sizeX = blaiBits(inst, 5, 10).int32" not in npu_source
    assert "layer.sizeY = blaiBits(inst, 15, 10).int32" not in npu_source
    assert "layer.strideX = blaiBits(inst, 25, 3).int32" not in npu_source
    assert "layer.strideY = blaiBits(inst, 28, 3).int32" not in npu_source
    assert "layer.paddingX = blaiBits(inst, 31, 9).int32" not in npu_source
    assert "layer.paddingY = blaiBits(inst, 40, 9).int32" not in npu_source
    assert "layer.inputNum = status.inputNum.int32" not in npu_source
    assert "BlaiCpuInputLayersBits).int32" not in npu_source
    assert "layer.graphLayer[0] = layerIndex.int32 + layer.layerOffset" not in npu_source
    assert "cast[int32](multiplier)" not in npu_source
    assert "layer.tfInput1Multiplier = cast[int32](decoded.input1Multiplier)" not in npu_source
    assert "layer.tfInput2Multiplier = cast[int32](decoded.input2Multiplier)" not in npu_source
    assert "layer.tfOutputMultiplier = cast[int32](decoded.outputMultiplier)" not in npu_source
    assert "proc blaiReferenceInputSampleValue*(sample: int8" in npu_source
    assert npu_source.count("blaiReferenceInputSampleValue(") >= 6
    assert "sample, plan.firstLayerUnsignedInput)" in npu_source
    assert "input[inputHwc.index.int], plan.firstLayerUnsignedInput)" in npu_source
    assert "cast[uint8](sample).int32" not in npu_source
    assert "cast[uint8](input[inputIndex.int]).int32" not in npu_source
    assert "input.channels.int32" not in npu_source
    assert "input.inLayerMemN.int32" not in npu_source
    assert "input.tfInputOffset.int32" not in npu_source
    assert "input.routeFrac.int32" not in npu_source
    assert "elementCount.int" not in npu_source
    assert "streamBytes.int" not in npu_source
    assert "settleReadCount.int" not in npu_source
    assert "proc blaiForwardWeightByteCountCursor*(byteCount: uint32" in npu_source
    assert "proc blaiForwardBiasWordCountCursor*(biasCount: uint32" in npu_source
    assert "weightByteCount.int" not in npu_source
    assert "biasCount.int" not in npu_source
    assert "expectedWeightByteCount.int" not in npu_source
    assert "expectedBiasByteCount.int" not in npu_source
    assert "weightBuf[weightCursor.int]" not in npu_source
    assert "weightsIn[sourceIndex.int]" not in npu_source
    assert "biasBuf[biasCursor.int]" not in npu_source
    assert "biasesIn[outChannel.int]" not in npu_source
    assert "temporaryWeights[destIndex.int]" not in npu_source
    assert "dramBiasCount * BlaiNpuBiasElementBytes" not in npu_source
    assert "if not blaiBiasWordCountBytes(dramBiasCount, outResult.biasBytes):" in npu_source
    assert (
        "high(uint32), outResult.alignedWeightBytes, outResult.biasBytes, totalFit"
        in npu_source
    )


def test_manifest_recovered_weight_schedule_summaries_match_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    weight_types = set(
        manifest["recovered_weight_buffer_planning"]["additional_nim_types"]
    )
    weight_procs = set(manifest["recovered_weight_buffer_planning"]["nim_procs"])

    assert "BlaiNpuWeightScheduleSummary" in weight_types
    assert "blaiNpuWeightScheduleSummary" in weight_procs
    for schedule, pixels, zeros, max_tap in (
        ("BlaiNpuWeight3x3DilatedSchedule", 9, 72, 8),
        ("BlaiNpuWeight5x5Schedule", 25, 56, 24),
        ("BlaiNpuWeight7x7Schedule", 49, 32, 48),
    ):
        assert schedule in npu_source
        assert (
            f"expectedPixelOps = {pixels}, expectedZeroTileUnits = {zeros}, "
            f"expectedMaxPixelTap = {max_tap}"
        ) in npu_source
    assert npu_source.count("doAssert schedule") >= 6


def test_manifest_recovered_packed_weight_size_plan_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    weight_types = set(
        manifest["recovered_weight_buffer_planning"]["additional_nim_types"]
    )
    weight_procs = set(manifest["recovered_weight_buffer_planning"]["nim_procs"])

    assert "BlaiNpuPackedWeightSizePlan" in weight_types
    assert "blaiPlanNpuPackedWeightSizeInto" in weight_procs
    assert "blaiPlanNpuPackedWeightSize" in weight_procs
    assert "proc blaiNpuPackedWeightBytes*" in npu_source
    assert "let plan = blaiPlanNpuPackedWeightSize(layer, useTflite, pack)" in npu_source
    for assertion in (
        "doAssert tinyPackedSizePlan.totalBytes == 16",
        "doAssert groupedPackedSizePlan.inputTileGroups == 8",
        "doAssert groupedPackedSizePlan.totalBytes == 288",
    ):
        assert assertion in npu_source


def test_manifest_recovered_weight_channel_range_plan_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    weight_types = set(
        manifest["recovered_weight_buffer_planning"]["additional_nim_types"]
    )
    weight_procs = set(manifest["recovered_weight_buffer_planning"]["nim_procs"])

    assert "BlaiNpuWeightGroupPartition" in weight_types
    assert "BlaiNpuWeightChannelRangePlan" in weight_types
    assert "blaiNpuWeightGroupPartition" in weight_procs
    assert "blaiPlanNpuWeightChannelRangeInto" in weight_procs
    assert "blaiPlanNpuWeightChannelRange" in weight_procs
    assert "proc blaiNpuWeightChannelRange*" in npu_source
    assert "let rangePlan = blaiPlanNpuWeightChannelRange(plan, outIn)" in npu_source
    assert "let partition = blaiNpuWeightGroupPartition(" in npu_source
    assert "outResult.outputsPerGroup = partition.outputsPerGroup" in npu_source
    channel_range_block = re.search(
        r"proc blaiPlanNpuWeightChannelRangeInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert channel_range_block is not None
    assert "plan.outputChannels div outResult.groups" not in channel_range_block.group(0)
    assert "plan.effectiveInputChannels div outResult.groups" not in (
        channel_range_block.group(0)
    )
    assert "outIn div outResult.outputsPerGroup" not in channel_range_block.group(0)
    for assertion in (
        "doAssert groupedFirstPartition.outputsPerGroup == 4",
        "doAssert groupedFirstRangePlan.outputsPerGroup == 4",
        "doAssert groupedSecondRangePlan.groupIndex == 1",
        "doAssert ungroupedRangePlan.cEnd == dispatchPlan.effectiveInputChannels",
    ):
        assert assertion in npu_source


def test_manifest_recovered_temporary_group_plan_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    weight_types = set(
        manifest["recovered_weight_buffer_planning"]["additional_nim_types"]
    )
    weight_procs = set(manifest["recovered_weight_buffer_planning"]["nim_procs"])

    assert "BlaiNpuTemporaryGroupPlan" in weight_types
    assert "BlaiNpuWeightSourceProjection" in weight_types
    assert "BlaiNpuWeightPackAlignment" in weight_types
    assert "BlaiNpuWeightPackEntryCursor" in weight_types
    assert "BlaiNpuBiasPackCursor" in weight_types
    assert "BlaiNpuBiasPackEntryCursor" in weight_types
    assert "BlaiNpuTemporaryGroupSourceCursor" in weight_types
    assert "blaiPlanNpuTemporaryGroupsInto" in weight_procs
    assert "blaiPlanNpuTemporaryGroups" in weight_procs
    assert "blaiNpuTemporaryGroupSourceCursor" in weight_procs
    assert "blaiNpuWeightSourceProjection" in weight_procs
    assert "blaiNpuWeightPackAlignment" in weight_procs
    assert "blaiNpuWeightPackEntryCursor" in weight_procs
    assert "blaiNpuBiasPackCursor" in weight_procs
    assert "blaiNpuBiasPackEntryCursor" in weight_procs
    assert "BlaiNpuWeightPackAlignment* = object" in npu_source
    assert "BlaiNpuWeightPackEntryCursor* = object" in npu_source
    assert "let alignment = blaiNpuWeightPackAlignment(outIn, cin, pack)" in npu_source
    assert "if not alignment.valid:" in npu_source
    assert "if not alignment.aligned:" in npu_source
    assert "let entryCursor = blaiNpuWeightPackEntryCursor(" in npu_source
    assert "entryCursor.inputChannel" in npu_source
    assert "BlaiNpuBiasPackCursor* = object" in npu_source
    assert "BlaiNpuBiasPackEntryCursor* = object" in npu_source
    assert "let biasPackCursor = blaiNpuBiasPackCursor(outIn, plan.biasPack)" in npu_source
    assert "if not biasPackCursor.aligned:" in npu_source
    assert "let entryCursor = blaiNpuBiasPackEntryCursor(" in npu_source
    assert "entryCursor.outChannel" in npu_source
    assert "BlaiNpuWeightSourceProjection* = object" in npu_source
    assert "BlaiNpuTemporaryGroupSourceCursor* = object" in npu_source
    assert (
        "blaiRowMajorIndex(outChannel, inputOffset, inputChannelsPerGroup)"
        in npu_source
    )
    assert "blaiRowMajorIndex(channelIndex.index, weightTap, kernelTaps)" in npu_source
    assert "let groupPlan = blaiPlanNpuTemporaryGroups(layer, plan, pack)" in npu_source
    assert "let destProjection = blaiNpuWeightSourceProjection(" in npu_source
    assert "let groupSource = blaiNpuTemporaryGroupSourceCursor(" in npu_source
    assert "if groupSource.sameOriginalGroup:" in npu_source
    assert (
        "let sourceProjection =\n            blaiNpuWeightSourceProjection("
        in npu_source
    )
    assert "inputChannels div groupCount) * outIn" not in npu_source
    assert "groupPlan.originalInputsPerGroup * outIn" not in npu_source
    assert "if outIn mod pack != 0'u32 or cin mod pack != 0'u32:" not in npu_source
    assert "if outIn mod pack == 0'u32 and cin mod pack == 0'u32:" not in npu_source
    assert "let outChannel = outIn + outOffset" not in npu_source
    assert "let inputChannel = cin + inOffset" not in npu_source
    assert "outIn mod plan.biasPack" not in npu_source
    assert "let outChannel = outIn + biasOffset" not in npu_source
    assert "let inputOffset =\n          (cin - channelRange.cStart) mod groupPlan.originalInputsPerGroup" not in npu_source
    assert "let outputGroup = outIn div groupPlan.originalOutputsPerGroup" not in npu_source
    assert "let inputGroup = cin div groupPlan.originalInputsPerGroup" not in npu_source
    assert "groupPlan.kernelTaps) + weightTap" not in npu_source
    for assertion in (
        "doAssert tempGroupPlan.originalGroups == 4",
        "doAssert tempGroupPlan.temporaryGroups == 2",
        "doAssert tempGroupPlan.kernelTaps == 9",
        "doAssert sameTempGroupSource.sameOriginalGroup",
        "doAssert not crossTempGroupSource.sameOriginalGroup",
    ):
        assert assertion in npu_source


def test_manifest_recovered_weight_materialize_readiness_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    weight_types = set(
        manifest["recovered_weight_buffer_planning"]["additional_nim_types"]
    )
    weight_procs = set(manifest["recovered_weight_buffer_planning"]["nim_procs"])

    assert "BlaiNpuWeightMaterializeBlock" in weight_types
    assert "BlaiNpuWeightMaterializeReadiness" in weight_types
    assert "blaiNpuWeightMaterializeReadinessInto" in weight_procs
    assert "blaiNpuWeightMaterializeReadiness" in weight_procs
    assert "outResult.firstBlock = outResult.readiness.firstBlock" in npu_source
    for assertion in (
        "doAssert materialized.firstBlock == blaiNpuWeightMaterializeNoBlock",
        "doAssert tempMaterialized.firstBlock == blaiNpuWeightMaterializeNoBlock",
        "doAssert shortMaterialized.firstBlock == blaiNpuWeightMaterializeBuffer",
    ):
        assert assertion in npu_source


def test_manifest_recovered_forward_resource_fit_first_block_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    forward_types = set(manifest["recovered_forward_npu_planning"]["nim_types"])
    forward_procs = set(manifest["recovered_forward_npu_planning"]["nim_procs"])

    assert "BlaiForwardResourceFitBlock" in forward_types
    assert "BlaiForwardResourceFitReadiness" in forward_types
    assert "blaiForwardResourceFitReadinessInto" in forward_procs
    assert "outResult.firstBlock = outResult.readiness.firstBlock" in npu_source
    for assertion in (
        "doAssert forwardResourceFitInto.firstBlock ==",
        "doAssert shortInstructionResourceFit.firstBlock ==",
        "doAssert shortDataResourceFit.firstBlock == blaiForwardResourceData",
        "doAssert shortTemporaryResourceFit.firstBlock ==",
    ):
        assert assertion in npu_source


def test_manifest_recovered_forward_tensor_io_first_block_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    forward_types = set(manifest["recovered_forward_npu_planning"]["nim_types"])
    forward_procs = set(manifest["recovered_forward_npu_planning"]["nim_procs"])

    assert "BlaiForwardTensorIoBlock" in forward_types
    assert "BlaiForwardTensorIoReadiness" in forward_types
    assert "blaiForwardTensorIoReadinessInto" in forward_procs
    for assertion in (
        "doAssert stagedForwardInput.readiness.firstBlock ==",
        "doAssert shortStagedForwardInput.readiness.firstBlock ==",
        "doAssert smallBufferForwardInput.readiness.firstBlock ==",
        "doAssert loadedShortForwardOutput.readiness.firstBlock ==",
    ):
        assert assertion in npu_source


def test_manifest_recovered_workspace_segment_fit_first_block_matches_nim_source():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    forward_types = set(manifest["recovered_forward_npu_planning"]["nim_types"])
    forward_procs = set(manifest["recovered_forward_npu_planning"]["nim_procs"])

    assert "BlaiForwardWorkspaceSegmentFitBlock" in forward_types
    assert "BlaiForwardWorkspaceSegmentFitResult" in forward_types
    assert "blaiForwardWorkspaceSegmentFitsInto" in forward_procs
    for assertion in (
        "doAssert modelWorkspaceSegmentFit.firstBlock ==",
        "doAssert shortWorkspaceSegmentFit.firstBlock ==",
        "doAssert inactiveWorkspaceSegmentFit.firstBlock ==",
    ):
        assert assertion in npu_source


def test_npu_register_manifest_offsets_have_static_overlay_assertions():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")

    assert "template blaiMmioBlock*[T](base: untyped): ptr T" in npu_source
    assert "cast[ptr T](base)" in npu_source
    assert npu_source.count("cast[ptr") == 1
    assert "proc blaiLoadReg*(reg: var uint32): uint32" in npu_source
    assert "proc blaiStoreReg*(reg: var uint32, value: uint32)" in npu_source
    assert "volatileLoad(addr reg)" in npu_source
    assert "volatileStore(addr reg, value)" in npu_source
    assert npu_source.count("volatileLoad(addr") == 1
    assert npu_source.count("volatileStore(addr") == 1
    assert "template loadReg" not in npu_source
    assert "template storeReg" not in npu_source
    assert "loadReg(" not in npu_source
    assert "storeReg(" not in npu_source
    assert "proc blaiRawByteAddress(byte: var uint8): uint" in npu_source
    assert "cast[uint](unsafeAddr byte)" in npu_source
    assert "blaiProjectHardwareAddress(blaiRawByteAddress(buffer[0]))" in npu_source
    assert npu_source.count("unsafeAddr") == 1
    assert npu_source.count("cast[uint](unsafeAddr") == 1
    assert "NpuActivationTableWordCursor" in (
        manifest["execution_status"]["typed_status"]
    )
    assert "BlaiFtableIndexBaseReset* = 0x05'u32" in npu_source
    assert "BlaiFtableDataBaseReset* = 0x07'u32" in npu_source
    assert "BlaiGeneralCfgKnownMask* =" in npu_source
    assert "NpuGeneralCfgDefaultEvidence* = object" in npu_source
    assert "proc npuGeneralCfgDefaultEvidenceInto*(" in npu_source
    assert "proc npuGeneralCfgDefaultEvidence*(" in npu_source
    assert "outResult.activationIndexBaseDefault =" in npu_source
    assert "outResult.reservedBitsClear =" in npu_source
    assert "NpuLayerRunPlan" in manifest["execution_status"]["typed_status"]
    forward_types = set(manifest["recovered_forward_npu_planning"]["nim_types"])
    forward_procs = set(manifest["recovered_forward_npu_planning"]["nim_procs"])
    assert "BlaiNpuCompletionStartPlan" in forward_types
    assert "BlaiNpuCompletionExitPlan" in forward_types
    assert "NpuInterruptPollTerminalPlan" in forward_types
    assert "BlaiNpuPollingWaitEvidencePlan" in forward_types
    assert "BlaiNpuCompletionSideEffectPlan" in forward_types
    assert "BlaiNpuClockExitPlan" in forward_types
    assert "NpuBusLimiterReadbackEvidence" in forward_types
    assert "NpuCodecQosStatus* = object" in npu_source
    assert "NpuCodecQosReadbackEvidence* = object" in npu_source
    assert "NpuCodecBusStatus* = object" in npu_source
    assert "CodecPclkForceOnMask* = 0x0000_FFFF'u32" in npu_source
    assert "CodecBlai2SysramThresholdMask* =" in npu_source
    assert "CodecBlai2ExtThresholdMask* =" in npu_source
    assert "proc npuCodecQosStatusFromRawInto*(" in npu_source
    assert "proc npuCodecQosStatus*()" in npu_source
    assert "proc npuCodecQosReadbackEvidenceInto*(" in npu_source
    assert "proc npuCodecQosReadbackEvidence*(" in npu_source
    assert "proc npuCodecBusStatusFromRawInto*(" in npu_source
    assert "proc npuCodecBusStatus*()" in npu_source
    assert "outResult.cnnAwqos = (qosCtrl and CnnAwqosMask) != 0'u32" in (
        npu_source
    )
    assert "outResult.encodedMatches =" in npu_source
    assert "outResult.blai2SysramThreshold =" in npu_source
    assert "outResult.blai2ExtThreshold =" in npu_source
    assert "NpuSramStatusResult* = object" in npu_source
    assert "BlaiSramSelMask*  = 1'u32 shl BlaiSramSel" in npu_source
    assert "blaiSramSelected*: bool" in npu_source
    assert "outResult.blaiSramSelected = (vramCtrl and BlaiSramSelMask) != 0" in (
        npu_source
    )
    assert "sramSelected*: bool" in npu_source
    assert "outResult.sramSelected = sram.blaiSramSelected" in npu_source
    assert "NpuRuntimeInitSdkBoundaryEvidence* = object" in npu_source
    assert "proc npuRuntimeInitSdkBoundaryEvidenceInto*(" in npu_source
    assert "proc npuRuntimeInitSdkBoundaryEvidence*(" in npu_source
    assert "outResult.sdkSelectsClockSource =" in npu_source
    assert "outResult.localPulsesReset =" in npu_source
    assert "outResult.boundaryExplicit =" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidence"
        in forward_types
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidence" in (
        forward_types
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidence" in (
        forward_types
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidence" in (
        forward_types
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlan" in (
        forward_types
    )
    assert "blaiNpuCompletionStartPlanInto" in forward_procs
    assert "blaiNpuCompletionStartPlan" in forward_procs
    assert "blaiNpuCompletionExitPlanInto" in forward_procs
    assert "blaiNpuCompletionExitPlan" in forward_procs
    assert "npuInterruptPollTerminalPlanInto" in forward_procs
    assert "npuInterruptPollTerminalPlan" in forward_procs
    assert "blaiNpuPollingWaitEvidencePlanInto" in forward_procs
    assert "blaiNpuPollingWaitEvidencePlan" in forward_procs
    assert "blaiNpuPollingBudgetScaleEvidenceInto" in forward_procs
    assert "blaiNpuPollingBudgetScaleEvidence" in forward_procs
    assert "blaiNpuCompletionSideEffectPlanInto" in forward_procs
    assert "blaiNpuCompletionSideEffectPlan" in forward_procs
    assert "blaiNpuClockExitPlanInto" in forward_procs
    assert "blaiNpuClockExitPlan" in forward_procs
    assert "npuBusLimiterReadbackEvidenceInto" in forward_procs
    assert "npuBusLimiterReadbackEvidence" in forward_procs
    assert (
        "blaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidenceInto"
        in forward_procs
    )
    assert (
        "blaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidence"
        in forward_procs
    )
    assert (
        "blaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidenceInto"
        in forward_procs
    )
    assert "blaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidence" in (
        forward_procs
    )
    assert (
        "blaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidenceInto"
        in forward_procs
    )
    assert "blaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidence" in (
        forward_procs
    )
    assert (
        "blaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidenceInto"
        in forward_procs
    )
    assert "blaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidence" in (
        forward_procs
    )
    assert "blaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlanInto" in (
        forward_procs
    )
    assert "blaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlan" in (
        forward_procs
    )
    assert "BlaiNpuCompletionStartPlan* = object" in npu_source
    assert "BlaiNpuCompletionExitPlan* = object" in npu_source
    assert "NpuInterruptPollTerminalPlan* = object" in npu_source
    assert "BlaiNpuPollingWaitEvidencePlan* = object" in npu_source
    assert "BlaiNpuPollingBudgetScaleEvidence* = object" in npu_source
    assert "BlaiNpuCompletionSideEffectPlan* = object" in npu_source
    assert "BlaiNpuClockExitPlan* = object" in npu_source
    assert "NpuBusLimiterReadbackEvidence* = object" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidence* = object"
        in npu_source
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidence* = object" in (
        npu_source
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidence* = object" in (
        npu_source
    )
    assert "BlaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidence* = object" in (
        npu_source
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveStartCommandSurfaceEvidence* = object"
        in npu_source
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlan* = object"
        in npu_source
    )
    assert "NpuRegisterSnapshotCaptureState* = object" in npu_source
    assert "NpuRegisterSnapshotCaptureApplyPlan* = object" in npu_source
    assert "NpuWrapperResetState* = object" in npu_source
    assert "NpuWrapperResetApplyPlan* = object" in npu_source
    assert "proc blaiNpuCompletionStartPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionStartPlan*(" in npu_source
    assert "proc blaiNpuCompletionExitPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionExitPlan*(" in npu_source
    assert "proc npuInterruptPollTerminalPlanInto*(" in npu_source
    assert "proc npuInterruptPollTerminalPlan*(" in npu_source
    assert "proc blaiNpuPollingWaitEvidencePlanInto*(" in npu_source
    assert "proc blaiNpuPollingWaitEvidencePlan*(" in npu_source
    assert "proc blaiNpuPollingBudgetScaleEvidenceInto*(" in npu_source
    assert "proc blaiNpuPollingBudgetScaleEvidence*(" in npu_source
    assert "proc blaiNpuCompletionSideEffectPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionSideEffectPlan*(" in npu_source
    assert "proc blaiNpuClockExitPlanInto*(" in npu_source
    assert "proc blaiNpuClockExitPlan*(" in npu_source
    assert "proc npuBusLimiterReadbackEvidenceInto*(" in npu_source
    assert "proc npuBusLimiterReadbackEvidence*(" in npu_source
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidenceInto*("
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveLocalAggregateInterruptEvidence*("
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidenceInto*("
        in npu_source
    )
    assert "proc blaiParsedForwardConfiguredWorkspaceActiveCommandIdleEvidence*(" in (
        npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidenceInto*("
        in npu_source
    )
    assert "proc blaiParsedForwardConfiguredWorkspaceActiveLaunchGapEvidence*(" in (
        npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidenceInto*("
        in npu_source
    )
    assert "proc blaiParsedForwardConfiguredWorkspaceActiveStartEdgeEvidence*(" in (
        npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveStartCommandSurfaceEvidenceInto*("
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveStartCommandSurfaceEvidence*("
        in npu_source
    )
    assert "outResult.generalStableToStart =" in npu_source
    assert "outResult.generalStableToWaitExit =" in npu_source
    assert "outResult.startOnlyTouchesIntCfg =" in npu_source
    assert "proc npuRegisterSnapshotCaptureApplyPlan*(" in npu_source
    assert "proc npuApplyLastLaunchRegisterSnapshotState*" in npu_source
    assert "proc npuApplyLastStartedRegisterSnapshotState*" in npu_source
    assert "proc npuWrapperResetApplyPlan*(plan: NpuResetPulsePlan)" in npu_source
    assert "proc npuApplyWrapperResetState*" in npu_source
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlanInto*("
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveOutputReadbackPlan*("
        in npu_source
    )
    assert "NpuLayerRunPlan* = object" in npu_source
    assert "proc npuPlanLayerRunInto*(" in npu_source
    assert "proc npuPlanLayerRun*(" in npu_source
    assert "outResult.waitPlan = npuPlanCompletionWait(" in npu_source
    reset_pulse_block = re.search(
        r"proc npuApplyResetPulsePlan\*\(.*?proc npuHoldReset\*",
        npu_source,
        re.S,
    )
    assert reset_pulse_block is not None
    assert "let wrapperResetApply = npuWrapperResetApplyPlan(plan)" in (
        reset_pulse_block.group(0)
    )
    assert "npuApplyWrapperResetState(npuWrapperResetState(wrapperResetApply))" in (
        reset_pulse_block.group(0)
    )
    assert "npuHasStarted = false" not in reset_pulse_block.group(0)
    assert "npuHasConfiguredInstructionStream = false" not in reset_pulse_block.group(0)
    assert "npuLastLaunchRegisterSnapshotCapturedFlag = false" not in (
        reset_pulse_block.group(0)
    )
    assert "npuLastStartedRegisterSnapshotCapturedFlag = false" not in (
        reset_pulse_block.group(0)
    )
    layer_run_block = re.search(
        r"proc npuRunLayerInto\*\(.*?proc npuRunLayerResult\*",
        npu_source,
        re.S,
    )
    assert layer_run_block is not None
    assert "let runPlan = npuPlanLayerRun(npuInstructionStreamConfigured(), timeout)" in (
        layer_run_block.group(0)
    )
    assert "outResult.waitPlan = runPlan.waitPlan" in layer_run_block.group(0)
    assert "if not runPlan.runnable:" in layer_run_block.group(0)
    assert "npuLayerRunReadinessInto(" not in layer_run_block.group(0)
    assert "npuPlanCompletionWait(" not in layer_run_block.group(0)
    completion_wait_block = re.search(
        r"proc npuWaitForCompletionInto\*\(.*?proc npuWaitForCompletion\*",
        npu_source,
        re.S,
    )
    assert completion_wait_block is not None
    assert "let startPlan = blaiNpuCompletionStartPlan(plan)" in (
        completion_wait_block.group(0)
    )
    assert "outResult.statusDecision = startPlan.initialStatus" in (
        completion_wait_block.group(0)
    )
    assert "if not startPlan.starts:" in completion_wait_block.group(0)
    assert "let exitPlan =" in completion_wait_block.group(0)
    assert "blaiNpuCompletionExitPlan(startPlan.waitPlan, outResult.interruptObserved)" in (
        completion_wait_block.group(0)
    )
    assert "if exitPlan.clearInterrupt:" in completion_wait_block.group(0)
    assert "if exitPlan.disableClock:" in completion_wait_block.group(0)
    assert "let launchSnapshotApply = npuRegisterSnapshotCaptureApplyPlan(" in (
        completion_wait_block.group(0)
    )
    assert "npuApplyLastLaunchRegisterSnapshotState(" in (
        completion_wait_block.group(0)
    )
    assert "let startedSnapshotApply = npuRegisterSnapshotCaptureApplyPlan(" in (
        completion_wait_block.group(0)
    )
    assert "npuApplyLastStartedRegisterSnapshotState(" in (
        completion_wait_block.group(0)
    )
    assert "npuLastLaunchRegisters)" not in completion_wait_block.group(0)
    assert "npuLastStartedRegisters)" not in completion_wait_block.group(0)
    assert "npuLastLaunchRegisterSnapshotCapturedFlag = true" not in (
        completion_wait_block.group(0)
    )
    assert "npuLastStartedRegisterSnapshotCapturedFlag = true" not in (
        completion_wait_block.group(0)
    )
    assert "if outResult.interruptObserved and plan.clearOnComplete:" not in (
        completion_wait_block.group(0)
    )
    assert "if plan.disableClockOnExit:" not in completion_wait_block.group(0)
    assert (
        "blaiNpuCompletionStatusInto(\n"
        "    plan.configured, interruptObserved = false"
        not in completion_wait_block.group(0)
    )
    interrupt_poll_block = re.search(
        r"proc npuWaitForInterruptInto\*\(.*?proc npuWaitForInterruptResult\*",
        npu_source,
        re.S,
    )
    assert interrupt_poll_block is not None
    assert "let terminal = npuInterruptPollTerminalPlan(" in interrupt_poll_block.group(0)
    assert "outResult.exhausted = terminal.exhausted" in interrupt_poll_block.group(0)
    assert "outResult.valid = terminal.valid" in interrupt_poll_block.group(0)
    assert "not outResult.interruptObserved and outResult.polls == timeout" not in (
        interrupt_poll_block.group(0)
    )
    assert "outResult.interruptObserved and outResult.polls <= timeout" not in (
        interrupt_poll_block.group(0)
    )
    polling_evidence_block = re.search(
        r"proc blaiNpuPollingWaitEvidenceInto\*\(.*?"
        r"proc blaiNpuPollingWaitEvidence\*",
        npu_source,
        re.S,
    )
    assert polling_evidence_block is not None
    assert "let plan = blaiNpuPollingWaitEvidencePlan(completion)" in (
        polling_evidence_block.group(0)
    )
    assert "outResult.budgetMatchesPolls = plan.budgetMatchesPolls" in (
        polling_evidence_block.group(0)
    )
    assert "outResult.valid = plan.valid" in polling_evidence_block.group(0)
    assert "completion.configured and completion.started and" not in (
        polling_evidence_block.group(0)
    )
    assert "completion.poll.exhausted and outResult.actualPolls" not in (
        polling_evidence_block.group(0)
    )
    assert "outResult.longerPollsObserved =" in npu_source
    assert "outResult.scaleMatchesEvidence =" in npu_source
    assert "outResult.localPollBitClear =" in npu_source
    assert "outResult.aggregateNoCompletionCandidate =" in npu_source
    assert "outResult.localAndAggregateAgree =" in npu_source
    assert "outResult.commandIdleMatchesWaitExit =" in npu_source
    assert "outResult.launchStateReachesCompletionGap =" in npu_source
    assert "outResult.noImmediateBusyOrInterruptEdge =" in npu_source
    assert "outResult.classifiedAsIdleNoCompletion =" in npu_source
    assert "BlaiForwardWorkspaceInstructionRawWordEvidence* = object" in npu_source
    assert "BlaiInstructionWordCursor* = object" in npu_source
    assert "proc blaiInstructionWordCursor*(wordIndex: uint32)" in npu_source
    assert "proc blaiInstructionWord*(" in npu_source
    assert "proc blaiInstructionWords*(" in npu_source
    assert "let cursor = blaiInstructionWordCursor(wordIndex)" in npu_source
    assert "discard blaiLoadLe32(inst, cursor.byteOffset, result)" in npu_source
    assert "inst[base + 1]" not in npu_source
    assert "inst[base + 2]" not in npu_source
    assert "inst[base + 3]" not in npu_source
    assert "proc blaiForwardWorkspaceInstructionRawWordEvidenceInto*(" in npu_source
    assert "proc blaiForwardWorkspaceInstructionRawWordEvidence*(" in npu_source
    assert "outResult.quantWords == outResult.rebuiltQuantWords" in npu_source
    assert "outResult.layerWords == outResult.rebuiltLayerWords" in npu_source
    assert "BlaiNpuSdkStreamWalkEvidence* = object" in npu_source
    assert "proc blaiNpuSdkStreamWalkEvidenceInto*(" in npu_source
    assert "proc blaiNpuSdkStreamWalkEvidence*(" in npu_source
    assert "outResult.firstRecordSideInstruction = isBlaiExternalInstruction(stream[0])" in (
        npu_source
    )
    assert "outResult.secondRecordLayerInstruction = isBlaiLayerInstruction(stream[1])" in (
        npu_source
    )
    assert "outResult.sdkLayerCount = blaiLayerCount(stream)" in npu_source
    assert "outResult.scanStopsAtSecondRecord =" in npu_source
    assert "descriptorHaltBit*: bool" in npu_source
    assert "BlaiForwardWorkspaceInstructionTerminalControlEvidence* = object" in npu_source
    assert "proc blaiForwardWorkspaceInstructionTerminalControlEvidenceInto*(" in npu_source
    assert "proc blaiForwardWorkspaceInstructionTerminalControlEvidence*(" in npu_source
    assert "outResult.descriptorHaltBitClear = not decoded.descriptorHaltBit" in npu_source
    assert "outResult.descriptorHaltBitSet = decoded.descriptorHaltBit" in npu_source
    assert "outResult.streamEndBitSet = decoded.instEndBit and decoded.halt" in npu_source
    assert "outResult.terminalBitsSdkStyle =" in npu_source
    assert "outResult.terminalBitsSplit or outResult.terminalBitsSdkStyle" in npu_source
    assert "BlaiForwardD0TerminalControlContrastEvidence* = object" in npu_source
    assert "proc blaiForwardD0TerminalControlContrastEvidenceInto*" in npu_source
    assert "proc blaiForwardD0TerminalControlContrastEvidence*" in npu_source
    assert "outResult.terminalControlsEquivalent =" in npu_source
    assert "outResult.terminalControlNotSoleBlock =" in npu_source
    assert "staticTerminalContrast.nextWorkIsEngineContext" in npu_source
    assert "BlaiForwardD0EngineContextGapEvidence* = object" in npu_source
    assert "proc blaiForwardD0EngineContextGapEvidenceInto*" in npu_source
    assert "proc blaiForwardD0EngineContextGapEvidence*" in npu_source
    assert "outResult.launchOperandContextKnown =" in npu_source
    assert "outResult.contextDiffExplainsNextFrontier =" in npu_source
    assert "staticEngineContextGap.nextWorkIsOperandEngineSemantics" in npu_source
    assert "BlaiForwardD0BufferContextContrastEvidence* = object" in npu_source
    assert "proc blaiForwardD0BufferContextContrastEvidenceInto*" in npu_source
    assert "proc blaiForwardD0BufferContextContrastEvidence*" in npu_source
    assert "BlaiForwardCompletionEdgeRecoveryFrontierEvidence* = object" in npu_source
    assert "proc blaiForwardCompletionEdgeRecoveryFrontierEvidenceInto*" in npu_source
    assert "proc blaiForwardCompletionEdgeRecoveryFrontierEvidence*" in npu_source
    assert "outResult.instructionWordsMatch =" in npu_source
    assert "outResult.firstWeightDiffers =" in npu_source
    assert (
        "staticBufferContextContrast.nextWorkIsWeightDataOrEngineSemantics"
        in npu_source
    )
    assert "staticCompletionEdgeFrontier.remainingCoreStartRouteOrCompletionEnable" in (
        npu_source
    )
    assert "outResult.forcedInterruptBindingRuledOut =" in npu_source
    assert "outResult.d0BootClockControlRuledOut =" in npu_source
    assert "activeDescriptorHalt = false" in (
        REPO_ROOT / "examples/m0_npu_model_smoke_test.nim"
    ).read_text(encoding="utf-8")
    assert "BlaiForwardLaunchCacheRegisterEvidence* = object" in npu_source
    assert "proc blaiForwardLaunchCacheRegisterEvidenceInto*(" in npu_source
    assert "proc blaiForwardLaunchCacheRegisterEvidence*(" in npu_source
    assert "outResult.instructionRegisterCacheClean =" in npu_source
    assert "outResult.dataRegisterCacheClean =" in npu_source
    assert "outResult.weightRegisterCacheClean =" in npu_source
    assert "outResult.biasRegisterCacheClean =" in npu_source
    assert "outResult.registerCacheAddressesMatch =" in npu_source
    assert "outResult.registerCacheBytesReady =" in npu_source
    assert "BlaiForwardLaunchSramAddressEvidence* = object" in npu_source
    assert "proc blaiForwardLaunchSramAddressEvidenceInto*(" in npu_source
    assert "proc blaiForwardLaunchSramAddressEvidence*(" in npu_source
    assert "outResult.registerAddressesInWram =" in npu_source
    assert "outResult.runtimeSramValid = runtime.sramValid" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active launch cache register evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch cache register evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active launch SRAM address evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch SRAM address evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiForwardLaunchWramSpanEvidence* = object" in npu_source
    assert "proc blaiForwardLaunchWramSpanEvidenceInto*(" in npu_source
    assert "proc blaiForwardLaunchWramSpanEvidence*(" in npu_source
    assert "blaiUint32AddressSpanInWram(launchSnapshot.instAddr" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active launch WRAM span evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch WRAM span evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiForwardLaunchInstructionFetchEvidence* = object" in npu_source
    assert "proc blaiForwardLaunchInstructionFetchEvidenceInto*(" in npu_source
    assert "proc blaiForwardLaunchInstructionFetchEvidence*(" in npu_source
    assert "launchSnapshot.instAddr == workspace.instruction.address" in npu_source
    assert "launchSpan.instructionBytes == raw.expectedCount * BlaiInstructionSize.uint32" in npu_source
    assert "walk.wouldAllocateOneLayer and walk.decodedLayerCountMatches" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active launch instruction fetch evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch instruction fetch evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiForwardLaunchOperandFetchEvidence* = object" in npu_source
    assert "proc blaiForwardLaunchOperandFetchEvidenceInto*(" in npu_source
    assert "proc blaiForwardLaunchOperandFetchEvidence*(" in npu_source
    assert "stream.decodedLayer.inLayer1Mem == data.inputSlot" in npu_source
    assert "stream.decodedLayer.outLayerMem == data.outputSlot" in npu_source
    assert "launchSnapshot.imageSeg == data.patchSize" in npu_source
    assert "NpuLayerConfigPatchSizeRegisterEvidence* = object" in npu_source
    assert "proc npuLayerConfigPatchSizeRegisterEvidenceInto*(" in npu_source
    assert "plan.launch.segmentCount" in npu_source
    assert "outResult.launchImageSeg == outResult.configPatchSize" in npu_source
    assert "activePatchSizeRegisterEvidence" in (
        REPO_ROOT / "examples/m0_npu_model_smoke_test.nim"
    ).read_text(encoding="utf-8")
    assert (
        "[PASS] NPU model parsed configured workspace fixture active config patch register evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "launchSpan.weightBytes == temp.weightBytes" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active launch operand fetch evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch operand fetch evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiToolchainNpuRunScalars* = object" in npu_source
    assert "BlaiToolchainNpuRunGate* = object" in npu_source
    assert "BlaiToolchainNpuRunDepthwisePressureLimit* = 8192'u64" in npu_source
    assert "proc blaiToolchainNpuRunGateInto*(" in npu_source
    assert "proc blaiToolchainNpuRunGate*(" in npu_source
    assert "scalars.kernelW == scalars.kernelH" in npu_source
    assert "BlaiToolchainNpuRunConvType" in npu_source
    assert "BlaiToolchainNpuRunMatmulType" in npu_source
    assert "BlaiToolchainNpuRunRouteMaxType" in npu_source
    assert "outResult.stride2KernelAccepted =" in npu_source
    assert "outResult.stride2ParityAccepted =" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active polling budget scale evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active polling budget scale evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active local aggregate interrupt evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active local aggregate interrupt evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model bus limiter demo readback evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model bus limiter demo readback evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active demo limiter evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active demo limiter evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active stream raw word evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active stream raw word evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active terminal control"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active terminal control"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active toolchain run gate"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active toolchain run gate"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active post-stop snapshot evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active post-stop snapshot evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active command idle evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active command idle evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "MmMiscBusDecodeRegs* {.bycopy.} = object" in npu_source
    assert "NpuBusDecodeStatusResult* = object" in npu_source
    assert "proc npuBusDecodeStatusFromRawInto*(" in npu_source
    assert "proc npuBusDecodeStatusInto*" in npu_source
    assert "MmBusDecErrLatchMask*" in npu_source
    assert "McuBusDecErrLatchMask*" in npu_source
    assert "outResult.noDecodeError = not outResult.anyErrorLatched" in npu_source
    assert "NpuD0ProbeOutputMovementEvidence* = object" in npu_source
    assert "proc npuD0ProbeOutputMovementEvidenceInto*" in npu_source
    assert "outResult.modelOutputStillUnvalidated =" in npu_source
    assert "d0ProbeMoved.modelOutputStillUnvalidated" in npu_source
    assert "NpuD0ProbeStatusEvidence* = object" in npu_source
    assert "proc npuD0ProbeStatusEvidenceInto*" in npu_source
    assert "proc npuD0ProbeStatusEvidence*" in npu_source
    assert "outResult.movementWithoutOracle =" in npu_source
    assert "d0ProbeStatus.movementWithoutOracle" in npu_source
    assert "NpuD0ProbeInstructionStreamEvidence* = object" in npu_source
    assert "proc npuD0ProbeInstructionStreamEvidenceInto*" in npu_source
    assert "decodeBlaiLayer(stream[stream.high])" in npu_source
    assert "outResult.setupWords = blaiInstructionWords(stream[0])" in npu_source
    assert (
        "outResult.terminalWords = blaiInstructionWords(stream[stream.high])"
        in npu_source
    )
    assert "NpuD0ProbeCompletionEdgeEvidence* = object" in npu_source
    assert "proc npuD0ProbeCompletionEdgeEvidenceInto*" in npu_source
    assert "outResult.outputMovedWithoutCompletion =" in npu_source
    assert "d0ProbeMissingCompletion.outputMovedWithoutCompletion" in npu_source
    assert "NpuD0WeightByteExperimentEvidence* = object" in npu_source
    assert "proc npuD0WeightByteExperimentEvidenceInto*" in npu_source
    assert "outResult.supportsWeightSensitiveMovement =" in npu_source
    assert "outResult.supportsCorePathDifference =" in npu_source
    assert "d0WeightByteExperiment.supportsWeightSensitiveMovement" in npu_source
    assert "NpuM0D0SyntheticRouteContrastEvidence* = object" in npu_source
    assert "proc npuM0D0SyntheticRouteContrastEvidenceInto*" in npu_source
    assert "outResult.supportsM0CoreRouteIssue =" in npu_source
    assert "outResult.supportsMaterializedContextIssue =" in npu_source
    assert "staticM0D0RouteContrast.supportsM0CoreRouteIssue" in npu_source
    assert "NpuM0SyntheticAddressAliasContrastEvidence* = object" in npu_source
    assert "proc npuM0SyntheticAddressAliasContrastEvidenceInto*" in npu_source
    assert "outResult.supportsAddressAliasBlocker =" in npu_source
    assert "outResult.supportsCoreRouteBlocker =" in npu_source
    assert "staticM0AddressAliasContrast.supportsAddressAliasBlocker" in npu_source
    assert "NpuM0SyntheticDramContrastEvidence* = object" in npu_source
    assert "proc npuM0SyntheticDramContrastEvidenceInto*" in npu_source
    assert "outResult.supportsDramPlacementBlocker =" in npu_source
    assert "outResult.supportsM0StartRouteBlocker =" in npu_source
    assert "staticM0DramContrast.supportsDramPlacementBlocker" in npu_source
    assert "NpuM0InterruptBoundDramContrastEvidence* = object" in npu_source
    assert "proc npuM0InterruptBoundDramContrastEvidenceInto*" in npu_source
    assert "forced hardware experiment, not the default runtime policy" in npu_source
    assert "outResult.supportsInterruptBindingBlocker =" in npu_source
    assert "staticM0InterruptBoundDram.supportsInterruptBindingBlocker" in npu_source
    assert "staticM0InterruptBoundDramStillGated.supportsM0StartRouteBlocker" in npu_source
    assert "SipeedD0BootApuSramRel* = 0'u32" in npu_source
    assert "SipeedD0BootBclkMuxPll160M* = 2'u32" in npu_source
    assert "SipeedD0BootCpuClkMuxPll400M* = 2'u32" in npu_source
    assert "SipeedD0BootClockControlFieldMask* =" in npu_source
    assert "NpuD0BootClockControlEvidence* = object" in npu_source
    assert "NpuD0BootClockControlPlan* = object" in npu_source
    assert "NpuD0BootVramRouteEvidence* = object" in npu_source
    assert "NpuD0BootVramRoutePlan* = object" in npu_source
    assert "NpuM0D0BootVramRouteDramContrastEvidence* = object" in npu_source
    assert "NpuM0D0BootClockControlDramContrastEvidence* = object" in npu_source
    assert "NpuM0DramCompletionSurfaceEvidence* = object" in npu_source
    assert "proc npuD0BootVramRouteEvidenceInto*" in npu_source
    assert "proc npuD0BootClockControlEvidenceInto*" in npu_source
    assert "proc npuMmClockCtrlWithD0BootClockControl*" in npu_source
    assert "proc npuD0BootClockControlPlanInto*" in npu_source
    assert "proc npuD0BootClockControlPlan*" in npu_source
    assert "proc npuApplyD0BootClockControlPlan*" in npu_source
    assert "blaiLoadReg(mmClockCtrl()[].mmClkCtrlCpu)" in npu_source
    assert "outResult.matchesD0BootClockConfig =" in npu_source
    assert "outResult.preservesUnrelatedBits =" in npu_source
    assert "d0BootClockEvidence.matchesD0BootClockConfig" in npu_source
    assert "d0BootClockPlan.candidatePrecondition" in npu_source
    assert "proc npuVramCtrlWithD0BootSramRoute*" in npu_source
    assert "proc npuD0BootVramRoutePlanInto*" in npu_source
    assert "proc npuApplyD0BootVramRoutePlan*" in npu_source
    assert "proc npuM0D0BootVramRouteDramContrastEvidenceInto*" in npu_source
    assert "proc npuM0D0BootClockControlDramContrastEvidenceInto*" in npu_source
    assert "proc npuM0DramCompletionSurfaceEvidenceInto*" in npu_source
    assert "outResult.gatedIdleNoInterrupt =" in npu_source
    assert "outResult.baselineAlreadyMoved =" in npu_source
    assert "staticM0InterruptBoundDramAlreadyMoved.baselineAlreadyMoved" in npu_source
    assert "staticM0D0BootClockAlreadyMoved.baselineAlreadyMoved" in npu_source
    assert "staticM0D0BootClockStillGated.supportsDeeperM0StartRouteBlocker" in npu_source
    assert "status.apuSramRel == SipeedD0BootApuSramRel" in npu_source
    assert "outResult.possibleD0BootRoutePrecondition =" in npu_source
    assert "localReleaseRouteEvidence.possibleD0BootRoutePrecondition" in npu_source
    assert "staticM0D0BootVramRouteMoved.supportsD0BootVramRoutePrecondition" in (
        npu_source
    )
    assert "when defined(bl808d0):" in npu_source
    assert "outResult.d0ApuCandidate" in npu_source
    assert "activeCoreRouteSafe and bindingVerified" in npu_source
    d0_probe_source = (
        REPO_ROOT / "examples/d0_npu_start_probe.nim"
    ).read_text(encoding="utf-8")
    d0_probe_helper = (
        REPO_ROOT / "examples/m0_d0_npu_start_probe.nim"
    ).read_text(encoding="utf-8")
    m0_probe_source = (
        REPO_ROOT / "examples/m0_npu_start_probe.nim"
    ).read_text(encoding="utf-8")
    model_smoke_source = (
        REPO_ROOT / "examples/m0_npu_model_smoke_test.nim"
    ).read_text(encoding="utf-8")
    assert "NpuProbeDataSlots = object" in d0_probe_source
    assert "probeInst {.align: 16.}: array[2, BlaiInstruction]" in d0_probe_source
    assert "npuD0ProbeInstructionStreamEvidence(probeInst)" in d0_probe_source
    assert "npuD0ProbeCompletionEdgeEvidence(" in d0_probe_source
    assert "ProbeActiveWeightWord = 0x0102_0302'u32" in d0_probe_source
    assert "npuD0WeightByteExperimentEvidence(" in d0_probe_source
    assert "StatusProbeActiveWeightClassified" in d0_probe_source
    assert "npuD0ProbeOutputMovementEvidence(" in d0_probe_source
    assert "cpuOracleValidated = false" in d0_probe_source
    assert "outputMovement.movementEvidenceValid" in d0_probe_source
    assert "npuD0ProbeStatusEvidence(" in d0_probe_source
    assert "setStatus(StatusTypedEvidence)" in d0_probe_source
    assert "npuApplyInterruptBindingOperationPlan(" in d0_probe_source
    assert "StatusIrqBindingApplied" in d0_probe_source
    assert "onNpuIrq" in d0_probe_source
    assert "StatusTypedModelOutputUnvalidated" in d0_probe_helper
    assert "D0 NPU typed status evidence" in d0_probe_helper
    assert "D0 NPU IRQ binding applied" in d0_probe_helper
    assert "D0 NPU typed probe stream decoded" in d0_probe_helper
    assert "D0 NPU output moved without completion edge" in d0_probe_helper
    assert "D0 NPU active-weight experiment classified" in d0_probe_helper
    assert "NpuProbeDataSlots = object" in m0_probe_source
    assert "probeInst {.align: 16.}: array[2, BlaiInstruction]" in m0_probe_source
    assert "ProbeActiveWeightWord = 0x0102_0302'u32" in m0_probe_source
    assert "ProbeDramBase = DramBase + 0x0000_7000'u" in m0_probe_source
    assert "NpuProbeDramSlots = object" in m0_probe_source
    assert "proc dramSlots(): var NpuProbeDramSlots" in m0_probe_source
    assert "npuD0ProbeInstructionStreamEvidence(probeInst)" in m0_probe_source
    assert "npuM0D0SyntheticRouteContrastEvidence(" in m0_probe_source
    assert "M0 NPU synthetic D0 route contrast classified" in m0_probe_source
    assert "M0 NPU synthetic active-weight stream gated DATA" in m0_probe_source
    assert "npuD0BootClockControlEvidence()" in m0_probe_source
    assert "m0_probe_mm_clk_ctrl_cpu" in m0_probe_source
    assert "M0 NPU SDK D0 boot clock control decoded" in m0_probe_source
    assert "npuD0BootClockControlPlan(d0BootClock.mmClkCtrlCpu)" in m0_probe_source
    assert "m0_probe_mm_clk_d0_plan" in m0_probe_source
    assert "M0 NPU SDK D0 boot clock control plan decoded" in m0_probe_source
    assert "npuApplyD0BootClockControlPlan(clockRoutePlan)" in m0_probe_source
    assert "m0_probe_d0_clock_ctrl_cpu" in m0_probe_source
    assert "npuM0D0BootClockControlDramContrastEvidence(" in m0_probe_source
    assert "M0 NPU D0 boot clock DRAM contrast classified" in m0_probe_source
    assert "M0 NPU forced IRQ DRAM baseline already moved DATA" in m0_probe_source
    assert "M0 NPU D0 boot clock DRAM baseline already moved DATA" in m0_probe_source
    assert "npuD0BootVramRouteEvidence(vramStatus)" in m0_probe_source
    assert "m0_probe_vram_ctrl" in m0_probe_source
    assert "M0 NPU SDK D0 boot VRAM route decoded" in m0_probe_source
    assert "npuApplyD0BootVramRoutePlan(d0RoutePlan)" in m0_probe_source
    assert "m0_probe_d0_route_vram_ctrl" in m0_probe_source
    assert "npuM0D0BootVramRouteDramContrastEvidence(" in m0_probe_source
    assert "M0 NPU D0 boot VRAM route DRAM configuration sampled" in m0_probe_source
    assert "M0 NPU D0 boot VRAM route DRAM configuration blocked" in m0_probe_source
    assert "M0 NPU D0 boot VRAM route DRAM contrast classified" in m0_probe_source
    assert "M0 NPU D0 boot VRAM route DRAM stream moved DATA" in m0_probe_source
    assert "M0 NPU D0 boot VRAM route DRAM stream gated DATA" in m0_probe_source
    assert "blaiProjectHardwareAddress(cast[uint](addr probeInst))" in m0_probe_source
    assert "npuM0SyntheticAddressAliasContrastEvidence(" in m0_probe_source
    assert "M0 NPU synthetic address alias contrast classified" in m0_probe_source
    assert "M0 NPU projected synthetic stream gated DATA" in m0_probe_source
    assert "npuM0SyntheticDramContrastEvidence(" in m0_probe_source
    assert "m0_probe_dram_wait_intcfg" in m0_probe_source
    assert "m0_probe_dram_wait_busy" in m0_probe_source
    assert "npuM0DramCompletionSurfaceEvidence(" in m0_probe_source
    assert "M0 NPU DRAM completion surface classified" in m0_probe_source
    assert "npuD0ProbeCompletionEdgeEvidence(" in m0_probe_source
    assert "M0 NPU DRAM output moved without completion edge" in m0_probe_source
    assert "M0 NPU DRAM output gated idle without interrupt" in m0_probe_source
    assert "M0 NPU synthetic DRAM contrast classified" in m0_probe_source
    assert "M0 NPU DRAM synthetic stream gated DATA" in m0_probe_source
    assert "NpuInterruptCoreBindingPolicy(" in m0_probe_source
    assert "npuApplyInterruptBindingOperationPlan(forcedBindingPlan, onNpuIrq)" in (
        m0_probe_source
    )
    assert "M0 NPU forced IRQ binding applied" in m0_probe_source
    assert "npuM0InterruptBoundDramContrastEvidence(" in m0_probe_source
    assert "M0 NPU forced IRQ DRAM contrast classified" in m0_probe_source
    assert "M0 NPU forced IRQ DRAM stream moved DATA" in m0_probe_source
    assert "M0 NPU forced IRQ DRAM stream gated DATA" in m0_probe_source
    assert "NpuSdkInterruptApiEvidence" in npu_source
    assert "NpuSdkInterruptPriorityUsesPreemptOnly* = true" in npu_source
    assert "NpuSdkInterruptInitClearsPending* = false" in npu_source
    assert "npuSdkInterruptApiEvidenceInto" in npu_source
    assert "subPriorityIgnoredBySdk" in npu_source
    assert "clearPendingApiSeparate" in npu_source
    assert "NPU model SDK interrupt init evidence" in model_smoke_source
    assert "NPU model SDK interrupt priority semantics" in model_smoke_source
    assert "NPU model SDK interrupt pending clear separate" in model_smoke_source
    assert "[PASS] D0 NPU typed status evidence" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU IRQ binding applied" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU typed probe stream decoded" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU output moved without completion edge" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU active-weight experiment classified" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU active-weight experiment moved DATA" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU synthetic D0 route contrast classified" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU synthetic active-weight stream gated DATA" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU synthetic address alias contrast classified" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU projected synthetic stream gated DATA" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU synthetic DRAM contrast classified" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] M0 NPU DRAM completion surface classified" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert "[PASS] D0 NPU probe output moved" in (
        REPO_ROOT / "tools/hardware_validation.json"
    ).read_text(encoding="utf-8")
    assert (
        "NPU model parsed configured workspace fixture active bus decode status"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active bus decode status"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active launch gap evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch gap evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active start edge evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active start edge evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active start command surface evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active start command surface evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active launch general cfg defaults"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active launch general cfg defaults"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiIntCfgKnownMask*" in npu_source
    assert "NpuIntCfgKnownFieldEvidence* = object" in npu_source
    assert "proc npuIntCfgKnownFieldEvidenceInto*" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active launch int cfg known fields"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active wait int cfg known fields"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active runtime SRAM selected"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active runtime SRAM selected"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active runtime SDK boundary evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active runtime SDK boundary evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active codec qos evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active codec qos evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active codec bus evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active codec bus evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    side_effect_block = re.search(
        r"proc blaiNpuCompletionSideEffectEvidenceInto\*\(.*?"
        r"proc blaiNpuCompletionSideEffectEvidence\*",
        npu_source,
        re.S,
    )
    assert side_effect_block is not None
    assert "let plan = blaiNpuCompletionSideEffectPlan(completion)" in (
        side_effect_block.group(0)
    )
    assert "outResult.timeoutSideEffectsApplied = plan.timeoutSideEffectsApplied" in (
        side_effect_block.group(0)
    )
    assert "outResult.valid = plan.valid" in side_effect_block.group(0)
    assert "completion.configured and completion.started and" not in (
        side_effect_block.group(0)
    )
    assert "completion.statusDecision.completed and completion.interruptObserved" not in (
        side_effect_block.group(0)
    )
    clock_exit_block = re.search(
        r"proc blaiNpuClockExitEvidenceInto\*\(.*?"
        r"proc blaiNpuClockExitEvidence\*",
        npu_source,
        re.S,
    )
    assert clock_exit_block is not None
    assert "let plan = blaiNpuClockExitPlan(completion)" in (
        clock_exit_block.group(0)
    )
    assert "outResult.retainedUntilWaitExit = plan.retainedUntilWaitExit" in (
        clock_exit_block.group(0)
    )
    assert "outResult.valid = plan.valid" in clock_exit_block.group(0)
    assert "completion.started and completion.waitExitClock.enabled" not in (
        clock_exit_block.group(0)
    )
    assert "completion.disableClockOnExit and outResult.retainedUntilWaitExit" not in (
        clock_exit_block.group(0)
    )
    assert "startClock*: NpuClockStatusResult" in npu_source
    assert "BlaiNpuStartClockEvidence* = object" in npu_source
    assert "proc blaiNpuStartClockEvidenceInto*(" in npu_source
    assert "npuClockStatusInto(outResult.startClock)" in npu_source
    assert "outResult.waitExitClockMatchesStart =" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active start clock evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active start clock evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "startTransition*: NpuStartTransitionPlan" in npu_source
    assert "wrapperStartedAfterStart*: bool" in npu_source
    assert "BlaiNpuStartTransitionEvidence* = object" in npu_source
    assert "proc blaiNpuStartTransitionEvidenceInto*(" in npu_source
    assert "npuPlanStartTransition(launchSnapshot.intCfg, npuHasStarted)" in npu_source
    assert "outResult.wrapperStartedAfterStart = npuHasStarted" in npu_source
    assert "outResult.startsFirstRun xor outResult.resumesExistingRun" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active start transition evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active start transition evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "npuActivationTableWordCursor" in (
        manifest["recovered_forward_npu_planning"]["nim_procs"]
    )
    assert "NpuActivationTableWordCursor* = object" in npu_source
    assert "proc npuActivationTableWordCursor*(wordIndex: uint32)" in npu_source
    assert "let wordCursor = npuActivationTableWordCursor(wordIndex)" in npu_source
    assert "outResult.firstEntryIndex = wordCursor.firstEntryIndex" in npu_source
    assert "outResult.registerOffset = wordCursor.registerOffset" in npu_source
    assert "outResult.registerAddress = wordCursor.registerAddress" in npu_source
    assert "BlaiActivationTableResetEntry0* = 0x00'u8" in npu_source
    assert "BlaiActivationTableResetEntry1* = 0xFB'u8" in npu_source
    assert "BlaiActivationTableResetWord0* = 0xF2F7_FB00'u32" in npu_source
    assert "NpuActivationTableDefaultEvidence* = object" in npu_source
    assert "proc npuActivationTableDefaultEvidenceInto*(" in npu_source
    assert "proc npuActivationTableDefaultEvidence*(" in npu_source
    assert "outResult.rawMatchesReset = raw == BlaiActivationTableResetWord0" in (
        npu_source
    )
    smoke_source = (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
        encoding="utf-8"
    )
    assert "active activation table reset evidence" in smoke_source
    assert "active activation table reset raw" in smoke_source
    assert "active activation table reset decoded" in smoke_source
    activation_word_block = re.search(
        r"proc npuPlanActivationTableWordInto\*\(.*?"
        r"proc npuPlanActivationTableWord\*",
        npu_source,
        re.S,
    )
    assert activation_word_block is not None
    assert "wordIndex * BlaiActivationTableEntriesPerWord.uint32" not in (
        activation_word_block.group(0)
    )
    assert "BlaiActivationTableBaseOffset + wordIndex * BlaiActivationTableWordBytes" not in (
        activation_word_block.group(0)
    )
    runtime_types = set(manifest["recovered_sdk_runtime_wrappers"]["nim_types"])
    runtime_procs = set(manifest["recovered_sdk_runtime_wrappers"]["nim_procs"])
    assert "NpuMmAggregateRawIndexCursor" in runtime_types
    assert "npuMmAggregateRawIndexCursor" in runtime_procs
    assert "NpuGlbMcuInterruptSourceCursor" in runtime_types
    assert "npuGlbMcuInterruptSourceCursor" in runtime_procs
    assert "NpuGlbMcuInterruptSourceCursor* = object" in npu_source
    assert "proc npuGlbMcuInterruptSourceCursor*(irq: uint32)" in npu_source
    assert "let sourceCursor = npuGlbMcuInterruptSourceCursor(interrupt.irq)" in npu_source
    assert "outResult.sourceOffset = sourceCursor.sourceOffset" in npu_source
    assert "outResult.withinGlbMcuSourceRange = sourceCursor.withinGlbMcuSourceRange" in npu_source
    for classifier_name in (
        "npuInterruptLineOwnershipInto",
        "npuInterruptGlbRouteMapInto",
    ):
        classifier_block = re.search(
            rf"proc {classifier_name}\*\(.*?proc ",
            npu_source,
            re.S,
        )
        assert classifier_block is not None
        assert "interrupt.irq - 16'u32" not in classifier_block.group(0)
    assert "NpuInterruptBindingApplyPreflight* = object" in npu_source
    assert "NpuInterruptBindingApplyResult* = object" in npu_source
    assert "proc npuInterruptBindingApplyPreflightInto*" in npu_source
    assert "proc npuInterruptBindingApplyPreflight*" in npu_source
    assert "proc npuApplyInterruptBindingOperationPlan*" in npu_source
    assert "irq.registerTrapHandler(plan.irq, handler)" in npu_source
    assert "irq.irqClearPending(plan.irq)" in npu_source
    assert "irq.irqSetLevel(plan.irq, plan.priority)" in npu_source
    assert "irq.irqEnable(plan.irq)" in npu_source
    assert "result.deferredByPolicy = result.preflight.deferredByPolicy" in npu_source
    apply_block = re.search(
        r"proc npuApplyInterruptBindingOperationPlan\*\(.*?"
        r"proc npuInterruptBindingApiContractInto\*",
        npu_source,
        re.S,
    )
    assert apply_block is not None
    for raw_irq_write in (
        "volatileStore",
        "ClicIntBase",
        "ClicIntIe",
        "ClicIntCtl",
        "PlicEnableBase",
    ):
        assert raw_irq_write not in apply_block.group(0)
    assert (
        "NPU model interrupt apply preflight evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model interrupt apply preflight evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "NpuMmAggregateRawIndexCursor* = object" in npu_source
    assert "proc npuMmAggregateRawIndexCursor*(index: uint32)" in npu_source
    assert "let cursor = npuMmAggregateRawIndexCursor(index)" in npu_source
    assert "outResult.bank = cursor.bank" in npu_source
    assert "outResult.bit = cursor.bit" in npu_source
    assert "outResult.mask = cursor.mask" in npu_source
    assert "NpuMmAggregateSdkHelperEvidence* = object" in npu_source
    assert "proc npuMmAggregateSdkHelperEvidenceInto*" in npu_source
    assert "proc npuMmAggregateSdkHelperEvidence*" in npu_source
    assert "outResult.statusAddress = MmMiscIntSta0" in npu_source
    assert "outResult.maskAddress = MmMiscIntMask0" in npu_source
    assert "outResult.clearAddress = MmMiscIntClr0" in npu_source
    assert "outResult.statusAddress = MmMiscIntSta1" in npu_source
    assert "outResult.maskUnmaskWrite = initialMaskWord and not outResult.plan.mask" in (
        npu_source
    )
    assert "staticMmAggregateSdkBank1.clearAddress == MmMiscIntClr1" in npu_source
    assert "NpuMmAggregateSdkOffsetCandidateEvidence* = object" in npu_source
    assert "proc npuMmAggregateSdkOffsetCandidateEvidenceInto*" in npu_source
    assert "proc npuMmAggregateSdkOffsetCandidateEvidence*" in npu_source
    assert "outResult.candidateIndex = NpuCnnIrqOffset" in npu_source
    assert "npuMmAggregateRawIndexSnapshotEvidenceInto(" in npu_source
    assert "outResult.noCandidatePending =" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active MM aggregate SDK offset candidate evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model interrupt MM aggregate SDK helper evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active MM aggregate SDK helper evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK offset candidate evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model interrupt MM aggregate SDK helper evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active MM aggregate SDK helper evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    mm_aggregate_plan_block = re.search(
        r"proc npuMmAggregateRawIndexPlanInto\*\(.*?"
        r"proc npuMmAggregateRawIndexPlan\*",
        npu_source,
        re.S,
    )
    assert mm_aggregate_plan_block is not None
    for raw_formula in (
        "index < NpuMmAggregateBankCount * NpuMmAggregateRawBitmapWidth",
        "index div NpuMmAggregateRawBitmapWidth",
        "index mod NpuMmAggregateRawBitmapWidth",
        "1'u32 shl outResult.bit",
    ):
        assert raw_formula not in mm_aggregate_plan_block.group(0)

    asserted_offsets = {
        "generalCfg": "0x00",
        "intCfg": "0x04",
        "weightAddr": "0x10",
        "biasAddr": "0x14",
        "instAddr": "0x18",
        "imageAddr": "0x1C",
        "imageSeg": "0x20",
        "tfCfg0": "0x24",
        "actTable": "0x100",
    }

    for reg in manifest["blai_registers"]:
        field = reg["nim_field"].split(".", 1)[1]
        if "[" in field:
            continue
        assert (
            f"doAssert offsetof(BlaiRegs, {field}) == {asserted_offsets[field]}"
            in npu_source
        )


def test_manifest_allocator_offsets_have_named_psram_ctrl_assertions():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    allocator_offsets = manifest["encoder_archive_oracle"]["allocator_store_offsets"][
        "BLAI_MEM_alloc"
    ]
    psram_ctrl_offsets = {
        "0x54": ("weightPatchCount", "BlaiPsramCtrlWeightPatchCountOffset"),
        "0x58": ("linePatchCount", "BlaiPsramCtrlLinePatchCountOffset"),
        "0x60": ("weightPatchOutC", "BlaiPsramCtrlWeightPatchOutCOffset"),
        "0x160": ("linePatchW", "BlaiPsramCtrlLinePatchWOffset"),
        "0x264": ("psramPatchSize", "BlaiPsramCtrlPsramPatchSizeOffset"),
        "0x268": ("psramPatchCount", "BlaiPsramCtrlPsramPatchCountOffset"),
        "0x26c": ("psramMidPatchCount", "BlaiPsramCtrlPsramMidPatchCountOffset"),
    }

    assert set(allocator_offsets) == set(psram_ctrl_offsets)
    for offset, (field, constant) in psram_ctrl_offsets.items():
        assert constant in npu_source
        assert (
            f"doAssert offsetof(BlaiPsramCtrl, {field}) == {constant}" in npu_source
        )
        assert allocator_offsets[offset].startswith("PSRAM_ctrl.")


def test_manifest_sdk_paths_exist_when_vendor_cache_is_present():
    sdk_root = REPO_ROOT / "build/vendor-cache/M1s_BL808_SDK"
    if not sdk_root.exists():
        return

    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )

    for source_path in manifest["sdk_runtime_sources"].values():
        assert (sdk_root / source_path).exists()


def test_manifest_encoder_oracle_matches_local_objdump_when_vendor_cache_is_present():
    sdk_root = REPO_ROOT / "build/vendor-cache/M1s_BL808_SDK"
    if not sdk_root.exists():
        return

    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    oracle = manifest["encoder_archive_oracle"]
    archive = sdk_root / oracle["source"]
    assert archive.exists()

    nm = audit.tool_path("riscv64-unknown-elf-nm")
    objdump = audit.tool_path("llvm-objdump", "LLVM_OBJDUMP")
    summary = audit.summarize(
        archive,
        nm=nm,
        objdump=objdump,
        keywords=tuple(
            symbol.lower() for symbol in manifest["objdump"]["recovered_archive_symbols"]
        ),
    )

    for symbol, expected_calls in oracle["calls"].items():
        assert summary["calls"][symbol] == expected_calls

    for symbol, expected_offsets in oracle["allocator_store_offsets"].items():
        store_lines = "\n".join(summary["store_lines"][symbol])
        observed_offsets = {
            f"0x{int(match.group(1), 16):x}"
            for match in re.finditer(r"\bsw\s+\w+,\s+0x([0-9a-fA-F]+)\(", store_lines)
        }
        assert observed_offsets >= set(expected_offsets)


def test_hal_completion_objdump_evidence_when_artifact_is_present():
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    assert "NpuHalCompletionObjdumpEvidence* = object" in npu_source
    assert "NpuHalNetParamObjdumpEvidence* = object" in npu_source
    assert "proc npuRecoveredHalCompletionObjdumpEvidence*" in npu_source
    assert "proc npuRecoveredHalNetParamObjdumpEvidence*" in npu_source
    assert "NpuHalObjdumpIntCfgOffset* = 0x04'u32" in npu_source
    assert "NpuHalObjdumpGetIntStatusMask* = 0x200'u32" in npu_source
    assert "NpuHalObjdumpClearIntMask* = 0x100'u32" in npu_source
    assert "NpuHalObjdumpTfCfgOffset* = 0x24'u32" in npu_source
    assert "NpuHalObjdumpTfEnableMask* = 0x8000_0000'u32" in npu_source
    assert "outResult.wrapperCfgNotUsedForHalCompletion =" in npu_source
    assert "outResult.noCompletionEnableInNetParams =" in npu_source
    assert "outResult.completionSurfaceStillIntCfgStatus =" in npu_source

    objdump = (
        REPO_ROOT
        / "build/npu-recovery/hal-completion/bl80x_npu.objdump.txt"
    )
    if not objdump.exists():
        return

    text = objdump.read_text(encoding="utf-8")
    assert re.search(
        r"<NPU_Get_Int>:[\s\S]*?lw\s+a0,\s+0x4\(a5\)"
        r"[\s\S]*?andi\s+a0,\s+a0,\s+0x200",
        text,
    )
    assert re.search(
        r"<NPU_Clr_Int>:[\s\S]*?lw\s+a4,\s+0x4\(a5\)"
        r"[\s\S]*?ori\s+a4,\s+a4,\s+0x100"
        r"[\s\S]*?sw\s+a4,\s+0x4\(a5\)",
        text,
    )
    assert re.search(
        r"<NPU_Start>:[\s\S]*?lw\s+a4,\s+0x4\(a5\)"
        r"[\s\S]*?ori\s+a4,\s+a4,\s+0x1"
        r"[\s\S]*?sw\s+a4,\s+0x4\(a5\)",
        text,
    )
    assert re.search(
        r"<NPU_Stop>:[\s\S]*?lw\s+a4,\s+0x4\(a5\)"
        r"[\s\S]*?ori\s+a4,\s+a4,\s+0x2"
        r"[\s\S]*?sw\s+a4,\s+0x4\(a5\)",
        text,
    )
    assert re.search(
        r"<NPU_Set_Relu_Val>:[\s\S]*?lw\s+a4,\s+0x4\(a5\)"
        r"[\s\S]*?lui\s+a3,\s+0xffe10"
        r"[\s\S]*?and\s+a4,\s+a4,\s+a3"
        r"[\s\S]*?slli\s+a0,\s+a0,\s+0x10"
        r"[\s\S]*?sw\s+a0,\s+0x4\(a5\)",
        text,
    )
    assert re.search(
        r"<NPU_Set_TF_En>:[\s\S]*?lw\s+a5,\s+0x24\(a4\)"
        r"[\s\S]*?slli\s+a0,\s+a0,\s+0x1f"
        r"[\s\S]*?slli\s+a5,\s+a5,\s+0x1"
        r"[\s\S]*?srli\s+a5,\s+a5,\s+0x1"
        r"[\s\S]*?sw\s+a0,\s+0x24\(a4\)",
        text,
    )


def test_manifest_tracks_fetched_toolchain_converter_oracle():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    npu_source = (REPO_ROOT / "src/bl808/npu.nim").read_text(encoding="utf-8")
    toolchain = manifest["source_inputs"]["toolchain"]
    oracle = manifest["toolchain_converter_oracle"]

    assert toolchain["fetched_archive"].endswith("blai_toolchain_for_m1s.zip")
    assert len(toolchain["fetched_archive_sha256"]) == 64
    assert oracle["source"].endswith("blai_toolchain/blai_toolchain")
    assert oracle["execution_probe"]["host_direct_status"] == "blocked"
    assert (
        oracle["execution_probe"]["linux_amd64_container_status"]
        == "blocked_missing_shared_libraries"
    )
    assert {
        "libbuiltin_ops.so",
        "libtensorflowlite.so",
        "libdarknet.so",
        "libopencv_core.so.4.2",
    }.issubset(set(oracle["execution_probe"]["missing_shared_libraries"]))
    assert oracle["symbols_total"] >= 800
    assert oracle["interesting_symbols"] >= 100
    output_artifacts = oracle["converter_output_artifacts"]
    assert output_artifacts["producer_symbol"].startswith("write_blai_binaries(")
    assert [entry["file"] for entry in output_artifacts["payload_order"]] == [
        "dspinstruction_b.bin",
        "all_dspbias_b.bin",
        "all_dspweight_b.bin",
        "instruction_b.bin",
        "all_bias_b.bin",
        "all_weight_b.bin",
    ]
    assert [entry["section"] for entry in output_artifacts["payload_order"]] == [
        "cpu_instruction",
        "cpu_bias",
        "cpu_weight",
        "npu_instruction",
        "npu_bias",
        "npu_weight",
    ]
    assert "BlaiToolchainConverterOutputContract* = object" in npu_source
    assert "proc blaiToolchainConverterOutputContract*" in npu_source
    assert "blaiToolchainOutputDspInstructionBin" in npu_source
    assert "blaiGeneratedCpuInstructionSection" in npu_source
    assert "blaiToolchainOutputInstructionBin" in npu_source
    assert "blaiGeneratedNpuInstructionSection" in npu_source

    demangled = {symbol["demangled"] for symbol in oracle["key_symbols"]}
    assert "check_BLAI_NPU_RUN(int, int, int, int, int, int, int, int, int, int)" in demangled
    assert "instruction_encode(BLAI_instruction, _IO_FILE*, _IO_FILE*, _IO_FILE*)" in demangled
    assert any(symbol.startswith("fetch_tflite_weight_CONV_F(") for symbol in demangled)
    assert any(symbol.startswith("forward_CONV_tflite_8(") for symbol in demangled)
    assert any(symbol.startswith("fetch_tflite_weight_FC(") for symbol in demangled)
    assert any(symbol.startswith("forward_MATMUL_tflite_8(") for symbol in demangled)
    assert "BlaiMnistTfliteModelPlan* = object" in npu_source
    assert "BlaiMnistTfliteTensor* = object" in npu_source
    assert "BlaiMnistTfliteOperator* = object" in npu_source
    assert "BlaiMnistTfliteSupportPlan* = object" in npu_source
    assert "BlaiMnistTfliteSampleOracle* = object" in npu_source
    assert "BlaiMnistTfliteSampleLayerOracle* = object" in npu_source
    assert "BlaiMnistTfliteSampleRawOutputValidation* = object" in npu_source
    assert "BlaiMnistTfliteSampleRawOutputBlock* = enum" in npu_source
    assert "BlaiMnistTfliteBufferDigest* = array[8, uint32]" in npu_source
    assert "bufferDigest*: BlaiMnistTfliteBufferDigest" in npu_source
    assert "proc blaiMnistTfliteSampleOracle*" in npu_source
    assert "proc blaiValidateMnistTfliteSampleRawOutputInto*" in npu_source
    assert "proc blaiValidateMnistTfliteSampleRawOutput*" in npu_source
    assert "result.outputVector = [-19'i8, 7, -1, -4, -18, -41, -50, 43, -22, -4]" in (
        npu_source
    )
    assert "result.topClass = 7'u32" in npu_source
    assert (
        "mnistProjectedRaw == [237'u8, 7, 255, 252, 238, 215, 206, 43, 234, 252]"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert "BlaiReferenceTfliteFullyConnected2d* = object" in npu_source
    assert "BlaiNpuRuntimeLifecycleEvidence* = object" in npu_source
    assert "proc blaiNpuRuntimeLifecycleEvidenceInto*" in npu_source
    assert "BlaiNpuReleasePlan* = object" in npu_source
    assert "proc blaiNpuReleasePlanInto*" in npu_source
    assert "outResult.layerStorageCount = blaiOpenArrayLenU32(layers)" in npu_source
    assert "outResult.cnStorageCount = blaiOpenArrayLenU32(cnAllocated)" in npu_source
    assert "outResult.layerTableFree = npuLayersAllocated" in npu_source
    assert "BlaiNpuStopWrapperEvidence* = object" in npu_source
    assert "proc blaiNpuStopWrapperEvidenceInto*" in npu_source
    assert "outResult.returnsNoError = true" in npu_source
    assert "BlaiNpuPostStopSnapshotEvidence* = object" in npu_source
    assert "proc blaiNpuPostStopSnapshotEvidenceInto*" in npu_source
    assert "postStopRegistersCaptured*: bool" in npu_source
    assert "postStopRegisters*: NpuRegisterSnapshot" in npu_source
    assert "outResult.postStopRegistersCaptured = postStopSnapshotState.captured" in (
        npu_source
    )
    assert "outResult.stopCommandRetained = execution.postStopRegisters.stopRequested" in (
        npu_source
    )
    assert "BlaiNpuInferenceSdkSequenceEvidence* = object" in npu_source
    assert "proc blaiNpuInferenceSdkSequenceEvidenceInto*" in npu_source
    assert "BlaiForwardNpuSdkSequenceEvidence* = object" in npu_source
    assert "proc blaiForwardNpuSdkSequenceEvidenceInto*" in npu_source
    assert "BlaiForwardNpuSdkTailEvidence* = object" in npu_source
    assert "proc blaiForwardNpuSdkTailEvidenceInto*" in npu_source
    assert "proc blaiForwardNpuSdkTailEvidence*" in npu_source
    assert "outResult.timeoutDoesNotValidateOutput =" in npu_source
    assert "sdkSequenceWeightTail.temporaryFreeAfterOutputLoad" in npu_source
    assert "NpuBlaiInitCfgSdkSequenceEvidence* = object" in npu_source
    assert "proc npuBlaiInitCfgSdkSequenceEvidenceInto*" in npu_source
    assert "proc npuBlaiInitCfgSdkSequenceEvidence*" in npu_source
    assert "outResult.interruptOperationOrderMatchesSdk =" in npu_source
    assert "outResult.noHiddenCompletionEnable =" in npu_source
    assert "staticInitCfgEvidence.noHiddenCompletionEnable" in npu_source
    assert "blaiTfliteLayerFullyConnected" in npu_source
    assert "blaiMnistTfliteNpuOutputValidationPending" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveIdleCompletionEvidence* = object"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveIdleCompletionEvidenceInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveIdleCompletionEvidence*"
        in npu_source
    )
    assert "outResult.idleCompletionCandidate =" in npu_source
    assert "outResult.outputStillGated =" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceIdleOutputReadbackGateEvidence* = object"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceIdleOutputReadbackGateEvidenceInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceIdleOutputReadbackGateEvidence*"
        in npu_source
    )
    assert "outResult.diagnosticReadbackAllowed =" in npu_source
    assert "outResult.validationStillBlocked =" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceIdleOutputReadbackDiagnostic* = object"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceIdleOutputReadbackDiagnosticInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceIdleOutputReadbackDiagnostic*"
        in npu_source
    )
    assert "outResult.modelValidationStillBlocked =" in npu_source
    assert "BlaiMnistTfliteActiveOutputValidationEvidence* = object" in npu_source
    assert "blaiMnistTfliteActiveOutputValidationEvidence*" in npu_source
    assert (
        "activeReadinessFirstBlock*:\n"
        "      BlaiParsedForwardConfiguredWorkspaceOutputEquivalenceReadinessBlock"
    ) in npu_source
    assert "outResult.activeReadinessFirstBlock = active.firstBlock" in npu_source
    assert "BlaiMnistTfliteLiveCompletionRouteEvidence* = object" in npu_source
    assert "proc blaiMnistTfliteLiveCompletionRouteEvidenceInto*" in npu_source
    assert "proc blaiMnistTfliteLiveCompletionRouteEvidence*" in npu_source
    assert "outResult.noRawPending =" in npu_source
    assert "outResult.noUnmaskedPending =" in npu_source
    assert "outResult.noMaskedOnlyPending =" in npu_source
    assert "outResult.liveRouteMatchesModelFrontier =" in npu_source
    assert "BlaiMnistTfliteLiveValidationNextStepEvidence* = object" in npu_source
    assert "BlaiMnistTfliteLiveValidationNextAction* = enum" in npu_source
    assert "proc blaiMnistTfliteLiveValidationNextStepEvidenceInto*" in npu_source
    assert "proc blaiMnistTfliteLiveValidationNextStepEvidence*" in npu_source
    assert "activeFirstBlock*: BlaiMnistTfliteActiveOutputValidationBlock" in npu_source
    assert (
        "liveRouteFirstBlock*: BlaiMnistTfliteLiveCompletionRouteBlock"
        in npu_source
    )
    assert "outResult.activeFirstBlock = active.firstBlock" in npu_source
    assert "outResult.liveRouteFirstBlock = liveRoute.firstBlock" in npu_source
    assert "BlaiMnistTfliteD0SyntheticContrastEvidence* = object" in npu_source
    assert "proc blaiMnistTfliteD0SyntheticContrastEvidenceInto*" in npu_source
    assert "proc blaiMnistTfliteD0SyntheticContrastEvidence*" in npu_source
    assert "mnistActiveFirstBlock*: BlaiMnistTfliteActiveOutputValidationBlock" in (
        npu_source
    )
    assert (
        "mnistLiveRouteFirstBlock*: BlaiMnistTfliteLiveCompletionRouteBlock"
        in npu_source
    )
    assert "mnistNextAction*: BlaiMnistTfliteLiveValidationNextAction" in npu_source
    assert "outResult.mnistActiveFirstBlock = mnistNext.activeFirstBlock" in (
        npu_source
    )
    assert "outResult.mnistLiveRouteFirstBlock = mnistNext.liveRouteFirstBlock" in (
        npu_source
    )
    assert "outResult.mnistNextAction = mnistNext.nextAction" in npu_source
    assert "outResult.mustResolveCompletionRoute =" in npu_source
    assert "outResult.noPrematureReadback =" in npu_source
    assert (
        "outResult.nextAction = blaiMnistLiveValidationResolveCompletionRoute"
        in npu_source
    )
    assert "outResult.syntheticProvesDataMovementOnly =" in npu_source
    assert "outResult.generatedModelStillRequiresCompletionRoute =" in npu_source
    assert "staticMnistD0Contrast.nextWorkIsCompletionRoute" in npu_source
    assert (
        "BlaiParsedForwardConfiguredWorkspaceCompletionRouteControlReadinessEvidence* = object"
        in npu_source
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceCompletionRouteBindingSafetyEvidence* = object"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceCompletionRouteControlReadinessEvidenceInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceCompletionRouteControlReadinessEvidence*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceCompletionRouteBindingSafetyEvidenceInto*"
        in npu_source
    )
    assert "outResult.mustNotEnableM0Alias =" in npu_source
    assert "outResult.nextRequiresVerifiedRoute =" in npu_source
    assert "outResult.firstDeferredOperation = route.firstDeferredOperation" in npu_source
    assert "outResult.mustBindRouteBeforeReadback =" in npu_source
    assert (
        "NPU model parsed configured workspace fixture active completion route control readiness evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active completion route control readiness evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active initCfg SDK sequence evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active initCfg SDK sequence evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active completion route binding safety evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active completion route binding safety evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active idle completion evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active idle completion evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active idle output readback gate diagnostic"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active idle output readback gate diagnostic"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active idle output readback diagnostic evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active idle output readback diagnostic evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceActiveLiveRouteEvidence* = object"
        in npu_source
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceCompletionRouteProbeAction* = enum"
        in npu_source
    )
    assert (
        "BlaiParsedForwardConfiguredWorkspaceCompletionRouteProbePlan* = object"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveLiveRouteEvidenceInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceActiveLiveRouteEvidence*"
        in npu_source
    )
    assert "outResult.routeMatchesLiveSnapshot =" in npu_source
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceCompletionRouteProbePlanInto*"
        in npu_source
    )
    assert (
        "proc blaiParsedForwardConfiguredWorkspaceCompletionRouteProbePlan*"
        in npu_source
    )
    assert "outResult.routeProbeBeforeReadback =" in npu_source
    assert (
        "blaiParsedConfiguredCompletionRouteProbeVerifyMmSubroute"
        in npu_source
    )
    assert (
        "NPU model parsed configured workspace fixture active live route evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model parsed configured workspace fixture active completion route probe plan"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active completion route probe plan"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model parsed configured workspace fixture active live route evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model MNIST TFLite live completion route evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model MNIST TFLite live completion route evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model MNIST TFLite live validation next action"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model MNIST TFLite active output validation readiness block"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model MNIST TFLite live validation next active block"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "NPU model MNIST TFLite live validation next route block"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model MNIST TFLite live validation next action"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model MNIST TFLite active output validation readiness block"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model MNIST TFLite live validation next active block"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model MNIST TFLite live validation next route block"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "NpuIntCfgSdkCommandEvidence* = object" in npu_source
    assert "proc npuIntCfgSdkCommandEvidenceInto*" in npu_source
    assert "proc npuIntCfgSdkCommandEvidence*" in npu_source
    assert "outResult.startMatchesSdk =" in npu_source
    assert "outResult.getIntMatchesSdk =" in npu_source
    assert (
        "NPU model int cfg SDK command evidence"
        in (REPO_ROOT / "examples/m0_npu_model_smoke_test.nim").read_text(
            encoding="utf-8"
        )
    )
    assert (
        "[PASS] NPU model int cfg SDK command evidence"
        in (REPO_ROOT / "tools/hardware_validation.json").read_text(
            encoding="utf-8"
        )
    )
    assert "proc blaiMnistTfliteModelPlan*()" in npu_source
    assert "proc blaiMnistTfliteSupportPlan*(" in npu_source
    assert "proc blaiMnistTflitePersistentBuffersIdentified*" in npu_source
    assert "proc blaiReferenceTfliteFullyConnected2d*" in npu_source
    assert "persistentTensorBufferBytes = 36300'u32" in npu_source
    assert "BlaiMnistTfliteConv3WeightDigest*" in npu_source
    assert "BlaiMnistTfliteFcWeightDigest*" in npu_source
    assert "persistentBuffersIdentified*: bool" in npu_source
    assert "result.persistentBuffersIdentified =" in npu_source
    assert "0x3B80_8081'u32" in npu_source
    assert "0x3E99_258E'u32" in npu_source
    assert "fullyConnectedReferenceSupported = true" in npu_source


def test_toolchain_converter_oracle_matches_local_scan_when_present():
    toolchain_root = REPO_ROOT / "build/vendor-cache/blai_npu_toolchain"
    converter = toolchain_root / "blai_toolchain/blai_toolchain"
    if not converter.exists():
        return

    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    oracle = manifest["toolchain_converter_oracle"]

    inputs = audit.iter_inputs([toolchain_root], ("blai", "npu"))
    assert converter in inputs

    nm = audit.tool_path("llvm-nm", "LLVM_NM")
    objdump = audit.tool_path("llvm-objdump", "LLVM_OBJDUMP")
    summary = audit.summarize(
        converter,
        nm=nm,
        objdump=objdump,
        keywords=tuple(k.lower() for k in audit.DEFAULT_KEYWORDS),
    )

    assert summary["symbols_total"] == oracle["symbols_total"]
    assert len(summary["interesting_symbols"]) == oracle["interesting_symbols"]
    observed = {
        symbol["name"]
        for symbol in audit.parse_symbols(nm, converter)
        if "name" in symbol
    }
    for symbol in oracle["key_symbols"]:
        assert symbol["mangled"] in observed

    assert summary["register_hits"] == oracle["register_hits"] == {}
    assert {
        item["name"] for item in summary["interesting_symbols"]
    } >= {
        "BLAI_ROUND",
        "_Z18check_BLAI_NPU_RUNiiiiiiiiii",
        "_Z18instruction_encode16BLAI_instructionP8_IO_FILES1_S1_",
        "_Z21BLAI_tflite_inferenceN7darknet7networkEPSt10unique_ptrIN6tflite4impl11InterpreterESt14default_deleteIS4_EEP13TfLiteContextiN4blai7blaicfgEP9BLAI_dataPc17tflite_input_data",
    }
