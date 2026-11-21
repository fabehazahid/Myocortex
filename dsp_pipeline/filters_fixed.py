# Fixed-point (integer only) version of the filter chain.
# It works the same way the FPGA will, so the RTL output must match it exactly.
#
# How the hardware works:
#   - one shared multiplier unit handles all 4 channels, one after another
#   - for each channel it runs high-pass, then low-pass, then notch
#   - each filter computes  y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
#     where x1, x2 are the last two inputs and y1, y2 the last two outputs
#   - after each filter the result is rounded and limited to DATA_TOTAL_BITS

import numpy as np

import config
import filters_float


def make_integer_coeffs(filter_coeffs=None):
    # Converts each coefficient to an integer: round(value * 2^16).
    # Returns one row [b0, b1, b2, a1, a2] per filter (a0 is always 1, so we skip it).
    if filter_coeffs is None:
        filter_coeffs = filters_float.design_filters()
    scale = 2 ** config.COEFF_FRACTION_BITS

    integer_coeffs = []
    for stage_name, row in zip(config.STAGE_ORDER, filter_coeffs):
        b0, b1, b2, a0, a1, a2 = row
        b0_int = int(round(b0 * scale))
        b1_int = int(round(b1 * scale))
        b2_int = int(round(b2 * scale))

        # For our high-pass and low-pass, b1 = -2*b0 or +2*b0 and b2 = b0.
        # If we round b1 on its own this relation breaks a little, and the
        # high-pass would then let some DC offset through. So we keep it exact.
        if stage_name == "highpass":
            b1_int = -2 * b0_int
            b2_int = b0_int
        if stage_name == "lowpass":
            b1_int = 2 * b0_int
            b2_int = b0_int

        a1_int = int(round(a1 * scale))
        a2_int = int(round(a2 * scale))
        integer_coeffs.append([b0_int, b1_int, b2_int, a1_int, a2_int])

    # check every coefficient fits in COEFF_TOTAL_BITS
    largest_allowed = 2 ** (config.COEFF_TOTAL_BITS - 1) - 1
    smallest_allowed = -(2 ** (config.COEFF_TOTAL_BITS - 1))
    for row in integer_coeffs:
        for value in row:
            if value > largest_allowed or value < smallest_allowed:
                raise ValueError(f"coefficient {value} does not fit in {config.COEFF_TOTAL_BITS} bits")

    return np.array(integer_coeffs, dtype=np.int64)


def integer_coeffs_to_float(integer_coeffs):
    # Turns the integer coefficients back into scipy's float format, so we can
    # check the frequency response of the coefficients the hardware will really use.
    scale = 2 ** config.COEFF_FRACTION_BITS
    rows = []
    for b0, b1, b2, a1, a2 in integer_coeffs:
        rows.append([b0 / scale, b1 / scale, b2 / scale, 1.0, a1 / scale, a2 / scale])
    return np.array(rows)


class FixedPointFilterChain:

    def __init__(self, integer_coeffs=None):
        if integer_coeffs is None:
            integer_coeffs = make_integer_coeffs()
        self.coeffs = integer_coeffs.tolist()
        self.num_stages = len(self.coeffs)

        self.max_value = 2 ** (config.DATA_TOTAL_BITS - 1) - 1
        self.min_value = -(2 ** (config.DATA_TOTAL_BITS - 1))
        self.rounding_offset = 2 ** (config.COEFF_FRACTION_BITS - 1)   # adding half before shifting = rounding
        self.reset()

    def reset(self):
        # memory[channel][stage] = [x1, x2, y1, y2]
        self.memory = []
        for channel in range(config.NUM_CHANNELS):
            channel_memory = []
            for stage in range(self.num_stages):
                channel_memory.append([0, 0, 0, 0])
            self.memory.append(channel_memory)
        self.overflow_count = 0

    def process_one_tick(self, samples):
        # samples: one ADC code for each channel
        # returns outputs[stage][channel] for this tick
        outputs = [[0] * config.NUM_CHANNELS for stage in range(self.num_stages)]

        for channel in range(config.NUM_CHANNELS):
            # add guard bits: scale the sample by 2^GUARD_BITS
            x = int(samples[channel]) << config.GUARD_BITS

            for stage in range(self.num_stages):
                b0, b1, b2, a1, a2 = self.coeffs[stage]
                x1, x2, y1, y2 = self.memory[channel][stage]

                total = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                y = (total + self.rounding_offset) >> config.COEFF_FRACTION_BITS

                if y > self.max_value:
                    y = self.max_value
                    self.overflow_count += 1
                elif y < self.min_value:
                    y = self.min_value
                    self.overflow_count += 1

                self.memory[channel][stage] = [x, x1, y, y1]
                outputs[stage][channel] = y
                x = y          # output of this stage is the input of the next

        return outputs

    def run(self, adc_codes):
        # adc_codes: (samples, channels)
        # returns (stages, samples, channels); values are scaled by 2^GUARD_BITS
        num_samples = len(adc_codes)
        results = np.zeros((self.num_stages, num_samples, config.NUM_CHANNELS), dtype=np.int64)
        for n in range(num_samples):
            results[:, n, :] = self.process_one_tick(adc_codes[n])
        return results
