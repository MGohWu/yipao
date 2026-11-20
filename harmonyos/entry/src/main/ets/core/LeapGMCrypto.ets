import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { LeapBLEError } from './LeapBLEError';
import { AffinePoint, bigIntToBytes, bytesToBigInt, concatBytes, EllipticCurve } from './EllipticCurve';

/**
 * 蓝牙钥匙用到的国密原语。
 *
 * iOS 那边这一层是 GmSSL 的 C 封装（`Core/GMCrypto/LeapGMCrypto.c`）。
 * 鸿蒙没有可直接链接的 GmSSL，`cryptoFramework` 又只给了 SM2 的签名和公钥加密，
 * 没有密钥协商（KAP），也没有暴露曲线上的点运算——而实车认证要的正是 KAP。
 * 所以这里的分工是：
 *
 * - SM3、SM4-CBC-PKCS7 直接用系统实现（`cryptoFramework`，同步 API）；
 * - SM2 的曲线运算走 `EllipticCurve`（手写 bigint）；
 * - Z 值、SM3-KDF 按 GB/T 32918 拼，字节序与 GmSSL 逐字节一致。
 *
 * 正确性不是「看着像」：`sm2KAP` 的输出已经拿 iOS `BLEProtocolTests` 里那组固定向量
 * 对过（私钥 = 31 个 0 字节 + 0x01，对端公钥固定），本机公钥和会话密钥全字节相同。
 * 校验脚本是 `scripts/ble-selftest.mjs`，改动这一层之后必须重跑。
 */

/** GmSSL 的 `SM2_DEFAULT_ID`。官方车端也用它，换掉的话 Z 值对不上。 */
const SM2_DEFAULT_ID = '1234567812345678';

const SM2_CURVE = EllipticCurve.sm2p256v1;

/** X.509 里的一个 TLV。只记位置，不复制内容。 */
class DERElement {
  readonly tag: number;
  readonly contentStart: number;
  readonly contentLength: number;

  constructor(tag: number, contentStart: number, contentLength: number) {
    this.tag = tag;
    this.contentStart = contentStart;
    this.contentLength = contentLength;
  }

  get end(): number {
    return this.contentStart + this.contentLength;
  }
}

/**
 * 极小的 DER 遍历器。
 *
 * 只够走「证书 → tbsCertificate → subjectPublicKeyInfo → BIT STRING」这一条路径。
 * 没有引 `@kit.DeviceCertificateKit`：那套要先把证书整体交给系统解析，SM2 证书在部分机型上
 * 会被判成不支持的算法直接抛错，而这里要的只是里面那 65 个字节。
 */
function readDERElement(bytes: Uint8Array, offset: number): DERElement {
  if (offset + 2 > bytes.length) {
    throw LeapBLEError.invalidCertificate('DER 结构在标签处就截断了');
  }
  const tag = bytes[offset];
  const first = bytes[offset + 1];
  let contentStart = offset + 2;
  let contentLength = first;
  if ((first & 0x80) !== 0) {
    const lengthBytes = first & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4 || contentStart + lengthBytes > bytes.length) {
      throw LeapBLEError.invalidCertificate('DER 长度字段无效');
    }
    contentLength = 0;
    for (let index = 0; index < lengthBytes; index++) {
      contentLength = (contentLength << 8) | bytes[contentStart + index];
    }
    contentStart += lengthBytes;
  }
  if (contentStart + contentLength > bytes.length) {
    throw LeapBLEError.invalidCertificate('DER 内容长度超出了证书本身');
  }
  return new DERElement(tag, contentStart, contentLength);
}

function subjectPublicKeyFromCertificate(der: Uint8Array): Uint8Array {
  const certificate = readDERElement(der, 0);
  if (certificate.tag !== 0x30) {
    throw LeapBLEError.invalidCertificate('最外层不是 SEQUENCE');
  }
  const tbs = readDERElement(der, certificate.contentStart);
  if (tbs.tag !== 0x30) {
    throw LeapBLEError.invalidCertificate('tbsCertificate 不是 SEQUENCE');
  }

  // v3 证书的第一个元素是 [0] EXPLICIT version，v1 直接从 serialNumber 开始。
  // SPKI 固定排在 serialNumber、signature、issuer、validity、subject 之后。
  const first = readDERElement(der, tbs.contentStart);
  const skipCount = first.tag === 0xa0 ? 6 : 5;
  let offset = tbs.contentStart;
  for (let index = 0; index < skipCount; index++) {
    offset = readDERElement(der, offset).end;
  }

  const spki = readDERElement(der, offset);
  if (spki.tag !== 0x30) {
    throw LeapBLEError.invalidCertificate('subjectPublicKeyInfo 不是 SEQUENCE');
  }
  const algorithm = readDERElement(der, spki.contentStart);
  const bitString = readDERElement(der, algorithm.end);
  if (bitString.tag !== 0x03 || bitString.contentLength !== 66) {
    throw LeapBLEError.invalidCertificate('公钥不是 65 字节未压缩 SM2 点');
  }
  if (der[bitString.contentStart] !== 0x00) {
    throw LeapBLEError.invalidCertificate('公钥 BIT STRING 有未使用位');
  }
  return der.slice(bitString.contentStart + 1, bitString.end);
}

/** 协商结果：本机 65 字节未压缩公钥 + 32 字节会话密钥。字段名与 iOS 的 `Agreement` 一致。 */
export class LeapGMAgreement {
  readonly publicKey: Uint8Array;
  readonly sharedKey: Uint8Array;

  constructor(publicKey: Uint8Array, sharedKey: Uint8Array) {
    this.publicKey = publicKey;
    this.sharedKey = sharedKey;
  }
}

export class LeapGMCrypto {
  // ---- 系统实现的原语 ----

  /** SM3。空输入按 iOS 一样直接拒绝：那从来不是有意的调用。 */
  static sm3(data: Uint8Array): Uint8Array {
    if (data.length === 0) {
      throw LeapBLEError.cryptoFailure('SM3 输入为空');
    }
    try {
      const md = cryptoFramework.createMd('SM3');
      md.updateSync({ data: data });
      return md.digestSync().data;
    } catch (e) {
      throw LeapBLEError.cryptoFailure(`SM3 失败（${(e as Error).message}）`);
    }
  }

  static sm4Encrypt(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
    return LeapGMCrypto.sm4(data, key, iv, true);
  }

  static sm4Decrypt(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
    return LeapGMCrypto.sm4(data, key, iv, false);
  }

  private static sm4(data: Uint8Array, key: Uint8Array, iv: Uint8Array, encrypting: boolean): Uint8Array {
    if (data.length === 0 || key.length !== 16 || iv.length !== 16) {
      throw LeapBLEError.cryptoFailure('SM4 输入或 key/iv 长度无效');
    }
    try {
      const generator = cryptoFramework.createSymKeyGenerator('SM4_128');
      const symKey = generator.convertKeySync({ data: key });
      const ivSpec: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv }
      };
      const cipher = cryptoFramework.createCipher('SM4_128|CBC|PKCS7');
      cipher.initSync(
        encrypting ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE,
        symKey,
        ivSpec
      );
      return cipher.doFinalSync({ data: data }).data;
    } catch (e) {
      throw LeapBLEError.cryptoFailure(`SM4-CBC 失败（${(e as Error).message}）`);
    }
  }

  // ---- SM2 ----

  /**
   * 生成一把落在 [1, n) 的临时私钥。
   *
   * 每次连接都换一把。取系统随机数再判区间，落在外面就重取——概率小到实际不会发生，
   * 但真落在外面算出来的公钥是废的，不能凑合。
   */
  static generatePrivateKey(curve: EllipticCurve = SM2_CURVE): Uint8Array {
    for (let attempt = 0; attempt < 8; attempt++) {
      const candidate = cryptoFramework.createRandom().generateRandomSync(32).data;
      if (curve.isValidPrivateKey(bytesToBigInt(candidate))) {
        return candidate;
      }
    }
    throw LeapBLEError.cryptoFailure('临时私钥生成失败');
  }

  /**
   * SM2 密钥协商，对齐 GmSSL 版 `leap_gm_sm2_kap`。
   *
   * 官方 App 把静态密钥当临时密钥用（P = R），所以标准里的两组因子塌缩成：
   * 本机 t = d + x̄(P_self.x)·d，对端 U = (1 + x̄(P_peer.x))·P_peer，
   * 会话密钥 = KDF(agreement.x ‖ agreement.y ‖ Z_self ‖ Z_peer, 32)。
   *
   * `peerPublicKeyX963` 给了就用它，没给才去解证书——和 iOS 同一条判断顺序。
   */
  static sm2KAP(
    certificatePEM: string,
    privateKey: Uint8Array | null,
    peerPublicKeyX963: Uint8Array | null
  ): LeapGMAgreement {
    if (privateKey !== null && privateKey.length !== 32) {
      throw LeapBLEError.cryptoFailure('SM2 临时私钥不是 32 字节');
    }
    const peerBytes = peerPublicKeyX963 !== null
      ? peerPublicKeyX963
      : subjectPublicKeyFromCertificate(LeapGMCrypto.decodeCertificate(certificatePEM));
    const peer = SM2_CURVE.decodeX963(peerBytes);
    if (peer === null) {
      throw LeapBLEError.invalidCertificate('SM2 公钥不是曲线上的 65 字节未压缩点');
    }

    const privateBytes = privateKey !== null ? privateKey : LeapGMCrypto.generatePrivateKey();
    const scalar = bytesToBigInt(privateBytes);
    if (!SM2_CURVE.isValidPrivateKey(scalar)) {
      throw LeapBLEError.cryptoFailure('SM2 临时私钥不在有效区间');
    }
    const selfPublic = SM2_CURVE.multiplyBase(scalar);
    if (selfPublic === null) {
      throw LeapBLEError.cryptoFailure('SM2 公钥推导失败');
    }

    const selfFactor = SM2_CURVE.scalarMod(SM2_CURVE.scalarMod(LeapGMCrypto.xBar(selfPublic.x) * scalar) + scalar);
    const peerFactor = SM2_CURVE.scalarMod(LeapGMCrypto.xBar(peer.x) + 1n);
    const peerCombined = SM2_CURVE.multiply(peerFactor, peer);
    if (peerCombined === null) {
      throw LeapBLEError.cryptoFailure('SM2 对端点乘落在无穷远');
    }
    const agreement = SM2_CURVE.multiply(selfFactor, peerCombined);
    if (agreement === null) {
      throw LeapBLEError.cryptoFailure('SM2 协商点落在无穷远');
    }

    const material = concatBytes([
      bigIntToBytes(agreement.x, 32),
      bigIntToBytes(agreement.y, 32),
      LeapGMCrypto.computeZ(selfPublic),
      LeapGMCrypto.computeZ(peer)
    ]);
    return new LeapGMAgreement(SM2_CURVE.encodeX963(selfPublic), LeapGMCrypto.kdf(material, 32));
  }

  /** x̄ = 2^127 + (x mod 2^127)，即保留低 128 位再把第 127 位置 1。 */
  private static xBar(x: bigint): bigint {
    return (x & ((1n << 128n) - 1n)) | (1n << 127n);
  }

  /** Z = SM3(ENTL ‖ ID ‖ a ‖ b ‖ Gx ‖ Gy ‖ Px ‖ Py)。 */
  private static computeZ(point: AffinePoint): Uint8Array {
    const id = new Uint8Array(SM2_DEFAULT_ID.length);
    for (let index = 0; index < SM2_DEFAULT_ID.length; index++) {
      id[index] = SM2_DEFAULT_ID.charCodeAt(index) & 0xff;
    }
    const entl = id.length * 8;
    return LeapGMCrypto.sm3(concatBytes([
      new Uint8Array([(entl >> 8) & 0xff, entl & 0xff]),
      id,
      bigIntToBytes(SM2_CURVE.a, 32),
      bigIntToBytes(SM2_CURVE.b, 32),
      bigIntToBytes(SM2_CURVE.generator.x, 32),
      bigIntToBytes(SM2_CURVE.generator.y, 32),
      bigIntToBytes(point.x, 32),
      bigIntToBytes(point.y, 32)
    ]));
  }

  /** GB/T 32918.4 的 KDF：计数器从 1 开始，四字节大端跟在素材后面。 */
  private static kdf(material: Uint8Array, length: number): Uint8Array {
    const out = new Uint8Array(length);
    let offset = 0;
    let counter = 1;
    while (offset < length) {
      const suffix = new Uint8Array([
        (counter >>> 24) & 0xff, (counter >>> 16) & 0xff, (counter >>> 8) & 0xff, counter & 0xff
      ]);
      const block = LeapGMCrypto.sm3(concatBytes([material, suffix]));
      const take = Math.min(block.length, length - offset);
      out.set(block.slice(0, take), offset);
      offset += take;
      counter += 1;
    }
    return out;
  }

  /** PEM 去头去尾取 DER；本来就是裸 base64 的原样收下。和 iOS 的 `decodeCertificate` 同规则。 */
  private static decodeCertificate(value: string): Uint8Array {
    const lines = value.split('\n');
    let hasHeader = false;
    for (let index = 0; index < lines.length; index++) {
      if (lines[index].indexOf('BEGIN CERTIFICATE') >= 0) {
        hasHeader = true;
        break;
      }
    }
    let encoded = value;
    if (hasHeader) {
      encoded = '';
      for (let index = 0; index < lines.length; index++) {
        if (!lines[index].startsWith('-----')) {
          encoded += lines[index].trim();
        }
      }
    }
    const der = LeapGMCrypto.base64ToBytes(encoded);
    if (der.length === 0) {
      throw LeapBLEError.invalidCertificate('SM2 X.509 证书不是有效 PEM/Base64');
    }
    return der;
  }

  private static readonly base64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /**
   * 宽松的 base64 解码：不认识的字符直接跳过。
   *
   * 没走 `util.Base64Helper`：证书和签名都是服务端给的，中间常夹换行和空格，
   * 而 `decodeSync` 遇到非字母表字符直接抛，等于把一份完全正常的 PEM 判成坏证书。
   * iOS 那边靠 `.ignoreUnknownCharacters` 达到同样效果。
   */
  static base64ToBytes(text: string): Uint8Array {
    const values: number[] = [];
    let buffer = 0;
    let bits = 0;
    for (let index = 0; index < text.length; index++) {
      const character = text.charAt(index);
      if (character === '=') {
        break;
      }
      const value = LeapGMCrypto.base64Alphabet.indexOf(character);
      if (value < 0) {
        continue;
      }
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        values.push((buffer >> bits) & 0xff);
      }
    }
    return new Uint8Array(values);
  }
}
