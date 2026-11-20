/**
 * 短 Weierstrass 曲线上的点运算。
 *
 * 立这一层的原因只有一个：蓝牙钥匙的两条证书路径都要在曲线上算点乘，
 * 而 `cryptoFramework` 只肯给成品——SM2 那条它根本没有密钥协商，
 * P-256 那条虽然有 `KeyAgreement`，但要用一把指定的临时私钥去推公钥时
 * 又只能自己算。两条路各写一套只会各错一处，这里统一成一份。
 *
 * 侧信道：标量乘是常规 double-and-add，不是常数时间。乘的都是每次连接
 * 重新生成的临时私钥，且攻击者要贴着手机测功耗才谈得上利用，不值得为它
 * 把代码写成看不懂的样子。
 */

/** 仿射点。曲线上的点对外一律用这个形状，投影坐标只活在标量乘内部。 */
export class AffinePoint {
  readonly x: bigint;
  readonly y: bigint;

  constructor(x: bigint, y: bigint) {
    this.x = x;
    this.y = y;
  }
}

/**
 * 雅可比投影点：仿射坐标是 (x/z², y/z³)，z = 0 表示无穷远。
 *
 * 不用投影坐标的话，每做一次点加都要求一次模逆，一次 256 位标量乘就是
 * 三百多次模逆，手机上要跑到秒级。这里把模逆推迟到最后一次。
 */
class JacobianPoint {
  x: bigint;
  y: bigint;
  z: bigint;

  constructor(x: bigint, y: bigint, z: bigint) {
    this.x = x;
    this.y = y;
    this.z = z;
  }

  get isInfinity(): boolean {
    return this.z === 0n;
  }
}

export function bytesToBigInt(bytes: Uint8Array): bigint {
  let value = 0n;
  for (let index = 0; index < bytes.length; index++) {
    value = (value << 8n) | BigInt(bytes[index]);
  }
  return value;
}

export function bigIntToBytes(value: bigint, length: number): Uint8Array {
  const out = new Uint8Array(length);
  let remaining = value;
  for (let index = length - 1; index >= 0; index--) {
    out[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  return out;
}

export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (let index = 0; index < parts.length; index++) {
    total += parts[index].length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (let index = 0; index < parts.length; index++) {
    out.set(parts[index], offset);
    offset += parts[index].length;
  }
  return out;
}

export class EllipticCurve {
  readonly p: bigint;
  readonly a: bigint;
  readonly b: bigint;
  readonly n: bigint;
  readonly generator: AffinePoint;

  constructor(p: bigint, a: bigint, b: bigint, n: bigint, gx: bigint, gy: bigint) {
    this.p = p;
    this.a = a;
    this.b = b;
    this.n = n;
    this.generator = new AffinePoint(gx, gy);
  }

  /** sm2p256v1（GB/T 32918.5）。 */
  static readonly sm2p256v1: EllipticCurve = new EllipticCurve(
    0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFFn,
    0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFCn,
    0x28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93n,
    0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123n,
    0x32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7n,
    0xBC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0n
  );

  /** NIST P-256 / secp256r1。老款蓝牙证书（keyType=0）走它。 */
  static readonly p256: EllipticCurve = new EllipticCurve(
    0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFn,
    0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFCn,
    0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604Bn,
    0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551n,
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296n,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5n
  );

  fieldMod(value: bigint): bigint {
    const result = value % this.p;
    return result < 0n ? result + this.p : result;
  }

  scalarMod(value: bigint): bigint {
    const result = value % this.n;
    return result < 0n ? result + this.n : result;
  }

  /** 模逆，走费马小定理。p 是素数，这条路比扩展欧几里得短且不用处理符号。 */
  private fieldInverse(value: bigint): bigint {
    return EllipticCurve.modPow(value, this.p - 2n, this.p);
  }

  /** 模幂。bigint 的 `**` 不带模，自己做平方-乘。 */
  private static modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
    let result = 1n;
    let factor = base % modulus;
    if (factor < 0n) {
      factor += modulus;
    }
    let remaining = exponent;
    while (remaining > 0n) {
      if ((remaining & 1n) === 1n) {
        result = (result * factor) % modulus;
      }
      factor = (factor * factor) % modulus;
      remaining >>= 1n;
    }
    return result;
  }

  private double(point: JacobianPoint): JacobianPoint {
    if (point.isInfinity || point.y === 0n) {
      return new JacobianPoint(1n, 1n, 0n);
    }
    // 两条曲线的 a 都等于 p - 3，所以 3(X - Z²)(X + Z²) 就是 3X² + aZ⁴，省两次平方。
    const zz = this.fieldMod(point.z * point.z);
    const yy = this.fieldMod(point.y * point.y);
    const yyyy = this.fieldMod(yy * yy);
    const s = this.fieldMod(2n * (this.fieldMod((point.x + yy) * (point.x + yy))
      - this.fieldMod(point.x * point.x) - yyyy));
    const m = this.fieldMod(3n * this.fieldMod((point.x - zz) * (point.x + zz)));
    const x3 = this.fieldMod(m * m - 2n * s);
    const y3 = this.fieldMod(m * (s - x3) - 8n * yyyy);
    const z3 = this.fieldMod(2n * point.y * point.z);
    return new JacobianPoint(x3, y3, z3);
  }

  private add(lhs: JacobianPoint, rhs: JacobianPoint): JacobianPoint {
    if (lhs.isInfinity) {
      return rhs;
    }
    if (rhs.isInfinity) {
      return lhs;
    }
    const z1z1 = this.fieldMod(lhs.z * lhs.z);
    const z2z2 = this.fieldMod(rhs.z * rhs.z);
    const u1 = this.fieldMod(lhs.x * z2z2);
    const u2 = this.fieldMod(rhs.x * z1z1);
    const s1 = this.fieldMod(lhs.y * rhs.z * z2z2);
    const s2 = this.fieldMod(rhs.y * lhs.z * z1z1);
    const h = this.fieldMod(u2 - u1);
    const r = this.fieldMod(2n * (s2 - s1));
    if (h === 0n) {
      // 同一个点：走倍点公式；互为相反数：结果是无穷远。
      return r === 0n ? this.double(lhs) : new JacobianPoint(1n, 1n, 0n);
    }
    const i = this.fieldMod(4n * h * h);
    const j = this.fieldMod(h * i);
    const v = this.fieldMod(u1 * i);
    const x3 = this.fieldMod(r * r - j - 2n * v);
    const y3 = this.fieldMod(r * (v - x3) - 2n * s1 * j);
    const z3 = this.fieldMod(this.fieldMod((lhs.z + rhs.z) * (lhs.z + rhs.z) - z1z1 - z2z2) * h);
    return new JacobianPoint(x3, y3, z3);
  }

  /** 标量乘。落到无穷远返回 null——调用方一律当失败处理，没有「就当没算」这种选项。 */
  multiply(scalar: bigint, point: AffinePoint): AffinePoint | null {
    if (scalar <= 0n) {
      return null;
    }
    let accumulator = new JacobianPoint(1n, 1n, 0n);
    const base = new JacobianPoint(point.x, point.y, 1n);
    let bitLength = 0;
    let bits = scalar;
    while (bits > 0n) {
      bitLength += 1;
      bits >>= 1n;
    }
    for (let index = bitLength - 1; index >= 0; index--) {
      accumulator = this.double(accumulator);
      if (((scalar >> BigInt(index)) & 1n) === 1n) {
        accumulator = this.add(accumulator, base);
      }
    }
    if (accumulator.isInfinity) {
      return null;
    }
    const zInverse = this.fieldInverse(accumulator.z);
    const zInverse2 = this.fieldMod(zInverse * zInverse);
    const zInverse3 = this.fieldMod(zInverse2 * zInverse);
    return new AffinePoint(
      this.fieldMod(accumulator.x * zInverse2),
      this.fieldMod(accumulator.y * zInverse3)
    );
  }

  multiplyBase(scalar: bigint): AffinePoint | null {
    return this.multiply(scalar, this.generator);
  }

  /** y² == x³ + ax + b，且坐标在域内。外面递进来的公钥先过这一关。 */
  isOnCurve(point: AffinePoint): boolean {
    if (point.x < 0n || point.x >= this.p || point.y < 0n || point.y >= this.p) {
      return false;
    }
    const left = this.fieldMod(point.y * point.y);
    const right = this.fieldMod(this.fieldMod(point.x * point.x * point.x)
      + this.fieldMod(this.a * point.x) + this.b);
    return left === right;
  }

  /** 65 字节未压缩点（X9.63）→ 仿射点。格式或曲线不对返回 null。 */
  decodeX963(bytes: Uint8Array): AffinePoint | null {
    if (bytes.length !== 65 || bytes[0] !== 0x04) {
      return null;
    }
    const point = new AffinePoint(
      bytesToBigInt(bytes.slice(1, 33)),
      bytesToBigInt(bytes.slice(33, 65))
    );
    return this.isOnCurve(point) ? point : null;
  }

  encodeX963(point: AffinePoint): Uint8Array {
    return concatBytes([new Uint8Array([0x04]), bigIntToBytes(point.x, 32), bigIntToBytes(point.y, 32)]);
  }

  /** 私钥必须落在 [1, n)，否则推出来的公钥是废的。 */
  isValidPrivateKey(scalar: bigint): boolean {
    return scalar > 0n && scalar < this.n;
  }
}
