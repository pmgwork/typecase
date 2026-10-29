# Sparkleによるアプリ更新

Sparkle 2をSwift Package Managerで導入し、TypeCaseメニューに「アップデートを確認…」を追加している。
`Config/Info.plist` の配信URLと公開鍵が未設定の場合、更新処理は開始せずメニューは無効になる。

## 配信を有効にする

1. Xcodeでパッケージを解決する。SparkleのツールはDerivedData内の `SourcePackages/artifacts/sparkle/Sparkle/bin/` にある。
2. `generate_keys --account pmgwork.typecase` を実行してTypeCase専用のEdDSA署名鍵を生成する。秘密鍵はログインキーチェーンに保持し、リポジトリへ保存しない。
3. 表示された公開鍵を `Config/Info.plist` の `SUPublicEDKey` に設定する。
4. 公開するappcastのHTTPS URLを同ファイルの `SUFeedURL` に設定する。
5. 新しい配布ビルドごとにXcodeの `CURRENT_PROJECT_VERSION` を増やす。表示バージョンは `MARKETING_VERSION` で管理する。
6. XcodeのArchive / ExportでDeveloper ID署名・公証したアプリを作成し、ZIPやDMGにまとめる。
7. 配布アーカイブを置いた専用ディレクトリに対し `generate_appcast --account pmgwork.typecase <ディレクトリ>` を実行し、署名付きappcastとアーカイブをHTTPSで公開する。
8. 旧バージョンを `/Applications` に配置し、更新の検出・ダウンロード・インストール・再起動まで実機で確認する。

自動確認の許可ダイアログと更新UIはSparkle標準の動作に従う。
サンドボックスではInstaller/Downloader XPCサービスを使用し、アプリ本体のネットワーク権限は追加していない。
署名・公証は通常のArchive / Exportフローを使う。独自の梱包スクリプトを追加する場合は、Sparkle内部のヘルパーとXPCサービスの再署名も必要になる。

現時点では配信URL・公開鍵の設定、鍵生成、配布先の公開、実際の更新インストールは行っていない。

公式資料: [基本設定](https://sparkle-project.org/documentation/)、[SwiftUI連携](https://sparkle-project.org/documentation/programmatic-setup/)、[Sandbox対応](https://sparkle-project.org/documentation/sandboxing/)
