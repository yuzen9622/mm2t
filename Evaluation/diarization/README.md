# 本機語者分群（diarization）評測

這個目錄量測 mm2t 的候選本機分群模型在中文多人會議上的準確度，結果見 [RESULTS.md](RESULTS.md)。它是獨立的評測工具，不依賴也不修改 repo 根目錄的 `Package.swift`、`Sources/`、`Tests/`、`server/`。

## 需求

- Apple silicon Mac（實測機器為 M4、32 GB、macOS 27、Xcode 27 / Swift 6.4）
- `uv`、`ffmpeg`（含 libopus）、`curl`
- 約 12 GB 磁碟空間（資料集壓縮檔 3.4 GB、解壓 5 GB、轉檔後音訊 1.6 GB、模型約 0.7 GB、建置輸出約 0.8 GB）
- 不需要 Hugging Face token。所有模型都從未設權限的 repo 下載。

## 一鍵重跑

```bash
cd Evaluation/diarization
./run_all.sh
```

腳本會依序完成下列步驟，每一步都可重複執行：

1. 從 OpenSLR 官方來源下載 AliMeeting Eval（`Eval_Ali.tar.gz`），以 SHA-256 驗證後解壓到 `data/raw/`。
2. 在 `.venv/` 建立 Python 虛擬環境，依 `requirements.lock.txt` 安裝固定版本的套件（快取放在 `.uv-cache/`）。
3. `scripts/prepare.py` 產生參考標註與三種單聲道 16 kHz 音訊（見下方「音訊條件」），並檢查參考標註與音訊是否有時間偏移，報告寫在 `data/prepare_report.json`。
4. `scripts/concat.py` 把兩場 4 人會議前後串接，做出 8 人的合成錄音，用來測說話者數量上限。
5. 建置 `swift/` 下的 `diareval` 執行檔（FluidAudio 鎖定 0.18.3），對每個引擎、每種條件跑分群。模型下載到 `models/`，不會寫進 `~/Library/Application Support`。
6. `scripts/score.py` 用 `pyannote.metrics` 計算 DER 與各分項，輸出到 `out/<引擎>/score_<條件>.txt` 與 `.json`。
7. `scripts/embeddings.py` 對參考標註中的單人片段抽聲紋向量，計算同人／不同人的 cosine 相似度分布與門檻。

## 單獨執行某一步

```bash
B=build/swift/release/diareval

# 分群：engine 可選 offline | sortformer | lseend-ami | nemotron3-offline | nemotron3-fast32
$B diarize --engine nemotron3-offline --models $PWD/models --out out/nemotron3-offline/far data/wav/far/*.wav

# 評分（--fill-gaps 0.5 會先補上同一說話者 0.5 秒以內的空隙）
.venv/bin/python scripts/score.py data/ref out/nemotron3-offline/far
.venv/bin/python scripts/score.py data/ref out/nemotron3-offline/far --fill-gaps 0.5

# 聲紋：參考片段 → 向量 → 分析
.venv/bin/python scripts/embeddings.py spans data out/embeddings/spans.json
$B embed --models $PWD/models --spans out/embeddings/spans.json --out out/embeddings/embeddings.json
.venv/bin/python scripts/embeddings.py analyze data out/embeddings/embeddings.json
```

`diareval` 只接受 16 kHz 單聲道 WAV，格式不符會直接報錯，不會默默重新取樣。

## 換成自己的會議錄音

這套工具不綁 AliMeeting。要用真實會議（例如 mm2t 錄下的遠端音軌）評測：

1. 把音訊轉成 16 kHz 單聲道：`ffmpeg -i remote.m4a -ac 1 -ar 16000 -sample_fmt s16 data/wav/mine/<場次>__mine.wav`
2. 在另一個目錄（例如 `data/ref_mine/`）放 `<場次>.rttm`（每行 `SPEAKER <場次> 1 <開始秒> <長度秒> <NA> <NA> <說話者> <NA> <NA>`）與 `<場次>.uem`（`<場次> 1 0.000 <結束秒>`）。
3. 跑 `diareval diarize` 與 `score.py data/ref_mine <輸出目錄>`。

## 音訊條件

| 條件 | 來源 | 用途 |
|---|---|---|
| `far` | 8 聲道麥克風陣列的第 0 聲道 | AliMeeting／pyannote 慣用的遠場條件，可對照公開數字 |
| `nearmix` | 每位與會者頭戴麥克風相加 | 近場人聲混成一軌，最接近 mm2t 遠端音軌的公開代理 |
| `nearmix_opus` | `nearmix` 經 Opus 24 kbit/s（VoIP 模式）編碼再解碼 | 加上會議軟體式的有損編碼 |

## 目錄

| 路徑 | 內容 | 版控 |
|---|---|---|
| `swift/` | `diareval` Swift 套件（FluidAudio 0.18.3） | 是 |
| `scripts/` | 前處理、評分、聲紋分析 | 是 |
| `run_all.sh`、`requirements.lock.txt` | 重跑腳本與 Python 套件版本 | 是 |
| `data/`、`models/`、`build/`、`out/`、`.venv/`、`.uv-cache/` | 下載、模型、建置與結果 | 否（`.gitignore`） |

## 下載來源與授權

| 項目 | 來源 | 大小 | 授權 |
|---|---|---|---|
| AliMeeting Eval（`Eval_Ali.tar.gz`，SHA-256 `dc47343b…8d92`） | https://www.openslr.org/119/ → `speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr/Eval_Ali.tar.gz` | 3,673,718,355 bytes | CC BY-SA 4.0 |
| FluidAudio SDK 0.18.3（commit `c8b41f98`） | https://github.com/FluidInference/FluidAudio | 原始碼 | Apache-2.0 |
| pyannote community-1 Core ML（rev `df2625ac`） | https://huggingface.co/FluidInference/speaker-diarization-coreml | 21 MB | CC-BY-4.0（PLDA 來自 BUT，同為 CC-BY-4.0） |
| Sortformer 4spk v2（highContextV2） | https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml | 243 MB | CC-BY-4.0 |
| LS-EEND（AMI 版） | https://huggingface.co/FluidInference/ls-eend-coreml | 43 MB | MIT |
| Nemotron-3-Diarization（offline、fast32） | https://huggingface.co/FluidInference/nemotron-3-diarization-coreml | 380 MB | OpenMDW-1.1 |
| Python 套件（pyannote.metrics 4.2.0 等） | PyPI | 約 200 MB | 見 `requirements.lock.txt` |

AliMeeting 只用於評測，不得隨 App 散布。
