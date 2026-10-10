#!/usr/bin/env python3
"""Collect per-port and per-instance SRAM counters from an Xcelium log."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path


COUNTER = re.compile(
    r"WINO_(EXTERNAL|INTERNAL)_SRAM\s+module=(\S+)\s+name=(\S+)\s+reads=(\d+)\s+writes=(\d+)"
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("counter_file", type=Path)
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument(
        "--output-trace",
        type=Path,
        help="derive output_DDR bank writes from the exact write trace",
    )
    args = parser.parse_args()

    external = []
    internal = []
    lines = args.counter_file.read_text(errors="replace").splitlines()
    output_writes: dict[str, int] = {}
    if args.output_trace is not None:
        output_writes = {"output_DDR0": 0, "output_DDR1": 0}
        for lineno, line in enumerate(
            args.output_trace.read_text(errors="replace").splitlines(), 1
        ):
            fields = line.split()
            if len(fields) != 3 or fields[0] not in {"0", "1"}:
                raise SystemExit(
                    f"Invalid output write trace at {args.output_trace}:{lineno}"
                )
            output_writes[f"output_DDR{fields[0]}"] += 1
        if not all(output_writes.values()):
            raise SystemExit(
                f"Output trace must contain writes to both banks: {output_writes}"
            )

    normalized_lines = []
    for line in lines:
        match = COUNTER.search(line)
        if not match:
            normalized_lines.append(line)
            continue
        kind, module, name, reads, writes = match.groups()
        if kind == "EXTERNAL" and name in output_writes:
            writes = str(output_writes[name])
            line = COUNTER.sub(
                f"WINO_EXTERNAL_SRAM module={module} name={name} "
                f"reads={reads} writes={writes}",
                line,
            )
        normalized_lines.append(line)
        record = {
            "module": module,
            "name": name,
            "reads": int(reads),
            "writes": int(writes),
        }
        (external if kind == "EXTERNAL" else internal).append(record)
    if args.output_trace is not None:
        args.counter_file.write_text("\n".join(normalized_lines) + "\n")

    # Xcelium may emit repeated identical records for some elaborated aliases.
    # Keep one record per hierarchical SRAM name and reject conflicting counts.
    external = deduplicate(external, "external")
    internal = deduplicate(internal, "internal")
    expected_external = {
        "input_DDR0",
        "input_DDR1",
        "weight_DDR0",
        "mem_params",
        "output_DDR0",
        "output_DDR1",
    }
    found_external = {str(item["name"]) for item in external}
    if found_external != expected_external or not internal:
        raise SystemExit(
            "Expected all six external SRAM ports and internal SRAM counters; "
            f"missing={sorted(expected_external - found_external)}, "
            f"unexpected={sorted(found_external - expected_external)}, "
            f"internal={len(internal)}"
        )

    by_module: dict[str, dict[str, int]] = defaultdict(
        lambda: {"instances": 0, "reads": 0, "writes": 0}
    )
    for record in internal:
        totals = by_module[record["module"]]
        totals["instances"] += 1
        totals["reads"] += record["reads"]
        totals["writes"] += record["writes"]

    result = {
        "source_counter_file": str(args.counter_file),
        "external_sram_ports": external,
        "internal_sram_instances": internal,
        "internal_totals_by_module": dict(sorted(by_module.items())),
        "total": {
            "reads": sum(item["reads"] for item in external + internal),
            "writes": sum(item["writes"] for item in external + internal),
        },
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["internal_totals_by_module"], indent=2))


def deduplicate(records: list[dict[str, int | str]], kind: str) -> list[dict[str, int | str]]:
    unique: dict[str, dict[str, int | str]] = {}
    for record in records:
        name = str(record["name"])
        existing = unique.get(name)
        if existing is not None and existing != record:
            raise SystemExit(f"Conflicting duplicate {kind} SRAM counter for {name}")
        unique[name] = record
    return list(unique.values())


if __name__ == "__main__":
    main()
