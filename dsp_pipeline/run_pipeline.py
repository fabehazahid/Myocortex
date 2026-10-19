# Runs the whole pipeline on one recording:
# dataset -> ADC codes -> float and fixed filters -> features -> checks -> test files
#
# Examples:
#   python run_pipeline.py izmir 10
#   python run_pipeline.py db2 1 --exercise 1 --seconds 60
#   python run_pipeline.py grabmyo ../datasets/grabmyo/session1_participant1_gesture10_trial1

import argparse

import matplotlib
matplotlib.use("Agg")      # save plots to a file instead of opening a window
import matplotlib.pyplot as plt
import numpy as np
from scipy import signal

import config
import datasets
import features
import filters_fixed
import filters_float
import stimulus
import vectors
import verify


def read_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", choices=["izmir", "db2", "grabmyo"])
    parser.add_argument("source", help="Izmir participant number, DB2 subject number, or GRABMyo record path")
    parser.add_argument("--exercise", type=int, default=1, help="DB2 exercise number (1-3)")
    parser.add_argument("--start", type=float, default=0.0, help="seconds to skip at the start")
    parser.add_argument("--seconds", type=float, default=30.0, help="how many seconds to process (0 = all)")
    parser.add_argument("--no-mains", action="store_true", help="do not add fake power-line noise")
    parser.add_argument("--seed", type=int, default=0, help="random seed for the noise phases")
    return parser.parse_args()


def load_recording(args):
    if args.dataset == "izmir":
        return datasets.load_izmir(args.source)
    if args.dataset == "db2":
        return datasets.load_ninapro_db2(int(args.source), args.exercise)
    return datasets.load_grabmyo(args.source)


def main():
    args = read_arguments()
    emg_volts, file_rate, labels = load_recording(args)

    # keep only the part of the recording we asked for
    first_sample = int(args.start * file_rate)
    if args.seconds > 0:
        last_sample = first_sample + int(args.seconds * file_rate)
    else:
        last_sample = len(emg_volts)
    emg_volts = emg_volts[first_sample:last_sample]
    if labels is not None:
        labels = labels[first_sample:last_sample]

    adc_codes, labels, num_clipped = stimulus.make_adc_codes(
        emg_volts, file_rate, labels, args.seed, add_noise=not args.no_mains)
    duration_s = len(adc_codes) / config.SAMPLE_RATE_HZ
    print(f"{args.dataset} {args.source}: {len(adc_codes)} samples per channel ({duration_s:.1f} s), "
          f"ADC codes from {adc_codes.min()} to {adc_codes.max()}, clipped samples: {num_clipped}")

    # filters
    integer_coeffs = filters_fixed.make_integer_coeffs()
    float_outputs = filters_float.run_float_filters(adc_codes, verify.rounded_coeffs_as_float())
    fixed_chain = filters_fixed.FixedPointFilterChain(integer_coeffs)
    fixed_outputs = fixed_chain.run(adc_codes)

    # features
    feature_input = features.filter_output_to_feature_input(fixed_outputs[-1])
    feature_rows = features.extract_features(feature_input)

    # checks
    design_ok = verify.check_filter_design()
    filters_ok = verify.check_fixed_against_float(adc_codes, fixed_outputs, float_outputs, fixed_chain.overflow_count)
    features_ok = verify.check_features(feature_input, feature_rows)
    print("ALL PASS" if design_ok and filters_ok and features_ok else "SOME CHECKS FAILED")

    # output files
    folder_name = f"{args.dataset}_{args.source}".replace("/", "_").replace(".", "")
    output_folder = config.OUTPUT_FOLDER / folder_name
    vectors.write_test_files(output_folder, adc_codes, integer_coeffs, fixed_outputs, feature_rows)
    save_report_plot(output_folder / "report.png", adc_codes, fixed_outputs, float_outputs, feature_rows)
    print(f"outputs written to {output_folder}")


def save_report_plot(file_path, adc_codes, fixed_outputs, float_outputs, feature_rows):
    time_s = np.arange(len(adc_codes)) / config.SAMPLE_RATE_HZ
    fixed_final = fixed_outputs[-1] / (2 ** config.GUARD_BITS)     # back to ADC steps
    float_final = float_outputs[-1]
    figure, axes = plt.subplots(4, 1, figsize=(11, 12))

    # 1. input and output over time
    axes[0].plot(time_s, adc_codes[:, 0], linewidth=0.4, label="ADC codes (input)")
    axes[0].plot(time_s, fixed_final[:, 0], linewidth=0.4, label="fixed-point output")
    axes[0].set(title="Channel 0: input and filtered output", xlabel="s", ylabel="ADC LSB")
    axes[0].legend(loc="upper right")

    # 2. spectrum of input and output
    for name, values in [("input", adc_codes[:, 0]), ("output", fixed_final[:, 0])]:
        frequencies, power = signal.welch(values - values.mean(), fs=config.SAMPLE_RATE_HZ,
                                          nperseg=2 * config.SAMPLE_RATE_HZ)
        axes[1].semilogy(frequencies, power, linewidth=0.7, label=name)
    axes[1].set(title="Channel 0 spectrum", xlabel="Hz", ylabel="LSB^2/Hz")
    axes[1].legend()

    # 3. error of the fixed-point version
    axes[2].plot(time_s, fixed_final[:, 0] - float_final[:, 0], linewidth=0.4)
    axes[2].set(title="Fixed minus float (channel 0)", xlabel="s", ylabel="ADC LSB")

    # 4. RMS feature for every channel
    for channel in range(config.NUM_CHANNELS):
        channel_rows = feature_rows[feature_rows[:, 1] == channel]
        window_end_time = channel_rows[:, 0] / config.SAMPLE_RATE_HZ
        rms_values = channel_rows[:, 7]
        axes[3].plot(window_end_time, rms_values, linewidth=0.8, label=f"ch{channel}")
    axes[3].set(title="RMS feature per window", xlabel="s", ylabel="ADC LSB")
    axes[3].legend()

    figure.tight_layout()
    figure.savefig(file_path, dpi=100)


if __name__ == "__main__":
    main()
