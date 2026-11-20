#!/usr/bin/env node
// 不依赖 HarmonyOS SDK 的静态自查（只用 node 内置模块，不需要 DevEco）。
//
//   node scripts/static-check.mjs           有问题退出码 1
//   node scripts/static-check.mjs --verbose 连通过的项目也逐条打印
//
// 拦的都是「本地编译通过、装到手机上也看着正常，偏偏 release 包或上架时才炸」的那几类：
//
//   1. 深浅两套 color.json 的 key 对齐 —— 加一个色值要改两个文件，漏一边的话
//      那个模式下取不到色。leap_panel_tint 这次就是两边各加一次。
//   2. 配置文件能不能解析 —— app.json5 / build-profile.json5 / 卡片配置写坏了，
//      要到构建那一步才报，而且报得很难懂。
//   3. 混淆白名单覆盖 —— release 才混淆，debug 测不出来。判据见
//      entry/obfuscation-rules.txt 开头那段：名字出了这个 HAP 还有别人按字面量认它，
//      就必须留住。这里把「会落盘、跨进程、发出去」的那几个类型全列出来逐字段核对。
//   4. VehicleStore 的 @Monitor('store.xxx') 路径 —— VehicleStore 是导出类，
//      属性名会被 export-obfuscation 改掉，而装饰器参数位上的字面量不改，
//      两边一错开监听就静默失效：界面停止更新，还不报错。
//   5. @Monitor('store.xxx') 那个 store 必须是状态变量 —— 普通成员做监听路径的根，
//      运行期彻底不触发。编译器只给一句混在几十条 deprecated 里的警告，
//      而且 hvigor 增量编译只报改动过的文件，一次改一个文件永远看不全。
//      2026-08-10 全量编译一跑才发现五个组件全是坏的，最早那个从写下就没生效过。

import { readFile, readdir } from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const VERBOSE = process.argv.includes('--verbose')

const COLOR = process.stdout.isTTY && !process.env.NO_COLOR
const paint = (c, s) => (COLOR ? `\x1b[${c}m${s}\x1b[0m` : s)
const red = (s) => paint(31, s)
const green = (s) => paint(32, s)
const dim = (s) => paint(2, s)

const problems = []
const fail = (section, message) => problems.push(`${section}：${message}`)
const pass = (message) => { if (VERBOSE) console.log(`  ${green('✓')} ${message}`) }

// ─────────────────────────────────────────────────────────────────────
// 1. 深浅两套 color.json 的 key 必须一一对应
// ─────────────────────────────────────────────────────────────────────

async function checkColorParity() {
  console.log('\n▸ 深浅色资源对齐')
  const read = async (mode) => {
    const path = join(ROOT, `entry/src/main/resources/${mode}/element/color.json`)
    const parsed = JSON.parse(await readFile(path, 'utf8'))
    return new Map(parsed.color.map((item) => [item.name, item.value]))
  }
  const base = await read('base')
  const dark = await read('dark')

  const missingInDark = [...base.keys()].filter((k) => !dark.has(k))
  const missingInBase = [...dark.keys()].filter((k) => !base.has(k))

  for (const key of missingInDark) fail('深浅色资源', `dark 缺少 ${key}`)
  for (const key of missingInBase) fail('深浅色资源', `base 缺少 ${key}`)
  if (!missingInDark.length && !missingInBase.length) {
    pass(`两套各 ${base.size} 个色值，key 完全对应`)
  }

  // 同名同值多半是忘了改深色那一份（纯黑纯白这类中性色除外）。
  const neutral = new Set(['#FFFFFF', '#000000', '#00000000', '#FFFFFFFF'])
  const identical = [...base.entries()]
    .filter(([k, v]) => dark.get(k) === v && !neutral.has(v.toUpperCase()))
    .map(([k]) => k)
  if (identical.length && VERBOSE) {
    console.log(dim(`    提示：深浅同值 ${identical.length} 项（${identical.slice(0, 5).join(', ')}${identical.length > 5 ? ' …' : ''}）`))
  }
}

// ─────────────────────────────────────────────────────────────────────
// 2. 配置文件能不能解析
// ─────────────────────────────────────────────────────────────────────

/** JSON5 的极简解析：去注释、去尾逗号、给裸键补引号，够核对语法用。 */
function parseJson5(text) {
  const stripped = text
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1')
  const quoted = stripped
    .replace(/([{,]\s*)([A-Za-z_$][\w$]*)\s*:/g, '$1"$2":')
    .replace(/'((?:[^'\\]|\\.)*)'/g, (_, inner) => JSON.stringify(inner.replace(/\\'/g, "'")))
    .replace(/,(\s*[}\]])/g, '$1')
  return JSON.parse(quoted)
}

async function checkConfigs() {
  console.log('\n▸ 配置文件')
  const files = [
    'AppScope/app.json5',
    'build-profile.json5',
    'entry/build-profile.json5',
    'oh-package.json5',
    'entry/src/main/module.json5',
    'entry/src/main/resources/base/profile/form_config.json',
    'entry/src/main/resources/base/profile/main_pages.json',
  ]
  for (const relative of files) {
    const path = join(ROOT, relative)
    let text
    try {
      text = await readFile(path, 'utf8')
    } catch {
      continue // 目录结构会变，缺文件不算错，别让检查脚本自己绊倒构建
    }
    try {
      relative.endsWith('.json5') ? parseJson5(text) : JSON.parse(text)
      pass(`${relative} 可解析`)
    } catch (error) {
      fail('配置文件', `${relative} 解析失败：${error.message}`)
    }
  }

  // 版本号格式：AppScope 是真正打进包的。
  try {
    const app = parseJson5(await readFile(join(ROOT, 'AppScope/app.json5'), 'utf8'))
    const { versionName, versionCode } = app.app
    if (!/^\d+\.\d+\.\d+$/.test(versionName)) {
      fail('配置文件', `versionName「${versionName}」不是 x.y.z`)
    } else {
      pass(`版本 ${versionName}（versionCode ${versionCode}）`)
    }
  } catch (error) {
    fail('配置文件', `读版本号失败：${error.message}`)
  }
}

// ─────────────────────────────────────────────────────────────────────
// 3. 混淆白名单覆盖
// ─────────────────────────────────────────────────────────────────────

/**
 * 名字出了这个 HAP 之后还有别人按字面量认的类型，逐字段核对白名单。
 *
 * 加新类型的判据（和 obfuscation-rules.txt 开头那段一致）：落盘的 JSON、
 * 发给服务端的请求体、跨进程按名字取的数据、卡片按 key 绑的字段。
 * 纯内部的类不要往这儿加，白名单不是越长越好。
 */
const GUARDED_TYPES = [
  { file: 'entry/src/main/ets/core/LeapModels.ets', types: ['LeapSession', 'OldAuth', 'NewAuth', 'Vehicle', 'VehicleRoute'], why: '落 AssetVault，跨版本读回' },
  { file: 'entry/src/main/ets/app/VehicleSnapshot.ets', types: ['VehicleSnapshot'], why: 'App 与卡片进程共写同一个 JSON' },
  { file: 'entry/src/main/ets/app/FormPusher.ets', types: ['CardData'], why: '卡片按字面量 key 取值' },
  { file: 'entry/src/main/ets/app/ControlDiagnostic.ets', types: ['ControlDiagnostic', 'ReceiptSample'], why: '存首选项，跨版本读回' },
  { file: 'entry/src/main/ets/app/BLEVehicleBinding.ets', types: ['BLEVehicleBindingRecord', 'BLEConfigurationRecord', 'BLEKeyCertificateRecord'], why: '绑定记录与钥匙证书落 AssetVault，跨版本读回' },
]

/** 从 `interface X {…}` / `class X {…}` 里抠出属性名。够用就好，不做真正的解析。 */
function fieldsOf(source, typeName) {
  const header = new RegExp(`(?:export\\s+)?(?:interface|class)\\s+${typeName}\\b[^{]*\\{`, 'm')
  const start = source.match(header)
  if (!start) return null
  let index = start.index + start[0].length
  let depth = 1
  const body = []
  while (index < source.length && depth > 0) {
    const char = source[index]
    if (char === '{') depth++
    else if (char === '}') depth--
    if (depth > 0) body.push(char)
    index++
  }
  const text = body.join('')
  const fields = new Set()
  // `name: type` 或 `name = value`，跳过方法（后面跟括号的）和注释行。
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) continue
    const match = trimmed.match(/^(?:readonly\s+|static\s+|private\s+|@\w+\s+)*([A-Za-z_$][\w$]*)\s*[?!]?\s*[:=]/)
    if (!match) continue
    const rest = trimmed.slice(match[0].length).trim()
    if (rest.startsWith('(')) continue // 方法/箭头函数
    fields.add(match[1])
  }
  return fields
}

async function checkObfuscationKeeps() {
  console.log('\n▸ 混淆白名单')
  const rules = await readFile(join(ROOT, 'entry/obfuscation-rules.txt'), 'utf8')
  const section = rules.split('-keep-property-name')[1] ?? ''
  const kept = new Set(
    section.split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && !line.startsWith('-'))
  )
  if (!kept.size) {
    fail('混淆白名单', '没解析出任何 -keep-property-name 条目，规则文件格式变了？')
    return
  }

  for (const group of GUARDED_TYPES) {
    let source
    try {
      source = await readFile(join(ROOT, group.file), 'utf8')
    } catch {
      fail('混淆白名单', `读不到 ${group.file}`)
      continue
    }
    for (const type of group.types) {
      const fields = fieldsOf(source, type)
      if (!fields) {
        fail('混淆白名单', `${group.file} 里找不到类型 ${type}（改名了就同步改 GUARDED_TYPES）`)
        continue
      }
      const missing = [...fields].filter((f) => !kept.has(f))
      if (missing.length) {
        fail('混淆白名单', `${type}（${group.why}）的字段没进白名单：${missing.join(', ')}`)
      } else {
        pass(`${type} ${fields.size} 个字段都在白名单`)
      }
    }
  }

  // @Monitor 的路径是字符串字面量，装饰器参数位上不改名，被监听的属性却会——
  // 两边一错开监听就静默失效。
  //
  // 监听组件自己的属性（@Param / @Local）同样要留：`-enable-property-obfuscation`
  // 混的是所有属性，不限于导出类。这里原来只扫 'store.xxx'，于是漏掉了
  // MileageStatsView 的 @Monitor('entries')——@Param entries 会被改名，图表在
  // release 包里不随数据刷新，debug 测不出来。
  const monitored = new Set()
  await walk(join(ROOT, 'entry/src/main/ets'), (path, text) => {
    if (!path.endsWith('.ets')) return
    for (const call of text.matchAll(/@Monitor\(([^)]*)\)/g)) {
      // 一个 @Monitor 可以写多条路径，逐个取。
      for (const arg of call[1].matchAll(/'([^']+)'/g)) {
        const segments = arg[1].split('.')
        // 'store.xxx' 认的是 VehicleStore 的属性，'xxx' 认的是组件自己的。
        const name = segments[0] === 'store' ? segments[1] : segments[0]
        if (name) monitored.add(name)
      }
    }
  })
  const missingMonitors = [...monitored].filter((name) => !kept.has(name))
  if (missingMonitors.length) {
    fail('混淆白名单', `@Monitor 监听的属性没进白名单：${missingMonitors.join(', ')}`)
  } else {
    pass(`@Monitor 监听的 ${monitored.size} 个属性都在白名单`)
  }
}

// ─────────────────────────────────────────────────────────────────────
// 5. @Monitor('store.xxx') 的根必须是状态变量
// ─────────────────────────────────────────────────────────────────────

/** 能让 @Monitor 追得下去的持有方式。普通成员不在其列。 */
const STATE_DECORATORS = new Set(['@Local', '@Param', '@Provider', '@Consumer'])

async function checkMonitorRoots() {
  console.log('\n▸ @Monitor 监听根')
  let checked = 0
  await walk(join(ROOT, 'entry/src/main/ets'), (path, text) => {
    if (!path.endsWith('.ets')) return
    if (!/@Monitor\(\s*'store\./.test(text)) return
    checked += 1
    const where = relative(ROOT, path)

    // 声明和装饰器写在同一行是本项目的一贯写法（@Local store: VehicleStore = ...）。
    const decl = text.match(/^[ \t]*(@\w+)?[ \t]*store\s*:\s*VehicleStore\b/m)
    if (!decl) {
      fail('@Monitor 监听根', `${where} 里有 @Monitor('store.…') 却找不到 store 的声明`)
      return
    }
    const decorator = decl[1] ?? ''
    if (!STATE_DECORATORS.has(decorator)) {
      const how = decorator ? `用 ${decorator} 持有` : '是普通成员'
      fail('@Monitor 监听根',
        `${where} 的 store ${how}，@Monitor 运行期不会触发。改成 @Local 持有`)
      return
    }
    pass(`${where} 的 store 用 ${decorator} 持有`)
  })
  if (!checked) {
    fail('@Monitor 监听根', "一个 @Monitor('store.…') 都没扫到，写法变了就同步改这条规则")
    return
  }
  pass(`${checked} 个组件的监听根都立得住`)
}

async function walk(dir, visit) {
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) {
      if (entry.name === 'build' || entry.name === 'oh_modules') continue
      await walk(path, visit)
    } else if (entry.isFile()) {
      visit(path, await readFile(path, 'utf8'))
    }
  }
}

// ─────────────────────────────────────────────────────────────────────

console.log('壹跑 · 静态自查')
await checkColorParity()
await checkConfigs()
await checkObfuscationKeeps()
await checkMonitorRoots()

console.log('\n▸ 结果')
if (problems.length) {
  for (const problem of problems) console.log(`  ${red('✗')} ${problem}`)
  console.log(`\n${red(`${problems.length} 项不通过`)}`)
  process.exit(1)
}
console.log(`  ${green('全部通过')}`)
