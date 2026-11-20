import { ble, access, constant } from '@kit.ConnectivityKit';
import { LeapBLECredentialContext, LeapBLECryptoSession, LeapBytes, LeapBLEFrame, LeapBLEFrameKind,
  StraightMoveDirection } from '../core/BLEProtocol';
import { CallCarProtocol, CallCarPacketBuffer, CallCarStatus, CallCarStatusKind } from '../core/CallCarProtocol';
import { concatBytes } from '../core/EllipticCurve';
import { BLEStraightMoveState, BLEStraightMoveStateKind, BLEBuffer } from './BLEVehicleControllerTypes';

/** EEED 座舱专用连接。独立认证、分片缓冲与控制心跳，不复用无感钥匙连接。 */
@ObservedV2
export class CallCarController {
  @Trace straightMoveState: BLEStraightMoveState = BLEStraightMoveState.idle;
  @Trace authenticated: boolean = false;
  private context: LeapBLECredentialContext | null = null;
  private client: ble.GattClientDevice | null = null;
  private characteristic: ble.BLECharacteristic | null = null;
  private crypto: LeapBLECryptoSession | null = null;
  private buffer: CallCarPacketBuffer = new CallCarPacketBuffer();
  private order: number = 3;
  private generation: number = 0;
  private closing: boolean = false;
  private active: boolean = true;
  private writing: boolean = false;
  private writeStarted: number = 0;
  private lastResponse: number = 0;
  private timer: number = -1;
  private scanListener: ((results: ble.ScanResult[]) => void) | null = null;
  private readonly logSink: (category: string, message: string, sensitiveDetail: string) => void;

  constructor(logSink: (category: string, message: string, sensitiveDetail: string) => void =
    (_category: string, _message: string, _sensitiveDetail: string): void => {}) {
    this.logSink = logSink;
  }

  private trace(message: string, category: string = 'COCKPIT'): void {
    this.logSink(category, message, '');
  }

  private setState(value: BLEStraightMoveState): void {
    if (!this.straightMoveState.equals(value)) { this.trace(`state=${CallCarController.stateName(value)}`); }
    this.straightMoveState = value;
  }

  configure(value: LeapBLECredentialContext | null): void {
    if (value?.vin !== this.context?.vin || value?.accountId !== this.context?.accountId ||
      value?.certificate.fingerprint !== this.context?.certificate.fingerprint) { this.closeStraightMove(); }
    this.context = value;
  }
  setApplicationActive(active: boolean): void { this.active = active; if (!active) { this.closeStraightMove(); } }
  async prepareStraightMove(): Promise<void> {
    this.trace(`prepare certificate=${this.context !== null} active=${this.active}`);
    if (!this.active || this.context === null) { throw new Error('请同步车辆蓝牙证书并保持 App 在前台'); }
    this.disconnect();
    const epoch = ++this.generation;
    this.closing = false;
    this.setState(BLEStraightMoveState.preparing);
    try {
      if (access.getState() !== access.BluetoothState.STATE_ON) { throw new Error('请打开手机蓝牙'); }
      this.trace('scan.start service=EEED');
      this.scanListener = (results: ble.ScanResult[]): void => {
        for (const result of results) {
          if (epoch !== this.generation || this.client !== null || this.closing || this.context === null) { return; }
          if (!CallCarProtocol.matchesAdvertisement(new Uint8Array(result.data), this.context.vin)) { continue; }
          this.trace(`scan.match rssi=${result.rssi}`);
          this.stopScan();
          try {
            const client = ble.createGattClientDevice(result.deviceId);
            this.client = client;
            this.trace('connect.request');
            client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState): void => {
              if (client !== this.client) { return; }
              this.trace(`connection state=${state.state}`);
              if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) { this.prepareLink(client, epoch); }
              if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) { this.authenticated = false; this.fail('座舱蓝牙已断开'); }
            });
            client.on('BLECharacteristicChange', (value: ble.BLECharacteristic): void => {
              if (client === this.client && value.characteristicUuid.toLowerCase() === CallCarProtocol.characteristic) {
                this.receive(new Uint8Array(value.characteristicValue));
              }
            });
            client.connect();
          } catch (e) { this.trace(`connect.failed error=${(e as Error).message}`); this.fail('座舱蓝牙连接失败'); }
          break;
        }
      };
      ble.on('BLEDeviceFind', this.scanListener);
      ble.startBLEScan([{ serviceUuid: CallCarProtocol.service } as ble.ScanFilter]);
      const deadline = Date.now() + 50000;
      while (Date.now() < deadline) {
        if (epoch !== this.generation) { throw new Error('直进直出连接已取消'); }
        if (this.straightMoveState.kind === BLEStraightMoveStateKind.Ready) { return; }
        if (this.straightMoveState.kind === BLEStraightMoveStateKind.Failed) { throw new Error(this.straightMoveState.message); }
        await CallCarController.sleep(80);
      }
      throw new Error('车辆直进直出未就绪，请检查上电、车门、P 档和周围环境');
    } catch (e) {
      if (epoch === this.generation) { this.fail((e as Error).message); }
      throw new Error((e as Error).message);
    }
  }
  startStraightMove(direction: StraightMoveDirection): void {
    if (!this.active || this.closing || !this.authenticated || this.straightMoveState.kind !== BLEStraightMoveStateKind.Ready ||
      Date.now() - this.lastResponse >= 1000) { throw new Error('请等待车辆就绪；暂停后需先恢复'); }
    this.order = direction === StraightMoveDirection.Forward ? 1 : 2;
    this.setState(BLEStraightMoveState.moving(direction));
    this.sendOrder();
  }
  stopStraightMove(): void {
    if (!this.authenticated || this.closing) { return; }
    this.order = 3; this.setState(BLEStraightMoveState.paused); this.sendOrder();
  }
  resume(): void {
    if (!this.authenticated || this.closing || this.straightMoveState.kind !== BLEStraightMoveStateKind.Paused) { return; }
    this.order = 4; this.setState(BLEStraightMoveState.preparing); this.sendOrder();
  }
  closeStraightMove(): void {
    this.trace(`close authenticated=${this.authenticated}`);
    const epoch = ++this.generation;
    this.closing = true; this.order = 3; this.setState(BLEStraightMoveState.idle);
    if (!this.authenticated) { this.disconnect(); return; }
    this.sendOrder();
    setTimeout((): void => {
      if (epoch !== this.generation) { return; }
      this.order = 6; this.sendOrder();
      setTimeout((): void => { if (epoch === this.generation) { this.disconnect(); } }, 200);
    }, 200);
  }
  private fail(message: string): void {
    this.trace(`fail message=${message}`);
    this.closeStraightMove();
    this.setState(BLEStraightMoveState.failed(message));
  }
  private stopScan(): void {
    if (this.scanListener !== null) {
      try { ble.stopBLEScan(); ble.off('BLEDeviceFind', this.scanListener); } catch (e) {}
      this.scanListener = null;
    }
  }
  private disconnect(): void {
    this.trace('disconnect local=true');
    this.stopScan();
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    const client = this.client; this.client = null;
    if (client !== null) {
      try { client.off('BLEConnectionStateChange'); client.off('BLECharacteristicChange'); client.disconnect(); client.close(); } catch (e) {}
    }
    this.characteristic = null; this.crypto = null; this.authenticated = false;
    this.buffer = new CallCarPacketBuffer(); this.writing = false;
  }
  private async prepareLink(client: ble.GattClientDevice, epoch: number): Promise<void> {
    try {
      const services = await client.getServices();
      if (client !== this.client || epoch !== this.generation) { return; }
      const service = services.find((s: ble.GattService): boolean => s.serviceUuid.toLowerCase() === CallCarProtocol.service);
      const target = service?.characteristics.find((c: ble.BLECharacteristic): boolean => c.characteristicUuid.toLowerCase() === CallCarProtocol.characteristic);
      this.trace(`services.discovered count=${services.length} service=${service !== undefined} target=${target !== undefined}`);
      if (target === undefined || target.properties?.write !== true) { throw new Error('车辆未提供直进直出服务'); }
      this.characteristic = target;
      this.trace('notify.request');
      await client.setCharacteristicChangeNotification(target, true);
      this.trace('notify.ack success=true');
      if (client !== this.client || epoch !== this.generation || this.context === null) { return; }
      const c = this.context;
      this.crypto = LeapBLECryptoSession.make(c.certificate, c.vin);
      const frame = this.crypto.callCarAuthenticationFrame(c.certificate, c.accountId, c.deviceId);
      this.trace(`auth.frame bytes=${frame.length}`);
      await this.write(frame);
    } catch (e) { if (client === this.client && epoch === this.generation) { this.fail((e as Error).message); } }
  }
  private async write(bytes: Uint8Array): Promise<void> {
    const client = this.client;
    const characteristic = this.characteristic;
    this.trace(`tx.request header=${LeapBytes.hexString(bytes.slice(0, Math.min(2, bytes.length)))} bytes=${bytes.length} busy=${this.writing} order=${this.order}`,
      'COCKPIT-TX');
    if (this.writing || client === null || characteristic === null) { return; }
    this.writing = true; this.writeStarted = Date.now();
    try {
      for (let offset = 0; offset < bytes.length; offset += 20) {
        if (client !== this.client) { return; }
        const chunk = bytes.slice(offset, Math.min(bytes.length, offset + 20));
        const payload: ble.BLECharacteristic = {
          serviceUuid: characteristic.serviceUuid, characteristicUuid: characteristic.characteristicUuid,
          characteristicValue: BLEBuffer.toArrayBuffer(chunk), descriptors: characteristic.descriptors
        };
        await client.writeCharacteristicValue(payload, ble.GattWriteType.WRITE);
        this.trace(`tx.ack chunk=${Math.trunc(offset / 20) + 1}`, 'COCKPIT-TX');
      }
    } catch (e) { if (client === this.client) { this.authenticated = false; this.fail('座舱指令写入失败'); } }
    finally { if (client === this.client) { this.writing = false; } }
  }
  private sendOrder(): void {
    if (!this.authenticated || this.writing || this.crypto === null) { return; }
    try { this.write(this.crypto.callCarOrderFrame(this.order)); } catch (e) { this.authenticated = false; this.fail('座舱指令加密失败'); }
  }
  private receive(data: Uint8Array): void {
    if (this.closing || this.crypto === null) { return; }
    this.trace(`rx.chunk bytes=${data.length}`, 'COCKPIT-RX');
    try {
      for (const packet of this.buffer.append(data)) {
        if (this.closing) { return; }
        this.trace(`rx.frame type=${packet.type} bytes=${packet.payload.length}`, 'COCKPIT-RX');
        if (packet.type === 0) { throw new Error('座舱认证失败，请重新同步蓝牙证书'); }
        const raw = concatBytes([new Uint8Array([170, 171]), LeapBytes.littleEndian32(packet.payload.length), packet.payload]);
        const plain = this.crypto.decrypt(new LeapBLEFrame(LeapBLEFrameKind.Encrypted, packet.payload.length, raw));
        const status = CallCarStatus.parse(LeapBytes.decodeUTF8(plain));
        if (status === null) { throw new Error('无法识别座舱状态'); }
        this.authenticated = true; this.lastResponse = Date.now();
        this.trace(`rx.status kind=${CallCarController.statusName(status.kind)} reason=${status.reason}`, 'COCKPIT-RX');
        switch (status.kind) {
          case CallCarStatusKind.Waiting:
            if (this.straightMoveState.kind === BLEStraightMoveStateKind.Ready || this.straightMoveState.isMoving) {
              this.order = 3; this.setState(BLEStraightMoveState.preparing);
            }
            break;
          case CallCarStatusKind.Activate: this.order = 5; this.setState(BLEStraightMoveState.preparing); break;
          case CallCarStatusKind.Ready:
            if (!this.straightMoveState.isMoving) { this.order = 3; this.setState(BLEStraightMoveState.ready); }
            break;
          case CallCarStatusKind.Paused: this.order = 3; this.setState(BLEStraightMoveState.paused); break;
          case CallCarStatusKind.Failed: this.fail(`车辆退出直进直出（原因 ${status.reason}）`); break;
          case CallCarStatusKind.Unavailable: this.fail(`车辆暂不可用，请检查车门、P 档和踏板（原因 ${status.reason}）`); break;
          default: break;
        }
        if (!this.closing && this.timer === -1) {
          this.trace('heartbeat.start intervalMs=100');
          this.timer = setInterval((): void => {
            if (!this.closing && (Date.now() - this.lastResponse > 1000 || (this.writing && Date.now() - this.writeStarted > 350))) {
              this.fail('座舱控制连接超时，已停止'); return;
            }
            this.sendOrder();
          }, 100);
        }
      }
    } catch (e) { this.fail((e as Error).message); }
  }
  private static sleep(ms: number): Promise<void> { return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); }); }

  private static stateName(value: BLEStraightMoveState): string {
    switch (value.kind) {
      case BLEStraightMoveStateKind.Idle: return 'idle';
      case BLEStraightMoveStateKind.Preparing: return 'preparing';
      case BLEStraightMoveStateKind.Ready: return 'ready';
      case BLEStraightMoveStateKind.Moving: return `moving:${value.direction === StraightMoveDirection.Forward ? 'forward' : 'backward'}`;
      case BLEStraightMoveStateKind.Paused: return 'paused';
      default: return `failed:${value.message}`;
    }
  }

  private static statusName(kind: CallCarStatusKind): string {
    switch (kind) {
      case CallCarStatusKind.Waiting: return 'waiting';
      case CallCarStatusKind.Activate: return 'activate';
      case CallCarStatusKind.Ready: return 'ready';
      case CallCarStatusKind.Paused: return 'paused';
      case CallCarStatusKind.Failed: return 'failed';
      default: return 'unavailable';
    }
  }
}
