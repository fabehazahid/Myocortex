# MyoCortex

**An FPGA-accelerated Hyperdimensional Computing (HDC) engine for real-time EMG gesture control.**

MyoCortex reads muscle signals (EMG) from the forearm, recognizes the hand gesture using HDC, and drives a robotic gripper. The HDC part runs on an FPGA, and we compare it against a CPU (ARM/software) version.

Final-year project, NUST.

> **Status:** early stage. We are currently running software experiments. No FPGA or hardware results yet.

## What is HDC?

Hyperdimensional Computing represents data as very long binary vectors ("hypervectors"). Each gesture gets one prototype vector, and a new signal is classified by finding the closest prototype. It uses only simple bit operations, so it needs little training data, adapts quickly, and maps well onto FPGA hardware.

## How it works

```
EMG sensor -> ADC -> DSP (filter, window, features) -> HDC classifier -> Gripper command
                                                        (FPGA vs CPU)
```

## Goal

Build a real-time EMG-controlled gripper using HDC accelerated on an FPGA, and compare FPGA vs CPU on:

- Latency
- Power / energy
- Classification performance

## Hardware

| Part | Choice |
|---|---|
| FPGA board | Alinx, Zynq-7000 XC7Z020 |
| EMG sensor | DFRobot SEN0240 (alternative: NCRA dry electrode) |
| ADC | 4 x TI ADS1015 (one per channel) |
| Power measurement | INA219 |
| Actuator | Robotic gripper |

## Datasets

| Dataset | Use |
|---|---|
| Ozdemir 4-channel sEMG | Main training set |
| GRABMyo | Drift / recalibration (stretch goal) |
| NinaPro DB2 | Comparison with published work |

## Team

M. Ahsan Ali, M. Rumman Rizwan, Fabeha Zahid, Mahmood Haseeb Ahmed Sardar

Supervisor: Dr. Asim Khan | Co-supervisor: Dr. Kiran Khurshid

## License

To be decided. Datasets keep their own licenses and are not included in this repo.
