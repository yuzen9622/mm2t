# M4 上使用 Nemotron 字幕與 Breeze Core ML 4-bit 的 60 分鐘實測

2026-11-19，Apple M4、32 GB。使用新版 mm2t 的 Release 最佳化建置，開啟測試音檔重播入口。先啟動並正常退出，再開同一執行檔。第二次 Breeze 回報模型就緒需 2.473 秒，載入期間該程序的 Neural Engine 編譯呼叫為 0。Nemotron 3.5 Multilingual 使用 1.12 秒版，本輪視窗有顯示即時字幕。

| 同一份 60 分鐘雙音軌 | Breeze Core ML 4-bit | Breeze MLX FP16 先前實測 |
|---|---:|---:|
| 停錄前已完成的雙軌音訊 | 40 分 2.9 秒 | 59 分 30 秒 |
| 停錄時待完成的雙軌音訊 | 19 分 57.1 秒 | 30 秒 |
| 停止到雙軌逐字稿存檔 | 25 分 3.99 秒 | 17.14 秒 |
| 停止到完整原始逐字稿可讀 | 25 分 4.15 秒 | 17.24 秒 |

以原速將相同的兩個 WAV 交給錄音流程，按停止後先檢查同一場會議已儲存兩軌轉錄，再偵測視窗的 01:00:00 與逐字稿列並截圖。兩軌檔案的 SHA-256 與先前 MLX 測試輸入一致。以測試 PID 的成功切段紀錄計算停止時的完成量，進行中的切段算入待完成。重播結束至停止標記間隔約 25 毫秒，期間沒有新增完成段落。Core ML 共完成 146 段、0 次切段失敗，覆蓋 3,600 秒。遠端軌有 6 個辨識單位的結束時間超過錄音終點，最晚 3,604.18 秒。

兩種配置各測一次，Core ML 使用目前 App 的自適應切段，MLX 使用固定 30 秒段落。測試期間另有 mm2t 程序執行過辨識，其段落已依 PID 排除，硬體競爭未受控。

[本輪數據](../../.build/coreml-hour-retest/result.json) · [計時原始輸出](../../.build/coreml-hour-retest/meter.log) · [完整逐字稿畫面](../../.build/coreml-hour-retest/full-hour-readable.png) · [MLX FP16 基準](M4-Nemotron-Breeze-MLX-30s.md)
