// TypeCase のアプリアイコン（Icon Composer の .icon 文書）を生成するスクリプト。
//
//   swift design/app-icon/generate_icon.swift
//
// 構成は「生成りの面 1 枚」と「墨色のセリフ体の小文字『f』1 字（ガラス）」だけ。
// f はフォントを表す定番の字。枠・仕切り・飾りは置かず、字の形と余白で書体の道具であることを伝える。
// 書体は Baskerville Bold。玉形の先端（ボール・ターミナル）と太い縦画で、小さいサイズでも f と読める。
//
// .icon ではキャンバス 1024 × 1024 pt 全体がアイコンの本体になり、角丸の形・縁の光・影・
// ダーク／色合い／クリアの外観はシステムが付ける。そのためレイヤーには角丸や影を描かず、
// 面は icon.json の塗り（fill）、字は SVG のレイヤー 1 枚として分けて持つ。
//
// 書き出すもの
//   - typecase/AppIcon.icon/icon.json          塗り・レイヤー・外観ごとの色（Icon Composer で開ける）
//   - typecase/AppIcon.icon/Assets/f.svg       字のレイヤー（アウトライン化した字形、キャンバスと同じ座標）
//   - design/app-icon/AppIcon-1024.png         確認用プレビュー（Icon Composer の ictool による macOS の描画）
//   - design/app-icon/AppIcon-1024-dark.png    同、ダーク外観
//
// Icon Composer で調整した場合は、このスクリプトの値にも反映すること（再実行すると上書きされる）。

import AppKit
import CoreText

// MARK: - 配色

struct RGBA {
    var r, g, b, a: CGFloat
    init(_ hex: UInt32, _ a: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        self.a = a
    }
    /// icon.json の色の書式
    var json: String { String(format: "srgb:%.5f,%.5f,%.5f,%.5f", r, g, b, a) }
    var svg: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
}

/// 面：生成りの紙。上をわずかに明るくして平板に見えないようにする
let paperTop = RGBA(0xF7F3EA)
let paperBottom = RGBA(0xE9E2D3)
/// 字：真っ黒ではなく少し温かい墨色
let ink = RGBA(0x1F1D1B)

/// ダーク外観では紙と墨を入れ替える。面は墨色、字は生成り
let darkTop = RGBA(0x2E2B27)
let darkBottom = RGBA(0x1F1D1B)
let darkInk = RGBA(0xEDE6D8)

/// 色合い・クリア外観はレイヤーの明るさから色を付けるため、墨色のままだと字が面に沈む。
/// 白にして、システムの色付けでも字が最も明るく読めるようにする
let tintedInk = RGBA(0xFFFFFF)

// MARK: - 字形（1024 × 1024、y は下向き）

let canvas: CGFloat = 1024
/// 以前の PNG 版は 1024 の中の 824 角の面に字を置いていた。.icon ではキャンバス全体が面なので、
/// 面に対する字の大きさと位置を保つよう、その比率で拡大する
let bodyScale = canvas / 824

/// 字形をアウトラインにする（y 下向き、原点はベースライン左端）
func glyphPath(_ char: String, font name: String, size: CGFloat) -> CGPath {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let actual = CTFontCopyPostScriptName(font) as String
    precondition(actual == name, "フォント \(name) が見つかりません（\(actual) に置き換わりました）")
    var chars = Array(char.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    // CoreText は y 上向きなので反転する
    var t = CGAffineTransform(scaleX: 1, y: -1)
    return CTFontCreatePathForGlyph(font, glyphs[0], &t)!
}

/// 字形を塗ったときの墨の重心の x 座標（字形と同じ座標系）
func inkCentroidX(_ path: CGPath) -> CGFloat {
    let box = path.boundingBoxOfPath
    let n = 512
    let k = CGFloat(n) / max(box.width, box.height)
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.addPath(path)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fillPath()
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n)
    var sum: Double = 0, sumX: Double = 0
    for y in 0..<n {
        for x in 0..<n {
            let v = Double(px[y * n + x])
            sum += v
            sumX += v * (Double(x) + 0.5)
        }
    }
    return box.minX + CGFloat(sumX / sum) / k
}

/// 主役の 1 字。小文字 f を字面の高さで大きさを決め、キャンバスの中央に置く
func makeGlyph() -> CGPath {
    let raw = glyphPath("f", font: "Baskerville-Bold", size: 100)
    let rawBox = raw.boundingBoxOfPath
    let glyphHeight: CGFloat = 540 * bodyScale
    var scale = CGAffineTransform(scaleX: glyphHeight / rawBox.height, y: glyphHeight / rawBox.height)
    let glyph = raw.copy(using: &scale)!
    let box = glyph.boundingBoxOfPath
    // f は右上に玉、左に横棒が張り出して字面の外枠と見た目の重心がずれる。
    // 外枠の中心と墨の重心の中間を面の中心に置く
    let centerX = (box.midX + inkCentroidX(glyph)) / 2
    // 目の錯覚で下がって見えないよう少し上げる
    let opticalLift: CGFloat = 10 * bodyScale
    var t = CGAffineTransform(translationX: canvas / 2 - centerX, y: canvas / 2 - box.midY - opticalLift)
    return glyph.copy(using: &t)!
}

// MARK: - 書き出し

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

/// 字のレイヤー。キャンバスと同じ 1024 角の viewBox にして、Icon Composer で等倍・中央のまま置けるようにする。
/// 色は icon.json の fill-specializations で外観ごとに塗り替えるので、ここでは淡色外観の墨色を入れておく
func glyphSVG(_ glyph: CGPath) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- design/app-icon/generate_icon.swift で生成 -->
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path fill="\(ink.svg)" d="\(svgPathData(glyph))"/>
    </svg>

    """
}

/// 上から下への線形グラデーション（orientation は面に対する 0〜1 の比率、y は下向き）
func gradient(_ top: RGBA, _ bottom: RGBA) -> [String: Any] {
    ["linear-gradient": [top.json, bottom.json],
     "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]]
}

func solid(_ c: RGBA) -> [String: Any] { ["solid": c.json] }

/// 字は Liquid Glass の 1 枚として置き、厚み・縁の反射・透けを見せる。
/// キーは Icon Composer（bundle-version 129）が読むものだけを使う。未知のキーはエラーにならず無視されるので、
/// 値を変えたら ictool で描画して効果が変わることを確かめる
///   - glass: true               字のレイヤーをガラスにする（false だとほぼ平らな墨になる）
///   - specular: true            縁の光沢。false にするとガラスでもマットに見える
///   - translucency 0.5          下へ向かって面が透ける量。0.8 では字の足が面に溶け、0.2 では透けがほぼ見えない
///   - blur-material 0.4         透けた面のぼかし。透けすぎて字の足が薄くなるのを抑える
///   - refractivity              縁の屈折
///   - shadow layer-color 0.6    字の色を落とした影。面から浮いた厚みを出す
/// 小さいサイズでも f と読める範囲に効果を留める
let iconDocument: [String: Any] = [
    "fill-specializations": [
        ["value": gradient(paperTop, paperBottom)],
        ["appearance": "dark", "value": gradient(darkTop, darkBottom)],
    ],
    "groups": [[
        "layers": [[
            "fill-specializations": [
                ["value": solid(ink)],
                ["appearance": "dark", "value": solid(darkInk)],
                ["appearance": "tinted", "value": solid(tintedInk)],
            ],
            "glass": true,
            "image-name": "f.svg",
            "name": "f",
            "position": ["scale": 1, "translation-in-points": [0, 0]],
        ]],
        "blur-material": NSDecimalNumber(string: "0.4"),
        "refractivity": ["enabled": true, "strength": 1, "depth": 1],
        "shadow": ["kind": "layer-color", "opacity": NSDecimalNumber(string: "0.6")],
        "specular": true,
        "translucency": ["enabled": true, "value": 0.5],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]

// MARK: - 実行

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // design/app-icon
let repo = root.deletingLastPathComponent().deletingLastPathComponent()
let icon = repo.appendingPathComponent("typecase/AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")

try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try glyphSVG(makeGlyph()).write(to: assets.appendingPathComponent("f.svg"), atomically: true, encoding: .utf8)
// Icon Composer が保存するときと同じく、キーを並べ替えた整形済み JSON にする
let json = try JSONSerialization.data(withJSONObject: iconDocument,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try (json + Data("\n".utf8)).write(to: icon.appendingPathComponent("icon.json"))
print("生成しました: \(icon.path)")

// 確認用プレビュー。Xcode に同梱の Icon Composer の ictool で、システムと同じ描画を書き出す
let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if FileManager.default.isExecutableFile(atPath: ictool) {
    for (rendition, suffix) in [("Default", ""), ("Dark", "-dark")] {
        let out = root.appendingPathComponent("AppIcon-1024\(suffix).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ictool)
        p.arguments = [icon.path, "--export-image", "--output-file", out.path, "--platform", "macOS",
                       "--rendition", rendition, "--width", "1024", "--height", "1024", "--scale", "1"]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "ictool が \(rendition) の書き出しに失敗しました")
        print("プレビュー: \(out.path)")
    }
} else {
    print("ictool が見つからないため、プレビューは書き出していません: \(ictool)")
}
