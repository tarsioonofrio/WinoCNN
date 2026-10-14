# WinoCNN

## ISCAS 2027 paper experiments

The WinoCNN implementation, experiment reports, and reproduction instructions
used for the ISCAS 2027 paper are maintained on the [`iscas2027` branch](https://github.com/tarsioonofrio/WinoCNN/tree/iscas2027).
See that branch's README for the workload configuration, dataset provenance,
validation evidence, and commands to reproduce the experiments. This `master`
branch remains the upstream-integration line.

WinoCNN combines systolic array and fast Winograd algorithm for CNN acceleration. This system supports flexible convolution kernel sizes without sacrificing DSP efficiency through various algorithmic, architecture and on-chip memory subsystem designs and optimizations. Overall, our accelerator delivers high throughput and state-of-the-art DSP efficiency compared to previous accelerator implementations.

Copyright (c) <2021> 
  
  <University of Illinois at Urbana-Champaign>

  All rights reserved.

Developed by: 		

  <University of Illinois at Urbana-Champaign>

  <http://dchen.ece.illinois.edu/>

This open source project contains the source code for WinoCNN.

When referencing this application in a publication, please cite the following paper:
  
[1] X. Liu, Y. Chen, C. Hao, A. Dhar and D. Chen, "WinoCNN: Kernel Sharing Winograd Systolic Array for Efficient Convolutional Neural Network Acceleration on FPGAs", IEEE International Conference on Application-specific Systems, Architectures and Processors, 2021. 



