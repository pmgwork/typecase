# 多言語対応

英語（en）、日本語（ja）、簡体字中国語（zh-Hans）、繁体字中国語（zh-Hant）、韓国語（ko）に対応しています。画面、設定、メニュー、ツールチップ、アクセシビリティラベル、アプリが生成するレイアウト名を `typecase/Localizable.xcstrings` で管理します。

TypeCaseの「設定 → 一般 → 言語 → アプリの言語」で「システムに従う」または5言語を選べます。変更はアプリの再起動後に反映されます。「システムに従う」はアプリ専用の言語指定を解除し、macOSの優先言語に従います。対応する言語がなければ英語にフォールバックします。

言語指定にはmacOS標準のアプリ別 `AppleLanguages` 設定を使用します。「システム設定 → 一般 → 言語と地域 → アプリケーション」で指定した言語も起動時に読み込みます。

ユーザーが入力したタグ、レイアウト名、サンプル文章、フォントファイル由来の名前・スタイル・ライセンスなどは翻訳しません。フォントのプレビュー言語の判定は表示言語から独立しています。新規レイアウトの初期名や複製時の接尾辞は作成時の言語を使い、既存の名前は保持します。OSが返すエラーや標準ダイアログはmacOS側の翻訳を使います。

## 文言を追加するとき

- 動的なメニュー、AppKitの文字列、モデルが返す表示名も `String(localized: "…")` を使用します。
- 名前や件数を文に含める場合は、文字列を連結せず補間した文全体を翻訳します。翻訳内で `%1$@`、`%2$lld` などにより語順を指定できます。
- 件数に応じて英語の単数・複数が変わる文言にはString Catalogのplural variationsを設定します。
- 永続化用の識別子、フォント検索名、OpenTypeタグは翻訳しません。
- 5言語すべての翻訳を追加し、プレースホルダの型と番号を保持します。

## 検証

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project typecase.xcodeproj -scheme typecase -configuration Debug \
  -derivedDataPath /tmp/typecase-localization-build CODE_SIGNING_ALLOWED=NO build
python3 Tests/check_localization.py /tmp/typecase-localization-build
```

検証スクリプトは翻訳の空欄、対応言語の欠落、引数の型や順序の不整合、コンパイラが抽出したUI文言の翻訳漏れを検出します。見た目の確認は各言語でアプリを起動し、特に設定・インスペクタ・混植編集のラベルが収まることを確認してください。

ビルド済みリソースの全キーの読み込みと、複数形・パーセント表示・引数の語順も検証できます。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path /tmp/typecase-probe-module-cache \
  Tests/LocalizationProbe.swift -o /tmp/typecase-localization-probe
/tmp/typecase-localization-probe \
  /tmp/typecase-localization-build/Build/Products/Debug/TypeCase.app/Contents/Resources \
  typecase/Localizable.xcstrings
```

アプリ内の言語選択の保存、地域付き言語コード、システム設定への復帰を検証するには以下を実行します（専用の一時設定ドメインを使用します）。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -module-cache-path /tmp/typecase-probe-module-cache \
  typecase/AppLanguage.swift Tests/AppLanguageTests.swift -o /tmp/typecase-app-language-tests
/tmp/typecase-app-language-tests
```
