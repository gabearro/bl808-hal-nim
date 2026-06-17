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
    assert "proc blaiCpuExtraStorageCursor*(inputIndex: uint32" in npu_source
    assert "proc blaiYoloBiasPairIndex*(maskIndex, total: uint32)" in npu_source
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
    assert "proc blaiCpuStreamStartLayerCursor*(cursor: BlaiCpuStreamCursor" in npu_source
    assert "let layerCursor = blaiU32ArrayIndexCursor(index, layers.len)" in npu_source
    assert "let extraCursor = blaiU32ArrayIndexCursor(index, extraInputs.len)" in npu_source
    assert "let yoloCursor = blaiU32ArrayIndexCursor(index, yoloStorage.len)" in npu_source
    assert "let layerCursor = blaiI32ArrayIndexCursor(index, layers.len)" in npu_source
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
    assert "BlaiFetchInputPatchCursor* = object" in npu_source
    assert "proc blaiFetchInputPatchCursor*(" in npu_source
    assert "let inputPatch = blaiFetchInputPatchCursor(" in npu_source
    assert "outResult.inputPatchCount[inputPatch.slotIndex] = inputPatch.patchCount" in npu_source
    assert "totalInputPatches = inputPatch.nextTotalPatches" in npu_source
    assert "outResult.inputPatchCount[inputCursor.index] = patchCount" not in npu_source
    assert "totalInputPatches += patchCount" not in npu_source
    assert "BlaiFetchInputSlotCursor* = object" in npu_source
    assert "proc blaiFetchInputSlotCursor*(" in npu_source
    assert "let inputSlot = blaiFetchInputSlotCursor(" in npu_source
    assert "outResult.inputSlots[inputSlot.slotIndex] = inputSlot.slot" in npu_source
    assert "cursor = inputSlot.nextSlot" in npu_source
    assert "outResult.inputSlots[inputCursor.index] = cursor" not in npu_source
    assert "cursor += outResult.inputPatchCount[inputCursor.index]" not in npu_source
    assert "BlaiFetchOutputSlotPlan* = object" in npu_source
    assert "proc blaiFetchOutputSlotPlan*(" in npu_source
    assert "BlaiFetchLayerApplyPlan* = object" in npu_source
    assert "proc blaiFetchLayerApplyPlan*(" in npu_source
    assert "BlaiFetchInputSlotApplyPlan* = object" in npu_source
    assert "proc blaiFetchInputSlotApplyPlan*(" in npu_source
    assert "BlaiFetchOutputSlotApplyPlan* = object" in npu_source
    assert "proc blaiFetchOutputSlotApplyPlan*(" in npu_source
    assert "BlaiFetchPatchSizeApplyPlan* = object" in npu_source
    assert "proc blaiFetchPatchSizeApplyPlan*(" in npu_source
    assert "let outputSlots = blaiFetchOutputSlotPlan(" in npu_source
    assert "outResult.midOutputSlot = outputSlots.midOutputSlot" in npu_source
    assert "outResult.outputSlot = outputSlots.outputSlot" in npu_source
    assert "outResult.dramPatchCount = outputSlots.dramPatchCount" in npu_source
    assert "let inputApply = blaiFetchInputSlotApplyPlan(" in npu_source
    assert "ctrl.sramIn[inputApply.slotIndex] = inputApply.sramSlot" in npu_source
    assert "let outputApply = blaiFetchOutputSlotApplyPlan(" in npu_source
    assert "ctrl.sramMidOut = outputApply.sramMidOut" in npu_source
    assert "ctrl.sramOut[0] = outputApply.sramOut0" in npu_source
    assert "let patchSizeApply = blaiFetchPatchSizeApplyPlan(" in npu_source
    assert "ctrl.psramPatchSize = patchSizeApply.patchSize" in npu_source
    assert "let layerApply = blaiFetchLayerApplyPlan(plan.dramPatchCount)" in npu_source
    assert "layer.dramPatchNum = layerApply.dramPatchNum" in npu_source
    fetch_memory_block = re.search(
        r"proc blaiPlanFetchMemoryInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert fetch_memory_block is not None
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
    assert "BlaiRouteDescriptorNextInputCursor* = object" in npu_source
    assert "proc blaiRouteDescriptorNextInputCursor*(" in npu_source
    assert "result.logicalInput = stepIndex + 1'u32" in npu_source
    assert "result.cnSlot = stepCursor.index" in npu_source
    assert "let nextInput = blaiRouteDescriptorNextInputCursor(" in npu_source
    assert "outResult.steps[nextInput.cnSlot] = BlaiRouteDescriptorStep" in npu_source
    assert "layer.cn[nextInput.cnSlot]" in npu_source
    assert "index + 1'u32 < nonNegativeU32(layer.inputNum)" not in npu_source
    assert "BlaiRouteDescriptorStepPosition* = object" in npu_source
    assert "proc blaiRouteDescriptorStepPosition*(" in npu_source
    assert "let stepCursor = blaiRouteDescriptorStepCursor(stepIndex)" in npu_source
    assert "result.stepSlot = stepCursor.index" in npu_source
    assert "result.last = stepIndex == descriptorCount - 1'u32" in npu_source
    assert "let stepPosition =" in npu_source
    assert "let step = routeLoop.steps[stepPosition.stepSlot]" in npu_source
    assert "descriptorHalt = descriptorHalt and stepPosition.last" in npu_source
    assert "stepIndex + 1'u32 == routeLoop.descriptorCount" not in npu_source
    assert "let packedCursor = blaiU32ArrayIndexCursor(packedIndex, BlaiMaxInputNum)" in npu_source
    assert npu_source.count(
        "let packedCursor = blaiU32ArrayIndexCursor(packedIndex, BlaiMaxInputNum)"
    ) >= 2
    assert "result.packedIndex = packedCursor.index" in npu_source
    assert "let storageCursor = blaiCpuExtraStorageCursor(input.inputIndex)" in npu_source
    assert "let storageCursor = blaiCpuExtraStorageCursor(inputIndex)" in npu_source
    assert "storage.inLayerMemN[storageCursor.storageIndex]" in npu_source
    assert "storage.tfInputMultiplierExtra[storageCursor.storageIndex]" in npu_source
    assert "activeIndex*: int" in npu_source
    assert (
        "let activeCursor = blaiU32ArrayIndexCursor(pairIndex.maskIndex, BlaiMaxYoloTotal)"
        in npu_source
    )
    assert (
        "let widthCursor = blaiU32ArrayIndexCursor(pairIndex.widthIndex, BlaiMaxYoloBiasNum)"
        in npu_source
    )
    assert (
        "pairIndex.heightIndex, BlaiMaxYoloBiasNum)"
        in npu_source
    )
    assert "result.activeIndex = activeCursor.index" in npu_source
    assert "result.widthIndex = widthCursor.index" in npu_source
    assert "result.heightIndex = heightCursor.index" in npu_source
    assert "storage.biasPairActive[cursor.activeIndex] = true" in npu_source
    assert "result.multipliers[inputCursor.index]" in npu_source
    assert "let cursor = blaiU32ArrayIndexCursor(slot, BlaiMaxInputNum)" in npu_source
    assert "result.slotIndex = cursor.index" in npu_source
    assert "BlaiRouteNextSlotIndex* = object" in npu_source
    assert "BlaiRoutePreviousOutputSlotCursor* = object" in npu_source
    assert "BlaiRouteOutputSlotCursor* = object" in npu_source
    assert "BlaiRouteInputPatchTotalCursor* = object" in npu_source
    assert "BlaiRouteFirstOutputSlotPlan* = object" in npu_source
    assert "BlaiRouteIntermediateChannelCursor* = object" in npu_source
    assert "BlaiRouteIntermediateOutputSlotPlan* = object" in npu_source
    assert "BlaiRouteSramLayerApplyPlan* = object" in npu_source
    assert "BlaiRouteOutputSlotApplyPlan* = object" in npu_source
    assert "proc blaiRouteNextSlotIndex*(slot: uint32)" in npu_source
    assert "proc blaiRoutePreviousOutputSlotCursor*(" in npu_source
    assert "proc blaiRouteOutputSlotCursor*(" in npu_source
    assert "proc blaiRouteInputPatchTotalCursor*(" in npu_source
    assert "proc blaiRouteFirstOutputSlotPlan*(" in npu_source
    assert "proc blaiRouteIntermediateChannelCursor*(" in npu_source
    assert "proc blaiRouteIntermediateOutputSlotPlan*(" in npu_source
    assert "proc blaiRouteSramLayerApplyPlan*(" in npu_source
    assert "proc blaiRouteOutputSlotApplyPlan*(" in npu_source
    assert "let nextSlot = blaiRouteNextSlotIndex(slot)" in npu_source
    assert "let inputTotal = blaiRouteInputPatchTotalCursor(" in npu_source
    assert "totalInputPatches = inputTotal.nextTotalPatches" in npu_source
    assert "let firstOutput = blaiRouteFirstOutputSlotPlan(" in npu_source
    assert "outResult.outputSlots[0] = firstOutput.outputSlot" in npu_source
    assert "cursor = firstOutput.nextCursor" in npu_source
    assert "let channelCursor = blaiRouteIntermediateChannelCursor(" in npu_source
    assert "cumulativeChannels = channelCursor.nextCumulativeChannels" in npu_source
    assert "let outputCommit = blaiRouteIntermediateOutputSlotPlan(" in npu_source
    assert "outResult.outputSlots[outputCommit.slotIndex] = outputCommit.outputSlot" in npu_source
    assert "outResult.outputSlotCount = outputCommit.nextOutputSlotCount" in npu_source
    assert "cursor = outputCommit.nextCursor" in npu_source
    assert "let layerApply = blaiRouteSramLayerApplyPlan(" in npu_source
    assert "ctrl.lineW0 = layerApply.lineW0" in npu_source
    assert "layer.groups = layerApply.groups" in npu_source
    assert "layer.dramPatchNum = layerApply.dramPatchNum" in npu_source
    assert "let outputApply = blaiRouteOutputSlotApplyPlan(" in npu_source
    assert "ctrl.sramOut[outputApply.slotIndex] = outputApply.sramSlot" in npu_source
    route_next_cursor_block = re.search(
        r"proc blaiRouteNextSlotCursor\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_next_cursor_block is not None
    assert "slot + 1'u32" not in route_next_cursor_block.group(0)
    route_sram_fetch_block = re.search(
        r"proc blaiRouteStepFetchMemoryPlan\(plan: BlaiRouteSramSlotPlan,.*?proc ",
        npu_source,
        re.S,
    )
    assert route_sram_fetch_block is not None
    assert "let previousOutput = blaiRoutePreviousOutputSlotCursor" in (
        route_sram_fetch_block.group(0)
    )
    assert "step.index - 1'u32" not in route_sram_fetch_block.group(0)
    assert "let outputSlot = blaiRouteOutputSlotCursor(" in npu_source
    route_slot_plan_block = re.search(
        r"proc blaiPlanRouteSramSlotsInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert route_slot_plan_block is not None
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
    assert "blaiAllocatorFieldValue(plan.outputSlots[outputSlot.slotIndex])" not in (
        route_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = blaiAllocatorFieldValue(plan.memory.patchSize)" not in (
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
    assert "BlaiMemAllocPatchSegmentCursor* = object" in npu_source
    assert "proc blaiMemAllocPatchSegmentCursor*(" in npu_source
    assert "result.patchSlot = patchCursor.index" in npu_source
    assert "result.last = patchIndex == patchCount - 1'u32" in npu_source
    assert "let patchSegment = blaiMemAllocPatchSegmentCursor(i, patchCount)" in npu_source
    assert "outResult.linePatchW[patchSegment.patchSlot] = patchWidth" in npu_source
    assert "BlaiMemAllocLinePatchProbe* = object" in npu_source
    assert "BlaiMemAllocLinePatchApplyPlan* = object" in npu_source
    assert "proc blaiMemAllocLinePatchProbe*(" in npu_source
    assert "proc blaiMemAllocLinePatchApplyPlan*(" in npu_source
    assert (
        "let probe = blaiMemAllocLinePatchProbe(\n"
        "      layer, patchCount, route.channels, route.routed, upsampleLayer)"
        in npu_source
    )
    assert "if probe.fits:" in npu_source
    assert "outResult.inputLineBytes = probe.inputLineBytes" in npu_source
    assert "outResult.outputLineBytes = probe.outputLineBytes" in npu_source
    assert "remaining = blaiSaturatingSubU32(remaining, probe.inputLine)" in npu_source
    line_patch_block = re.search(
        r"proc blaiPlanLinePatchMemAllocInto\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert line_patch_block is not None
    assert "routeKernelPadding =" not in line_patch_block.group(0)
    assert "outputLineBase =" not in line_patch_block.group(0)
    line_patch_apply_block = re.search(
        r"proc blaiApplyLinePatchMemAlloc\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert line_patch_apply_block is not None
    assert "let applyPlan = blaiMemAllocLinePatchApplyPlan(plan)" in (
        line_patch_apply_block.group(0)
    )
    assert "ctrl.linePatchCount = applyPlan.linePatchCount" in (
        line_patch_apply_block.group(0)
    )
    assert "ctrl.linePatchW[i] = applyPlan.linePatchW[i]" in (
        line_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.linePatchCount)" not in (
        line_patch_apply_block.group(0)
    )
    assert "blaiAllocatorFieldValue(plan.linePatchW[i])" not in (
        line_patch_apply_block.group(0)
    )
    assert (
        "let patchSegment = blaiMemAllocPatchSegmentCursor(patchIndex, weightPatchCount)"
        in npu_source
    )
    assert "BlaiMemAllocWeightPatchStoreEntry* = object" in npu_source
    assert "BlaiMemAllocPatchCountPlan* = object" in npu_source
    assert "BlaiMemAllocWeightPatchApplyPlan* = object" in npu_source
    assert "BlaiMemAllocPatchBranchPlan* = object" in npu_source
    assert "BlaiMemAllocControlApplyPlan* = object" in npu_source
    assert "proc blaiMemAllocWeightPatchStoreEntry*(" in npu_source
    assert "proc blaiMemAllocPatchCountPlan*(" in npu_source
    assert "proc blaiMemAllocWeightPatchApplyPlan*(" in npu_source
    assert "proc blaiPlanPatchMemAllocBranchInto*(" in npu_source
    assert "proc blaiPlanPatchMemAllocBranch*(" in npu_source
    assert "proc blaiMemAllocControlApplyPlan*(" in npu_source
    assert "proc blaiApplyMemAllocControlApplyPlan*(" in npu_source
    assert (
        "let patchStore = blaiMemAllocWeightPatchStoreEntry(\n"
        "      patchIndex, result.weightPatchCount, emittedChannels, outputChannels,"
        in npu_source
    )
    assert "result.weightPatchOutC[patchStore.patchSlot] = patchStore.patchOutC" in npu_source
    assert "emittedChannels = patchStore.nextEmittedChannels" in npu_source
    assert "let countPlan = blaiMemAllocPatchCountPlan(" in npu_source
    assert "result.psramPatchCount = countPlan.psramPatchCount" in npu_source
    assert "result.psramMidPatchCount = countPlan.psramMidPatchCount" in npu_source
    weight_patch_apply_block = re.search(
        r"proc blaiApplyHighWeightPatchMemAlloc\*\(.*?proc ",
        npu_source,
        re.S,
    )
    assert weight_patch_apply_block is not None
    assert "let applyPlan = blaiMemAllocWeightPatchApplyPlan(plan)" in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchCount = applyPlan.weightPatchCount" in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.weightPatchOutC[i] = applyPlan.weightPatchOutC[i]" in (
        weight_patch_apply_block.group(0)
    )
    assert "ctrl.psramPatchSize = applyPlan.psramPatchSize" in (
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
    assert "BlaiMemAllocSinglePatchApplyPlan* = object" in npu_source
    assert "proc blaiMemAllocSinglePatchShape*(" in npu_source
    assert "proc blaiMemAllocSinglePatchApplyPlan*(" in npu_source
    assert "let shape = blaiMemAllocSinglePatchShape(layer)" in npu_source
    assert "outResult.psramPatchSize = shape.psramPatchSize" in npu_source
    assert "outResult.midSource = shape.midSource" in npu_source
    assert "let applyPlan = blaiMemAllocSinglePatchApplyPlan(plan)" in npu_source
    assert "ctrl.weightPatchCount = applyPlan.weightPatchCount" in npu_source
    assert "ctrl.weightPatchOutC[0] = applyPlan.firstWeightPatchOutC" in npu_source
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
    assert "i + 1'u32 == patchCount" not in npu_source
    assert "patchIndex + 1'u32 == result.weightPatchCount" not in npu_source
    assert "BlaiMemAllocWeightPressureMode* = enum" in npu_source
    assert "BlaiMemAllocWeightPatchPressure* = object" in npu_source
    assert "BlaiMemAllocPsramPatchPressure* = object" in npu_source
    assert "proc blaiMemAllocWeightPatchPressure*(" in npu_source
    assert "proc blaiMemAllocPsramPatchPressure*(" in npu_source
    assert "result.mode = blaiWeightPressureOneByOne" in npu_source
    assert "result.mode = blaiWeightPressureDilatedOrLarge" in npu_source
    assert "result.mode = blaiWeightPressureSmallKernel" in npu_source
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
    assert "BlaiMemAllocRouteInputCursor* = object" in npu_source
    assert "proc blaiMemAllocRouteInputCursor*(" in npu_source
    assert "let routeInput = blaiMemAllocRouteInputCursor(i)" in npu_source
    assert "layer.cn[routeInput.cnIndex]" in npu_source
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
    assert "proc blaiFetchPatchBudgetPlan*(" in npu_source
    assert "let budgetPlan = blaiFetchPatchBudgetPlan(" in npu_source
    assert "outResult.patchBudget = budgetPlan.budget" in npu_source
    assert "totalInputPatches <= budgetPlan.budget" in npu_source
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
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, layers.len)" in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, extraInputs.len)" in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, yoloStorage.len)" in npu_source
    assert "blaiU32ArrayIndexCursor(result.storedLayerCount, parsedLayers.len)" in npu_source
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
    assert "outResult.descriptorCount > BlaiMaxRouteInputNumU32" in npu_source
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
    assert "let limit = blaiBoundedU32Count(parsed.storedLayerCount, layers.len)" in npu_source
    assert "let layerCount = blaiBoundedU32Count(outResult.readiness.layerCount, layers.len)" in npu_source
    assert "let layerCount = blaiBoundedU32Count(currentReadiness.layerCount, layers.len)" in npu_source
    assert "let layerCount = blaiBoundedU32Count(plan.readiness.layerCount, layers.len)" in npu_source
    assert "blaiBoundedU32Count(\n      plan.memory.inputCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(\n      plan.outputSlotCount, BlaiMaxInputNum)" in npu_source
    assert "blaiBoundedU32Count(\n      plan.inputCount, BlaiMaxInputNum)" in npu_source
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
    assert "result.firstReleaseOverflowLayer = releaseLayer.int32" not in npu_source
    assert "result.firstReleaseOverflowLayer = releaseMidLayer.int32" not in npu_source
    assert "result.firstGraphMapOverflowLayer = layerIndex.int32" not in npu_source
    assert "graphLayerToLayer[graph0Cursor.mapIndex] = layerIndex.int32" not in npu_source
    assert "graphLayerToLayer[graph1Cursor.mapIndex] = layerIndex.int32" not in npu_source
    assert "stagedLayer.c = step.descriptorC1.int32" not in npu_source
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
    assert "NpuLayerRunPlan" in manifest["execution_status"]["typed_status"]
    forward_types = set(manifest["recovered_forward_npu_planning"]["nim_types"])
    forward_procs = set(manifest["recovered_forward_npu_planning"]["nim_procs"])
    assert "BlaiNpuCompletionStartPlan" in forward_types
    assert "BlaiNpuCompletionExitPlan" in forward_types
    assert "NpuInterruptPollTerminalPlan" in forward_types
    assert "BlaiNpuPollingWaitEvidencePlan" in forward_types
    assert "BlaiNpuCompletionSideEffectPlan" in forward_types
    assert "blaiNpuCompletionStartPlanInto" in forward_procs
    assert "blaiNpuCompletionStartPlan" in forward_procs
    assert "blaiNpuCompletionExitPlanInto" in forward_procs
    assert "blaiNpuCompletionExitPlan" in forward_procs
    assert "npuInterruptPollTerminalPlanInto" in forward_procs
    assert "npuInterruptPollTerminalPlan" in forward_procs
    assert "blaiNpuPollingWaitEvidencePlanInto" in forward_procs
    assert "blaiNpuPollingWaitEvidencePlan" in forward_procs
    assert "blaiNpuCompletionSideEffectPlanInto" in forward_procs
    assert "blaiNpuCompletionSideEffectPlan" in forward_procs
    assert "BlaiNpuCompletionStartPlan* = object" in npu_source
    assert "BlaiNpuCompletionExitPlan* = object" in npu_source
    assert "NpuInterruptPollTerminalPlan* = object" in npu_source
    assert "BlaiNpuPollingWaitEvidencePlan* = object" in npu_source
    assert "BlaiNpuCompletionSideEffectPlan* = object" in npu_source
    assert "proc blaiNpuCompletionStartPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionStartPlan*(" in npu_source
    assert "proc blaiNpuCompletionExitPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionExitPlan*(" in npu_source
    assert "proc npuInterruptPollTerminalPlanInto*(" in npu_source
    assert "proc npuInterruptPollTerminalPlan*(" in npu_source
    assert "proc blaiNpuPollingWaitEvidencePlanInto*(" in npu_source
    assert "proc blaiNpuPollingWaitEvidencePlan*(" in npu_source
    assert "proc blaiNpuCompletionSideEffectPlanInto*(" in npu_source
    assert "proc blaiNpuCompletionSideEffectPlan*(" in npu_source
    assert "NpuLayerRunPlan* = object" in npu_source
    assert "proc npuPlanLayerRunInto*(" in npu_source
    assert "proc npuPlanLayerRun*(" in npu_source
    assert "outResult.waitPlan = npuPlanCompletionWait(" in npu_source
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
    assert "npuActivationTableWordCursor" in (
        manifest["recovered_forward_npu_planning"]["nim_procs"]
    )
    assert "NpuActivationTableWordCursor* = object" in npu_source
    assert "proc npuActivationTableWordCursor*(wordIndex: uint32)" in npu_source
    assert "let wordCursor = npuActivationTableWordCursor(wordIndex)" in npu_source
    assert "outResult.firstEntryIndex = wordCursor.firstEntryIndex" in npu_source
    assert "outResult.registerOffset = wordCursor.registerOffset" in npu_source
    assert "outResult.registerAddress = wordCursor.registerAddress" in npu_source
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
    assert "NpuMmAggregateRawIndexCursor* = object" in npu_source
    assert "proc npuMmAggregateRawIndexCursor*(index: uint32)" in npu_source
    assert "let cursor = npuMmAggregateRawIndexCursor(index)" in npu_source
    assert "outResult.bank = cursor.bank" in npu_source
    assert "outResult.bit = cursor.bit" in npu_source
    assert "outResult.mask = cursor.mask" in npu_source
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

    assert summary["register_hits"] == oracle["register_hits"] == {}
    assert {
        item["name"] for item in summary["interesting_symbols"]
    } >= {
        "BLAI_MEM_alloc",
        "Load_NPU_weights",
        "fetch_BLAI_data_general",
        "fetch_BLAI_data_route",
    }
