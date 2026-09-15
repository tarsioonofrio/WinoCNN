#!/usr/bin/env python3
"""Convert the WinoCNN C-simulation DDR dumps into $readmemh hex files.

The C testbench (testbench/single_main.cpp) writes the raw external-memory
contents produced by the software model:

    input.bin   128-bit words, "in"  feature-map DDR buffer
    weight.bin  128-bit words, weight DDR buffer (port 0)
    param.bin    32-bit words, conv descriptor (128 entries)

The host is little-endian, so a word is the little-endian sum of its bytes.
Usage: bin2hex.py <dir>   (reads <dir>/*.bin, writes <dir>/*.hex)
"""
import os
import struct
import sys


def words_from_file(path, word_bytes):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) % word_bytes:
        raise SystemExit(f"{path}: size {len(data)} not a multiple of {word_bytes}")
    out = []
    for i in range(0, len(data), word_bytes):
        out.append(int.from_bytes(data[i:i + word_bytes], "little"))
    return out


def write_hex(path, values, digits):
    with open(path, "w") as f:
        for v in values:
            f.write(f"{v:0{digits}x}\n")


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    inp = words_from_file(os.path.join(d, "input.bin"), 16)
    wgt = words_from_file(os.path.join(d, "weight.bin"), 16)
    prm = words_from_file(os.path.join(d, "param.bin"), 4)
    write_hex(os.path.join(d, "input.hex"), inp, 32)
    write_hex(os.path.join(d, "weight.hex"), wgt, 32)
    write_hex(os.path.join(d, "param.hex"), prm, 8)
    print(f"input.hex  {len(inp)} x 128-bit")
    print(f"weight.hex {len(wgt)} x 128-bit")
    print(f"param.hex  {len(prm)} x 32-bit")


if __name__ == "__main__":
    main()
