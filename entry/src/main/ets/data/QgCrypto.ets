/**
 * 纯 ArkTS 加密基础库：MD5 / SHA-256 / HMAC-SHA256 / SM3 / AES-CBC。
 * 输出与 Node crypto / Go crypto 逐字节一致（已用红果签名链路交叉验证）。
 * 全部同步实现：签名算法内嵌多次哈希，不能依赖异步 cryptoFramework。
 */
import { qgConcat, qgRotl32, qgUtf8Encode } from './QgBytes';

// ---------------- MD5 ----------------

const MD5_S: number[] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
const MD5_K: number[] = [0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1,
  0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
  0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6,
  0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60,
  0xbebfbc70, 0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5,
  0x1fa27cf8, 0xc4ac5665, 0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3,
  0x8f0ccc92, 0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391];

/** MD5 摘要（16 字节） */
export function qgMd5(input: Uint8Array): Uint8Array {
  const bitLen: bigint = BigInt(input.length) * 8n;
  const parts: Uint8Array[] = [input, Uint8Array.from([0x80])];
  let total: number = input.length + 1;
  while (total % 64 !== 56) {
    parts.push(Uint8Array.from([0]));
    total++;
  }
  const lenBytes: Uint8Array = new Uint8Array(8);
  for (let i: number = 0; i < 8; i++) {
    lenBytes[i] = Number((bitLen >> BigInt(i * 8)) & 0xffn);
  }
  parts.push(lenBytes);
  const data: Uint8Array = qgConcat(parts);

  let a0: number = 0x67452301;
  let b0: number = 0xefcdab89;
  let c0: number = 0x98badcfe;
  let d0: number = 0x10325476;
  const m: number[] = new Array(16);
  for (let chunk: number = 0; chunk < data.length; chunk += 64) {
    for (let i: number = 0; i < 16; i++) {
      const o: number = chunk + i * 4;
      m[i] = (data[o] | (data[o + 1] << 8) | (data[o + 2] << 16) | (data[o + 3] << 24)) >>> 0;
    }
    let aa: number = a0;
    let bb: number = b0;
    let cc: number = c0;
    let dd: number = d0;
    for (let i: number = 0; i < 64; i++) {
      let f: number = 0;
      let g: number = 0;
      if (i < 16) {
        f = (bb & cc) | (~bb & dd);
        g = i;
      } else if (i < 32) {
        f = (dd & bb) | (~dd & cc);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = bb ^ cc ^ dd;
        g = (3 * i + 5) % 16;
      } else {
        f = cc ^ (bb | ~dd);
        g = (7 * i) % 16;
      }
      f = (f + aa + MD5_K[i] + m[g]) >>> 0;
      aa = dd;
      dd = cc;
      cc = bb;
      bb = (bb + qgRotl32(f, MD5_S[i])) >>> 0;
    }
    a0 = (a0 + aa) >>> 0;
    b0 = (b0 + bb) >>> 0;
    c0 = (c0 + cc) >>> 0;
    d0 = (d0 + dd) >>> 0;
  }
  const out: Uint8Array = new Uint8Array(16);
  for (let i: number = 0; i < 4; i++) {
    out[i] = (a0 >>> (i * 8)) & 0xff;
    out[4 + i] = (b0 >>> (i * 8)) & 0xff;
    out[8 + i] = (c0 >>> (i * 8)) & 0xff;
    out[12 + i] = (d0 >>> (i * 8)) & 0xff;
  }
  return out;
}

/** MD5 字符串 */
export function qgMd5Hex(text: string): string {
  const bytes: Uint8Array = qgMd5(qgUtf8Encode(text));
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  }
  return out;
}

// ---------------- SHA-256 ----------------

const SHA256_K: number[] = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
  0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6,
  0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d,
  0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
  0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585,
  0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa,
  0xa4506ceb, 0xbef9a3f7, 0xc67178f2];

function rotr32(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** SHA-256 摘要（32 字节） */
export function qgSha256(input: Uint8Array): Uint8Array {
  const bitLenHi: number = Math.floor(input.length / 0x20000000);
  const bitLenLo: number = (input.length << 3) >>> 0;
  const parts: Uint8Array[] = [input, Uint8Array.from([0x80])];
  let total: number = input.length + 1;
  while (total % 64 !== 56) {
    parts.push(Uint8Array.from([0]));
    total++;
  }
  const lenBytes: Uint8Array = new Uint8Array(8);
  lenBytes[0] = (bitLenHi >>> 24) & 0xff;
  lenBytes[1] = (bitLenHi >>> 16) & 0xff;
  lenBytes[2] = (bitLenHi >>> 8) & 0xff;
  lenBytes[3] = bitLenHi & 0xff;
  lenBytes[4] = (bitLenLo >>> 24) & 0xff;
  lenBytes[5] = (bitLenLo >>> 16) & 0xff;
  lenBytes[6] = (bitLenLo >>> 8) & 0xff;
  lenBytes[7] = bitLenLo & 0xff;
  parts.push(lenBytes);
  const data: Uint8Array = qgConcat(parts);

  const h: number[] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const w: number[] = new Array(64);
  for (let chunk: number = 0; chunk < data.length; chunk += 64) {
    for (let i: number = 0; i < 16; i++) {
      const o: number = chunk + i * 4;
      w[i] = ((data[o] << 24) | (data[o + 1] << 16) | (data[o + 2] << 8) | data[o + 3]) >>> 0;
    }
    for (let i: number = 16; i < 64; i++) {
      const s0: number = (rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3)) >>> 0;
      const s1: number = (rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a: number = h[0];
    let b: number = h[1];
    let c: number = h[2];
    let d: number = h[3];
    let e: number = h[4];
    let f: number = h[5];
    let g: number = h[6];
    let hh: number = h[7];
    for (let i: number = 0; i < 64; i++) {
      const s1: number = (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) >>> 0;
      const ch: number = (e & f) ^ (~e & g);
      const t1: number = (hh + s1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const s0: number = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) >>> 0;
      const maj: number = (a & b) ^ (a & c) ^ (b & c);
      const t2: number = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  const out: Uint8Array = new Uint8Array(32);
  for (let i: number = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xff;
    out[i * 4 + 3] = h[i] & 0xff;
  }
  return out;
}

/** HMAC-SHA256（32 字节） */
export function qgHmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
  let k: Uint8Array = key;
  if (k.length > 64) {
    k = qgSha256(k);
  }
  const ipad: Uint8Array = new Uint8Array(64);
  const opad: Uint8Array = new Uint8Array(64);
  for (let i: number = 0; i < 64; i++) {
    const kb: number = i < k.length ? k[i] : 0;
    ipad[i] = kb ^ 0x36;
    opad[i] = kb ^ 0x5c;
  }
  return qgSha256(qgConcat([opad, qgSha256(qgConcat([ipad, message]))]));
}

// ---------------- SHA-512 ----------------

const SHA512_K: bigint[] = [0x428a2f98d728ae22n, 0x7137449123ef65cdn, 0xb5c0fbcfec4d3b2fn, 0xe9b5dba58189dbbcn,
  0x3956c25bf348b538n, 0x59f111f1b605d019n, 0x923f82a4af194f9bn, 0xab1c5ed5da6d8118n,
  0xd807aa98a3030242n, 0x12835b0145706fben, 0x243185be4ee4b28cn, 0x550c7dc3d5ffb4e2n,
  0x72be5d74f27b896fn, 0x80deb1fe3b1696b1n, 0x9bdc06a725c71235n, 0xc19bf174cf692694n,
  0xe49b69c19ef14ad2n, 0xefbe4786384f25e3n, 0x0fc19dc68b8cd5b5n, 0x240ca1cc77ac9c65n,
  0x2de92c6f592b0275n, 0x4a7484aa6ea6e483n, 0x5cb0a9dcbd41fbd4n, 0x76f988da831153b5n,
  0x983e5152ee66dfabn, 0xa831c66d2db43210n, 0xb00327c898fb213fn, 0xbf597fc7beef0ee4n,
  0xc6e00bf33da88fc2n, 0xd5a79147930aa725n, 0x06ca6351e003826fn, 0x142929670a0e6e70n,
  0x27b70a8546d22ffcn, 0x2e1b21385c26c926n, 0x4d2c6dfc5ac42aedn, 0x53380d139d95b3dfn,
  0x650a73548baf63den, 0x766a0abb3c77b2a8n, 0x81c2c92e47edaee6n, 0x92722c851482353bn,
  0xa2bfe8a14cf10364n, 0xa81a664bbc423001n, 0xc24b8b70d0f89791n, 0xc76c51a30654be30n,
  0xd192e819d6ef5218n, 0xd69906245565a910n, 0xf40e35855771202an, 0x106aa07032bbd1b8n,
  0x19a4c116b8d2d0c8n, 0x1e376c085141ab53n, 0x2748774cdf8eeb99n, 0x34b0bcb5e19b48a8n,
  0x391c0cb3c5c95a63n, 0x4ed8aa4ae3418acbn, 0x5b9cca4f7763e373n, 0x682e6ff3d6b2b8a3n,
  0x748f82ee5defb2fcn, 0x78a5636f43172f60n, 0x84c87814a1f0ab72n, 0x8cc702081a6439ecn,
  0x90befffa23631e28n, 0xa4506cebde82bde9n, 0xbef9a3f7b2c67915n, 0xc67178f2e372532bn,
  0xca273eceea26619cn, 0xd186b8c721c0c207n, 0xeada7dd6cde0eb1en, 0xf57d4f7fee6ed178n,
  0x06f067aa72176fban, 0x0a637dc5a2c898a6n, 0x113f9804bef90daen, 0x1b710b35131c471bn,
  0x28db77f523047d84n, 0x32caab7b40c72493n, 0x3c9ebe0a15c9bebcn, 0x431d67c49c100d4cn,
  0x4cc5d4becb3e42b6n, 0x597f299cfc657e2an, 0x5fcb6fab3ad6faecn, 0x6c44198c4a475817n];

const SHA512_MASK: bigint = 0xffffffffffffffffn;

function rotr64(x: bigint, n: number): bigint {
  return ((x >> BigInt(n)) | (x << BigInt(64 - n))) & SHA512_MASK;
}

/** SHA-512 摘要（64 字节） */
export function qgSha512(input: Uint8Array): Uint8Array {
  const bitLength: bigint = BigInt(input.length) * 8n;
  const parts: Uint8Array[] = [input, Uint8Array.from([0x80])];
  let total: number = input.length + 1;
  while (total % 128 !== 112) {
    parts.push(Uint8Array.from([0]));
    total++;
  }
  const lenBytes: Uint8Array = new Uint8Array(16);
  let remaining: bigint = bitLength;
  for (let i: number = 15; i >= 0; i--) {
    lenBytes[i] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  parts.push(lenBytes);
  const data: Uint8Array = qgConcat(parts);

  const h: bigint[] = [0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
    0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n];
  const w: bigint[] = new Array(80);
  for (let chunk: number = 0; chunk < data.length; chunk += 128) {
    for (let i: number = 0; i < 16; i++) {
      const o: number = chunk + i * 8;
      w[i] = (BigInt(data[o]) << 56n) | (BigInt(data[o + 1]) << 48n) | (BigInt(data[o + 2]) << 40n) |
        (BigInt(data[o + 3]) << 32n) | (BigInt(data[o + 4]) << 24n) | (BigInt(data[o + 5]) << 16n) |
        (BigInt(data[o + 6]) << 8n) | BigInt(data[o + 7]);
    }
    for (let i: number = 16; i < 80; i++) {
      const s0: bigint = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7n);
      const s1: bigint = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6n);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & SHA512_MASK;
    }
    let a: bigint = h[0];
    let b: bigint = h[1];
    let c: bigint = h[2];
    let d: bigint = h[3];
    let e: bigint = h[4];
    let f: bigint = h[5];
    let g: bigint = h[6];
    let hh: bigint = h[7];
    for (let i: number = 0; i < 80; i++) {
      const s1: bigint = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
      const ch: bigint = (e & f) ^ (~e & g);
      const t1: bigint = (hh + s1 + ch + SHA512_K[i] + w[i]) & SHA512_MASK;
      const s0: bigint = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
      const maj: bigint = (a & b) ^ (a & c) ^ (b & c);
      const t2: bigint = (s0 + maj) & SHA512_MASK;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & SHA512_MASK;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & SHA512_MASK;
    }
    h[0] = (h[0] + a) & SHA512_MASK;
    h[1] = (h[1] + b) & SHA512_MASK;
    h[2] = (h[2] + c) & SHA512_MASK;
    h[3] = (h[3] + d) & SHA512_MASK;
    h[4] = (h[4] + e) & SHA512_MASK;
    h[5] = (h[5] + f) & SHA512_MASK;
    h[6] = (h[6] + g) & SHA512_MASK;
    h[7] = (h[7] + hh) & SHA512_MASK;
  }
  const out: Uint8Array = new Uint8Array(64);
  for (let i: number = 0; i < 8; i++) {
    for (let j: number = 0; j < 8; j++) {
      out[i * 8 + j] = Number((h[i] >> BigInt(56 - j * 8)) & 0xffn);
    }
  }
  return out;
}

// ---------------- SM3 ----------------

/** SM3 密码杂凑摘要（32 字节），国密标准 GB/T 32905-2016 */
export function qgSm3(input: Uint8Array): Uint8Array {
  const len: bigint = BigInt(input.length) * 8n;
  const parts: Uint8Array[] = [input, Uint8Array.from([0x80])];
  let total: number = input.length + 1;
  while (total % 64 !== 56) {
    parts.push(Uint8Array.from([0]));
    total++;
  }
  const lenBytes: Uint8Array = new Uint8Array(8);
  for (let i: number = 0; i < 8; i++) {
    lenBytes[i] = Number((len >> BigInt(56 - i * 8)) & 0xffn);
  }
  parts.push(lenBytes);
  const data: Uint8Array = qgConcat(parts);

  const state: number[] = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
    0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e];
  const w: number[] = new Array(68);
  for (let off: number = 0; off < data.length; off += 64) {
    for (let i: number = 0; i < 16; i++) {
      const o: number = off + i * 4;
      w[i] = ((data[o] << 24) | (data[o + 1] << 16) | (data[o + 2] << 8) | data[o + 3]) >>> 0;
    }
    for (let i: number = 16; i < 68; i++) {
      const v: number = (w[i - 16] ^ w[i - 9] ^ qgRotl32(w[i - 3], 15)) >>> 0;
      w[i] = (v ^ qgRotl32(v, 15) ^ qgRotl32(v, 23) ^ qgRotl32(w[i - 13], 7) ^ w[i - 6]) >>> 0;
    }
    let a: number = state[0];
    let b: number = state[1];
    let c: number = state[2];
    let d: number = state[3];
    let e: number = state[4];
    let f: number = state[5];
    let g: number = state[6];
    let h: number = state[7];
    for (let i: number = 0; i < 64; i++) {
      let t: number = 0x79cc4519;
      let ff: number = (a ^ b ^ c) >>> 0;
      let gg: number = (e ^ f ^ g) >>> 0;
      if (i >= 16) {
        t = 0x7a879d8a;
        ff = ((a & b) | (a & c) | (b & c)) >>> 0;
        gg = ((e & f) | (~e & g)) >>> 0;
      }
      const rotT: number = qgRotl32(t, i % 32);
      const rotA12: number = qgRotl32(a, 12);
      const ss1: number = qgRotl32((rotA12 + e + rotT) >>> 0, 7);
      const ss2: number = (ss1 ^ rotA12) >>> 0;
      const tt1: number = (ff + d + ss2 + (w[i] ^ w[i + 4])) >>> 0;
      const tt2: number = (gg + h + ss1 + w[i]) >>> 0;
      d = c;
      c = qgRotl32(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = qgRotl32(f, 19);
      f = e;
      e = (tt2 ^ qgRotl32(tt2, 9) ^ qgRotl32(tt2, 17)) >>> 0;
    }
    state[0] = (state[0] ^ a) >>> 0;
    state[1] = (state[1] ^ b) >>> 0;
    state[2] = (state[2] ^ c) >>> 0;
    state[3] = (state[3] ^ d) >>> 0;
    state[4] = (state[4] ^ e) >>> 0;
    state[5] = (state[5] ^ f) >>> 0;
    state[6] = (state[6] ^ g) >>> 0;
    state[7] = (state[7] ^ h) >>> 0;
  }
  const out: Uint8Array = new Uint8Array(32);
  for (let i: number = 0; i < 8; i++) {
    out[i * 4] = (state[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (state[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (state[i] >>> 8) & 0xff;
    out[i * 4 + 3] = state[i] & 0xff;
  }
  return out;
}

// ---------------- AES-CBC ----------------

const AES_SBOX: number[] = [0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67,
  0x2b, 0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4,
  0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34,
  0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a,
  0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a,
  0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc,
  0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb, 0x43,
  0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f,
  0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13,
  0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73, 0x60, 0x81,
  0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb, 0xe0,
  0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae,
  0x08, 0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd,
  0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86,
  0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9,
  0xce, 0x55, 0x28, 0xdf, 0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d,
  0x0f, 0xb0, 0x54, 0xbb, 0x16];
const AES_RCON: number[] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

function xtime(x: number): number {
  return ((x << 1) ^ ((x & 0x80) !== 0 ? 0x1b : 0)) & 0xff;
}

/** AES 轮密钥扩展 */
function aesExpandKey(key: Uint8Array): Uint8Array[] {
  const nk: number = key.length / 4;
  const rounds: number = nk + 6;
  const words: Uint8Array[] = [];
  for (let i: number = 0; i < nk; i++) {
    words.push(Uint8Array.from([key[i * 4], key[i * 4 + 1], key[i * 4 + 2], key[i * 4 + 3]]));
  }
  for (let i: number = nk; i < 4 * (rounds + 1); i++) {
    const prev: Uint8Array = words[i - 1];
    let temp: Uint8Array = Uint8Array.from([prev[0], prev[1], prev[2], prev[3]]);
    if (i % nk === 0) {
      temp = Uint8Array.from([AES_SBOX[temp[1]], AES_SBOX[temp[2]], AES_SBOX[temp[3]], AES_SBOX[temp[0]]]);
      temp[0] ^= AES_RCON[i / nk - 1];
    } else if (nk > 6 && i % nk === 4) {
      temp = Uint8Array.from([AES_SBOX[temp[0]], AES_SBOX[temp[1]], AES_SBOX[temp[2]], AES_SBOX[temp[3]]]);
    }
    const src: Uint8Array = words[i - nk];
    words.push(Uint8Array.from([(src[0] ^ temp[0]) & 0xff, (src[1] ^ temp[1]) & 0xff,
      (src[2] ^ temp[2]) & 0xff, (src[3] ^ temp[3]) & 0xff]));
  }
  const roundKeys: Uint8Array[] = [];
  for (let r: number = 0; r <= rounds; r++) {
    const rk: Uint8Array = new Uint8Array(16);
    for (let c: number = 0; c < 4; c++) {
      const w: Uint8Array = words[r * 4 + c];
      rk[c * 4] = w[0];
      rk[c * 4 + 1] = w[1];
      rk[c * 4 + 2] = w[2];
      rk[c * 4 + 3] = w[3];
    }
    roundKeys.push(rk);
  }
  return roundKeys;
}

function aesEncryptBlock(roundKeys: Uint8Array[], block: Uint8Array, out: Uint8Array): void {
  const s: Uint8Array = new Uint8Array(16);
  const t: Uint8Array = new Uint8Array(16);
  for (let i: number = 0; i < 16; i++) {
    s[i] = (block[i] ^ roundKeys[0][i]) & 0xff;
  }
  const rounds: number = roundKeys.length - 1;
  for (let r: number = 1; r <= rounds; r++) {
    for (let i: number = 0; i < 16; i++) {
      t[i] = AES_SBOX[s[i]];
    }
    if (r < rounds) {
      // ShiftRows + MixColumns
      for (let c: number = 0; c < 4; c++) {
        const r0: number = t[c * 4];
        const r1: number = t[((c + 1) % 4) * 4 + 1];
        const r2: number = t[((c + 2) % 4) * 4 + 2];
        const r3: number = t[((c + 3) % 4) * 4 + 3];
        s[c * 4] = (xtime(r0) ^ (xtime(r1) ^ r1) ^ r2 ^ r3) & 0xff;
        s[c * 4 + 1] = (r0 ^ xtime(r1) ^ (xtime(r2) ^ r2) ^ r3) & 0xff;
        s[c * 4 + 2] = (r0 ^ r1 ^ xtime(r2) ^ (xtime(r3) ^ r3)) & 0xff;
        s[c * 4 + 3] = ((xtime(r0) ^ r0) ^ r1 ^ r2 ^ xtime(r3)) & 0xff;
      }
    } else {
      // 最后一轮仅 ShiftRows
      for (let c: number = 0; c < 4; c++) {
        s[c * 4] = t[c * 4];
        s[c * 4 + 1] = t[((c + 1) % 4) * 4 + 1];
        s[c * 4 + 2] = t[((c + 2) % 4) * 4 + 2];
        s[c * 4 + 3] = t[((c + 3) % 4) * 4 + 3];
      }
    }
    for (let i: number = 0; i < 16; i++) {
      s[i] = (s[i] ^ roundKeys[r][i]) & 0xff;
    }
  }
  for (let i: number = 0; i < 16; i++) {
    out[i] = s[i];
  }
}

function aesDecryptBlock(roundKeys: Uint8Array[], block: Uint8Array, out: Uint8Array): void {
  const rounds: number = roundKeys.length - 1;
  const s: Uint8Array = new Uint8Array(16);
  const t: Uint8Array = new Uint8Array(16);
  for (let i: number = 0; i < 16; i++) {
    s[i] = (block[i] ^ roundKeys[rounds][i]) & 0xff;
  }
  for (let r: number = rounds - 1; r >= 0; r--) {
    // InvShiftRows
    for (let c: number = 0; c < 4; c++) {
      t[c * 4] = s[c * 4];
      t[c * 4 + 1] = s[((c + 3) % 4) * 4 + 1];
      t[c * 4 + 2] = s[((c + 2) % 4) * 4 + 2];
      t[c * 4 + 3] = s[((c + 1) % 4) * 4 + 3];
    }
    // InvSubBytes
    for (let i: number = 0; i < 16; i++) {
      t[i] = AES_INV_SBOX[t[i]];
    }
    // AddRoundKey
    for (let i: number = 0; i < 16; i++) {
      t[i] = (t[i] ^ roundKeys[r][i]) & 0xff;
    }
    if (r > 0) {
      // InvMixColumns
      for (let c: number = 0; c < 4; c++) {
        const r0: number = t[c * 4];
        const r1: number = t[c * 4 + 1];
        const r2: number = t[c * 4 + 2];
        const r3: number = t[c * 4 + 3];
        s[c * 4] = (mul(r0, 14) ^ mul(r1, 11) ^ mul(r2, 13) ^ mul(r3, 9)) & 0xff;
        s[c * 4 + 1] = (mul(r0, 9) ^ mul(r1, 14) ^ mul(r2, 11) ^ mul(r3, 13)) & 0xff;
        s[c * 4 + 2] = (mul(r0, 13) ^ mul(r1, 9) ^ mul(r2, 14) ^ mul(r3, 11)) & 0xff;
        s[c * 4 + 3] = (mul(r0, 11) ^ mul(r1, 13) ^ mul(r2, 9) ^ mul(r3, 14)) & 0xff;
      }
    } else {
      for (let i: number = 0; i < 16; i++) {
        s[i] = t[i];
      }
    }
  }
  for (let i: number = 0; i < 16; i++) {
    out[i] = s[i];
  }
}

const AES_INV_SBOX: number[] = buildInvSbox();

function buildInvSbox(): number[] {
  const inv: number[] = new Array(256);
  for (let i: number = 0; i < 256; i++) {
    inv[AES_SBOX[i]] = i;
  }
  return inv;
}

function mul(a: number, b: number): number {
  let result: number = 0;
  let x: number = a;
  let y: number = b;
  while (y !== 0) {
    if ((y & 1) !== 0) {
      result ^= x;
    }
    x = xtime(x);
    y >>= 1;
  }
  return result & 0xff;
}

/** PKCS7 填充到 16 字节块 */
export function qgPkcs7Pad(data: Uint8Array): Uint8Array {
  const p: number = 16 - (data.length % 16);
  const out: Uint8Array = new Uint8Array(data.length + p);
  out.set(data, 0);
  for (let i: number = 0; i < p; i++) {
    out[data.length + i] = p;
  }
  return out;
}

/** PKCS7 去填充 */
export function qgPkcs7Unpad(data: Uint8Array): Uint8Array {
  if (data.length === 0 || data.length % 16 !== 0) {
    return data;
  }
  const p: number = data[data.length - 1];
  if (p < 1 || p > 16 || p > data.length) {
    return data;
  }
  for (let i: number = data.length - p; i < data.length; i++) {
    if (data[i] !== p) {
      return data;
    }
  }
  return data.slice(0, data.length - p);
}

/** AES-CBC 加密（PKCS7 填充），key 为 16/32 字节 */
export function qgAesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  const roundKeys: Uint8Array[] = aesExpandKey(key);
  const padded: Uint8Array = qgPkcs7Pad(plain);
  const out: Uint8Array = new Uint8Array(padded.length);
  const block: Uint8Array = new Uint8Array(16);
  const enc: Uint8Array = new Uint8Array(16);
  let prev: Uint8Array = iv;
  for (let off: number = 0; off < padded.length; off += 16) {
    for (let i: number = 0; i < 16; i++) {
      block[i] = (padded[off + i] ^ prev[i]) & 0xff;
    }
    aesEncryptBlock(roundKeys, block, enc);
    out.set(enc, off);
    prev = Uint8Array.from([enc[0], enc[1], enc[2], enc[3], enc[4], enc[5], enc[6], enc[7],
      enc[8], enc[9], enc[10], enc[11], enc[12], enc[13], enc[14], enc[15]]);
  }
  return out;
}

/** AES-CBC 解密（PKCS7 去填充），密文必须 16 字节对齐 */
export function qgAesCbcDecrypt(cipherText: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  if (cipherText.length % 16 !== 0) {
    return new Uint8Array(0);
  }
  const roundKeys: Uint8Array[] = aesExpandKey(key);
  const out: Uint8Array = new Uint8Array(cipherText.length);
  const dec: Uint8Array = new Uint8Array(16);
  let prev: Uint8Array = iv;
  for (let off: number = 0; off < cipherText.length; off += 16) {
    aesDecryptBlock(roundKeys, cipherText.slice(off, off + 16), dec);
    for (let i: number = 0; i < 16; i++) {
      out[off + i] = (dec[i] ^ prev[i]) & 0xff;
    }
    prev = cipherText.slice(off, off + 16);
  }
  return qgPkcs7Unpad(out);
}

/** AES-CBC 解密（不去填充，用于手动校验 PKCS7），密文必须 16 字节对齐 */
export function qgAesCbcDecryptNoUnpad(cipherText: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  if (cipherText.length % 16 !== 0) {
    return new Uint8Array(0);
  }
  const roundKeys: Uint8Array[] = aesExpandKey(key);
  const out: Uint8Array = new Uint8Array(cipherText.length);
  const dec: Uint8Array = new Uint8Array(16);
  let prev: Uint8Array = iv;
  for (let off: number = 0; off < cipherText.length; off += 16) {
    aesDecryptBlock(roundKeys, cipherText.slice(off, off + 16), dec);
    for (let i: number = 0; i < 16; i++) {
      out[off + i] = (dec[i] ^ prev[i]) & 0xff;
    }
    prev = cipherText.slice(off, off + 16);
  }
  return out;
}

/** AES-CBC 加密（无填充，输入必须已对齐，用于 X-Argus 容器） */
export function qgAesCbcEncryptNoPad(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  if (plain.length % 16 !== 0) {
    return new Uint8Array(0);
  }
  const roundKeys: Uint8Array[] = aesExpandKey(key);
  const out: Uint8Array = new Uint8Array(plain.length);
  const block: Uint8Array = new Uint8Array(16);
  const enc: Uint8Array = new Uint8Array(16);
  let prev: Uint8Array = iv;
  for (let off: number = 0; off < plain.length; off += 16) {
    for (let i: number = 0; i < 16; i++) {
      block[i] = (plain[off + i] ^ prev[i]) & 0xff;
    }
    aesEncryptBlock(roundKeys, block, enc);
    out.set(enc, off);
    prev = Uint8Array.from([enc[0], enc[1], enc[2], enc[3], enc[4], enc[5], enc[6], enc[7],
      enc[8], enc[9], enc[10], enc[11], enc[12], enc[13], enc[14], enc[15]]);
  }
  return out;
}

/** AES 轮密钥扩展（导出版，供 CTR 等模式复用） */
export function qgAesExpandKey(key: Uint8Array): Uint8Array[] {
  return aesExpandKey(key);
}

/**
 * AES-CTR 就地加/解密（CENC cenc-aes-ctr：128 位大端计数器整体 +1）。
 * roundKeys 为 qgAesExpandKey 结果；iv 为 16 字节完整计数器初值；
 * 只处理 data[start, end) 区间，区间内按块对齐生成 keystream 并异或。
 */
export function qgAesCtrCrypt(roundKeys: Uint8Array[], iv: Uint8Array,
  data: Uint8Array, start: number, end: number): void {
  const counter: Uint8Array = new Uint8Array(16);
  counter.set(iv.subarray(0, 16), 0);
  const stream: Uint8Array = new Uint8Array(16);
  let blockStart: number = start;
  while (blockStart < end) {
    aesEncryptBlock(roundKeys, counter, stream);
    const blockEnd: number = Math.min(blockStart + 16, end);
    for (let i: number = 0; i < blockEnd - blockStart; i++) {
      data[blockStart + i] = (data[blockStart + i] ^ stream[i]) & 0xff;
    }
    // 计数器 128 位大端 +1
    for (let i: number = 15; i >= 0; i--) {
      counter[i] = (counter[i] + 1) & 0xff;
      if (counter[i] !== 0) {
        break;
      }
    }
    blockStart = blockEnd;
  }
}
