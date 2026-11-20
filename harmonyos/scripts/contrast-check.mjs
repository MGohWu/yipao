#!/usr/bin/env node
// 色彩对比度自查：把色板放回真实的渲染环境里量，而不是拿 bg_* 当背景拍脑袋。
//
//   node scripts/contrast-check.mjs           全部达标退出码 0，有不达标退出码 1
//   node scripts/contrast-check.mjs --verbose 连每个表面的数值一起打印
//
// 判据来自华为《通用应用 UX 体验标准》：
//   2.1.4.1 色彩对比度 —— 正文文字 >4.5:1，图标/标题 >3:1
//
// 为什么需要这个脚本：1.0.1 上架被打回，就是因为拿 `bg_top/mid/bottom` 那三个值
// 当背景去核对比度。真正压在文字底下的是「渐变 + 两团光晕 + 卡片材质」层层叠出来
// 的颜色，跟着光晕在屏幕上到处漂。深色下光晕能把卡片抬到 #4979C1 那种亮蓝，
// 那里连纯白文字都只有 4.39:1 —— 色值再怎么调都不可能达标。
// 所以这里复刻 LeapBackground 的渲染，在整屏网格 × 三种车况色调上取最差值。

import { readFile, readdir } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const RES = join(ROOT, 'entry/src/main/resources')
const GLASS_ETS = join(ROOT, 'entry/src/main/ets/design/LeapGlass.ets')

const COLOR = process.stdout.isTTY && !process.env.NO_COLOR
const paint = (c, s) => (COLOR ? `\x1b[${c}m${s}\x1b[0m` : s)
const log = {
  step: (s) => console.log(paint('36;1', `\n▸ ${s}`)),
  info: (s) => console.log(`  ${s}`),
  warn: (s) => console.warn(paint('33', `  ! ${s}`)),
  fail: (s) => console.error(paint('31;1', `✗ ${s}`)),
}

// ── 屏幕 ────────────────────────────────────────────────────────────────
// LeapBackground 拿不到 display 时的兜底值，也是常见长条屏的比例。
// 光晕的半径全部按屏宽取、再按 aspect 竖直拉伸，所以换个机型结果只差零点几，
// 不影响判定。
const SW = 360
const SH = 780
const ASPECT = SH / SW

// ── 必须和 LeapGlass.ets 对齐的几个数 ───────────────────────────────────
// 抄一份是没办法的事：那边是 ArkTS、跑在 ArkUI 里，这里没法直接 import。
// 所以下面 assertGlowInSync() 会回头读 LeapGlass.ets 核对这些数字还在不在，
// 对不上就报错——否则改了光晕参数、这个脚本还在按老数字算，自查就成了摆设。
const GLOW_TINT = [[0.60, 0.0], [0.42, 0.45], [0.18, 0.75], [0.0, 1.0]]
const GLOW_COOL = [[0.34, 0.0], [0.24, 0.45], [0.10, 0.75], [0.0, 1.0]]
const TINT_CENTER = [0.5, 0.06]  // 圆心（占屏宽 / 占屏高）
const TINT_RADIUS = 0.75         // 半径，占屏宽
const COOL_CENTER = [0.9, 0.8]
const COOL_RADIUS = 0.62
const COOL_GLOW_HEX = '#6BA8FF'

// 背景光晕会取的色调，见各页面传给 LeapBackground 的 tint。
// 前三个是车况色，第四个是功能页固定用的青（跟车况无关，见 FeatureCenterView）。
const TINTS = {
  '充电(绿)': '#4DC47D',
  '制热(橙)': '#FF8C59',
  '常态(蓝)': '#6BA8FF',
  '功能页(青)': '#46B4C0'
}

// ── 颜色 ────────────────────────────────────────────────────────────────
function parseColor(hex) {
  const h = String(hex).replace('#', '')
  if (h.length === 8) {
    return {
      rgb: [parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), parseInt(h.slice(6, 8), 16)],
      a: parseInt(h.slice(0, 2), 16) / 255,
    }
  }
  if (h.length === 6) {
    return { rgb: [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)], a: 1 }
  }
  throw new Error(`认不出的颜色值：${hex}`)
}

const over = (fg, bg) => fg.rgb.map((c, i) => c * fg.a + bg[i] * (1 - fg.a))
const lerp = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t)
const hex = (c) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0').toUpperCase()).join('')

const chan = (v) => {
  const s = v / 255
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4
}
const luminance = (c) => 0.2126 * chan(c[0]) + 0.7152 * chan(c[1]) + 0.0722 * chan(c[2])
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((p, q) => q - p)
  return (hi + 0.05) / (lo + 0.05)
}

// ── 渲染模型 ────────────────────────────────────────────────────────────
function glowAlpha(stops, d) {
  if (d >= 1) return 0
  for (let i = 0; i < stops.length - 1; i++) {
    const [a0, p0] = stops[i]
    const [a1, p1] = stops[i + 1]
    if (d >= p0 && d <= p1) return p1 > p0 ? a0 + (a1 - a0) * ((d - p0) / (p1 - p0)) : a0
  }
  return 0
}

/** 页面背景：竖直渐变，再叠随车况变色的顶部光晕和右下角恒定冷光。 */
function background(x, y, P, tintHex) {
  const t = y / SH
  const top = parseColor(P.bg_top).rgb
  const mid = parseColor(P.bg_mid).rgb
  const bot = parseColor(P.bg_bottom).rgb
  const base = t <= 0.55 ? lerp(top, mid, t / 0.55) : lerp(mid, bot, (t - 0.55) / 0.45)

  // 光晕是椭圆：横向半径按屏宽，纵向按屏宽再乘 aspect（LeapGlass 用 scale 拉的）
  const d1 = Math.hypot(
    (x - TINT_CENTER[0] * SW) / (TINT_RADIUS * SW),
    (y - TINT_CENTER[1] * SH) / (TINT_RADIUS * SW * ASPECT),
  )
  const withTint = over({ rgb: parseColor(tintHex).rgb, a: glowAlpha(GLOW_TINT, d1) }, base)

  const d2 = Math.hypot(
    (x - COOL_CENTER[0] * SW) / (COOL_RADIUS * SW),
    (y - COOL_CENTER[1] * SH) / (COOL_RADIUS * SW * ASPECT),
  )
  return over({ rgb: parseColor(COOL_GLOW_HEX).rgb, a: glowAlpha(GLOW_COOL, d2) }, withTint)
}

/** 卡片 = glass_tint 垫在背景之上。浅色叠白、深色叠黑，方向是相反的。 */
const card = (x, y, P, tint) => over(parseColor(P.glass_tint), background(x, y, P, tint))

/** 在整屏网格 × 三种色调上扫，返回最差对比度。 */
function worst(P, fgKey, fillKey) {
  let lo = Infinity
  let at = null
  for (const [tintName, tintHex] of Object.entries(TINTS)) {
    for (let yi = 0; yi <= 40; yi++) {
      for (let xi = 0; xi <= 12; xi++) {
        const x = (xi * SW) / 12
        const y = (yi * SH) / 40
        let bg = card(x, y, P, tintHex)
        if (fillKey) bg = over(parseColor(P[fillKey]), bg)
        const fg = over(parseColor(P[fgKey]), bg)
        const r = contrast(fg, bg)
        if (r < lo) {
          lo = r
          at = `${tintName} 底${hex(bg)}`
        }
      }
    }
  }
  return { ratio: lo, at }
}

// ── 前景 × 它会落在哪些表面上 ───────────────────────────────────────────
// 加新色 / 改用法时要一起维护这张表。写错了会漏检：
// 比如 text_tertiary 如果漏了 fill_neutral，就查不出导航按钮禁用态那种组合。
const SURFACES = {
  '卡片': null,
  '卡片+fill_accent': 'fill_accent',
  '卡片+fill_cool': 'fill_cool',
  '卡片+fill_neutral': 'fill_neutral',
  '卡片+selected': 'selected_fill',
}
const NEED_TEXT = 4.5   // 正文文字
const NEED_GRAPHIC = 3.0 // 图标 / 图形元素

const CHECKS = [
  // [色名, 判定线, 会落在哪些表面上]
  ['text_primary', NEED_TEXT, ['卡片', '卡片+fill_neutral', '卡片+selected']],
  ['text_secondary', NEED_TEXT, ['卡片', '卡片+fill_neutral', '卡片+selected']],
  // tertiary 不会落在 selected 上——那上面只有选中态的 primary
  ['text_tertiary', NEED_TEXT, ['卡片', '卡片+fill_neutral']],
  ['text_disabled', NEED_TEXT, ['卡片', '卡片+fill_neutral']],
  ['accent', NEED_TEXT, ['卡片', '卡片+fill_accent']],
  ['cool', NEED_TEXT, ['卡片', '卡片+fill_cool', '卡片+fill_neutral']],
  ['warm', NEED_TEXT, ['卡片', '卡片+fill_accent']],
  ['caution', NEED_TEXT, ['卡片', '卡片+fill_accent']],
  ['frost', NEED_TEXT, ['卡片']],
  ['muted_fill', NEED_GRAPHIC, ['卡片']],
  ['chart_bar', NEED_GRAPHIC, ['卡片']],
  ['accent_soft', NEED_GRAPHIC, ['卡片']],
]

// 服务卡片是另一套环境：底色 card_bg 不透明，不受光晕影响。
const WIDGET_TILES = ['card_tile_soft', 'card_tile_accent', 'card_tile_cool', 'card_tile_caution']
const WIDGET_FGS = ['text_primary', 'text_secondary', 'text_tertiary', 'accent', 'cool', 'caution']

// 实心底按钮：底是不透明主题色，盖住了背景，跟光晕无关，所以上面那套扫描扫不到它。
// 1.0.2 复审又被点了一条「关闭空调 1.86」就是漏在这儿——深色的 accent 是亮绿
// #5FCE8C，白字压上去只有 1.96:1。凡是「实心色块 + 其上前景」的配对都得列进来。
// 白色写成字面量，因为它不是色板里的资源。
const SOLID_PAIRS = [
  { bg: 'accent', fg: 'on_accent', need: NEED_TEXT, what: '主色按钮（关闭空调 / 登录 / 标定页主按钮）' },
  { bg: 'fill_disabled', fg: '#FFFFFF', need: NEED_TEXT, what: '禁用态实心按钮 + 白字' },
]

// ── 与 LeapGlass.ets 的一致性 ───────────────────────────────────────────
async function assertGlowInSync() {
  const src = await readFile(GLASS_ETS, 'utf-8')
  const nums = (re) => [...src.matchAll(re)].map((m) => Number(m[1]))
  const problems = []

  // 尾巴上那个可选的 `* this.tintIntensity` 是「同一个色但更弱」那一档（空调关机时压到 0.6）。
  // 倍率只会把光晕整体调弱、合成色更靠近底色，所以按满强度（intensity = 1）这档校对就是最坏情况。
  const tintAlphas = nums(/LeapColors\.alpha\(this\.tint,\s*([\d.]+)(?:\s*\*\s*this\.tintIntensity)?\)/g)
  const coolAlphas = nums(/LeapColors\.alpha\(LeapColors\.coolGlow,\s*([\d.]+)\)/g)
  const eq = (a, b) => a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) < 1e-9)

  if (!eq(tintAlphas, GLOW_TINT.map((s) => s[0]))) {
    problems.push(`顶部光晕 alpha：LeapGlass.ets 是 [${tintAlphas}]，脚本按 [${GLOW_TINT.map((s) => s[0])}] 在算`)
  }
  if (!eq(coolAlphas, GLOW_COOL.map((s) => s[0]))) {
    problems.push(`右下光晕 alpha：LeapGlass.ets 是 [${coolAlphas}]，脚本按 [${GLOW_COOL.map((s) => s[0])}] 在算`)
  }
  for (const [label, want] of [
    ['corner(0.5, 0.75, true)', `${TINT_CENTER[0]}, ${TINT_RADIUS}`],
    ['corner(0.06, 0.75, false)', `${TINT_CENTER[1]}, ${TINT_RADIUS}`],
    ['corner(0.9, 0.62, true)', `${COOL_CENTER[0]}, ${COOL_RADIUS}`],
    ['corner(0.8, 0.62, false)', `${COOL_CENTER[1]}, ${COOL_RADIUS}`],
  ]) {
    if (!src.includes(`corner(${want},`)) problems.push(`光晕圆心/半径对不上：LeapGlass.ets 里找不到 ${label}`)
  }
  return problems
}

// ── 不许拿「变淡」表达状态 ──────────────────────────────────────────────
// `.opacity()` 作用在**渲染好的子树**上，底和前景会一起被拉向下面的表面，
// 对比度成比例地掉。这套色板再怎么调都救不回来：整块 0.55 时正文只剩 2.72:1，
// 0.5 时「关闭空调」只剩 2.51:1——上架检测点名的 1.55（获取验证码）和
// 1.86（关闭空调）都是这个来路。要抬回 4.5 得把 opacity 提到 0.9，
// 那个程度肉眼看不出变淡，等于没反馈。
//
// 所以规则是：**禁用态、下发中一律不用 opacity**，改成换色（`text_disabled`）
// 或者加转圈。这里直接扫源码，比事后算色值可靠。
// 0 和 1 放行——那是整块显隐/交叉淡入（`VehicleHero` 的 3D 就绪切换），不是变淡。
async function assertNoDimming() {
  const files = []
  const walk = async (dir) => {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      const p = join(dir, e.name)
      if (e.isDirectory()) await walk(p)
      else if (e.name.endsWith('.ets')) files.push(p)
    }
  }
  await walk(join(ROOT, 'entry/src/main/ets'))

  const problems = []
  for (const f of files.sort()) {
    const src = await readFile(f, 'utf-8')
    src.split('\n').forEach((line, i) => {
      // 块注释也得跳过：讲清楚 iOS 那边为什么写 `.opacity(0.6)`、这边为什么不跟，
      // 是注释该干的事，不是这边真在用。只认行首，行尾挂注释的真代码照样查。
      const head = line.trimStart()
      if (head.startsWith('//') || head.startsWith('*') || head.startsWith('/*')) return
      const m = /\.opacity\(([^)]*)\)/.exec(line)
      if (!m) return
      const partial = [...m[1].matchAll(/(?<![\w.])(0?\.\d+)/g)].map((x) => x[1])
      if (partial.length) {
        problems.push(`${f.slice(ROOT.length + 1)}:${i + 1}  .opacity(${partial.join(' / ')})  →  ${line.trim()}`)
      }
    })
  }
  return problems
}

// ── 禁用态实心按钮上不许用 text_disabled ────────────────────────────────
// `text_disabled` 是给**卡片底**准备的深灰，落在卡片上够 4.5:1；可它一旦压到
// `fill_disabled`（禁用按钮那块中性灰）上，浅色下只有 1.51:1——上面 SOLID_PAIRS
// 那条量的是「fill_disabled + 白字」，量不到代码里实际用的是哪个前景。
// 禁用态按钮的文字就曾因此糊成一片。
// 判据：同一段里出现 `.backgroundColor(... fillDisabled ...)`，往上 12 行内
// 不许有 `LeapStyle.textDisabled`。禁用态的前景写 `Color.White`。
async function assertDisabledButtonForeground() {
  const files = []
  const walk = async (dir) => {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      const p = join(dir, e.name)
      if (e.isDirectory()) await walk(p)
      else if (e.name.endsWith('.ets')) files.push(p)
    }
  }
  await walk(join(ROOT, 'entry/src/main/ets'))

  const problems = []
  for (const f of files.sort()) {
    const lines = (await readFile(f, 'utf-8')).split('\n')
    lines.forEach((line, i) => {
      if (line.trimStart().startsWith('//')) return
      if (!/\.backgroundColor\([^)]*fillDisabled/.test(line)) return
      for (let j = Math.max(0, i - 12); j < i; j++) {
        if (lines[j].trimStart().startsWith('//')) continue
        if (lines[j].includes('LeapStyle.textDisabled')) {
          problems.push(`${f.slice(ROOT.length + 1)}:${j + 1}  禁用底 fillDisabled 上用了 textDisabled  →  ${lines[j].trim()}`)
        }
      }
    })
  }
  return problems
}

// ── 跑 ──────────────────────────────────────────────────────────────────
async function readPalette(mode) {
  const raw = JSON.parse(await readFile(join(RES, mode, 'element/color.json'), 'utf-8'))
  return Object.fromEntries(raw.color.map((c) => [c.name.replace(/^leap_/, ''), c.value]))
}

async function main() {
  const verbose = process.argv.includes('--verbose')
  let failed = 0

  log.step('校对光晕参数与 LeapGlass.ets 是否一致')
  const drift = await assertGlowInSync()
  if (drift.length) {
    drift.forEach((d) => log.fail(d))
    log.warn('光晕参数变了就得同步改本脚本顶部的常量，否则算出来的背景是错的')
    process.exit(2)
  }
  log.info('一致')

  log.step('扫源码：禁用态实心按钮的前景是不是白字')
  const wrongFg = await assertDisabledButtonForeground()
  if (wrongFg.length) {
    wrongFg.forEach((d) => log.fail(d))
    log.warn('text_disabled 是卡片底上的深灰，压在 fill_disabled 上只有 1.51:1。禁用态前景写 Color.White。')
    failed += wrongFg.length
  } else {
    log.info('是')
  }

  log.step('扫源码：有没有拿 opacity 表达禁用/下发中')
  const dimmed = await assertNoDimming()
  if (dimmed.length) {
    dimmed.forEach((d) => log.fail(d))
    log.warn('变淡会把底和前景一起拉向背景，对比度必掉。改成换色（text_disabled）或加转圈。')
    failed += dimmed.length
  } else {
    log.info('没有')
  }

  for (const [mode, label] of [['base', '浅色'], ['dark', '深色']]) {
    const P = await readPalette(mode)
    log.step(`${label}（glass_tint ${P.glass_tint}）`)
    for (const [key, need, surfaces] of CHECKS) {
      if (P[key] === undefined) {
        log.warn(`${key} 在 ${mode}/color.json 里没有，跳过`)
        continue
      }
      let lowest = Infinity
      let where = ''
      const parts = []
      for (const name of surfaces) {
        const { ratio, at } = worst(P, key, SURFACES[name])
        parts.push(`${name}=${ratio.toFixed(2)}`)
        if (ratio < lowest) { lowest = ratio; where = at }
      }
      const ok = lowest >= need
      if (!ok) failed++
      const line = `${ok ? paint('32', '✓') : paint('31;1', '✗')} ${key.padEnd(15)} ${String(P[key]).padStart(10)}  需${need}  最差 ${lowest.toFixed(2)}`
      console.log(`  ${line}${verbose ? `   (${parts.join(', ')})` : ''}`)
      if (!ok) log.info(`    ↑ 最差出现在 ${where}`)
    }

    // 实心底按钮：底不透明，直接算
    for (const { bg, fg, need, what } of SOLID_PAIRS) {
      if (P[bg] === undefined) { log.warn(`${bg} 不在 ${mode}/color.json 里，跳过`); continue }
      const fgSrc = fg.startsWith('#') ? fg : P[fg]
      if (fgSrc === undefined) { log.warn(`${fg} 不在 ${mode}/color.json 里，跳过`); continue }
      const bgRgb = parseColor(P[bg]).rgb
      const ratio = contrast(over(parseColor(fgSrc), bgRgb), bgRgb)
      const ok = ratio >= need
      if (!ok) failed++
      const label = `${fg.startsWith('#') ? '白字' : fg} on ${bg}`
      console.log(`  ${ok ? paint('32', '✓') : paint('31;1', '✗')} ${label.padEnd(24)} ${String(fgSrc).padStart(10)}  需${need}  ${ratio.toFixed(2)}`)
      if (!ok) log.info(`    ↑ ${what}`)
    }

    // 服务卡片：底不透明
    const base = parseColor(P.card_bg).rgb
    for (const fg of WIDGET_FGS) {
      const surfaces = [['卡片底', base], ...WIDGET_TILES.map((t) => [t, over(parseColor(P[t]), base)])]
      for (const [name, bg] of surfaces) {
        const r = contrast(over(parseColor(P[fg]), bg), bg)
        if (r < NEED_TEXT) {
          failed++
          log.fail(`服务卡片 ${fg} on ${name}（${hex(bg)}）= ${r.toFixed(2)}，需 ${NEED_TEXT}`)
        }
      }
    }
  }

  log.step('结果')
  if (failed) {
    log.fail(`${failed} 项不达标`)
    log.info('调色时记住：深色的 glass_tint 是叠黑的，卡片压在背景之下；')
    log.info('把它改回叠白，光晕会把卡片抬亮到纯白文字都不够 4.5:1 的程度。')
    process.exit(1)
  }
  console.log(paint('32;1', '  全部达标'))
}

main().catch((e) => { log.fail(e.message); process.exit(2) })
