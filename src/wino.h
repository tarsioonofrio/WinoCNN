#ifndef _WINO_H_
#define _WINO_H_
#include "wino_macro.h"
#include <ap_int.h>

void wino_systolic_top(
    INPUT_PORTS_DECLARE(input_DDR),
    WEIGHT_PORTS_DECLARE(weight_DDR),
#ifdef WINO_ASIC
    ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> output_DDR0[FEATURE_PORT_DEPTH],
    ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> output_DDR1[FEATURE_PORT_DEPTH],
    ap_int<32> mem_params[65535]
#else
    // ap_uint<128> *weight_DDR0,
    // ap_uint<128> *weight_DDR1,
    // ap_uint<128> *weight_DDR2,
    // ap_uint<128> *weight_DDR3,
    ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> *output_DDR0,
    ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> *output_DDR1,
    // ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> *output_DDR2,
    // ap_uint<ODDR_WIDTH*BATCH_SIZE*OUT_PORT_BATCH_NUM> *output_DDR3,
    ap_int<32> *mem_params
#endif
    #ifdef __SDSVHLS__
    ,ap_uint<1> ap_clk_div2
    #endif
    );


    
#endif