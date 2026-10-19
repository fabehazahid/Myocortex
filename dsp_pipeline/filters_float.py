# Filter design and the floating-point (exact) version of the filter chain.
# This is the "correct answer" that the fixed-point version is compared against.

import numpy as np
from scipy import signal

import config


def design_filters():
    # Returns one row per filter in STAGE_ORDER.
    # Each row is [b0, b1, b2, a0, a1, a2] (scipy's "sos" format).
    highpass = signal.iirfilter(2, config.HIGHPASS_CUTOFF_HZ, btype="highpass",
                                ftype=config.FILTER_TYPE, fs=config.SAMPLE_RATE_HZ, output="sos")[0]
    lowpass = signal.iirfilter(2, config.LOWPASS_CUTOFF_HZ, btype="lowpass",
                               ftype=config.FILTER_TYPE, fs=config.SAMPLE_RATE_HZ, output="sos")[0]
    notch_b, notch_a = signal.iirnotch(config.NOTCH_FREQ_HZ, config.NOTCH_QUALITY_FACTOR,
                                       fs=config.SAMPLE_RATE_HZ)
    notch = np.concatenate([notch_b, notch_a])

    filters_by_name = {"highpass": highpass, "lowpass": lowpass, "notch": notch}
    rows = [filters_by_name[name] for name in config.STAGE_ORDER]
    return np.array(rows)


def run_float_filters(adc_codes, filter_coeffs=None):
    # adc_codes: (samples, channels)
    # returns the output after every stage: (stages, samples, channels), in ADC steps
    # sosfilt only runs forward in time, like the hardware does
    if filter_coeffs is None:
        filter_coeffs = design_filters()

    signal_now = adc_codes.astype(float)
    stage_outputs = []
    for stage_coeffs in filter_coeffs:
        signal_now = signal.sosfilt([stage_coeffs], signal_now, axis=0)
        stage_outputs.append(signal_now)
    return np.array(stage_outputs)
