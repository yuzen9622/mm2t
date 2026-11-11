# 本機語者分群評測結果

量測日期 2026-11-10。機器為 Apple M4、32 GB、macOS 27。每個數字都標明來源：**實測**（本目錄的工具跑出來的）、**推論**（由實測數字推出，但沒有直接量）、**推測**（沒有證據支持的判斷）。

## 結論

**建議：有條件採用 FluidAudio 的 Nemotron-3-Diarization 做分群，聲紋向量改用同一個 SDK 的 WeSpeaker（pyannote community-1）`embedSpans` 另外抽。** spec 原本的首選（FluidAudio 的 pyannote community-1 Offline 管線）可以用，但在本評測中明顯較差，不建議當主要路徑。

- 誰在說話（說話者混淆）：Nemotron-3 offline 在最接近 App 遠端音軌的條件（`nearmix_opus`）混淆率 0.19%，pyannote community-1 是 5.51%（實測）。後者在一場會議把 4 人分成 3 人，在 8 人合成錄音上混淆率 9.8%（實測）。
- 說話者數量：Nemotron-3 offline 在 8 場 4/3/2 人會議與 2 段 8 人合成錄音上全部數對；pyannote community-1 錯 1/8 場，8 人合成錄音錯 1/2 段（實測）。
- Sortformer v2 在 4 人以內的會議最準（`nearmix_opus` DER 11.3%），但模型上限 4 人，8 人錄音混淆率 37.8%（實測），會議常超過 4 人，所以排除。
- 重要保留：Nemotron-3 與 Sortformer v2 的模型卡都列出訓練資料含 AliMeeting Train（Nemotron-3 還含 AISHELL-4 與 AliMeeting 頭戴麥克風資料）。本評測用的是 Eval 分割，不是訓練資料本身，但錄音環境同源，這些數字很可能高估它們在台灣會議上的表現（推論）。pyannote community-1 的訓練資料無法查證（模型卡需登入）。**要過硬門檻，下一步必須用 3–5 段使用者自己的真實會議（人工標註說話者）跑同一套工具。**

## 評分方式

- 評分工具：`pyannote.metrics` 4.2.0 的 `DiarizationErrorRate`，不是自寫的。
- 每場以 UEM 評整段：0 秒到「TextGrid 結束時間與該條件音訊長度的較小值」。參考標註的最後一段結束時間與 UEM 結束相差不到 0.1 秒（實測，`data/prepare_report.json`）。遠場音訊比標註多出 2–22 秒，那段沒有標註，不評分。
- 重疊語音一律計分（`skip_overlap=False`）。主要報兩種 collar：0 秒（pyannote 公開 benchmark 的慣例）與 0.25 秒（M2MeT／AliMeeting 常用）。另外報「略過重疊區」的 DER，以及「只評重疊區」的 DER（UEM 換成參考標註中兩人以上同時說話的區段，collar 0）。
- 漏判、誤判、混淆三項都除以參考語音總長（重疊區每位說話者各算一次），三項相加等於 DER。
- 總計（POOLED）是把 8 場的錯誤時間與參考時間各自加總後相除，不是場次平均。
- 重疊召回／精確率：系統標成兩人以上同時說話的時間，與參考重疊區交集，分別除以參考重疊總長與系統重疊總長。
- 參考重疊區佔參考語音時間的 21.6%（實測）。
- RTF＝處理秒數÷音訊秒數，不含模型下載與編譯，每個引擎先用第一個檔案前 60 秒暖機（實測，單次執行）。同一引擎不同條件的 RTF 差到 1.5 倍以上，機器上還有其他程式在跑，請當數量級看。

### AliMeeting 標註造成的漏判

AliMeeting 的 TextGrid 一段話常包含句中停頓。邊界貼得緊的模型會把停頓判成沒人說話，collar 0 的漏判因此偏高。

- Nemotron-3 offline 在 `nearmix_opus` 的漏判時間中，74% 落在短於 0.5 秒的片段，85% 的時間在近場混音裡比平均語音音量低 20 dB 以上，也就是幾乎無聲（實測）。所以它 10% 的漏判大多是停頓，不是漏掉的字（推論）。
- pyannote community-1 的漏判只有 58% 是近乎無聲，其餘是聽得到的語音（實測）。
- 所以另外報「把同一說話者 0.5 秒以內的空隙補起來」後的分數（`--fill-gaps 0.5`，等同 pyannote 的 `min_duration_off`）。這是 App 顯示時本來就會做的後處理。

## 資料

AliMeeting Eval（OpenSLR SLR119，CC BY-SA 4.0）全部 8 場，共約 4.3 小時，每場 26–37 分鐘，2–4 人，總共 25 位說話者，每位只出現在一場。只有 Eval 分割同時提供遠場陣列與每人頭戴麥克風，下載 3.4 GB；Test 分割 8.9 GB，同一份 Eval 再切更小也省不了下載量，所以全用。

| 場次 | 說話者數 | 評分長度 |
|---|---|---|
| R8001_M8004 | 4 | 1551.0 秒 |
| R8003_M8001 | 4 | 2067.7 秒 |
| R8007_M8010 | 4 | 1853.9 秒 |
| R8007_M8011 | 4 | 1859.0 秒 |
| R8008_M8013 | 3 | 2235.5 秒 |
| R8009_M8018 | 2 | 1651.5 秒 |
| R8009_M8019 | 2 | 1964.7 秒 |
| R8009_M8020 | 2 | 1907.6 秒 |

三種單聲道 16 kHz 條件：`far`（陣列第 0 聲道）、`nearmix`（每人頭戴麥克風相加）、`nearmix_opus`（`nearmix` 經 Opus 24 kbit/s VoIP 模式編解碼）。8 人合成錄音（`concat8`）：R8001_M8004＋R8003_M8001、R8007_M8010＋R8007_M8011，各自前後串接 `nearmix_opus`，約 60 分鐘、8 人。兩半的說話者不會交錯，所以只測人數上限與計數，不測 8 人輪流發言。

### 這個代理和使用者真實會議的差別

- 語言：AliMeeting 是中國大陸普通話，沒有中英夾雜，也沒有台灣口音（實測於標註文字，推論其影響）。分群模型主要靠音色，語言差異的影響應該比 ASR 小，但沒有量（推測）。
- 收音：`nearmix` 是每人頭戴麥克風直接相加，各麥克風也收到旁人的聲音，相加後會有輕微的延遲疊音。真實遠端音軌是會議伺服器把每人各自降噪、自動增益後混好的單軌，音量較平均（推論）。
- 編碼：只模擬 Opus 24 kbit/s 一種，沒有封包遺失、抖動緩衝、各平台不同的降噪與回音消除。
- 場景：AliMeeting 是同一間會議室面對面開會，Eval 每場最多 4 人；真實線上會議可能更多人，而且每個人的麥克風、房間不同。這點反而讓真實會議的說話者比較好分（推測），但跨場次的聲紋比對會比本評測難（見聲紋一節）。
- 訓練資料重疊：見「結論」。

### 參考標註與音訊對齊檢查

`prepare.py` 把參考語音遮罩與音訊能量做互相關，找出 ±5 秒內最吻合的位移（實測）：

- `nearmix`、`nearmix_opus`：0.00–0.10 秒。
- `far`：0.00–0.16 秒（聲音傳到陣列的延遲加上標註誤差）。
- 全部都正相關（0.24–0.51），沒有反向或錯場。位移都小於 collar 0.25 秒，不做修正。

## 結果總表（8 場合計）

| 引擎 | 條件 | DER c0 | DER c0.25 | 漏判 | 誤判 | 混淆 | 略過重疊 DER | 重疊區 DER | 重疊召回 | 重疊精確 | 人數正確 | RTF |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pyannote community-1（FluidAudio Offline） | far | 23.18 | 17.18 | 9.67 | 1.72 | 5.79 | 6.47 | 43.56 | 53% | 90% | 7/8 | 0.0095 |
| pyannote community-1（FluidAudio Offline） | nearmix | 29.20 | 22.85 | 17.33 | 0.34 | 5.19 | 13.01 | 47.85 | 46% | 96% | 7/8 | 0.0136 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | 26.31 | 20.19 | 14.17 | 0.51 | 5.51 | 9.81 | 46.21 | 50% | 95% | 7/8 | 0.0095 |
| pyannote community-1（FluidAudio Offline） | concat8 | 32.56 | 27.11 | 16.72 | 0.57 | 9.81 | 10.61 | 49.54 | 54% | 96% | 1/2 | 0.0114 |
| Nemotron-3 offline | far | 17.44 | 12.13 | 11.18 | 0.70 | 0.25 | 8.80 | 24.38 | 66% | 96% | 8/8 | 0.0020 |
| Nemotron-3 offline | nearmix | 15.34 | 10.70 | 10.25 | 0.30 | 0.16 | 7.98 | 20.78 | 71% | 97% | 8/8 | 0.0021 |
| Nemotron-3 offline | nearmix_opus | 15.30 | 10.68 | 10.15 | 0.33 | 0.19 | 7.94 | 20.79 | 71% | 98% | 8/8 | 0.0021 |
| Nemotron-3 offline | concat8 | 16.73 | 13.83 | 12.83 | 0.38 | 0.63 | 10.22 | 21.39 | 73% | 98% | 2/2 | 0.0024 |
| Nemotron-3 fast32 | far | 19.06 | 13.76 | 11.29 | 0.70 | 1.77 | 10.54 | 25.76 | 66% | 95% | 7/8 | 0.0079 |
| Nemotron-3 fast32 | nearmix | 15.35 | 10.71 | 10.14 | 0.32 | 0.25 | 8.05 | 20.64 | 72% | 97% | 8/8 | 0.0071 |
| Nemotron-3 fast32 | nearmix_opus | 15.44 | 10.80 | 10.18 | 0.33 | 0.29 | 8.11 | 20.86 | 71% | 98% | 8/8 | 0.0116 |
| Sortformer v2（highContextV2） | far | 14.08 | 8.78 | 5.24 | 2.34 | 1.20 | 4.85 | 22.13 | 75% | 88% | 6/8 | 0.0059 |
| Sortformer v2（highContextV2） | nearmix | 10.85 | 6.07 | 4.23 | 1.18 | 0.65 | 2.82 | 17.64 | 82% | 92% | 8/8 | 0.0059 |
| Sortformer v2（highContextV2） | nearmix_opus | 11.27 | 6.38 | 4.36 | 1.26 | 0.75 | 2.98 | 18.45 | 80% | 92% | 7/8 | 0.0059 |
| Sortformer v2（highContextV2） | concat8 | 53.31 | 51.40 | 11.42 | 2.20 | 37.78 | 48.24 | 46.52 | 79% | 93% | 0/2 | 0.0079 |
| LS-EEND（AMI 版） | far | 86.80 | 85.12 | 80.57 | 1.00 | 3.55 | 81.33 | 94.17 | 0% | 92% | 1/8 | 0.0146 |
| LS-EEND（AMI 版） | nearmix | 26.81 | 21.92 | 4.78 | 7.29 | 9.84 | 18.57 | 32.23 | 79% | 78% | 4/8 | 0.0189 |
| LS-EEND（AMI 版） | nearmix_opus | 26.18 | 21.09 | 3.57 | 7.55 | 9.97 | 17.37 | 31.83 | 80% | 76% | 5/8 | 0.0186 |

漏判、誤判、混淆皆為 collar 0.25。所有數字都是實測。

### 補上 0.5 秒內同一說話者空隙後

| 引擎 | 條件 | DER c0 | DER c0.25 | 漏判 | 誤判 | 混淆 |
|---|---|---|---|---|---|---|
| pyannote community-1（FluidAudio Offline） | far | 23.41 | 17.37 | 9.54 | 2.02 | 5.82 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | 25.18 | 19.24 | 13.00 | 0.67 | 5.58 |
| Nemotron-3 offline | far | 12.63 | 8.09 | 6.99 | 0.85 | 0.25 |
| Nemotron-3 offline | nearmix_opus | 10.26 | 6.54 | 5.88 | 0.48 | 0.18 |
| Nemotron-3 fast32 | far | 14.36 | 9.90 | 7.19 | 0.87 | 1.84 |
| Nemotron-3 fast32 | nearmix_opus | 10.42 | 6.68 | 5.91 | 0.48 | 0.29 |
| Sortformer v2（highContextV2） | far | 13.88 | 8.60 | 4.50 | 2.90 | 1.21 |
| Sortformer v2（highContextV2） | nearmix_opus | 10.92 | 6.03 | 3.48 | 1.79 | 0.77 |

## 解讀

- **混淆率是「誰說了什麼」的核心指標。** 在 `nearmix_opus`：Nemotron-3 offline 0.19%、Sortformer v2 0.75%、pyannote community-1 5.51%、LS-EEND 9.97%（實測）。略過重疊區後，pyannote community-1 的混淆率剩 1.98%（實測），代表它的混淆大多發生在重疊區附近（推論）。
- **重疊語音。** pyannote community-1 只抓到參考重疊時間的 50%，重疊區 DER 46%；Nemotron-3 offline 抓到 71%，重疊區 DER 21%；Sortformer v2 抓到 80%，重疊區 DER 18%（皆實測，`nearmix_opus`）。三者標成重疊的地方 92–98% 確實是重疊（實測）。spec 說「遠端多人重疊只能標記、無法可靠分離」，以 Nemotron-3 來看，標記是可靠的，但約三成重疊會漏標（推論）。
- **說話者數量。** 沒有任何引擎拿到正確人數：pyannote community-1 的 `numSpeakers`／`minSpeakers`／`maxSpeakers` 都保持預設 `nil`；Sortformer、Nemotron-3、LS-EEND 本來就沒有人數參數，只有模型的槽位上限（4、8、10）（已讀 `swift/Sources/diareval/main.swift` 與 FluidAudio 0.18.3 原始碼確認）。pyannote community-1 在 R8007_M8010 把 4 人估成 3 人（三種條件都一樣），這場有一位只說 530 秒的人被拆散到三個群（實測）。Nemotron-3 fast32 在 `far` 的 R8008_M8013 把 3 人估成 4 人，混淆率 10.8%；offline 預設沒有這個問題（實測）。
- **遠場 vs 近場。** pyannote community-1 在 `nearmix` 反而比 `far` 差（DER c0 29.2% vs 23.2%），差距幾乎全在漏判（實測）。原因沒有查清；近乎無聲的停頓只能解釋約 58% 的漏判時間（實測），其餘可能是頭戴麥克風相加造成的疊音或乾聲（推測）。另外三個模型都是近場比較好（實測）。
- **Opus 編碼的影響很小。** 三個主要候選在 `nearmix` 與 `nearmix_opus` 之間 DER 差距都在 0.4 個百分點以內，pyannote community-1 甚至變好 2.9 個百分點（實測）。
- **LS-EEND（AMI 版）不適用。** 遠場有 2 場輸出 0 位說話者、漏判 80.6%，近場混淆率約 10%（實測）。遠場失效的原因沒有追（推測與輸入音量或 `finalizedSegments` 有關）。
- **與公開數字對照。** pyannote 官方 README 的 benchmark 表（2025-09）列 community-1 在 AliMeeting（channel 1）的 DER 為 20.3%。本評測同一個模型的 Core ML 版本在 `far`（陣列第 0 聲道，即 1-based 的 channel 1）collar 0 為 23.18%（實測）。兩者差 2.9 個百分點，公開數字用的是哪個分割、哪種 collar 沒有寫明，Test 與 Eval 也不同場，所以只能說同一數量級，轉換後的模型與這套評分沒有明顯錯誤（推論）。

## 每場結果

pyannote community-1、Sortformer v2、Nemotron-3 offline 在 `far` 與 `nearmix_opus` 的逐場數字（實測）。完整數字在 `out/<引擎>/score_<條件>.txt`。漏判、誤判、混淆為 collar 0.25。

| 引擎 | 條件 | 場次 | 說話者 參考/系統 | DER c0 | DER c0.25 | 漏判 | 誤判 | 混淆 | 重疊區 DER | 重疊召回 | RTF |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pyannote community-1（FluidAudio Offline） | far | R8001_M8004 | 4/4 | 25.8 | 20.5 | 12.5 | 0.9 | 7.2 | 43.8 | 53% | 0.0124 |
| pyannote community-1（FluidAudio Offline） | far | R8003_M8001 | 4/4 | 20.3 | 14.4 | 8.0 | 3.3 | 3.1 | 41.0 | 45% | 0.0132 |
| pyannote community-1（FluidAudio Offline） | far | R8007_M8010 | 4/3 | 40.4 | 36.5 | 20.7 | 0.9 | 15.0 | 47.6 | 64% | 0.0095 |
| pyannote community-1（FluidAudio Offline） | far | R8007_M8011 | 4/4 | 24.6 | 17.6 | 8.1 | 1.7 | 7.9 | 43.4 | 60% | 0.0083 |
| pyannote community-1（FluidAudio Offline） | far | R8008_M8013 | 3/3 | 24.8 | 18.6 | 9.5 | 2.3 | 6.7 | 47.5 | 29% | 0.0098 |
| pyannote community-1（FluidAudio Offline） | far | R8009_M8018 | 2/2 | 14.4 | 8.6 | 5.2 | 2.2 | 1.3 | 42.9 | 18% | 0.0071 |
| pyannote community-1（FluidAudio Offline） | far | R8009_M8019 | 2/2 | 11.0 | 6.7 | 4.9 | 1.5 | 0.3 | 21.3 | 59% | 0.0081 |
| pyannote community-1（FluidAudio Offline） | far | R8009_M8020 | 2/2 | 9.9 | 5.1 | 3.7 | 1.0 | 0.4 | 34.9 | 32% | 0.0072 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8001_M8004 | 4/4 | 29.0 | 24.4 | 16.8 | 0.2 | 7.4 | 45.2 | 53% | 0.0105 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8003_M8001 | 4/4 | 22.2 | 16.7 | 10.0 | 1.7 | 5.0 | 42.9 | 50% | 0.0078 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8007_M8010 | 4/3 | 43.6 | 40.4 | 25.7 | 0.2 | 14.5 | 52.1 | 55% | 0.0083 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8007_M8011 | 4/4 | 27.2 | 20.9 | 11.4 | 0.4 | 9.2 | 46.2 | 57% | 0.0156 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8008_M8013 | 3/3 | 24.4 | 19.3 | 17.3 | 0.2 | 1.8 | 46.1 | 31% | 0.0104 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8009_M8018 | 2/2 | 13.2 | 7.8 | 6.7 | 0.8 | 0.4 | 40.1 | 24% | 0.0084 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8009_M8019 | 2/2 | 18.6 | 11.6 | 10.2 | 0.6 | 0.8 | 25.9 | 55% | 0.0084 |
| pyannote community-1（FluidAudio Offline） | nearmix_opus | R8009_M8020 | 2/2 | 18.8 | 10.7 | 9.7 | 0.0 | 1.0 | 38.2 | 31% | 0.0071 |
| Sortformer v2 | far | R8001_M8004 | 4/4 | 15.3 | 10.7 | 7.0 | 2.5 | 1.2 | 22.8 | 74% | 0.0058 |
| Sortformer v2 | far | R8003_M8001 | 4/4 | 17.7 | 12.9 | 5.6 | 3.7 | 3.6 | 25.3 | 69% | 0.0061 |
| Sortformer v2 | far | R8007_M8010 | 4/4 | 19.4 | 14.4 | 10.9 | 2.1 | 1.4 | 22.3 | 82% | 0.0058 |
| Sortformer v2 | far | R8007_M8011 | 4/4 | 12.4 | 6.5 | 3.1 | 2.4 | 1.1 | 19.4 | 82% | 0.0058 |
| Sortformer v2 | far | R8008_M8013 | 3/4 | 17.4 | 11.5 | 6.4 | 3.7 | 1.4 | 29.1 | 54% | 0.0059 |
| Sortformer v2 | far | R8009_M8018 | 2/3 | 10.0 | 5.0 | 1.5 | 3.4 | 0.1 | 18.6 | 64% | 0.0059 |
| Sortformer v2 | far | R8009_M8019 | 2/2 | 8.0 | 2.9 | 2.4 | 0.4 | 0.0 | 10.7 | 79% | 0.0059 |
| Sortformer v2 | far | R8009_M8020 | 2/2 | 6.7 | 2.3 | 2.2 | 0.2 | 0.0 | 21.5 | 57% | 0.0060 |
| Sortformer v2 | nearmix_opus | R8001_M8004 | 4/4 | 11.9 | 7.9 | 5.2 | 1.9 | 0.7 | 17.5 | 80% | 0.0059 |
| Sortformer v2 | nearmix_opus | R8003_M8001 | 4/4 | 10.6 | 5.7 | 4.2 | 1.2 | 0.3 | 20.5 | 73% | 0.0059 |
| Sortformer v2 | nearmix_opus | R8007_M8010 | 4/4 | 16.7 | 11.8 | 8.8 | 1.9 | 1.2 | 18.9 | 86% | 0.0058 |
| Sortformer v2 | nearmix_opus | R8007_M8011 | 4/4 | 14.0 | 8.6 | 2.9 | 2.8 | 2.9 | 21.3 | 84% | 0.0058 |
| Sortformer v2 | nearmix_opus | R8008_M8013 | 3/4 | 12.2 | 7.6 | 7.0 | 0.3 | 0.3 | 19.6 | 70% | 0.0059 |
| Sortformer v2 | nearmix_opus | R8009_M8018 | 2/2 | 7.4 | 2.8 | 1.7 | 1.1 | 0.0 | 17.5 | 65% | 0.0058 |
| Sortformer v2 | nearmix_opus | R8009_M8019 | 2/2 | 6.2 | 1.6 | 1.1 | 0.6 | 0.0 | 6.8 | 87% | 0.0059 |
| Sortformer v2 | nearmix_opus | R8009_M8020 | 2/2 | 5.9 | 1.6 | 1.3 | 0.2 | 0.1 | 16.7 | 67% | 0.0058 |
| Nemotron-3 offline | far | R8001_M8004 | 4/4 | 18.2 | 15.1 | 14.4 | 0.5 | 0.2 | 24.2 | 66% | 0.0020 |
| Nemotron-3 offline | far | R8003_M8001 | 4/4 | 18.4 | 15.3 | 12.7 | 2.4 | 0.2 | 25.3 | 62% | 0.0021 |
| Nemotron-3 offline | far | R8007_M8010 | 4/4 | 22.0 | 18.0 | 17.2 | 0.2 | 0.5 | 25.1 | 72% | 0.0021 |
| Nemotron-3 offline | far | R8007_M8011 | 4/4 | 13.2 | 9.9 | 9.4 | 0.2 | 0.3 | 18.9 | 76% | 0.0020 |
| Nemotron-3 offline | far | R8008_M8013 | 3/3 | 17.5 | 14.1 | 13.2 | 0.7 | 0.3 | 25.2 | 58% | 0.0020 |
| Nemotron-3 offline | far | R8009_M8018 | 2/2 | 16.7 | 9.2 | 7.5 | 1.3 | 0.4 | 35.7 | 35% | 0.0020 |
| Nemotron-3 offline | far | R8009_M8019 | 2/2 | 16.3 | 6.6 | 6.3 | 0.2 | 0.0 | 19.8 | 64% | 0.0020 |
| Nemotron-3 offline | far | R8009_M8020 | 2/2 | 14.6 | 5.1 | 5.0 | 0.0 | 0.0 | 31.2 | 45% | 0.0020 |
| Nemotron-3 offline | nearmix_opus | R8001_M8004 | 4/4 | 16.8 | 14.2 | 13.4 | 0.5 | 0.2 | 21.6 | 69% | 0.0021 |
| Nemotron-3 offline | nearmix_opus | R8003_M8001 | 4/4 | 14.9 | 12.5 | 11.7 | 0.6 | 0.2 | 21.8 | 67% | 0.0021 |
| Nemotron-3 offline | nearmix_opus | R8007_M8010 | 4/4 | 18.5 | 15.8 | 15.0 | 0.4 | 0.4 | 21.0 | 77% | 0.0020 |
| Nemotron-3 offline | nearmix_opus | R8007_M8011 | 4/4 | 12.3 | 9.6 | 8.9 | 0.3 | 0.4 | 17.0 | 78% | 0.0020 |
| Nemotron-3 offline | nearmix_opus | R8008_M8013 | 3/3 | 15.6 | 13.5 | 13.2 | 0.2 | 0.1 | 20.4 | 66% | 0.0021 |
| Nemotron-3 offline | nearmix_opus | R8009_M8018 | 2/2 | 11.0 | 5.8 | 5.2 | 0.5 | 0.0 | 22.0 | 59% | 0.0021 |
| Nemotron-3 offline | nearmix_opus | R8009_M8019 | 2/2 | 15.9 | 5.4 | 5.2 | 0.2 | 0.0 | 19.2 | 65% | 0.0021 |
| Nemotron-3 offline | nearmix_opus | R8009_M8020 | 2/2 | 14.9 | 4.9 | 4.9 | 0.0 | 0.0 | 29.8 | 48% | 0.0021 |

## 處理速度

RTF 皆為實測、單次執行。4.3 小時的 `nearmix_opus` 全部處理完：Nemotron-3 offline 約 33 秒（RTF 0.0021，約 480 倍即時），Sortformer v2 約 92 秒，pyannote community-1 約 2.5 分鐘（RTF 0.0095）。換算一場 60 分鐘會議：Nemotron-3 offline 約 8 秒，pyannote community-1 約 35–50 秒（推論）。FluidAudio 文件說 Nemotron-3 `offline` 預設只能跑在 GPU（ANE 編譯器限制），`fast32` 可以走 ANE；本評測兩者都用預設 compute units。

## 聲紋向量（跨場次辨識可行性）

App 需要每個群至少一個聲紋向量。

- pyannote community-1 Offline 管線有：`DiarizationResult.speakerDatabase` 給每群一個 256 維向量，`OfflineDiarizerManager.embedSpans(audioSource:spans:)` 可以對任意時間區段抽同一種向量（已讀 FluidAudio 0.18.3 原始碼確認）。
- Sortformer、Nemotron-3、LS-EEND 沒有對外的聲紋向量。所以若用 Nemotron-3 分群，就要把每群的非重疊片段丟給 `embedSpans` 另外抽（本評測就是這樣做，見下方）。

### 方法

AliMeeting Eval 沒有人出現在兩場，無法直接量「同一人、不同場會議」。改用兩種代理：

1. **片段層級。** 從參考標註取出只有一人說話的區段，切成 2–8 秒，每種條件 2,026 段。同一人取時間相距 60 秒以上的兩段為正例，同場不同人與不同場的人為反例。
2. **聲紋層級（較接近 App）。** 每人用會議前半最多 60 秒乾淨語音的平均向量當「已存聲紋」，後半最多 60 秒的平均向量當「新會議的群」。同場前後半內容不重疊，但麥克風與房間相同，所以這是偏樂觀的代理。`nearmix→far` 這組讓存檔與比對用不同麥克風，模擬換了收音環境。25 位說話者中 24 位兩半都有語音，所以正例 24 組、反例 576 組。存檔語音最少 17 秒，比對最少 4 秒。

### 結果（cosine 相似度，皆實測）

片段層級（單段 2–8 秒）：

| 條件 | 反例對象 | EER | 正例中位數 | 反例中位數 | 反例最大值 | FAR 1% 門檻（FRR） | FAR 0.1% 門檻（FRR） |
|---|---|---|---|---|---|---|---|
| far | 同場其他人 | 4.95% | 0.577 | 0.122 | 0.583 | 0.415（11.9%） | 0.484（24.0%） |
| nearmix | 同場其他人 | 1.18% | 0.697 | 0.153 | 0.611 | 0.449（1.3%） | 0.520（4.9%） |
| nearmix_opus | 同場其他人 | 1.76% | 0.675 | 0.157 | 0.606 | 0.460（2.7%） | 0.536（9.6%） |
| nearmix_opus | 其他場的人 | 1.30% | 0.675 | 0.122 | 0.595 | 0.437（1.7%） | 0.519（7.4%） |

聲紋層級（前半最多 60 秒 → 後半最多 60 秒）：

| 存檔 → 比對 | 正例最小值 | 正例 5 百分位 | 正例中位數 | 同場反例最大值 | 所有反例最大值 | 完全分開 |
|---|---|---|---|---|---|---|
| nearmix → nearmix | 0.860 | 0.905 | 0.940 | 0.514 | 0.561 | 是 |
| nearmix_opus → nearmix_opus | 0.865 | 0.895 | 0.941 | 0.527 | 0.589 | 是 |
| far → far | 0.828 | 0.842 | 0.918 | 0.505 | 0.585 | 是 |
| nearmix → nearmix_opus | 0.863 | 0.866 | 0.929 | 0.517 | 0.570 | 是 |
| nearmix → far（換麥克風） | 0.586 | 0.663 | 0.858 | 0.512 | 0.563 | 是，但只差 0.023 |

分群結果的群向量對上「`nearmix` 前半聲紋」（群依 DER 最佳對應指派到參考說話者）：

| 群向量來源 | 正例最小值 | 正例中位數 | 反例中位數 | 反例最大值 |
|---|---|---|---|---|
| pyannote community-1 `speakerDatabase`，`far` | 0.635 | 0.892 | 0.151 | 0.585 |
| pyannote community-1 `speakerDatabase`，`nearmix_opus` | 0.914 | 0.951 | 0.179 | 0.607 |
| Nemotron-3 offline 群的非重疊片段 → `embedSpans` 平均，`far` | 0.668 | 0.902 | 0.154 | 0.576 |
| Nemotron-3 offline 群的非重疊片段 → `embedSpans` 平均，`nearmix_opus` | 0.927 | 0.959 | 0.173 | 0.558 |

群向量涵蓋整場，和前半聲紋有內容重疊，比上表更樂觀（推論）。重點是兩件事都成立：`speakerDatabase` 和 `embedSpans` 在同一個向量空間；「Nemotron-3 分群＋WeSpeaker 抽聲紋」的組合可行（實測）。

### 門檻建議（推論）

App 有兩道門檻：高於「自動命名」門檻直接套名字，介於兩者之間只產生建議，低於「建議」門檻維持 A/B/C。

- **自動命名：0.70 左右（建議範圍 0.65–0.75）。** 所有條件下，不同人的聲紋最高 0.611（片段層級）／0.607（群向量）（實測）。0.70 比它高約 0.09。同麥克風的正例最低 0.828，所以同環境下的同一人幾乎都會自動命名（實測）；換麥克風時有約 5–10% 的人落到 0.70 以下（正例 5 百分位 0.663），會變成「建議」而不是錯誤命名（推論）。
- **建議：0.50 左右（建議範圍 0.45–0.55）。** 反例中位數 0.10–0.18，99 百分位 0.39–0.46（實測）。0.50 以上就提示，誤報率約 0.1–0.3%（片段層級，推論），換麥克風的同一人（最低 0.586）仍在建議區內。
- 比對時用「每人所有已存聲紋的最大相似度」，聲紋庫人數越多，誤配機率越高，大約隨人數線性增加（推論）。
- 聲紋至少用 20–60 秒的乾淨語音平均；單段 2–8 秒的分數散得多（正例 5 百分位只有 0.50），不應該單獨拿來自動命名（實測）。
- 以上只有 25 人、24 組正例，而且是同場前後半，不是真的跨場。門檻請在拿到 3–5 段真實會議後重量（推論）。

## 授權

| 元件 | 授權 | 查證來源 | 與 AGPL-3.0 App 的相容性 |
|---|---|---|---|
| FluidAudio SDK 0.18.3 | Apache-2.0 | GitHub API `license.spdx_id` | 相容（Apache-2.0 可併入 GPLv3／AGPLv3 作品，這是 FSF 的公開立場；推論） |
| FluidAudio 的 NemoTextProcessing 二進位依賴 | 未查 | — | 本評測用 SwiftPM trait `["Diarizer"]` 沒有連結它；App 也應該這樣做，避免多一個二進位授權要查 |
| pyannote community-1 Core ML（`FluidInference/speaker-diarization-coreml`） | CC-BY-4.0（repo 的 `NOTICE.md` 指定範圍），PLDA 來自 BUT Speech@FIT，同為 CC-BY-4.0 | HF API、`NOTICE.md`、`PROVENANCE.md` | 模型權重是資料不是程式碼，執行時下載，需在 App 內標示 pyannote、WeSpeaker、BUT、Fluid Inference 與 CC-BY-4.0 連結（推論） |
| 上游 `pyannote/speaker-diarization-community-1` | CC-BY-4.0，但 HF 上需登入並同意條件（`gated: auto`） | HF API | 同意條件的內容需登入才能看，本機沒有 token，無法查證；FluidInference 未設權限轉散布（實測），是否受上游同意條件約束無法確認（推測：CC-BY-4.0 本身允許轉散布） |
| Nemotron-3-Diarization（NVIDIA 原版與 FluidInference Core ML 版） | OpenMDW-1.1 | HF API、OpenMDW 官方 GitHub 全文 | 寬鬆授權：可使用、修改、散布，散布時附上授權全文與原有聲明；對他人提出專利或著作權訴訟則權利終止；對輸出沒有限制。與 AGPL 不衝突（推論） |
| Sortformer 4spk v2（本評測用的 highContextV2） | CC-BY-4.0 | HF API | 同 CC-BY-4.0；注意 v2.1 系列權重是 NVIDIA Open Model License，條款不同 |
| LS-EEND Core ML | MIT | HF API | 相容 |
| AliMeeting | CC BY-SA 4.0 | OpenSLR 頁面 | 只用於評測，不隨 App 散布 |

以上不是法律意見。

## 驗證清單（排除量到別的東西）

| 風險 | 怎麼排除 | 狀態 |
|---|---|---|
| 用錯聲道 | `far` 明確取 8 聲道陣列的第 0 聲道；`nearmix` 前先確認每場的 TextGrid 說話者層與頭戴麥克風檔案一一對應（`prepare.py` 中的 assert） | 實測通過 |
| 取樣率不符 | 所有音訊寫成 16 kHz 單聲道 PCM16；`diareval` 讀檔前檢查格式，不是 16 kHz 單聲道就報錯；FluidAudio 各模型的 16 kHz 需求來自其原始碼與文件 | 實測通過 |
| 參考與音訊時間偏移 | 參考語音遮罩對音訊能量的互相關，最佳位移 0.00–0.16 秒，全部正相關 | 實測通過 |
| 只評到檔案一部分 | UEM 從 0 到標註結束；參考最後一段結束時間對 UEM 結束的比例 ≥ 0.999；系統輸出的最後時間對參考最後時間的比例 ≥ 0.993（LS-EEND `far` 例外，那是模型失效） | 實測通過 |
| 正確人數洩漏給模型 | 沒有傳任何人數參數，見「解讀」 | 已讀程式碼確認 |
| 評分工具本身 | 用 `pyannote.metrics` 4.2.0；同一模型在 `far` 的 DER 與 pyannote 公開數字同一數量級 | 推論 |
| 暖機與模型編譯算進 RTF | 每個引擎先跑 60 秒暖機；模型準備在計時之外 | 實測通過 |
| 測到在 Mac 以外的作業系統行為 | 只在 macOS 27 測過；FluidAudio 文件記載 macOS 14 上 Core ML BNNS 路徑會當機（Offline 管線），App 目標是 macOS 14.2+ | **未驗證**，見下 |

## 未驗證與阻擋

- **Python pyannote 基準線：被擋。** `pyannote/speaker-diarization-community-1`、`pyannote/speaker-diarization-3.1`、`pyannote/segmentation-3.0` 在 Hugging Face 都需要登入並同意條件（HF API 回傳 `gated: auto`），本機沒有 HF token（`~/.cache/huggingface/token` 不存在，環境變數也沒有）。解除方式：在 HF 網頁同意 community-1 的使用條件，然後在本目錄執行時設定 `HF_TOKEN`。它的價值有限：FluidAudio 的 Offline 管線就是 community-1 的 Core ML 轉換版，FluidAudio 在 AMI ES2004a 上做過輸出對照；跑 Python 版主要是確認轉換沒有掉準度。
- **真實會議：沒有。** 這是最大的缺口。中英夾雜、台灣口音、Meet／Teams／Zoom／Webex 的實際編碼與降噪、超過 4 人的真實輪流發言、真正跨場次的同一人，都沒有量到。
- **macOS 14：沒有測。** FluidAudio 文件說 macOS 14（至少到 14.8.7）的 Core ML BNNS 錯誤會讓 Offline 分群管線當機，macOS 15 起修好。App 若維持 macOS 14.2+，要在 macOS 14 實機測過 Nemotron-3 與 `embedSpans`，否則考慮把最低版本提高到 macOS 15。
- **重複性：** 每個組合只跑一次，沒有量變異。Core ML 推論是決定性的，DER 應該可重現（推論）；RTF 會隨機器負載變動（實測差到 1.5 倍）。

## 下一步

1. **用 3–5 段使用者自己的會議過門檻。** 用 mm2t 錄下遠端音軌（或直接從 Meet／Teams 錄影抽音軌），人工標說話者區段（每場 20–30 分鐘），照 README「換成自己的會議錄音」跑 `nemotron3-offline` 與 `offline`。建議的及格線：混淆率 < 3%、人數正確、`--fill-gaps 0.5` 後 DER c0.25 < 15%（推測，依本評測數字與「誰說了什麼」的產品需求訂的）。
2. **真實跨場次聲紋。** 同一批人錄兩場以上，重量兩道門檻。
3. 若 Nemotron-3 在真實會議上明顯退步，第二順位是 pyannote community-1 Offline 管線，可試 `segmentation.stepRatio 0.1`（FluidAudio 文件說對快速輪流發言較好），並依真實資料調 `clustering.threshold`。
4. 在 macOS 14 實機確認不會當機。
