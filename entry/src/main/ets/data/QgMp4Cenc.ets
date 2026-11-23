/**
 * MP4 CENC（cenc-aes-ctr）就地解密器。
 * 针对红果 App 变体：完整加密 MP4（ftyp + moov + mdat，moov 在前），
 * 每 trak 的 stbl 内含 senc（per-sample 8 字节 IV，无 subsample）、saiz、saio，
 * stsd 的 encv/enca entry 含 sinf（frma + schm cenc + schi tenc）。
 *
 * 就地手术（文件布局与所有 box 偏移保持不变，stco 无需重算）：
 *  1. mdat 内每 sample 用 senc 的 IV（补零到 16 字节）做 AES-128-CTR 解密；
 *  2. senc / saiz / saio 的 fourcc 改写为 free（大小不变）；
 *  3. stsd entry：encv→hvc1、enca→mp4a（读 sinf/frma 的原始 fourcc），
 *     将 sinf 之后的 entry 内容前移覆盖 sinf，entry size 缩小，尾部清零。
 * 已用真实红果加密样本验证（senc IV 逐样本 +1 递增，解密后 NAL 结构合法）。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { QgDiag } from './QgDiag';
import { qgAesCtrCrypt, qgAesExpandKey } from './QgCrypto';

/** 待解密的单个 CENC sample：绝对偏移 + 大小 + 16 字节计数器初值 */
class QgCencSample {
  offset: number = 0;
  size: number = 0;
  iv: Uint8Array = new Uint8Array(16);

  constructor(offset: number, size: number, iv: Uint8Array) {
    this.offset = offset;
    this.size = size;
    this.iv = new Uint8Array(16);
    this.iv.set(iv.subarray(0, 16), 0);
  }
}

/**
 * 用系统 Native AES 一次性生成全部 CTR keystream，再异或回样本数据。
 * CENC 的计数器是 128 位大端 +1，等价于「AES-ECB 加密一串递增 counter 块」。
 * 原逐块 JS 实现 1.45MB 要 6 秒、5.5MB 要 20 秒；Native 加密 + 一次线性异或可降到亚秒级。
 */
async function qgDecryptSamplesNative(buf: Uint8Array, samples: QgCencSample[],
  key: Uint8Array): Promise<void> {
  let total: number = 0;
  for (let i: number = 0; i < samples.length; i++) {
    total += Math.ceil(samples[i].size / 16) * 16;
  }
  if (total === 0) {
    return;
  }
  // 1) 拼出所有 sample 的 counter 块（每个 sample 从自己的 IV 重新起算）
  const blocks: Uint8Array = new Uint8Array(total);
  let cursor: number = 0;
  for (let i: number = 0; i < samples.length; i++) {
    const s: QgCencSample = samples[i];
    const ctr: Uint8Array = new Uint8Array(16);
    ctr.set(s.iv, 0);
    const count: number = Math.ceil(s.size / 16);
    for (let b: number = 0; b < count; b++) {
      blocks.set(ctr, cursor);
      cursor += 16;
      for (let k: number = 15; k >= 0; k--) {
        ctr[k] = (ctr[k] + 1) & 0xff;
        if (ctr[k] !== 0) {
          break;
        }
      }
    }
  }
  // 2) 一次 Native AES-ECB 得到全部 keystream
  const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = generator.convertKeySync({ data: key });
  // transformation 格式是「算法|模式|填充」，连字符写法会报 create C cipher fail
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);
  const encrypted: cryptoFramework.DataBlob = await cipher.doFinal({ data: blocks });
  const stream: Uint8Array = encrypted.data;
  if (stream.length < total) {
    throw new Error('Native AES keystream 长度不足');
  }
  // 3) 逐字节异或回原 sample 区间
  cursor = 0;
  for (let i: number = 0; i < samples.length; i++) {
    const s: QgCencSample = samples[i];
    for (let k: number = 0; k < s.size; k++) {
      buf[s.offset + k] = (buf[s.offset + k] ^ stream[cursor + k]) & 0xff;
    }
    cursor += Math.ceil(s.size / 16) * 16;
  }
}

/** MP4 box 位置描述 */
class QgMp4Box {
  type: string = '';
  start: number = 0;
  bodyStart: number = 0;
  size: number = 0;

  constructor(type: string, start: number, bodyStart: number, size: number) {
    this.type = type;
    this.start = start;
    this.bodyStart = bodyStart;
    this.size = size;
  }
}

/** 容器 box：需要递归遍历的类型 */
const MP4_CONTAINERS: string[] = ['moov', 'trak', 'mdia', 'minf', 'stbl'];

function mp4ReadU32(buf: Uint8Array, offset: number): number {
  return ((buf[offset] << 24) | (buf[offset + 1] << 16) |
    (buf[offset + 2] << 8) | buf[offset + 3]) >>> 0;
}

function mp4WriteU32(buf: Uint8Array, offset: number, value: number): void {
  buf[offset] = (value >>> 24) & 0xff;
  buf[offset + 1] = (value >>> 16) & 0xff;
  buf[offset + 2] = (value >>> 8) & 0xff;
  buf[offset + 3] = value & 0xff;
}

function mp4WriteFourcc(buf: Uint8Array, offset: number, fourcc: string): void {
  for (let i: number = 0; i < 4; i++) {
    buf[offset + i] = i < fourcc.length ? fourcc.charCodeAt(i) & 0xff : 0x20;
  }
}

/** 遍历 [start, end) 内的顶层 box */
function mp4IterBoxes(buf: Uint8Array, start: number, end: number): QgMp4Box[] {
  const out: QgMp4Box[] = [];
  let off: number = start;
  while (off + 8 <= end) {
    let size: number = mp4ReadU32(buf, off);
    let headerSize: number = 8;
    if (size === 1) {
      // largesize（64 位），CENC 样本文件不会走到，防御性支持
      if (off + 16 > end) {
        break;
      }
      const hi: number = mp4ReadU32(buf, off + 8);
      const lo: number = mp4ReadU32(buf, off + 12);
      if (hi > 0) {
        break; // 超过 2^32 的文件不支持
      }
      size = lo;
      headerSize = 16;
    } else if (size === 0) {
      size = end - off;
    }
    if (size < headerSize || off + size > end) {
      break;
    }
    let type: string = '';
    for (let i: number = 0; i < 4; i++) {
      type += String.fromCharCode(buf[off + 4 + i]);
    }
    out.push(new QgMp4Box(type, off, off + headerSize, size));
    off += size;
  }
  return out;
}

/** 在 [start, end) 递归查找指定类型 box（深度优先，返回首个） */
function mp4FindBox(buf: Uint8Array, start: number, end: number, type: string): QgMp4Box | null {
  const boxes: QgMp4Box[] = mp4IterBoxes(buf, start, end);
  for (let i: number = 0; i < boxes.length; i++) {
    if (boxes[i].type === type) {
      return boxes[i];
    }
    if (MP4_CONTAINERS.indexOf(boxes[i].type) >= 0) {
      const found: QgMp4Box | null = mp4FindBox(buf, boxes[i].bodyStart, boxes[i].start + boxes[i].size, type);
      if (found !== null) {
        return found;
      }
    }
  }
  return null;
}

/** 单个 trak 的 sample 表（绝对偏移 + 大小） */
class QgMp4SampleTable {
  offsets: number[] = [];
  sizes: number[] = [];
}

/** 解析 trak 内 stsz/stsc/stco(co64) 得到每 sample 绝对偏移与大小 */
function mp4ParseSampleTable(buf: Uint8Array, trak: QgMp4Box): QgMp4SampleTable | null {
  const table: QgMp4SampleTable = new QgMp4SampleTable();
  const stsz: QgMp4Box | null = mp4FindBox(buf, trak.bodyStart, trak.start + trak.size, 'stsz');
  const stsc: QgMp4Box | null = mp4FindBox(buf, trak.bodyStart, trak.start + trak.size, 'stsc');
  let stco: QgMp4Box | null = mp4FindBox(buf, trak.bodyStart, trak.start + trak.size, 'stco');
  let co64: QgMp4Box | null = null;
  if (stco === null) {
    co64 = mp4FindBox(buf, trak.bodyStart, trak.start + trak.size, 'co64');
  }
  if (stsz === null || stsc === null || (stco === null && co64 === null)) {
    return null;
  }
  // stsz：固定值或逐 sample 大小表
  const fixedSize: number = mp4ReadU32(buf, stsz.bodyStart + 4);
  const sampleCount: number = mp4ReadU32(buf, stsz.bodyStart + 8);
  if (sampleCount === 0) {
    return table;
  }
  const sizes: number[] = new Array(sampleCount);
  for (let i: number = 0; i < sampleCount; i++) {
    sizes[i] = fixedSize > 0 ? fixedSize : mp4ReadU32(buf, stsz.bodyStart + 12 + i * 4);
  }
  // stco / co64：chunk 绝对偏移
  const chunkBox: QgMp4Box = stco !== null ? stco : co64 as QgMp4Box;
  const chunkCount: number = mp4ReadU32(buf, chunkBox.bodyStart + 4);
  const chunkOffsets: number[] = new Array(chunkCount);
  for (let i: number = 0; i < chunkCount; i++) {
    if (stco !== null) {
      chunkOffsets[i] = mp4ReadU32(buf, stco.bodyStart + 8 + i * 4);
    } else {
      const hi: number = mp4ReadU32(buf, chunkBox.bodyStart + 8 + i * 8);
      const lo: number = mp4ReadU32(buf, chunkBox.bodyStart + 12 + i * 8);
      if (hi > 0) {
        return null; // 超大文件不支持
      }
      chunkOffsets[i] = lo;
    }
  }
  // stsc：first_chunk / samples_per_chunk（sample_description_index 忽略）
  const stscCount: number = mp4ReadU32(buf, stsc.bodyStart + 4);
  const stscFirst: number[] = new Array(stscCount);
  const stscPer: number[] = new Array(stscCount);
  for (let i: number = 0; i < stscCount; i++) {
    stscFirst[i] = mp4ReadU32(buf, stsc.bodyStart + 8 + i * 12);
    stscPer[i] = mp4ReadU32(buf, stsc.bodyStart + 12 + i * 12);
  }
  // 展开：chunk 内 sample 连续排列
  const offsets: number[] = new Array(sampleCount);
  let sampleIndex: number = 0;
  for (let chunk: number = 0; chunk < chunkCount && sampleIndex < sampleCount; chunk++) {
    let perChunk: number = 1;
    for (let k: number = stscCount - 1; k >= 0; k--) {
      if (stscFirst[k] > 0 && chunk + 1 >= stscFirst[k]) {
        perChunk = stscPer[k];
        break;
      }
    }
    let cursor: number = chunkOffsets[chunk];
    for (let j: number = 0; j < perChunk && sampleIndex < sampleCount; j++) {
      offsets[sampleIndex] = cursor;
      cursor += sizes[sampleIndex];
      sampleIndex++;
    }
  }
  if (sampleIndex < sampleCount) {
    return null;
  }
  table.offsets = offsets;
  table.sizes = sizes;
  return table;
}

/**
 * 就地解密整个 CENC MP4 文件。
 * @param buf 完整文件字节（将被修改）
 * @param key 16 字节 AES-128 内容密钥
 * @returns 成功返回 true；结构不支持（subsample/多 entry stsd/超大文件等）返回 false
 */
/** 让出主线程一次：大文件分块解密时避免连续占用超过 watchdog 的 3s 阈值 */
function qgYieldAsync(): Promise<void> {
  return new Promise<void>((resolve: (value: void | PromiseLike<void>) => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}

/**
 * CENC 解密（异步分块）。
 * 原实现同步跑完整个 MP4 的 AES-CTR，主线程连续被占用数秒触发 THREAD_BLOCK_6S，
 * 表现为点播放后卡死再闪退。现在每解密 128KB 主动让出一次事件循环。
 */
export async function qgCencDecryptMp4(buf: Uint8Array, key: Uint8Array,
  yieldToMain: boolean = true): Promise<boolean> {
  if (key.length !== 16) {
    return false;
  }
  const topBoxes: QgMp4Box[] = mp4IterBoxes(buf, 0, buf.length);
  let moov: QgMp4Box | null = null;
  for (let i: number = 0; i < topBoxes.length; i++) {
    if (topBoxes[i].type === 'moov') {
      moov = topBoxes[i];
      break;
    }
  }
  if (moov === null) {
    return false;
  }
  const iv16: Uint8Array = new Uint8Array(16);
  /** 先收集全部 sample，最后一次性批量解密（Native AES keystream） */
  const samples: QgCencSample[] = [];
  const traks: QgMp4Box[] = mp4IterBoxes(buf, moov.bodyStart, moov.start + moov.size);
  let decryptedTracks: number = 0;
  for (let t: number = 0; t < traks.length; t++) {
    if (traks[t].type !== 'trak') {
      continue;
    }
    const trak: QgMp4Box = traks[t];
    const stbl: QgMp4Box | null = mp4FindBox(buf, trak.bodyStart, trak.start + trak.size, 'stbl');
    if (stbl === null) {
      continue;
    }
    const stblBoxes: QgMp4Box[] = mp4IterBoxes(buf, stbl.bodyStart, stbl.start + stbl.size);
    let senc: QgMp4Box | null = null;
    let saiz: QgMp4Box | null = null;
    let saio: QgMp4Box | null = null;
    for (let i: number = 0; i < stblBoxes.length; i++) {
      if (stblBoxes[i].type === 'senc') {
        senc = stblBoxes[i];
      } else if (stblBoxes[i].type === 'saiz') {
        saiz = stblBoxes[i];
      } else if (stblBoxes[i].type === 'saio') {
        saio = stblBoxes[i];
      }
    }
    if (senc === null) {
      continue; // 未加密轨道
    }
    // senc：version/flags(4) + sample_count(4) + 逐 sample 8 字节 IV
    const flags: number = mp4ReadU32(buf, senc.bodyStart);
    const sampleCount: number = mp4ReadU32(buf, senc.bodyStart + 4);
    if ((flags & 0x01) !== 0) {
      return false; // subsample 加密不支持（红果实测为 0）
    }
    if (sampleCount === 0 || senc.bodyStart + 8 + sampleCount * 8 > senc.start + senc.size) {
      return false;
    }
    const table: QgMp4SampleTable | null = mp4ParseSampleTable(buf, trak);
    if (table === null || table.offsets.length !== sampleCount) {
      return false;
    }
    // 逐 sample AES-CTR 解密
    for (let i: number = 0; i < sampleCount; i++) {
      const offset: number = table.offsets[i];
      const size: number = table.sizes[i];
      if (size === 0) {
        continue;
      }
      if (offset < 0 || offset + size > buf.length) {
        return false;
      }
      for (let k: number = 0; k < 8; k++) {
        iv16[k] = buf[senc.bodyStart + 8 + i * 8 + k];
      }
      for (let k: number = 8; k < 16; k++) {
        iv16[k] = 0;
      }
      samples.push(new QgCencSample(offset, size, iv16));
    }
    // senc/saiz/saio → free（布局不变）
    mp4WriteFourcc(buf, senc.start + 4, 'free');
    if (saiz !== null) {
      mp4WriteFourcc(buf, saiz.start + 4, 'free');
    }
    if (saio !== null) {
      mp4WriteFourcc(buf, saio.start + 4, 'free');
    }
    // stsd 手术：encv/enca → 原始 fourcc，去 sinf
    const stsd: QgMp4Box | null = mp4FindBox(buf, stbl.bodyStart, stbl.start + stbl.size, 'stsd');
    if (stsd !== null && !mp4StripStsdEncryption(buf, stsd)) {
      return false;
    }
    decryptedTracks++;
  }
  if (decryptedTracks === 0) {
    return false;
  }
  try {
    await qgDecryptSamplesNative(buf, samples, key);
    QgDiag.log('Cenc', `native aes ok ${samples.length} samples`);
  } catch (error) {
    // Native 加密不可用时退回原 JS 实现：慢但不影响可用性
    const err: Error = error as Error;
    QgDiag.log('Cenc', `native aes failed, fallback to JS: ${err.message}`);
    const roundKeys: Uint8Array[] = qgAesExpandKey(key);
    let sinceYield: number = 0;
    for (let i: number = 0; i < samples.length; i++) {
      const s: QgCencSample = samples[i];
      qgAesCtrCrypt(roundKeys, s.iv, buf, s.offset, s.offset + s.size);
      sinceYield += s.size;
      if (yieldToMain && sinceYield >= 131072) {
        sinceYield = 0;
        await qgYieldAsync();
      }
    }
  }
  return true;
}

/** stsd 内 encv/enca entry 去 sinf（frma 恢复 fourcc，内容前移补洞） */
function mp4StripStsdEncryption(buf: Uint8Array, stsd: QgMp4Box): boolean {
  const entryCount: number = mp4ReadU32(buf, stsd.bodyStart + 4);
  if (entryCount === 0) {
    return true;
  }
  // 逐 entry 检查；多 entry 时手术会破坏后续 entry 偏移，不支持
  let cursor: number = stsd.bodyStart + 8;
  for (let e: number = 0; e < entryCount; e++) {
    if (cursor + 8 > stsd.start + stsd.size) {
      return false;
    }
    const entrySize: number = mp4ReadU32(buf, cursor);
    if (entrySize < 8 || cursor + entrySize > stsd.start + stsd.size) {
      return false;
    }
    let fourcc: string = '';
    for (let i: number = 0; i < 4; i++) {
      fourcc += String.fromCharCode(buf[cursor + 4 + i]);
    }
    if (fourcc === 'encv' || fourcc === 'enca') {
      if (entryCount !== 1) {
        return false;
      }
      // VisualSampleEntry / AudioSampleEntry 的 body 前面是 78 / 28 字节固定字段，
      // 不是子 box。若从 cursor+8 直接遍历，会把 data_reference_index 前的 0 读成
      // size=0 的伪 box 并吞掉整个 entry，导致找不到 sinf、解密被判为「结构不支持」。
      const fixedFields: number = fourcc === 'encv' ? 78 : 28;
      const childrenStart: number = cursor + 8 + fixedFields;
      if (childrenStart > cursor + entrySize) {
        return false;
      }
      const children: QgMp4Box[] = mp4IterBoxes(buf, childrenStart, cursor + entrySize);
      let sinf: QgMp4Box | null = null;
      for (let i: number = 0; i < children.length; i++) {
        if (children[i].type === 'sinf') {
          sinf = children[i];
          break;
        }
      }
      if (sinf === null) {
        return false;
      }
      // frma 里的原始 fourcc（sinf/frma 后 4 字节）
      let originalFourcc: string = fourcc === 'encv' ? 'hvc1' : 'mp4a';
      const sinfChildren: QgMp4Box[] = mp4IterBoxes(buf, sinf.bodyStart, sinf.start + sinf.size);
      for (let i: number = 0; i < sinfChildren.length; i++) {
        if (sinfChildren[i].type === 'frma' &&
          sinfChildren[i].bodyStart + 4 <= sinfChildren[i].start + sinfChildren[i].size) {
          let frma: string = '';
          for (let k: number = 0; k < 4; k++) {
            frma += String.fromCharCode(buf[sinfChildren[i].bodyStart + k]);
          }
          if (frma.trim().length === 4) {
            originalFourcc = frma;
          }
          break;
        }
      }
      // sinf 之后的内容前移覆盖 sinf，尾部清零，entry size 缩小
      const sinfEnd: number = sinf.start + sinf.size;
      const entryEnd: number = cursor + entrySize;
      const tailLength: number = entryEnd - sinfEnd;
      if (tailLength > 0) {
        buf.copyWithin(sinf.start, sinfEnd, entryEnd);
      }
      for (let i: number = entryEnd - sinf.size; i < entryEnd; i++) {
        buf[i] = 0;
      }
      mp4WriteU32(buf, cursor, entrySize - sinf.size);
      mp4WriteFourcc(buf, cursor + 4, originalFourcc);
      return true;
    }
    cursor += entrySize;
  }
  return true;
}
