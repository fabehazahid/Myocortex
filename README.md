# MyoCortex

**FPGA-accelerated Hyperdimensional Computing (HDC) for real-time EMG gesture control of a robotic gripper.**

Final-year project, NUST. Surface EMG → DSP → HDC inference → gripper command.
HDC runs on an FPGA (Alinx board, Xilinx Zynq-7000 XC7Z020). We compare **FPGA vs CPU (ARM/software)** on latency, power/energy, and classification performance.

> **Status: Phase 1 (software-only experiments).** No FPGA results, no hardware measurements, and no final DSP interface yet. Every number below is either cited from a paper or marked unknown.

---

## Tag legend

Every claim in the docs carries one of these tags.

| Tag | Meaning |
|---|---|
| `[VERIFIED-SOURCE]` | Read directly from the source paper/datasheet by us |
| `[PAPER-REPORTED]` | Number reported by a paper we cite |
| `[ESTIMATE]` | Our reasoning, not measured |
| `[RECOMMENDATION]` | Our design choice |
| `[UNKNOWN]` | Not yet checked or measured |
| `[DSP-DEP]` | Depends on the DSP design (teammate's work, not yet shared). Placeholder until files arrive |

---

## Pipeline

```
 sEMG sensor ──► ADC (I2C) ──► DSP (filter, window, features) ──► HDC encoder ──► Associative memory ──► Gripper command
                                [DSP-DEP]                          (FPGA vs CPU)   (Hamming distance)     (servo)
                                                                        │
                                                         INA219 power monitor + latency timers
```

---

## Hardware (current decisions)

| Part | Choice | Status |
|---|---|---|
| FPGA board | Alinx, Zynq-7000 XC7Z020 (ARM + programmable logic) | Decided |
| ADC | 4 × TI ADS1015 (12-bit, I2C, 3.3 kSPS max per chip), one per channel, target ~1.6–2 kHz per channel | Decided. Real sample rate and jitter `[UNKNOWN]` |
| I2C layout | One bus vs two buses | `[UNKNOWN]` not decided |
| Sensor (main) | DFRobot SEN0240 | Output type (envelope or near-raw), bandwidth, voltage range `[UNKNOWN]` until datasheet is checked |
| Sensor (alternative) | NCRA dry electrode | Specs unverified |
| Power measurement | INA219 | Decided |
| Actuator | Robotic gripper (servo driver) | Decided |

---

## Datasets

None of these three matches our SEN0240 / dry-sensor hardware. Domain mismatch is a known limitation.

| # | Dataset | Role | Key facts | License |
|---|---|---|---|---|
| 1 | **Ozdemir (Izmir) 4-ch sEMG** | **Main training set** | 40 subjects, 4 forearm muscles, bipolar Ag/AgCl, BIOPAC MP36, 2 kHz, 5–500 Hz band-pass + 50 Hz notch (filtered copy; raw also provided), ±10 mV, 10 gestures incl. rest, 5 cycles per subject in one session `[VERIFIED-SOURCE]` | CC BY 4.0 |
| 2 | **GRABMyo** (PhysioNet) | Drift / recalibration stretch goal | 43 subjects, 16 forearm + 12 wrist channels, 2048 Hz, 17 gestures, 3 sessions on 3 different days. We must pick 4 channels and document why | ODC-BY 1.0 |
| 3 | **NinaPro DB2** | Comparison with published work | 40 subjects, 12 ch, Delsys Trigno, 2 kHz, 52 gestures, 6 repetitions. Gesture subset and split must match the paper we compare against `[UNKNOWN]` | CC BY-NC 4.0 |

**Items to verify**
- Ozdemir bit depth: our notes say 24-bit; the dataset paper we have does not state it. `[UNKNOWN]` check Mendeley page.
- Ozdemir DOI: our notes say `.1`; the paper cites `10.17632/ckwc76xr2z.2`. Use `.2` unless the `.1` is checked. `[UNKNOWN]`
- Ozdemir timeline: each gesture is held 6 s with 4 s rest around it; cycles are separated by 30 s rest. Use this when labelling windows. `[VERIFIED-SOURCE]`

---

## HDC design

### Plain-language glossary

| Name | Meaning |
|---|---|
| **Hypervector (HV)** | A very long vector of bits (here, 0/1). Information is spread across all bits, so a few flipped bits do little damage (noise tolerance) |
| `HV_LEN` | Length of a hypervector (bits) |
| `N_CH` | Number of EMG channels (4) |
| `N_LEVELS` | Number of amplitude levels a feature is quantized into |
| `N_CLASSES` | Number of gestures |
| `WIN_LEN` | Window length in samples `[DSP-DEP]` |
| `NGRAM` | How many consecutive time steps are combined (Candidate B only) |
| `CHUNK` | How many hypervector bits the hardware processes per clock cycle (hardware parallelism choice) |
| **XOR (binding)** | Combines two HVs into a new one unlike both. Used to attach "channel identity" to "amplitude" |
| **Majority vote (bundling)** | Per-bit vote across several HVs. Result stays similar to all inputs |
| **Hamming distance** | Count of differing bits between two HVs. Smaller = more similar |
| **Prototype** | One HV per gesture, made by bundling many training windows of that gesture |
| **Associative memory** | Table of prototypes. Inference = find the closest one |

### Candidate encoders

| | **A: window-feature ID-level** | **B: Rahimi/Schmuck sample-level + N-gram** | **C: random projection** |
|---|---|---|---|
| Idea | Features per window → quantize → bind with channel ID → bundle | Per-sample spatial record, then temporal N-gram | Project feature vector through random matrix |
| Status | **Provisional choice, build first** `[RECOMMENDATION]` | Later; kept in software as accuracy reference | Not justified with ~4 features. Revisit only if DSP gives ~16+ features `[DSP-DEP]` |
| Depends on DSP | Yes (features, window) `[DSP-DEP]` | Mostly no (works on sample stream) | Yes |
| Variants | none | **B-original** (bipolar ±1, integer gesture vectors, cosine) and **B-binary** (Hamming, counters or approximate bundling), treated separately | none |

We do not pick the most accurate option by default. We pick the best trade-off of accuracy, resources, latency, energy, and independence from the DSP design. `[RECOMMENDATION]`

### Candidate A math (per window)

1. Per channel, take feature `x_c` (normalized to [0, 1)) `[DSP-DEP]`.
2. Quantize: `q_c = clip(floor(N_LEVELS * x_c), 0, N_LEVELS - 1)`.
3. Level vectors `LV[q]` are *correlated*: start from a random vector and flip the next `HV_LEN / 2 / (N_LEVELS - 1)` bits (rounded) of a fixed random permutation per level. Neighbouring levels stay similar; the two end levels are about orthogonal.
4. Bind: `B_c = ID_c XOR LV[q_c]` (`ID_c` = fixed random vector per channel).
5. Bundle: `H = majority(B_1 … B_N_CH)` plus a fixed random **tie-break vector**. With `N_CH = 4` (even), ties are possible, so this vector is required.
6. Train: prototype `P_k = majority of windows of class k`. Keep **integer counters** so online updates are possible.
7. Infer: `y = argmin_k Hamming(H, P_k)`.

---

## Literature (cited numbers only)

| Work | Result | Notes |
|---|---|---|
| Rahimi et al. 2016 | 97.8% avg, 4 ch, 5 gestures, 5 subjects `[VERIFIED-SOURCE]` | Cosine on ±1 vectors, `HV_LEN` = 10,000, 21 levels, enveloped input at 500 Hz downsampled by 250 (50 for one subject), N-gram 3–5. Training = random 25% of samples from the same recordings (**optimistic**). Spatial-only: 90.8%. Accuracy held down to `HV_LEN` ≈ 6,000. **The 97.8% is a gesture-level result (N-gram spans ~0.4–2 s), not a short real-time window result** |
| Schmuck et al. (arXiv 1807.08583) | UltraScale VHDL HDC library | Rematerialized level/ID vectors, cellular-automaton ID memory, saturating counters vs approximate bundling, combinational vs vector-sequential associative memory. Case study: `HV_LEN` 8192, 21 levels, N-gram 3, 4 ch, 5 classes. Paper text not yet read by us, so no table values are quoted |
| Zhou 2021 | up to 93.34%, 13 gestures `[PAPER-REPORTED]` | EMG + accelerometer |
| GateMate 2026 | HDC best case 95.20% vs LDA 98.54% `[PAPER-REPORTED]` | 32 ch, 5 classes. HDC is *not* always more accurate than LDA |
| Moin 2019 | 88.87% `[PAPER-REPORTED]` | Below 90%; do not cite as a >90% result |

---

## Phase 1 experiment plan (software first)

| Item | Plan |
|---|---|
| Encoders | A first, then B (software reference). C only if justified |
| `HV_LEN` | 1024, 2048, 4096, 10000 |
| `N_LEVELS` | 8, 16, 32 |
| Windowing | Test **short real-time windows** and downsampling (Rahimi's setup is gesture-length, ours is not) `[DSP-DEP]` |
| Split 1 | Leave-subjects-out (grouped folds) |
| Split 2 | Within-subject: train cycles 1–3, test cycles 4–5. **Never mix windows from the same cycle across train and test** |
| Baseline | LDA on the same features |
| Metrics | Accuracy, macro-F1, balanced accuracy, confusion matrix, inference time |
| Seeds | At least 5 random seeds; log the master seed |
| Sample rate | Ozdemir is 2 kHz, same as our target, so no resampling if we sample near 2 kHz `[VERIFIED-SOURCE]` |

### FPGA vs CPU comparison (Phase 2, after Vivado)

| Metric | CPU (ARM) | FPGA (PL) | How measured |
|---|---|---|---|
| End-to-end latency | `[UNKNOWN]` | `[UNKNOWN]` | Hardware timers / timestamp log |
| Power / energy per prediction | `[UNKNOWN]` | `[UNKNOWN]` | INA219 |
| Accuracy / macro-F1 | `[UNKNOWN]` | `[UNKNOWN]` | Same test data, same model |
| Resource use (LUT, FF, BRAM, DSP) | n/a | `[UNKNOWN]` | Vivado synthesis report |

**Rules:** no resource, speed, or power number goes in without Vivado synthesis or a cited source. Any XC7Z020 resource figure must be labelled "verify against the Xilinx datasheet". Schmuck's UltraScale numbers are never ported directly; scaling reasoning must be shown.

---

## DSP interface contract (fill when teammate shares files)

| Item | Placeholder | Final value |
|---|---|---|
| Features per channel | `[DSP-DEP]` | |
| Feature order | `[DSP-DEP]` | |
| `WIN_LEN` | `[DSP-DEP]` | |
| Window overlap | `[DSP-DEP]` | |
| Normalization | `[DSP-DEP]` | |
| Numeric format (fixed-point width) | `[DSP-DEP]` | |

When the real files arrive, this table gets updated and the replaced placeholders are listed in the changelog.

---

## Open items

- [ ] Measure real ADS1015 sample rate and jitter (timestamp log, 60 s)
- [ ] Check SEN0240 datasheet (output type, bandwidth, voltage range)
- [ ] Get DSP files from teammate; fill the contract above
- [ ] Decide I2C bus layout for the four ADCs
- [ ] Verify Ozdemir bit depth and DOI version
- [ ] Choose GRABMyo 4-channel subset and document why
- [ ] Identify the NinaPro comparison paper (gesture subset and split)
- [ ] Read Schmuck et al. in full before using any of its design claims

## Corrections needed in title-defense slides

| Slide item | Problem | Fix |
|---|---|---|
| Moin 2021: 97.12% | Not verified | Check against the paper before reuse |
| Moin 2019 cited for "<5.5% drop" | Not verified | Check; Moin 2019 reported 88.87% (below 90%) |
| "SENO240" | Typo | **SEN0240** |
| ADC: ADS1115 | Wrong part | **ADS1015** (12-bit) |
| "ADC 1 kHz" on system diagram | Does not match plan | Target ~1.6–2 kHz per channel (not yet measured) |

---

## Proposed repo layout `[RECOMMENDATION]`

```
MyoCortex/
├── README.md
├── docs/            # interface contract, design notes, measurement logs
├── data/            # NOT committed; scripts to download datasets
├── sw/
│   ├── datasets/    # loaders: ozdemir, grabmyo, ninapro
│   ├── hdc/         # encoders A/B, training, inference
│   ├── baselines/   # LDA
│   └── experiments/ # sweep configs, seeds, result logs
├── hw/
│   ├── rtl/         # Verilog HDC accelerator
│   ├── vivado/      # project scripts, reports
│   └── firmware/    # ARM-side C/C++ (ADC, DMA, gripper)
└── results/         # tables, plots, confusion matrices
```

## Team

M. Ahsan Ali, M. Rumman Rizwan, Fabeha Zahid Mahmood, Haseeb Ahmed Sardar
Supervisor: Dr. Asim Khan. Co-supervisor: Dr. Kiran Khurshid.

## Licensing

Code license: `[UNKNOWN]` (choose before publishing). Datasets keep their own licenses (see table above); datasets are not redistributed in this repo.
