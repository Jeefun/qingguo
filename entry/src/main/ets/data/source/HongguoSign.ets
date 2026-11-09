/**
 * 红果请求签名：X-Gorgon / X-Khronos / X-SS-STUB / X-SS-Req-Ticket / X-Argus / X-Ladon。
 * 移植自 guoapp provider_hongguo_player_sign.go，已用 Node 版（qg_source_test.mjs）
 * 与 Go 实现交叉验证（逐字节一致）。
 */
import { qgBase64Encode, qgFromHex, qgRandomBytes, qgReadLe32, qgReadLe64,
  qgRotl64, qgRotr64, qgToHex, qgUtf8Encode, qgWriteBe32, qgWriteLe64 } from '../QgBytes';
import { qgAesCbcEncryptNoPad, qgMd5, qgSm3 } from '../QgCrypto';

const U64: bigint = (1n << 64n) - 1n;
const ARGUS_KEY_HEX: string = 'ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c';
const GORGON_KEY: number[] = [0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc,
  0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f];

/** 字节流构造器（protobuf 消息用） */
class HongguoBuilder {
  private bytes: number[] = [];

  append(data: Uint8Array): void {
    for (let i: number = 0; i < data.length; i++) {
      this.bytes.push(data[i]);
    }
  }

  uvarint(value: bigint): void {
    let x: bigint = value;
    do {
      let b: number = Number(x & 0x7fn);
      x >>= 7n;
      if (x > 0n) {
        b |= 0x80;
      }
      this.bytes.push(b);
    } while (x > 0n);
  }

  varintField(field: number, value: bigint): void {
    this.uvarint(BigInt(field) * 8n);
    this.uvarint(value);
  }

  bytesField(field: number, value: Uint8Array): void {
    this.uvarint(BigInt(field) * 8n + 2n);
    this.uvarint(BigInt(value.length));
    this.append(value);
  }

  build(): Uint8Array {
    return Uint8Array.from(this.bytes);
  }
}

/** 16 字节 PKCS 填充（hongguoCommentPad） */
function pad16(data: Uint8Array): Uint8Array {
  const p: number = 16 - (data.length % 16);
  const out: Uint8Array = new Uint8Array(data.length + p);
  out.set(data, 0);
  for (let i: number = 0; i < p; i++) {
    out[data.length + i] = p;
  }
  return out;
}

/** 8 位字节位反转 */
function reverse8(b: number): number {
  let v: number = b & 0xff;
  v = ((v & 0xf0) >> 4) | ((v & 0x0f) << 4);
  v = ((v & 0xcc) >> 2) | ((v & 0x33) << 2);
  v = ((v & 0xaa) >> 1) | ((v & 0x55) << 1);
  return v & 0xff;
}

/** 8 位左循环移位 */
function rotl8(b: number, n: number): number {
  return ((b << n) | (b >>> (8 - n))) & 0xff;
}

/** X-Gorgon 签名（signHongguoPlayerRequest 前半） */
export function hongguoGorgon(rawQuery: string, body: Uint8Array | null, stamp: number): string {
  const queryHash: Uint8Array = qgMd5(qgUtf8Encode(rawQuery));
  const payload: Uint8Array = new Uint8Array(20);
  for (let i: number = 0; i < 4; i++) {
    payload[i] = queryHash[i];
  }
  if (body !== null) {
    const bodyHash: Uint8Array = qgMd5(body);
    for (let i: number = 0; i < 4; i++) {
      payload[4 + i] = bodyHash[i];
    }
  }
  payload[12] = 0;
  payload[13] = 6;
  payload[14] = 11;
  payload[15] = 28;
  qgWriteBe32(payload, 16, stamp);
  for (let i: number = 0; i < 20; i++) {
    payload[i] ^= GORGON_KEY[i];
  }
  for (let i: number = 0; i < 20; i++) {
    const mixed: number = rotl8(payload[i], 4) ^ payload[(i + 1) % 20];
    payload[i] = (reverse8(mixed) ^ 0xff ^ 20) & 0xff;
  }
  const signature: Uint8Array = new Uint8Array(26);
  const head: number[] = [0x84, 0x04, 0x40, 0x1c, 0, 0];
  for (let i: number = 0; i < head.length; i++) {
    signature[i] = head[i];
  }
  for (let i: number = 0; i < 20; i++) {
    signature[6 + i] = payload[i];
  }
  return qgToHex(signature);
}

/** X-Argus（hongguoPlayerArgus） */
export function hongguoArgus(query: string, body: Uint8Array | null, stamp: number,
  deviceId: string, nonce: Uint8Array): string {
  const key: Uint8Array = qgFromHex(ARGUS_KEY_HEX);
  let bodyHash: Uint8Array = qgSm3(new Uint8Array(16));
  if (body !== null) {
    bodyHash = qgSm3(qgMd5(body));
  }
  const queryHash: Uint8Array = qgSm3(qgUtf8Encode(query));
  const counters: HongguoBuilder = new HongguoBuilder();
  counters.varintField(1, 1n);
  counters.varintField(2, 1n);
  counters.varintField(3, 1n);
  counters.varintField(7, 3348294860n);
  const env: HongguoBuilder = new HongguoBuilder();
  env.bytesField(1, qgUtf8Encode('25053RT47C'));
  env.bytesField(2, qgUtf8Encode('16'));
  env.bytesField(3, qgUtf8Encode('update_64'));
  env.varintField(4, 2147483648n);
  const message: HongguoBuilder = new HongguoBuilder();
  message.varintField(1, 0x20200929n * 2n);
  message.varintField(2, 2n);
  message.varintField(3, BigInt(qgReadLe32(nonce, 6) & 0x7fffffff));
  message.bytesField(4, qgUtf8Encode('8662'));
  message.bytesField(5, qgUtf8Encode(deviceId));
  message.bytesField(6, qgUtf8Encode('1611921764'));
  message.bytesField(7, qgUtf8Encode('7.3.5.32'));
  message.bytesField(8, qgUtf8Encode('v04.07.01-ml-android'));
  message.varintField(9, 135135744n);
  message.bytesField(10, new Uint8Array(8));
  message.varintField(11, 0n);
  message.varintField(12, BigInt(stamp) * 2n);
  message.bytesField(13, bodyHash.slice(0, 6));
  message.bytesField(14, queryHash.slice(0, 6));
  message.bytesField(15, counters.build());
  message.bytesField(16, new Uint8Array(0));
  message.bytesField(20, qgUtf8Encode('none'));
  message.varintField(21, 738n);
  message.bytesField(23, env.build());
  message.varintField(25, 2n);
  const data: Uint8Array = pad16(message.build());
  const seed: Uint8Array = new Uint8Array(key.length * 2 + 4);
  seed.set(key, 0);
  seed[key.length] = 0x3c;
  seed[key.length + 1] = 0xcc;
  seed[key.length + 2] = 0x56;
  seed[key.length + 3] = 0x7b;
  seed.set(key, key.length + 4);
  const derived: Uint8Array = qgSm3(seed);
  const rounds: bigint[] = new Array(72);
  for (let i: number = 0; i < 4; i++) {
    rounds[i] = qgReadLe64(derived, i * 8);
  }
  for (let i: number = 4; i < 72; i++) {
    let mixed: bigint = qgRotr64(rounds[i - 1], 3) ^ rounds[i - 3];
    mixed ^= qgRotr64(mixed, 1);
    rounds[i] = ((~rounds[i - 4]) & U64) ^ mixed ^
      ((0x3dc94c3a046d678bn >> BigInt((i - 4) % 62)) & 1n) ^ 3n;
  }
  for (let off: number = 0; off < data.length; off += 16) {
    let left: bigint = qgReadLe64(data, off);
    let right: bigint = qgReadLe64(data, off + 8);
    for (let r: number = 0; r < 72; r++) {
      const nextLeft: bigint = right;
      const nextRight: bigint = left ^ (qgRotl64(right, 1) & qgRotl64(right, 8)) ^
        qgRotl64(right, 2) ^ rounds[r];
      left = nextLeft;
      right = nextRight;
    }
    qgWriteLe64(data, off, left);
    qgWriteLe64(data, off + 8, right);
  }
  const xor: number[] = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (let i: number = 0; i < data.length; i++) {
    data[i] ^= xor[i % 8];
  }
  const withPrefix: Uint8Array = new Uint8Array(8 + data.length);
  for (let i: number = 0; i < 8; i++) {
    withPrefix[i] = xor[i];
  }
  withPrefix.set(data, 8);
  withPrefix.reverse();
  const head: number[] = [0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18];
  const tail: number[] = [0x56, 0x7b];
  const container: Uint8Array = new Uint8Array(head.length + withPrefix.length + tail.length);
  for (let i: number = 0; i < head.length; i++) {
    container[i] = head[i];
  }
  container.set(withPrefix, head.length);
  for (let i: number = 0; i < tail.length; i++) {
    container[head.length + withPrefix.length + i] = tail[i];
  }
  const padded: Uint8Array = pad16(container);
  const aesKey: Uint8Array = qgMd5(key.slice(0, 16));
  const iv: Uint8Array = qgMd5(key.slice(16));
  const encrypted: Uint8Array = qgAesCbcEncryptNoPad(padded, aesKey, iv);
  const out: Uint8Array = new Uint8Array(2 + encrypted.length);
  out[0] = 0x3c;
  out[1] = 0xcc;
  out.set(encrypted, 2);
  return qgBase64Encode(out);
}

/** X-Ladon（hongguoPlayerLadon） */
export function hongguoLadon(aid: string, stamp: number, prefix: Uint8Array): string {
  const aidBytes: Uint8Array = qgUtf8Encode(aid);
  const hashInput: Uint8Array = new Uint8Array(prefix.length + aidBytes.length);
  hashInput.set(prefix, 0);
  hashInput.set(aidBytes, prefix.length);
  const digest: Uint8Array = qgUtf8Encode(qgToHex(qgMd5(hashInput)));
  let left: bigint = qgReadLe64(digest, 0);
  let right: bigint = qgReadLe64(digest, 8);
  const queue: bigint[] = [qgReadLe64(digest, 16), qgReadLe64(digest, 24)];
  const keys: bigint[] = new Array(34);
  for (let i: number = 0; i < 34; i++) {
    keys[i] = left;
    const mixed: bigint = ((qgRotr64(right, 8) + left) & U64) ^ BigInt(i);
    queue.push(mixed);
    left = mixed ^ qgRotl64(left, 3);
    const shifted: bigint | undefined = queue.shift();
    right = shifted !== undefined ? shifted : 0n;
  }
  const payload: Uint8Array = qgUtf8Encode(`${stamp}-1611921764-${aid}`);
  const data: Uint8Array = pad16(payload);
  for (let off: number = 0; off < data.length; off += 16) {
    let l: bigint = qgReadLe64(data, off);
    let r: bigint = qgReadLe64(data, off + 8);
    for (let k: number = 0; k < 34; k++) {
      r = keys[k] ^ ((l + qgRotr64(r, 8)) & U64);
      l = r ^ qgRotl64(l, 3);
    }
    qgWriteLe64(data, off, l);
    qgWriteLe64(data, off + 8, r);
  }
  const out: Uint8Array = new Uint8Array(prefix.length + data.length);
  out.set(prefix, 0);
  out.set(data, prefix.length);
  return qgBase64Encode(out);
}

/**
 * 生成完整签名头集合（signHongguoPlayerRequest）。
 * @param rawQuery 不含 '?' 的查询串
 * @param body     请求体（GET 为 null）
 * @param deviceId 设备 ID（X-Argus 字段 5）
 * @param aid      应用 ID（X-Ladon 用，"8662"）
 */
export function hongguoSignHeaders(rawQuery: string, body: Uint8Array | null,
  deviceId: string, aid: string): Record<string, string> {
  const stamp: number = Math.floor(Date.now() / 1000);
  const nonce: Uint8Array = qgRandomBytes(11);
  const headers: Record<string, string> = {};
  headers['X-Khronos'] = `${stamp}`;
  headers['X-SS-Req-Ticket'] = `${Date.now()}`;
  if (body !== null) {
    headers['X-SS-STUB'] = qgToHex(qgMd5(body)).toUpperCase();
    headers['Content-Type'] = 'application/json; charset=utf-8';
  }
  headers['X-Gorgon'] = hongguoGorgon(rawQuery, body, stamp);
  headers['X-Argus'] = hongguoArgus(rawQuery, body, stamp, deviceId, nonce);
  headers['X-Ladon'] = hongguoLadon(aid, stamp, nonce.slice(2, 6));
  return headers;
}

/** 新设备 ID：1e18 + be64(random) % 8e18（19 位数字） */
export function newHongguoDeviceId(): string {
  const random: Uint8Array = qgRandomBytes(8);
  let value: bigint = 0n;
  for (let i: number = 0; i < 8; i++) {
    value = (value << 8n) | BigInt(random[i]);
  }
  return (1000000000000000000n + value % 8000000000000000000n).toString();
}
