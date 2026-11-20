import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = fileURLToPath(import.meta.url);
if (!process.env.LEAP_WIDGET_SELFTEST_CHILD) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', here], {
    stdio: 'inherit', env: { ...process.env, LEAP_WIDGET_SELFTEST_CHILD: '1' },
  });
  process.exit(child.status ?? 1);
}

const root = path.resolve(path.dirname(here), '..');
const files = ['core/JsonValue.ets', 'core/SignalSchema.ets', 'app/VehicleSnapshot.ets', 'formability/LeapFormAbility.ets'];
const models = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/LeapModels.ets'), 'utf8');
const vehicleState = models.slice(models.indexOf('export class VehicleState {'), models.indexOf('export enum ExpectationKind'));
const source = files.map(file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8'))
  .join('\n').replace(/^import\s[\s\S]*?;\s*$/gm, '').replace('export default class', 'export class');
const prelude = `
class FormExtensionAbility {}
class SharedSettings {
  static values = new Map<string, string>();
  static getString(key: string, fallback: string) { return this.values.get(key) ?? fallback; }
  static setString(key: string, value: string) { this.values.set(key, value); }
}
class LeapCommand {
  static lock() { return 'lock'; }
  static unlock() { return 'unlock'; }
}
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leap-widget-test-'));
try {
  const modulePath = path.join(directory, 'widget.mts');
  fs.writeFileSync(modulePath, prelude + source + vehicleState);
  const { WidgetButtonLayout, WidgetSettings, SnapshotUtil, LeapFormAbility, VehicleState, SignalSchema } = await import(pathToFileURL(modulePath));
  assert.deepEqual(WidgetSettings.buttons(false), ['toggleLock', 'toggleClimate', 'trunk', 'horn']);
  assert.deepEqual(WidgetButtonLayout.normalize(['unlock', 'invalid', 'unlock', 'lock'], true), ['unlock', 'lock']);
  const ordered = ['lock', 'unlock', 'horn', 'trunk'];
  assert.deepEqual(WidgetButtonLayout.moving(ordered, 0, 3), ['unlock', 'horn', 'trunk', 'lock']);
  assert.deepEqual(WidgetButtonLayout.moving(ordered, 3, 0), ['trunk', 'lock', 'unlock', 'horn']);
  assert.deepEqual(WidgetButtonLayout.moving(['lock', 'unlock'], 1, 0), ['unlock', 'lock']);
  assert.deepEqual(WidgetButtonLayout.moving(ordered, -1, 2), ordered);
  assert.deepEqual(WidgetButtonLayout.moving(ordered, 2, 2), ordered);
  WidgetSettings.setButtons(false, ['unlock', 'lock', 'horn', 'trunk']);
  WidgetSettings.setButtons(true, ['horn', 'lock']);
  assert.deepEqual(WidgetSettings.buttons(false), ['unlock', 'lock', 'horn', 'trunk']);
  assert.deepEqual(WidgetSettings.buttons(true), ['horn', 'lock']);
  for (const isLocked of [true, false, null]) {
    const snapshot = { ...SnapshotUtil.placeholder(), isLocked };
    assert.equal(LeapFormAbility.command('lock', snapshot), 'lock');
    assert.equal(LeapFormAbility.command('unlock', snapshot), 'unlock');
    assert.equal(SnapshotUtil.optimistic('lock', snapshot).isLocked, true);
    assert.equal(SnapshotUtil.optimistic('unlock', snapshot).isLocked, false);
  }
  for (const action of ['lock', 'unlock']) {
    assert.equal(LeapFormAbility.parseAction(JSON.stringify({ leapAction: action })), action);
  }
  // 真机回归：2188 不变，中卡跟随 WLTC / CLTC 的电油分项。
  const state = new VehicleState();
  state.schema = SignalSchema.numeric;
  state.isExtendRange = true;
  state.signalMap = new Map(Object.entries({ '100003': '75', '2188': '254', '3262': '1',
    '3257': '150', '3256': '433', '3260': '114', '3259': '365' }));
  const snapshot = SnapshotUtil.make(state, '测试车', null);
  assert.equal(snapshot.rangeKm, 254);
  assert.equal(SnapshotUtil.mediumRangeText(snapshot), '电 114 · 油 365 km');
  assert.equal(SnapshotUtil.mediumRangeText(JSON.parse(JSON.stringify(snapshot))), '电 114 · 油 365 km');
  state.signalMap.set('3260', '110');
  const refreshed = SnapshotUtil.merged(state, snapshot);
  assert.equal(refreshed.isExtendRange, true);
  assert.equal(SnapshotUtil.mediumRangeText(refreshed), '电 110 · 油 365 km');
  state.signalMap.set('3262', '0');
  assert.equal(SnapshotUtil.mediumRangeText(SnapshotUtil.make(state, '测试车', null)), '电 150 · 油 433 km');
  state.signalMap.set('3262', '1');
  state.signalMap.delete('3260');
  assert.equal(SnapshotUtil.mediumRangeText(SnapshotUtil.merged(state, snapshot)), '油 365 km');
  state.signalMap.set('3259', '0');
  assert.equal(SnapshotUtil.mediumRangeText(SnapshotUtil.merged(state, snapshot)), '油 0 km');
  state.signalMap.delete('3259');
  assert.equal(SnapshotUtil.mediumRangeText(SnapshotUtil.merged(state, snapshot)), '');
  state.isExtendRange = false;
  assert.equal(SnapshotUtil.mediumRangeText(SnapshotUtil.make(state, '测试车', null)), '254 km');
  const legacy = { ...snapshot };
  delete legacy.isExtendRange;
  assert.equal(SnapshotUtil.mediumRangeText(legacy), '电 114 · 油 365 km');
  assert.equal(SnapshotUtil.optimistic('lock', snapshot).isExtendRange, true);
  console.log('Widget configuration, lock/unlock commands and range regressions passed.');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
