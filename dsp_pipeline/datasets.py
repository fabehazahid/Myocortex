# Functions to load EMG recordings from the three datasets.
# Each function returns:
#   emg_volts   - array of shape (samples, channels), in volts at the electrode
#   file_rate   - sample rate of the recording in Hz
#   labels      - gesture number for each sample, or None if the dataset has no labels

import numpy as np
from scipy.io import loadmat

import config


def load_izmir(participant_number, channels=(0, 1, 2, 3)):
    # Izmir raw files are saved in millivolts at 2000 Hz.
    # Note: channel 4 (index 3) is already filtered in these files.
    izmir_folder = config.DATASET_FOLDER / "izmir"
    file_path = list(izmir_folder.glob(f"{participant_number}_raw*.mat"))[0]
    mat_file = loadmat(file_path)

    file_rate = float(mat_file["fs"][0][0])
    emg_millivolts = mat_file["data"][:, list(channels)]
    emg_volts = emg_millivolts.astype(float) / 1000.0
    return emg_volts, file_rate, None


def load_ninapro_db2(subject_number, exercise_number, channels=(0, 2, 4, 6)):
    # NinaPro DB2 files are already in volts at 2000 Hz.
    # "restimulus" holds the gesture number of every sample (0 means rest).
    # OPEN: which 4 of the 12 electrodes we use is not decided yet.
    file_path = (config.DATASET_FOLDER / "ninapro" / f"DB2_s{subject_number}"
                 / f"S{subject_number}_E{exercise_number}_A1.mat")
    mat_file = loadmat(file_path, variable_names=["emg", "restimulus"])

    emg_volts = mat_file["emg"][:, list(channels)].astype(float)
    labels = mat_file["restimulus"].flatten().astype(int)

    # the label array can be one sample shorter than the emg array
    length = min(len(emg_volts), len(labels))
    return emg_volts[:length], 2000.0, labels[:length]


def load_grabmyo(record_path, channels=(0, 1, 2, 3)):
    # GRABMyo uses the WFDB format: a .hea text header and a .dat file of 16-bit numbers.
    # Note: this data already has a 60 Hz notch and a 10-450 Hz filter applied.
    header_lines = open(f"{record_path}.hea").read().splitlines()
    first_line = header_lines[0].split()
    num_signals = int(first_line[1])
    file_rate = float(first_line[2])
    num_samples = int(first_line[3])

    # each signal line looks like: "file.dat 16 109223.8(4352)/mV ..."
    gains = []
    baselines = []
    for line in header_lines[1:1 + num_signals]:
        gain_text = line.split()[2].split("/")[0]          # "109223.8(4352)"
        gain_part, baseline_part = gain_text.rstrip(")").split("(")
        gains.append(float(gain_part))
        baselines.append(float(baseline_part))

    raw_numbers = np.fromfile(f"{record_path}.dat", dtype="<i2")
    raw_numbers = raw_numbers.reshape(num_samples, num_signals)
    emg_millivolts = (raw_numbers - np.array(baselines)) / np.array(gains)
    emg_volts = emg_millivolts / 1000.0
    return emg_volts[:, list(channels)], file_rate, None
