# 停止錄音到完整輸出的量測

`App/MM2T/DebugBenchmark.swift` 提供兩種錄音重播方式，皆走正式的 `CaptureController.startNow()` 與 `stop()`。重播使用原始雙軌 WAV，不使用已存在的轉錄、說話者或 LLM 結果。只有重播器能讀原始音檔；處理流程只能讀隔離資料目錄中逐步增加的 WAV。

目前報告為 `schema_version=4`。第 4 版新增空來源、無效說話者／負責人、重複逐字稿 ID 的驗收檢查；第 3 版的 `all_outputs_complete=true` 不表示已通過這些新增檢查。

## 模式與計時範圍

| `MM2T_BENCH_MODE` | 行為 | 能建立的證據 |
| --- | --- | --- |
| `timed`（預設） | 按單調時鐘以 1 倍速釋出音訊；48 分鐘來源需重播 48 分鐘 | 實際錄音進度下的背景處理積欠與停止延遲。仍需檢查內容品質與實際音訊擷取負載。 |
| `accelerated` | 每次釋出 60 秒，等背景處理水位追上；預設保留最後 20 秒直到 `RecordingSession.stop()` 內才寫入 | 背景工作有充足時間時的停止尾段診斷。刻意提供提前處理時間，**不能作為 10 秒驗收結果**。 |
| `batch` | 整場音訊從 `ProcessingQueue` 開始處理，或用 `MM2T_BENCH_MEETING` 接續隔離資料庫中的工作 | 整場／接續工作耗時；不包含停止錄音，不能作為停止延遲。 |
| `llm` | 讀既有逐字稿與說話者結果，在同一 recording provider 先產生一次 prefix checkpoint，再更新完整會議的 LLM 輸出 | 純文字語意與增量快取診斷；不執行錄音、STT 或分群，不能作為 10 秒驗收。 |

錄音重播的 `stop_to_completed_seconds` 從呼叫 `CaptureController.stop()` 前開始，到它完成 `onRecorded`／`ProcessingQueue` 返回為止。錄音器的尾段寫入、同步與關檔、等候進行中的工作、搬檔、尾段轉錄、分群、LLM 整理與持久化都在此範圍內。失敗或等待設定也可能返回，故耗時必須與結構檢查一起判讀。

僅 `accelerated` 可用 `MM2T_BENCH_DIAGNOSTIC_TAIL_SECONDS` 指定保留的秒數（0 至音訊總長，預設 20）。例如 0 可用來快速檢查最後已完成的背景清稿是否被摘要重用；仍有尚不足一片的 STT 尾段要在停止時處理。報告記錄指定值與實際尾段秒數。這是語意／快取診斷，不能把 0 秒保留尾段或任何 accelerated 結果當成 1 倍速驗收；`timed` 完全不使用此設定。

`accelerated` 的水位門檻是轉錄落後釋出位置不超過 30 秒、分群不超過 65 秒；釋出超過 150 秒後，已完成 checkpoint 的封閉音訊水位落後不超過 130 秒且沒有進行中的 checkpoint。此音訊水位包含已確認的靜音，與最後一句已整理文字的時間分開記錄，避免長沉默讓診斷永遠等不到門檻。門檻允許安靜切段、模型緩衝與 checkpoint 間距，不能解讀為全部背景工作已完成。每個水位預設等候最多 180 秒，逾時會留下該次等待目標、各條件是否達成、實際等待秒數及最近的進度；`MM2T_BENCH_PREFIX_TIMEOUT_SECONDS` 可調整此診斷逾時。期限檢查與模型 actor 的進度抽樣分開，因此模型停止回應不會讓診斷的逾時檢查一起卡住。

## 準備與執行

1. 使用含 `DEBUG` 編譯旗標的 App。正式效能量測應使用最佳化編譯，報告另外記錄版本、編譯選項、機器、電源狀態、供應商／模型與冷啟動或暖機條件。一般 Debug 編譯適合查流程，不能與最佳化正式版直接比較。
2. 在 KINGSTON 建立新的隔離資料根目錄。重播要求其中沒有會議，並要求設定 `MM2T_DEFAULTS_SUITE`。該設定 suite 應包含與實際使用相同的非機密模型／路由設定。讓隔離目錄可讀相同的模型與聲紋；不要把既有處理結果當作輸入。App 仍透過正常 credential store 使用已授權的憑證，量測工具不讀出或列印金鑰。
3. `MM2T_BENCH_SOURCE` 指向來源 `meeting.json`。只解碼錄音檔名、metadata 與 highlights；日期、時區、時長與標記會保留，以維持「今天／明天」的上下文。來源文件與音檔只讀。另可傳 `MM2T_BENCH_MIC`、`MM2T_BENCH_REMOTE`，但沒有原始會議日期的結果不具正式驗收資格。
4. 指定已存在且可寫的報告父目錄，直接執行 App binary。以下路徑與 suite 為範例，執行前填入實際隔離環境：

```sh
MM2T_DEFAULTS_SUITE=dev.mm2t.benchmark.run1 \
MM2T_BENCH_SOURCE="/path/to/source/meeting.json" \
MM2T_BENCH_MODE=timed \
MM2T_BENCH_OUT="/Volumes/KINGSTON/path/to/benchmark/report.json" \
"/path/to/mm2t.app/Contents/MacOS/mm2t" \
  -MM2TDataRoot "/Volumes/KINGSTON/path/to/benchmark/data"
```

執行中約每 30 秒更新 `report.json.progress.json`；accelerated 約每 250ms 抽樣水位，進度檔仍以 30 秒節奏寫入。主報告完成後 App 結束。主報告與進度只含計數、狀態、模式、輸入時長、耗時及非機密的模型／路由資訊，不含標題、逐字稿、名詞、服務網址或錯誤回應內容。隔離資料庫中的正式會議輸出仍包含原始會議內容，應留在本機。

## 純文字語意定點診斷

`MM2T_BENCH_MODE=llm` 的 `MM2T_BENCH_SOURCE` 改指向已完成轉錄與說話者歸屬的 derived `meeting.json`。這是前述「不使用既有處理結果」規則的明確例外，只用來快速檢查已知語意問題。來源文件只讀；在新的隔離 library 建立新 ID 的副本，保留原始逐字稿 ID、順序、speaker、時間、metadata 與 highlights，清除副本既有 LLM 輸出。音檔不讀取、不複製，產物供文字比對，不能用來播放音訊。

此模式僅支援目前設定的 cloud Gemini，使用相同預設模型與 `GeminiLLM.forRecording()`。`MM2T_KEYCHAIN_SERVICE` 與 App 的 DEBUG credential store 規則相同；未指定時使用預設 service 加上 `.debug`。不需 STT 或分群模型設定齊全，也不列印憑證。

`MM2T_BENCH_LLM_PREFIX_SECONDS` 預設為 `2853.2`，適用本次 48 分鐘來源。工具取結束時間不超過水位的**連續 utterance prefix**，不抽掉中間段落；prefix 必須非空且留下至少一段供最後更新。先 await `pipeline.precomputeRecording(prefix)` 成功，再透過相同 pipeline 重新生成完整副本。這會重新產生 prefix 清稿並暖起 summary、digest 與 normalization cache，不直接注入已保存的清稿或摘要。若任一 warm 工作失敗，便回報失敗而不繼續。

報告另含 `warm_checkpoint_seconds`、`final_llm_seconds`、prefix／新增段落數、原始輸入保真檢查，並固定 `semantic_diagnostic_only=true`、`acceptance_eligible=false`、`target_timing_passed=false`。進度檔只在 warm 與 final 階段切換時更新。此流程讓最後更新取得已完成的 prefix 清稿，是刻意安排的診斷條件；沒有重現長時間累積 checkpoint、錄音中的競爭或停止時排程。只檢查已知日期／時刻矛盾、條件式提議、明確交辦與來源，仍須另有 1 倍速測試才能驗收延遲。

```sh
MM2T_DEFAULTS_SUITE=dev.mm2t.benchmark.semantic \
MM2T_BENCH_SOURCE="/path/to/derived/meeting.json" \
MM2T_BENCH_MODE=llm \
MM2T_BENCH_LLM_PREFIX_SECONDS=2853.2 \
MM2T_BENCH_OUT="/Volumes/KINGSTON/path/to/semantic/report.json" \
"/path/to/mm2t.app/Contents/MacOS/mm2t" \
  -MM2TDataRoot "/Volumes/KINGSTON/path/to/semantic/data"
```

## 判讀與品質確認

- `before_stop`：最近一次背景抽樣的已轉錄、已分群、checkpoint 秒數與忙碌狀態；`checkpoint_seconds` 是最後一句已整理文字的結束時間，`checkpoint_audio_seconds` 是這次已完成 checkpoint 的封閉音訊範圍。`before_stop_sample_age_seconds` 說明抽樣距離停止多久。timed 不會為取得即時水位而等模型 actor 排空。
- `recording_wall_seconds`、`released_before_stop_seconds`、`stop_tail_audio_seconds`：錄音階段花了多久、已釋出多少音訊、多少新音訊在停止內才釋出。
- `max_release_ahead_seconds`：僅 timed 模式提供，應不大於一個音訊 frame。計時模式不會等背景工作追上後才按停止。
- `all_outputs_complete`：會議與 queue 均 completed；有逐字稿、可分離的說話者歸屬、整理版、依人彙整與摘要；輸出未過期；逐字稿 ID 不重複；每個已生成的段落、彙整重點、摘要條目與待辦皆有來源，且引用的逐字稿 ID 都存在；逐字稿、段落、彙整、分群區段的說話者及待辦負責人都能解析為會議中的說話者（包含自己與合法合併）。待辦可合法為空，整理版也可省略語助詞，仍需人工驗證內容。
- `empty_source_items`／`empty_source_items_by_output`、`invalid_source_references`、`invalid_speaker_references`／`invalid_speaker_references_by_output`、`invalid_action_owners`、`duplicate_utterance_ids`：結構缺陷的計數。任一非零會讓 `output_structure_valid` 與 `all_outputs_complete` 為 false；不會輸出實際 ID 或姓名。
- `cleaned_utterances_omitted`：沒有出現在整理版引用中的原始段落數，供人工比對。整理版允許省略語助詞，不能僅由此判定缺漏。
- `stop_dispatch_delay_seconds`：timed 模式實際呼叫停止比原定音訊結束時間晚了多久；`audio_deadline_to_completed_seconds` 包含這段排程延遲，避免主執行緒卡住時，額外的背景處理時間被漏算。重播依原定截止時間停止，不會先排空背景工作。
- `capture_stop_timing_passed`：僅 timed 模式、保留原始 metadata、沒有超前釋出、結構檢查通過且 `CaptureController.stop()` 返回耗時不超過 10 秒時成立。`target_timing_passed` 另要求從原定音訊結束時間至完成也不超過 10 秒。兩者都只是結構與時間的結果。
- `quality_review_required` 固定為 true。工具不宣告整體目標已達成。需以同一份完整音訊核對尾段是否出現、是否漏字／重複、跨段說話者一致性、決議與待辦是否忠實、相對日期與時間是否正確。既有 LLM 結果只能作比較資料，不是真實答案。

至少保留一次 1 倍速重播與對應內容檢查；多次重播才能描述穩定性。accelerated、batch 和 llm 的任何小於 10 秒結果都不能替代這項驗證。重播也不會同時啟動實體麥克風與系統音訊擷取，正式產品體驗仍須在原生錄音情境確認。
