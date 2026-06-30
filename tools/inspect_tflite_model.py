#!/usr/bin/env python3
"""Dependency-free TFLite model metadata inspector.

This intentionally extracts only stable graph metadata needed by the BL808 NPU
recovery workflow. It is not a general FlatBuffers implementation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any


TENSOR_TYPES = {
    0: "FLOAT32",
    1: "FLOAT16",
    2: "INT32",
    3: "UINT8",
    4: "INT64",
    5: "STRING",
    6: "BOOL",
    7: "INT16",
    8: "COMPLEX64",
    9: "INT8",
    10: "FLOAT64",
    11: "COMPLEX128",
    12: "UINT64",
    13: "RESOURCE",
    14: "VARIANT",
    15: "UINT32",
    16: "UINT16",
    17: "INT4",
}


BUILTIN_OPERATORS = {
    0: "ADD",
    1: "AVERAGE_POOL_2D",
    2: "CONCATENATION",
    3: "CONV_2D",
    4: "DEPTHWISE_CONV_2D",
    6: "DEQUANTIZE",
    9: "FULLY_CONNECTED",
    14: "LOGISTIC",
    17: "MAX_POOL_2D",
    18: "MUL",
    22: "RESHAPE",
    25: "SOFTMAX",
    34: "PAD",
    36: "GATHER",
    39: "TRANSPOSE",
    40: "MEAN",
    50: "LOG_SOFTMAX",
    67: "TRANSPOSE_CONV",
    74: "SUM",
    97: "RESIZE_NEAREST_NEIGHBOR",
}


class FlatBuffer:
    def __init__(self, data: bytes):
        self.data = data

    def u8(self, offset: int) -> int:
        return self.data[offset]

    def u16(self, offset: int) -> int:
        return struct.unpack_from("<H", self.data, offset)[0]

    def i32(self, offset: int) -> int:
        return struct.unpack_from("<i", self.data, offset)[0]

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, offset)[0]

    def root_table(self) -> int:
        return self.u32(0)

    def field_offset(self, table: int, field: int) -> int | None:
        vtable = table - self.i32(table)
        vtable_len = self.u16(vtable)
        slot = 4 + field * 2
        if slot + 2 > vtable_len:
            return None
        rel = self.u16(vtable + slot)
        if rel == 0:
            return None
        return table + rel

    def table_field(self, table: int, field: int) -> int | None:
        loc = self.field_offset(table, field)
        if loc is None:
            return None
        return loc + self.u32(loc)

    def string_field(self, table: int, field: int) -> str | None:
        loc = self.field_offset(table, field)
        if loc is None:
            return None
        start = loc + self.u32(loc)
        length = self.u32(start)
        raw = self.data[start + 4:start + 4 + length]
        return raw.decode("utf-8", errors="replace")

    def scalar_field(self, table: int, field: int, fmt: str, default: int = 0) -> int:
        loc = self.field_offset(table, field)
        if loc is None:
            return default
        return struct.unpack_from(fmt, self.data, loc)[0]

    def vector_start(self, table: int, field: int) -> int | None:
        loc = self.field_offset(table, field)
        if loc is None:
            return None
        return loc + self.u32(loc)

    def vector_len(self, vector: int) -> int:
        return self.u32(vector)

    def table_vector(self, table: int, field: int) -> list[int]:
        vector = self.vector_start(table, field)
        if vector is None:
            return []
        return [
            vector + 4 + index * 4 + self.u32(vector + 4 + index * 4)
            for index in range(self.vector_len(vector))
        ]

    def int_vector(self, table: int, field: int) -> list[int]:
        vector = self.vector_start(table, field)
        if vector is None:
            return []
        return [self.i32(vector + 4 + index * 4)
                for index in range(self.vector_len(vector))]

    def int64_vector(self, table: int, field: int) -> list[int]:
        vector = self.vector_start(table, field)
        if vector is None:
            return []
        return [
            struct.unpack_from("<q", self.data, vector + 4 + index * 8)[0]
            for index in range(self.vector_len(vector))
        ]

    def float_vector(self, table: int, field: int) -> list[float]:
        vector = self.vector_start(table, field)
        if vector is None:
            return []
        return [
            struct.unpack_from("<f", self.data, vector + 4 + index * 4)[0]
            for index in range(self.vector_len(vector))
        ]

    def byte_vector_len(self, table: int, field: int) -> int:
        vector = self.vector_start(table, field)
        if vector is None:
            return 0
        return self.vector_len(vector)

    def byte_vector(self, table: int, field: int) -> bytes:
        vector = self.vector_start(table, field)
        if vector is None:
            return b""
        length = self.vector_len(vector)
        return self.data[vector + 4:vector + 4 + length]


def builtin_code(buf: FlatBuffer, opcode: int) -> int:
    code = buf.scalar_field(opcode, 3, "<i", default=-1)
    if code >= 0:
        return code
    return buf.scalar_field(opcode, 0, "<b", default=0)


def quantization_summary(buf: FlatBuffer, tensor: int) -> dict[str, Any] | None:
    quantization = buf.table_field(tensor, 4)
    if quantization is None:
        return None
    scales = buf.float_vector(quantization, 2)
    zero_points = buf.int64_vector(quantization, 3)
    if not scales and not zero_points:
        return None
    return {
        "scale": scales,
        "zero_point": zero_points,
        "quantized_dimension": buf.scalar_field(quantization, 5, "<i", default=0),
    }


def tensor_summary(
    buf: FlatBuffer,
    tensor: int,
    buffers: list[int],
    *,
    include_quantization: bool = False,
) -> dict[str, Any]:
    tensor_type = buf.scalar_field(tensor, 1, "<b", default=0)
    buffer_index = buf.scalar_field(tensor, 2, "<I", default=0)
    buffer_data = (
        buf.byte_vector(buffers[buffer_index], 0)
        if buffer_index < len(buffers) else b""
    )
    summary: dict[str, Any] = {
        "buffer": buffer_index,
        "buffer_bytes": len(buffer_data),
        "name": buf.string_field(tensor, 3) or "",
        "shape": buf.int_vector(tensor, 0),
        "type": TENSOR_TYPES.get(tensor_type, f"UNKNOWN_{tensor_type}"),
    }
    if buffer_data:
        summary["buffer_sha256"] = hashlib.sha256(buffer_data).hexdigest()
    if include_quantization:
        quantization = quantization_summary(buf, tensor)
        if quantization is not None:
            summary["quantization"] = quantization
    return summary


def operator_summary(
    buf: FlatBuffer,
    operator: int,
    opcode_codes: list[int],
) -> dict[str, Any]:
    opcode_index = buf.scalar_field(operator, 0, "<I", default=0)
    builtin = opcode_codes[opcode_index] if opcode_index < len(opcode_codes) else -1
    return {
        "opcode_index": opcode_index,
        "opcode": BUILTIN_OPERATORS.get(builtin, f"BUILTIN_{builtin}"),
        "inputs": buf.int_vector(operator, 1),
        "outputs": buf.int_vector(operator, 2),
    }


def tensor_buffer_data(buf: FlatBuffer, tensor: int, buffers: list[int]) -> bytes:
    buffer_index = buf.scalar_field(tensor, 2, "<I", default=0)
    if buffer_index >= len(buffers):
        return b""
    return buf.byte_vector(buffers[buffer_index], 0)


def tensor_quantization_scalar(buf: FlatBuffer, tensor: int) -> tuple[float, int]:
    quantization = quantization_summary(buf, tensor)
    if quantization is None:
        raise ValueError("tensor has no quantization parameters")
    scales = quantization["scale"]
    zero_points = quantization["zero_point"]
    if len(scales) != 1 or len(zero_points) != 1:
        raise ValueError("only per-tensor quantization is supported")
    return float(scales[0]), int(zero_points[0])


def decode_bmp_luma8(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 54 or data[:2] != b"BM":
        raise ValueError(f"{path} is not a BMP file")

    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    bits_per_pixel = struct.unpack_from("<H", data, 28)[0]
    if width <= 0 or height == 0 or bits_per_pixel != 8:
        raise ValueError("only non-empty 8-bit grayscale BMP inputs are supported")

    absolute_height = abs(height)
    row_stride = ((width * bits_per_pixel + 31) // 32) * 4
    pixels: list[int] = []
    for output_y in range(absolute_height):
        source_y = absolute_height - 1 - output_y if height > 0 else output_y
        row_start = pixel_offset + source_y * row_stride
        row = data[row_start:row_start + row_stride]
        if len(row) < width:
            raise ValueError("BMP pixel data is truncated")
        pixels.extend(row[:width])

    return {
        "path": str(path),
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "width": width,
        "height": absolute_height,
        "bits_per_pixel": bits_per_pixel,
        "pixel_offset": pixel_offset,
        "pixel_sum": sum(pixels),
        "pixel_min": min(pixels),
        "pixel_max": max(pixels),
        "first_row": pixels[:width],
        "pixels": pixels,
    }


def int8_values(data: bytes) -> list[int]:
    return list(struct.unpack(f"<{len(data)}b", data))


def int32_values(data: bytes) -> list[int]:
    return list(struct.unpack(f"<{len(data) // 4}i", data))


def round_away_from_zero(value: float) -> int:
    if value >= 0:
        return math.floor(value + 0.5)
    return math.ceil(value - 0.5)


def clamp_int8(value: int) -> int:
    return max(-128, min(127, value))


def requantize_int8(
    accumulator: int,
    input_scale: float,
    weight_scale: float,
    output_scale: float,
    output_zero_point: int,
) -> int:
    scaled = accumulator * input_scale * weight_scale / output_scale
    return clamp_int8(round_away_from_zero(scaled + output_zero_point))


def conv2d_int8_same(
    input_values: list[int],
    input_shape: list[int],
    weights: list[int],
    weight_shape: list[int],
    bias: list[int],
    output_shape: list[int],
    input_quantization: tuple[float, int],
    weight_quantization: tuple[float, int],
    output_quantization: tuple[float, int],
    *,
    stride_h: int,
    stride_w: int,
    fused_relu: bool,
) -> list[int]:
    if len(input_shape) != 4 or len(weight_shape) != 4 or len(output_shape) != 4:
        raise ValueError("CONV_2D oracle requires NHWC input/output and OHWI weights")
    _, input_h, input_w, input_c = input_shape
    _, output_h, output_w, output_c = output_shape
    weight_o, kernel_h, kernel_w, weight_i = weight_shape
    if input_c != weight_i or output_c != weight_o:
        raise ValueError("CONV_2D channel dimensions do not match")

    pad_h = max((output_h - 1) * stride_h + kernel_h - input_h, 0)
    pad_w = max((output_w - 1) * stride_w + kernel_w - input_w, 0)
    pad_top = pad_h // 2
    pad_left = pad_w // 2
    input_scale, input_zero = input_quantization
    weight_scale, weight_zero = weight_quantization
    output_scale, output_zero = output_quantization

    output = [0] * (output_h * output_w * output_c)
    for oy in range(output_h):
        for ox in range(output_w):
            for oc in range(output_c):
                accumulator = bias[oc]
                for ky in range(kernel_h):
                    iy = oy * stride_h + ky - pad_top
                    if iy < 0 or iy >= input_h:
                        continue
                    for kx in range(kernel_w):
                        ix = ox * stride_w + kx - pad_left
                        if ix < 0 or ix >= input_w:
                            continue
                        for ic in range(input_c):
                            input_index = (iy * input_w + ix) * input_c + ic
                            weight_index = ((oc * kernel_h + ky) * kernel_w + kx) * input_c + ic
                            accumulator += (
                                (input_values[input_index] - input_zero) *
                                (weights[weight_index] - weight_zero)
                            )
                value = requantize_int8(
                    accumulator,
                    input_scale,
                    weight_scale,
                    output_scale,
                    output_zero,
                )
                if fused_relu:
                    value = max(value, output_zero)
                output[(oy * output_w + ox) * output_c + oc] = value
    return output


def fully_connected_int8(
    input_values: list[int],
    weights: list[int],
    bias: list[int],
    output_shape: list[int],
    input_quantization: tuple[float, int],
    weight_quantization: tuple[float, int],
    output_quantization: tuple[float, int],
) -> list[int]:
    output_count = output_shape[-1]
    input_count = len(input_values)
    input_scale, input_zero = input_quantization
    weight_scale, weight_zero = weight_quantization
    output_scale, output_zero = output_quantization
    output: list[int] = []
    for oc in range(output_count):
        accumulator = bias[oc]
        for index, input_value in enumerate(input_values):
            accumulator += (
                (input_value - input_zero) *
                (weights[oc * input_count + index] - weight_zero)
            )
        output.append(requantize_int8(
            accumulator,
            input_scale,
            weight_scale,
            output_scale,
            output_zero,
        ))
    return output


def run_mnist_sample(model_path: Path, image_path: Path) -> dict[str, Any]:
    data = model_path.read_bytes()
    if len(data) < 8 or data[4:8] != b"TFL3":
        raise ValueError(f"{model_path} is not a TFLite FlatBuffer with TFL3 identifier")

    decoded_image = decode_bmp_luma8(image_path)
    buf = FlatBuffer(data)
    model = buf.root_table()
    opcode_codes = [builtin_code(buf, opcode) for opcode in buf.table_vector(model, 1)]
    buffers = buf.table_vector(model, 4)
    subgraphs = buf.table_vector(model, 2)
    if len(subgraphs) != 1:
        raise ValueError("MNIST sample oracle expects exactly one subgraph")
    subgraph = subgraphs[0]
    tensors = buf.table_vector(subgraph, 0)
    operators = buf.table_vector(subgraph, 3)
    inputs = buf.int_vector(subgraph, 1)
    outputs = buf.int_vector(subgraph, 2)
    if len(inputs) != 1 or len(outputs) != 1:
        raise ValueError("MNIST sample oracle expects one input and one output")

    input_shape = buf.int_vector(tensors[inputs[0]], 0)
    expected_pixels = input_shape[1] * input_shape[2] * input_shape[3]
    if expected_pixels != len(decoded_image["pixels"]):
        raise ValueError("BMP pixel count does not match model input tensor")

    input_scale, input_zero = tensor_quantization_scalar(buf, tensors[inputs[0]])
    tensor_values: dict[int, list[int]] = {
        inputs[0]: [pixel + input_zero for pixel in decoded_image["pixels"]]
    }
    layer_summaries: list[dict[str, Any]] = []

    for operator_index, operator in enumerate(operators):
        opcode_index = buf.scalar_field(operator, 0, "<I", default=0)
        builtin = opcode_codes[opcode_index]
        opcode = BUILTIN_OPERATORS.get(builtin, f"BUILTIN_{builtin}")
        operator_inputs = buf.int_vector(operator, 1)
        operator_outputs = buf.int_vector(operator, 2)
        output_tensor = operator_outputs[0]

        if opcode == "CONV_2D":
            options = buf.table_field(operator, 4)
            stride_w = buf.scalar_field(options, 1, "<i", default=1) if options else 1
            stride_h = buf.scalar_field(options, 2, "<i", default=1) if options else 1
            fused_activation = (
                buf.scalar_field(options, 3, "<b", default=0) if options else 0
            )
            tensor_values[output_tensor] = conv2d_int8_same(
                tensor_values[operator_inputs[0]],
                buf.int_vector(tensors[operator_inputs[0]], 0),
                int8_values(tensor_buffer_data(buf, tensors[operator_inputs[1]], buffers)),
                buf.int_vector(tensors[operator_inputs[1]], 0),
                int32_values(tensor_buffer_data(buf, tensors[operator_inputs[2]], buffers)),
                buf.int_vector(tensors[output_tensor], 0),
                tensor_quantization_scalar(buf, tensors[operator_inputs[0]]),
                tensor_quantization_scalar(buf, tensors[operator_inputs[1]]),
                tensor_quantization_scalar(buf, tensors[output_tensor]),
                stride_h=stride_h,
                stride_w=stride_w,
                fused_relu=(fused_activation == 1),
            )
        elif opcode == "RESHAPE":
            tensor_values[output_tensor] = list(tensor_values[operator_inputs[0]])
        elif opcode == "FULLY_CONNECTED":
            tensor_values[output_tensor] = fully_connected_int8(
                tensor_values[operator_inputs[0]],
                int8_values(tensor_buffer_data(buf, tensors[operator_inputs[1]], buffers)),
                int32_values(tensor_buffer_data(buf, tensors[operator_inputs[2]], buffers)),
                buf.int_vector(tensors[output_tensor], 0),
                tensor_quantization_scalar(buf, tensors[operator_inputs[0]]),
                tensor_quantization_scalar(buf, tensors[operator_inputs[1]]),
                tensor_quantization_scalar(buf, tensors[output_tensor]),
            )
        else:
            raise ValueError(f"unsupported MNIST sample opcode {opcode}")

        values = tensor_values[output_tensor]
        layer_summaries.append({
            "operator_index": operator_index,
            "opcode": opcode,
            "output_tensor": output_tensor,
            "output_shape": buf.int_vector(tensors[output_tensor], 0),
            "output_min": min(values),
            "output_max": max(values),
            "output_sum": sum(values),
            "output_first16": values[:16],
        })

    output_vector = tensor_values[outputs[0]]
    output_scale, output_zero = tensor_quantization_scalar(buf, tensors[outputs[0]])
    dequantized = [
        round((value - output_zero) * output_scale, 6)
        for value in output_vector
    ]
    top_class = max(range(len(output_vector)), key=output_vector.__getitem__)

    return {
        "model": str(model_path),
        "model_sha256": hashlib.sha256(data).hexdigest(),
        "image": {
            key: value
            for key, value in decoded_image.items()
            if key != "pixels"
        },
        "input": {
            "shape": input_shape,
            "scale": input_scale,
            "zero_point": input_zero,
            "quantized_min": min(tensor_values[inputs[0]]),
            "quantized_max": max(tensor_values[inputs[0]]),
            "quantized_sum": sum(tensor_values[inputs[0]]),
        },
        "layers": layer_summaries,
        "output_tensor": outputs[0],
        "output_vector_int8": output_vector,
        "output_vector_dequantized": dequantized,
        "top_class": top_class,
        "top_score_int8": output_vector[top_class],
        "top_score_dequantized": dequantized[top_class],
    }


def inspect_tflite(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 8 or data[4:8] != b"TFL3":
        raise ValueError(f"{path} is not a TFLite FlatBuffer with TFL3 identifier")
    buf = FlatBuffer(data)
    model = buf.root_table()
    opcodes = buf.table_vector(model, 1)
    subgraphs = buf.table_vector(model, 2)
    buffers = buf.table_vector(model, 4)
    opcode_codes = [builtin_code(buf, opcode) for opcode in opcodes]

    subgraph_summaries: list[dict[str, Any]] = []
    for subgraph in subgraphs:
        tensors = buf.table_vector(subgraph, 0)
        inputs = buf.int_vector(subgraph, 1)
        outputs = buf.int_vector(subgraph, 2)
        operators = buf.table_vector(subgraph, 3)
        operator_summaries = [
            operator_summary(buf, operator, opcode_codes)
            for operator in operators
        ]
        tensor_summaries = [
            tensor_summary(buf, tensor, buffers, include_quantization=True)
            for tensor in tensors
        ]
        subgraph_summaries.append({
            "name": buf.string_field(subgraph, 4) or "",
            "tensor_count": len(tensors),
            "operator_count": len(operators),
            "inputs": [tensor_summaries[index] for index in inputs],
            "outputs": [tensor_summaries[index] for index in outputs],
            "operator_codes": [operator["opcode"] for operator in operator_summaries],
            "operators": operator_summaries,
            "tensors": tensor_summaries,
        })

    return {
        "path": str(path),
        "size": len(data),
        "identifier": "TFL3",
        "version": buf.scalar_field(model, 0, "<I", default=0),
        "description": buf.string_field(model, 3) or "",
        "operator_code_count": len(opcodes),
        "subgraph_count": len(subgraphs),
        "buffer_count": len(buffers),
        "operator_codes": [
            BUILTIN_OPERATORS.get(code, f"BUILTIN_{code}") for code in opcode_codes
        ],
        "subgraphs": subgraph_summaries,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect stable TFLite metadata")
    parser.add_argument("model", type=Path)
    parser.add_argument("--mnist-sample-image", type=Path)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()

    summary = (
        run_mnist_sample(args.model, args.mnist_sample_image)
        if args.mnist_sample_image else
        inspect_tflite(args.model)
    )
    text = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(text)
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
