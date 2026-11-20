#!/usr/bin/env python3
# 壹跑 · 桌面快捷方式图标生成脚本
#
# 长按桌面图标弹出的那三条（开关车锁／鸣笛寻车／开关尾门）的图标，是从鸿蒙系统符号字体
# HMSymbolVF.ttf 里把字形原样导出成 SVG 得到的——和 App 界面里 $r('sys.symbol.lock') 那些
# 是同一套图形，只是换了个载体。
#
# 为什么不直接在 shortcuts_config.json 里写 $sys.symbol.* ：
#   试过，真机上三条全变成蓝色四叶花（系统的"资源找不到"占位图）。快捷方式的 icon 只认
#   图片资源，而 symbol 是字体字形不是图片；$sys.media.* 同样不认。编译期不报错，只有装到
#   手机上长按才看得见，所以别信"编译过了就行"。
#
# 两个参数是照着菜单上系统自带那几条（移除／添加应用锁／卡片）量出来的，别凭肉眼调：
#   EDGE  图形最大边占 viewBox 24 的比例。11.0 时真机上量到 ~64px，和官方那组一致。
#   WGHT  字重。字体默认 400，和官方那组的笔画粗细基本对得上。
# 量的办法：截图后取图标那一格，按亮度阈值找亮像素的外接框（宽高）和像素数（墨量），
# 和「添加应用锁」那条比。桌面还会给第三方快捷方式套一层圆形背板，看着比实际大一圈，
# 这层背板去不掉。
#
# 用法（需要 pip install fonttools）：
#   python3 scripts/gen-shortcut-icons.py [EDGE] [WGHT]
# 输出覆盖 entry/src/main/resources/{base,dark}/media/ic_shortcut_{lock,horn,trunk}.svg
import sys, os
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.varLib.instancer import instantiateVariableFont

FONT = os.environ.get(
    "HM_SYMBOL_FONT",
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/previewer/common/bin/fonts/HMSymbolVF.ttf",
)
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "entry/src/main/resources")
EDGE = float(sys.argv[1]) if len(sys.argv) > 1 else 11.0
WGHT = float(sys.argv[2]) if len(sys.argv) > 2 else 400.0

# 和 App 界面里用的是同几个符号：HomeView 的车锁/尾门、卡片上的喇叭。
MAP = {
    "ic_shortcut_lock": "lock",
    "ic_shortcut_horn": "horn_fill",
    "ic_shortcut_trunk": "car_side_rear_open_1",
}

font = instantiateVariableFont(TTFont(FONT), {"wght": WGHT})
glyphs = font.getGlyphSet()


def build(gname: str, color: str) -> str:
    glyph = glyphs[gname]
    bounds = BoundsPen(glyphs)
    glyph.draw(bounds)
    x0, y0, x1, y1 = bounds.bounds
    scale = EDGE / max(x1 - x0, y1 - y0)
    # 字体 Y 轴向上、SVG 向下，所以下面 scale 的 Y 取负；平移把图形摆到 viewBox 正中。
    tx = 12 - (x0 + x1) / 2 * scale
    ty = 12 + (y0 + y1) / 2 * scale
    pen = SVGPathPen(glyphs)
    glyph.draw(pen)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 24 24">\n'
        f'  <!-- 系统符号 sys.symbol.{gname} 的字形，字重 {WGHT:.0f}，由 scripts/gen-shortcut-icons.py\n'
        f'       从 HMSymbolVF.ttf 导出。手改没有意义，改参数重跑那个脚本，理由都写在脚本头上。 -->\n'
        f'  <g transform="translate({tx:.3f} {ty:.3f}) scale({scale:.5f} {-scale:.5f})" fill="{color}">\n'
        f'    <path d="{pen.getCommands()}"/>\n  </g>\n</svg>\n'
    )


for name, gname in MAP.items():
    with open(f"{DST}/base/media/{name}.svg", "w") as fp:
        fp.write(build(gname, "#182431"))
    with open(f"{DST}/dark/media/{name}.svg", "w") as fp:
        fp.write(build(gname, "#D8D8D8"))
    print(f"{name}.svg  <-  sys.symbol.{gname}")
print(f"最大边 {EDGE} / 24，字重 {WGHT:.0f}")
