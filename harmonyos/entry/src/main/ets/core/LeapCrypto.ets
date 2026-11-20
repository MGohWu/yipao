import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { LeapError } from './LeapError';

/**
 * 与 demo `src/leapmotor-cn-sdk.js` 中的签名/加密实现一一对应（经 iOS 版对拍固化）。
 * 任何一处偏差都会让服务端返回 result=39（信息校验失败），因此这里的字节级行为不可随意“优化”。
 */
export class LeapCrypto {
  private static readonly hexChars = '0123456789abcdef';

  static utf8Encode(text: string): Uint8Array {
    const encoder = new util.TextEncoder('utf-8');
    return encoder.encodeInto(text);
  }

  static utf8Decode(data: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(data);
  }

  static toHex(data: Uint8Array): string {
    let out = '';
    for (let i = 0; i < data.length; i++) {
      const byte = data[i];
      out += LeapCrypto.hexChars.charAt((byte >> 4) & 0x0f) + LeapCrypto.hexChars.charAt(byte & 0x0f);
    }
    return out;
  }

  // ---- 摘要 ----

  private static digest(algorithm: string, data: Uint8Array): Uint8Array {
    const md = cryptoFramework.createMd(algorithm);
    md.updateSync({ data: data });
    return md.digestSync().data;
  }

  static md5Hex(data: Uint8Array): string {
    return LeapCrypto.toHex(LeapCrypto.digest('MD5', data));
  }

  /** 老链路签名：md5(hex) 取 [8, 24)，即中间 16 个十六进制字符。 */
  static shortMD5(input: string): string {
    return LeapCrypto.md5Hex(LeapCrypto.utf8Encode(input)).substring(8, 24);
  }

  static sha256Hex(input: string): string {
    return LeapCrypto.toHex(LeapCrypto.digest('SHA256', LeapCrypto.utf8Encode(input)));
  }

  static hmacSHA256Hex(message: string, key: Uint8Array): string {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = generator.convertKeySync({ data: key });
    const mac = cryptoFramework.createMac('SHA256');
    mac.initSync(symKey);
    mac.updateSync({ data: LeapCrypto.utf8Encode(message) });
    return LeapCrypto.toHex(mac.doFinalSync().data);
  }

  // ---- 签名串拼接 ----

  /**
   * 合并若干字典，按 key 升序排列后把 value 直接首尾相接。
   * Map 的 value 均为非空字符串，与 JS 侧「丢弃空值」的行为由调用方保证一致。
   */
  static sortAndConcatValues(...maps: (Map<string, string> | null)[]): string {
    const merged = new Map<string, string>();
    for (let i = 0; i < maps.length; i++) {
      const map = maps[i];
      if (map === null) {
        continue;
      }
      map.forEach((value: string, key: string) => {
        merged.set(key, value);
      });
    }
    const keys: string[] = [];
    merged.forEach((_value: string, key: string) => {
      keys.push(key);
    });
    keys.sort();
    let out = '';
    for (let i = 0; i < keys.length; i++) {
      out += merged.get(keys[i]) ?? '';
    }
    return out;
  }

  // ---- Base64 / Base64URL ----

  static base64Encode(data: Uint8Array): string {
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(data);
  }

  static base64Decode(text: string): Uint8Array {
    try {
      const helper = new util.Base64Helper();
      return helper.decodeSync(text);
    } catch (e) {
      return new Uint8Array(0);
    }
  }

  static base64URLNoPadding(data: Uint8Array): string {
    return LeapCrypto.base64Encode(data)
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');
  }

  static base64URLDecode(input: string): Uint8Array {
    let normalized = input.replace(/-/g, '+').replace(/_/g, '/');
    const remainder = normalized.length % 4;
    if (remainder > 0) {
      normalized += '===='.substring(0, 4 - remainder);
    }
    return LeapCrypto.base64Decode(normalized);
  }

  // ---- 手机号 RSA ----

  private static readonly publicKeyBase64 =
    'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB';

  /**
   * App 规则：手机号用固定公钥 RSA/PKCS1 加密后转 base64url（无 padding）。
   * cryptoFramework 直接吃 X.509(SPKI) DER，不需要像 iOS 那样手工剥 SPKI 头。
   */
  static phoneNoCiphertext(phone: string): string {
    const spki = LeapCrypto.base64Decode(LeapCrypto.publicKeyBase64);
    if (spki.length === 0) {
      throw LeapError.crypto('内置公钥解析失败');
    }
    try {
      const generator = cryptoFramework.createAsyKeyGenerator('RSA1024');
      const keyPair = generator.convertKeySync({ data: spki }, null);
      const cipher = cryptoFramework.createCipher('RSA1024|PKCS1');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
      const encrypted = cipher.doFinalSync({ data: LeapCrypto.utf8Encode(phone) });
      return LeapCrypto.base64URLNoPadding(encrypted.data);
    } catch (e) {
      throw LeapError.crypto(`手机号加密失败: ${(e as Error).message}`);
    }
  }

  // ---- signKey 推导 ----

  /** signKey = accessToken 第三段(base64url) XOR r2(base64) XOR r3(base64)，长度取三者最小值。 */
  static deriveSignKey(accessToken: string, r2: string, r3: string): Uint8Array {
    const parts = accessToken.split('.');
    if (parts.length !== 3) {
      throw LeapError.crypto('accessToken 不是三段式 token');
    }
    const tail = LeapCrypto.base64URLDecode(parts[2]);
    const r2Bytes = LeapCrypto.base64Decode(r2);
    const r3Bytes = LeapCrypto.base64Decode(r3);
    const length = Math.min(tail.length, r2Bytes.length, r3Bytes.length);
    if (length <= 0) {
      throw LeapError.crypto('signKey 素材为空');
    }
    const out = new Uint8Array(length);
    for (let i = 0; i < length; i++) {
      out[i] = tail[i] ^ r2Bytes[i] ^ r3Bytes[i];
    }
    return out;
  }

  // ---- 操作密码 ----

  /** oppwd = AES-128-CBC(操作密码)，key/iv 由老 token 前后 32 字符各自求短 MD5 得到。 */
  static encryptOperationPassword(password: string, oldToken: string): string {
    if (password.length === 0) {
      return '';
    }
    if (oldToken.length < 64) {
      throw LeapError.crypto('旧 token 长度不足，无法加密操作密码');
    }
    const key = LeapCrypto.utf8Encode(LeapCrypto.shortMD5(oldToken.substring(0, 32)));
    const iv = LeapCrypto.utf8Encode(LeapCrypto.shortMD5(oldToken.substring(32, 64)));
    try {
      const generator = cryptoFramework.createSymKeyGenerator('AES128');
      const symKey = generator.convertKeySync({ data: key });
      const ivSpec: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv }
      };
      const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
      const encrypted = cipher.doFinalSync({ data: LeapCrypto.utf8Encode(password) });
      return LeapCrypto.base64Encode(encrypted.data);
    } catch (e) {
      throw LeapError.crypto(`操作密码加密失败 (${(e as Error).message})`);
    }
  }

  // ---- JWT ----

  /** 读取 JWT 的 exp（毫秒）。 */
  static jwtExpiryMilliseconds(token: string): number {
    const parts = token.split('.');
    if (parts.length !== 3) {
      return 0;
    }
    try {
      const payload = LeapCrypto.utf8Decode(LeapCrypto.base64URLDecode(parts[1]));
      const parsed: Record<string, number> = JSON.parse(payload) as Record<string, number>;
      const exp = parsed['exp'];
      if (typeof exp === 'number' && exp > 0) {
        return exp * 1000;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  static randomNonce(): string {
    return String(10000 + Math.floor(Math.random() * (10009999 - 10000 + 1)));
  }
}
