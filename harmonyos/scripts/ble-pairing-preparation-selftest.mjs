#!/usr/bin/env node
// Execute production policies and async entry points with deferred storage/network operations.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
if (!process.env.LEAP_PAIRING_SELFTEST_CHILD) {
  const run = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, LEAP_PAIRING_SELFTEST_CHILD: '1' } });
  process.exit(run.status ?? 1);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
const extract = (source, signature) => {
  const start = source.indexOf(`  ${signature}`);
  assert(start >= 0, signature);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
const controller = read('app/BLEVehicleController.ets');
const store = read('app/VehicleStore.ets');
const types = read('app/BLEVehicleControllerTypes.ets');
const contextSource = read('core/BLEProtocol.ets');
const contextStart = contextSource.indexOf('export class LeapBLECredentialContext');
const context = contextSource.slice(contextStart, contextSource.indexOf('\n}', contextStart) + 2);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'leap-pairing-'));
try {
  const file = path.join(dir, 'Pairing.ts');
  fs.writeFileSync(file, `
${read('core/LeapError.ets')}
${types.slice(types.indexOf('export enum BLEPairingStateKind'), types.indexOf('\n}', types.indexOf('export enum BLEPairingStateKind')) + 2)}
${context}
${read('app/BLEPairingPreparation.ets').replace(/^import .*;\n/gm, '')}
const BLEPassiveEntryTask = { async stop() {} };
const BLERuntimeState = { unbound: 'unbound', disabled: 'disabled', needsAttention: (s) => s };
const BLEConfigurationSyncState = { Pending: 'pending', PendingDisable: 'pendingDisable' };
export const BLEPermission = { async ensure() { return true; } };
export class Controller {
  productionRefreshGeneration = 0; productionEligible = true; credentialContext = null;
  pairingState = { kind: BLEPairingStateKind.Idle }; binding = null; logs = []; stops = 0;
  async configure(c) { this.credentialContext = c; }
  async syncPassiveEntryTask() {} ensureManagedConnection() {}
  stopManagedConnection() { this.stops++; }
  append(category, message) { this.logs.push(message); }
${extract(controller, 'async configureProduction(')}
${extract(controller, 'private preserveManualPairing(')}
${extract(controller, 'recordPairingPreparation(')}
}
export class Store {
  blePairingPreparationInProgress = false; bluetoothKeyEligible = true; errors = [];
  session = { oldAuth: { accountId: 'account' }, selectedVin: 'vin', deviceId: 'device' };
  isBLEIdentityCurrent() { return true; }
  show(...v) { this.errors.push(v); } showError(e) { this.errors.push(e); }
  async refreshBLEProtocolVersion() {}
${extract(store, 'async prepareBLEPairing(')}
}
`);
  const { BLEPairingPreparation: Policy, LeapBLECredentialContext: Context, LeapError: ErrorType,
    BLEPairingStateKind: State, Controller, Store } = await import(pathToFileURL(file));
  const cert = (fingerprint = 'cert', extras = {}) => ({ fingerprint, keyType: 1, vin: 'vin',
    isSupportedKeyType: true, hasValidPasswordCard: true, ...extras });
  const make = (c = cert(), account = 'account', device = 'device', vin = 'vin') => new Context(c, account, device, vin);
  const current = make();
  for (const state of [State.Scanning, State.Connecting, State.Authenticating]) {
    assert(Policy.preservesConnection(state, current, make(), true));
    for (const changed of [null, make(cert('new')), make(cert(), 'other'), make(cert(), 'account', 'other'),
      make(cert(), 'account', 'device', 'other'), make(cert('cert', { keyType: 2 })), make(cert('cert', { vin: 'other' }))]) {
      assert(!Policy.preservesConnection(state, current, changed, true));
    }
    assert(!Policy.preservesConnection(state, current, current, false));
  }
  for (const state of [State.Idle, State.Preparing, State.Bound, State.Failed]) {
    assert(!Policy.preservesConnection(state, current, current, true));
  }
  let calls = 0;
  const fresh = make(cert('new'));
  assert.equal(await Policy.resolve(current, async () => { calls++; return fresh; }, () => true, () => {}), fresh);
  assert.equal(calls, 1, 'cached certificate must still refresh from cloud');
  for (const error of [{ code: 2300006 }, { code: 2300028 }, ErrorType.http(503, '')]) {
    assert.equal(await Policy.resolve(current, async () => { throw error; }, () => true, () => {}), current);
    for (const cache of [null, make(cert('cert', { hasValidPasswordCard: false })), make(cert('cert', { isSupportedKeyType: false }))]) {
      await assert.rejects(Policy.resolve(cache, async () => { throw error; }, () => true, () => {}));
    }
  }
  for (const error of [ErrorType.sessionExpired(), ErrorType.needsRelogin(), ErrorType.server('rejected'),
    ErrorType.decode('invalid'), ErrorType.http(401, ''), { code: 201 }, { code: 2300060 }, new Error('cancelled')]) {
    await assert.rejects(Policy.resolve(current, async () => { throw error; }, () => true, () => {}));
  }
  const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
  for (const failed of [false, true]) {
    const network = deferred(); let valid = true;
    const pending = Policy.resolve(current, () => network.promise, () => valid, () => {});
    valid = false;
    if (failed) network.reject({ code: 2300028 }); else network.resolve(fresh);
    await assert.rejects(pending, /配对已取消/);
  }
  // A periodic refresh waiting for storage must not stop a pairing started while it waited.
  const c = new Controller(); c.credentialContext = current; const disk = deferred(); c.bindingStore = { load: () => disk.promise };
  const refresh = c.configureProduction(current, true);
  await Promise.resolve(); c.pairingState.kind = State.Authenticating;
  disk.resolve(null); await refresh;
  assert.equal(c.stops, 0); assert(c.logs.some(s => s.includes('preservePairing')));
  const changedController = new Controller();
  changedController.credentialContext = current; changedController.pairingState.kind = State.Authenticating;
  changedController.bindingStore = { async load() { return null; } };
  await changedController.configureProduction(fresh, true);
  assert.equal(changedController.stops, 1, 'changed credentials must not preserve the old pairing');
  // Older account refresh cannot override a newer configuration.
  const c2 = new Controller(); const disk2 = deferred(); let reads = 0;
  c2.bindingStore = { load: () => ++reads === 1 ? disk2.promise : Promise.resolve(null) };
  const old = c2.configureProduction(current, true); await Promise.resolve();
  const other = make(cert(), 'other'); await c2.configureProduction(other, true);
  disk2.resolve({ shouldMaintainConnection: true }); await old;
  assert.equal(c2.credentialContext, other); assert.equal(c2.binding, null); assert.equal(c2.stops, 1);
  // Exercise real prepare entry point: duplicates coalesce and cancellation never starts scanning.
  for (const cancelStage of ['fetch', 'version', 'none']) {
    const s = new Store(); let starts = 0, fetches = 0; const network = deferred(); const version = deferred();
    s.bleController = { pairingPreparationGeneration: 0, cancelPairing() { this.pairingPreparationGeneration++; },
      recordPairingPreparation() {}, async configureProduction() {}, beginPairing() { starts++; } };
    s.cachedBLECredentialContext = async () => current;
    s.syncBLECredentialContext = () => { fetches++; return network.promise; };
    s.refreshBLEProtocolVersion = () => version.promise;
    const pending = s.prepareBLEPairing(); await s.prepareBLEPairing();
    for (let i=0; i<8; i++) await Promise.resolve();
    assert.equal(fetches, 1);
    if (cancelStage === 'fetch') s.bleController.cancelPairing();
    network.resolve(fresh);
    for (let i=0; i<8; i++) await Promise.resolve();
    if (cancelStage === 'version') s.bleController.cancelPairing();
    version.resolve(); await pending;
    assert.equal(starts, cancelStage === 'none' ? 1 : 0);
    assert.equal(s.blePairingPreparationInProgress, false); assert.equal(s.errors.length, 0);
  }
  console.log('BLE pairing preparation selftest passed: identity/state matrix, cloud/cache policy, stale refresh, duplicate/cancel races');
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
