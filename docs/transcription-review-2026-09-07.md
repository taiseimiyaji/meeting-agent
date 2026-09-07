# 文字起こし機能レビュー（2026-09-07）

対象: commit `9b7bc59`。音声取得、ライブ認識、音声保存、終了処理、再処理、DB、API、Web表示、要約・設定、テストを追跡した。実装変更は行っていない。

結論: 現状は会議全体の文字起こしを保証できない。認識エンジンの精度以前に、結果更新通知、タスク終了後の復帰、録音の保全、欠落検出に問題がある。AIだけ置換しても表示停止や録音欠落は解決しない。

## 優先度の高い指摘

### 1. P1: DBに文字が入ってもライブ表示が更新されない

`apps/web/src/App.tsx:86` のTranscriptクエリに定期取得がなく、更新はWebSocket通知に依存する。しかし `apps/macos/Sources/LocalAPI/APIRouter.swift:80` と `:84` が送るのはAPI経由の開始・停止のcaptureイベントのみ。Pipelineの保存や解析workerの完了から `LocalAPIServer.publish` への接続がない。

詳細画面を開いた後に発話しても再取得されず、復旧ジョブ完了時も進捗だけ更新されて本文が空のままになり得る。ネイティブUI経由の開始・停止もこの通知経路を通らない。Transcript・Screen・会議状態の変更を保存成功後に通知し、再接続時の再取得とポーリングによる補完が必要。

### 2. P1: 認識エラー・final後にタスクを再開しない

`apps/macos/Sources/MeetingCapture/Transcription.swift:135,177`。

開始時に一度だけrecognitionTaskを作り、callbackのerrorは即returnする。final受信時もrequest/taskを終了済みとして片付けず、新しいタスクを作らない。以後consumeはrequestの存在しか検査しない。認識サービスの終了・エラー後も録音中のまま文字が増えなくなる。

終了を検出する状態管理、エラー通知、期限付き再試行、認識区間ごとのIDと時刻オフセット、再開時の音声補完が必要。「必ず何秒で終了するか」はこの環境では未実測であり断定しない。

### 3. P1: STTが起動しなければ復旧用の録音も開始できない

`apps/macos/Sources/MeetingPipeline/MeetingPipeline.swift:85`。

両トラックのtranscriber.startが成功してからcapture.startする。端末内モデルが使えない、Speech権限がない、recognizerが利用不可のいずれでも会議全体がfailedになり、保存音声から復旧する前提が成立しない。captureConfigurationで無効にした音声トラックもSTTを開始している。

録音の必須条件とライブSTTの利用条件を分離し、STT不可でも録音・後処理待ちへ進める設計が必要。

### 4. P1: 一部だけ文字が残ると自動復旧しない

`apps/macos/Sources/MeetingPipeline/MeetingPipeline.swift:139`、`MeetingAnalysisRuntime.swift:61`。

復旧条件が会議全体のtranscripts.isEmpty。一方の音声だけ認識された、冒頭だけ認識後に停止したケースは復旧対象にならない。stop時にはpartialをfinalへ変更し、録音停止成功だけで会議をcompletedにするため、欠落が完了として扱われる。

トラック・音声区間単位の処理履歴と未処理区間を持ち、録音完了と文字起こし完了を分ける必要がある。無音を文字数の不足と誤判定しないことも必要。

### 5. P1: 保存音声からの復旧も単一障害で全体が失敗する

`apps/macos/Sources/MeetingPipeline/MeetingAnalysisRuntime.swift:108`、`apps/macos/Sources/MeetingCapture/OfflineTranscription.swift:53`。

復旧も同じApple Speechの端末内認識に固定されている。system.cafから順に処理し、1トラック／1チャンクのthrowで全体を中断する。後続の有効な音声を試せず、途中まで得た結果も保存しない。認識のcallback待ちにはタイムアウトとTaskキャンセル連携がなく、callbackが来ない場合は単一workerが止まり、他会議の要約・exportまで待たされる。

トラック・チャンクごとのチェックポイント、独立した失敗状態、タイムアウト、認識タスクの明示的な保持とキャンセル、プロバイダー交換が必要。

### 6. P1: 復旧用音声自体の欠落が観測できない

`apps/macos/Sources/MeetingCapture/ScreenCaptureKitAdapter.swift:20`、`apps/macos/Sources/MeetingPipeline/MeetingPipeline.swift:178`。

音声と映像が同じbufferingNewest(256)を共有する。consumerは画像処理も待つため、負荷でキューが溢れると保存前の音声も破棄され得る。音声yieldのdropは記録されず、archive.writeの失敗もtry?で破棄される。PCM変換失敗も音声件数自体は増える。件数やレベルメーターだけでは保存・認識成功を証明できない。

保存を画像処理から独立させ、音声の取得・変換・保存・認識への投入・結果受信を別々に計測する。ディスク書込失敗や形式変更をエラーとして保持する。

### 7. P2: 停止処理はdrain完了を保証していない

`apps/macos/Sources/MeetingPipeline/MeetingPipeline.swift:113,254`。

capture停止後100ms待ち、Speech停止とarchive.finishを行ってからeventTaskをcancelする。キューが100ms以上残ると末尾を捨てる。Speech最終結果も固定1秒で待ちを終了する。長い最終処理は取りこぼし、partialをfinalに昇格させて完了扱いになる。

音声producer終了→キューの処理完了→ファイルclose→STTの最終結果または明示的timeoutの順を、時間待ちではなく完了通知で管理する。

### 8. P2: 復旧後のタイムライン精度と既存結果の保護が不足

`OfflineTranscription.swift:24` は50秒で固定分割し、最後に全チャンクを1つの文字列に統合する。`MeetingAnalysisRuntime.swift:110` はトラック全体を1イベントとして保存する。チャンク境界の発話文脈や細かな時刻が失われる。archiveには最初の入力の会議時刻・入力欠落区間を保存していないため、ファイル時刻と会議時刻もずれる。

`apps/macos/Sources/LocalAPI/APIRouter.swift:133` は収録中でもtranscribeを受け付ける。再処理は `MeetingStore.replaceTranscripts` で既存Transcriptを全削除して置換するため、ライブ書込みとの競合や既存参照の消失につながる。収録中の再処理制限、結果の世代管理、区間単位での置換、要約の世代更新が必要。

### 9. P2: 収録異常とUI操作の失敗が十分表示されない

`ScreenCaptureKitAdapter.swift:160` のdidStopWithErrorはmetricsのエラー数を増やすだけでcontrollerの状態を更新しない。録画停止後もcapturingに見え得る。`apps/web/src/App.tsx:46` のHomeはstart/stop mutationのerrorとcapture.data.errorを表示していない。権限・対象ウィンドウ・STT起動エラーが利用者に伝わらない。

さらにWebからの開始はAgentViewModel.startを通らないため、そこで起動するDiagnosticsRecorderも開始しない。診断情報は共通controller/pipelineで記録する必要がある。

### 10. P2: 設定画面のProvider選択が実処理につながっていない

`apps/web/src/api.ts:77` の設定保存はlocalStorageとmock更新のみ。実際の要約は `MeetingAnalysisRuntime.swift:79` のHierarchicalHeuristicSummarizer固定で、画面のApple Foundation Models／Codex選択は実行経路に反映されない。保持日数設定もこの保存経路からバックエンドに渡らない。

機能全体として「選んだAIで処理された」という期待に応えられない。設定の永続化とバックエンド接続、実際のprovider/modelの表示が必要。

## 検証結果と限界

- Web: `npm test` の12件は成功。
- Webの `npm run build` とmacOSの `swift build` は成功。後者は不要なawaitと、macOS 14向けバイナリにmacOS 26向けHomebrew SQLiteをリンクする警告がある。旧OSへの配布互換性は未検証。
- 評価harnessとCodex helper: Nodeテスト3件は成功。
- `make test`: meeting-coreでXCTestが見つからず停止。
- macOS／meeting-analysisのswift testも個別に試し、XCTest／Testingが見つからず停止。選択中の開発環境はCommandLineToolsで、/ApplicationsにXcodeはない。
- 既存PipelineテストはFakeTranscriberから文字イベントを注入する。音声認識自体、1分超の認識継続、二重トラック、無音→発話、エラー後の復帰、DB更新→実画面更新を検証していない。録音テストもファイルの存在・サイズ確認にとどまる。
- このMacの通常のApplication Support/MeetingAgentは存在せず、sandbox container内のDBは会議・Transcript・ジョブとも0件、Meetingsディレクトリも空だった。この場所には失敗会議の録音・診断ログがない。過去の具体的な発生原因や音声品質を実測で確定したわけではない。
- 実音声でのE2E、認識精度、遅延の測定、クラウドへの音声送信は行っていない。

## 方式の提案

推奨する構成は「原音を確実に保存→区間ごとに文字起こし→会議終了後に欠落を補完」。まず10〜30秒程度の区間で準リアルタイム表示を成立させる。これは設計案であり、実測の遅延保証ではない。発話境界、区間の重なりと重複除去、会議時刻、再試行可能な音声IDを持つ。録音済み区間が残るため、プロバイダーが落ちても再処理できる。

| 候補 | 適用 | 判断 |
| --- | --- | --- |
| Apple SpeechAnalyzer / SpeechTranscriber | macOS 26系でのローカル認識候補 | Appleは長時間音声・会議・ライブ文字起こし向けとして説明している。現在の旧SFSpeechRecognizerと別実装。対象端末・日本語モデルの実際の利用可否を事前確認する。macOS 14対応を残すなら別経路が必要。 |
| WhisperKit | Apple Silicon上のローカル認識候補 | Swiftから録音ファイル・ストリーミングを扱える。モデル配布とメモリ・処理速度の実機評価が必要。まず保存音声で比較し、ライブ化する。 |
| OpenAI Transcription API | クラウドでのファイル／ライブ文字起こし候補 | ファイル処理とRealtime transcriptionが用意されている。API接続、費用、音声送信の設定が必要。現状のCAFは対応形式へ変換が必要。 |

根拠: [Apple SpeechAnalyzer解説](https://developer.apple.com/videos/play/wwdc2025/277/)、[WhisperKit公式リポジトリ](https://github.com/argmaxinc/argmax-oss-swift)、[OpenAIファイル文字起こし](https://developers.openai.com/api/docs/guides/speech-to-text)、[OpenAIリアルタイム文字起こし](https://developers.openai.com/api/docs/guides/realtime-transcription)。OpenAIファイルAPIの上限は25MBで、長時間録音は圧縮または分割が必要。各方式の日本語精度の優劣は未測定。

## 修正と受け入れ確認の順序

1. 更新通知・UI再取得・エラー表示を修正し、原音保存をSTT／画像処理から独立させる。
2. トラック・区間単位の処理状態、タイムアウト、再処理を実装する。空文字の有無だけで完了判定しない。
3. 同じ日本語音声でSpeechAnalyzerとWhisperKitを比較する。クラウド利用を選ぶ場合は同じ入力でAPIも比較する。
4. 30分以上の二重トラック、長い無音後の再発話、認識エラー、録音終了直前の発話、再起動復旧を検証する。音声区間欠落、文字誤り率、確定結果の遅延p95、時刻ずれ、メモリを記録する。
5. Web表示を開いたまま発話・停止・復旧し、手動リロードなしでDBの最新結果が表示されることを確認する。認識停止時は「収録継続／文字起こし復旧待ち」を表示する。

認識エンジンだけの差し替えを先に進めず、録音と結果の流れを直してから同一音声による比較で採用方式を決める。
