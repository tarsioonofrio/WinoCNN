#!/usr/bin/env bash
set -euo pipefail
source /etc/profile.d/modules.sh
module use /soft64/modulefiles
module load xilinx/vivado/2019.2
cd "$(dirname "$0")"
exec vivado_hls -f hw_scripts/script.tcl
