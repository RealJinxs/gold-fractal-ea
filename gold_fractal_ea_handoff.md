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

1. ~~MT5起動 → F4(MetaEditor) → Expertsツリーでファイルを開き F7 でコンパイル~~
   ✅ 2026-10-22 Windows版で実施済み(MetaEditor64.exe /compile CLI、0 errors/0 warnings)
2. ✅ XAUUSD,H1 チャートにアタッチ済み(MCP chart_add_expert、デフォルトパラメータ)
3. ~~Strategy Tester でバックテスト(H1データ必須)~~
   ✅ 2026-10-22 実施済み(下記「バックテスト結果」参照)
4. デモ口座でフォワード検証 ← 進行中(下記「残課題」)

## Windows環境での作業メモ(2026-10-22)

- MT5本体: `C:\Program Files\MetaTrader 5` (build 6276)、
  データフォルダ: `C:\Users\Dee\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075`
- **コンパイルはCLIで可能**: `"C:\Program Files\MetaTrader 5\MetaEditor64.exe" /compile:"<mq5の絶対パス>" /log:"<ログ出力パス>"`。
  ログはUTF-16。GUI不要。
- **MT5内蔵MCPサーバー**: `http://127.0.0.1:22346/mcp` (terminal) / `:22345` (metaeditor)。
  認証は `Authorization: Bearer <APIキー>`。APIキーは MT5 GUI の
  Tools → Options → MCP タブで確認可能(config/assistant.ini 内の値は暗号化済みで使えない)。
  67ツールあり: tester_run_backtest / chart_add_expert / get_trading_account_info 等。
- **口座**: 旧 `988033867` (Bitget-MT5-LIVE2表示、実体は期限切れデモ)は接続不可。
  新規 MetaQuotes-Demo デモ `5057696280` (名義 Dehi Lee、残高$100,000、hedging)に切替済み、接続OK。
- **バックテストは terminal64.exe /config でも MCP (tester_prepare_config→tester_run_backtest) でも可能**。
  MCPの方が進捗・レポート取得まで完結するので推奨。

## バックテスト結果(2026-10-22、初回デフォルトパラメータ)

- 条件: XAUUSD, H1, Every tick(生成ティック), 2025-10-21〜2026-10-21(約1年),
  初回証拠金 $10,000, レバレッジ 1:100, MetaQuotes-Demo
- 結果: **純利益 +$799.36 (+8.0%)** / PF 1.29 / 667トレード(勝率 88.6%=591勝76敗)
  / 最大DD $607(6.0%) / Sharpe 2.23 / Expected payoff $1.20
- 所見: 高勝率・小利確(TP1%/SL2%)型。連勝最大33回、連敗最大3回。
  ロング305/ショート362。トレード実行系は全て正常(逆指値発注・約定・BE移動・
  残り逆指値キャンセル全て確認済み、エラーなし)。
- レポート保存: `MQL5\Files\gold_fractal_xauusd_backtest.xlsx`

## フォワードテスト稼働中(2026-10-22 01:31〜)

- デモ口座 `5057696280` (MetaQuotes-Demo、$100,000) で EA 稼働中
- 初回注文: **SELL_STOP 0.01 XAUUSD @ 4110.12** (SL 4192.32 / TP 4069.02)、order #58994350475
- EAは15分毎に構造スキャン(InpRescanMinutes)

## トラブルシュート済み: 「AutoTrading disabled by client」(retcode 10027)

原因は**EA個別の「Allow Algo Trading」フラグ**(MCP chart_add_expert でアタッチすると OFF になる)。
解決手順:

1. ターミナル終了
2. `MQL5\Profiles\Charts\Default\chart04.chr` の `<expert>` ブロック内
   `expertmode=0` → `expertmode=1` に書き換え
3. `terminal64.exe /config:mt5_autotrade.ini` で起動
   (ini内容: `[Experts] Enabled=1 AllowLiveTrading=1`)
4. EA再初期化後のスキャンで正常発注(retcode=10009)

※ common.ini の [Experts] キーは通常起動では読まれない(Optionsの設定は暗号化された
  settings.ini に保存)。/config 起動時のみ有効。グローバル側の Algo Trading は
  最初から ON だった模様(experts_trade_allowed=true)。

## 残課題・注意点

- MCP の trade_* 系ツールは "trading is not permitted" で拒否中
  (mcp_trade_allowed=true でも別途 Assistant 権限がある模様。EA運用には影響なし)
- 最適化は未実施。tester_run_optimization で可能
- テスターの「every tick」は生成ティック。より厳密には real ticks モデル推奨
- 手動で MT5 を閉じた場合、EAは停止する。継続稼働させるにはターミナル起動状態を維持

## 話した内容の経緯

1. ユーザーがリンクを提示 → 「なんのEA?実装に必要なものは?」と質問
2. ページを解析して仕様・必要環境を回答
3. 「落としてみよう」→ curlで.mq5をダウンロード、MT5のExpertsへ配置
4. パスを質問 → 2箇所を回答
5. 別のDevinに引き継ぎたい → このファイルを作成
