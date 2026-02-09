#!/usr/bin/env python3
"""NPU inference validation test for RK3588 via TFLite + Mesa Teflon + Rocket.

Stack: TFLite runtime → libteflon.so (external delegate) → Rocket driver → NPU
Ref:   https://docs.mesa3d.org/teflon.html

If libteflon.so is found, inference runs on the NPU via the Teflon delegate.
If not, inference falls back to CPU (TFLite default) and the result reports
which backend was used so hw-test can distinguish the two.

Requires: python3.11 + tflite-runtime (installed via deadsnakes/pip).

Tests:
  1. MobileNet V1 classification (UINT8 quantized .tflite)

Output: JSON with test results, parsed by hw-test (same format as
npu_inference_test.py for RKNPU2).
"""

import sys
import os
import json
import time
import glob
import numpy as np

MODELS_DIR = "/usr/local/lib/hw-test/models"

# Search paths for the Teflon delegate shared library (built by Mesa)
TEFLON_SEARCH_PATHS = [
    "/usr/lib/aarch64-linux-gnu/libteflon.so",
    "/usr/lib/libteflon.so",
    "/usr/local/lib/libteflon.so",
    "/usr/local/lib/aarch64-linux-gnu/libteflon.so",
]


def find_teflon_delegate():
    """Locate libteflon.so on the system."""
    for path in TEFLON_SEARCH_PATHS:
        if os.path.exists(path):
            return path
    # Glob fallback
    for match in glob.glob("/usr/lib/**/libteflon.so", recursive=True):
        return match
    return None


def test_mobilenet():
    """Run MobileNet V1 inference, preferring NPU via Teflon delegate."""
    model_path = os.path.join(MODELS_DIR, "mobilenet_v1_1.0_224_quant.tflite")
    if not os.path.exists(model_path):
        return {"status": "SKIP", "error": "Model not found at " + model_path}

    try:
        from tflite_runtime.interpreter import Interpreter, load_delegate
    except ImportError:
        return {"status": "SKIP", "error": "tflite-runtime not installed"}

    # Try to load the Teflon delegate for NPU acceleration
    teflon_path = find_teflon_delegate()
    backend = "cpu"
    delegate = None

    if teflon_path:
        try:
            delegate = load_delegate(teflon_path)
            backend = "npu"
        except Exception:
            # Delegate load failed — fall back to CPU
            delegate = None

    try:
        if delegate:
            interpreter = Interpreter(
                model_path=model_path,
                experimental_delegates=[delegate],
            )
        else:
            interpreter = Interpreter(model_path=model_path)
        interpreter.allocate_tensors()
    except Exception as e:
        return {"status": "FAIL", "error": f"Model load/alloc failed: {e}",
                "backend": backend}

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    # MobileNet V1 quant expects [1, 224, 224, 3] uint8
    input_shape = input_details[0]["shape"]

    # Create test input: deterministic pseudo-random image
    np.random.seed(42)
    test_input = np.random.randint(0, 256, size=input_shape, dtype=np.uint8)

    # Warm-up inference
    try:
        interpreter.set_tensor(input_details[0]["index"], test_input)
        interpreter.invoke()
    except Exception as e:
        return {"status": "FAIL", "error": f"Warm-up inference failed: {e}",
                "backend": backend}

    # Timed inference (10 runs)
    times = []
    try:
        for _ in range(10):
            interpreter.set_tensor(input_details[0]["index"], test_input)
            t0 = time.perf_counter()
            interpreter.invoke()
            t1 = time.perf_counter()
            times.append((t1 - t0) * 1000)
    except Exception as e:
        return {"status": "FAIL", "error": f"Inference failed: {e}",
                "backend": backend}

    avg_ms = sum(times) / len(times)
    min_ms = min(times)

    output = interpreter.get_tensor(output_details[0]["index"])
    output_flat = output.flatten().astype(np.float32)

    # Check for invalid output
    if np.isnan(output_flat).any() or np.isinf(output_flat).any():
        return {"status": "FAIL", "error": "NaN/Inf in output",
                "inference_ms": round(avg_ms, 2), "backend": backend}

    # Dequantize if needed (uint8 quantized model)
    quant_params = output_details[0].get("quantization_parameters", {})
    scales = quant_params.get("scales", np.array([]))
    zero_points = quant_params.get("zero_points", np.array([]))
    if len(scales) > 0 and scales[0] != 0:
        output_flat = (output_flat - zero_points[0]) * scales[0]

    # Apply softmax if output looks like raw logits
    if output_flat.max() > 10:
        exp_out = np.exp(output_flat - output_flat.max())
        output_flat = exp_out / exp_out.sum()

    # Get top-5 predictions
    top5_idx = output_flat.argsort()[-5:][::-1]
    top5 = [{"class_id": int(i), "confidence": round(float(output_flat[i]), 6)}
            for i in top5_idx]

    # Validate output is meaningful (not uniform/zero)
    if output_flat.max() < 0.001:
        return {"status": "FAIL", "error": "Output appears uniform/zero",
                "inference_ms": round(avg_ms, 2), "top5": top5,
                "backend": backend}

    return {
        "status": "PASS",
        "inference_ms": round(avg_ms, 2),
        "min_inference_ms": round(min_ms, 2),
        "output_shape": list(output.shape),
        "top5": top5,
        "backend": backend,
        "teflon_delegate": teflon_path,
    }


def main():
    results = {}

    # Test 1: MobileNet V1 classification
    results["mobilenet"] = test_mobilenet()

    print(json.dumps(results, indent=2))

    if results.get("mobilenet", {}).get("status") == "PASS":
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
