#!/usr/bin/env node
// Execute production controller methods with a deferred GATT Promise to reproduce notification/write races.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
if (!process.env.LEAP_AUTH_SELFTEST_CHILD) {
  const run = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, LEAP_AUTH_SELFTEST_CHILD: '1' } });
  process.exit(run.status ?? 1);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/app/BLEVehicleController.ets'), 'utf8');
function method(name) {
  const start = source.indexOf(`  private ${name}`);
  assert(start >= 0, name);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}
const protocol = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/BLEProtocol.ets'), 'utf8');
const mapping = protocol.slice(protocol.indexOf('export function leapBLEAuthenticationResultDescription'));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leap-auth-write-'));
try {
  const file = path.join(directory, 'Controller.ts');
  fs.writeFileSync(file, `
const systemDateTime = { TimeType: { STARTUP: 0 }, getUptime: () => performance.now() };
const BLEBuffer = { hex: (v) => Buffer.from(v).toString('hex'), toArrayBuffer: (v) => v.buffer };
const BLETransmissionKind = { Authentication: 'auth', Control: 'control' };
const BLEAuthenticationState = { Authenticating: 'authenticating', Failed: 'failed' };
const BLEAuthenticationMode = { Reconnect: 'reconnect' };
const BLEConnectionIntent = { Pairing: 'pairing', Managed: 'managed' };
const BLEPairingState = { failed: (message) => message };
const BLERuntimeState = { needsAttention: (message) => message };
${mapping}
export class BLEVehicleController {
  static maximumChunkSize = 160;
  static messageOf(e) { return e.message; }
  transmissionGeneration = 0; connectionEpoch = 1; transmissionPurpose = null;
  transmissionInFlight = false; negotiatedMtu = 163; writeType = 1;
  diagnosticAuthentication = 1; diagnosticAuthStarted = -1;
  diagnosticAuthSentParts = 0; diagnosticAuthAckedParts = 0; diagnosticAuthTotalParts = 0;
  authenticationState = 'authenticating'; authenticationMode = 'full'; connectionIntent = 'pairing';
  characteristic = { serviceUuid: 'FFFE', characteristicUuid: 'FFF2', descriptors: [] };
  activeControlAttempt = null; logs = []; completed = 0; failedWrites = 0; invalidated = 0;
  pendingFullAuthenticationFallback = false;
  append(category, message) { this.logs.push(message); }
  cancelResponseTimeout() {} cancelPairingTimeout() {}
  completeTransmission() { this.completed++; this.transmissionInFlight = false; }
  failTransmission() { this.failedWrites++; this.transmissionInFlight = false; }
  invalidateReconnectToken() { this.invalidated++; }
  performFullAuthenticationFallback() { throw new Error('unexpected early fallback'); }
${method('authenticationTrace(')}
${method('async beginTransmission(')}
${method('handleErrorResponse(')}
${method('failAuthentication(')}
}
`);
  const { BLEVehicleController: Controller, leapBLEAuthenticationResultDescription: description } = await import(pathToFileURL(file));
  for (const [code, text] of [[16, '协议版本号低于1.7'], [17, '加密芯片无应答'], [18, '加密芯片应答错误']]) {
    assert.equal(description(code), text);
    let resolve, reject, writes = 0;
    const c = new Controller();
    c.client = { writeCharacteristicValue() { writes++; return new Promise((yes, no) => { resolve = yes; reject = no; }); } };
    const task = c.beginTransmission(new Uint8Array(311), { kind: 'auth', label: 'auth' });
    c.handleErrorResponse(code);
    assert.equal(c.authenticationState, 'failed');
    assert.equal(c.transmissionPurpose, null);
    assert.equal(c.transmissionInFlight, true, 'pending write must block a new transmission');
    await assert.rejects(c.beginTransmission(new Uint8Array(3), { kind: 'auth' }), /已有数据/);
    if (code === 17) reject(new Error('late failed write')); else resolve();
    await task;
    assert.equal(writes, 1, 'rejected authentication must not send the second fragment');
    assert.equal(c.completed, 0, 'must not arm response timeout after rejection');
    assert.equal(c.failedWrites, 0, 'late rejection must not replace the vehicle error');
    assert.equal(c.transmissionInFlight, false);
  }
  for (const rejectOld of [false, true]) {
    let resolve, reject;
    const c = new Controller();
    c.client = { writeCharacteristicValue() { return new Promise((yes, no) => { resolve = yes; reject = no; }); } };
    const task = c.beginTransmission(new Uint8Array(311), { kind: 'auth' });
    c.connectionEpoch++; c.transmissionGeneration++; c.client = {};
    const newerPurpose = { kind: 'auth' }; c.transmissionPurpose = newerPurpose;
    c.transmissionInFlight = true;
    if (rejectOld) reject(new Error('old connection')); else resolve();
    await task;
    assert.equal(c.transmissionInFlight, true);
    assert.equal(c.transmissionPurpose, newerPurpose);
    assert.equal(c.failedWrites, 0);
    assert.equal(c.completed, 0);
  }
  const normal = new Controller(); let writes = 0;
  normal.client = { async writeCharacteristicValue() { writes++; } };
  await normal.beginTransmission(new Uint8Array(311), { kind: 'auth' });
  assert.equal(writes, 2); assert.equal(normal.completed, 1);
  const fallback = new Controller(); fallback.authenticationMode = 'reconnect'; fallback.transmissionInFlight = true;
  fallback.handleErrorResponse(3);
  assert.equal(fallback.pendingFullAuthenticationFallback, true);
  assert.equal(fallback.invalidated, 1);
  assert.equal(fallback.authenticationState, 'authenticating');
  assert.equal(description(255), '未知错误码');
  console.log('PASS: 8 authentication result, deferred-write, stale-connection and normal/fallback scenarios');
} finally { fs.rmSync(directory, { recursive: true, force: true }); }
