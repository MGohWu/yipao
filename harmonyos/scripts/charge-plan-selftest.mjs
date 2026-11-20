import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = fileURLToPath(import.meta.url);
if (!process.env.LEAP_CHARGE_SELFTEST_CHILD) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', here], {
    stdio: 'inherit', env: { ...process.env, LEAP_CHARGE_SELFTEST_CHILD: '1' },
  });
  process.exit(child.status ?? 1);
}
const root = path.resolve(path.dirname(here), '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
// Run the production client/model methods; only platform and transport dependencies are mocked.
const source = ['JsonValue', 'SignalSchema', 'CabinComfort', 'ClimateAppointment', 'LeapModels', 'LeapError', 'LeapClient']
  .map(name => read(`core/${name}.ets`)).join('\n').replace(/^import\s[\s\S]*?;\s*$/gm, '').replace(/^export \{[^}]+\} from [^;]+;$/gm, '');
const store = read('app/VehicleStore.ets');
const storeMethod = store.slice(store.indexOf('  async refreshChargePlan()'), store.indexOf('  async refresh(showSpinner:'));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leap-charge-test-'));
try {
  const modulePath = path.join(directory, 'charge.mts');
  fs.writeFileSync(modulePath, `const DiagLog = { note() {} };
export const HttpTransport = { async request() { throw new Error('offline'); } };
` + source + `\nexport class StoreHarness { ${storeMethod} }`);
  const { LeapClient, JsonValue, VehicleState, StoreHarness, HttpTransport } = await import(pathToFileURL(modulePath));
  const client = Object.create(LeapClient.prototype);
  Object.assign(client, { sessionData: { selectedVin: 'car-a', oldAuth: { accountId: 'owner-a' } },
    cachedConfigVin: '', configAccount: '', configRequest: 0, configFetchedAt: 0,
    cachedChargePlan: null, cachedChargePlanLimit: null });
  let calls = 0;
  let percent = 80;
  const config = () => JsonValue.parse(JSON.stringify({ 3: { percent, beginTime: '22:00', endTime: '08:00',
    cycles: '1,1,1,1,1,0,0', isEnable: 1, circulation: 1, recharge: 0 } }));
  client.fetchCommonConfig = async () => { calls++; return config(); };
  const state = new VehicleState();
  await client.fillChargePlanFromCache(state, false);
  assert.equal(state.chargePlan.percent, 80);
  assert.equal(calls, 1);
  percent = 95;
  await client.fillChargePlanFromCache(state, false);
  assert.equal(state.chargePlan.percent, 80);
  assert.equal(calls, 1);
  await client.refreshChargePlan(); // Explicit reread after command 190 / entering editor.
  await client.fillChargePlanFromCache(state, false);
  assert.equal(state.chargePlan.percent, 95);
  assert.equal(calls, 2);
  percent = 90;
  client.configFetchedAt -= 15001;
  await client.fillChargePlanFromCache(state, false);
  assert.equal(state.chargePlan.percent, 90);
  assert.equal(calls, 3);
  const timestamp = client.configFetchedAt;
  client.fetchCommonConfig = async () => { throw new Error('offline'); };
  await assert.rejects(client.refreshChargePlan(), /offline/);
  await client.fillChargePlanFromCache(state, true);
  assert.equal(state.chargePlan.percent, 90);
  assert.equal(client.configFetchedAt, timestamp);
  client.sessionData.selectedVin = 'car-b';
  await client.fillChargePlanFromCache(state, false);
  assert.equal(state.chargePlan, null); // Never show car-a's plan on car-b.

  let resolve;
  client.fetchCommonConfig = () => new Promise(done => { resolve = done; });
  const switched = client.refreshChargePlan();
  client.sessionData.selectedVin = 'car-c';
  resolve(config());
  await assert.rejects(switched, /车辆或配置请求已更新/);
  assert.equal(client.cachedChargePlan, null);
  const accountSwitched = client.refreshChargePlan();
  client.sessionData.oldAuth.accountId = 'owner-b';
  resolve(config());
  await assert.rejects(accountSwitched, /车辆或配置请求已更新/);

  const older = client.refreshChargePlan();
  const resolveOlder = resolve;
  const newer = client.refreshChargePlan();
  percent = 100;
  resolve(config());
  await newer;
  percent = 70;
  resolveOlder(config());
  await assert.rejects(older, /车辆或配置请求已更新/);
  assert.equal(client.cachedChargePlan.percent, 100);

  // Failed hosts must throw, while a successful response with no config is valid empty data.
  delete client.fetchCommonConfig;
  client.ensureRoute = async () => ({ appCenter: 'https://center.test', appRegion: 'https://region.test' });
  client.ensureFreshOldToken = async () => {};
  client.oldSignedParams = value => value;
  client.oldAppHeaders = () => ({});
  await assert.rejects(client.fetchCommonConfig(), /获取充电计划失败/);
  HttpTransport.request = async () => JsonValue.parse('{"code":0,"data":{}}');
  assert.equal(await client.refreshChargePlan(), null);

  const harness = new StoreHarness();
  const oldState = new VehicleState();
  oldState.signalMap.set('48', '1');
  oldState.isExtendRange = true;
  oldState.collectedAt = 123;
  Object.assign(harness, { isDemo: false, state: oldState, session: client.sessionData, client,
    fetchInFlight: true, show() {} });
  client.fetchCommonConfig = async () => config();
  assert.equal(await harness.refreshChargePlan(), true); // Bypasses busy generic vehicle fetch.
  assert.notEqual(harness.state, oldState); // @Trace needs a fresh reference.
  assert.equal(harness.state.chargePlan.percent, 70);
  assert.equal(harness.state.signalMap.get('48'), '1');
  assert.equal(harness.state.isExtendRange, true);
  assert.equal(harness.state.collectedAt, 123);
  console.log('Charge-plan cache, forced readback, failure, VIN/account races and state publication passed.');
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
