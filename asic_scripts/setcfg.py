#!/usr/bin/env python3
"""Set the WinoCNN hardware configuration (src/wino_hw_config.h + BATCH_SIZE).

Usage:
    python3 asic_scripts/setcfg.py <DOMAIN> <M> <N> <H2> <W2> <QBIT> <B>

    DOMAIN = WINO_DOMAIN_SIZE  (4 = F(2x2,3x3), 6 = F(4x4,3x3))
    M      = WINO_HEIGHT
    N      = WINO_WIDTH
    H2     = WINO_H2
    W2     = WINO_W2
    QBIT   = INDEPTH_MINITILE_SIZE_BITWIDTH  (0 -> Q=1)
    B      = BATCH_SIZE

Example (the validated micro configs):
    python3 asic_scripts/setcfg.py 4 2 1 2 1 0 1   # F(2x2,3x3), 1 PE
    python3 asic_scripts/setcfg.py 6 2 1 2 1 0 1   # F(4x4,3x3), 1 PE

After running, regenerate the systolic kernel:
    python3 codegen/gen_systolic.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) != 8:
        print(__doc__)
        return 2
    dom, m, n, h2, w2, qbit, b = sys.argv[1:8]

    cfg = f"""#ifndef _WINO_HW_CONFIG_H_
#define _WINO_HW_CONFIG_H_
#define WINO_DOMAIN_SIZE {dom}
#define INPUT_BUFFER_DEPTH_BITWIDTH 12
#define OUTPUT_BUFFER_DEPTH_BITWIDTH 10
#define WEIGHT_BUFFER_DEPTH_BITWIDTH 10
#define WINO_HEIGHT {m}
#define WINO_WIDTH {n}
#define INBUFFER_HEIGHT_BITWIDTH 3
#define INDEPTH_MINITILE_SIZE_BITWIDTH {qbit}
#define WINO_W2 {w2}
#define WINO_H2 {h2}
#endif
"""
    with open(os.path.join(ROOT, "src", "wino_hw_config.h"), "w") as f:
        f.write(cfg)

    macro = os.path.join(ROOT, "src", "wino_macro.h")
    s = open(macro).read()
    s = re.sub(r"#define BATCH_SIZE \d+", f"#define BATCH_SIZE {b}", s)
    with open(macro, "w") as f:
        f.write(s)

    print(f"config: dom={dom} M={m} N={n} H2={h2} W2={w2} Q={1 << int(qbit)} B={b}")
    print("next: python3 codegen/gen_systolic.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
