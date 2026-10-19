# Windowing and feature extraction, written the way the FPGA will do it.
#
# For each channel, every window of 256 samples gives:
#   sum_abs = sum of |x|               mav = sum_abs >> 8   (divide by 256)
#   sum_sq  = sum of x*x               rms = sqrt(sum_sq >> 8), whole number
#   wl      = sum of |x[i] - x[i-1]|   (waveform length)
#   zc      = number of times x changes sign with a jump of at least ZERO_CROSSING_THRESHOLD
#
# A new window finishes every 64 samples. The hardware keeps sums for blocks of
# 64 samples and adds the last 4 blocks together, so it never re-adds 256 values.
# The difference for the first sample of a window uses the sample just before the
# window (0 right after reset), so that every window is exactly 4 blocks.

import math

import numpy as np

import config

COLUMN_NAMES = ["end_sample", "channel", "sum_abs", "sum_sq", "wl", "zc", "mav", "rms"]


def filter_output_to_feature_input(filter_output):
    # remove the guard bits (with rounding) so values are in whole ADC steps,
    # then limit them to FEATURE_INPUT_BITS
    rounding_offset = 2 ** (config.GUARD_BITS - 1)
    values = (filter_output + rounding_offset) >> config.GUARD_BITS

    max_value = 2 ** (config.FEATURE_INPUT_BITS - 1) - 1
    min_value = -(2 ** (config.FEATURE_INPUT_BITS - 1))
    return np.clip(values, min_value, max_value)


def extract_features(feature_input):
    # feature_input: (samples, channels) integers
    # returns one row per window per channel, columns as in COLUMN_NAMES
    blocks_per_window = config.WINDOW_LENGTH // config.WINDOW_STEP
    rows = []

    for channel in range(feature_input.shape[1]):
        previous_sample = 0
        finished_blocks = []
        block_sum_abs = 0
        block_sum_sq = 0
        block_wl = 0
        block_zc = 0

        for n in range(len(feature_input)):
            sample = int(feature_input[n, channel])
            difference = sample - previous_sample

            block_sum_abs += abs(sample)
            block_sum_sq += sample * sample
            block_wl += abs(difference)
            sign_changed = previous_sample * sample < 0
            if sign_changed and abs(difference) >= config.ZERO_CROSSING_THRESHOLD:
                block_zc += 1

            previous_sample = sample

            block_is_full = (n + 1) % config.WINDOW_STEP == 0
            if block_is_full:
                finished_blocks.append([block_sum_abs, block_sum_sq, block_wl, block_zc])
                if len(finished_blocks) > blocks_per_window:
                    finished_blocks.pop(0)
                block_sum_abs = 0
                block_sum_sq = 0
                block_wl = 0
                block_zc = 0

                if len(finished_blocks) == blocks_per_window:
                    sum_abs = sum(block[0] for block in finished_blocks)
                    sum_sq = sum(block[1] for block in finished_blocks)
                    wl = sum(block[2] for block in finished_blocks)
                    zc = sum(block[3] for block in finished_blocks)
                    mav = sum_abs >> config.WINDOW_SHIFT
                    rms = math.isqrt(sum_sq >> config.WINDOW_SHIFT)
                    rows.append([n, channel, sum_abs, sum_sq, wl, zc, mav, rms])

    # sort by time, then by channel (the order the hardware sends them)
    rows.sort(key=lambda row: (row[0], row[1]))
    return np.array(rows, dtype=np.int64).reshape(-1, len(COLUMN_NAMES))


def extract_features_simple(feature_input):
    # A second, straightforward version that recalculates every window from scratch.
    # It is only used to check that extract_features() is correct.
    rows = []
    num_samples, num_channels = feature_input.shape

    for window_end in range(config.WINDOW_LENGTH - 1, num_samples, config.WINDOW_STEP):
        window_start = window_end - config.WINDOW_LENGTH + 1
        for channel in range(num_channels):
            sum_abs = 0
            sum_sq = 0
            wl = 0
            zc = 0
            for n in range(window_start, window_end + 1):
                sample = int(feature_input[n, channel])
                previous_sample = int(feature_input[n - 1, channel]) if n > 0 else 0
                difference = sample - previous_sample
                sum_abs += abs(sample)
                sum_sq += sample * sample
                wl += abs(difference)
                if previous_sample * sample < 0 and abs(difference) >= config.ZERO_CROSSING_THRESHOLD:
                    zc += 1
            mav = sum_abs >> config.WINDOW_SHIFT
            rms = math.isqrt(sum_sq >> config.WINDOW_SHIFT)
            rows.append([window_end, channel, sum_abs, sum_sq, wl, zc, mav, rms])

    return np.array(rows, dtype=np.int64).reshape(-1, len(COLUMN_NAMES))


def worst_case_bit_widths():
    # number of bits each output needs for the largest possible input
    largest_sample = 2 ** (config.FEATURE_INPUT_BITS - 1)
    largest_values = {
        "sum_abs": config.WINDOW_LENGTH * largest_sample,
        "sum_sq": config.WINDOW_LENGTH * largest_sample * largest_sample,
        "wl": config.WINDOW_LENGTH * 2 * largest_sample,
        "zc": config.WINDOW_LENGTH,
        "mav": largest_sample,
        "rms": largest_sample,
    }
    widths = {}
    for name, value in largest_values.items():
        widths[name] = value.bit_length()
    return widths
