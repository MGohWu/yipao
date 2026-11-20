#!/usr/bin/env node
/**
 * 拿 iOS 的固定向量校验 `core/EllipticCurve.ets` / `core/LeapGMCrypto.ets` / `core/BLEProtocol.ets`。
 *
 * 鸿蒙这边没有单元测试基建，而国密那一层是手写的曲线运算、协议那一层是逐字节组帧，
 * 错一位就是「认证失败」四个字，在车边上根本查不出来。所以这里把 .ets 源码原样搬到
 * Node 上跑：只把 import 换成替身——`cryptoFramework` 用 Node 的 OpenSSL（同样有
 * SM3/SM4/AES），`util` 用 Buffer，`LeapBLEError` 用一个同名的 Error 子类。
 * 除此之外一个字符都不改，跑的就是真正上机的那份代码。
 *
 * 向量逐条抄自 iOS 端的 LeapControlTests/BLEProtocolTests.swift，
 * 每一条 check 都能在那边找到同名的 @Test。
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = fileURLToPath(import.meta.url);

// 协议层有 enum，Node 默认的「只剥类型」模式不认，得开 transform。
// 这个开关只能在启动时给，所以第一次进来先把自己重新拉起一遍。
if (!process.env.LEAP_BLE_SELFTEST_CHILD) {
  const child = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', here, ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, LEAP_BLE_SELFTEST_CHILD: '1' } }
  );
  process.exit(child.status ?? 1);
}

const root = path.resolve(path.dirname(here), '..');
// 按依赖顺序拼起来：`LeapGMCrypto` 里的顶层常量会立刻读 `EllipticCurve` 的静态字段。
const modules = ['JsonValue', 'EllipticCurve', 'LeapGMCrypto', 'BLEProtocol', 'BLECalibration', 'CallCarProtocol'];
const source = modules
  .map((name) => fs.readFileSync(path.join(root, `entry/src/main/ets/core/${name}.ets`), 'utf8'))
  .join('\n');
const stateSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/app/BLEVehicleControllerTypes.ets'), 'utf8');
const callTypes = stateSource.slice(stateSource.indexOf('export enum BLEStraightMoveStateKind'), stateSource.indexOf('export class BLEDiscoveredDevice'));
const callNative = fs.readFileSync(path.join(root, 'entry/src/main/ets/app/CallCarController.ets'), 'utf8').replace(/@ObservedV2\s*/g, '').replace(/@Trace\s*/g, '');

const prelude = `
class LeapError extends Error { static decode(reason) { return new LeapError(reason); } }
class LeapBLEError extends Error {
  constructor(kind, message) { super(message); this.name = 'LeapBLEError'; this.kind = kind; }
  static unsupportedKeyType(value) { return new LeapBLEError('UnsupportedKeyType', '暂不支持的蓝牙证书类型（keyType=' + value + '）'); }
  static invalidCertificate(reason) { return new LeapBLEError('InvalidCertificate', '蓝牙证书无效：' + reason); }
  static invalidFrame(reason) { return new LeapBLEError('InvalidFrame', '蓝牙帧无效：' + reason); }
  static cryptoFailure(reason) { return new LeapBLEError('CryptoFailure', '蓝牙加解密失败：' + reason); }
}
const nodeCrypto = (await import('node:crypto')).default;
const LeapCrypto = { md5Hex(data) { return nodeCrypto.createHash('md5').update(data).digest('hex'); } };
const BLEBuffer = { toArrayBuffer(data) { return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength); } };
const ble = { GattWriteType: { WRITE: 1 } };
const nodeDigestName = { SM3: 'sm3', SHA256: 'sha256' };
const nodeCipherName = { 'SM4_128|CBC|PKCS7': 'sm4-cbc', 'AES128|CBC|PKCS7': 'aes-128-cbc' };
const cryptoFramework = {
  CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
  createMd(algorithm) {
    const hash = nodeCrypto.createHash(nodeDigestName[algorithm]);
    return {
      updateSync(blob) { hash.update(Buffer.from(blob.data)); },
      digestSync() { return { data: new Uint8Array(hash.digest()) }; }
    };
  },
  createSymKeyGenerator() {
    return { convertKeySync(blob) { return { raw: Buffer.from(blob.data) }; } };
  },
  createCipher(transformation) {
    const name = nodeCipherName[transformation];
    let handle = null;
    return {
      initSync(mode, key, params) {
        const iv = Buffer.from(params.iv.data);
        handle = mode === 0
          ? nodeCrypto.createCipheriv(name, key.raw, iv)
          : nodeCrypto.createDecipheriv(name, key.raw, iv);
      },
      doFinalSync(blob) {
        const out = Buffer.concat([handle.update(Buffer.from(blob.data)), handle.final()]);
        return { data: new Uint8Array(out) };
      }
    };
  },
  createRandom() {
    return { generateRandomSync(length) { return { data: new Uint8Array(nodeCrypto.randomBytes(length)) }; } };
  }
};
const util = {
  TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } },
  Base64Helper: class { encodeToStringSync(data) { return Buffer.from(data).toString('base64'); } },
  TextDecoder: { create() { return { decodeToString(data) { return Buffer.from(data).toString('utf8'); } }; } }
};
`;

const transpiled = (source + callTypes + callNative)
  .replace(/^import\s[\s\S]*?;\s*$/gm, '');

const temporary = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'leap-ble-')), 'LeapBLE.ts');
fs.writeFileSync(temporary, prelude + transpiled);
const loaded = await import(pathToFileURL(temporary).href);
const {
  JsonValue, LeapGMCrypto, LeapBLEProtocol, LeapBytes, LeapBLEKeyCertificate, LeapBLEConfiguration,
  LeapBLEDecryptedResponse, LeapBLEResponseKind, LeapBLECryptoSession, LeapBLEFrame, LeapBLEFrameKind,
  LeapBLEEventKind, LeapBLEFrameReassembler, LeapBLEControlCommand, StraightMoveOrder, BLECalibration, BLEUnlockDistance, CallCarPacketBuffer, CallCarStatus, CallCarStatusKind, CallCarProtocol, CallCarController, BLEStraightMoveState, BLEStraightMoveStateKind, StraightMoveDirection
} = loaded;

// ---- 断言 ----

let failures = 0;
const check = (name, actual, expected) => {
  if (actual === expected) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}\n      实际 ${actual}\n      期望 ${expected}`);
  }
};
const section = (title) => console.log(`\n${title}`);
/** 只关心「抛没抛、文案对不对」，所以统一收成一个字符串再比。 */
const thrownMessage = (body) => {
  try {
    body();
    return '<未抛出>';
  } catch (e) {
    return e.message;
  }
};

// iOS 测试里那份真实的自签 SM2 证书，用来验 DER 解析对官方产物也成立。
const IOS_SM2_CERTIFICATE_PEM = [
  '-----BEGIN CERTIFICATE-----',
  'MIIBhjCCASugAwIBAgIUTzck05zW50mkmjvS/cenk1gi1DkwCgYIKoEcz1UBg3Uw',
  'GDEWMBQGA1UEAwwNTGVhcCBCTEUgVGVzdDAeFw0yNjA4MTExMTI0MjRaFw0zNjA4',
  'MDgxMTI0MjRaMBgxFjAUBgNVBAMMDUxlYXAgQkxFIFRlc3QwWTATBgcqhkjOPQIB',
  'BggqgRzPVQGCLQNCAARm0r00h4HiOELHHY28UKYY8lX5SKf4LBHGmvWNa0KHsASd',
  'U0HR+dehjj+S2Lx09VidadPDi94ZFdcXF4jh9BhCo1MwUTAdBgNVHQ4EFgQUGukz',
  'fBVOWfRrTrtSw1Ir3aXscdwwHwYDVR0jBBgwFoAUGukzfBVOWfRrTrtSw1Ir3aXs',
  'cdwwDwYDVR0TAQH/BAUwAwEB/zAKBggqgRzPVQGDdQNJADBGAiEA6uBKX+5wjDkW',
  'JTdlQ1ELDYJqkYGOq+YnPZ7A7hM8cUMCIQDFAca3P6D583BC8j5q+Q1Udix210pb',
  'Vr72D+mN0HFPSg==',
  '-----END CERTIFICATE-----'
].join('\n');

const hex = (bytes) => Buffer.from(bytes).toString('hex');
const fromHex = (text) => new Uint8Array(Buffer.from(text, 'hex'));
const bytes = (...values) => new Uint8Array(values);
const join = (...parts) => new Uint8Array(Buffer.concat(parts.map((part) => Buffer.from(part))));
const single = (frames) => (frames.length === 1 ? frames[0] : null);

// ---- 国密 ----

section('LeapGMCrypto 对拍 iOS 固定向量');

const privateKey = new Uint8Array(32);
privateKey[31] = 1;
const peerPublicKey = fromHex(
  '0456cefd60d7c87c000d58ef57fa73ba4d9c0dfa08c08a7331495c2e1da3f2bd52' +
  '31b7e7e6cc8189f668535ce0f8eaf1bd6de84c182f6c8e716f780d3a970a23c3'
);
const expectedPublicKey =
  '0432c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7' +
  'bc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0';
const expectedSharedKey = '5f86e6b17708f60dfb5d8e3f3ce2b35d3d29744d51c46fc14cdb7bb95fdaf48b';

check('SM3("abc")', hex(LeapGMCrypto.sm3(Buffer.from('abc'))),
  '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0');

const agreement = LeapGMCrypto.sm2KAP('', privateKey, peerPublicKey);
check('SM2 KAP 本机公钥', hex(agreement.publicKey), expectedPublicKey);
check('SM2 KAP 会话密钥', hex(agreement.sharedKey), expectedSharedKey);

// 随机私钥也要能跑通，且公钥落在曲线上（由 KAP 内部的点校验兜底）。
const randomAgreement = LeapGMCrypto.sm2KAP('', null, peerPublicKey);
check('SM2 KAP 随机私钥输出长度',
  `${randomAgreement.publicKey.length}/${randomAgreement.sharedKey.length}`, '65/32');

// SM4-CBC-PKCS7 走一圈。
const sm4Key = fromHex('0123456789abcdeffedcba9876543210');
const sm4Iv = new Uint8Array(16);
const sm4Plain = Buffer.from('leap bluetooth key');
const sm4Cipher = LeapGMCrypto.sm4Encrypt(sm4Plain, sm4Key, sm4Iv);
check('SM4 往返', Buffer.from(LeapGMCrypto.sm4Decrypt(sm4Cipher, sm4Key, sm4Iv)).toString(), sm4Plain.toString());

// 证书路径：拿上面那把对端公钥现造一份自签 SM2 证书，验 DER 解析取点。
const generatedCertificate = buildSelfSignedSM2Certificate(peerPublicKey);
check('SM2 KAP 走证书解析',
  hex(LeapGMCrypto.sm2KAP(generatedCertificate, privateKey, null).sharedKey), expectedSharedKey);

// iOS 测试里那份真实的 X.509 PEM 也要能走通（对端公钥不同，只验能取出点、密钥非零）。
const iosCertificateAgreement = LeapGMCrypto.sm2KAP(IOS_SM2_CERTIFICATE_PEM, privateKey, null);
check('iOS PEM 证书取出中控公钥',
  `${hex(iosCertificateAgreement.publicKey)}/${iosCertificateAgreement.sharedKey.length}/` +
  `${iosCertificateAgreement.sharedKey.some((byte) => byte !== 0)}`,
  `${expectedPublicKey}/32/true`);

// ---- 组帧 ----

section('LeapBLEFrameReassembler 对拍 iOS 固定向量');

{
  const raw = bytes(0xAA, 0xAB, 0x04, 0, 0, 0, 0x41, 0x42, 0x43, 0x44);
  const reassembler = new LeapBLEFrameReassembler();
  const first = reassembler.append(raw.slice(0, 3));
  const buffered = reassembler.bufferedByteCount;
  const frames = reassembler.append(raw.slice(3));
  check('AA AB 跨分片后按声明长度重组',
    `${first.length}/${buffered}/${frames.length}/${frames[0]?.kind}/` +
    `${frames[0]?.declaredPayloadLength}/${hex(frames[0]?.bytes ?? [])}/${reassembler.bufferedByteCount}`,
    `0/3/1/${LeapBLEFrameKind.Encrypted}/4/${hex(raw)}/0`);

  const frame = new LeapBLEFrame(LeapBLEFrameKind.Encrypted, 4, raw);
  check('脱敏帧说明不含载荷、完整模式保留十六进制',
    `${frame.logDetail(false).includes('41424344')}/${frame.logDetail(true).includes('41424344')}`,
    'false/true');
}

{
  const area = bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01);
  const encrypted = bytes(0xAA, 0xAB, 1, 0, 0, 0, 0x58);
  const reassembler = new LeapBLEFrameReassembler();
  const frames = reassembler.append(join(bytes(0x00, 0xFF, 0xAA, 0x00), area, encrypted));
  check('噪声和同一分片中的多帧不破坏同步',
    `${frames.map((frame) => frame.kind).join(',')}|${frames.map((frame) => frame.declaredPayloadLength).join(',')}`,
    `${LeapBLEFrameKind.Event},${LeapBLEFrameKind.Encrypted}|2,1`);
}

{
  const raw = bytes(0xAA, 0xEE, 0x03, 0x00, 0x11, 0x22, 0x33);
  const reassembler = new LeapBLEFrameReassembler();
  const partial = reassembler.append(raw.slice(0, raw.length - 1));
  const buffered = reassembler.bufferedByteCount;
  const completed = single(reassembler.append(raw.slice(raw.length - 1)));
  check('截断帧继续缓存，补齐后才输出',
    `${partial.length}/${buffered}/${hex(completed?.bytes ?? [])}`, `0/6/${hex(raw)}`);
}

{
  const invalid = bytes(0xAA, 0xAB, 0xFF, 0xFF, 0xFF, 0x7F);
  const valid = bytes(0xAA, 0xAB, 0x01, 0, 0, 0, 0x58);
  const reassembler = new LeapBLEFrameReassembler();
  const frames = reassembler.append(join(invalid, valid));
  check('异常的大长度字段被丢弃并重新找到下一帧',
    `${hex(single(frames)?.bytes ?? [])}/${reassembler.bufferedByteCount}`, `${hex(valid)}/0`);
}

// ---- 事件 ----

section('LeapBLEEvent 对拍 iOS 固定向量');

{
  const reassembler = new LeapBLEFrameReassembler();
  const unlock = bytes(0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x2D, 0x02, 0x01);
  const lock = bytes(0xAA, 0xAC, 2, 0, 0, 2, 3, 0, 0, 0, 0x24, 0x02, 0x02);
  const frames = reassembler.append(join(unlock, lock));
  const describe = (frame) => {
    const event = frame.event;
    return `${event.kind}:${event.crc8}:${event.trigger.rawValue}:${event.operation.rawValue}`;
  };
  check('实车 AA AC 无感解锁和闭锁事件可解析',
    `${frames.length}|${describe(frames[0])}|${describe(frames[1])}`,
    `2|${LeapBLEEventKind.LockOperation}:45:2:1|${LeapBLEEventKind.LockOperation}:36:2:2`);
  check('解闭锁事件说明文案', frames[0].event.summary, '解闭锁事件：无感 / 解锁，CRC8=2D');
}

{
  const reassembler = new LeapBLEFrameReassembler();
  const unlockArea = bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x07, 0x01);
  const trendLockArea = bytes(0xAA, 0xAC, 2, 0, 0, 3, 2, 0, 0, 0, 0x09, 0x03);
  const frames = reassembler.append(join(unlockArea, trendLockArea));
  const describe = (frame) => `${frame.event.kind}:${frame.event.crc8}:${frame.event.area.rawValue}`;
  check('实车 AA AC 区域事件可解析',
    `${describe(frames[0])}|${describe(frames[1])}`,
    `${LeapBLEEventKind.AreaChange}:7:1|${LeapBLEEventKind.AreaChange}:9:3`);
}

{
  const reassembler = new LeapBLEFrameReassembler();
  const raw = bytes(0xAA, 0xAC, 2, 0, 0, 1, 2, 0, 0, 0, 0x55, 0x07);
  const event = single(reassembler.append(raw)).event;
  check('AA AC 错误应答取最后一字节 resultCode',
    `${event.kind}:${event.resultCode}:${hex(event.payload)}`,
    `${LeapBLEEventKind.ErrorResponse}:7:5507`);
}

// ---- 配置与校验 ----

section('配置、CRC8 与响应解析');

check('CRC8 与官方多项式 0x07 一致',
  LeapBLECryptoSession.crc8(bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01)), 0x88);
check('官方 1.9 默认蓝牙配置固定为 9 字节',
  hex(LeapBLEConfiguration.officialDefault.bytes), hex(bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1)));
check('首次绑定默认只开启蓝牙控车',
  `${LeapBLEConfiguration.manualControl.calibrationText}|${hex(LeapBLEConfiguration.manualControl.bytes)}`,
  `56;2.00;08;16|${hex(bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 0, 1))}`);
check('无感解锁开关只翻 autoUnlock 那一位',
  `${hex(LeapBLEConfiguration.manualControl.withPassiveUnlock(true).bytes)}|` +
  `${hex(LeapBLEConfiguration.officialDefault.withPassiveUnlock(false).bytes)}`,
  `${hex(bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1))}|${hex(bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 0, 1))}`);

{
  const parse = (text) => {
    const response = LeapBLEDecryptedResponse.parse(LeapBytes.utf8(text));
    if (response === null) {
      return 'null';
    }
    return `${response.kind}:${response.identifier}:${response.value}:${response.remainingFields.join(',')}`;
  };
  check('官方分号响应区分认证状态和重连 token',
    [parse('0;1;extra'), parse('1;A1B2C3D4'), parse('2;00;3;extra'),
      parse('1;not-hex'), parse('0')].join('|'),
    [`${LeapBLEResponseKind.Authentication}:1::extra`,
      `${LeapBLEResponseKind.ReconnectToken}::A1B2C3D4:`,
      `${LeapBLEResponseKind.Command}:3:00:extra`,
      'null', 'null'].join('|'));
}

section('证书解析');

{
  const node = (vin) => `{"ecdhPublicKey":"public-${vin}","keyType":0,"passwordCard":"card-${vin}",` +
    `"plainText":"plain-${vin}","signResult":"sign-${vin}","vin":"${vin}"}`;
  const json = JsonValue.parse(
    `{"result":0,"data":{"mobileControl":${node('MOBILE')},"bluetoothKey":${node('BLUETOOTH')}}}`);
  const certificate = LeapBLEKeyCertificate.fromJson(json);
  check('证书响应明确选择 bluetoothKey 而不是 mobileControl',
    `${certificate?.vin}|${certificate?.ecdhPublicKey}`, 'BLUETOOTH|public-BLUETOOTH');
}

{
  const json = JsonValue.parse(JSON.stringify({
    data: {
      bluetoothKey: {
        ecdhPublicKey: 'legacy-public',
        passwordCard: '0'.repeat(80),
        plainText: 'a;b;c;d;e;f',
        signResult: Buffer.from([0x01]).toString('base64')
      }
    }
  }));
  const certificate = LeapBLEKeyCertificate.fromJson(json);
  check('旧证书缺少 keyType 时兼容路由到老款',
    `${certificate?.keyType}/${certificate?.isSupportedKeyType}`, '0/true');
}

check('生产蓝牙路径支持 keyType=0/1，拒绝未知类型',
  `${LeapBLEProtocol.supportsKeyType(0)}/${LeapBLEProtocol.supportsKeyType(1)}/` +
  `${LeapBLEProtocol.supportsKeyType(2)}/${deterministicCertificate().isSupportedKeyType}`,
  'true/true/false/true');

{
  const base = deterministicCertificate();
  const withCard = (card) => new LeapBLEKeyCertificate(
    base.ecdhPublicKey, base.keyType, card, base.plainText, base.signResult, base.vin);
  const short = withCard('0'.repeat(79));
  const nonASCII = withCard(`${'0'.repeat(79)}é`);
  const expected = '蓝牙证书无效：passwordCard 必须是至少 80 字节的 ASCII 字符串';
  check('passwordCard 必须覆盖 16 个 ASCII 五字节切片',
    `${base.hasValidPasswordCard}/${short.hasValidPasswordCard}/${nonASCII.hasValidPasswordCard}`,
    'true/false/false');
  check('passwordCard 过短时的报错文案', thrownMessage(() => short.validatePasswordCard()), expected);
  check('passwordCard 非 ASCII 时的报错文案', thrownMessage(() => nonASCII.validatePasswordCard()), expected);
  check('passwordCard 非法时建会话也拒绝',
    thrownMessage(() => LeapBLECryptoSession.make(short, short.vin)), expected);
}

{
  const base = deterministicCertificate();
  const unknown = new LeapBLEKeyCertificate(
    base.ecdhPublicKey, 2, base.passwordCard, base.plainText, base.signResult, base.vin);
  check('未知证书类型仍明确拒绝',
    thrownMessage(() => LeapBLECryptoSession.make(unknown, unknown.vin)),
    '暂不支持的蓝牙证书类型（keyType=2）');
}

// ---- 老款 P-256 会话 ----

section('老款 P-256 + AES 会话对拍 iOS 固定向量');

{
  const session = makeDeterministicSession();
  const frame = session.controlFrame(LeapBLEControlCommand.Unlock, 0x0102030405060708n);
  const reassembler = new LeapBLEFrameReassembler();
  const parsed = single(reassembler.append(frame));
  check('固定 ECDH 向量生成官方 AA AB 控车帧',
    hex(frame), 'aaab180000002f54522b62355a533357472b365965427753487079513d3d');
  check('AA AB 控车帧明文',
    hex(session.decrypt(parsed)), hex(bytes(0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01)));
}

{
  const session = makeDeterministicSession();
  const results = [StraightMoveOrder.Forward, StraightMoveOrder.Backward, StraightMoveOrder.Stop]
    .map((order) => {
      const frame = session.straightMoveFrame(order);
      const parsed = single(new LeapBLEFrameReassembler().append(frame));
      return `${hex(frame.slice(0, 2))}:${parsed.declaredPayloadLength}:${hex(session.decrypt(parsed))}`;
    });
  check('直进直出 1/2/3 明文只有单个 order 字节',
    results.join('|'), 'aaab:24:01|aaab:24:02|aaab:24:03');
}

{
  const session = makeDeterministicSession();
  const frame = session.configurationFrame(LeapBLEConfiguration.manualControl, 0x0102030405060708n);
  const parsed = single(new LeapBLEFrameReassembler().append(frame));
  const plain = session.decrypt(parsed);
  const body = join(bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x03),
    LeapBLEConfiguration.manualControl.bytes);
  check('命令 3 明文携带完整 9 字节配置',
    `${plain.length}/${plain[0]}/${hex(plain.slice(1))}`,
    `19/${LeapBLECryptoSession.crc8(body)}/${hex(body)}`);
}

{
  const session = makeDeterministicSession();
  const frame = session.fullAuthenticationFrame(
    deterministicCertificate(), '12345678', '0123456789ABCDEF0123456789ABCDEF', 1700000000);
  check('固定 ECDH 向量生成官方 1.9 AA AE 认证帧',
    `${frame.length}/${hex(frame.slice(0, 8))}/${hex(frame.slice(frame.length - 2))}`,
    '291/aaae1f01d4b01a00/0109');
  check('AA AE 认证帧明文',
    authTextOf(session, frame, 2),
    '1700000000;a;12345678;0123456789ABCDEF0123456789ABCDEF;d;e;f;56;2.00;08;16;1;0;1;1;');
  check('AA AE 认证帧整体摘要', hex(LeapBLECryptoSession.sha256(frame)),
    'e71e332f17e6d305edf2ba359b11b1c4fb9921f83d75fe85ace36ec4ab1d4d98');
}

{
  const session = makeDeterministicSession();
  const frame = session.fullAuthenticationFrame(
    deterministicCertificate(), '12345678', '0123456789ABCDEF0123456789ABCDEF', 1700000000,
    LeapBLEConfiguration.manualControl);
  check('AA AE 从同一配置模型生成无感开关',
    authTextOf(session, frame, 2).endsWith(';56;2.00;08;16;1;0;0;1;'), true);
}

{
  const session = makeDeterministicSession();
  const frame = session.reconnectAuthenticationFrame(
    'DEADBEEF', '1234567890', LeapBLEConfiguration.officialDefault, 0x0102030405060708n);
  const digest = LeapBLECryptoSession.sha256(frame.slice(0, frame.length - 16));
  check('老款 AES AA EE 重连帧使用 SHA-256 摘要',
    `${hex(frame.slice(0, 2))}/${hex(frame.slice(frame.length - 18, frame.length - 16))}/` +
    `${hex(frame.slice(frame.length - 16))}`,
    `aaee/0109/${hex(digest.slice(0, 16))}`);
}

// ---- 国密会话 ----

section('国密 SM2 + SM4 会话对拍 iOS 固定向量');

const smCertificate = new LeapBLEKeyCertificate(
  'unused by raw vector', 1, '0123456789'.repeat(8), 'a;b;c;d;e;f',
  Buffer.alloc(64).toString('base64'), 'TESTVIN1234567890');
const makeSMSession = () => LeapBLECryptoSession.make(
  smCertificate, smCertificate.vin, 0x001AB0D4, privateKey, peerPublicKey);

{
  const session = makeSMSession();
  const frame = session.controlFrame(LeapBLEControlCommand.Unlock, 0x0102030405060708n);
  const parsed = single(new LeapBLEFrameReassembler().append(frame));
  check('国密证书生成官方 SM3/SM4 AA AB 控车帧',
    hex(frame), 'aaab18000000416943615a4a303431474e644a4561545a70646736413d3d');
  check('国密 AA AB 控车帧明文',
    hex(session.decrypt(parsed)), hex(bytes(0x88, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01)));
}

{
  const publicKey = join(bytes(0x04), Uint8Array.from({ length: 64 }, (_, index) => index + 1));
  const frame = LeapBLECryptoSession.reconnectFrame(
    0x001AB0D4, publicKey, new Uint8Array(64).fill(0x41), true);
  check('AA EE 组帧与官方 App 运行时固定向量一致',
    `${frame.length}/${hex(frame)}`,
    '155/' + [
      'aaee9700d4b01a00040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e',
      '1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404141414141',
      '414141414141414141414141414141414141414141414141414141414141414141414141414141',
      '414141414141414141414141414141414141414101096135e0da096a186bf8d79ced78d22062',
    ].join(''));
}

{
  const session = makeSMSession();
  const frame = session.reconnectAuthenticationFrame(
    'DEADBEEF', '1234567890', LeapBLEConfiguration.officialDefault, 0x0102030405060708n);
  const plain = session.decrypt(reencapsulate(frame.slice(73, frame.length - 18)));
  const expected = join(
    bytes(0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01),
    bytes(0xDE, 0xAD, 0xBE, 0xEF),
    bytes(0x38, 0xC8, 0, 0x08, 0x10, 1, 0, 1, 1),
    bytes(0x0A, 0),
    LeapBytes.utf8('1234567890'));
  check('国密 AA EE 明文包含 token、9 字节配置和账号长度',
    `${frame.length}/${hex(frame.slice(0, 8))}/${hex(frame.slice(frame.length - 18, frame.length - 16))}/${hex(plain)}`,
    `155/aaee9700d4b01a00/0109/${hex(expected)}`);
}

section('完整 UUID 与分段广播版本识别');
for (const uuid of ['0109', '00000109', '00000109-0000-1000-8000-00805f9b34fb']) {
  check('版本 ' + uuid, LeapBLEProtocol.protocolMinor([uuid]), 9);
  const session = makeDeterministicSession();
  check('认证字段不退回 1.8 ' + uuid,
    hex(session.fullAuthenticationFrame(deterministicCertificate(), '12345678', 'device', 1700000000,
      LeapBLEConfiguration.officialDefault, LeapBLEProtocol.protocolMinor([uuid]))),
    hex(session.fullAuthenticationFrame(deterministicCertificate(), '12345678', 'device', 1700000000,
      LeapBLEConfiguration.officialDefault, 9)));
}
{
  const partial = LeapBLEProtocol.mergingAdvertisedServices(['FFFE', '0109'], ['FFFE']);
  check('分段广播保留版本', LeapBLEProtocol.protocolMinor(partial), 9);
  check('空扫描响应保留版本', LeapBLEProtocol.protocolMinor(LeapBLEProtocol.mergingAdvertisedServices(partial, [])), 9);
  check('明确新版本替换历史版本', LeapBLEProtocol.protocolMinor(LeapBLEProtocol.mergingAdvertisedServices(partial, ['0106'])), 6);
  check('不解释厂商 UUID', LeapBLEProtocol.protocolMinor(['00000109-1234-5678-ABCD-00805F9B34FB']), 8);
  check('保留目标服务', partial.includes(LeapBLEProtocol.normalizeUUID('FFFE')), true);
}

section('iOS 1.22.66 距离与版本兼容');
{
  let config = new LeapBLEConfiguration(56, 200, 12, 16, true, false, false, true);
  config = config.withUnlockDistance(BLEUnlockDistance.Near);
  check('较近写入 04', config.calibrationText, '56;2.00;04;16');
  check('开关修改保留距离选择', config.withPassiveUnlock(true).unlockDistance, BLEUnlockDistance.Near);
  config = config.withUnlockDistance(BLEUnlockDistance.Far).withUnlockDistance(BLEUnlockDistance.Standard);
  check('默认恢复云端基准', config.unlockCalibration, 12);
  check('旧车/新车配置长度', config.wireBytes(8).length + '/' + config.wireBytes(9).length, '7/9');
  const response = JsonValue.parse(JSON.stringify({data: {anchorPointParams:'56;2.00;12;16', autonomyParams:'56;2.00;04;16',
    multipleAnchorPointParams:'60;2.50;14;20', multipleAnchorAutonomyParams:'60;2.50;07;20'}}));
  const one = BLECalibration.fromJson(response).applying(LeapBLEConfiguration.manualControl);
  const multi = BLECalibration.fromJson(response, true).applying(LeapBLEConfiguration.manualControl);
  check('单锚点距离和基准', one.unlockDistance + '/' + one.defaultUnlockCalibration, '4/12');
  check('多锚点距离和基准', multi.unlockDistance + '/' + multi.defaultUnlockCalibration + '/' + multi.multipleAnchors, '7/14/true');
  check('拒绝损坏标定', BLECalibration.parse('56;NaN;08;16'), null);
  check('广播协议版本', [LeapBLEProtocol.protocolMinor(['FFFE','0109']), LeapBLEProtocol.protocolMinor(['0106']), LeapBLEProtocol.protocolMinor([])].join('/'), '9/6/8');
  const session = makeDeterministicSession();
  const old = session.reconnectAuthenticationFrame('deadbeef', '1234567890', LeapBLEConfiguration.officialDefault, 0x0102030405060708n, true, 6);
  check('新版兼容旧车仍是两字节长度，无版本摘要', old.length + '/' + hex(old.slice(0,8)), '117/aaee7100d4b01a00');
}

section('官方座舱直进直出：独立认证、回包与控制生命周期');
{
  const session = makeDeterministicSession();
  const auth = session.callCarAuthenticationFrame(deterministicCertificate(), '12345678', 'device', 1700000000);
  check('座舱模块头与 1.10 版本', hex(auth.slice(0, 5)), 'aaae01010a');
  check('长度字段位于第 5 字节', auth[5] | auth[6] << 8, auth.length - 7);
  const plain = session.decrypt(reencapsulate(auth.slice(76)));
  const length = LeapBytes.readLittleEndian32(plain, 0);
  check('明文不含钥匙配置', Buffer.from(plain.slice(4, 4 + length)).toString(), '1700000000;a;12345678;device;d;e;f;');
  check('签名原样附加', plain.length, 4 + length + 64);
  for (const order of [1, 2, 3, 4, 5, 6]) {
    check('独立指令 ' + order, hex(session.decrypt(single(new LeapBLEFrameReassembler().append(session.callCarOrderFrame(order))))), hex(bytes(order)));
  }
  check('通用三段回包不能放行', CallCarStatus.parse('2;01;3'), null);
  check('ON3 触发激活', CallCarStatus.parse('0;5;1;0;0').kind, CallCarStatusKind.Activate);
  check('业务就绪', CallCarStatus.parse('0;2;0;0;0').kind, CallCarStatusKind.Ready);
  check('故障优先于暂停', CallCarStatus.parse('0;2;0;4;9').kind, CallCarStatusKind.Failed);
  check('障碍物暂停', CallCarStatus.parse('0;2;0;4;0').kind, CallCarStatusKind.Paused);
  const raw = bytes(170, 172, 1, 1, 0, 3, 0, 0, 0, 65, 66, 67, 0, 0);
  const parser = new CallCarPacketBuffer();
  check('噪声与分片', parser.append(join(bytes(0, 170), raw.slice(0, 7))).length, 0);
  check('座舱粘包', parser.append(join(raw.slice(7), raw)).length, 2);
  check('异常长度拒绝', thrownMessage(() => new CallCarPacketBuffer().append(bytes(170, 172, 1, 1, 0, 255, 255, 255, 255))), '座舱回包长度异常');
  const marker = Buffer.from((await import('node:crypto')).createHash('md5').update('TESTVIN1234567890').digest('hex').slice(8, 16));
  check('只连接匹配 VIN 的座舱', CallCarProtocol.matches(join(new Uint8Array(6), marker), 'TESTVIN1234567890'), true);
  check('其它车辆不能匹配', CallCarProtocol.matches(join(new Uint8Array(6), marker), 'OTHER'), false);

  const controller = new CallCarController();
  const orders = [];
  const writes = new LeapBLEFrameReassembler();
  controller.client = {
    async writeCharacteristicValue(value) {
      for (const frame of writes.append(new Uint8Array(value.characteristicValue))) orders.push(session.decrypt(frame)[0]);
    }, off() {}, disconnect() {}, close() {}
  };
  controller.crypto = session;
  controller.characteristic = { serviceUuid: CallCarProtocol.service, characteristicUuid: CallCarProtocol.characteristic, descriptors: [] };
  controller.authenticated = true;
  controller.lastResponse = Date.now();
  check('未就绪不允许移动', thrownMessage(() => controller.startStraightMove(StraightMoveDirection.Forward)), '请等待车辆就绪；暂停后需先恢复');
  controller.straightMoveState = BLEStraightMoveState.ready;
  controller.startStraightMove(StraightMoveDirection.Forward);
  await new Promise(resolve => setTimeout(resolve, 5));
  check('按下发送前进', orders.at(-1), 1);
  controller.stopStraightMove();
  await new Promise(resolve => setTimeout(resolve, 5));
  check('松手发停止', orders.at(-1), 3);
  check('停止后不自动续行', controller.straightMoveState.kind, BLEStraightMoveStateKind.Paused);
  controller.resume();
  await new Promise(resolve => setTimeout(resolve, 5));
  check('恢复只发 4，不发方向', orders.at(-1), 4);
  check('恢复必须等业务确认', controller.straightMoveState.kind, BLEStraightMoveStateKind.Preparing);
  controller.setApplicationActive(false);
  await new Promise(resolve => setTimeout(resolve, 450));
  check('后台退出业务', orders.at(-1), 6);
  check('后台销毁连接', controller.client, null);
}

// 使用真实控制器/重组器，替换解密出口，覆盖状态退回、同批故障与超时。
{
  const frame = bytes(170, 172, 1, 1, 0, 0, 0, 0, 0, 0, 0);
  const controller = new CallCarController();
  let replies = ['0;1;0;0;0'];
  controller.crypto = { decrypt: () => LeapBytes.utf8(replies.shift()), callCarOrderFrame: () => new Uint8Array() };
  controller.straightMoveState = BLEStraightMoveState.ready;
  controller.receive(frame);
  check('等待回包撤销旧就绪状态', controller.straightMoveState.kind, BLEStraightMoveStateKind.Preparing);
  replies = ['0;5;1;0;0', '0;1;0;0;0'];
  controller.receive(join(frame, frame));
  check('激活中等待回包保留激活指令', controller.order, 5);
  replies = ['0;2;0;0;9', '0;2;0;0;0'];
  controller.receive(join(frame, frame));
  check('故障后的同批就绪回包不能重新放行', controller.straightMoveState.kind, BLEStraightMoveStateKind.Failed);
  await new Promise(resolve => setTimeout(resolve, 450));

  const timeout = new CallCarController();
  timeout.crypto = { decrypt: () => LeapBytes.utf8('0;2;0;0;0'), callCarOrderFrame: () => new Uint8Array() };
  timeout.receive(frame);
  timeout.lastResponse = Date.now() - 2000;
  await new Promise(resolve => setTimeout(resolve, 150));
  check('业务回包超时退出', timeout.straightMoveState.kind, BLEStraightMoveStateKind.Failed);
  await new Promise(resolve => setTimeout(resolve, 450));
}

section('iOS cloud protocol profile and real calibration parity');
for (const result of ['', '000', '01', '1']) check(`reject config result '${result}'`, LeapBLEProtocol.acceptsConfigurationResult(result), false);
for (const result of ['0', '00']) check(`accept config result '${result}'`, LeapBLEProtocol.acceptsConfigurationResult(result), true);
{
  for (const version of ['2.0', '2', '1.9.0', '01.09.00', '1.256']) {
    check(`cloud version ${version}`, LeapBLEProtocol.cloudProtocolMinor(JsonValue.parse(JSON.stringify({data:{list:[{bluetoothInfo:version}]}}))), 9);
  }
  for (const version of ['', '0.9', '1.-2', '1.x', '256.0', '1..9']) {
    check(`invalid cloud version ${version}`, LeapBLEProtocol.cloudProtocolMinor(JsonValue.parse(JSON.stringify({data:{list:[{bluetoothInfo:version}]}}))), undefined);
  }
  check('unknown version is not assumed 1.8', LeapBLEProtocol.resolvedProtocolMinor(undefined, ['FFFE'], undefined), undefined);
  check('cloud takes precedence', LeapBLEProtocol.resolvedProtocolMinor(9, ['0108'], 8), 9);
  let config = BLECalibration.fromJson(JsonValue.parse(JSON.stringify({data:{anchorPointParams:'68;1.10;04;21',autonomyParams:'68;1.10;07;21'}}))).applying(LeapBLEConfiguration.officialDefault);
  check('real calibration far', config.calibrationText, '68;1.10;07;21');
  check('real calibration wire', hex(config.wireBytes(9)), '446e00071501000101');
  config = config.withUnlockDistance(BLEUnlockDistance.Standard);
  check('default may equal near', config.calibrationText, '68;1.10;04;21');
}

console.log(failures === 0 ? '\n全部通过。' : `\n${failures} 项不一致。`);
process.exit(failures === 0 ? 0 : 1);

// ---- 辅助 ----

/** iOS 测试里的确定性证书，keyType=0 走老款 P-256 路径。 */
function deterministicCertificate() {
  return new LeapBLEKeyCertificate(
    'BHzyexiNA09+ilI4AwS1GsPAiWnid/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=',
    0, '0123456789'.repeat(8), 'a;b;c;d;e;f', Buffer.alloc(64).toString('base64'), 'TESTVIN1234567890');
}

function makeDeterministicSession() {
  return LeapBLECryptoSession.make(
    deterministicCertificate(), 'TESTVIN1234567890', 0x001AB0D4, privateKey);
}

/** 认证帧里的密文是 Base64 文本，套回一个 `AA AB` 才能交给 `decrypt`。 */
function reencapsulate(encodedCipher) {
  return single(new LeapBLEFrameReassembler().append(join(
    bytes(0xAA, 0xAB), LeapBytes.littleEndian32(encodedCipher.length), encodedCipher)));
}

/** 从 `AA AE` / `AA EE` 帧里取出认证明文的文本段。`tail` 是帧尾不属于密文的字节数。 */
function authTextOf(session, frame, tail) {
  const plain = session.decrypt(reencapsulate(frame.slice(73, frame.length - tail)));
  const length = LeapBytes.readLittleEndian32(plain, 0);
  return Buffer.from(plain.slice(4, 4 + length)).toString('utf8');
}

/** 手工拼一份最小 v3 证书，只为覆盖 `subjectPublicKeyFromCertificate` 的路径。 */
function buildSelfSignedSM2Certificate(publicKey) {
  const der = (tag, content) => {
    const body = Buffer.from(content);
    let length;
    if (body.length < 0x80) {
      length = Buffer.from([body.length]);
    } else if (body.length < 0x100) {
      length = Buffer.from([0x81, body.length]);
    } else {
      length = Buffer.from([0x82, body.length >> 8, body.length & 0xff]);
    }
    return Buffer.concat([Buffer.from([tag]), length, body]);
  };
  const oid = (values) => der(0x06, Buffer.from(values));
  const algorithm = der(0x30, Buffer.concat([
    oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
    oid([0x2A, 0x81, 0x1C, 0xCF, 0x55, 0x01, 0x82, 0x2D])
  ]));
  const spki = der(0x30, Buffer.concat([
    algorithm,
    der(0x03, Buffer.concat([Buffer.from([0x00]), Buffer.from(publicKey)]))
  ]));
  const name = der(0x30, der(0x31, der(0x30, Buffer.concat([
    oid([0x55, 0x04, 0x03]),
    der(0x0C, Buffer.from('Leap BLE Test'))
  ]))));
  const validity = der(0x30, Buffer.concat([
    der(0x17, Buffer.from('260811112424Z')),
    der(0x17, Buffer.from('360808112424Z'))
  ]));
  const tbs = der(0x30, Buffer.concat([
    der(0xA0, der(0x02, Buffer.from([0x02]))),
    der(0x02, Buffer.from([0x01])),
    algorithm,
    name,
    validity,
    name,
    spki
  ]));
  const certificate = der(0x30, Buffer.concat([
    tbs,
    algorithm,
    der(0x03, Buffer.concat([Buffer.from([0x00]), Buffer.alloc(70, 0x01)]))
  ]));
  return `-----BEGIN CERTIFICATE-----\n${certificate.toString('base64')}\n-----END CERTIFICATE-----`;
}
