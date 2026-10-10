#!/usr/bin/env python3
"""Run the WinoCNN C-sim on FastConv-style normal data and score float error.

The raw normal tensors follow FastConv's seeded NumPy generation order. They
are then independently quantized to WinoCNN's signed 8-bit input / signed
7-bit 3x3-weight limits. The output scale is selected before simulation from
the output and Scale_oback representable ranges; it is not fitted to results.
"""

import argparse
import json
import math
import re
import subprocess
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def conv2d_valid(x, w):
    cin, h, width = x.shape
    cout, wcin, kh, kw = w.shape
    if cin != wcin:
        raise ValueError("Cin mismatch")
    y = np.zeros((cout, h - kh + 1, width - kw + 1), dtype=np.float64)
    for oc in range(cout):
        for ic in range(cin):
            for ky in range(kh):
                for kx in range(kw):
                    y[oc] += x[ic, ky:ky + y.shape[1], kx:kx + y.shape[2]] * w[oc, ic, ky, kx]
    return y


def conv2d_valid_int(x, w):
    """Exact int64 cross-correlation over the quantized operands."""
    cin, h, width = x.shape
    cout, wcin, kh, kw = w.shape
    if cin != wcin:
        raise ValueError("Cin mismatch")
    y = np.zeros((cout, h - kh + 1, width - kw + 1), dtype=np.int64)
    for oc in range(cout):
        for ic in range(cin):
            for ky in range(kh):
                for kx in range(kw):
                    y[oc] += x[ic, ky:ky + y.shape[1], kx:kx + y.shape[2]].astype(np.int64) * int(w[oc, ic, ky, kx])
    return y


def metrics(reference, estimate, quantized_reference, codes):
    err = estimate - reference
    sse = float(np.sum(err * err))
    centered = reference - float(np.mean(reference))
    sst = float(np.sum(centered * centered))
    code_err = codes.astype(np.int64) - quantized_reference.astype(np.int64)
    denom = np.maximum(np.abs(reference), 1e-9)
    return {
        "count": int(reference.size),
        "mae": float(np.mean(np.abs(err))),
        "rmse": math.sqrt(float(np.mean(err * err))),
        "max_abs": float(np.max(np.abs(err))),
        "max_rel": float(np.max(np.abs(err) / denom)),
        # Same pooled, unbounded-below R2 definition used by FastConv.
        "r2_computed": 1.0 - sse / sst if sst else (1.0 if sse == 0 else 0.0),
        "quantized_golden_mae_codes": float(np.mean(np.abs(code_err))),
        "quantized_golden_rmse_codes": math.sqrt(float(np.mean(code_err.astype(np.float64) ** 2))),
        "quantized_golden_max_abs_codes": int(np.max(np.abs(code_err))),
        "quantized_golden_mismatch_count": int(np.count_nonzero(code_err)),
        "quantized_golden_mismatch_rate": float(np.mean(code_err != 0)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "single_csim.out")
    parser.add_argument("--height", type=int, default=32)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--cin", type=int, default=3)
    parser.add_argument("--cout", type=int, default=12)
    parser.add_argument("--seed", type=int, default=3)
    parser.add_argument("--input-quant-max", type=float, default=48.0,
                        help="target absolute quantized input range before rounding")
    parser.add_argument("--weight-quant-max", type=float, default=31.0,
                        help="target absolute quantized 3x3 weight range before rounding")
    parser.add_argument("--out", type=Path, help="output directory (default: reports/winocnn_normal)")
    args = parser.parse_args()

    if args.height < 3 or args.width < 3:
        parser.error("3x3 convolution requires height and width >= 3")
    rng = np.random.RandomState(args.seed)
    x_float = rng.normal(0.0, 1.0, size=(1, args.cin, args.height, args.width))[0]
    w_float = rng.normal(0.0, 1.0, size=(args.cout, args.cin, 3, 3))
    y_float = conv2d_valid(x_float, w_float)

    # FastConv's normal path forms x*2**quant_bits then truncates to int.
    # Keep these as provenance/reference, but feed WinoCNN its native ranges.
    fast_quant_bits = 8
    fast_x = (x_float * (1 << fast_quant_bits)).astype(np.int64)
    fast_w = (w_float * (1 << fast_quant_bits)).astype(np.int64)
    # The source has narrow fixed-point transform intermediates (notably the
    # 6-bit BTB input). Use headroom instead of filling every operand bit;
    # the chosen native ranges are part of this reproducible experiment.
    scale_i = args.input_quant_max / float(np.max(np.abs(x_float)))
    scale_w = args.weight_quant_max / float(np.max(np.abs(w_float)))
    x_q = np.clip(np.rint(x_float * scale_i), -128, 127).astype(np.int8)
    w_q = np.clip(np.rint(w_float * scale_w), -64, 63).astype(np.int8)

    # F(2x2,3x3), current macro quantization total=15 and Scale_wino=4.
    out_h, out_w = y_float.shape[1:]
    scale_o_headroom = 0.90 * 127.0 / float(np.max(np.abs(y_float)))
    scale_oback_max = (32767.0 / 1024.0) * scale_i * 4.0 * scale_w / (1 << 15)
    scale_o = min(scale_o_headroom, scale_oback_max)
    scale_oback = scale_o * (1 << 15) / (scale_i * 4.0 * scale_w)
    scale_oback_int = int(np.floor(scale_oback * 1024.0 + 0.5))
    if not 1 <= scale_oback_int <= 32767:
        raise RuntimeError(f"Scale_oback_int fora de 16 bits: {scale_oback_int}")

    outdir = args.out.resolve() if args.out else ROOT / "reports" / "winocnn_normal"
    outdir.mkdir(parents=True, exist_ok=True)
    workdir = outdir / "csim_work"
    workdir.mkdir(parents=True, exist_ok=True)
    feature_path = outdir / "feature_int8.bin"
    weight_path = outdir / "weight_int8.bin"
    x_q.tofile(feature_path)
    w_q.tofile(weight_path)

    common = [str(args.height), str(args.width), str(args.cin), str(out_h), str(out_w), str(args.cout),
              "3", "3", "1", "0", "0", "0", str(scale_oback_int),
              f"file:{feature_path}", "random", f"file:{weight_path}"]
    compare_cmd = [str(args.binary.resolve()), *common, "compare", str(outdir), "3"]
    compare = subprocess.run(compare_cmd, cwd=workdir, text=True, capture_output=True)
    compare_log = compare.stdout + compare.stderr
    compare_pass = compare.returncode == 0 and "Not different!" in compare.stdout

    dump_cmd = [str(args.binary.resolve()), *common, "dump_metrics", str(outdir), "3"]
    dump = subprocess.run(dump_cmd, cwd=workdir, text=True, capture_output=True)
    if dump.returncode != 0:
        raise RuntimeError("C-sim dump_metrics falhou:\n" + dump.stdout[-3000:] + dump.stderr[-2000:])
    codes_path = outdir / "hw_codes.csv"
    model_codes_path = outdir / "model_codes.csv"
    prescale_codes_path = outdir / "model_prescale_codes.csv"
    if not codes_path.is_file():
        raise RuntimeError("C-sim não produziu hw_codes.csv")
    if not model_codes_path.is_file():
        raise RuntimeError("C-sim não produziu model_codes.csv")
    if not prescale_codes_path.is_file():
        raise RuntimeError("C-sim não produziu model_prescale_codes.csv")
    codes = np.loadtxt(codes_path, delimiter=",", dtype=np.int64).reshape(y_float.shape)
    model_codes = np.loadtxt(model_codes_path, delimiter=",", dtype=np.int64).reshape(y_float.shape)
    prescale_codes = np.loadtxt(prescale_codes_path, delimiter=",", dtype=np.int64).reshape(y_float.shape)
    direct_quantized = conv2d_valid_int(x_q, w_q)
    estimate = codes.astype(np.float64) / scale_o
    model_estimate = model_codes.astype(np.float64) / scale_o
    yq = np.trunc(y_float * scale_o).astype(np.int64)
    hw_model_diff = codes.astype(np.int64) - model_codes.astype(np.int64)
    direct_flat = direct_quantized.ravel().astype(np.float64)
    prescale_flat = prescale_codes.ravel().astype(np.float64)
    direct_variance = float(np.sum((direct_flat - np.mean(direct_flat)) ** 2))
    fit_slope = float(np.sum((direct_flat - np.mean(direct_flat)) * (prescale_flat - np.mean(prescale_flat))) / direct_variance) if direct_variance else 0.0
    fit_intercept = float(np.mean(prescale_flat) - fit_slope * np.mean(direct_flat))
    fit_residual = prescale_flat - (fit_slope * direct_flat + fit_intercept)
    prescale_variance = float(np.sum((prescale_flat - np.mean(prescale_flat)) ** 2))
    prescale_fit_r2 = 1.0 - float(np.sum(fit_residual ** 2)) / prescale_variance if prescale_variance else (1.0 if np.all(fit_residual == 0) else 0.0)
    correlation = float(np.corrcoef(direct_flat, prescale_flat)[0, 1]) if np.std(direct_flat) and np.std(prescale_flat) else None
    extra_mismatches = re.search(r"\.\.\. (\d+) additional mismatches", compare_log)
    printed_mismatches = len(re.findall(r"mismatch\[\d+\] at", compare_log))

    result = {
        "project": "WinoCNN",
        "comparison_reference": "direct float cross-correlation, valid padding, no bias/ReLU",
        "generation": {
            "generator": "FastConv simulation.py cmd_sim_normal (NumPy RandomState/legacy seed order)",
            "seed": args.seed,
            "distribution": "N(0,1)",
            "shape_input_chw": list(x_float.shape),
            "shape_weights_oihw": list(w_float.shape),
            "fastconv_quant_bits": fast_quant_bits,
            "fastconv_quant_rule": "trunc(normal * 2**8), retained as provenance; not the WinoCNN operands",
            "winocnn_input_bits": 8,
            "winocnn_weight_bits": 7,
            "winocnn_input_quant_target_abs_max": args.input_quant_max,
            "winocnn_weight_quant_target_abs_max": args.weight_quant_max,
            "winocnn_input_quant_scale": scale_i,
            "winocnn_weight_quant_scale": scale_w,
            "winocnn_input_rounding": "nearest-even (numpy.rint), clipped to [-128,127]",
            "winocnn_weight_rounding": "nearest-even (numpy.rint), clipped to [-64,63]",
            "fastconv_input_integer_range": [int(fast_x.min()), int(fast_x.max())],
            "fastconv_weight_integer_range": [int(fast_w.min()), int(fast_w.max())],
        },
        "convolution": {"input_height": args.height, "input_width": args.width, "cin": args.cin,
                        "output_height": out_h, "output_width": out_w, "cout": args.cout,
                        "kernel": [3, 3], "stride": 1, "padding": 0, "bias": False, "relu": False},
        "winocnn_scaling": {"Scale_wino": 4, "quant_shift_total": 15, "Scale_o": scale_o,
                            "Scale_oback": scale_oback, "Scale_oback_int": scale_oback_int,
                            "output_code_limit_headroom": 0.90,
                            "scale_selection": "min(0.9*127/max_abs(float_output), max representable Scale_oback)"},
        "integer_csim": {"result": "PASS" if compare_pass else "FAIL",
                          "return_code": compare.returncode,
                          "mismatch_count": 0 if compare_pass else printed_mismatches + (int(extra_mismatches.group(1)) if extra_mismatches else 0),
                          "check": "Not different! (hardware C model equals integer Winograd golden)" if compare_pass
                                   else "hardware C model differs from integer Winograd golden",
                          "diagnostic_tail": compare_log[-2500:] if not compare_pass else "Not different!"},
        "metrics_vs_float": metrics(y_float, estimate, yq, codes),
        "metrics_integer_model_vs_float": metrics(y_float, model_estimate, yq, model_codes),
        "r2_definition": "1 - sum((estimate-reference)^2) / sum((reference-mean(reference))^2), pooled over all outputs; negative values are valid and are not clipped",
        "hardware_vs_integer_model": {
            "mismatch_count": int(np.count_nonzero(hw_model_diff)),
            "mismatch_rate": float(np.mean(hw_model_diff != 0)),
            "mae_codes": float(np.mean(np.abs(hw_model_diff))),
            "max_abs_codes": int(np.max(np.abs(hw_model_diff))),
        },
        "pre_rescale_diagnostic": {
            "comparison": "exact int64 direct cross-correlation on input_int8 and weight_int8 vs WinoCNN output_buffer before Scale_oback",
            "direct_quantized_min": int(np.min(direct_quantized)),
            "direct_quantized_max": int(np.max(direct_quantized)),
            "winocnn_prescale_min": int(np.min(prescale_codes)),
            "winocnn_prescale_max": int(np.max(prescale_codes)),
            "direct_positive_fraction": float(np.mean(direct_quantized > 0)),
            "winocnn_prescale_positive_fraction": float(np.mean(prescale_codes > 0)),
            "winocnn_prescale_at_signed_9bit_rail_fraction": float(np.mean((prescale_codes <= -256) | (prescale_codes >= 255))),
            "correlation_direct_vs_prescale": correlation,
            "best_affine_fit_slope": fit_slope,
            "best_affine_fit_intercept": fit_intercept,
            "best_affine_fit_r2_diagnostic_only": prescale_fit_r2,
        },
        "result_scope_warning": "Diagnostic only: do not use as paper PPA/accuracy evidence because hardware C-sim differs from the integer golden.",
        "artifacts": {"feature_int8": str(feature_path), "weight_int8": str(weight_path),
                      "hardware_output_codes": str(codes_path), "integer_model_output_codes": str(model_codes_path),
                      "integer_model_prescale_codes": str(prescale_codes_path)},
    }
    report_path = outdir / "metrics.json"
    report_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"Relatório salvo em: {report_path}")
if __name__ == "__main__":
    main()
