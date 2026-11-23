/**
 * Playback request signing from guoapp-modules/hongguo 1.0.3 (2026-11-17).
 * Source: https://github.com/guoapp-modules/hongguo/blob/main/main.js
 * SPDX-License-Identifier: GPL-3.0-only
 * Kept as JavaScript to preserve upstream byte arithmetic. This module only
 * signs API requests; platform byte/hash functions are injected by ArkTS.
 */
export function createPlaybackSigner(host) {
const mask64 = (1n << 64n) - 1n;
const sm3 = input => host.sm3(input);
function decodeQueryComponent(text) {
  try {
    return decodeURIComponent(text.replace(/\+/g, " "));
  } catch (error) {
    return null;
  }
}

function queryValue(query, name) {
  for (const part of String(query || "").split("&")) {
    if (part === "") {
      continue;
    }
    const separator = part.indexOf("=");
    const key = decodeQueryComponent(separator < 0 ? part : part.slice(0, separator));
    if (key === name) {
      const value = decodeQueryComponent(separator < 0 ? "" : part.slice(separator + 1));
      return value === null ? "" : value;
    }
  }
  return "";
}

function queryEscape(text) {
  return encodeURIComponent(text)
    .replace(/[!'()*]/g, (character) => "%" + character.charCodeAt(0).toString(16).toUpperCase())
    .replace(/%20/g, "+");
}

function encodeQuery(params) {
  return Object.keys(params)
    .sort()
    .map((key) => queryEscape(key) + "=" + queryEscape(String(params[key])))
    .join("&");
}

function concatBytes(...parts) {
  let length = 0;
  for (const part of parts) {
    length += part.length;
  }
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    for (let index = 0; index < part.length; index++) {
      out[offset++] = part[index];
    }
  }
  return out;
}

function pad16(data) {
  const padding = 16 - (data.length % 16);
  const out = new Uint8Array(data.length + padding);
  for (let index = 0; index < out.length; index++) {
    out[index] = index < data.length ? data[index] : padding;
  }
  return out;
}

function sliceBytes(data, start, end) {
  const out = [];
  for (let index = start; index < end; index++) {
    out.push(data[index]);
  }
  return out;
}

function appendUvarint(out, value) {
  while (value >= 128) {
    out.push((value % 128) | 128);
    value = Math.floor(value / 128);
  }
  out.push(value);
}

function varintField(out, field, value) {
  appendUvarint(out, field * 8);
  appendUvarint(out, value);
}

function bytesField(out, field, value) {
  appendUvarint(out, field * 8 + 2);
  appendUvarint(out, value.length);
  for (let index = 0; index < value.length; index++) {
    out.push(value[index]);
  }
}

function u32le(data, offset) {
  return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

function rotl32(value, bits) {
  bits &= 31;
  return bits === 0 ? value >>> 0 : ((value << bits) | (value >>> (32 - bits))) >>> 0;
}

function readU64(data, offset) {
  return BigInt(u32le(data, offset)) | (BigInt(u32le(data, offset + 4)) << 32n);
}

function writeU64(data, offset, value) {
  const low = Number(value & 0xffffffffn);
  const high = Number(value >> 32n);
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (low >>> (8 * index)) & 255;
    data[offset + 4 + index] = (high >>> (8 * index)) & 255;
  }
}

function rotl64(value, bits) {
  const shift = ((bits % 64) + 64) % 64;
  return shift === 0 ? value : ((value << BigInt(shift)) | (value >> BigInt(64 - shift))) & mask64;
}

function rotl8(value, bits) {
  return ((value << bits) | (value >>> (8 - bits))) & 255;
}

function putUint32BE(data, offset, value) {
  for (let index = 0; index < 4; index++) {
    data[offset + index] = (value >>> (24 - 8 * index)) & 255;
  }
}
// Derived from N3urda/hongguoTV Signer/AesV3/V5Constants and drpys 22261ad; SPDX-License-Identifier: GPL-3.0-only.
const playbackV5Magic = host.hexDecode("2d4b4fca49750d433fb5ae2c226dcc56");
const playbackV5SignKey = host.hexDecode("b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d");
const playbackV5Sbox = host.hexDecode(
  "53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d" +
  "f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a" +
  "80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d" +
  "d12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912" +
  "38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65" +
  "b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe" +
  "1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8" +
  "94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc" +
  "d759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d" +
  "e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e" +
  "47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28" +
  "8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5" +
  "d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9" +
  "1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f" +
  "d830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168" +
  "1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e"
);
const playbackV5HashTable = [
  0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
  0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
  0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
  0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
  0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
  0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
  0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
  0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586
];
let playbackV5Process = null;

function playbackV5Le32(value) {
  return new Uint8Array([value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255]);
}

function playbackV5IV(queryHashBytes, bodyMd5Bytes, ts) {
  let value = 0x20230928;
  for (const data of [queryHashBytes, bodyMd5Bytes, playbackV5Le32(ts)]) {
    for (let index = 0; index < data.length; index++) {
      value = (index & 1) === 0
        ? (value >>> 4) ^ value ^ (value << 6) ^ data[index]
        : ~((value >>> 7) ^ value ^ (data[index] | (value << 12)));
    }
  }
  return value;
}

function playbackV5Hash(queryHashBytes, bodyMd5Bytes, ts) {
  if (queryHashBytes.length !== 32 || bodyMd5Bytes.length !== 16) {
    throw new Error("V5 hash requires a 32-byte query hash and a 16-byte body hash");
  }
  if ((playbackV5IV(queryHashBytes, bodyMd5Bytes, ts) & 15) !== 12) {
    throw new Error("Unsupported V5 hash branch");
  }
  const iv = 0x9d4a97c2;
  const count = (iv + ts) | 0;
  const table = playbackV5HashTable.map((value) => rotl32(value, -((count + 1) & 255)));
  const shift = (count + 2) & 7;
  const padding = [0xfa, 0x45, 0x61, 0xd7].map((value) => ((value | (value << 8)) >>> shift) & 255);
  const data = concatBytes(queryHashBytes, bodyMd5Bytes, playbackV5Le32(ts), padding, [0, 0, 0, 0, 0, 0, 1, 0xa0]);
  const words = [];
  for (let index = 0; index < data.length; index += 4) {
    words.push((data[index] << 24) | (data[index + 1] << 16) | (data[index + 2] << 8) | data[index + 3]);
  }
  for (let index = 0; index < 112; index++) {
    const x = words[index + 1];
    const y = words[index + 14];
    words.push((words[index] + words[index + 9] +
      (rotl32(x, 14) ^ rotl32(x, 25) ^ (x >>> 3)) +
      (rotl32(y, 13) ^ rotl32(y, 15) ^ (y >>> 10))) | 0);
  }
  const initial = [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f, 984304912, 3005047866, 2874125293, 2152413264]
    .map((value) => rotl32(value, -count));
  const state = initial.slice();
  for (let index = 0; index < 96; index++) {
    const base = (iv + index) | 0;
    const choose = ((state[4] ^ state[0]) & state[1]) ^ state[4];
    const sigma1 = rotl32(state[1], 26) ^ rotl32(state[1], 21) ^ rotl32(state[1], 7);
    const mixed = (words[base & 127] + choose + sigma1 + table[base & 63] + state[6]) | 0;
    const sigma0 = rotl32(state[3], 30) ^ rotl32(state[3], 19) ^ rotl32(state[3], 10);
    const majority = (state[3] & state[5]) | ((state[3] | state[5]) & state[2]);
    const old = state[7];
    state.unshift(state.pop());
    state[7] = (sigma0 + majority + mixed) | 0;
    state[0] = (old + mixed) | 0;
  }
  const digest = new Uint8Array(32);
  for (let index = 0; index < 8; index++) {
    putUint32BE(digest, index * 4, (state[index] + initial[index]) | 0);
  }
  const folded = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    folded[index] = digest[index] ^ digest[index + 16];
  }
  let check = 0x20220420;
  for (let index = 0; index < 12; index++) {
    const even = (index & 1) === 0;
    const temp = (check >>> (even ? 3 : 5)) ^ check;
    check = (even ? folded[index] ^ (check << 7) : ~(folded[index] | (check << 11))) ^ temp;
  }
  return concatBytes(folded, playbackV5Le32(((check | 4) ^ 0x1000000) | 0x20));
}

function playbackV5Carrier(keyBytes, ivBytes, sourceBytes, ts) {
  if (keyBytes.length !== 16 || ivBytes.length !== 16 || sourceBytes.length < 248) {
    throw new Error("V5 carrier requires 16-byte key/IV and at least 248 source bytes");
  }
  const variant = ts & 3;
  const box = sliceBytes(playbackV5Sbox, variant * 256, (variant + 1) * 256);
  const con = [[2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]][variant];
  const order = [
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
    [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
    [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7]
  ][variant];
  const initial = [0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9][variant];
  const initialBytes = playbackV5Le32(initial);
  const expanded = new Uint8Array(48);
  for (let index = 0; index < 16; index++) {
    expanded[index] = initialBytes[index & 3] ^ keyBytes[index];
  }
  let rounds = 8;
  for (let index = 4; index < 12; index++) {
    const at = 4 * (index - 1);
    let a = expanded[at];
    let b = expanded[at + 1];
    let c = expanded[at + 2];
    let d = expanded[at + 3];
    if ((index & 3) === 0) {
      const next = ((initial >> (rounds & 24)) ^ box[b]) & 255;
      b = box[c];
      c = box[d];
      d = box[a];
      a = next;
    }
    rounds += 2;
    expanded[at + 4] = a ^ expanded[at - 12];
    expanded[at + 5] = b ^ expanded[at - 11];
    expanded[at + 6] = c ^ expanded[at - 10];
    expanded[at + 7] = d ^ expanded[at - 9];
  }
  function xt(value) {
    return ((value << 1) ^ ((value & 128) !== 0 ? 0x1b : 0)) & 255;
  }
  function block(value) {
    let rows = [0, 1, 2, 3].map((index) => sliceBytes(value, index * 4, index * 4 + 4));
    function addCon(offset) {
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          rows[i][j] ^= expanded[(offset + i) * 4 + con[j]];
        }
      }
    }
    addCon(0);
    for (let round = 1; round <= 2; round++) {
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 4; j++) {
          rows[i][j] = box[rows[i][j]];
        }
      }
      const before = rows.map((row) => row.slice());
      rows = con.map((index) => before[index]);
      const flat = concatBytes(...rows);
      for (let index = 0; index < 16; index++) {
        rows[Math.floor(index / 4)][index % 4] = flat[order[index]];
      }
      if (round === 1) {
        rows = rows.map((row) => con.map((index) => row[index]));
        for (let index = 0; index < 4; index++) {
          const mixed = rows[0][index] ^ rows[1][index] ^ rows[2][index] ^ rows[3][index];
          const first = rows[0][index];
          rows[0][index] ^= mixed ^ xt(rows[0][index] ^ rows[1][index]);
          rows[1][index] ^= mixed ^ xt(rows[1][index] ^ rows[2][index]);
          rows[2][index] ^= mixed ^ xt(rows[2][index] ^ rows[3][index]);
          rows[3][index] ^= mixed ^ xt(rows[3][index] ^ first);
        }
      }
      addCon(round * 4);
    }
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) {
        rows[i][j] ^= expanded[(4 + i) * 4 + j];
      }
    }
    return concatBytes(...rows);
  }
  const wire = [6, 5, 3, 4, 2, 7, 1, 0];
  const compact = [1, 7, 3, 6, 2, 0, 4, 5];
  const plaintext = new Uint8Array(32);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      plaintext[i] |= ((sourceBytes[i * 8 + j] >>> wire[j]) & 1) << compact[j];
    }
  }
  plaintext[31] = 1;
  const input = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index] ^ ivBytes[index];
  }
  const first = block(input);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index + 16] ^ first[index];
  }
  const key = concatBytes(first, block(input));
  const out = concatBytes([key[31]], sourceBytes);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      const at = 1 + i * 8 + j;
      out[at] = (out[at] & ~(1 << wire[j])) | (((key[i] >>> compact[j]) & 1) << wire[j]);
    }
  }
  return out;
}

function playbackV5Proto(fields) {
  const out = [];
  for (const [tag, value] of fields) {
    if (typeof value === "number") {
      varintField(out, tag, value < 0 ? -value * 2 - 1 : value * 2);
    } else {
      const bytes = typeof value === "string" ? host.utf8Encode(value) : value;
      if (bytes.length !== 0) {
        bytesField(out, tag, bytes);
      }
    }
  }
  return new Uint8Array(out);
}

function playbackV5Xmxor(data, key) {
  const encoded = new Uint8Array(data.length);
  for (let index = 0; index < data.length; index++) {
    const at = (index * 4) & 28;
    const d0 = key[at];
    const d1 = key[at + 1];
    let mixed = rotl8(data[index], 4) + d0;
    mixed = ~mixed ^ d1;
    mixed = rotl8(mixed & 255, 3);
    mixed = (mixed + d1) & 255;
    mixed ^= d0;
    encoded[data.length - index - 1] = ~mixed & 255;
  }
  const lastIndex = encoded.length - 1;
  const last = encoded[lastIndex] ^ encoded[lastIndex - 1];
  const first = encoded[0];
  encoded[0] = (~last + first) & 255;
  encoded[1] = ((encoded[0] ^ encoded[lastIndex] ^ 254) + encoded[1]) & 255;
  encoded[2] = (encoded[2] + ((last - first) ^ rotl8(encoded[1], 3) ^ 2)) & 255;
  for (let index = 0; index < encoded.length - 4; index++) {
    const mixed = rotl8(encoded[index + 2], 3) ^ encoded[index + 1] ^ (index + 3);
    encoded[index + 3] = (~mixed + encoded[index + 3]) & 255;
  }
  encoded[lastIndex] ^= encoded[lastIndex - 1];
  let sum = 0;
  for (let index = 1; index < encoded.length; index++) {
    sum += encoded[index];
  }
  encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255;
  return encoded;
}

function playbackV5Helios(ts) {
  const prefix = host.randomBytes(4);
  const ascii = host.utf8Encode(host.hexEncode(host.md5(concatBytes(prefix, host.utf8Encode("8662")))));
  let left = readU64(ascii, 0);
  let right = readU64(ascii, 8);
  const queue = [readU64(ascii, 16), readU64(ascii, 24)];
  const keys = [];
  for (let index = 0; index < 34; index++) {
    keys.push(left);
    const mixed = ((rotl64(right, -8) + left) & mask64) ^ BigInt(index);
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    right = queue.shift();
  }
  const data = pad16(host.utf8Encode(ts + "-646637794-8662"));
  for (let offset = 0; offset < data.length; offset += 16) {
    let a = readU64(data, offset);
    let b = readU64(data, offset + 8);
    for (const key of keys) {
      b = key ^ ((a + rotl64(b, -8)) & mask64);
      a = b ^ rotl64(a, 3);
    }
    writeU64(data, offset, a);
    writeU64(data, offset + 8, b);
  }
  return host.base64Encode(concatBytes(prefix, data));
}

function playbackV5Medusa(queryHash, f13, ts, who, nowMs) {
  if (playbackV5Process === null) {
    playbackV5Process = {
      nonce: host.base64Encode(host.randomBytes(18)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
      started: nowMs
    };
  }
  const flags = new Uint8Array(8);
  const deviceInfo = playbackV5Proto([
    [1, 1], [2, 2], [3, "8662"], [4, who.device_id], [5, playbackV5Process.nonce],
    [6, "!noperm!"], [12, "Asia/Shanghai,8"], [13, "zh_CN"], [22, who.os_version],
    [25, playbackV5Process.started], [30, who.device_type], [31, who.device_brand],
    [32, who.device_type], [34, who.device_brand]
  ]);
  const env = playbackV5Proto([
    [6, "v04.10.03.04-bugfix"], [8, who.channel], [12, deviceInfo], [14, who.version_name]
  ]);
  const message = playbackV5Proto([
    [1, playbackV5Magic], [2, 5], [3, u32le(host.randomBytes(4), 0)], [4, "8662"],
    [5, who.device_id], [6, "646637794"], [7, who.version_name], [8, "v04.10.03-ml-android"],
    [9, 0x040a0300], [10, flags], [12, ts], [13, f13], [14, sliceBytes(queryHash, 0, 6)],
    [15, playbackV5Proto([[1, 1], [2, 1], [3, 1], [5, 1]])], [17, ts], [20, "none"],
    [21, 377], [23, env],
    [24, '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}']
  ]);
  const nonce = u32le(host.randomBytes(4), 0);
  const hash = sm3(concatBytes(playbackV5SignKey, playbackV5Le32(nonce), playbackV5SignKey));
  const high = (nonce >>> 16) & 255;
  const seed = playbackV5Le32(~(((high << 11) | (nonce >>> 24)) ^ (high >>> 5) ^ high));
  const transformed = concatBytes(flags, playbackV5Xmxor(message, hash)).reverse();
  for (let index = 0; index < transformed.length; index++) {
    transformed[index] ^= seed[(~index) & 3];
  }
  const check = 0x18000001 | ((queryHash[0] & 63) << 14) | ((f13[0] & 63) << 8);
  const packed = concatBytes([0xca], host.randomBytes(4), playbackV5Le32(check), transformed, [(nonce >>> 16) & 255, (nonce >>> 24) & 255]);
  const encrypted = playbackV5Carrier(
    host.md5(sliceBytes(playbackV5SignKey, 0, 16)),
    host.md5(sliceBytes(playbackV5SignKey, 16, 32)),
    packed,
    ts
  );
  const prefix = concatBytes(playbackV5Le32(5), playbackV5Magic);
  const stamp = playbackV5Le32(ts);
  for (let index = 0; index < prefix.length; index++) {
    prefix[index] ^= stamp[index & 3];
  }
  return host.base64Encode(concatBytes(prefix, [nonce & 255, (nonce >>> 8) & 255, 0, 1], encrypted));
}

function signPlaybackV5(base, values, bodyBytes, nowMs) {
  const ts = Math.floor(nowMs / 1000) | 0;
  const hasBody = bodyBytes !== null && bodyBytes !== undefined;
  const bodyMd5 = hasBody ? host.md5(bodyBytes) : new Uint8Array(16);
  const params = Object.assign({}, values);
  for (let offset = 0; offset < 1024; offset++) {
    params._rticket = String(nowMs + offset);
    const query = encodeQuery(params);
    const queryHash = sm3(host.utf8Encode(query));
    if ((playbackV5IV(queryHash, bodyMd5, ts) & 15) !== 12) {
      continue;
    }
    const who = {};
    for (const name of ["device_id", "version_name", "os_version", "device_type", "channel"]) {
      who[name] = queryValue(query, name);
      if (who[name] === "") {
        throw new Error("播放签名缺少设备字段：" + name);
      }
    }
    who.device_brand = queryValue(query, "device_brand") || "HONOR";
    const f13 = playbackV5Hash(queryHash, bodyMd5, ts);
    const headers = {
      "X-Khronos": String(ts),
      "X-Helios": playbackV5Helios(ts),
      "X-Medusa": playbackV5Medusa(queryHash, f13, ts, who, nowMs)
    };
    if (hasBody) {
      headers["X-SS-STUB"] = host.hexEncode(bodyMd5).toUpperCase();
      headers["Content-Type"] = "application/json; charset=utf-8";
    }
    return { url: base + "?" + query, headers };
  }
  throw new Error("无法在 1024 次 ticket 尝试内生成 V5 播放签名");
}

return { sign: signPlaybackV5 };
}
