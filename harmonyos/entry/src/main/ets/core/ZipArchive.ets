import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { LeapError } from './LeapError';
import { DiagLog } from './DiagLog';

/**
 * 够用就好的 ZIP 解包器。
 *
 * 本来该用系统的 `zlib.decompressFile`，但零跑的车模型包里有一批 GBK 命名的 CSV
 * （`C11_2026_1_0_0_640激光雷达智尊版.csv` 这种），系统接口没有编码开关，解出来
 * 的文件名是一串替换字符，渲染器按正确名字去取就是 404。iOS 那版也栽在这儿，
 * 最后同样是自己解包解决的（`ZipArchive.swift`），这里照着翻一遍。
 *
 * 包本身只用了 Stored 和 DEFLATE，没有加密、没有 ZIP64。`zlib.Zip` 的
 * `inflateInit2` 传负的 windowBits 就是 ZIP 要的 raw DEFLATE，不必引第三方库。
 *
 * 只认标准布局：从尾部找 EOCD → 读中央目录 → 按 local header 定位数据。
 * 遇到不认识的结构就整包失败，交给上层回退 2D，不做半解压。
 */
export class ZipArchive {
  private static readonly eocdSignature: number = 0x06054B50;
  private static readonly centralSignature: number = 0x02014B50;
  private static readonly localSignature: number = 0x04034B50;
  private static readonly eocdMinSize: number = 22;
  /** ZIP 尾注释最长 65535，EOCD 最多藏在这么深。 */
  private static readonly maxComment: number = 65535;
  private static readonly stored: number = 0;
  private static readonly deflated: number = 8;
  /** 负值 = raw DEFLATE，不去找 zlib/gzip 头。 */
  private static readonly rawWindowBits: number = -15;

  /** 解压到 `destination`。目录按需创建，同名文件覆盖。 */
  static async extract(payload: ArrayBuffer, destination: string): Promise<void> {
    const bytes = new Uint8Array(payload);
    const entries = ZipArchive.readCentralDirectory(bytes);
    DiagLog.note(`[zip] ${bytes.length} 字节，${entries.length} 个条目`);
    ZipArchive.makeDirectory(destination);

    for (const entry of entries) {
      const target = ZipArchive.safePath(entry.name, destination);
      if (target === null) {
        throw LeapError.server(`包里有越界路径：${entry.name}`);
      }
      if (entry.name.endsWith('/')) {
        ZipArchive.makeDirectory(target);
        continue;
      }
      ZipArchive.makeDirectory(ZipArchive.parentOf(target));
      const data = await ZipArchive.payloadOf(entry, bytes);
      ZipArchive.write(target, data);
    }
  }

  // MARK: - 结构

  /**
   * 从尾部回扫 EOCD 签名，再顺着中央目录把条目读出来。
   *
   * 文件名先按 UTF-8 严解，解不动才退 GB18030——不看 general purpose 的 UTF-8
   * 标志位：有些打包器压根不设那一位，照着它判会把好名字也判成 GBK。
   */
  private static readCentralDirectory(bytes: Uint8Array): ZipEntry[] {
    if (bytes.length < ZipArchive.eocdMinSize) {
      throw LeapError.server('不是 ZIP：长度不够一个 EOCD');
    }
    const view = new DataView(bytes.buffer);
    const floor = Math.max(0, bytes.length - ZipArchive.eocdMinSize - ZipArchive.maxComment);
    let eocd = -1;
    for (let i = bytes.length - ZipArchive.eocdMinSize; i >= floor; i--) {
      if (view.getUint32(i, true) === ZipArchive.eocdSignature) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw LeapError.server('不是 ZIP：找不到 EOCD');
    }

    const count = view.getUint16(eocd + 10, true);
    let cursor = view.getUint32(eocd + 16, true);
    const entries: ZipEntry[] = [];
    for (let i = 0; i < count; i++) {
      if (cursor + 46 > bytes.length || view.getUint32(cursor, true) !== ZipArchive.centralSignature) {
        throw LeapError.server('中央目录项损坏');
      }
      const nameLength = view.getUint16(cursor + 28, true);
      const nameStart = cursor + 46;
      if (nameStart + nameLength > bytes.length) {
        throw LeapError.server('文件名越界');
      }
      const entry: ZipEntry = {
        name: ZipArchive.decodeName(bytes.slice(nameStart, nameStart + nameLength)),
        method: view.getUint16(cursor + 10, true),
        compressedSize: view.getUint32(cursor + 20, true),
        uncompressedSize: view.getUint32(cursor + 24, true),
        localOffset: view.getUint32(cursor + 42, true)
      };
      if (entry.name.length === 0) {
        throw LeapError.server('文件名无法解码');
      }
      entries.push(entry);
      cursor = nameStart + nameLength
        + view.getUint16(cursor + 30, true)   // extra
        + view.getUint16(cursor + 32, true);  // comment
    }
    return entries;
  }

  private static decodeName(raw: Uint8Array): string {
    try {
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(raw);
    } catch (e) {
      try {
        return util.TextDecoder.create('gb18030').decodeToString(raw);
      } catch (inner) {
        return '';
      }
    }
  }

  /**
   * local header 里的 name/extra 长度可能和中央目录不一样，
   * 定位数据必须以 local 的为准。
   */
  private static async payloadOf(entry: ZipEntry, bytes: Uint8Array): Promise<Uint8Array> {
    const view = new DataView(bytes.buffer);
    const base = entry.localOffset;
    if (base + 30 > bytes.length || view.getUint32(base, true) !== ZipArchive.localSignature) {
      throw LeapError.server(`local header 损坏：${entry.name}`);
    }
    const start = base + 30
      + view.getUint16(base + 26, true)   // name
      + view.getUint16(base + 28, true);  // extra
    const end = start + entry.compressedSize;
    if (end > bytes.length) {
      throw LeapError.server(`数据越界：${entry.name}`);
    }
    const raw = bytes.slice(start, end);
    if (entry.method === ZipArchive.stored) {
      return raw;
    }
    if (entry.method !== ZipArchive.deflated) {
      throw LeapError.server(`不支持的压缩方式 ${entry.method}：${entry.name}`);
    }
    return await ZipArchive.inflate(raw, entry.uncompressedSize, entry.name);
  }

  /**
   * raw DEFLATE 解一个条目。
   *
   * 解压后的大小中央目录里写着，一次把输出缓冲开够，`FINISH` 一把解完，
   * 不用循环喂数据。空文件不必进 zlib——`availableIn` 为 0 时它只会返回 BUF_ERROR。
   */
  private static async inflate(raw: Uint8Array, size: number, name: string): Promise<Uint8Array> {
    if (size === 0) {
      return new Uint8Array(0);
    }
    const zip = zlib.createZipSync();
    // 解出来的数据写回这块，不是从 getZStream 取——那个回来的 ZStream 里
    // nextOut 是空的。这套接口的约定看 uncompress(dest, source)：dest 传进去
    // 由 native 原地填，inflate 的 nextOut 同理。
    const out = new ArrayBuffer(size);
    const stream: zlib.ZStream = {
      nextIn: raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength),
      availableIn: raw.byteLength,
      nextOut: out,
      availableOut: size
    };
    try {
      await zip.inflateInit2(stream, ZipArchive.rawWindowBits);
      const status = await zip.inflate(stream, zlib.CompressFlushMode.FINISH);
      // 一把解完只可能落在 STREAM_END；停在 OK 说明输出缓冲不够，
      // 那就是中央目录写的大小和实际对不上，这包不能要。
      if (status !== zlib.ReturnStatus.STREAM_END) {
        throw LeapError.server(`解压失败（${status}）：${name}`);
      }
      return new Uint8Array(out);
    } finally {
      try {
        await zip.inflateEnd(stream);
      } catch (e) {
        // 已经 END 过或者根本没 init 成功，这里再失败也没什么可做的。
      }
    }
  }

  // MARK: - 落盘

  /** 防 zip slip：拼出来的路径必须还在 destination 底下。 */
  private static safePath(name: string, destination: string): string | null {
    if (name.startsWith('/') || name.indexOf('\\') >= 0) {
      return null;
    }
    const parts = name.split('/');
    const kept: string[] = [];
    for (const part of parts) {
      if (part.length === 0 || part === '.') {
        continue;
      }
      if (part === '..') {
        return null;
      }
      kept.push(part);
    }
    if (kept.length === 0) {
      return null;
    }
    return `${destination}/${kept.join('/')}`;
  }

  private static parentOf(path: string): string {
    const slash = path.lastIndexOf('/');
    return slash > 0 ? path.substring(0, slash) : path;
  }

  private static makeDirectory(path: string): void {
    try {
      fileIo.mkdirSync(path, true);
    } catch (e) {
      // 已经存在就是我们要的结果；真建不出来，后面写文件时会报出来。
    }
  }

  private static write(path: string, data: Uint8Array): void {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    } finally {
      fileIo.closeSync(file);
    }
  }
}

interface ZipEntry {
  name: string;
  method: number;
  compressedSize: number;
  uncompressedSize: number;
  localOffset: number;
}
