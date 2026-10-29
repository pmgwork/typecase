# ベータ版の自動アップデート

TypeCase は Sparkle 2 で更新を確認する。現在のビルドはベータ版専用で、GitHub Releases の `beta` タグに置いた `appcast.xml` を参照する。各バージョンの ZIP は `v1.0.0-beta.1` のような個別の pre-release に置く。`beta` は更新情報を置くための固定タグで、個別リリースの一覧とは別に残す。リポジトリとリリースは公開されている必要がある。フィードを公開するまでは更新確認は成功しない。

更新用の EdDSA 公開鍵は `Config/Info.plist` に設定済み。秘密鍵はこの Mac のログインキーチェーンに `pmgwork.typecase` アカウントとして保存されている。秘密鍵を紛失すると既存のアプリに更新を配信できなくなるため、安全にバックアップすること。秘密鍵はリポジトリやリリースに含めない。

## 初回ベータの公開

1. `MARKETING_VERSION` をベータ版の表示バージョンに設定し、配布ビルドごとに `CURRENT_PROJECT_VERSION` を増やす。
2. 有料アカウントなしでは Apple Development 署名で作成し、公証せず配布する。`bash scripts/package-beta.sh 1.0.0-beta.1` は ZIP、SHA-256、署名付き appcast を `dist/` に作成する。初回起動時の Gatekeeper 警告は、利用者がシステム設定の「プライバシーとセキュリティ」で許可する必要がある。更新の実機検証は初回配布後に行う。
3. 空の作業ディレクトリに、バージョンごとに異なるファイル名で ZIP を作成する。シンボリックリンクを保持するため `ditto -c -k --keepParent /path/to/TypeCase.app /path/to/updates/TypeCase-1.0-beta.1.zip` を使う。
4. Xcode の DerivedData 内の `SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast` を使って以下を実行する。キーチェーンへのアクセスを求められたら許可する。

   ```sh
   generate_appcast --account pmgwork.typecase --maximum-deltas 0 \
     --download-url-prefix https://github.com/pmgwork/typecase/releases/download/v1.0.0-beta.1/ \
     /path/to/updates
   ```

5. GitHub Releases に `v1.0.0-beta.1` タグの **pre-release** を作り、ZIP をアップロードする。別に `beta` タグの pre-release を作り、生成された `appcast.xml` をアップロードする。一般公開されるファイルなので、中身を確認してから公開する。
6. 配布したベータ版を `/Applications` に配置する。次のビルドを公開したら、更新の検出・ダウンロード・インストール・再起動まで実機で確認する。初回ビルドだけでは更新インストールを検証できない。

## 以降のベータ更新

- 各バージョンに固有のタグと ZIP ファイル名を付け、pre-release を作る。過去の ZIP は同じ URL で取得できるよう残す。
- 前回の `appcast.xml` と新旧の ZIP を作業ディレクトリに置き、`--download-url-prefix` を新しいバージョンのリリース URL に変更して `generate_appcast` を再実行する。新しい ZIP を個別リリースに先にアップロードし、最後に固定の `beta` リリースにある `appcast.xml` を差し替える。既存の ZIP を上書きしない。
- `--maximum-deltas 0` により差分更新は生成しない。公開した appcast の内容や署名を手で変更しない。
- GitHub の pre-release を使うため、`releases/latest` は使わない。安定版を配布する際は別のフィードを用意し、安定版ビルドの `SUFeedURL` を変更する。

Sparkle の自動確認の許可ダイアログと更新 UI は標準動作に従う。サンドボックスでは Installer / Downloader XPC サービスを使用する。

参考: [Sparkle の設定](https://sparkle-project.org/documentation/)、[アップデートの公開](https://sparkle-project.org/documentation/publishing/)、[Sandbox 対応](https://sparkle-project.org/documentation/sandboxing/)
