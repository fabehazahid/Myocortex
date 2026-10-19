# All settings for the DSP pipeline are kept in this one file.
# "OPEN" means the team has not decided this value yet.

from pathlib import Path

# Folders
PROJECT_FOLDER = Path(__file__).resolve().parent
DATASET_FOLDER = PROJECT_FOLDER.parent / "datasets"
OUTPUT_FOLDER = PROJECT_FOLDER / "out"

# Sampling
SAMPLE_RATE_HZ = 1500        # samples per second for each channel
NUM_CHANNELS = 4             # one ADS1015 per channel

# Sensor (OYMotion Gravity analog EMG)
SENSOR_GAIN = 1000.0         # +/-1.5 mV in -> +/-1.5 V out (worked out from the datasheet)
SENSOR_MAX_OUTPUT_V = 1.5    # output swings 1.5 V above and below its 1.5 V centre
REFERENCE_ERROR_V = 0.0      # set non-zero to test a mismatch in the 1.5 V reference

# ADC (ADS1015, differential input against 1.5 V)
ADC_BITS = 12
ADC_FULL_SCALE_V = 2.048     # input range is -2.048 V to +2.048 V
ADC_STEP_V = 2 * ADC_FULL_SCALE_V / (2 ** ADC_BITS)   # 1 mV per step

# Filters (each one is 2nd order)
STAGE_ORDER = ["highpass", "lowpass", "notch"]
HIGHPASS_CUTOFF_HZ = 20.0
LOWPASS_CUTOFF_HZ = 450.0
NOTCH_FREQ_HZ = 50.0
FILTER_TYPE = "butter"       # OPEN: Butterworth for high-pass and low-pass
NOTCH_QUALITY_FACTOR = 30.0  # OPEN: notch width = 50 / 30 = 1.7 Hz

# Fixed-point number sizes
COEFF_TOTAL_BITS = 18        # fits the 18-bit input of the FPGA multiplier
COEFF_FRACTION_BITS = 16     # coefficients are stored as round(value * 2^16)
GUARD_BITS = 8               # extra bits below one ADC step to keep rounding error small
DATA_TOTAL_BITS = 24         # size of every value inside the filters (max 25 for one multiplier)

# Windows and features
WINDOW_LENGTH = 256          # samples per window (about 171 ms)
WINDOW_STEP = 64             # a new window every 64 samples (about 43 ms)
WINDOW_SHIFT = 8             # dividing by 256 is the same as shifting right by 8
FEATURE_INPUT_BITS = 13      # filter output is rounded to whole ADC steps and limited to this size
ZERO_CROSSING_THRESHOLD = 10 # OPEN: a crossing only counts if the jump is at least 10 steps

# Pass / fail limits for the checks
MAX_ALLOWED_ERROR_LSB = 1.0  # fixed-point error must stay below one ADC step
MIN_NOTCH_DEPTH_DB = 40.0    # OPEN: how much the notch must cut 50 Hz

# Fake power-line noise added to the dataset signals (volts at the electrode)
# OPEN: these are test values, not measured ones
MAINS_NOISE_AMPLITUDES_V = {50: 20e-6, 100: 5e-6, 150: 10e-6, 200: 3e-6, 250: 5e-6}
