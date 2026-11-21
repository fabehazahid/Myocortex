# Turns dataset EMG into the ADC numbers our FPGA would receive.
# Steps: resample to 1500 Hz -> add power-line noise -> sensor -> ADC

from fractions import Fraction

import numpy as np
from scipy import signal

import config


def resample_to_our_rate(emg_volts, file_rate, labels=None):
    # e.g. 2000 Hz -> 1500 Hz is "up by 3, down by 4"
    ratio = Fraction(config.SAMPLE_RATE_HZ) / Fraction(file_rate).limit_denominator(10000)
    resampled = signal.resample_poly(emg_volts, ratio.numerator, ratio.denominator, axis=0)

    if labels is not None:
        # for each new sample, take the label of the closest earlier original sample
        new_labels = np.zeros(len(resampled), dtype=int)
        for i in range(len(resampled)):
            original_index = int(i * file_rate / config.SAMPLE_RATE_HZ)
            original_index = min(original_index, len(labels) - 1)
            new_labels[i] = labels[original_index]
        labels = new_labels

    return resampled, labels


def add_mains_noise(emg_volts, random_seed=0):
    # adds 50 Hz and its harmonics, with a random starting phase on each channel
    random_generator = np.random.default_rng(random_seed)
    num_samples, num_channels = emg_volts.shape
    time_s = np.arange(num_samples) / config.SAMPLE_RATE_HZ
    noisy = emg_volts.copy()

    for frequency_hz, amplitude_v in config.MAINS_NOISE_AMPLITUDES_V.items():
        phases = random_generator.uniform(0, 2 * np.pi, num_channels)
        for channel in range(num_channels):
            noisy[:, channel] += amplitude_v * np.sin(2 * np.pi * frequency_hz * time_s + phases[channel])
    return noisy


def sensor_model(emg_volts, remove_offset=True):
    # The ADC measures (sensor output - 1.5 V reference), which is gain * EMG.
    # OPEN: we remove each channel's average first because the datasets contain
    # electrode offsets of several mV that the real sensor would most likely block.
    if remove_offset:
        emg_volts = emg_volts - emg_volts.mean(axis=0)

    adc_input_v = emg_volts * config.SENSOR_GAIN + config.REFERENCE_ERROR_V

    # the sensor output cannot go past its supply limits
    adc_input_v = np.clip(adc_input_v, -config.SENSOR_MAX_OUTPUT_V, config.SENSOR_MAX_OUTPUT_V)
    return adc_input_v


def adc_model(adc_input_v):
    # round to the nearest 1 mV step and limit to a signed 12-bit number
    max_code = 2 ** (config.ADC_BITS - 1) - 1      # 2047
    min_code = -(2 ** (config.ADC_BITS - 1))       # -2048
    codes = np.round(adc_input_v / config.ADC_STEP_V)
    codes = np.clip(codes, min_code, max_code)
    return codes.astype(np.int64)


def make_adc_codes(emg_volts, file_rate, labels=None, random_seed=0, add_noise=True, remove_offset=True):
    # runs all the steps above, returns (adc codes, labels, number of clipped samples)
    signal_v, labels = resample_to_our_rate(emg_volts, file_rate, labels)
    if add_noise:
        signal_v = add_mains_noise(signal_v, random_seed)

    adc_input_v = sensor_model(signal_v, remove_offset)
    num_clipped = int(np.sum(np.abs(adc_input_v) >= config.SENSOR_MAX_OUTPUT_V))

    return adc_model(adc_input_v), labels, num_clipped
