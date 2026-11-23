/**
 * DEFLATE (RFC 1951) / GZIP (RFC 1952) 纯 ArkTS 实现（puff 移植）。
 * - qgInflateRaw: 解压任意合法 deflate 流（存储/固定/动态块）
 * - qgGunzip: 解压 gzip（支持多成员），用于黄豆加密响应
 * - qgGzipStored: 构造仅含存储块的 gzip（黄豆请求体，服务端标准 gunzip 可解）
 * 不依赖 @ohos.zlib（其仅支持文件级操作），供网络数据流加解密使用。
 */
import { qgConcat } from './QgBytes';

const MAXBITS: number = 15;

/** 霍夫曼解码表（count 按码长统计，symbol 按码长+符号序排序） */
class QgHuffTable {
  count: number[] = [];
  symbol: number[] = [];

  constructor() {
    for (let i: number = 0; i <= MAXBITS; i++) {
      this.count.push(0);
    }
  }
}

/** 解压状态：输入、输出（自动扩容）、比特缓冲 */
class QgInflateState {
  input: Uint8Array;
  inPos: number;
  out: Uint8Array;
  outLen: number = 0;
  bitBuf: number = 0;
  bitCnt: number = 0;
  maxOut: number = Number.MAX_SAFE_INTEGER;

  constructor(input: Uint8Array, start: number, initCap: number) {
    this.input = input;
    this.inPos = start;
    this.out = new Uint8Array(initCap);
  }

  private grow(extra: number): void {
    let cap: number = this.out.length * 2;
    while (cap < this.outLen + extra) {
      cap *= 2;
    }
    const next: Uint8Array = new Uint8Array(cap);
    next.set(this.out.subarray(0, this.outLen), 0);
    this.out = next;
  }

  put(b: number): void {
    if (this.outLen >= this.maxOut) {
      throw new Error('deflate: 解压输出超出限制');
    }
    if (this.outLen + 1 > this.out.length) {
      this.grow(1);
    }
    this.out[this.outLen++] = b & 0xff;
  }

  ensure(extra: number): void {
    if (this.outLen + extra > this.maxOut) {
      throw new Error('deflate: 解压输出超出限制');
    }
    if (this.outLen + extra > this.out.length) {
      this.grow(extra);
    }
  }
}

/** 读取 need 个比特（LSB 先行） */
function qgBits(s: QgInflateState, need: number): number {
  let val: number = s.bitBuf;
  while (s.bitCnt < need) {
    if (s.inPos >= s.input.length) {
      throw new Error('deflate: 输入意外结束');
    }
    val |= s.input[s.inPos++] << s.bitCnt;
    s.bitCnt += 8;
  }
  s.bitBuf = val >> need;
  s.bitCnt -= need;
  return val & ((1 << need) - 1);
}

/** 规范霍夫曼解码：逐比特累积，按码长升序匹配 */
function qgDecode(s: QgInflateState, h: QgHuffTable): number {
  let code: number = 0;
  let first: number = 0;
  let index: number = 0;
  for (let len: number = 1; len <= MAXBITS; len++) {
    code |= qgBits(s, 1);
    const cnt: number = h.count[len];
    if (code - cnt < first) {
      return h.symbol[index + (code - first)];
    }
    index += cnt;
    first = (first + cnt) << 1;
    code <<= 1;
  }
  throw new Error('deflate: 非法霍夫曼编码');
}

/**
 * 构建解码表。返回 0 表示码空间完整；负数为超订；正数为不完整（欠订）。
 */
function qgConstruct(h: QgHuffTable, lengths: number[], n: number): number {
  for (let len: number = 0; len <= MAXBITS; len++) {
    h.count[len] = 0;
  }
  for (let sym: number = 0; sym < n; sym++) {
    const l: number = lengths[sym];
    if (l < 0 || l > MAXBITS) {
      return -1;
    }
    h.count[l]++;
  }
  if (h.count[0] === n) {
    return 0;
  }
  let left: number = 1;
  for (let len: number = 1; len <= MAXBITS; len++) {
    left <<= 1;
    left -= h.count[len];
    if (left < 0) {
      return left;
    }
  }
  const offs: number[] = new Array(MAXBITS + 2);
  offs[1] = 0;
  for (let len: number = 1; len <= MAXBITS; len++) {
    offs[len + 1] = offs[len] + h.count[len];
  }
  h.symbol = new Array<number>(n);
  for (let sym: number = 0; sym < n; sym++) {
    if (lengths[sym] !== 0) {
      h.symbol[offs[lengths[sym]]++] = sym;
    }
  }
  return left;
}

// 长度码 257..285 的基础长度与附加比特数
const QG_LENS: number[] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const QG_LEXT: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
// 距离码 0..29 的基础距离与附加比特数
const QG_DISTS: number[] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const QG_DEXT: number[] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
// 动态块码长码的读取顺序
const QG_CORDER: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/** 解压字面量/长度-距离序列，直至块结束符 256 */
function qgInflateCodes(s: QgInflateState, lencode: QgHuffTable, distcode: QgHuffTable): void {
  let symbol: number = qgDecode(s, lencode);
  while (symbol !== 256) {
    if (symbol < 256) {
      s.put(symbol);
    } else {
      const lsym: number = symbol - 257;
      if (lsym >= 29) {
        throw new Error('deflate: 非法长度码');
      }
      const len: number = QG_LENS[lsym] + qgBits(s, QG_LEXT[lsym]);
      const dsym: number = qgDecode(s, distcode);
      if (dsym < 0 || dsym >= 30) {
        throw new Error('deflate: 非法距离码');
      }
      const dist: number = QG_DISTS[dsym] + qgBits(s, QG_DEXT[dsym]);
      if (dist > s.outLen) {
        throw new Error('deflate: 距离越过输出起点');
      }
      s.ensure(len);
      let from: number = s.outLen - dist;
      for (let i: number = 0; i < len; i++) {
        s.out[s.outLen++] = s.out[from++];
      }
    }
    symbol = qgDecode(s, lencode);
  }
}

/** 存储块：跳到字节边界，校验 LEN/NLEN，原样拷贝 */
function qgInflateStored(s: QgInflateState): void {
  s.bitBuf = 0;
  s.bitCnt = 0;
  if (s.inPos + 4 > s.input.length) {
    throw new Error('deflate: 存储块头不完整');
  }
  const len: number = s.input[s.inPos] | (s.input[s.inPos + 1] << 8);
  const nlen: number = s.input[s.inPos + 2] | (s.input[s.inPos + 3] << 8);
  s.inPos += 4;
  if ((len ^ 0xffff) !== nlen) {
    throw new Error('deflate: 存储块长度校验失败');
  }
  if (s.inPos + len > s.input.length) {
    throw new Error('deflate: 存储块数据不完整');
  }
  s.ensure(len);
  for (let i: number = 0; i < len; i++) {
    s.out[s.outLen++] = s.input[s.inPos++];
  }
}

/** 固定表缓存（惰性构建） */
let qgFixedLen: QgHuffTable | null = null;
let qgFixedDist: QgHuffTable | null = null;

function qgEnsureFixed(): void {
  if (qgFixedLen !== null && qgFixedDist !== null) {
    return;
  }
  const lens: number[] = new Array<number>(288);
  for (let sym: number = 0; sym < 144; sym++) {
    lens[sym] = 8;
  }
  for (let sym: number = 144; sym < 256; sym++) {
    lens[sym] = 9;
  }
  for (let sym: number = 256; sym < 280; sym++) {
    lens[sym] = 7;
  }
  for (let sym: number = 280; sym < 288; sym++) {
    lens[sym] = 8;
  }
  const lenTable: QgHuffTable = new QgHuffTable();
  qgConstruct(lenTable, lens, 288);
  const dlens: number[] = new Array<number>(30);
  for (let sym: number = 0; sym < 30; sym++) {
    dlens[sym] = 5;
  }
  const distTable: QgHuffTable = new QgHuffTable();
  qgConstruct(distTable, dlens, 30);
  qgFixedLen = lenTable;
  qgFixedDist = distTable;
}

/** 动态块：读取码长表并构建长度/距离解码表 */
function qgInflateDynamic(s: QgInflateState): QgHuffTable[] {
  const nlen: number = qgBits(s, 5) + 257;
  const ndist: number = qgBits(s, 5) + 1;
  const ncode: number = qgBits(s, 4) + 4;
  if (nlen > 286 || ndist > 30) {
    throw new Error('deflate: 动态块计数非法');
  }
  const lengths: number[] = new Array<number>(316);
  for (let i: number = 0; i < 316; i++) {
    lengths[i] = 0;
  }
  for (let i: number = 0; i < ncode; i++) {
    lengths[QG_CORDER[i]] = qgBits(s, 3);
  }
  const clTable: QgHuffTable = new QgHuffTable();
  if (qgConstruct(clTable, lengths, 19) !== 0) {
    throw new Error('deflate: 码长码表非法');
  }
  let index: number = 0;
  while (index < nlen + ndist) {
    const len: number = qgDecode(s, clTable);
    if (len < 16) {
      lengths[index++] = len;
      continue;
    }
    let value: number = 0;
    let repeat: number = 0;
    if (len === 16) {
      if (index === 0) {
        throw new Error('deflate: 无前置码长可复制');
      }
      value = lengths[index - 1];
      repeat = 3 + qgBits(s, 2);
    } else if (len === 17) {
      value = 0;
      repeat = 3 + qgBits(s, 3);
    } else {
      value = 0;
      repeat = 11 + qgBits(s, 7);
    }
    if (index + repeat > nlen + ndist) {
      throw new Error('deflate: 码长重复越界');
    }
    while (repeat > 0) {
      lengths[index++] = value;
      repeat--;
    }
  }
  const lencode: QgHuffTable = new QgHuffTable();
  const err1: number = qgConstruct(lencode, lengths, nlen);
  if (err1 !== 0 && (err1 < 0 || nlen !== lencode.count[0] + lencode.count[1])) {
    throw new Error('deflate: 字长码表非法');
  }
  const distLens: number[] = lengths.slice(nlen, nlen + ndist);
  const distcode: QgHuffTable = new QgHuffTable();
  const err2: number = qgConstruct(distcode, distLens, ndist);
  if (err2 !== 0 && (err2 < 0 || ndist !== distcode.count[0] + distcode.count[1])) {
    throw new Error('deflate: 距离码表非法');
  }
  return [lencode, distcode];
}

/** 逐块解压直至 BFINAL */
function qgInflateBlocks(s: QgInflateState): void {
  let last: number = 0;
  do {
    last = qgBits(s, 1);
    const type: number = qgBits(s, 2);
    if (type === 0) {
      qgInflateStored(s);
    } else if (type === 1) {
      qgEnsureFixed();
      const lenTable: QgHuffTable | null = qgFixedLen;
      const distTable: QgHuffTable | null = qgFixedDist;
      if (lenTable === null || distTable === null) {
        throw new Error('deflate: 固定表未初始化');
      }
      qgInflateCodes(s, lenTable, distTable);
    } else if (type === 2) {
      const tables: QgHuffTable[] = qgInflateDynamic(s);
      qgInflateCodes(s, tables[0], tables[1]);
    } else {
      throw new Error('deflate: 非法块类型 3');
    }
  } while (last === 0);
}

/** 解压 raw deflate 流 */
export function qgInflateRaw(input: Uint8Array, start: number): Uint8Array {
  const s: QgInflateState = new QgInflateState(input, start, 1 << 16);
  qgInflateBlocks(s);
  return s.out.slice(0, s.outLen);
}

/**
 * 解压 gzip。支持多成员；若开头不是 gzip 魔数则原样返回（便于「明文/压缩」两态兼容）。
 * maxBytes > 0 时限制解压总输出，超出抛错（防压缩炸弹）。
 */
export function qgGunzip(input: Uint8Array, maxBytes: number = 0): Uint8Array {
  if (input.length < 2 || input[0] !== 0x1f || input[1] !== 0x8b) {
    return input;
  }
  const outs: Uint8Array[] = [];
  let pos: number = 0;
  let total: number = 0;
  while (pos + 2 <= input.length && input[pos] === 0x1f && input[pos + 1] === 0x8b) {
    if (pos + 10 > input.length) {
      break;
    }
    if (input[pos + 2] !== 8) {
      throw new Error('gzip: 非法压缩方法');
    }
    const flg: number = input[pos + 3];
    let p: number = pos + 10;
    if ((flg & 0x04) !== 0) {
      if (p + 2 > input.length) {
        break;
      }
      const xlen: number = input[p] | (input[p + 1] << 8);
      p += 2 + xlen;
    }
    if ((flg & 0x08) !== 0) {
      while (p < input.length && input[p] !== 0) {
        p++;
      }
      p++;
    }
    if ((flg & 0x10) !== 0) {
      while (p < input.length && input[p] !== 0) {
        p++;
      }
      p++;
    }
    if ((flg & 0x02) !== 0) {
      p += 2;
    }
    if (p > input.length) {
      throw new Error('gzip: 头越界');
    }
    const s: QgInflateState = new QgInflateState(input, p, 1 << 16);
    if (maxBytes > 0) {
      s.maxOut = maxBytes - total;
    }
    qgInflateBlocks(s);
    outs.push(s.out.slice(0, s.outLen));
    total += s.outLen;
    if (maxBytes > 0 && total > maxBytes) {
      throw new Error('gzip: 解压后内容过大');
    }
    // 尾随 8 字节 CRC32+ISIZE（容忍缺失）
    pos = Math.min(s.inPos + 8, input.length);
  }
  if (outs.length === 0) {
    throw new Error('gzip: 无法解析');
  }
  return qgConcat(outs);
}

// ---------------- CRC32（构造 gzip 用） ----------------

let qgCrcTable: number[] | null = null;

function qgCrc32Table(): number[] {
  const cached: number[] | null = qgCrcTable;
  if (cached !== null) {
    return cached;
  }
  const table: number[] = new Array<number>(256);
  for (let n: number = 0; n < 256; n++) {
    let c: number = n;
    for (let k: number = 0; k < 8; k++) {
      c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  qgCrcTable = table;
  return table;
}

/** CRC-32 (IEEE 802.3, 反射) */
export function qgCrc32(data: Uint8Array): number {
  const table: number[] = qgCrc32Table();
  let c: number = 0xffffffff;
  for (let i: number = 0; i < data.length; i++) {
    c = table[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

/**
 * 构造仅含存储（stored）块的 gzip。
 * 黄豆请求体压缩用：合法 gzip、服务端标准 gunzip 可解，无需真实压缩器。
 */
export function qgGzipStored(data: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [];
  parts.push(Uint8Array.from([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]));
  if (data.length === 0) {
    parts.push(Uint8Array.from([0x01, 0x00, 0x00, 0xff, 0xff]));
  } else {
    let offset: number = 0;
    while (offset < data.length) {
      const chunk: number = Math.min(65535, data.length - offset);
      const isFinal: number = offset + chunk >= data.length ? 1 : 0;
      const nlen: number = (~chunk) & 0xffff;
      parts.push(Uint8Array.from([isFinal, chunk & 0xff, (chunk >>> 8) & 0xff,
        nlen & 0xff, (nlen >>> 8) & 0xff]));
      parts.push(data.subarray(offset, offset + chunk));
      offset += chunk;
    }
  }
  const crc: number = qgCrc32(data);
  const isize: number = data.length >>> 0;
  const trailer: Uint8Array = new Uint8Array(8);
  trailer[0] = crc & 0xff;
  trailer[1] = (crc >>> 8) & 0xff;
  trailer[2] = (crc >>> 16) & 0xff;
  trailer[3] = (crc >>> 24) & 0xff;
  trailer[4] = isize & 0xff;
  trailer[5] = (isize >>> 8) & 0xff;
  trailer[6] = (isize >>> 16) & 0xff;
  trailer[7] = (isize >>> 24) & 0xff;
  parts.push(trailer);
  return qgConcat(parts);
}
