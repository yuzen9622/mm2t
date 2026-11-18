"""Match-threshold calibration for a speaker-embedding model, same procedure for every model.

  threshold_calibration.py MODEL DATA_DIR [--variant all|matched]

MODEL is `wespeaker` or `campplus`; the vectors come from out/embeddings (see EMB below).

autoName / suggest  ("voiceprint vs a new meeting's cluster")
  Nemotron-3 clusters (out/nemotron3-offline/<condition>) are mapped to reference speakers by the
  DER optimal mapping. Each trial: the first half of the session is the enrollment (--variant all:
  mean of every clean piece of the cluster; matched: random pieces totalling at least L s), the
  second half is matched with the mean of random clean pieces totalling at least L s. 20 draws x 5
  seeds per L. Same = a cluster against its own later vector; different = every other mapped
  cluster of any session (24 x 23 pairs per draw: 480 same / 11,040 different trials per 20 draws).
user  ("enrollment of about 10 s against the mean of 1-2.5 s turns from another part of the meeting")
  Enrollment: reference 2-8 s clean pieces from the first half of a session, taken in a random
  order until they total at least 10 s. Test: fixed-length reference pieces (threshold_spans.py)
  from the second half, single or averaged over K random pieces. Different = every other speaker
  of all 25 (both far-field and near-mix conditions).
"""

import argparse
import itertools
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from embeddings import clean_pieces, read_rttm, unit, voiceprints, load  # noqa: E402

OUT = Path(__file__).resolve().parents[1] / "out"
EMB = OUT / "embeddings"
FILES = {
    "wespeaker": {
        "ref": EMB / "embeddings.json",
        "hyp": lambda c: EMB / f"hypemb_nemotron3-offline_{c}.json",
        "short": EMB / "shortemb_wespeaker.json",
    },
    "campplus": {
        "ref": EMB / "embeddings_campplus.json",
        "hyp": lambda c: EMB / f"hypemb_campplus_nemotron3-offline_{c}.json",
        "short": EMB / "shortemb_campplus.json",
    },
}
LENGTHS = (2, 4, 6, 8, 10, 12, 15, 20, 30, 40, 60)


def hyp_clusters(model, condition, data):
    """{(session, speaker): [(start, end, vec)]} for the Nemotron-3 clusters mapped to speakers."""
    from pyannote.metrics.diarization import DiarizationErrorRate
    from score import load_rttm

    hyp_dir = OUT / "nemotron3-offline" / condition
    result = {}
    for item in json.loads(FILES[model]["hyp"](condition).read_text()):
        stem = Path(item["wav"]).stem
        session = stem.split("__")[0]
        owner = {p: k for k, ps in clean_pieces(read_rttm(hyp_dir / f"{stem}.rttm")).items() for p in ps}
        mapping = DiarizationErrorRate().optimal_mapping(
            load_rttm(data / "ref" / f"{session}.rttm"), load_rttm(hyp_dir / f"{stem}.rttm"))
        by_cluster = defaultdict(list)
        for span, vec in zip(item["spans"], item["embeddings"]):
            by_cluster[owner[(span[0], span[1])]].append((span[0], span[1], unit(vec)))
        for cluster, pieces in by_cluster.items():
            speaker = mapping.get(cluster)
            if speaker is not None:
                result[(session, f"{cluster}->{speaker}")] = sorted(pieces)
    return result


def accumulate(pieces, seconds, rng=None):
    """Mean of pieces (time order, or random order with rng) until they total at least `seconds`."""
    order = range(len(pieces)) if rng is None else rng.permutation(len(pieces))
    chosen, total = [], 0.0
    for i in order:
        chosen.append(pieces[i][2])
        total += pieces[i][1] - pieces[i][0]
        if total >= seconds:
            return unit(np.mean(chosen, axis=0))
    return None


def length_sweep(model, condition, data, enroll_mode, seeds=5, draws=20):
    """Random-draw trials. Each draw: every cluster's second-half vector from random pieces totalling
    at least L s, against its first-half enrollment (`all` = mean of every first-half piece;
    `matched` = random pieces totalling at least L s too)."""
    clusters = hyp_clusters(model, condition, data)
    end = defaultdict(float)
    for (session, _), pieces in clusters.items():
        end[session] = max(end[session], max(p[1] for p in pieces))
    first = {k: [p for p in v if p[0] < end[k[0]] / 2] for k, v in clusters.items()}
    second = {k: [p for p in v if p[0] >= end[k[0]] / 2] for k, v in clusters.items()}
    rows = {}
    for length in LENGTHS:
        same, diff = [], []
        for seed in range(seeds):
            rng = np.random.default_rng(seed)
            for _ in range(draws):
                if enroll_mode == "all":
                    enroll = {k: unit(np.mean([p[2] for p in v], axis=0)) for k, v in first.items() if v}
                else:
                    enroll = {k: accumulate(v, length, rng) for k, v in first.items()}
                tests = {k: accumulate(v, length, rng) for k, v in second.items()}
                for a, e in enroll.items():
                    if e is None:
                        continue
                    for b, t in tests.items():
                        if t is not None:
                            (same if a == b else diff).append(float(e @ t))
        if same:
            rows[length] = (np.array(same), np.array(diff))
    return rows


def user_trials(model, data, rng, conditions=("far", "nearmix", "nearmix_opus")):
    table = load(data, FILES[model]["ref"])
    short = json.loads(FILES[model]["short"].read_text())
    out = {}
    for condition in conditions:
        enroll = {}
        for (c, session), speakers in table.items():
            if c != condition:
                continue
            end = max(p[1] for ps in speakers.values() for p in ps)
            for speaker, pieces in speakers.items():
                first = [p for p in pieces if p[0] < end / 2]
                if not first:
                    continue
                draws = []
                for _ in range(20):
                    order = rng.permutation(len(first))
                    chosen, total = [], 0.0
                    for i in order:
                        chosen.append(first[i][2])
                        total += first[i][1] - first[i][0]
                        if total >= 10.0:
                            draws.append((unit(np.mean(chosen, axis=0)), total))
                            break
                if draws:
                    enroll[(session, speaker)] = draws
        # test pieces by (session, speaker, length) in the second half
        pieces = defaultdict(list)
        ends = {session: max(p[1] for ps in speakers.values() for p in ps)
                for (c, session), speakers in table.items() if c == condition}
        owner = {}
        for ref in sorted((data / "ref").glob("*.rttm")):
            by_speaker = read_rttm(ref)
            for speaker, intervals in by_speaker.items():
                owner.setdefault(ref.stem, []).append((speaker, sorted(intervals)))
        for item in short:
            session, c = Path(item["wav"]).stem.split("__")
            if c != condition:
                continue
            for span, vec in zip(item["spans"], item["embeddings"]):
                if span[0] < ends[session] / 2:
                    continue
                mid = (span[0] + span[1]) / 2
                speaker = next(s for s, iv in owner[session] if any(a <= mid <= b for a, b in iv))
                length = round(span[1] - span[0], 1)
                pieces[(session, speaker, length)].append(unit(vec))
        out[condition] = (enroll, pieces)
    return out


def user_scores(enroll, pieces, rng, lengths, mean_pieces, trials_per_speaker=300):
    """Scores for one test recipe: same / different lists."""
    pools = defaultdict(list)
    for (session, speaker, length), vecs in pieces.items():
        if length in lengths:
            pools[(session, speaker)].extend(vecs)
    same, diff = [], []
    for test_key, pool in pools.items():
        if len(pool) < mean_pieces:
            continue
        for _ in range(trials_per_speaker):
            idx = rng.choice(len(pool), size=mean_pieces, replace=False)
            t = unit(np.mean([pool[i] for i in idx], axis=0))
            for enroll_key, draws in enroll.items():
                e = draws[rng.integers(len(draws))][0]
                (same if enroll_key == test_key else diff).append(float(e @ t))
    return np.array(same), np.array(diff)


def pct(x, q):
    return float(np.percentile(x, q))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=FILES)
    parser.add_argument("data", type=Path)
    parser.add_argument("--variant", default="all", choices=("all", "matched"))
    parser.add_argument("--skip-user", action="store_true")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    report = {"sweep": {}, "user": {}}

    for condition in ("nearmix_opus", "far"):
        rows = length_sweep(args.model, condition, args.data, args.variant)
        print(f"\n[{args.model}] length sweep, {condition}, enroll={args.variant}")
        print("  L(s)  n_same n_diff | same min  p5   p50 | diff p50   p99   max")
        report["sweep"][condition] = {}
        for length, (same, diff) in rows.items():
            print(f"  {length:4}  {len(same):5} {len(diff):6} | {same.min():.3f} {pct(same,5):.3f} {np.median(same):.3f}"
                  f" | {np.median(diff):.3f} {pct(diff,99):.3f} {diff.max():.3f}")
            report["sweep"][condition][length] = {
                "n_same": len(same), "n_diff": len(diff), "same_min": float(same.min()),
                "same_p5": pct(same, 5), "diff_max": float(diff.max()), "diff_p99": pct(diff, 99)}
        ge8 = [(s, d) for length, (s, d) in rows.items() if length >= 8]
        same8 = np.concatenate([s for s, _ in ge8])
        diff8 = np.concatenate([d for _, d in ge8])
        print(f"  >=8 s all lengths: same n {len(same8)} min {same8.min():.3f} | diff n {len(diff8)} max {diff8.max():.3f}")
        grid = (0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80)
        print("  >=8 s pooled   t:      " + " ".join(f"{t:6.2f}" for t in grid))
        print("    same below t (miss)  " + " ".join(f"{(same8 < t).mean()*100:5.1f}%" for t in grid))
        print("    diff at/above t      " + " ".join(f"{(diff8 >= t).mean()*100:5.2f}%" for t in grid))
        report["sweep"][condition][">=8"] = {
            "same_below": {str(t): float((same8 < t).mean()) for t in grid},
            "diff_above": {str(t): float((diff8 >= t).mean()) for t in grid},
            "n_same": len(same8), "same_min": float(same8.min()), "n_diff": len(diff8), "diff_max": float(diff8.max())}

    if args.skip_user:
        return
    rng = np.random.default_rng(0)
    trials = user_trials(args.model, args.data, rng)
    recipes = [
        ("0.5s single", (0.5,), 1), ("0.7s single", (0.7,), 1), ("1.0s single", (1.0,), 1),
        ("1.5s single", (1.5,), 1), ("2.5s single", (2.5,), 1),
        ("1-2.5s single", (1.0, 1.5, 2.0, 2.5), 1),
        ("1-2.5s mean of 3", (1.0, 1.5, 2.0, 2.5), 3),
        ("1-2.5s mean of 6", (1.0, 1.5, 2.0, 2.5), 6),
        ("0.5s mean of 6", (0.5,), 6), ("0.7s mean of 6", (0.7,), 6),
    ]
    print(f"\n[{args.model}] user: ~10 s enrollment vs brief test vectors (first half enrol, second half test)")
    for condition, (enroll, pieces) in trials.items():
        for name, lengths, k in recipes:
            same, diff = user_scores(enroll, pieces, rng, lengths, k)
            if not len(same):
                continue
            row = {
                "n_same": len(same), "n_diff": len(diff),
                "same_p1": pct(same, 1), "same_p5": pct(same, 5), "same_p50": pct(same, 50),
                "same_min": float(same.min()), "diff_p50": pct(diff, 50), "diff_p99.9": pct(diff, 99.9),
                "diff_max": float(diff.max()),
                "diff_above": {str(t): float((diff >= t).mean()) for t in np.arange(0.2, 0.81, 0.02).round(2)},
                "same_below": {str(t): float((same < t).mean()) for t in np.arange(0.2, 0.81, 0.02).round(2)},
            }
            report["user"].setdefault(condition, {})[name] = row
            print(f"  {condition:12} {name:18} same n {len(same):6} min {same.min():.3f} p5 {pct(same,5):.3f} p50 {pct(same,50):.3f}"
                  f" | diff n {len(diff):7} p50 {pct(diff,50):.3f} p99.9 {pct(diff,99.9):.3f} max {diff.max():.3f}")
    if args.json:
        args.json.write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
