# mm2t 自架轉錄伺服器

mm2t 的第三種轉錄來源。這是在你自己的 GPU 主機上執行的 HTTP 服務，Mac 版 mm2t 透過區網或 Tailscale 把會議錄音送過來，伺服器回傳帶逐字時間戳記的轉錄稿。音訊只在你自己的機器之間傳輸，也不需要付 API 費用。

- 引擎：[faster-whisper](https://github.com/SYSTRAN/faster-whisper) 1.2.1（CTranslate2 4.8.5）
- 預設模型：[MediaTek-Research/Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25)（Apache-2.0，Whisper-large-v2 微調，針對台灣華語與中英夾雜）。聯發科官方只提供 Transformers 格式，所以預設使用社群轉好的 CTranslate2 版 [`SoybeanMilk/faster-whisper-Breeze-ASR-25`](https://huggingface.co/SoybeanMilk/faster-whisper-Breeze-ASR-25)（Apache-2.0，float16，約 3.1 GB），並固定在 commit `85be11de5f67aaa6a92e931622f1c2b55cc1dd3a`。

> **尚未在 GPU 上驗證。** 開發環境沒有 NVIDIA 顯示卡。HTTP 契約與 faster-whisper 介接已在 CPU 上以 tiny 模型實測過，但 Docker image 在 RTX 5080 上的實際執行、Breeze-ASR-25 的轉錄品質與速度都還沒測。第一次部署後，請先用一小段錄音確認（見下方「部署後檢查」）。

## 用 Docker 執行

主機需求：

- NVIDIA 驅動程式需支援 CUDA 12.8 以上（Linux 570.26 以上，依 [CUDA Toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html)）。RTX 50 系列（Blackwell，sm_120）本來就需要這個版本以上的驅動程式。
- Docker 與 [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)。Windows 請在 WSL2 裡的 Docker 中執行。

```bash
cd server
cp .env.example .env
docker compose up -d --build
docker compose logs -f   # 第一次啟動會下載約 3.1 GB 模型，存放在 models volume
curl http://localhost:8000/healthz
```

`/healthz` 回傳 `"device":"cuda"` 才代表有用到 GPU。compose 設定了 `MM2T_DEVICE=cuda`，所以抓不到 GPU 時服務會直接啟動失敗，不會默默退回 CPU。

### 部署後檢查

```bash
curl -H "Authorization: Bearer $MM2T_SERVER_TOKEN" \
  -F file=@sample.m4a -F language=zh -F 'vocabulary=["王小明","Kubernetes"]' \
  http://localhost:8000/v1/transcriptions
```

如果日誌出現 `CUBLAS_STATUS_NOT_SUPPORTED`，代表 cuBLAS 不支援目前的 GPU 與運算型別組合。RTX 50 系列已知的情況是 int8 GEMM 會觸發這個錯誤（[CTranslate2#1865](https://github.com/OpenNMT/CTranslate2/issues/1865)）。CTranslate2 4.6.2 起已在 sm_120 上停用 INT8（[#1937](https://github.com/OpenNMT/CTranslate2/pull/1937)），本 image 預設也使用 `float16`。請不要把 `MM2T_COMPUTE_TYPE` 改成 `int8_*`。

## 環境變數

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `MM2T_MODEL` | `SoybeanMilk/faster-whisper-Breeze-ASR-25` | Hugging Face repo id 或容器內的本機路徑（CTranslate2 格式） |
| `MM2T_MODEL_REVISION` | 使用預設模型時為上述 commit，否則不指定 | Hugging Face 的 commit／branch |
| `MM2T_DEVICE` | `auto`（compose 中為 `cuda`） | `cuda`、`cpu` 或 `auto` |
| `MM2T_COMPUTE_TYPE` | `default`（compose 中為 `float16`） | CTranslate2 運算型別 |
| `MM2T_BATCH_SIZE` | `16` | 一次並行解碼的音訊片段數；`1` 改回逐段解碼。RTX 5080 上 16 比逐段快約 16 倍，32 沒有再變快 |
| `MM2T_SERVER_TOKEN` | 未設定 | 有設定時，`/v1/*` 需帶 `Authorization: Bearer <token>` |
| `MM2T_MAX_UPLOAD_MB` | `500` | 上傳檔案大小上限（MB） |
| `MM2T_PORT` | `8000` | 監聽埠；修改時請一併調整 compose 的 `ports` |
| `MM2T_HOST` | `0.0.0.0` | 監聽位址 |

### 自行轉換模型

如果不想信任社群轉換版，可以從聯發科官方權重自己轉換：

```bash
pip install "faster-whisper[conversion]==1.2.1"
ct2-transformers-converter --model MediaTek-Research/Breeze-ASR-25 \
  --output_dir breeze-asr-25-ct2 \
  --copy_files tokenizer.json preprocessor_config.json \
  --quantization float16
```

接著把 `breeze-asr-25-ct2` 掛載進容器（例如 `./breeze-asr-25-ct2:/models/breeze-asr-25-ct2:ro`），再設定 `MM2T_MODEL=/models/breeze-asr-25-ct2`。

## HTTP 契約

### `GET /healthz`

不需驗證。

```json
{"status": "ok", "model": "SoybeanMilk/faster-whisper-Breeze-ASR-25", "device": "cuda"}
```

### `POST /v1/transcriptions`

`multipart/form-data`：

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `file` | 是 | 音訊檔（wav、flac、m4a、mp3；任何 FFmpeg 能解碼的格式都可以） |
| `language` | 否 | BCP-47（`zh-TW`）或 Whisper 代碼（`zh`）。只取主要子標籤；省略時自動偵測 |
| `vocabulary` | 否 | 字串 JSON 陣列，例如人名或專有名詞，會以 faster-whisper 的 `hotwords` 提示模型，每個 30 秒窗格都會套用 |

200 回應（時間以秒計，從檔案開頭起算）：

```json
{
  "model": "SoybeanMilk/faster-whisper-Breeze-ASR-25",
  "language": "zh",
  "duration": 12.3,
  "segments": [
    {
      "start": 0.0, "end": 2.4, "text": "王小明你好",
      "words": [{"word": "王小明", "start": 0.0, "end": 0.9, "probability": 0.93}]
    }
  ]
}
```

錯誤一律回傳 `{"error": {"code": "...", "message": "..."}}`：

| 狀態碼 | `code` | 情況 |
| --- | --- | --- |
| 400 | `invalid_request` | 缺少 `file` 等欄位 |
| 400 | `invalid_language` | 不支援的語言 |
| 400 | `invalid_vocabulary` | `vocabulary` 不是字串 JSON 陣列 |
| 400 | `invalid_audio` | 音訊無法解碼或沒有內容 |
| 401 | `unauthorized` | 缺少 token 或 token 錯誤 |
| 413 | `payload_too_large` | 超過 `MM2T_MAX_UPLOAD_MB` |
| 500 | `engine_error` | 轉錄引擎失敗（例如 GPU 錯誤） |

請求會依序處理。一段一小時的會議會占住伺服器直到轉完，Mac 端的逾時設定請預留足夠時間。

## 區網與 Tailscale

- 區網：Mac 端填 `http://<主機區網 IP>:8000`。
- Tailscale：兩台機器都登入同一個 tailnet，Mac 端填 `http://<主機名稱>:8000`（MagicDNS）或 `http://100.x.y.z:8000`。Tailscale 的流量本身就有 WireGuard 加密。
- 伺服器只提供 HTTP。請不要把 8000 埠直接開放到網際網路；如果要經過不受信任的網路，請透過 Tailscale，或在前面加一層 HTTPS 反向代理。
- 只要伺服器能被本機以外的裝置連到，就請設定 `MM2T_SERVER_TOKEN`。

## 開發

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
# 實際跑 faster-whisper tiny 模型（CPU，會下載約 75 MB 模型與 jfk.flac）
MM2T_REAL_ENGINE_TEST=1 .venv/bin/python -m pytest tests/test_real_engine.py
```

本機以 CPU 啟動：`MM2T_MODEL=tiny MM2T_DEVICE=cpu .venv/bin/python -m mm2t_server`
