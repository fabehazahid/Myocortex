#!/usr/bin/env python3
"""
MyoCortex Phase-1, Experiment 1
Candidate A (window-feature ID-level HDC encoder) on the Ozdemir 4-ch sEMG dataset.

Pipeline:  signal -> window -> 1 feature per channel -> quantize to N_LEVELS levels
           -> bind (XOR) channel-ID with level-vector -> majority over channels
           -> hypervector -> Hamming distance to class prototypes -> predicted class

Splits (never mix windows of the same cycle across train/test):
  loso   : leave-subjects-out, grouped folds (whole subjects held out)
  within : per subject, train cycles 1-3, test cycles 4-5

DSP values come from the teammate's dsp_pipeline (read at run time). [GAP] = something his DSP
does not define. [UNKNOWN] = must be verified against the dataset's own files.

Usage:
  python phase1_candidate_A_ozdemir.py --data-dir <raw files> --dsp-dir <Myocortex/dsp_pipeline> --plot-check 0
  python phase1_candidate_A_ozdemir.py --data-dir <...> --dsp-dir <...> --quick
  python phase1_candidate_A_ozdemir.py --data-dir <...> --dsp-dir <...> --features rms   # full grid
"""
import argparse, glob, json, os, platform, re, sys, time
import numpy as np
import pandas as pd
from sklearn.discriminant_analysis import LinearDiscriminantAnalysis
from sklearn.metrics import (accuracy_score, balanced_accuracy_score,
                             confusion_matrix, f1_score)

# =====================================================================
# 1. CONFIG
# =====================================================================
# DSP numbers (sample rate, window, step, filters, bit widths) are NOT typed here:
# they are READ at run time from the teammate's dsp_pipeline/config.py
# (GitHub fabehazahid/Myocortex, commit 8e3369c) via load_dsp(). So this script
# can never disagree with his DSP.
FILE_RATE_HZ = 2000     # [VERIFIED-SOURCE] Ozdemir file rate (paper); DSP resamples it to 1500 Hz
N_CH = 4                # [VERIFIED-SOURCE]
N_CLASSES = 10          # [VERIFIED-SOURCE]

FEATURES = ["rms"]      # [RECOMMENDATION] choose from the DSP outputs: mav, rms, wl, zc
                        # 1 feature -> 4 fields (one per channel). 2 features -> 8 fields, etc.
FEATURE_ORDER = ["mav", "rms", "wl", "zc"]   # column order of the cached table
NORM_PERCENTILE = 99    # [GAP] DSP has NO normalization step. This scale is my software choice.
COMPRESS = "none"       # "none" or "sqrt" (applied after scaling to 0..1)
NORM_MODE = "global"    # "global": one scale per field from training windows
                        # "per_subject": each subject scaled by own data (loso: uses the test
                        # subject's UNLABELED data = a calibration assumption; report it so)

# Timeline of ONE cycle, in seconds. [UNKNOWN] my reading of the Ozdemir paper text
# (104 s cycle, 6 s gestures, 4 s rests). Verify with --plot-check first.
# Labels: 0 rest/neutral, 1 extension, 2 flexion, 3 ulnar dev., 4 radial dev.,
#         5 grip, 6 abduction, 7 adduction, 8 supination, 9 pronation.
CYCLE_SCHEDULE = [(0, 4, 10), (1, 14, 20), (2, 24, 30), (3, 34, 40), (4, 44, 50),
                  (5, 54, 60), (6, 64, 70), (7, 74, 80), (8, 84, 90), (9, 94, 100)]
CYCLE_START_S = [0, 134, 268, 402, 536]   # 104 s cycle + 30 s rest
TRIM_S = 0.5            # [RECOMMENDATION] drop 0.5 s at both ends of each 6 s gesture
                        # The 4 s rests and 4 s "hold" parts are NOT used (ambiguous labels).

HV_LENS = [1024, 2048, 4096, 10000]
N_LEVELS_LIST = [8, 16, 32]
BLOCK = 4096            # rows processed at once (memory control)

# filled by load_dsp()
DSP = {}
FS_HZ = WIN_LEN = STEP = None


def load_dsp(dsp_dir):
    """Import the teammate's modules and read his parameters."""
    global DSP, FS_HZ, WIN_LEN, STEP
    sys.path.insert(0, os.path.abspath(dsp_dir))
    import config as dc, stimulus, filters_float          # his files
    DSP = dict(cfg=dc, stimulus=stimulus, filters_float=filters_float)
    FS_HZ, WIN_LEN, STEP = dc.SAMPLE_RATE_HZ, dc.WINDOW_LENGTH, dc.WINDOW_STEP
    assert dc.NUM_CHANNELS == N_CH
    print(f"DSP loaded: fs={FS_HZ} Hz, window={WIN_LEN} ({1000*WIN_LEN/FS_HZ:.0f} ms), "
          f"step={STEP} ({1000*STEP/FS_HZ:.0f} ms), filters HP{dc.HIGHPASS_CUTOFF_HZ:g}/"
          f"LP{dc.LOWPASS_CUTOFF_HZ:g}/notch{dc.NOTCH_FREQ_HZ:g}")


# =====================================================================
# 2. DATA LOADING + DSP FEATURES
# =====================================================================
def load_subject_mv(path):
    """Returns array (n_samples, N_CH) in millivolts. Accepts csv or mat, either orientation."""
    if path.lower().endswith(".mat"):
        from scipy.io import loadmat
        a = np.asarray(loadmat(path)["data"], dtype=np.float64)
    else:
        df = pd.read_csv(path, header=None).apply(pd.to_numeric, errors="coerce")
        a = df.dropna(how="all").to_numpy(dtype=np.float64)  # header row -> dropped
    if a.shape[0] == N_CH and a.shape[1] > N_CH:
        a = a.T
    if a.shape[1] != N_CH:
        raise ValueError(f"{path}: expected {N_CH} channels, got shape {a.shape}")
    return a


def list_subject_files(data_dir):
    """The DSP chain needs RAW data (it does its own filtering), so prefer *raw* files."""
    allf = glob.glob(os.path.join(data_dir, "*.csv")) + glob.glob(os.path.join(data_dir, "*.mat"))
    raw = [f for f in allf if "raw" in os.path.basename(f).lower()]
    files = raw if raw else allf
    if not files:
        sys.exit(f"No .csv/.mat files in {data_dir}")
    if not raw:
        print("  warning: no file name contains 'raw'. Make sure these are the RAW files, "
              "not the filtered ones (the DSP filters again).")
    def key(f):
        m = re.search(r"(\d+)", os.path.basename(f))
        return int(m.group(1)) if m else 10**9
    return sorted(files, key=key)


def _isqrt(v):
    r = np.floor(np.sqrt(v.astype(np.float64))).astype(np.int64)
    r -= (r * r > v)
    r += ((r + 1) * (r + 1) <= v)
    return r


def dsp_window_features(x):
    """
    Vectorized copy of teammate's features.extract_features().
    x: (N, N_CH) integers (filter output rounded to ADC steps, limited to FEATURE_INPUT_BITS).
    Returns ends (n_win,) and dict name -> (n_win, N_CH).  Same windows as his code:
    window k covers samples [end-WIN_LEN+1, end], end = WIN_LEN-1 + k*STEP.
    """
    dc = DSP["cfg"]
    ends = np.arange(WIN_LEN - 1, len(x), STEP)
    prev = np.vstack([np.zeros((1, x.shape[1]), np.int64), x[:-1]])
    d = x - prev
    zc_hit = ((prev * x) < 0) & (np.abs(d) >= dc.ZERO_CROSSING_THRESHOLD)

    def wsum(a):
        cs = np.vstack([np.zeros((1, a.shape[1]), np.int64), np.cumsum(a, axis=0)])
        return cs[ends + 1] - cs[ends + 1 - WIN_LEN]
    sum_abs, sum_sq = wsum(np.abs(x)), wsum(x * x)
    return ends, dict(mav=sum_abs >> dc.WINDOW_SHIFT,
                      rms=_isqrt(sum_sq >> dc.WINDOW_SHIFT),
                      wl=wsum(np.abs(d)), zc=wsum(zc_hit.astype(np.int64)))


def subject_to_features(sig_mv, noise_seed, add_mains=True):
    """Ozdemir raw (mV, 2 kHz) -> DSP stimulus (1500 Hz, mains, sensor, ADS1015) ->
    float filter chain (HP20, LP450, notch50) -> integer features.
    Returns ends, feats(dict), n_clipped_samples."""
    dc, st, ff = DSP["cfg"], DSP["stimulus"], DSP["filters_float"]
    adc, _, n_clip = st.make_adc_codes(sig_mv / 1000.0, FILE_RATE_HZ, None,
                                       random_seed=noise_seed, add_noise=add_mains)
    out = ff.run_float_filters(adc)[-1]              # causal, in ADC steps, whole recording
    lim = 2 ** (dc.FEATURE_INPUT_BITS - 1)
    x = np.clip(np.rint(out), -lim, lim - 1).astype(np.int64)
    ends, feats = dsp_window_features(x)
    return ends, feats, n_clip, adc.size


def label_windows(ends, n_samples):
    """A window is used only if it lies fully inside a trimmed gesture segment."""
    y = np.full(len(ends), -1); cyc = np.full(len(ends), -1)
    starts = ends - (WIN_LEN - 1)
    for c, c0 in enumerate(CYCLE_START_S):
        for label, s0, s1 in CYCLE_SCHEDULE:
            a = int(round((c0 + s0 + TRIM_S) * FS_HZ)); b = int(round((c0 + s1 - TRIM_S) * FS_HZ))
            if b > n_samples:
                continue
            m = (starts >= a) & (ends <= b - 1)
            y[m] = label; cyc[m] = c
    return y, cyc


def build_feature_table(data_dir, max_subjects, out_dir, add_mains):
    cache = os.path.join(out_dir, f"dsp_features_fs{FS_HZ}_w{WIN_LEN}_s{STEP}_t{TRIM_S}"
                                  f"_mains{int(add_mains)}_n{max_subjects or 'all'}.npz")
    if os.path.exists(cache):
        z = np.load(cache)
        return z["F"], z["y"], z["subj"], z["cyc"]
    files = list_subject_files(data_dir)[: max_subjects or None]
    Fs, ys, ss, cs_ = [], [], [], []
    for i, f in enumerate(files):
        sig = load_subject_mv(f)
        if len(sig) != 1_280_000:
            print(f"  warning: {os.path.basename(f)} has {len(sig)} samples (paper says 1,280,000)")
        ends, feats, n_clip, n_tot = subject_to_features(sig, noise_seed=i, add_mains=add_mains)
        y, cyc = label_windows(ends, int(ends[-1]) + 1)
        keep = y >= 0
        # table layout: (n_win, n_features_in_FEATURE_ORDER, N_CH)
        F = np.stack([feats[n][keep] for n in FEATURE_ORDER], axis=1).astype(np.float64)
        Fs.append(F); ys.append(y[keep]); cs_.append(cyc[keep]); ss.append(np.full(keep.sum(), i))
        frac = n_clip / n_tot
        print(f"  subject {i:2d} ({os.path.basename(f)}): {keep.sum()} windows, "
              f"sensor-clipped samples {100*frac:.2f}%" + ("   <-- HIGH" if frac > 0.001 else ""))
    F, y, subj, cyc = np.concatenate(Fs), np.concatenate(ys), np.concatenate(ss), np.concatenate(cs_)
    np.savez(cache, F=F, y=y, subj=subj, cyc=cyc)
    return F, y, subj, cyc


def select_fields(F_all):
    """(n, n_features, N_CH) -> (n, N_CH * len(FEATURES)), channel-major."""
    idx = [FEATURE_ORDER.index(f) for f in FEATURES]
    return np.stack([F_all[:, i, c] for c in range(N_CH) for i in idx], axis=1)


def plot_check(data_dir, idx, out_dir):
    """Timeline sanity check. Top: whole recording. Bottom: zoom on cycle 1.
    The signal is high-pass filtered at 20 Hz first (like the DSP does), otherwise slow
    baseline drift hides the muscle bursts. One line per channel."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from scipy.signal import butter, sosfiltfilt
    sig = load_subject_mv(list_subject_files(data_dir)[idx])
    hp = sosfiltfilt(butter(2, 20, btype="highpass", fs=FILE_RATE_HZ, output="sos"), sig, axis=0)
    k = int(0.25 * FILE_RATE_HZ)                      # 0.25 s smoothing
    env = np.sqrt(np.apply_along_axis(lambda v: np.convolve(v ** 2, np.ones(k) / k, "same"), 0, hp))
    t = np.arange(len(sig)) / FILE_RATE_HZ
    fig, axes = plt.subplots(2, 1, figsize=(18, 8))
    for ax, (lo, hi) in zip(axes, [(0, len(sig) / FILE_RATE_HZ), (0, 110)]):
        m = (t >= lo) & (t <= hi)
        for c in range(N_CH):
            ax.plot(t[m][::10], env[m, c][::10], lw=0.7, label=f"ch{c}")
        for c0 in CYCLE_START_S:
            for label, s0, s1 in CYCLE_SCHEDULE:
                if lo <= c0 + s0 + TRIM_S <= hi:
                    ax.axvspan(c0 + s0 + TRIM_S, c0 + s1 - TRIM_S, alpha=0.2, color=f"C{label % 10}")
                    if hi <= 110:
                        ax.text(c0 + s0 + 3, ax.get_ylim()[1] * 0.92, str(label), ha="center")
        ax.set_ylabel("RMS after 20 Hz high-pass (mV)")
    axes[0].set_title("Whole recording. Boxes = windows the script will use. Bursts should line up with boxes.")
    axes[1].set_title("Zoom on cycle 1 (numbers = gesture label: 0 rest ... 9 pronation)")
    axes[1].set_xlabel("time (s)"); axes[0].legend(loc="upper right", ncol=4)
    path = os.path.join(out_dir, f"plot_check_subject{idx}.png")
    fig.savefig(path, dpi=110, bbox_inches="tight")
    print("saved", path)


# =====================================================================
# 3. NORMALIZE + QUANTIZE
# =====================================================================
def compute_x(F, subj, fit_mask, mode=NORM_MODE, compress=COMPRESS):
    """Scale features to about [0,1]. Scale is fitted ONLY on fit_mask windows."""
    if mode == "global":
        x = F / np.percentile(F[fit_mask], NORM_PERCENTILE, axis=0)
    else:  # per_subject
        x = np.empty_like(F)
        for u in np.unique(subj):
            m = subj == u
            fm = m & fit_mask if (m & fit_mask).any() else m
            x[m] = F[m] / np.percentile(F[fm], NORM_PERCENTILE, axis=0)
    x = np.clip(x, 0.0, 1.0)
    return np.sqrt(x) if compress == "sqrt" else x


def quantize(x, n_levels):
    return np.clip(np.floor(n_levels * x), 0, n_levels - 1).astype(np.int64)


# =====================================================================
# 4. CANDIDATE A: ID-level HDC (binary hypervectors, Hamming distance)
# =====================================================================
class HDCModel:
    """
    hv_len   = HV_LEN  (hypervector length, number of bits)
    n_ch     = N_CH    (channels)
    n_levels = N_LEVELS
    """
    def __init__(self, hv_len, n_ch, n_levels, n_classes, seed):
        rng = np.random.default_rng(seed)
        self.hv_len, self.n_ch, self.n_levels, self.n_classes = hv_len, n_ch, n_levels, n_classes
        # one random ID vector per channel ("which channel is this?")
        self.ID = rng.integers(0, 2, (n_ch, hv_len), dtype=np.uint8)
        # level vectors: neighbours are similar, first and last are ~orthogonal.
        # Start from a random vector, flip a growing prefix of a fixed random
        # permutation: level k has round(k * (hv_len/2)/(n_levels-1)) flipped bits.
        lv0 = rng.integers(0, 2, hv_len, dtype=np.uint8)
        perm = rng.permutation(hv_len)
        self.LV = np.empty((n_levels, hv_len), np.uint8)
        for k in range(n_levels):
            nflip = int(round(k * (hv_len / 2) / (n_levels - 1)))
            v = lv0.copy(); v[perm[:nflip]] ^= 1
            self.LV[k] = v
        # lookup table: T[c][q] = ID_c XOR LV[q]   (the "bound" vector)
        self.T = self.ID[:, None, :] ^ self.LV[None, :, :]
        # majority over an EVEN number of channels can tie -> add one fixed random vote
        self.tie_vote = rng.integers(0, 2, hv_len, dtype=np.uint8) if n_ch % 2 == 0 else None
        self.voters = n_ch + (1 if self.tie_vote is not None else 0)
        self.proto_tie = rng.integers(0, 2, hv_len, dtype=np.uint8)  # for prototype ties

    def encode_bits(self, q):
        """q: (n, n_ch) level indices -> (n, hv_len) uint8 bits."""
        votes = np.zeros((len(q), self.hv_len), np.uint8)
        for c in range(self.n_ch):
            votes += self.T[c][q[:, c]]
        if self.tie_vote is not None:
            votes += self.tie_vote
        return (votes * 2 > self.voters).astype(np.uint8)

    @staticmethod
    def _unique(q):
        # many windows share the same level pattern -> encode each pattern only once
        uq, inv = np.unique(q, axis=0, return_inverse=True)
        return uq, inv.reshape(-1)

    def fit_counters(self, q, y):
        """Integer counters per class (kept so online updates are possible later)."""
        uq, inv = self._unique(q)
        W = np.zeros((self.n_classes, len(uq)), np.float32)
        np.add.at(W, (y, inv), 1.0)
        counts = np.zeros((self.n_classes, self.hv_len), np.int64)
        for s in range(0, len(uq), BLOCK):
            Hu = self.encode_bits(uq[s:s + BLOCK]).astype(np.float32)
            counts += np.rint(W[:, s:s + BLOCK] @ Hu).astype(np.int64)
        return counts, np.bincount(y, minlength=self.n_classes)

    def prototypes(self, counts, nk):
        """Majority of the class's window vectors (ties -> fixed random bit)."""
        twice = counts * 2
        P = (twice > nk[:, None]).astype(np.uint8)
        tie = twice == nk[:, None]
        rows, cols = np.nonzero(tie)
        P[rows, cols] = self.proto_tie[cols]
        return P, nk > 0

    def predict(self, q, P, valid):
        """argmin Hamming(H, P_k)."""
        uq, inv = self._unique(q)
        Pf = P.astype(np.float32); psum = Pf.sum(1)
        out = np.empty(len(uq), np.int64)
        for s in range(0, len(uq), BLOCK):
            Hu = self.encode_bits(uq[s:s + BLOCK]).astype(np.float32)
            ham = Hu.sum(1)[:, None] + psum[None, :] - 2.0 * (Hu @ Pf.T)
            ham[:, ~valid] = np.inf
            out[s:s + BLOCK] = ham.argmin(1)
        return out[inv]


def time_single_window(model, P, valid, q, n=200):
    """Median laptop/PC time for ONE window (encode + Hamming + argmin), in ms.
    [ESTIMATE] host-PC number only. It is NOT the ARM number and NOT the FPGA number."""
    ts = []
    for i in range(min(n, len(q))):
        t0 = time.perf_counter()
        h = model.encode_bits(q[i:i + 1])[0]
        d = (h != P).sum(1).astype(np.float64)
        d[~valid] = np.inf
        d.argmin()
        ts.append(time.perf_counter() - t0)
    return float(np.median(ts) * 1e3)


# =====================================================================
# 5. SPLITS
# =====================================================================
def tasks_loso(subj, seed, n_folds=5):
    rng = np.random.default_rng(seed)
    subs = rng.permutation(np.unique(subj))
    allm = np.ones(len(subj), bool)
    for fold in np.array_split(subs, n_folds):
        te = np.isin(subj, fold)
        yield allm, ~te, te


def tasks_within(subj, cyc):
    for s in np.unique(subj):
        scope = subj == s
        yield scope, scope & (cyc <= 2), scope & (cyc >= 3)   # cycles 1-3 train, 4-5 test


def run_split(split, F, y, subj, cyc, hv_len, n_levels, seed, do_lda, norm_mode):
    n = len(y)
    pred_h = np.full(n, -1); pred_l = np.full(n, -1)
    model = HDCModel(hv_len, F.shape[1], n_levels, N_CLASSES, seed)   # one ID per field
    tasks = tasks_loso(subj, seed) if split == "loso" else tasks_within(subj, cyc)
    t_ms = None
    for scope, tr, te in tasks:
        idx = np.where(scope)[0]
        # loso + per_subject: scale from each subject's own unlabeled data (calibration assumption)
        fit = np.ones(len(idx), bool) if (split == "loso" and norm_mode == "per_subject") else tr[idx]
        x = compute_x(F[idx], subj[idx], fit, norm_mode)
        q = quantize(x, n_levels)
        tr_l, te_l = tr[idx], te[idx]
        counts, nk = model.fit_counters(q[tr_l], y[idx][tr_l])
        P, valid = model.prototypes(counts, nk)
        pred_h[idx[te_l]] = model.predict(q[te_l], P, valid)
        if t_ms is None:
            t_ms = time_single_window(model, P, valid, q[te_l])
        if do_lda:
            lda = LinearDiscriminantAnalysis().fit(x[tr_l], y[idx][tr_l])
            pred_l[idx[te_l]] = lda.predict(x[te_l])
    return pred_h, pred_l, t_ms


def score(y, p, subj, label_count=N_CLASSES):
    m = p >= 0
    y, p, s = y[m], p[m], subj[m]
    labels = list(range(label_count))
    per_sub = [accuracy_score(y[s == u], p[s == u]) for u in np.unique(s)]
    return dict(accuracy=accuracy_score(y, p),
                macro_f1=f1_score(y, p, average="macro", labels=labels, zero_division=0),
                balanced_acc=balanced_accuracy_score(y, p),
                acc_per_subject_mean=float(np.mean(per_sub)),
                acc_per_subject_std=float(np.std(per_sub)),
                n_test_windows=int(m.sum())), confusion_matrix(y, p, labels=labels)


# =====================================================================
# 6. MAIN
# =====================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--dsp-dir", required=True, help="path to teammate's dsp_pipeline folder")
    ap.add_argument("--features", default="rms", help="comma list from mav,rms,wl,zc")
    ap.add_argument("--no-mains", action="store_true", help="skip the DSP's synthetic 50 Hz noise")
    ap.add_argument("--out-dir", default="phase1_out")
    ap.add_argument("--master-seed", type=int, default=12345)
    ap.add_argument("--n-seeds", type=int, default=5)
    ap.add_argument("--max-subjects", type=int, default=None)
    ap.add_argument("--norm-mode", default=NORM_MODE, choices=["global", "per_subject"])
    ap.add_argument("--quick", action="store_true", help="HV_LEN 2048, N_LEVELS 16, 1 seed, 8 subjects")
    ap.add_argument("--plot-check", type=int, default=None, help="subject index: draw segment boxes and exit")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    global FEATURES
    FEATURES = a.features.split(",")
    load_dsp(a.dsp_dir)
    if a.plot_check is not None:
        plot_check(a.data_dir, a.plot_check, a.out_dir); return

    hv_lens, levels, n_seeds, max_sub = HV_LENS, N_LEVELS_LIST, a.n_seeds, a.max_subjects
    if a.quick:
        hv_lens, levels, n_seeds, max_sub = [2048], [16], 1, 8
    seeds = [int(s) for s in np.random.SeedSequence(a.master_seed).generate_state(n_seeds)]

    print("Loading + windowing ...")
    F_all, y, subj, cyc = build_feature_table(a.data_dir, max_sub, a.out_dir, not a.no_mains)
    F = select_fields(F_all)
    print("Selected feature shape:", F.shape)
    print("Features:", FEATURES)
    print(f"fields used: {N_CH} channels x {FEATURES} = {F.shape[1]}")
    print(f"{len(y)} windows, {len(np.unique(subj))} subjects, class counts {np.bincount(y)}")

    log = dict(master_seed=a.master_seed, seeds=seeds, args=vars(a), FS_HZ=FS_HZ, WIN_LEN=WIN_LEN, STEP=STEP,
               FEATURES=FEATURES, NORM_PERCENTILE=NORM_PERCENTILE, COMPRESS=COMPRESS,
               TRIM_S=TRIM_S, python=sys.version, numpy=np.__version__, platform=platform.platform(),
               timestamp=time.strftime("%Y-%m-%d %H:%M:%S"))
    json.dump(log, open(os.path.join(a.out_dir, "run_log.json"), "w"), indent=2)

    rows, cms = [], {}
    first = True
    for hv_len in hv_lens:
        for n_levels in levels:
            for seed in seeds:
                for split in ("loso", "within"):
                    do_lda = first  # LDA does not depend on hv_len/n_levels: run once per split+seed
                    t0 = time.time()
                    ph, pl, t_ms = run_split(split, F, y, subj, cyc, hv_len, n_levels, seed, do_lda, a.norm_mode)
                    for method, p in (("A_hdc", ph), ("LDA", pl)):
                        if method == "LDA" and not do_lda:
                            continue
                        r, cm = score(y, p, subj)
                        r.update(split=split, method=method, hv_len=hv_len if method != "LDA" else np.nan,
                                 n_levels=n_levels if method != "LDA" else np.nan, seed=seed,
                                 host_ms_per_window=t_ms if method == "A_hdc" else np.nan,
                                 norm_mode=a.norm_mode)
                        rows.append(r)
                        cms[f"{split}|{method}|{hv_len}|{n_levels}|{seed}"] = cm
                    print(f"[{split:6s}] HV_LEN={hv_len:5d} N_LEVELS={n_levels:2d} seed={seed} "
                          f"acc={rows[-1 if not do_lda else -2]['accuracy']:.3f}  ({time.time()-t0:.0f}s)")
                first = False if seed == seeds[-1] and split == "within" else first
        # note: LDA rows are produced only during the very first (hv_len, n_levels) pass
    df = pd.DataFrame(rows)
    df.to_csv(os.path.join(a.out_dir, "results_raw.csv"), index=False)
    np.savez_compressed(os.path.join(a.out_dir, "confusion_matrices.npz"), **cms)
    summ = (df.groupby(["split", "method", "hv_len", "n_levels"], dropna=False)
              [["accuracy", "macro_f1", "balanced_acc", "acc_per_subject_std", "host_ms_per_window"]]
              .agg(["mean", "std"]))
    summ.to_csv(os.path.join(a.out_dir, "results_summary.csv"))
    print("\n=== SUMMARY (mean/std over seeds) ===")
    print(summ.round(4).to_string())
    print(f"\nSaved to {a.out_dir}/ (results_raw.csv, results_summary.csv, confusion_matrices.npz, run_log.json)")


if __name__ == "__main__":
    main()