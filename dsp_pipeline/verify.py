# Checks for the software models.
#   Level 1 - are the filters designed correctly?
#   Level 2 - how much error does the fixed-point maths add?
#   Level 4 - do simple known inputs give the expected outputs?
#   Level 5 - do the two feature versions give identical results?
#
# Two kinds of error are checked separately:
#   - rounding the coefficients changes the frequency response (checked in level 1)
#   - rounding inside the maths adds noise (levels 2 and 4). For this we compare
#     against a float chain that uses the SAME rounded coefficients.
#
# Run "python verify.py" to do levels 1 and 4 on their own.

import numpy as np
from scipy import signal

import config
import features
import filters_fixed
import filters_float

# skip the first 0.5 s, while the filters are still settling after reset
SETTLING_SAMPLES = int(0.5 * config.SAMPLE_RATE_HZ)


def print_result(test_name, passed, details):
    status = "PASS" if passed else "FAIL"
    print(f"  [{status}] {test_name}: {details}")
    return passed


def rounded_coeffs_as_float():
    return filters_fixed.integer_coeffs_to_float(filters_fixed.make_integer_coeffs())


def to_db(value):
    return 20 * np.log10(abs(value) + 1e-15)


def check_filter_design():
    print("Level 1 - filter design")
    exact_coeffs = filters_float.design_filters()
    rounded_coeffs = rounded_coeffs_as_float()
    all_passed = True

    for version_name, coeffs in [("float", exact_coeffs), ("rounded", rounded_coeffs)]:
        test_frequencies = [config.HIGHPASS_CUTOFF_HZ, config.LOWPASS_CUTOFF_HZ, config.NOTCH_FREQ_HZ, 150.0]
        _, response = signal.sosfreqz(coeffs, worN=test_frequencies, fs=config.SAMPLE_RATE_HZ)
        highpass_db = to_db(response[0])
        lowpass_db = to_db(response[1])
        notch_db = to_db(response[2])
        passband_db = to_db(response[3])

        # the filter is stable if every pole is inside the unit circle
        largest_pole_radius = 0
        for row in coeffs:
            poles = np.roots(row[3:])
            largest_pole_radius = max(largest_pole_radius, np.abs(poles).max())

        passed = largest_pole_radius < 1 and notch_db < -config.MIN_NOTCH_DEPTH_DB
        details = (f"HP {highpass_db:.2f} dB @ {config.HIGHPASS_CUTOFF_HZ} Hz, "
                   f"LP {lowpass_db:.2f} dB @ {config.LOWPASS_CUTOFF_HZ} Hz, "
                   f"notch {notch_db:.1f} dB @ {config.NOTCH_FREQ_HZ} Hz, "
                   f"passband {passband_db:.2f} dB @ 150 Hz, largest pole radius {largest_pole_radius:.6f}")
        all_passed = print_result(f"{version_name} response", passed, details) and all_passed
    return all_passed


def check_fixed_against_float(adc_codes, fixed_outputs, float_outputs, overflow_count):
    # float_outputs must come from the float chain using rounded_coeffs_as_float()
    print("Level 2 - fixed point vs float (same rounded coefficients)")
    scale = 2 ** config.GUARD_BITS
    fixed_final = fixed_outputs[-1][SETTLING_SAMPLES:] / scale
    float_final = float_outputs[-1][SETTLING_SAMPLES:]
    error = fixed_final - float_final

    worst_error = np.abs(error).max()
    rms_error = np.sqrt(np.mean(error ** 2))
    signal_power = np.sum(float_final ** 2, axis=0)
    error_power = np.maximum(np.sum(error ** 2, axis=0), 1e-30)
    snr_db = 10 * np.log10(signal_power / error_power)

    all_passed = print_result("arithmetic error", worst_error < config.MAX_ALLOWED_ERROR_LSB,
                              f"worst {worst_error:.4f} LSB (limit {config.MAX_ALLOWED_ERROR_LSB}), "
                              f"rms {rms_error:.4f} LSB, SNR per channel {np.round(snr_db, 1)} dB")

    # for information: error against the exact (unrounded) coefficients
    exact_final = filters_float.run_float_filters(adc_codes)[-1][SETTLING_SAMPLES:]
    print(f"  [INFO] vs exact coefficients: worst {np.abs(fixed_final - exact_final).max():.4f} LSB "
          f"(includes coefficient rounding)")

    largest_value = np.abs(fixed_outputs).max()
    value_limit = 2 ** (config.DATA_TOTAL_BITS - 1) - 1
    all_passed = print_result("overflow", overflow_count == 0,
                              f"{overflow_count} overflows, largest value {largest_value} of {value_limit}") and all_passed
    return all_passed


def check_known_inputs():
    print("Level 4 - known input tests")
    num_samples = 3 * config.SAMPLE_RATE_HZ
    sample_index = np.arange(num_samples)
    time_s = sample_index / config.SAMPLE_RATE_HZ
    full_scale = 2 ** (config.ADC_BITS - 1) - 1

    test_inputs = {
        "impulse": np.where(sample_index == 10, 1000, 0),
        "dc step": np.where(sample_index >= 10, 1000, 0),
        "tone 150 Hz": np.round(1000 * np.sin(2 * np.pi * 150 * time_s)),
        "tone 50 Hz": np.round(1000 * np.sin(2 * np.pi * 50 * time_s)),
        "tone 600 Hz": np.round(1000 * np.sin(2 * np.pi * 600 * time_s)),
        "full-scale square 25 Hz": np.where(np.sin(2 * np.pi * 25 * time_s) >= 0, full_scale, -full_scale - 1),
    }

    all_passed = True
    for test_name, one_channel in test_inputs.items():
        # same signal on all 4 channels
        adc_codes = np.zeros((num_samples, config.NUM_CHANNELS), dtype=np.int64)
        for channel in range(config.NUM_CHANNELS):
            adc_codes[:, channel] = one_channel

        chain = filters_fixed.FixedPointFilterChain()
        fixed_out = chain.run(adc_codes)[-1][:, 0] / (2 ** config.GUARD_BITS)
        float_out = filters_float.run_float_filters(adc_codes, rounded_coeffs_as_float())[-1][:, 0]
        worst_error = np.abs(fixed_out - float_out).max()

        last_second = fixed_out[-config.SAMPLE_RATE_HZ:]
        last_second_rms = np.sqrt(np.mean(last_second ** 2))
        details = f"worst fixed-float error {worst_error:.4f} LSB, last-second rms {last_second_rms:.3f} LSB"

        if test_name == "dc step":
            passed = np.abs(last_second).max() < 1          # the high-pass must remove the step
            details += " (should be about 0)"
        elif test_name.startswith("tone"):
            input_rms = 1000 / np.sqrt(2)
            gain = last_second_rms / input_rms
            details += f", gain {to_db(gain):.1f} dB"
            if "150" in test_name:
                passed = gain > 0.9                          # 150 Hz should pass
            else:
                passed = gain < 0.5                          # 50 Hz and 600 Hz should be cut
        elif test_name.startswith("full-scale"):
            passed = chain.overflow_count == 0
            details += f", {chain.overflow_count} overflows"
        else:
            passed = True

        all_passed = print_result(test_name, passed and worst_error < config.MAX_ALLOWED_ERROR_LSB, details) and all_passed
    return all_passed


def check_features(feature_input, feature_rows):
    print("Level 5 - features")
    simple_rows = features.extract_features_simple(feature_input)
    same = simple_rows.shape == feature_rows.shape and np.array_equal(simple_rows, feature_rows)
    return print_result("block version == simple version", same,
                        f"{len(feature_rows)} rows compared; worst-case bit widths {features.worst_case_bit_widths()}")


if __name__ == "__main__":
    design_ok = check_filter_design()
    known_inputs_ok = check_known_inputs()
    print("ALL PASS" if design_ok and known_inputs_ok else "SOME CHECKS FAILED")
