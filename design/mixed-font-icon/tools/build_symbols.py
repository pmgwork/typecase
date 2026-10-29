"""サイドバーの Mixed Fonts と Duplicates を、Xcode の Custom Symbol（.symbolset）として書き出す。

    python3 design/mixed-font-icon/tools/build_symbols.py

座標は build_preview.py と同じ 20 × 20 pt（16 pt regular の SF Symbols と同じ大きさ）。
線幅は実画面で隣の SF Symbols に合わせ（字 1.6 pt・枠 1.3 pt）、端部と角は丸で描いた線を Inkscape でアウトライン化し、SF Symbols のテンプレート
（Regular-M のみ）に流し込む。テンプレートは 100 pt 基準なので 1 pt = 100 / 16 = 6.25 単位、
ベースラインは textformat の字の下端と同じ y 16 に置く。

書き出すもの
  - typecase/Assets.xcassets/<name>.symbolset/  Xcode が読む Custom Symbol
  - design/mixed-font-icon/<name>.svg            確認用の単色 SVG（アウトライン後）
"""

import json
import math
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent
ASSETS = REPO / "typecase" / "Assets.xcassets"



def stroke(width):
    return f'fill="none" stroke="#000" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"'


# Mixed Fonts は実画面で細く見えるため、字を 1.6 pt に補正する。
# square.on.square や folder の枠は約 1.3 pt。
LETTER = stroke(1.6)
FRAME = stroke(1.3)
UNIT = 100 / 16
BASELINE_PT = 16

TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def placed(d, scale, origin, to):
    """絶対座標パスを移動・拡大する。scale は一律または (横, 縦)。"""
    scales = (scale, scale) if isinstance(scale, (int, float)) else scale
    tokens = TOKEN.findall(d)
    out, axis = [], 0
    for token in tokens:
        if token.isalpha():
            out.append(token)
            axis = {"H": 0, "V": 1}.get(token, 0)
            fixed = token in "HV"
            continue
        value = to[axis] + (float(token) - origin[axis]) * scales[axis]
        out.append(f"{value:.3f}")
        if not fixed:
            axis = 1 - axis
    return " ".join(out)


# 採用案 03（variants-20261026/03.svg）。縦横比と下端を保って全体を拡大する。
KANA_A = (
    "M1.7 6.3H10.1L7.7 9.7",
    "M5.7 8.5V10C5.7 12.2 4.8 14 2.8 15.4",
)
LATIN_A = (
    "M13.1 10.1C13.7 9 17.6 8.5 17.6 11.2V15.5",
    "M17.6 12.1H15.3C11.9 12.1 12.1 15.6 14.5 15.6C16.2 15.6 17.6 14.5 17.6 13",
)
MIXED_KANA = placed(" ".join(KANA_A), 1.18, (0, 15.6), (0, 15.6))
# 字形のサイズを変えず、a を 0.8 pt 左へ寄せて字間を詰める。
MIXED_LATIN = placed(" ".join(LATIN_A), 1.18, (0, 15.6), (-0.8, 15.6))

SYMBOLS = [
    {
        "name": "mixed.font",
        "body": (
            f'<path {LETTER} d="{MIXED_KANA}"/>'
            f'<path {LETTER} d="{MIXED_LATIN}"/>'
        ),
    },
    {
        # square.on.square の手前の札に A を置き、「同じ書体がもう 1 つある」を表す。
        # 奥の札は手前の札の外側 1.25 pt の隙間で切り欠く。
        "name": "font.duplicate",
        "body": (
            f'<rect id="back" x="2.25" y="2.75" width="10.5" height="10.5" rx="2.75" {FRAME}/>'
            '<rect id="cut" x="5" y="4.5" width="14" height="14" rx="4.25" fill="#000"/>'
            f'<rect x="7.25" y="6.75" width="10.5" height="10.5" rx="2.75" {FRAME}/>'
            f'<path {FRAME} d="M10.15 14.6L12.5 9.15L14.85 14.6"/>'
            f'<path {FRAME} d="M11.05 12.75H13.95"/>'
        ),
        "difference": ("back", "cut"),
    },
    {
        # インスペクタの 14 pt 用。座標は 14 pt の 1 pt = 1 画素で、等倍の画面でも
        # 縦横の線が画素に収まるよう中心を x.5 に、切れ目を画素の境に置く。
        "name": "font.duplicate.small",
        "unit": 100 / 14,
        "baseline": 12.4,
        "body": (
            f'<rect id="back" x="0.5" y="0.5" width="9" height="9" rx="2.5" {stroke(1.1)}/>'
            '<rect id="cut" x="4" y="3" width="12" height="12" rx="4" fill="#000"/>'
            f'<rect x="5.5" y="4.5" width="9" height="9" rx="2.5" {stroke(1.1)}/>'
            f'<path {stroke(1.1)} d="M8 11.45L10 6.6L12 11.45"/>'
            f'<path {stroke(1.1)} d="M8.75 10.5H11.25"/>'
        ),
        "difference": ("back", "cut"),
    },
]


# --- SVG パス --------------------------------------------------------------------

ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def arc_to_cubics(p0, rx, ry, phi, large, sweep, p1):
    """SVG の楕円弧を 3 次ベジェに分ける（SVG 1.1 付録 F.6 の中心化）。"""
    if p0 == p1:
        return []
    if rx == 0 or ry == 0:
        return [(p0, p1, p1)]
    rx, ry = abs(rx), abs(ry)
    cos, sin = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (p0[0] - p1[0]) / 2, (p0[1] - p1[1]) / 2
    x1, y1 = cos * dx + sin * dy, -sin * dx + cos * dy
    scale = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if scale > 1:
        rx, ry = rx * math.sqrt(scale), ry * math.sqrt(scale)
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    coef = math.sqrt(max(0, num / den)) * (-1 if large == sweep else 1)
    cx1, cy1 = coef * rx * y1 / ry, -coef * ry * x1 / rx
    cx = cos * cx1 - sin * cy1 + (p0[0] + p1[0]) / 2
    cy = sin * cx1 + cos * cy1 + (p0[1] + p1[1]) / 2

    def angle(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    dt = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi

    def point(t):
        x, y = rx * math.cos(t), ry * math.sin(t)
        return (cos * x - sin * y + cx, sin * x + cos * y + cy)

    def derivative(t):
        x, y = -rx * math.sin(t), ry * math.cos(t)
        return (cos * x - sin * y, sin * x + cos * y)

    count = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    step = dt / count
    k = 4 / 3 * math.tan(step / 4)
    cubics = []
    for i in range(count):
        a, b = t1 + i * step, t1 + (i + 1) * step
        pa, pb = point(a), point(b)
        da, db = derivative(a), derivative(b)
        cubics.append(
            ((pa[0] + k * da[0], pa[1] + k * da[1]), (pb[0] - k * db[0], pb[1] - k * db[1]), pb)
        )
    cubics[-1] = (cubics[-1][0], cubics[-1][1], p1)
    return cubics


def parse_path(d):
    """パスを絶対座標の M / L / C / Z の列にする。"""
    tokens = TOKEN.findall(d)
    out, i, command = [], 0, None
    current = start = (0.0, 0.0)
    last_control = None
    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]
            i += 1
        upper = command.upper()
        relative = command.islower()
        args = [float(t) for t in tokens[i : i + ARITY[upper]]]
        i += ARITY[upper]
        ox, oy = current if relative else (0.0, 0.0)
        control = None
        if upper == "M":
            current = start = (args[0] + ox, args[1] + oy)
            out.append(("M", current))
            command = "l" if relative else "L"
        elif upper in "LHV":
            if upper == "L":
                current = (args[0] + ox, args[1] + oy)
            elif upper == "H":
                current = (args[0] + ox, current[1])
            else:
                current = (current[0], args[0] + oy)
            out.append(("L", current))
        elif upper in "CS":
            if upper == "C":
                c1 = (args[0] + ox, args[1] + oy)
                rest = args[2:]
            else:
                c1 = (2 * current[0] - last_control[0], 2 * current[1] - last_control[1]) if last_control else current
                rest = args
            c2 = (rest[0] + ox, rest[1] + oy)
            current = (rest[2] + ox, rest[3] + oy)
            out.append(("C", c1, c2, current))
            control = c2
        elif upper == "Q":
            q = (args[0] + ox, args[1] + oy)
            end = (args[2] + ox, args[3] + oy)
            c1 = (current[0] + 2 / 3 * (q[0] - current[0]), current[1] + 2 / 3 * (q[1] - current[1]))
            c2 = (end[0] + 2 / 3 * (q[0] - end[0]), end[1] + 2 / 3 * (q[1] - end[1]))
            current = end
            out.append(("C", c1, c2, current))
        elif upper == "A":
            end = (args[5] + ox, args[6] + oy)
            for c1, c2, p in arc_to_cubics(current, args[0], args[1], args[2], bool(args[3]), bool(args[4]), end):
                out.append(("C", c1, c2, p))
            current = end
        elif upper == "Z":
            out.append(("Z",))
            current = start
        else:
            raise ValueError(f"unsupported path command {command}")
        last_control = control
    return out


def cubic_point(p0, c1, c2, p1, t):
    u = 1 - t
    return tuple(u**3 * p0[k] + 3 * u * u * t * c1[k] + 3 * u * t * t * c2[k] + t**3 * p1[k] for k in (0, 1))


def bounds(paths):
    xs, ys = [], []
    for segments in paths:
        current = (0.0, 0.0)
        for segment in segments:
            if segment[0] in "ML":
                current = segment[1]
                xs.append(current[0])
                ys.append(current[1])
            elif segment[0] == "C":
                for n in range(1, 17):
                    x, y = cubic_point(current, segment[1], segment[2], segment[3], n / 16)
                    xs.append(x)
                    ys.append(y)
                current = segment[3]
    return min(xs), min(ys), max(xs), max(ys)


def format_path(segments, transform):
    def p(point):
        x, y = transform(point)
        return f"{x:.4g} {y:.4g}"

    parts = []
    for segment in segments:
        if segment[0] == "Z":
            parts.append("Z")
        elif segment[0] == "C":
            parts.append(f"C{p(segment[1])} {p(segment[2])} {p(segment[3])}")
        else:
            parts.append(f"{segment[0]}{p(segment[1])}")
    return "".join(parts)


# --- アウトライン化 -----------------------------------------------------------------


def outline(symbol):
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "in.svg"
        target = Path(directory) / "out.svg"
        source.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" width="20" height="20">'
            f'{symbol["body"]}</svg>'
        )
        actions = ["select-all", "object-stroke-to-path", "select-clear"]
        if "difference" in symbol:
            actions += [f'select-by-id:{",".join(symbol["difference"])}', "path-difference", "select-clear"]
        actions += ["export-plain-svg", f"export-filename:{target}", "export-do"]
        subprocess.run(
            ["inkscape", str(source), f'--actions={";".join(actions)}'],
            check=True,
            capture_output=True,
        )
        return [parse_path(d) for d in re.findall(r'\sd="([^"]+)"', target.read_text())]


# --- SF Symbols テンプレート -----------------------------------------------------------

GUIDE = "fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"
MARGIN = "fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"


def template(name, paths, unit=UNIT, baseline=BASELINE_PT):
    left, top, right, bottom = bounds(paths)
    origin_x = 1391.0
    width = (right - left) * unit

    def transform(point):
        return ((point[0] - left) * unit, (point[1] - baseline) * unit)

    shapes = "\n".join(
        f'   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary" '
        f'd="{format_path(segments, transform)}"/>'
        for segments in paths
    )
    guides = []
    for size, baseline in (("S", 696), ("M", 1126), ("L", 1556)):
        guides.append(f'  <line id="Baseline-{size}" style="{GUIDE}" x1="263" x2="3036" y1="{baseline}" y2="{baseline}"/>')
        capline = baseline - 70.459
        guides.append(f'  <line id="Capline-{size}" style="{GUIDE}" x1="263" x2="3036" y1="{capline:.3f}" y2="{capline:.3f}"/>')
    guides.append(
        f'  <line id="left-margin-Regular-M" style="{MARGIN}" x1="{origin_x}" x2="{origin_x}" y1="1030.79" y2="1150.12"/>'
    )
    guides.append(
        f'  <line id="right-margin-Regular-M" style="{MARGIN}" x1="{origin_x + width:.3f}" x2="{origin_x + width:.3f}" '
        'y1="1030.79" y2="1150.12"/>'
    )
    guide_lines = "\n".join(guides)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- design/mixed-font-icon/tools/build_symbols.py が書き出す。直接編集しない。 -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <style>
.monochrome-0 {{-sfsymbols-motion-group:0}}
.multicolor-0:tintColor {{-sfsymbols-motion-group:0;fill:#007AFF}}
.hierarchical-0:primary {{-sfsymbols-motion-group:0;fill:#000000}}
.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}
 </style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.5.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1953)">{name}</text>
 </g>
 <g id="Guides">
{guide_lines}
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {origin_x} 1126)">
{shapes}
  </g>
 </g>
</svg>
"""


def preview_svg(name, paths):
    # 拡大した字形を確認用 SVG の右端で切らない。
    width = max(20, math.ceil(bounds(paths)[2]))
    shapes = "".join(f'<path d="{format_path(segments, lambda p: p)}"/>' for segments in paths)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 20" width="{width}" height="20" '
        f'fill="currentColor" role="img" aria-label="{name}">{shapes}</svg>\n'
    )


def build():
    for symbol in SYMBOLS:
        name = symbol["name"]
        paths = outline(symbol)
        folder = ASSETS / f"{name}.symbolset"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{name}.svg").write_text(
            template(name, paths, symbol.get("unit", UNIT), symbol.get("baseline", BASELINE_PT))
        )
        contents = {
            "info": {"author": "xcode", "version": 1},
            "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}],
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
        (ROOT / f"{name}.svg").write_text(preview_svg(name, paths))
        print(f"{folder.relative_to(REPO)}  bounds {tuple(round(v, 2) for v in bounds(paths))}")


if __name__ == "__main__":
    build()
