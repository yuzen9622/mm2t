#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

URL=https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Eval_Ali.tar.gz
SHA=dc47343b2474b5ebcf458927e878155f6ddeb59c85e685b3645c32a1f9578d92

mkdir -p data/download data/raw
if [[ ! -f data/download/Eval_Ali.tar.gz ]] || [[ "$(shasum -a 256 data/download/Eval_Ali.tar.gz | cut -d' ' -f1)" != $SHA ]]; then
  until curl -sS -C - -o data/download/Eval_Ali.tar.gz $URL; do sleep 5; done
fi
[[ "$(shasum -a 256 data/download/Eval_Ali.tar.gz | cut -d' ' -f1)" == $SHA ]]
[[ -d data/raw/Eval_Ali ]] || tar -xzf data/download/Eval_Ali.tar.gz -C data/raw

if [[ ! -x .venv/bin/python ]]; then
  uv venv --python python3 .venv
  UV_CACHE_DIR=$PWD/.uv-cache uv pip install --python .venv/bin/python -r requirements.lock.txt
fi

.venv/bin/python scripts/prepare.py data/raw/Eval_Ali data

(cd swift && swift build -c release --build-path ../build/swift)
BIN=build/swift/release/diareval

.venv/bin/python scripts/concat.py data

outdir() { [[ $1 == offline ]] && echo out/fluidaudio-offline || echo out/$1 }

for engine in offline sortformer lseend-ami nemotron3-offline nemotron3-fast32; do
  dir=$(outdir $engine)
  for condition in far nearmix nearmix_opus; do
    $BIN diarize --engine $engine --models $PWD/models --out $dir/$condition data/wav/$condition/*.wav \
      | grep -E "RTF|error"
    .venv/bin/python scripts/score.py data/ref $dir/$condition --json $dir/score_$condition.json \
      > $dir/score_$condition.txt
    .venv/bin/python scripts/score.py data/ref $dir/$condition --fill-gaps 0.5 \
      --json $dir/score_${condition}_fill0.5.json > $dir/score_${condition}_fill0.5.txt
  done
done

for engine in offline sortformer nemotron3-offline; do
  dir=$(outdir $engine)
  $BIN diarize --engine $engine --models $PWD/models --out $dir/concat8 data/wav/concat8/*.wav | grep -E "RTF|error"
  .venv/bin/python scripts/score.py data/ref_concat8 $dir/concat8 --json $dir/score_concat8.json \
    > $dir/score_concat8.txt
done

mkdir -p out/embeddings
.venv/bin/python scripts/embeddings.py spans data out/embeddings/spans.json
$BIN embed --models $PWD/models --spans out/embeddings/spans.json --out out/embeddings/embeddings.json \
  | grep -v Profiling
.venv/bin/python scripts/embeddings.py analyze data out/embeddings/embeddings.json \
  --json out/embeddings/analysis.json | tee out/embeddings/analysis.txt
for condition in far nearmix nearmix_opus; do
  .venv/bin/python scripts/embeddings.py clusters data out/embeddings/embeddings.json out/fluidaudio-offline/$condition
done | tee out/embeddings/clusters.txt
for condition in far nearmix_opus; do
  .venv/bin/python scripts/embeddings.py hypspans out/nemotron3-offline/$condition \
    out/embeddings/hypspans_nemotron3-offline_$condition.json
  $BIN embed --models $PWD/models --spans out/embeddings/hypspans_nemotron3-offline_$condition.json \
    --out out/embeddings/hypemb_nemotron3-offline_$condition.json | grep -v Profiling
  .venv/bin/python scripts/embeddings.py clusters data out/embeddings/embeddings.json \
    out/nemotron3-offline/$condition --span-embeddings out/embeddings/hypemb_nemotron3-offline_$condition.json
done | tee out/embeddings/clusters_nemotron3.txt
