# 文字起こし検証（2026-09-07）

実装トラッカー: https://github.com/taiseimiyaji/meeting-agent/issues/30

`asr-comparison.json` は、このMac（macOS 26.6.2）で同一の約16.5秒の
日本語合成音声を各Providerで3回処理した結果。SpeechAnalyzerは約0.21〜0.32秒、
WhisperKit smallは初回約23.61秒、モデルを保持した2回目以降は約1.27秒だった。
文字誤り率はそれぞれ約3.8%と5.1%。数字の表記違いも誤りに含む。

これは1種類の合成音声を繰り返した小規模な確認であり、実会議の精度やライブ遅延の
保証ではない。p95も3サンプルのみ。residentMemoryBytesは呼出し元プロセスのRSSで、
Apple側の音声認識サービスなど別プロセスのメモリを含まないため、総メモリ比較には使わない。
時刻の正解ラベルを付けていないため、ASRの時刻ずれは未評価。

再現手順（リポジトリルート）:

```sh
swift run --package-path apps/macos MeetingVerification
mkdir -p /tmp/meeting-agent-evaluation
say -v Kyoko -f tools/evaluation/japanese-reference.txt -o /tmp/meeting-agent-evaluation/japanese.aiff
swift run --package-path apps/macos MeetingVerification prepare-analyzer
swift run --package-path apps/macos MeetingVerification prepare-whisper
swift run --package-path apps/macos MeetingVerification transcribe speech_analyzer /tmp/meeting-agent-evaluation/japanese.aiff 3 > /tmp/meeting-agent-evaluation/analyzer.jsonl
swift run --package-path apps/macos MeetingVerification transcribe whisperkit /tmp/meeting-agent-evaluation/japanese.aiff 3 > /tmp/meeting-agent-evaluation/whisper.jsonl
node tools/evaluation/compare-asr.mjs tools/evaluation/japanese-reference.txt /tmp/meeting-agent-evaluation/analyzer.jsonl /tmp/meeting-agent-evaluation/whisper.jsonl
```

検証用WhisperKitモデルは `~/Library/Caches/MeetingAgentVerification/Models` に保存する。
アプリ本体のモデル保存先とは独立している。

自動統合検証は、権限不要の音声取得テストダブルと実際のCAF／SQLiteを使用する。
認識失敗時の他トラック保全、再起動後の未処理区間だけの再開、サイレント音声、
時刻の空白、終了時の末尾、開いたままの音声ファイルの復旧、APIの録音中再処理拒否、
30分相当の2トラックの全5,760万入力サンプルの保全と区間連続性を確認する。
WebではDOMを描画し、保存通知・再接続・操作エラー表示を確認する。

実デバイスで30分連続収録し、マイク／システム音声の両方、長い無音後の再発話、
抜き差し・スリープ・アプリ再起動、画面更新を確認する受け入れ試験は未実施。
そのため #29 の実機評価条件は未完了として保持する。
