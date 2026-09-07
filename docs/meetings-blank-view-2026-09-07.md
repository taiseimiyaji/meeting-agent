# Meetingsタブ空白画面の調査（#32）

## 確認した状態

- 実行中アプリは9月3日起動、同じパスの実行ファイルは9月7日に更新されていた。
- 実行中プロセスで `SecTaskLoadEntitlements failed error=85` と `Bad executable (or shared library)` が発生。実行中の署名済みバンドルの上書きが確認できた。
- `http://127.0.0.1:8765/` はHTMLを200で返し、実際のWKWebViewでも配信されたReactアプリのroot描画を確認した。
- 旧EmbeddedWebViewにはnavigation失敗・WebContent終了・タイムアウトの表示がなく、これらを空白と区別できなかった。
- 画面操作ツールは `Sky Computer Use native pipe startup failed` で利用できなかったため、ユーザーのタブ操作そのものの目視再現は未確認。上記は空白原因の有力な証拠であり、唯一の原因を断定するものではない。

## 修正

- ビルド開始時とバンドル配置直前に、対象パスの実行中プロセスがあればビルドを中止する。`APP_OUTPUT_DIR` で別の場所に成果物を作成できる。
- WebViewの読み込み中表示、エラー表示、再試行、20秒タイムアウトを追加。
- HTML読み込み完了後もReact rootの描画を待つ。JavaScriptが実行されず空白の場合もエラーにする。
- 再読み込みは元の認証URLから行い、キャッシュを使わず取得する。

## 検証

`sh apps/macos/Scripts/verify-embedded-web.sh [http://127.0.0.1:8765/]`

実WebKitで遅延描画、空白検出、失敗後の再読み込み、WebContent終了通知を検証する。URLを渡すと配信中Webアプリのroot描画も確認する（API認証・会議内容の取得を保証するものではない）。WebContent終了のケースのみdelegate通知を直接呼ぶ。

初回5項目成功。修正版のSwift/Webビルドと署名済みバンドル生成成功。起動中ビルドの拒否も確認。
