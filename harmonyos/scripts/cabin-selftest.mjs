// 舒适座舱 / 车载冰箱 / 启停充电 / 预约空调 / 锁车后检查 / 控车条排序的自测。
//
// 断言照搬 iOS aac5db5 的四组单测（CabinComfortTests、RemoteChargeAndScheduleTests、
// LeapautoGapRound3Tests、QuickControlOrderTests），跑的是鸿蒙的生产代码，
// 只把 import 去掉、拼成一个模块。双端同源，一端的断言就是另一端的验收清单。
//
// 运行：node scripts/cabin-selftest.mjs（需要 Node 22.7+，DevEco 自带的 18 不行）。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = fileURLToPath(import.meta.url);
if (!process.env.LEAP_CABIN_SELFTEST_CHILD) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', here], {
    stdio: 'inherit', env: { ...process.env, LEAP_CABIN_SELFTEST_CHILD: '1' },
  });
  process.exit(child.status ?? 1);
}
const root = path.resolve(path.dirname(here), '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
const strip = text => text.replace(/^import\s[\s\S]*?;\s*$/gm, '').replace(/^export \{[^}]+\} from [^;]+;$/gm, '');
const source = ['JsonValue', 'SignalSchema', 'CabinComfort', 'ClimateAppointment', 'LeapError', 'LeapModels']
  .map(name => strip(read(`core/${name}.ets`))).join('\n');
// 控车条排序那段是 QuickControlBar.ets 文件内部的，截出 enum + 排序类，SharedSettings 换成内存版。
const bar = read('views/components/QuickControlBar.ets');
const orderSource = bar.slice(bar.indexOf('enum QuickControl {'), bar.indexOf('/**\n * 车辆主视觉下面'));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leap-cabin-test-'));
try {
  const modulePath = path.join(directory, 'cabin.mts');
  fs.writeFileSync(modulePath, `const DiagLog = { note() {} };
const LeapCrypto = {};
const SharedSettings = { store: new Map(), getString(k, d) { return this.store.get(k) ?? d; }, setString(k, v) { this.store.set(k, v); } };
` + source + '\n' + orderSource + `
export { QuickControl, QuickControlOrder };`);
  const m = await import(pathToFileURL(modulePath));
  const {
    VehicleState, SignalSchema, LeapCommand, ControlExpectation, ExpectationKind, VehicleUtil,
    SeatPosition, SeatComfortChannel, FridgeSetting, FridgeMode, FridgeStyle, FridgePreset, FridgeText,
    ClimateAppointment, ClimateAppointmentMode, AppointmentWeekday, JsonValue, ClimateMode,
    QuickControlOrder
  } = m;

  const state = pairs => {
    const s = new VehicleState();
    s.signalMap = new Map(Object.entries(pairs));
    s.schema = SignalSchema.detect(s.signalMap);
    return s;
  };
  const json = raw => JSON.parse(raw);

  // C16 的 signalMap 片段（同 iOS CabinComfortTests.c16；经纬度已平移脱敏）。
  const c16 = {
    '1': '1786972478598', '100003': '90.6', '1204': '91',
    '2100': '0', '2101': '0', '2118': '0', '2119': '0',
    '1879': '0', '3727': '0', '1880': '0', '3728': '0',
    '1816': '0', '1624': '15', '49': '0', '50': '0', '1946': '0',
    '1938': '0', '1943': '1', '2669': '0', '2681': '0', '3713': '1',
    '2': '120.215527', '3': '30.246109', '2190': '120.210028', '2191': '30.247968',
    '3724': '120.210009', '3725': '30.24797', 'sts': '1786972478119'
  };
  const c16Abilities = ['1', '2', '3', '5', '6', '7', '10', '11', '12', '13', '14', '15', '19', '20', '21',
    '22', '23', '24', '29', '30', '31', '32', '34', '35', '38', '39', '41', '42', '43', '45', '46', '47', '48', '49',
    '50', '51', '52', '53', '55', '56', '57', '58', '59', '60', '61', '65', '66', '67', '68', '71', '72', '73', '74',
    '75', '82', '87', '88', '89'];
  const D = SeatPosition, H = SeatComfortChannel.heating, V = SeatComfortChannel.ventilation;

  // ── 座椅
  {
    const s = state({ ...c16, '2100': '3', '2119': '2', '1879': '1', '3728': '3' });
    assert.equal(s.seatLevel(D.driver, H), 3);
    assert.equal(s.seatLevel(D.passenger, V), 2);
    assert.equal(s.seatLevel(D.leftRear, H), 1);
    assert.equal(s.seatLevel(D.rightRear, V), 3);
    assert.equal(s.seatLevel(D.driver, V), 0);
    assert.ok(s.hasSeatComfort && s.hasRearSeatComfort && s.hasCabinComfort);
  }
  {
    const front = { ...c16 };
    for (const key of ['1879', '3727', '1880', '3728']) delete front[key];
    const s = state(front);
    assert.equal(s.seatLevel(D.leftRear, H), null);
    assert.equal(s.seatLevel(D.rightRear, V), null);
    assert.equal(s.hasRearSeatComfort, false);
    assert.equal(s.seatLevel(D.driver, H), 0);
    assert.deepEqual(s.seats(H), [D.driver, D.passenger]);
  }
  {
    // 老口径（S01/T03）一个座舱字段都没有
    const s = state({ soc: '80', acSwitch: '0' });
    assert.equal(s.schema, SignalSchema.legacy);
    assert.equal(s.hasCabinComfort, false);
    assert.equal(s.steeringWheelHeatLevel, null);
    assert.equal(s.mirrorHeatingOn, null);
    assert.equal(s.fridgeState, null);
  }
  assert.equal(state({ ...c16, '2100': '7' }).seatLevel(D.driver, H), 3, '越界档位夹到 3');
  // ── 方向盘：1624 在关闭时也非 0，不能当加热中
  assert.equal(state(c16).steeringWheelHeatLevel, 0);
  assert.equal(state(c16).steeringWheelHeatMinutes, null);
  assert.equal(state({ ...c16, '1816': '2' }).steeringWheelHeatLevel, 2);
  assert.equal(state({ ...c16, '1816': '2' }).steeringWheelHeatMinutes, 15);
  assert.equal(state({ ...c16, '1816': '5' }).steeringWheelHeatLevel, 2);
  // ── 后视镜
  assert.equal(state({ ...c16, '49': '1' }).mirrorHeatingOn, true);
  assert.equal(state({ ...c16, '49': '1' }).mirrorHeatingMismatched, true);
  assert.equal(state({ ...c16, '49': '1', '50': '1' }).mirrorHeatingMismatched, false);
  {
    const none = { ...c16 }; delete none['49']; delete none['50'];
    assert.equal(state(none).mirrorHeatingOn, null);
  }
  // ── 冰箱
  assert.equal(state(c16).fridgeState, null);
  assert.equal(state({ ...c16, '11260': '0' }).fridgeState, null);
  {
    const f = state({ ...c16, '10709': '1', '10708': '1', '10707': '50', '10711': '1', '10712': '0',
      '11190': '1', '11189': '3', '11191': '0', '11260': '1786980000' }).fridgeState;
    assert.equal(f.enabled, true);
    assert.equal(f.mode, FridgeMode.hot);
    assert.equal(f.style, FridgeStyle.turbo);
    assert.equal(f.hasFault, false);
    assert.equal(f.parkEnabled, true);
    assert.equal(f.parkHours, 3);
    assert.equal(f.parkEndsAt, 1786980000 * 1000);
  }
  assert.equal(state({ ...c16, '10709': '0', '10712': '3' }).fridgeState.fault, 3);
  assert.equal(state({ ...c16, '10709': '0', '11260': '0' }).fridgeState.parkEndsAt, null);

  // ── 指令
  {
    const heat = LeapCommand.seatComfort(D.driver, H, 3);
    assert.equal(heat.cmdid, '301');
    assert.deepEqual(json(heat.stateJSON), { position: 'left_front', level: '3' });
    assert.equal(heat.label, '主驾加热 3 档');
    const vent = LeapCommand.seatComfort(D.rightRear, V, 0);
    assert.equal(vent.cmdid, '370');
    assert.deepEqual(json(vent.stateJSON), { position: 'right_rear', level: '0' });
    assert.equal(vent.label, '二排右通风关闭');
    const wheel = LeapCommand.steeringWheelHeating(2);
    assert.equal(wheel.cmdid, '320');
    assert.equal(wheel.stateJSON, '{"level":2}');
    assert.equal(wheel.label, '方向盘加热强档');
    assert.equal(LeapCommand.mirrorHeating(true).cmdid, '440');
    assert.equal(json(LeapCommand.mirrorHeating(true).stateJSON).value, '2');
    assert.equal(json(LeapCommand.mirrorHeating(false).stateJSON).value, '1');
  }
  {
    const command = LeapCommand.fridge(new FridgeSetting());
    assert.equal(command.cmdid, '500');
    const payload = json(command.stateJSON);
    assert.deepEqual(payload, { cycles: '1', duration: 3600, enable: 1, mode: 'cold', parkEnable: 0,
      style: 'normal', temp: 4, value: 'false' });
    // 和 iOS sortedKeys 逐字一致
    assert.equal(command.stateJSON,
      '{"cycles":"1","duration":3600,"enable":1,"mode":"cold","parkEnable":0,"style":"normal","temp":4,"value":"false"}');
    const setting = new FridgeSetting();
    setting.apply(FridgePreset.keepWarm);
    assert.equal(setting.mode, FridgeMode.hot);
    assert.equal(setting.wireTemperature, 50);
    assert.equal(setting.temperature, 4, '切保温不覆盖制冷温度');
    const frozen = new FridgeSetting();
    frozen.apply(FridgePreset.freeze);
    assert.equal(frozen.temperature, -6);
    const short = new FridgeSetting(); short.parkHours = 0;
    assert.equal(short.durationSeconds, FridgeSetting.minDurationSeconds);
    short.parkHours = 3;
    assert.equal(short.durationSeconds, 10800);
    assert.equal(FridgeText.matching(FridgeMode.cold, 4), FridgePreset.chill);
    assert.equal(FridgeText.matching(FridgeMode.cold, -6), FridgePreset.freeze);
    assert.equal(FridgeText.matching(FridgeMode.hot, 50), FridgePreset.keepWarm);
    assert.equal(FridgeText.matching(FridgeMode.cold, 8), null);
    const clamp = new FridgeSetting(); clamp.temperature = 40;
    assert.equal(clamp.wireTemperature, 15);
    clamp.temperature = -20;
    assert.equal(clamp.wireTemperature, -6);
  }

  // ── 确认判据
  {
    const e = ControlExpectation.seatLevel(D.driver, H, 2);
    assert.equal(e.isSatisfied(state(c16)), false);
    assert.equal(e.isSatisfied(state({ ...c16, '2100': '2' })), true);
    assert.equal(e.isSatisfied(state({ ...c16, '2100': '1' })), false);
    const missing = { ...c16 }; delete missing['2100'];
    assert.equal(e.isSatisfied(state(missing)), false);
    const mirror = ControlExpectation.mirrorHeating(true);
    assert.equal(mirror.isSatisfied(state(c16)), false);
    assert.equal(mirror.isSatisfied(state({ ...c16, '49': '1' })), true);
    assert.equal(mirror.isSatisfied(state({ ...c16, '1946': '1' })), true);
    assert.equal(ControlExpectation.steeringWheelLevel(1).isSatisfied(state({ ...c16, '1816': '1' })), true);

    const setting = new FridgeSetting();
    const fridge = ControlExpectation.fridge(setting);
    assert.equal(fridge.isSatisfied(state(c16)), false);
    const ok = { ...c16, '10709': '1', '10708': '0', '10707': '4', '10711': '0' };
    assert.equal(fridge.isSatisfied(state(ok)), true);
    const noTemp = { ...ok }; delete noTemp['10707'];
    assert.equal(fridge.isSatisfied(state(noTemp)), true, '目标温度没报不作否决');
    assert.equal(fridge.isSatisfied(state({ ...ok, '10707': '8' })), false);
    const off = new FridgeSetting(); off.enabled = false;
    assert.equal(ControlExpectation.fridge(off).isSatisfied(state({ ...c16, '10709': '0', '10708': '1' })), true);
    // 下发后改草稿不影响已发那条的判据（深拷贝）
    setting.temperature = 10;
    assert.equal(fridge.isSatisfied(state(ok)), true);
  }

  // ── 能力码与门控
  {
    const permission = VehicleUtil.permissionCodes(c16Abilities);
    assert.ok(permission.includes('301') && permission.includes('370') && permission.includes('440'));
    assert.ok(!permission.includes('500'));
    assert.equal(permission.filter(code => code === '370').length, 1, '42/43 都翻成 370，只留一个');
    assert.ok(VehicleUtil.supportsCabinComfort('C16', permission));
    assert.ok(!VehicleUtil.supportsFridge('C16', permission));
    assert.ok(!VehicleUtil.supportsCabinComfort('S01', permission));
    assert.ok(!VehicleUtil.supportsCabinComfort('T03', permission));
    assert.ok(!VehicleUtil.supportsCabinComfort('T03-2023', permission));
    assert.ok(!VehicleUtil.supportsFridge('S01', permission));
    assert.ok(!VehicleUtil.supportsCabinComfort('C11', ['400', '240']));
  }

  // ── 经纬度 / 1943 / 2669 / 2681 / 除雾
  {
    const s = state(c16);
    assert.equal(s.longitude, 120.210009);
    assert.equal(s.latitude, 30.24797);
    const legacyPair = { ...c16 };
    for (const key of ['3724', '3725', '2190', '2191']) delete legacyPair[key];
    assert.equal(state(legacyPair).longitude, 120.215527);
    assert.equal(state(legacyPair).latitude, 30.246109);
    assert.equal(state(c16).acCircleIn, true);
    assert.equal(state({ ...c16, '1943': '0' }).acCircleIn, false);
    assert.equal(state({ ...c16, '2669': '1', '2681': '0' }).rapidCoolingOn, true);
    assert.equal(state({ ...c16, '2669': '1', '2681': '0' }).rapidHeatingOn, false);
    const defrost = json(LeapCommand.defrost().stateJSON);
    assert.equal(defrost.circle, 'out');
    assert.equal(defrost.position, 'wshld');
    assert.equal(defrost.wshld, '1');
    assert.equal(defrost.mode, 'hot');
    assert.equal(defrost.temperature, '32');
    const normal = json(LeapCommand.climate(true, 24, 3, ClimateMode.cold, true, false).stateJSON);
    assert.equal(normal.position, 'all');
    assert.equal(normal.circle, 'in');
    assert.equal(normal.wshld, '0');
  }

  // ── 遮阳帘 / 天窗
  const base = { '1204': '80', '1318': '1000', 'sts': '1' };
  const withBase = extra => state({ ...base, ...extra });
  assert.equal(withBase({ '1724': '0' }).sunshadeOpen, false);
  assert.equal(withBase({ '1724': '0' }).sunroofOpen, null);
  assert.equal(withBase({ '1724': '100' }).sunshadeOpen, true);
  assert.equal(withBase({ '1718': '10' }).sunroofOpen, true);
  assert.equal(withBase({ '1718': '0' }).sunroofOpen, false);
  assert.equal(withBase({ '1718': '15' }).sunroofOpen, null);
  assert.equal(withBase({ '1718': '150' }).sunroofOpen, null);
  assert.equal(LeapCommand.sunshade(true).expectation.kind, ExpectationKind.unobservable);
  assert.equal(LeapCommand.sunshade(true, true).expectation.kind, ExpectationKind.sunshadeOpen);
  assert.equal(LeapCommand.sunroof(false, true).expectation.kind, ExpectationKind.sunroofOpen);
  {
    const e = ControlExpectation.sunshadeOpen(true);
    assert.equal(e.isSatisfied(withBase({ '1724': '0' })), false);
    assert.equal(e.isSatisfied(withBase({ '1724': '10' })), true);
    assert.equal(e.isSatisfied(withBase({ '1724': '100' })), true);
    assert.equal(json(LeapCommand.sunshade(true, true).stateJSON).value, '10');
    assert.equal(json(LeapCommand.sunshade(false).stateJSON).value, '0');
    assert.equal(json(LeapCommand.sunroof(true).stateJSON).value, '1');
  }

  // ── 启停充电 / 解锁充电枪
  {
    const start = LeapCommand.charging(true);
    const stop = LeapCommand.charging(false);
    assert.equal(start.cmdid, '193');
    assert.equal(json(start.stateJSON).value, 'start');
    assert.equal(json(stop.stateJSON).value, 'finish');
    assert.equal(start.isAppointment, false);
    const startE = ControlExpectation.charging(true);
    assert.equal(startE.isSatisfied(withBase({ '1149': '0' })), false);
    assert.equal(startE.isSatisfied(withBase({ '1149': '1' })), true);
    assert.equal(startE.isSatisfied(withBase({})), false);
    const stopE = ControlExpectation.charging(false);
    for (const value of ['0', '2', '4', '6']) assert.equal(stopE.isSatisfied(withBase({ '1149': value })), true, value);
    assert.equal(stopE.isSatisfied(withBase({ '1149': '1' })), false);
    assert.equal(stopE.isSatisfied(withBase({ '1149': '3' })), false);
    const gun = LeapCommand.unlockChargingGun();
    assert.equal(gun.cmdid, '192');
    assert.equal(json(gun.stateJSON).operation, 'unlock');
    assert.equal(gun.expectation.kind, ExpectationKind.unobservable);
  }

  // ── 预约空调
  {
    const a = new ClimateAppointment();
    a.hour = 7; a.minute = 30; a.days = [1, 3, 0]; a.temperature = 26; a.mode = ClimateAppointmentMode.hot;
    const command = LeapCommand.climateAppointment(a, 'VIN123', new Date(2026, 10, 19, 6));
    assert.equal(command.cmdid, '171');
    assert.equal(command.isAppointment, true);
    const controls = json(command.stateJSON).controls;
    assert.equal(controls.length, 1);
    const item = controls[0];
    assert.equal(item.on, '1');
    assert.equal(item.operate, 'manual');
    assert.equal(item.mode, 'hot');
    assert.equal(item.temperature, '26');
    assert.equal(item.windlevel, '7');
    assert.equal(item.circle, 'in');
    assert.equal(item.wshld, '1');
    assert.equal(item.position, 'all');
    assert.deepEqual(item.days, [0, 1, 3]);
    assert.equal(item.start_time, '2026-11-19 07:30:00');
    assert.ok(item.set_id.startsWith('HarmonyOS_VIN123_'));

    const once = new ClimateAppointment(); once.days = [];
    const onceItem = json(LeapCommand.climateAppointment(once, 'V', new Date(2026, 10, 19, 9)).stateJSON).controls[0];
    assert.equal(onceItem.start_time, '2026-11-20 07:30:00');
    assert.deepEqual(onceItem.days, []);

    const keep = new ClimateAppointment(); keep.setID = 'android_abc123';
    assert.equal(json(LeapCommand.climateAppointment(keep, 'V').stateJSON).controls[0].set_id, 'android_abc123');

    const cancel = LeapCommand.cancelClimateAppointment();
    assert.equal(cancel.cmdid, '171');
    assert.equal(cancel.stateJSON, '{"controls":[]}');

    const raw = '{"controls":[{"circle":"in","days":[1,3,4],"mode":"hot","on":"1","operate":"manual","position":"all","set_id":"android_x","start_time":"2026-10-22 19:54:00","temperature":"32","update_time":"1","windlevel":"7","wshld":"1"}]}';
    const parsedControls = ClimateAppointment.controlsFromAppointmentData(JsonValue.ofString(raw));
    const parsed = ClimateAppointment.parse(parsedControls);
    assert.equal(parsed.hour, 19);
    assert.equal(parsed.minute, 54);
    assert.deepEqual(parsed.days, [1, 3, 4]);
    assert.equal(parsed.temperature, 32);
    assert.equal(parsed.mode, ClimateAppointmentMode.hot);
    assert.equal(parsed.setID, 'android_x');
    assert.equal(parsed.summary, '每周一、三、四 19:54 · 制热 32 ℃');

    const empty = ClimateAppointment.controlsFromAppointmentData(JsonValue.ofString('{"controls":[]}'));
    assert.deepEqual(empty, []);
    assert.equal(ClimateAppointment.parse(empty), null);
    assert.equal(ClimateAppointment.controlsFromAppointmentData(JsonValue.ofString('not json')), null);
    assert.equal(ClimateAppointment.controlsFromAppointmentData(null), null);
    const disabled = ClimateAppointment.controlsFromAppointmentData(JsonValue.ofString(
      '{"controls":[{"on":"0","start_time":"2026-10-22 07:00:00","days":[]}]}'));
    assert.equal(ClimateAppointment.parse(disabled), null);
    // 网关直接回对象也认
    const asObject = ClimateAppointment.controlsFromAppointmentData(JsonValue.parse(raw));
    assert.equal(ClimateAppointment.parse(asObject).hour, 19);
  }

  // ── 星期编码
  assert.equal(AppointmentWeekday.ordered[0].value, 1);
  assert.equal(AppointmentWeekday.ordered[6].value, 0);
  assert.equal(AppointmentWeekday.ordered[6].label, '日');
  assert.ok(!AppointmentWeekday.ordered.some(option => option.value === 7));
  assert.equal(AppointmentWeekday.summary([]), '仅一次');
  assert.equal(AppointmentWeekday.summary([1, 2, 3, 4, 5]), '工作日');
  assert.equal(AppointmentWeekday.summary([6, 0]), '周末');
  assert.equal(AppointmentWeekday.summary([0, 1, 2, 3, 4, 5, 6]), '每天');
  assert.equal(AppointmentWeekday.summary([0, 1]), '每周一、日');
  {
    const preheat = LeapCommand.batteryPreheatAppointment(true, new Date(), [0, 6], 'V');
    assert.deepEqual(json(preheat.stateJSON).controls[0].days, [0, 6]);
  }

  // ── 快速除味
  {
    const command = LeapCommand.deodorize();
    assert.equal(command.cmdid, '170');
    assert.equal(command.label, '快速除味');
    const payload = json(command.stateJSON);
    assert.equal(payload.operate, 'manual');
    assert.equal(payload.mode, 'nohotcold');
    assert.equal(payload.circle, 'out');
    assert.equal(payload.windlevel, '7');
    assert.equal(payload.wshld, '0');
    assert.equal(payload.position, 'all');
    const e = command.expectation;
    assert.equal(e.kind, ExpectationKind.climate);
    assert.equal(e.temperature, null, '判据不比温度');
    assert.equal(e.fanLevel, 7);
    assert.equal(e.mode, ClimateMode.vent);
  }

  // ── 锁车后检查
  {
    const allClosed = { '1693': '0', '1694': '0', '1695': '0', '1696': '0', '644': '0', '645': '0', '865': '0',
      '866': '0', '1277': '0', '1278': '0', '1279': '0', '1280': '0', '1281': '0', '1282': '0' };
    const closed = extra => withBase({ ...allClosed, ...extra });
    assert.deepEqual(closed({}).openItemsAfterLock, []);
    assert.deepEqual(withBase({}).openItemsAfterLock, []);
    assert.deepEqual(closed({ '1696': '2' }).openItemsAfterLock, ['右后车窗']);
    assert.deepEqual(closed({ '866': '30' }).openItemsAfterLock, ['右后车窗']);
    assert.deepEqual(closed({ '1693': '2', '1694': '2' }).openItemsAfterLock, ['主驾车窗', '副驾车窗']);
    assert.deepEqual(closed({ '1693': '2', '1694': '2', '1695': '2', '1696': '2' }).openItemsAfterLock, ['车窗']);
    assert.deepEqual(closed({ '1718': '10', '1281': '1' }).openItemsAfterLock, ['天窗', '尾门']);
    assert.deepEqual(closed({ '1282': '1' }).openItemsAfterLock, ['前备箱']);
    assert.deepEqual(closed({ '1277': '1' }).openItemsAfterLock, ['车门']);
    assert.deepEqual(closed({ '1724': '100' }).openItemsAfterLock, []);
    assert.deepEqual(closed({ '1718': '150' }).openItemsAfterLock, []);
  }

  // ── 控车条排序
  assert.deepEqual(QuickControlOrder.order('').slice(0, 4), ['lock', 'unlock', 'trunk', 'climate']);
  {
    const order = QuickControlOrder.order('trunk,climate,lock,horn');
    assert.deepEqual(order.slice(0, 5), ['trunk', 'climate', 'lock', 'unlock', 'horn']);
    assert.equal(order.length, QuickControlOrder.all.length);
    const saved = ['unlock', 'horn', 'lock', 'trunk', 'climate', 'sentinel', 'sunshade', 'sunroof', 'frunk'];
    assert.deepEqual(QuickControlOrder.order(saved.join(',')), saved);
  }

  console.log('Cabin comfort, fridge, charging, climate appointment, lock reminder and quick-control order passed.');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
