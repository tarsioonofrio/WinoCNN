#!/usr/bin/env python3
"""Compare every RTL output-RAM write against the WinoCNN C-model DDR image."""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("golden_bin", type=Path)
    parser.add_argument("rtl_writes", type=Path)
    parser.add_argument("--json", type=Path, help="write machine-readable result")
    args = parser.parse_args()

    data = args.golden_bin.read_bytes()
    if len(data) % 4:
        raise SystemExit(f"golden DDR image size {len(data)} is not 32-bit aligned")
    expected = struct.unpack(f"<{len(data) // 4}I", data)

    checked = 0
    mismatches = []
    seen = set()
    for line_no, line in enumerate(args.rtl_writes.read_text().splitlines(), 1):
        fields = line.split()
        if len(fields) != 3:
            mismatches.append({"line": line_no, "reason": "malformed write record", "text": line})
            continue
        bank, address, value = int(fields[0], 0), int(fields[1], 0), int(fields[2], 16)
        checked += 1
        if not 0 <= address < len(expected):
            mismatches.append({"line": line_no, "bank": bank, "address": address,
                               "rtl": f"0x{value:08x}", "reason": "address outside golden image"})
            continue
        key = (bank, address)
        if key in seen:
            mismatches.append({"line": line_no, "bank": bank, "address": address,
                               "reason": "duplicate physical write address"})
            continue
        seen.add(key)
        ref = expected[address]
        if value != ref:
            mismatches.append({"line": line_no, "bank": bank, "address": address,
                               "rtl": f"0x{value:08x}", "golden": f"0x{ref:08x}"})

    expected_write_count = len(expected) // 2
    if checked != expected_write_count:
        mismatches.append({"reason": "incomplete or excess RTL write coverage",
                           "expected_writes": expected_write_count,
                           "checked_writes": checked})

    result = {"result": "PASS" if checked == expected_write_count and not mismatches else "FAIL",
              "golden_image": str(args.golden_bin), "rtl_write_trace": str(args.rtl_writes),
              "golden_sha256": hashlib.sha256(data).hexdigest(),
              "rtl_write_trace_sha256": hashlib.sha256(args.rtl_writes.read_bytes()).hexdigest(),
              "expected_writes": expected_write_count,
              "checked_writes": checked, "unique_bank_addresses": len(seen),
              "mismatch_count": len(mismatches), "mismatches": mismatches[:20]}
    rendered = json.dumps(result, indent=2)
    print(rendered)
    if args.json:
        args.json.write_text(rendered + "\n")
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
