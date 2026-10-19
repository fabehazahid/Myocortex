# Writes the test files that the RTL testbench (MC-18) reads.
# Samples are written one per line in the order ch0, ch1, ch2, ch3 for each tick.

import json

import config
import features


def to_hex_lines(values, num_bits):
    # writes each number as two's complement hex, e.g. -1 in 12 bits -> "fff"
    num_hex_digits = (num_bits + 3) // 4
    mask = (1 << num_bits) - 1
    lines = []
    for value in values.flatten():
        lines.append(f"{int(value) & mask:0{num_hex_digits}x}\n")
    return "".join(lines)


def write_test_files(output_folder, adc_codes, integer_coeffs, stage_outputs, feature_rows):
    output_folder.mkdir(parents=True, exist_ok=True)

    (output_folder / "adc_in.hex").write_text(to_hex_lines(adc_codes, config.ADC_BITS))
    (output_folder / "coeffs.hex").write_text(to_hex_lines(integer_coeffs, config.COEFF_TOTAL_BITS))

    # one file per filter stage, so the RTL can be debugged stage by stage
    file_names = {"highpass": "hp_out.hex", "lowpass": "lp_out.hex", "notch": "notch_out.hex"}
    for stage_name, stage_output in zip(config.STAGE_ORDER, stage_outputs):
        (output_folder / file_names[stage_name]).write_text(to_hex_lines(stage_output, config.DATA_TOTAL_BITS))

    with open(output_folder / "features.csv", "w") as csv_file:
        csv_file.write(",".join(features.COLUMN_NAMES) + "\n")
        for row in feature_rows:
            csv_file.write(",".join(str(value) for value in row) + "\n")

    # save every setting used, so the testbench knows the bit widths
    settings = {}
    for name in dir(config):
        value = getattr(config, name)
        if name.isupper() and isinstance(value, (int, float, str, list)):
            settings[name] = value
    settings["MAINS_NOISE_AMPLITUDES_V"] = {str(f): a for f, a in config.MAINS_NOISE_AMPLITUDES_V.items()}
    settings["INTEGER_COEFFS"] = integer_coeffs.tolist()
    settings["FEATURE_BIT_WIDTHS"] = features.worst_case_bit_widths()
    settings["NUM_SAMPLES"] = len(adc_codes)
    (output_folder / "params.json").write_text(json.dumps(settings, indent=2))
