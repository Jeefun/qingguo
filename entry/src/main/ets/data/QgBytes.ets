/**
 * 字节工具：UTF-8 编解码 / hex / base64 / 拼接 / 随机字节。
 * 全部基于 Uint8Array 同步实现，供签名与加解密算法使用。
 */

/** UTF-8 编码字符串为字节 */
export function qgUtf8Encode(text: string): Uint8Array {
  const out: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return Uint8Array.from(out);
}

/** UTF-8 解码字节为字符串 */
export function qgUtf8Decode(data: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < data.length) {
    const b0: number = data[i];
    let code: number = 0;
    if (b0 < 0x80) {
      code = b0;
      i += 1;
    } else if ((b0 & 0xe0) === 0xc0) {
      code = ((b0 & 0x1f) << 6) | (data[i + 1] & 0x3f);
      i += 2;
    } else if ((b0 & 0xf0) === 0xe0) {
      code = ((b0 & 0x0f) << 12) | ((data[i + 1] & 0x3f) << 6) | (data[i + 2] & 0x3f);
      i += 3;
    } else {
      code = ((b0 & 0x07) << 18) | ((data[i + 1] & 0x3f) << 12) |
        ((data[i + 2] & 0x3f) << 6) | (data[i + 3] & 0x3f);
      i += 4;
    }
    if (code >= 0x10000) {
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

/** 转 hex 小写 */
export function qgToHex(data: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < data.length; i++) {
    const b: number = data[i];
    out += (b < 16 ? '0' : '') + b.toString(16);
  }
  return out;
}

/** hex 解码（容忍大小写） */
export function qgFromHex(hex: string): Uint8Array {
  const clean: string = hex.trim();
  const out: number[] = [];
  for (let i: number = 0; i + 1 < clean.length; i += 2) {
    const v: number = parseInt(clean.substring(i, i + 2), 16);
    out.push(Number.isNaN(v) ? 0 : v);
  }
  return Uint8Array.from(out);
}

const B64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 标准 base64 编码 */
export function qgBase64Encode(data: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < data.length; i += 3) {
    const b0: number = data[i];
    const b1: number = i + 1 < data.length ? data[i + 1] : 0;
    const b2: number = i + 2 < data.length ? data[i + 2] : 0;
    out += B64_ALPHABET.charAt(b0 >> 2);
    out += B64_ALPHABET.charAt(((b0 & 3) << 4) | (b1 >> 4));
    out += i + 1 < data.length ? B64_ALPHABET.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
    out += i + 2 < data.length ? B64_ALPHABET.charAt(b2 & 63) : '=';
  }
  return out;
}

/** 标准 base64 解码 */
export function qgBase64Decode(text: string): Uint8Array {
  const clean: string = text.replace(/[^A-Za-z0-9+/=]/g, '');
  const out: number[] = [];
  let buffer: number = 0;
  let bits: number = 0;
  for (let i: number = 0; i < clean.length; i++) {
    const ch: string = clean.charAt(i);
    if (ch === '=') {
      break;
    }
    const v: number = B64_ALPHABET.indexOf(ch);
    if (v < 0) {
      continue;
    }
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return Uint8Array.from(out);
}

/** URL 安全 base64 解码（去 padding） */
export function qgBase64UrlDecode(text: string): Uint8Array {
  let patched: string = text.replace(/-/g, '+').replace(/_/g, '/');
  while (patched.length % 4 !== 0) {
    patched += '=';
  }
  return qgBase64Decode(patched);
}

/** 拼接多段字节 */
export function qgConcat(parts: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i: number = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i: number = 0; i < parts.length; i++) {
    out.set(parts[i], offset);
    offset += parts[i].length;
  }
  return out;
}

/** 取子段 */
export function qgSlice(data: Uint8Array, start: number, end: number): Uint8Array {
  const stop: number = Math.min(end, data.length);
  return data.slice(start, stop);
}

/** 随机字节 */
export function qgRandomBytes(n: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(n);
  for (let i: number = 0; i < n; i++) {
    out[i] = Math.floor(Math.random() * 256);
  }
  return out;
}

/** 随机 hex（n 字节 → 2n 字符） */
export function qgRandomHex(n: number): string {
  return qgToHex(qgRandomBytes(n));
}

/** UUID 形态字符串 */
export function qgUuidLike(): string {
  const raw: string = qgRandomHex(16);
  return `${raw.substring(0, 8)}-${raw.substring(8, 12)}-${raw.substring(12, 16)}-${raw.substring(16, 20)}-${raw.substring(20)}`;
}

/** 读小端 64 位无符号数为 BigInt */
export function qgReadLe64(data: Uint8Array, offset: number): bigint {
  let v: bigint = 0n;
  for (let i: number = 7; i >= 0; i--) {
    v = (v << 8n) | BigInt(data[offset + i]);
  }
  return v;
}

/** 写小端 64 位无符号数 */
export function qgWriteLe64(data: Uint8Array, offset: number, value: bigint): void {
  const mask64: bigint = (1n << 64n) - 1n;
  let v: bigint = value & mask64;
  for (let i: number = 0; i < 8; i++) {
    data[offset + i] = Number(v & 0xffn);
    v >>= 8n;
  }
}

/** 32 位左循环移位 */
export function qgRotl32(x: number, n: number): number {
  return ((x << n) | (x >>> (32 - n))) >>> 0;
}

/** 64 位左循环移位（BigInt） */
export function qgRotl64(x: bigint, n: number): bigint {
  const mask64: bigint = (1n << 64n) - 1n;
  return ((x << BigInt(n)) | (x >> BigInt(64 - n))) & mask64;
}

/** 64 位右循环移位（BigInt） */
export function qgRotr64(x: bigint, n: number): bigint {
  return qgRotl64(x, 64 - n);
}

/** 读大端 32 位无符号数 */
export function qgReadBe32(data: Uint8Array, offset: number): number {
  return ((data[offset] << 24) | (data[offset + 1] << 16) |
    (data[offset + 2] << 8) | data[offset + 3]) >>> 0;
}

/** 写大端 32 位无符号数 */
export function qgWriteBe32(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 24) & 0xff;
  data[offset + 1] = (value >>> 16) & 0xff;
  data[offset + 2] = (value >>> 8) & 0xff;
  data[offset + 3] = value & 0xff;
}

/** 读小端 32 位无符号数 */
export function qgReadLe32(data: Uint8Array, offset: number): number {
  return (data[offset] | (data[offset + 1] << 8) |
    (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

/** URL 查询参数编码（与 Go url.Values.Encode 一致：key 排序，RFC3986 转义） */
export function qgBuildQuery(params: Record<string, string>): string {
  const keys: string[] = Object.keys(params).sort();
  const parts: string[] = [];
  for (let i: number = 0; i < keys.length; i++) {
    const key: string = keys[i];
    if (params[key] === undefined) {
      continue;
    }
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`);
  }
  return parts.join('&');
}
