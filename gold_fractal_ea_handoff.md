# Gold Fractal Breakout EA — 引き継ぎメモ

## 概要

MQL5 CodeBase の EA「Gold MT5 Fractal Breakout EA」をダウンロードし、
ローカルの MetaTrader 5 (macOS版) の Experts フォルダに配置済み。

- 出典: https://www.mql5.com/en/code/78308
- 作者: chen guang (rbot.cc)
- 公開: 2026-10-12 / 更新: 2026-10-13
- コード内部名: "Gold X9 strategy" / コメント名 "GoldX9 strategy 9"

## ファイルの場所

| 用途 | パス |
|---|---|
| ダウンロード元コピー | `/Users/dee/Gold_Fractal_Breakout_EA.mq5` |
| MT5配置済み(コンパイル対象) | `/Users/dee/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/Gold_Fractal_Breakout_EA.mq5` |

- サイズ 30,874 bytes / 631行、CRLF、ASCII
- MT5アプリ本体: `/Applications/MetaTrader 5.app` (インストール済み)
- このMacのMT5はWineラッパー構成のため、CLIでのヘッドレスコンパイル経路なし。
  コンパイルは MT5起動 → F4 (MetaEditor) → F7 が確実。

## EAの仕組み(コードから確認済み)

- **戦略**: スイングハイ/ローのブレイクアウトを狙う逆指値(BuyStop/SellStop)EA
- **構造検出**: 独自実装(`IsSwingHigh`/`IsSwingLow`)、iFractals不使用。
  左右各5本(デフォルト)の隣接バーより厳密に高い/安いバーを探索
- **タイムフレーム**: H1固定(`InpFractalTF`はconst、入力変更不可)。チャート/テスター期間とは独立
- **スキャン間隔**: 15分毎(`InpRescanMinutes`)、tick駆動
- **エントリー**: スイング ± オフセット%(デフォルト-0.10% = ブレイク前の先行エントリー)。
  クリアランス0.02%未満なら見送り、100ポイント以内の重複注文もスキップ
- **エグジット**: 全て%ベース。SL 2% / TP 1%、BE(0.10%発動→0.025%ロック)、
  トレーリング(0.20〜1.00%の利益レンジ内のみ)、サルベージ(-1%でTPを-0.15%へ移動)
- **サイジング**: 固定ロット or エクイティリスク%(`InpLotMode`)
- **制限**: 同シンボルにポジションがあれば新規エントリー全ブロック(Magic問わず)、
  約定後に残りの自EA逆指値をキャンセル

## 既知の注意点

- **実績根拠なし**: バックテスト証拠・最適パラメータ未検証(ページ明記)
- `InpPendingExpiryHours`は実装上GTCのみで時限失効は未実装(実装漏れ)
- `InpMaxPositions`は事実上無効(ポジション1つで全ブロックのため)
- サルベージ発動後のTPは元に戻らない
- 最低ロットへの切り上げでリスク見積もり超過の可能性あり

## 入力パラメータ(25個、デフォルト値)

Trade setup: InpMagic=900009, InpComment="GoldX9 strategy 9", InpLotMode=LOT_FIXED,
InpFixedLots=0.01, InpRiskPercent=0.50, InpMaxPending=3, InpMaxPositions=10,
InpPendingExpiryHours=15(未実装), InpDuplicatePoints=100

Structure: InpRescanMinutes=15, InpFractalLeft=5, InpFractalRight=5,
InpMaxSearchBars=200, InpMinFractalClearancePct=0.02

Entry/exits(%): InpBuyEntryOffsetPct=-0.10, InpSellEntryOffsetPct=-0.10,
InpStopLossPct=2.00, InpTakeProfitPct=1.00, InpTrailTriggerPct=0.20,
InpTrailDistancePct=0.20, InpMaxTrailPct=1.00, InpSalvageTriggerPct=1.00,
InpSalvageExitPct=0.15, InpBreakEvenTriggerPct=0.10, InpBreakEvenLockPct=0.025

## 依存

- `#include <Trade/Trade.mqh>` のみ(MT5標準ライブラリ、追加インストール不要)
- 外部インジケータ・DLL・Webサービス不使用

## 次のステップ(未実施)

1. MT5起動 → F4(MetaEditor) → Expertsツリーでファイルを開き F7 でコンパイル
   (作者報告: 0 errors / 0 warnings)
2. Navigator → Expert Advisors からチャートにアタッチ(想定シンボル: XAUUSD)
3. Strategy Tester でバックテスト(H1データ必須)
4. デモ口座でフォワード検証

## 話した内容の経緯

1. ユーザーがリンクを提示 → 「なんのEA?実装に必要なものは?」と質問
2. ページを解析して仕様・必要環境を回答
3. 「落としてみよう」→ curlで.mq5をダウンロード、MT5のExpertsへ配置
4. パスを質問 → 2箇所を回答
5. 別のDevinに引き継ぎたい → このファイルを作成
