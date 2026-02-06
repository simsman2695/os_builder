#!/usr/bin/env python3
"""NPU inference validation test for RK3588 (RKNPU2).

Runs real model inference on the NPU to validate hardware, driver,
and runtime are all functioning correctly.

Tests:
  1. MobileNet classification (always available from rknpu2 examples)
  2. PP-OCR text recognition (optional, if OCR models installed)

Output: JSON with test results, parsed by hw-test.
"""

import sys
import os
import json
import time
import numpy as np

MODELS_DIR = "/usr/local/lib/hw-test/models"


def test_mobilenet(RKNNLite):
    """Run MobileNet inference — validates NPU executes correctly."""
    model_path = os.path.join(MODELS_DIR, "mobilenet_v1.rknn")
    if not os.path.exists(model_path):
        return {"status": "SKIP", "error": "Model not found at " + model_path}

    rknn = RKNNLite()

    ret = rknn.load_rknn(model_path)
    if ret != 0:
        return {"status": "FAIL", "error": f"Model load failed (ret={ret})"}

    ret = rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO)
    if ret != 0:
        rknn.release()
        return {"status": "FAIL", "error": f"NPU runtime init failed (ret={ret})"}

    # Create test input: 224x224 RGB image with a deterministic pattern
    np.random.seed(42)
    test_input = np.random.randint(0, 256, (224, 224, 3), dtype=np.uint8)

    # Warm-up inference
    try:
        rknn.inference(inputs=[test_input])
    except Exception as e:
        rknn.release()
        return {"status": "FAIL", "error": f"Warm-up inference failed: {e}"}

    # Timed inference (10 runs)
    times = []
    outputs = None
    try:
        for _ in range(10):
            t0 = time.perf_counter()
            outputs = rknn.inference(inputs=[test_input])
            t1 = time.perf_counter()
            times.append((t1 - t0) * 1000)
    except Exception as e:
        rknn.release()
        return {"status": "FAIL", "error": f"Inference failed: {e}"}

    rknn.release()

    avg_ms = sum(times) / len(times)
    min_ms = min(times)

    if not outputs or len(outputs) == 0:
        return {"status": "FAIL", "error": "No output from inference",
                "inference_ms": round(avg_ms, 2)}

    output = outputs[0].flatten().astype(np.float32)

    # Check for invalid output
    if np.isnan(output).any() or np.isinf(output).any():
        return {"status": "FAIL", "error": "NaN/Inf in output",
                "inference_ms": round(avg_ms, 2)}

    # Apply softmax if output looks like raw logits
    if output.max() > 10:
        exp_out = np.exp(output - output.max())
        output = exp_out / exp_out.sum()

    # Get top-5 predictions
    top5_idx = output.argsort()[-5:][::-1]
    top5 = [{"class_id": int(i), "confidence": round(float(output[i]), 6)}
            for i in top5_idx]

    # Validate output is meaningful (not uniform/zero)
    if output.max() < 0.001:
        return {"status": "FAIL", "error": "Output appears uniform/zero",
                "inference_ms": round(avg_ms, 2), "top5": top5}

    return {
        "status": "PASS",
        "inference_ms": round(avg_ms, 2),
        "min_inference_ms": round(min_ms, 2),
        "output_shape": list(outputs[0].shape),
        "top5": top5
    }


def test_ocr(RKNNLite):
    """Run PP-OCR text recognition on a test image with known text."""
    model_path = os.path.join(MODELS_DIR, "ppocrv4_rec.rknn")
    keys_path = os.path.join(MODELS_DIR, "ppocr_keys_v1.txt")
    test_image_path = os.path.join(MODELS_DIR, "ocr_test_image.png")

    if not os.path.exists(model_path):
        return {"status": "SKIP", "error": "OCR model not found"}

    # Load character dictionary
    keys = []
    if os.path.exists(keys_path):
        with open(keys_path, 'r', encoding='utf-8') as f:
            keys = [line.strip() for line in f.readlines()]
    else:
        return {"status": "FAIL", "error": "Character dictionary not found"}

    # Load the bundled test image (contains the word "JOINT")
    expected = "JOINT"
    test_input = _load_ocr_image(test_image_path)
    if test_input is None:
        return {"status": "FAIL", "error": "Could not load test image"}

    rknn = RKNNLite()

    ret = rknn.load_rknn(model_path)
    if ret != 0:
        return {"status": "FAIL", "error": f"OCR model load failed (ret={ret})"}

    ret = rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO)
    if ret != 0:
        rknn.release()
        return {"status": "FAIL", "error": f"NPU runtime init failed (ret={ret})"}

    # Run inference
    try:
        # Warm-up
        rknn.inference(inputs=[test_input])

        t0 = time.perf_counter()
        outputs = rknn.inference(inputs=[test_input])
        t1 = time.perf_counter()
        inference_ms = (t1 - t0) * 1000
    except Exception as e:
        rknn.release()
        return {"status": "FAIL", "error": f"OCR inference failed: {e}"}

    rknn.release()

    if not outputs or len(outputs) == 0:
        return {"status": "FAIL", "error": "No output from OCR inference"}

    output = outputs[0]  # Expected shape: (1, seq_len, vocab_size)

    # CTC greedy decode
    recognized = _ctc_decode(output, keys)

    match = recognized.strip() == expected

    return {
        "status": "PASS" if match else "WARN",
        "inference_ms": round(inference_ms, 2),
        "expected": expected,
        "recognized": recognized,
        "match": match,
        "output_shape": list(output.shape)
    }


def _load_ocr_image(image_path):
    """Load and preprocess image for PP-OCR recognition (resize to 48x320)."""
    try:
        from PIL import Image
        img = Image.open(image_path).convert('RGB')
        # Resize to model input: height=48, width=320 (maintaining aspect ratio with padding)
        target_h, target_w = 48, 320
        w, h = img.size
        ratio = target_h / h
        new_w = min(int(w * ratio), target_w)
        img = img.resize((new_w, target_h), Image.BILINEAR)
        # Pad to target width with white
        padded = Image.new('RGB', (target_w, target_h), (255, 255, 255))
        padded.paste(img, (0, 0))
        return np.array(padded, dtype=np.uint8)
    except ImportError:
        # Fallback: try loading with numpy if PIL not available
        try:
            import subprocess
            # Use ImageMagick convert if available
            result = subprocess.run(
                ['convert', image_path, '-resize', '320x48', '-extent', '320x48',
                 '-background', 'white', '-gravity', 'West', 'RGB:-'],
                capture_output=True, timeout=10)
            if result.returncode == 0:
                data = np.frombuffer(result.stdout, dtype=np.uint8)
                return data.reshape(48, 320, 3)
        except Exception:
            pass
        return None


def _ctc_decode(output, keys):
    """CTC greedy decode: argmax, remove blanks and consecutive duplicates."""
    if len(output.shape) == 3:
        logits = output[0]  # (seq_len, vocab_size)
    else:
        logits = output

    indices = np.argmax(logits, axis=-1)  # (seq_len,)

    chars = []
    prev = -1
    for idx in indices:
        idx = int(idx)
        if idx != 0 and idx != prev:  # 0 = CTC blank
            if keys and (idx - 1) < len(keys):
                chars.append(keys[idx - 1])
            else:
                chars.append(f"[{idx}]")
        prev = idx

    return ''.join(chars)


def main():
    try:
        from rknnlite.api import RKNNLite
    except ImportError:
        print(json.dumps({"error": "rknnlite2 not installed", "status": "SKIP"}))
        return 1

    results = {}

    # Test 1: MobileNet classification (always)
    results["mobilenet"] = test_mobilenet(RKNNLite)

    # Test 2: PP-OCR recognition (if model present)
    ocr_model = os.path.join(MODELS_DIR, "ppocrv4_rec.rknn")
    if os.path.exists(ocr_model):
        results["ocr"] = test_ocr(RKNNLite)

    print(json.dumps(results, indent=2))

    if results.get("mobilenet", {}).get("status") == "PASS":
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
