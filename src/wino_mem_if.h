#ifndef _WINO_MEM_IF_H_
#define _WINO_MEM_IF_H_

/*
 * External-memory interface abstraction.
 *
 * Two flows share the same datapath source:
 *
 *   default (FPGA / Zynq) : the external buffers are AXI master ports
 *                           (`m_axi`, burst-capable, with slave offset).
 *
 *   WINO_ASIC             : the same buffers are plain synchronous
 *                           single-port RAMs (`ap_memory`).  This is what
 *                           the ASIC flow wants: address / data / we / ce
 *                           with a fixed read latency, no AXI protocol, so
 *                           the RAMs can be black-boxed and replaced by the
 *                           PDK SRAM macros in Genus.
 *
 * `_Pragma` requires a single string literal, so the pragma text is built
 * with the STR/XSTR trick (XSTR expands the arguments before stringizing).
 * C-sim (g++) ignores the unknown `HLS` pragma.
 *
 * For `ap_memory` the bundle/offset/depth clauses do not apply, so they are
 * dropped.  Depth still documents the required buffer size.
 */

#define WINO_STR_(x) #x
#define WINO_XSTR_(x) WINO_STR_(x)

#ifdef WINO_ASIC

/* Simple synchronous RAM port.  depth is kept for documentation only.
 * NOTE: parameter names must not be `port`/`bundle`/`depth`, otherwise the
 * tokens in `port=`, `bundle=`, `depth=` would be substituted too. */
#define WINO_MEM_IF_AXI(p, b, d) \
    _Pragma(WINO_XSTR_(HLS interface ap_memory port=p depth=d))

#else /* default: AXI master (FPGA / Zynq) */

#define WINO_MEM_IF_AXI(p, b, d) \
    _Pragma(WINO_XSTR_(HLS interface m_axi port=p offset=slave bundle=b depth=d))

#endif /* WINO_ASIC */

/*
 * Inner-function ports: these are the same physical buffers passed down the
 * call chain.  On the ASIC flow they must also be `ap_memory`; on the AXI
 * flow the top level already binds the bundle, so no extra clause is needed.
 */
#ifdef WINO_ASIC
#define WINO_MEM_IF_PORT(p) \
    _Pragma(WINO_XSTR_(HLS interface ap_memory port=p))
#else
#define WINO_MEM_IF_PORT(p) \
    _Pragma(WINO_XSTR_(HLS interface m_axi port=p))
#endif

#endif /* _WINO_MEM_IF_H_ */
