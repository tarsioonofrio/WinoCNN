#!/usr/bin/env python3
"""Build deterministic random physical RAM images plus WinoCNN parameters."""

from __future__ import annotations

import argparse
import json
import random
import struct
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csim", type=Path, required=True)
    parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--seed", type=int, default=20261010)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    h = w = args.size
    cin, cout, kernel = 3, 12, 3
    if h < kernel:
        parser.error("image size must be at least 3")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(args.csim.resolve()), str(h), str(w), str(cin), str(h - 2), str(w - 2),
        str(cout), str(kernel), str(kernel), "1", "0", "0", "0", "128",
        "random", "random", "random", "dump_param", ".", str(kernel),
    ]
    subprocess.run(cmd, cwd=out, check=True, stdout=subprocess.DEVNULL)
    param = (out / "param.bin").read_bytes()
    if len(param) != 128 * 4:
        raise SystemExit(f"expected 128 descriptor words, got {len(param) // 4}")
    params = struct.unpack("<128i", param)
    (out / "param.hex").write_text("".join(f"{v & 0xffffffff:08x}\n" for v in params))

    # The generated physical input buffer is padded to groups of eight channels
    # and to an eight-pixel row. The source packing code assumes square input.
    input_words = ((cin + 7) // 8) * h * ((h + 7) // 8 * 8)
    # For this fixed Cin/Cout/kernel the weight address generator wraps within
    # this conservative window; the simulator reports its access counters only.
    weight_words = 4096
    rng = random.Random(args.seed + h)
    with (out / "input.hex").open("w") as f:
        for _ in range(input_words):
            f.write(f"{rng.getrandbits(128):032x}\n")
    with (out / "weight.hex").open("w") as f:
        for _ in range(weight_words):
            f.write(f"{rng.getrandbits(128):032x}\n")
    meta = {
        "image": [h, w], "cin": cin, "cout": cout, "kernel": [3, 3],
        "stride": 1, "padding": 0, "seed": args.seed + h,
        "random_physical_memory_words": {"input": input_words, "weight": weight_words},
        "parameter_descriptor": "WinoCNN single_csim.out dump_param; no convolution/output comparison",
        "descriptor_values": {
            "input_ddr_128bits": params[21],
            "weightDDR_buffer_burst_length": params[42],
            "weightDDR_port_burst_length": params[43],
            "weightDDR_burst_number": params[44],
        },
    }
    (out / "stimulus.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
