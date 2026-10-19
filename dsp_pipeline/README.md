# MyoCortex DSP pipeline: software golden model (MC-14 / MC-15 / MC-18)

Python reference for the FPGA signal-conditioning chain. The RTL must reproduce `filters_fixed.py`
and `features.py` bit for bit.

```
dataset EMG -> stimulus (1500 Hz, mains, sensor, ADC) -> HP 20 -> LP 450 -> notch 50 -> features (256/64)
```

| File | Role |
| --- | --- |
| `config.py` | Every parameter of the spec (rates, filters, word lengths, window). OPEN = undecided. |
| `datasets.py` | Loaders for Izmir raw, NinaPro DB2 and GRABMyo, returning volts at the electrode. |
| `stimulus.py` | Resample to 1500 Hz, add synthetic 50 Hz + harmonics, sensor model, ADS1015 model. |
| `filters_float.py` | Filter design and the causal floating-point reference chain. |
| `filters_fixed.py` | Bit-accurate time-shared biquad engine (the model the RTL must match). |
| `features.py` | Bit-accurate windowing and features (sum\|x\|, sum x², WL, ZC, MAV, RMS) plus an independent check version. |
| `verify.py` | Checks: filter response, fixed vs float error, directed tests, feature cross-check. |
| `vectors.py` | Writes testbench files (hex streams, coefficients, features, parameters). |
| `run_pipeline.py` | Runs everything on a chosen recording and writes `out/<dataset>_<id>/`. |

```
python verify.py
python run_pipeline.py izmir 10 --seconds 30
python run_pipeline.py db2 1 --exercise 1 --start 20 --seconds 30
```

Output files in `out/<run>/`: `adc_in.hex` (12-bit input), `hp_out.hex` / `lp_out.hex` / `notch_out.hex`
(per-stage outputs, DATA_W bits), `coeffs.hex`, `features.csv`, `params.json`, `report.png`.
All streams are interleaved ch0, ch1, ch2, ch3 per sample tick.
