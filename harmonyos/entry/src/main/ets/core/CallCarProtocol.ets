import { LeapBytes } from './BLEProtocol';
import { LeapCrypto } from './LeapCrypto';
import { concatBytes } from './EllipticCurve';

export class CallCarProtocol {
  static readonly service: string = '0000eeed-0000-1000-8000-00805f9b34fb';
  static readonly characteristic: string = '0000eee2-0000-1000-8000-00805f9b34fb';
  static matches(manufacturer: Uint8Array, vin: string): boolean {
    if (manufacturer.length < 14) { return false; }
    return LeapBytes.decodeUTF8(manufacturer.slice(6, 14)) === LeapCrypto.md5Hex(LeapBytes.utf8(vin)).substring(8, 16);
  }
  static matchesAdvertisement(data: Uint8Array, vin: string): boolean {
    for (let offset = 0; offset + 1 < data.length;) {
      const length = data[offset];
      if (length === 0 || offset + length >= data.length) { break; }
      if (data[offset + 1] === 255 && CallCarProtocol.matches(data.slice(offset + 2, offset + length + 1), vin)) { return true; }
      offset += length + 1;
    }
    return false;
  }
}

export class CallCarPacket {
  type: number;
  payload: Uint8Array;
  constructor(type: number, payload: Uint8Array) { this.type = type; this.payload = payload; }
}
export class CallCarPacketBuffer {
  private buffer: Uint8Array = new Uint8Array();
  append(bytes: Uint8Array): CallCarPacket[] {
    this.buffer = concatBytes([this.buffer, bytes]);
    const packets: CallCarPacket[] = [];
    while (this.buffer.length >= 2) {
      if (this.buffer[0] !== 170 || this.buffer[1] !== 172) { this.buffer = this.buffer.slice(1); continue; }
      if (this.buffer.length < 9) { break; }
      const length = LeapBytes.readLittleEndian32(this.buffer, 5) >>> 0;
      if (length > 65536) { throw new Error('座舱回包长度异常'); }
      if (this.buffer.length < length + 11) { break; }
      if (this.buffer[2] !== 1) { throw new Error('座舱业务模块不匹配'); }
      packets.push(new CallCarPacket(this.buffer[3] | (this.buffer[4] << 8), this.buffer.slice(9, 9 + length)));
      this.buffer = this.buffer.slice(length + 11);
    }
    return packets;
  }
}
export enum CallCarStatusKind { Waiting, Activate, Ready, Paused, Failed, Unavailable }
export class CallCarStatus {
  kind: CallCarStatusKind;
  reason: number;
  constructor(kind: CallCarStatusKind, reason: number = 0) { this.kind = kind; this.reason = reason; }
  static parse(text: string): CallCarStatus | null {
    const parts = text.split(';');
    if (parts.length < 5) { return null; }
    const values: number[] = [];
    for (let i = 0; i < 5; i++) {
      if (!/^[0-9]+$/.test(parts[i])) { return null; }
      const n = Number(parts[i]);
      if (!Number.isSafeInteger(n)) { return null; }
      values.push(n);
    }
    if (values.every((n: number): boolean => n === 0)) { return new CallCarStatus(CallCarStatusKind.Waiting); }
    const status = values[1];
    if (status === 5) { return values[2] === 1 ? new CallCarStatus(CallCarStatusKind.Activate) : new CallCarStatus(CallCarStatusKind.Unavailable, values[2]); }
    if (values[4] !== 0) { return new CallCarStatus(CallCarStatusKind.Failed, values[4]); }
    if (values[3] !== 0) { return new CallCarStatus(CallCarStatusKind.Paused, values[3]); }
    if (values[2] !== 0) { return new CallCarStatus(CallCarStatusKind.Unavailable, values[2]); }
    if (status === 1) { return new CallCarStatus(CallCarStatusKind.Waiting); }
    if (status === 2 || status === 6) { return new CallCarStatus(CallCarStatusKind.Ready); }
    if (status === 4) { return new CallCarStatus(CallCarStatusKind.Paused); }
    return new CallCarStatus(CallCarStatusKind.Failed, status);
  }
}
