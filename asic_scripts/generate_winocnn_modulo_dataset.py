#!/usr/bin/env python3
"""Generate a deterministic signed-int dataset using WinoCNN-style modulo RNG."""

import argparse
import ctypes
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def glibc_random(seed: int):
    """Yield the same random() sequence as WinoCNN's Linux C++ testbench."""
    libc = ctypes.CDLL(None)
    libc.srandom.argtypes = [ctypes.c_uint]
    libc.random.argtypes = []
    libc.random.restype = ctypes.c_long
    libc.srandom(seed)
    while True:
        yield int(libc.random())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--height", type=int, default=32)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--cin", type=int, default=3)
    parser.add_argument("--cout", type=int, default=12)
    parser.add_argument("--kernel", type=int, default=3)
    parser.add_argument("--feature-bits", type=int, default=8,
                        help="signed feature range width (1..8 bits)")
    parser.add_argument("--weight-bits", type=int, default=7,
                        help="signed weight range width (1..7 bits)")
    parser.add_argument("--seed", type=int, default=1,
                        help="glibc random() seed; WinoCNN's unseeded default is 1")
    parser.add_argument("--out", type=Path,
                        default=ROOT / "reports" / "winocnn_modulo8_7_seed1_32x32_cin3_cout12")
    args = parser.parse_args()

    if min(args.height, args.width, args.cin, args.cout, args.kernel) <= 0:
        parser.error("all dimensions must be positive")
    if not 1 <= args.feature_bits <= 8:
        parser.error("--feature-bits must be between 1 and 8")
    if not 1 <= args.weight_bits <= 7:
        parser.error("--weight-bits must be between 1 and 7")
    if args.height < args.kernel or args.width < args.kernel:
        parser.error("kernel must fit within the input dimensions")

    rng = glibc_random(args.seed)
    feature_modulus = 1 << args.feature_bits
    feature_sign_bit = feature_modulus // 2
    feature_raw = [next(rng) % feature_modulus
                   for _ in range(args.cin * args.height * args.width)]
    # feature_map_buffer_init stores random()%256 as a char byte. Interpret the
    # selected-width low-bit pattern as two's-complement signed data.
    feature = [value if value < feature_sign_bit else value - feature_modulus
               for value in feature_raw]

    # Match init_weight's draw order (id, od, kernel position) and OIHW layout.
    weight_count = args.cout * args.cin * args.kernel * args.kernel
    weight = [0] * weight_count
    for ic in range(args.cin):
        for oc in range(args.cout):
            for ks in range(args.kernel * args.kernel):
                weight_modulus = 1 << args.weight_bits
                value = next(rng) % weight_modulus - weight_modulus // 2
                index = (oc * args.cin + ic) * args.kernel * args.kernel + ks
                weight[index] = value

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Store the low byte; consumers interpret it as signed char.
    (out / "feature.bin").write_bytes(bytes(value & 0xFF for value in feature))
    (out / "weight.bin").write_bytes(bytes(value & 0xFF for value in weight))

    out_h = args.height - args.kernel + 1
    out_w = args.width - args.kernel + 1
    params = {
        "input_height": args.height,
        "input_width": args.width,
        "input_depth": args.cin,
        "output_height": out_h,
        "output_width": out_w,
        "output_depth": args.cout,
        "kernel_size_h": args.kernel,
        "kernel_size_w": args.kernel,
        "stride": 1,
        "pad_size_h": 0,
        "pad_size_w": 0,
        "relu": 0,
        "scale": 128,
        "feature_layout": f"feature[c*H*W + h*W + w], signed int{args.feature_bits}",
        "weight_layout": f"weight[(od*Cin + id)*kh*kw + ks], signed int{args.weight_bits}",
    }
    (out / "params.json").write_text(json.dumps(params, indent=2) + "\n")

    metadata = {
        "generator": "WinoCNN modulo-style dataset generator",
        "source_functions_adapted": [
            "software/buffer.h:feature_map_buffer_init random branch (random()%256)",
            "software/buffer.h:init_weight random branch (random()%128-64)",
        ],
        "rng": "glibc random()",
        "seed": args.seed,
        "feature_generation": f"random()%{feature_modulus}, interpreted as signed {args.feature_bits}-bit two's-complement",
        "weight_generation": f"random()%{weight_modulus}-{weight_modulus // 2} (signed {args.weight_bits}-bit range)",
        "feature_bits": args.feature_bits,
        "weight_bits": args.weight_bits,
        "feature_signed_range": [min(feature), max(feature)],
        "weight_signed_range": [min(weight), max(weight)],
        "feature_shape_chw": [args.cin, args.height, args.width],
        "weight_shape_oihw": [args.cout, args.cin, args.kernel, args.kernel],
        "caveat": "Modulo reduction has the same small bias as the original C++ generator.",
    }
    (out / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (out / "README.md").write_text(
        "# WinoCNN modulo-generated dataset\n\n"
        f"Feature values use signed {args.feature_bits}-bit modulo samples; "
        f"weights use signed {args.weight_bits}-bit modulo samples. "
        "See `provenance.json` for seed and exact ranges.\n\n"
        "C-sim example (run from the WinoCNN repository root):\n\n"
        "```bash\n"
        f"./single_csim.out {args.height} {args.width} {args.cin} {out_h} {out_w} {args.cout} "
        f"{args.kernel} {args.kernel} 1 0 0 0 128 file:{out / 'feature.bin'} random "
        f"file:{out / 'weight.bin'} compare . {args.kernel}\n"
        "```\n"
    )
    print(json.dumps({"output": str(out), **metadata}, indent=2))


if __name__ == "__main__":
    main()
