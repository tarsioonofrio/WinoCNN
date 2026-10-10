#!/usr/bin/env python3
"""Stage HLS behavioral RAM models with simulation-only access counters."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def instrument(source: str, tco_ns: str | None) -> tuple[str, int]:
    module_re = re.compile(
        r"module\s+(\w+_ram)\s*\((.*?)\)\s*;", re.DOTALL
    )
    read_delay_count = 0

    matches = list(module_re.finditer(source))
    for match in reversed(matches):
        module_name, header = match.group(1), match.group(2)
        end = source.find("endmodule", match.end())
        if end < 0:
            raise ValueError(f"Missing endmodule for {module_name}")
        body = source[match.end() : end]
        ram_decl = re.search(r"\(\*\s*ram_style\s*=\s*\"block\"\s*\*\).*?;", body, re.DOTALL)
        if not ram_decl:
            continue

        body = source[match.end() : end]
        if tco_ns is not None:
            body, changed = re.subn(
                r"(\bq[01]\s*<=\s*)(?!#)([^;\n]+)(;)",
                rf"\g<1>#({tco_ns}) \g<2>\g<3>",
                body,
            )
            read_delay_count += changed
            ram_decl = re.search(
                r"\(\*\s*ram_style\s*=\s*\"block\"\s*\*\).*?;",
                body,
                re.DOTALL,
            )
            assert ram_decl is not None

        ports = set(re.findall(r"\b(?:ce|we|q)([01])\b", header))
        counter_lines = [
            "\n// Simulation-only SRAM transaction counters; not synthesized.",
            "integer wino_sram_reads;",
            "integer wino_sram_writes;",
            "initial begin wino_sram_reads = 0; wino_sram_writes = 0; end",
            "always @(posedge clk) begin",
        ]
        for port in sorted(ports):
            ce, we, q = f"ce{port}", f"we{port}", f"q{port}"
            if ce not in header:
                continue
            if q in header:
                if we in header:
                    counter_lines.extend(
                        [
                            f"  if ({ce} === 1'b1) begin",
                            f"    if ({we} === 1'b1) wino_sram_writes = wino_sram_writes + 1;",
                            "    else wino_sram_reads = wino_sram_reads + 1;",
                            "  end",
                        ]
                    )
                else:
                    counter_lines.append(
                        f"  if ({ce} === 1'b1) wino_sram_reads = wino_sram_reads + 1;"
                    )
            elif we in header:
                counter_lines.append(
                    f"  if (({ce} === 1'b1) && ({we} === 1'b1)) wino_sram_writes = wino_sram_writes + 1;"
                )
        counter_lines.extend(
            [
                "end",
                "always @(posedge tb.report_sram_accesses)",
                f'  $fwrite(tb.sram_counter_file, "WINO_INTERNAL_SRAM module={module_name} name=%m reads=%0d writes=%0d\\n", wino_sram_reads, wino_sram_writes);',
                "",
            ]
        )

        insert_at = ram_decl.end()
        body = body[:insert_at] + "\n".join(counter_lines) + body[insert_at:]
        source = source[: match.end()] + body + source[end:]
    return source, read_delay_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--read-tco-ns")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for old in args.output_dir.glob("*.v"):
        old.unlink()

    model_count = 0
    read_delay_count = 0
    for source_path in sorted(args.source_dir.glob("*.v")):
        source = source_path.read_text()
        if "ram_style" not in source:
            continue
        transformed, changed = instrument(source, args.read_tco_ns)
        if transformed == source:
            raise SystemExit(f"No RAM module instrumented in {source_path}")
        (args.output_dir / source_path.name).write_text(transformed)
        model_count += 1
        read_delay_count += changed

    if model_count == 0:
        raise SystemExit(f"No HLS RAM models found in {args.source_dir}")
    if args.read_tco_ns is not None and read_delay_count != 6:
        raise SystemExit(
            f"Expected 6 internal RAM read outputs for tCO, changed {read_delay_count}"
        )
    print(
        f"Instrumented {model_count} HLS RAM model files; "
        f"added tCO to {read_delay_count} read outputs."
    )


if __name__ == "__main__":
    main()
