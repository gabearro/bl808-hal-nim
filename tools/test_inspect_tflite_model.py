"""Tests for the dependency-free TFLite metadata inspector."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import inspect_tflite_model as tflite_inspect


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_rejects_non_tflite_file(tmp_path):
    model = tmp_path / "not-a-model.tflite"
    model.write_bytes(b"not tflite")

    with pytest.raises(ValueError, match="TFL3"):
        tflite_inspect.inspect_tflite(model)


def test_manifest_tracks_mnist_tflite_oracle_metadata():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    summary = manifest["toolchain_converter_oracle"]["sample_model_summary"]

    assert summary["identifier"] == "TFL3"
    assert summary["version"] == 3
    assert summary["operator_codes"] == ["CONV_2D", "RESHAPE", "FULLY_CONNECTED"]
    assert summary["main_subgraph"]["operator_codes"] == [
        "CONV_2D",
        "CONV_2D",
        "CONV_2D",
        "CONV_2D",
        "RESHAPE",
        "FULLY_CONNECTED",
    ]
    assert summary["main_subgraph"]["input"]["shape"] == [1, 28, 28, 1]
    assert summary["main_subgraph"]["input"]["type"] == "INT8"
    assert summary["main_subgraph"]["input"]["quantization"]["zero_point"] == [-128]
    assert summary["main_subgraph"]["output"]["shape"] == [1, 10]
    assert summary["main_subgraph"]["output"]["type"] == "INT8"
    assert summary["main_subgraph"]["output"]["quantization"]["zero_point"] == [4]
    assert summary["main_subgraph"]["operators"][0] == {
        "opcode": "CONV_2D",
        "inputs": [0, 2, 3],
        "outputs": [12],
    }
    assert summary["main_subgraph"]["operators"][-1] == {
        "opcode": "FULLY_CONNECTED",
        "inputs": [16, 10, 11],
        "outputs": [17],
    }
    assert summary["main_subgraph"]["persistent_tensor_buffer_bytes"] == 36300
    assert [tensor["buffer_bytes"] for tensor in summary["main_subgraph"]["persistent_tensors"]] == [
        8,
        108,
        48,
        2592,
        96,
        10368,
        192,
        20736,
        192,
        1920,
        40,
    ]
    assert summary["main_subgraph"]["persistent_tensors"][9]["buffer_sha256"] == (
        "b36f1cfc3fa950d21f2f6373add8120b18f9b2f6f495d2e09f7e659ebe39f04d"
    )
    assert summary["main_subgraph"]["persistent_tensors"][10]["buffer_sha256"] == (
        "94984443542a0fc7bd5d344bfe366934b99235dbd8ba420f705116ebe7db3e93"
    )


def test_mnist_tflite_oracle_matches_local_model_when_present():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    oracle = manifest["toolchain_converter_oracle"]
    model = REPO_ROOT / oracle["sample_model"]
    if not model.exists():
        return

    observed = tflite_inspect.inspect_tflite(model)
    expected = oracle["sample_model_summary"]
    main = observed["subgraphs"][0]

    assert observed["identifier"] == expected["identifier"]
    assert observed["version"] == expected["version"]
    assert observed["description"] == expected["description"]
    assert observed["size"] == expected["size"]
    assert observed["operator_code_count"] == expected["operator_code_count"]
    assert observed["operator_codes"] == expected["operator_codes"]
    assert observed["subgraph_count"] == expected["subgraph_count"]
    assert observed["buffer_count"] == expected["buffer_count"]
    assert main["name"] == expected["main_subgraph"]["name"]
    assert main["tensor_count"] == expected["main_subgraph"]["tensor_count"]
    assert main["operator_count"] == expected["main_subgraph"]["operator_count"]
    assert main["operator_codes"] == expected["main_subgraph"]["operator_codes"]
    assert main["inputs"][0]["name"] == expected["main_subgraph"]["input"]["name"]
    assert main["inputs"][0]["shape"] == expected["main_subgraph"]["input"]["shape"]
    assert main["inputs"][0]["type"] == expected["main_subgraph"]["input"]["type"]
    assert main["inputs"][0]["quantization"] == (
        expected["main_subgraph"]["input"]["quantization"]
    )
    assert main["outputs"][0]["name"] == expected["main_subgraph"]["output"]["name"]
    assert main["outputs"][0]["shape"] == expected["main_subgraph"]["output"]["shape"]
    assert main["outputs"][0]["type"] == expected["main_subgraph"]["output"]["type"]
    assert main["outputs"][0]["quantization"] == (
        expected["main_subgraph"]["output"]["quantization"]
    )
    assert [
        {
            "opcode": operator["opcode"],
            "inputs": operator["inputs"],
            "outputs": operator["outputs"],
        }
        for operator in main["operators"]
    ] == expected["main_subgraph"]["operators"]
    persistent_tensors = [
        {
            "index": index,
            "name": tensor["name"],
            "shape": tensor["shape"],
            "type": tensor["type"],
            "buffer_bytes": tensor["buffer_bytes"],
            "buffer_sha256": tensor["buffer_sha256"],
        }
        for index, tensor in enumerate(main["tensors"])
        if tensor["buffer_bytes"] > 0
    ]
    assert persistent_tensors == expected["main_subgraph"]["persistent_tensors"]
    assert sum(tensor["buffer_bytes"] for tensor in persistent_tensors) == (
        expected["main_subgraph"]["persistent_tensor_buffer_bytes"]
    )


def test_mnist_sample_input_oracle_tracks_expected_known_answer():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    oracle = manifest["toolchain_converter_oracle"]["sample_input_oracle"]

    assert oracle["image"] == (
        "build/vendor-cache/blai_npu_toolchain/blai_toolchain/image/a.bmp"
    )
    assert oracle["image_sha256"] == (
        "8d6369947f5291c9294feb0b59c13550cb914202c1c013360d58134fbf55193e"
    )
    assert oracle["image_width"] == 28
    assert oracle["image_height"] == 28
    assert oracle["image_bits_per_pixel"] == 8
    assert oracle["image_pixel_sum"] == 13635
    assert oracle["input_quantized_min"] == -128
    assert oracle["input_quantized_max"] == 64
    assert oracle["input_quantized_sum"] == -86717
    assert oracle["output_tensor"] == 17
    assert oracle["output_vector_int8"] == [
        -19,
        7,
        -1,
        -4,
        -18,
        -41,
        -50,
        43,
        -22,
        -4,
    ]
    assert oracle["top_class"] == 7
    assert oracle["top_score_int8"] == 43
    assert [layer["output_sum"] for layer in oracle["layer_output_summaries"]] == [
        -287009,
        -141948,
        -92273,
        -22503,
        -22503,
        -109,
    ]


def test_mnist_sample_oracle_matches_local_model_and_image_when_present():
    manifest = json.loads(
        (REPO_ROOT / "tools/ref/npu_recovery_manifest.json").read_text(encoding="utf-8")
    )
    converter = manifest["toolchain_converter_oracle"]
    oracle = converter["sample_input_oracle"]
    model = REPO_ROOT / converter["sample_model"]
    image = REPO_ROOT / oracle["image"]
    if not model.exists() or not image.exists():
        return

    observed = tflite_inspect.run_mnist_sample(model, image)

    assert observed["model_sha256"] == converter["sample_model_sha256"]
    assert observed["image"]["sha256"] == oracle["image_sha256"]
    assert observed["image"]["size"] == oracle["image_size"]
    assert observed["image"]["width"] == oracle["image_width"]
    assert observed["image"]["height"] == oracle["image_height"]
    assert observed["image"]["bits_per_pixel"] == oracle["image_bits_per_pixel"]
    assert observed["image"]["pixel_offset"] == oracle["image_pixel_offset"]
    assert observed["image"]["pixel_min"] == oracle["image_pixel_min"]
    assert observed["image"]["pixel_max"] == oracle["image_pixel_max"]
    assert observed["image"]["pixel_sum"] == oracle["image_pixel_sum"]
    assert observed["input"]["quantized_min"] == oracle["input_quantized_min"]
    assert observed["input"]["quantized_max"] == oracle["input_quantized_max"]
    assert observed["input"]["quantized_sum"] == oracle["input_quantized_sum"]
    assert observed["output_tensor"] == oracle["output_tensor"]
    assert observed["output_vector_int8"] == oracle["output_vector_int8"]
    assert observed["output_vector_dequantized"] == oracle["output_vector_dequantized"]
    assert observed["top_class"] == oracle["top_class"]
    assert observed["top_score_int8"] == oracle["top_score_int8"]
    assert observed["top_score_dequantized"] == oracle["top_score_dequantized"]
    assert [
        {
            "operator_index": layer["operator_index"],
            "opcode": layer["opcode"],
            "output_tensor": layer["output_tensor"],
            "output_min": layer["output_min"],
            "output_max": layer["output_max"],
            "output_sum": layer["output_sum"],
        }
        for layer in observed["layers"]
    ] == oracle["layer_output_summaries"]
