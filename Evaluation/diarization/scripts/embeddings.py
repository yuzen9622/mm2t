"""Speaker-embedding separability on AliMeeting Eval, as a proxy for cross-meeting voiceprints.

  embeddings.py spans DATA_DIR SPANS.json
      Clean single-speaker reference regions (no other reference speaker active), cut into
      2-8 s pieces, for every session and condition.
  embeddings.py analyze DATA_DIR EMBEDDINGS.json [--json OUT.json]
      Cosine-similarity distributions, EER and operating thresholds.
  embeddings.py hypspans HYP_DIR SPANS.json
      Clean single-cluster pieces of each hypothesis cluster, for diarizers without embeddings.
  embeddings.py clusters DATA_DIR EMBEDDINGS.json HYP_DIR [--span-embeddings HYP_EMBEDDINGS.json]
      Diarizer cluster centroids against near-mix first-half voiceprints, clusters mapped to
      reference speakers by the DER optimal mapping. Centroids come from speakerDatabase, or with
      --span-embeddings from the mean WeSpeaker embedding of each cluster's hypspans pieces.

No Eval speaker appears in two sessions, so "another meeting" is approximated by the other half
of the same session (pieces at least 60 s apart, voiceprints from disjoint halves). Same room,
same microphone: an optimistic proxy for a real cross-meeting match.
"""

import argparse
import itertools
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

MIN_PIECE, MAX_PIECE = 2.0, 8.0
CONDITIONS = ("far", "nearmix", "nearmix_opus")
VOICEPRINT_SECONDS = 60.0


def read_rttm(path: Path) -> dict[str, list[tuple[float, float]]]:
    by_speaker = defaultdict(list)
    for line in path.read_text().splitlines():
        f = line.split()
        by_speaker[f[7]].append((float(f[3]), float(f[3]) + float(f[4])))
    return by_speaker


def subtract(intervals, holes):
    out = []
    for start, end in intervals:
        pieces = [(start, end)]
        for h_start, h_end in holes:
            pieces = [
                p
                for s, e in pieces
                for p in ((s, min(e, h_start)), (max(s, h_end), e))
                if p[1] - p[0] > 0
            ]
        out.extend(pieces)
    return out


def clean_pieces(by_speaker):
    result = {}
    for speaker, intervals in by_speaker.items():
        others = sorted(i for s, iv in by_speaker.items() if s != speaker for i in iv)
        pieces = []
        for start, end in subtract(sorted(intervals), others):
            while end - start >= MIN_PIECE:
                stop = min(end, start + MAX_PIECE)
                pieces.append((round(start, 3), round(stop, 3)))
                start = stop
        result[speaker] = pieces
    return result


def make_spans(data: Path, out: Path) -> None:
    requests = []
    for ref in sorted((data / "ref").glob("*.rttm")):
        pieces = clean_pieces(read_rttm(ref))
        spans = sorted(p for ps in pieces.values() for p in ps)
        for condition in CONDITIONS:
            wav = data / "wav" / condition / f"{ref.stem}__{condition}.wav"
            requests.append({"wav": str(wav.resolve()), "spans": [list(s) for s in spans]})
    out.write_text(json.dumps(requests))
    print(f"{len(requests)} files, {sum(len(r['spans']) for r in requests)} spans")


def eer_and_thresholds(pos: np.ndarray, neg: np.ndarray) -> dict:
    thresholds = np.unique(np.concatenate([pos, neg]))
    far = np.array([(neg >= t).mean() for t in thresholds])
    frr = np.array([(pos < t).mean() for t in thresholds])
    i = int(np.argmin(np.abs(far - frr)))

    def at_far(target):
        ok = np.where(far <= target)[0]
        j = ok[0]
        return {"threshold": float(thresholds[j]), "far": float(far[j]), "frr": float(frr[j])}

    return {
        "eer": float((far[i] + frr[i]) / 2),
        "eer_threshold": float(thresholds[i]),
        "at_far_1pct": at_far(0.01),
        "at_far_0.1pct": at_far(0.001),
        "pos": summary(pos),
        "neg": summary(neg),
    }


def summary(x: np.ndarray) -> dict:
    return {
        "n": int(len(x)),
        "mean": float(x.mean()),
        "p1": float(np.percentile(x, 1)),
        "p5": float(np.percentile(x, 5)),
        "p50": float(np.percentile(x, 50)),
        "p95": float(np.percentile(x, 95)),
        "p99": float(np.percentile(x, 99)),
        "max": float(x.max()),
    }


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


def load(data: Path, path: Path):
    """Return {(condition, session): {speaker: [(start, end, vector)]}}."""
    owner = {}
    for ref in sorted((data / "ref").glob("*.rttm")):
        for speaker, pieces in clean_pieces(read_rttm(ref)).items():
            for p in pieces:
                owner[(ref.stem, p)] = speaker
    table = defaultdict(lambda: defaultdict(list))
    for item in json.loads(path.read_text()):
        session, condition = Path(item["wav"]).stem.split("__")
        for span, vector in zip(item["spans"], item["embeddings"]):
            key = (session, (span[0], span[1]))
            table[(condition, session)][owner[key]].append((span[0], span[1], unit(vector)))
    return table


def segment_pairs(table, condition, rng):
    same, diff_session, diff_other = [], [], []
    sessions = {s: spk for (c, s), spk in table.items() if c == condition}
    for session, speakers in sessions.items():
        for speaker, pieces in speakers.items():
            for a, b in itertools.combinations(pieces, 2):
                if abs(a[0] - b[0]) >= 60.0:
                    same.append(float(a[2] @ b[2]))
        for (sa, pa), (sb, pb) in itertools.combinations(speakers.items(), 2):
            for a in pa:
                for b in pb:
                    diff_session.append(float(a[2] @ b[2]))
    flat = [(s, spk, p[2]) for s, speakers in sessions.items() for spk, ps in speakers.items() for p in ps]
    idx = rng.choice(len(flat), size=(200_000, 2))
    for i, j in idx:
        if flat[i][0] != flat[j][0]:
            diff_other.append(float(flat[i][2] @ flat[j][2]))
    return np.array(same), np.array(diff_session), np.array(diff_other)


def voiceprints(table, condition, half):
    """Mean of up to VOICEPRINT_SECONDS of clean pieces from one half of each session."""
    prints = {}
    for (c, session), speakers in table.items():
        if c != condition:
            continue
        end = max(p[1] for ps in speakers.values() for p in ps)
        for speaker, pieces in speakers.items():
            chosen, total = [], 0.0
            ordered = pieces if half == 0 else list(reversed(pieces))
            for start, stop, vector in ordered:
                in_half = start < end / 2 if half == 0 else start >= end / 2
                if in_half and total < VOICEPRINT_SECONDS:
                    chosen.append(vector)
                    total += stop - start
            if chosen:
                prints[(session, speaker)] = (unit(np.mean(chosen, axis=0)), total)
    return prints


def voiceprint_trials(table, enroll_condition, test_condition):
    enroll = voiceprints(table, enroll_condition, 0)
    test = voiceprints(table, test_condition, 1)
    pos, neg_session, neg_other = [], [], []
    for (s1, k1), (v1, _) in enroll.items():
        for (s2, k2), (v2, _) in test.items():
            score = float(v1 @ v2)
            if (s1, k1) == (s2, k2):
                pos.append(score)
            elif s1 == s2:
                neg_session.append(score)
            else:
                neg_other.append(score)
    return np.array(pos), np.array(neg_session), np.array(neg_other), enroll, test


def analyze(data: Path, path: Path, out: Path | None) -> None:
    rng = np.random.default_rng(0)
    table = load(data, path)
    result = {"segments": {}, "voiceprints": {}}
    for condition in CONDITIONS:
        same, diff_session, diff_other = segment_pairs(table, condition, rng)
        result["segments"][condition] = {
            "vs_same_meeting_others": eer_and_thresholds(same, diff_session),
            "vs_other_meetings": eer_and_thresholds(same, diff_other),
        }
    for enroll_c, test_c in [("nearmix", "nearmix"), ("nearmix_opus", "nearmix_opus"), ("far", "far"),
                             ("nearmix", "nearmix_opus"), ("nearmix", "far")]:
        pos, neg_session, neg_other, enroll, test = voiceprint_trials(table, enroll_c, test_c)
        neg_all = np.concatenate([neg_session, neg_other])
        result["voiceprints"][f"{enroll_c}->{test_c}"] = {
            "positives": summary(pos),
            "neg_same_meeting": summary(neg_session),
            "neg_other_meetings": summary(neg_other),
            "max_neg": float(neg_all.max()),
            "min_pos": float(pos.min()),
            "separable": bool(pos.min() > neg_all.max()),
            "enroll_seconds_min": float(min(t for _, t in enroll.values())),
            "test_seconds_min": float(min(t for _, t in test.values())),
        }

    for condition, r in result["segments"].items():
        for kind, m in r.items():
            print(
                f"segments {condition:13} {kind:24} EER {m['eer']*100:5.2f}%  thr@EER {m['eer_threshold']:.3f}  "
                f"thr@FAR1% {m['at_far_1pct']['threshold']:.3f} (FRR {m['at_far_1pct']['frr']*100:4.1f}%)  "
                f"thr@FAR0.1% {m['at_far_0.1pct']['threshold']:.3f} (FRR {m['at_far_0.1pct']['frr']*100:4.1f}%)  "
                f"pos p50 {m['pos']['p50']:.3f} neg p50 {m['neg']['p50']:.3f} n+ {m['pos']['n']} n- {m['neg']['n']}"
            )
    for name, v in result["voiceprints"].items():
        print(
            f"voiceprint {name:26} pos min {v['min_pos']:.3f} p50 {v['positives']['p50']:.3f} | "
            f"neg same-mtg max {v['neg_same_meeting']['max']:.3f} p50 {v['neg_same_meeting']['p50']:.3f} | "
            f"neg other max {v['neg_other_meetings']['max']:.3f} | separable {v['separable']}"
        )
    if out:
        out.write_text(json.dumps(result, indent=2))


def make_hyp_spans(hyp_dir: Path, out: Path) -> None:
    requests = []
    for hyp_path in sorted(hyp_dir.glob("*.rttm")):
        record = json.loads(hyp_path.with_suffix(".json").read_text())
        pieces = clean_pieces(read_rttm(hyp_path))
        spans = sorted(p for ps in pieces.values() for p in ps)
        requests.append({"wav": record["wav"], "spans": [list(x) for x in spans]})
    out.write_text(json.dumps(requests))
    print(f"{len(requests)} files, {sum(len(r['spans']) for r in requests)} spans")


def span_centroids(hyp_dir: Path, path: Path) -> dict[str, dict[str, list[float]]]:
    result = {}
    for item in json.loads(path.read_text()):
        file_id = Path(item["wav"]).stem
        owner = {p: k for k, ps in clean_pieces(read_rttm(hyp_dir / f"{file_id}.rttm")).items() for p in ps}
        by_cluster = defaultdict(list)
        for span, vector in zip(item["spans"], item["embeddings"]):
            by_cluster[owner[(span[0], span[1])]].append(unit(vector))
        result[file_id] = {k: list(np.mean(v, axis=0)) for k, v in by_cluster.items()}
    return result


def clusters(data: Path, path: Path, hyp_dir: Path, span_embeddings: Path | None) -> None:
    from pyannote.metrics.diarization import DiarizationErrorRate
    from score import load_rttm

    enroll = voiceprints(load(data, path), "nearmix", 0)
    from_spans = span_centroids(hyp_dir, span_embeddings) if span_embeddings else None
    pos, neg = [], []
    for hyp_path in sorted(hyp_dir.glob("*.rttm")):
        session = hyp_path.stem.split("__")[0]
        mapping = DiarizationErrorRate().optimal_mapping(
            load_rttm(data / "ref" / f"{session}.rttm"), load_rttm(hyp_path))
        database = (
            from_spans[hyp_path.stem]
            if from_spans is not None
            else json.loads(hyp_path.with_suffix(".json").read_text())["speakerDatabase"]
        )
        for cluster, vector in database.items():
            v = unit(vector)
            for (s, k), (e, _) in enroll.items():
                (pos if (s, k) == (session, mapping.get(cluster)) else neg).append(float(v @ e))
    pos, neg = np.array(pos), np.array(neg)
    print(f"{hyp_dir.name}: centroid vs voiceprint  pos n {len(pos)} min {pos.min():.3f} p50 {np.median(pos):.3f}"
          f" | neg n {len(neg)} p50 {np.median(neg):.3f} max {neg.max():.3f}")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("spans")
    s.add_argument("data", type=Path)
    s.add_argument("out", type=Path)
    a = sub.add_parser("analyze")
    a.add_argument("data", type=Path)
    a.add_argument("embeddings", type=Path)
    a.add_argument("--json", type=Path)
    c = sub.add_parser("clusters")
    c.add_argument("data", type=Path)
    c.add_argument("embeddings", type=Path)
    c.add_argument("hyp_dir", type=Path)
    c.add_argument("--span-embeddings", type=Path)
    h = sub.add_parser("hypspans")
    h.add_argument("hyp_dir", type=Path)
    h.add_argument("out", type=Path)
    args = parser.parse_args()
    if args.cmd == "spans":
        make_spans(args.data, args.out)
    elif args.cmd == "clusters":
        clusters(args.data, args.embeddings, args.hyp_dir, args.span_embeddings)
    elif args.cmd == "hypspans":
        make_hyp_spans(args.hyp_dir, args.out)
    else:
        analyze(args.data, args.embeddings, args.json)


if __name__ == "__main__":
    main()
