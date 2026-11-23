/**
 * 笔盒站源（兜底域名 https://bh4066.top；域名池由发布页 beabox.cc / beabox.live 动态发现）。
 * 发布页内嵌加密域名配置：__ENC_DOMAINS（base64）与 __KEY 逐字节异或解出真实 API 域名池；
 * 接口 envelope.data 为纯 hex 密文时用内置密钥 AES-128-CBC（前 16 字节 IV）解密。
 * 移植自 guoapp provider_beabox.go（域名发现/解密、目录、搜索、详情、播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBase64UrlDecode, qgBuildQuery, qgFromHex, qgUtf8Decode, qgUtf8Encode } from '../QgBytes';
import { qgAesCbcDecrypt } from '../QgCrypto';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const BASE_URL: string = 'https://bh4066.top';
const PUBLISH_URL: string = 'https://beabox.cc';
const PERMANENT_URL: string = 'https://beabox.live';
const UA: string = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const TAG_PREFIX: string = 'tag:';
const PAGE_SIZE: number = 20;
const TIMEOUT_MS: number = 15000;
const MAX_BODY_BYTES: number = 20 * 1024 * 1024;
const POOL_TTL_MS: number = 30 * 60 * 1000;
const POOL_RETRY_TTL_MS: number = 60 * 1000;
/** 接口 data 字段 AES-128-CBC 密钥（beaboxKeyHex） */
const CIPHER_KEY: Uint8Array = qgFromHex('f6322fa1c064370ea40c8cdc20649f8e');

const RE_ID: RegExp = /^[A-Za-z0-9]{1,64}$/;
const RE_HOST: RegExp = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?)+$/;
const RE_ENC_DOMAINS: RegExp = /__ENC_DOMAINS\s*=\s*["']([A-Za-z0-9+/=_-]+)["']/;
const RE_PAGE_KEY: RegExp = /__KEY\s*=\s*["']([^"']+)["']/;
const RE_EM_TAG: RegExp = /<\/?em\b[^>]*>/gi;
const RE_SCRIPT: RegExp = /<script\b[\s\S]*?<\/script>/gi;
const RE_STYLE: RegExp = /<style\b[\s\S]*?<\/style>/gi;
const RE_ANY_TAG: RegExp = /<[^>]+>/g;
const RE_SPACES: RegExp = /[\t\n\f\r ]+/g;
const RE_HEX: RegExp = /^[0-9a-fA-F]+$/;
const RE_INT: RegExp = /^[+-]?[0-9]+$/;
const RE_TAG_FORBIDDEN: RegExp = /[\|\/\\\x00\r\n]/;

/** 单次 HTTP 结果（beaboxFetch） */
class BbFetchResult {
  status: number = 0;
  data: Uint8Array = new Uint8Array(0);
}

/** beaboxCall 结果：解包后的 data + 命中站点 */
class BbCallResult {
  data: Object | null = null;
  site: string = '';
}

/** beaboxCall 一次成功命中：envelope + 站点 */
class BbEnvelopeHit {
  envelope: Record<string, Object> = {};
  site: string = '';
}

/** beaboxCall 轮换上下文（Go tried/lastErr/method/path/body） */
class BbCallContext {
  method: string = 'GET';
  path: string = '';
  body: Uint8Array | null = null;
  tried: Record<string, boolean> = {};
  lastError: Error | null = null;
}

/** 播放分组（vodPlaySource / vodPlay 的一个线路） */
class BbPlayGroup {
  name: string = '';
  entries: Record<string, Object>[] = [];
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function bbDecodeNumericEntities(text: string): string {
  let out: string = '';
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '&' && i + 2 < text.length) {
      let consumed: number = 0;
      let code: number = -1;
      if (text.charAt(i + 1) === '#' && text.charAt(i + 2) === 'x') {
        let j: number = i + 3;
        let hex: string = '';
        while (j < text.length && /[0-9a-fA-F]/.test(text.charAt(j))) {
          hex += text.charAt(j);
          j++;
        }
        if (hex.length > 0 && j < text.length && text.charAt(j) === ';') {
          code = parseInt(hex, 16);
          consumed = j + 1 - i;
        }
      } else if (text.charAt(i + 1) === '#') {
        let j: number = i + 2;
        let dec: string = '';
        while (j < text.length && /[0-9]/.test(text.charAt(j))) {
          dec += text.charAt(j);
          j++;
        }
        if (dec.length > 0 && j < text.length && text.charAt(j) === ';') {
          code = parseInt(dec, 10);
          consumed = j + 1 - i;
        }
      }
      if (consumed > 0 && code >= 0) {
        out += String.fromCharCode(code);
        i += consumed;
        continue;
      }
    }
    out += ch;
    i++;
  }
  return out;
}

/** HTML 实体解码（Go html.UnescapeString 的常用子集，多轮展开） */
function bbUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = bbDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go cleanText：去 script/style/标签 + 实体解码 + 空白折叠 */
function bbStripText(text: string): string {
  let out: string = text.replace(RE_SCRIPT, ' ');
  out = out.replace(RE_STYLE, ' ');
  out = out.replace(RE_ANY_TAG, ' ');
  out = bbUnescapeHtml(out);
  out = out.replace(RE_SPACES, ' ');
  return out.trim();
}

/** Go beaboxCleanText：双重实体解码 + 去 em 标签 + cleanText */
function bbCleanText(value: string): string {
  let out: string = bbUnescapeHtml(bbUnescapeHtml(value));
  out = out.replace(RE_EM_TAG, '');
  return bbStripText(out);
}

/** Go truncate：超长截断加省略号（按码点计数） */
function bbTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go firstNonEmpty：第一个非空（trim 后）值 */
function bbFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Go mapString：依次取第一个非空字符串字段（自动 trim） */
function bbMapString(row: Record<string, Object> | null, keys: string[]): string {
  if (row === null) {
    return '';
  }
  for (let i: number = 0; i < keys.length; i++) {
    const value: string = QgJson.str(row[keys[i]]);
    if (value.trim().length > 0) {
      return value.trim();
    }
  }
  return '';
}

/** mapStringSlice 的去重追加 */
function bbAddSlicePart(part: string, seen: Record<string, boolean>, out: string[]): void {
  const value: string = part.trim();
  if (value.length > 0 && seen[value] !== true) {
    seen[value] = true;
    out.push(value);
  }
}

/** Go mapStringSlice：字符串按 ,/，、 切分，数组取 name/title/label/tag */
function bbMapStringSlice(row: Record<string, Object> | null, keys: string[]): string[] {
  const seen: Record<string, boolean> = {};
  const out: string[] = [];
  if (row === null) {
    return out;
  }
  for (let k: number = 0; k < keys.length; k++) {
    const value: Object | undefined = row[keys[k]];
    if (value === undefined) {
      continue;
    }
    if (typeof value === 'string') {
      const parts: string[] = value.split(/[,/，、]/);
      for (let i: number = 0; i < parts.length; i++) {
        bbAddSlicePart(parts[i], seen, out);
      }
    } else if (Array.isArray(value)) {
      const items: Object[] = value as Object[];
      for (let i: number = 0; i < items.length; i++) {
        const entry: Record<string, Object> | null = QgJson.obj(items[i]);
        if (entry !== null) {
          bbAddSlicePart(bbMapString(entry, ['name', 'title', 'label', 'tag']), seen, out);
          continue;
        }
        bbAddSlicePart(QgJson.str(items[i]), seen, out);
      }
    }
  }
  return out;
}

/** Go validBeaboxID */
function bbValidID(id: string): boolean {
  return RE_ID.test(id.trim());
}

/** Go validBeaboxCategory：空串合法，其余必须 tag:<名称> */
function bbValidCategory(category: string): boolean {
  if (category.length === 0) {
    return true;
  }
  if (!category.startsWith(TAG_PREFIX)) {
    return false;
  }
  const tag: string = category.substring(TAG_PREFIX.length).trim();
  if (tag.length === 0 || Array.from(tag).length > 24) {
    return false;
  }
  return !RE_TAG_FORBIDDEN.test(tag);
}

/** Go beaboxTagName：取 tag: 前缀后的名称 */
function bbTagName(category: string): string {
  const stripped: string = category.startsWith(TAG_PREFIX) ?
    category.substring(TAG_PREFIX.length) : category;
  return stripped.trim();
}

/** Go beaboxFlag：bool / "1" / "true"（忽略大小写）/ 数字 1 */
function bbFlag(value: Object | undefined): boolean {
  if (value === true) {
    return true;
  }
  if (typeof value === 'string') {
    return value === '1' || value.toLowerCase() === 'true';
  }
  if (typeof value === 'number') {
    return value === 1;
  }
  return false;
}

/** Go webProviderInteger：解析 0..maximum 整数，失败返回 -1 */
function bbWebInteger(value: Object | undefined, maximum: number): number {
  let text: string = '';
  if (typeof value === 'string') {
    text = value.trim();
  } else if (typeof value === 'number') {
    text = `${Math.trunc(value)}`;
  } else {
    return -1;
  }
  if (!RE_INT.test(text)) {
    return -1;
  }
  const parsed: number = Number(text);
  if (parsed < 0 || parsed > maximum) {
    return -1;
  }
  return parsed;
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function bbIsHttpUrl(raw: string): boolean {
  const value: string = raw.trim();
  let rest: string = '';
  if (value.startsWith('http://')) {
    rest = value.substring(7);
  } else if (value.startsWith('https://')) {
    rest = value.substring(8);
  } else {
    return false;
  }
  let cut: number = rest.length;
  const slash: number = rest.indexOf('/');
  if (slash >= 0 && slash < cut) {
    cut = slash;
  }
  const question: number = rest.indexOf('?');
  if (question >= 0 && question < cut) {
    cut = question;
  }
  const hash: number = rest.indexOf('#');
  if (hash >= 0 && hash < cut) {
    cut = hash;
  }
  const hostPart: string = rest.substring(0, cut);
  if (hostPart.includes('@')) {
    return false;
  }
  const colon: number = hostPart.indexOf(':');
  const hostname: string = colon >= 0 ? hostPart.substring(0, colon) : hostPart;
  return hostname.length > 0;
}

/** 相对地址补全（url.ResolveReference 简化版，含 ./ 与 ../ 段处理） */
function bbCoverResolve(pageURL: string, ref: string): string {
  const value: string = ref.trim();
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
    return value;
  }
  const scheme: string = pageURL.startsWith('http://') ? 'http' : 'https';
  if (value.startsWith('//')) {
    return `${scheme}:${value}`;
  }
  let rest: string = pageURL;
  if (rest.startsWith('https://')) {
    rest = rest.substring(8);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring(7);
  }
  const slashIdx: number = rest.indexOf('/');
  const origin: string = slashIdx >= 0 ? rest.substring(0, slashIdx) : rest;
  const basePath: string = slashIdx >= 0 ? rest.substring(slashIdx) : '/';
  if (value.startsWith('/')) {
    return `${scheme}://${origin}${value}`;
  }
  let dir: string = basePath.substring(0, basePath.lastIndexOf('/') + 1);
  if (dir.length === 0) {
    dir = '/';
  }
  const combined: string = `${dir}${value}`;
  const parts: string[] = combined.split('/');
  const segments: string[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    const seg: string = parts[i];
    if (seg === '.') {
      continue;
    }
    if (seg === '..') {
      if (segments.length > 1) {
        segments.pop();
      }
      continue;
    }
    segments.push(seg);
  }
  const resolved: string = segments.join('/');
  return `${scheme}://${origin}${resolved.startsWith('/') ? resolved : `/${resolved}`}`;
}

/** Go providerCoverAddress：数组/对象/字符串取封面并相对补全 */
function bbCoverAddress(value: Object | undefined, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = bbCoverAddress(items[i], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
    return '';
  }
  if (typeof value === 'string') {
    const text: string = value.trim();
    if (text.length === 0) {
      return '';
    }
    const resolved: string = bbCoverResolve(pageURL, text);
    return bbIsHttpUrl(resolved) ? resolved : '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = bbCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** 发布页域名解密（parseBeaboxPublishPage）：__ENC_DOMAINS base64 → __KEY 异或 → 域名池 */
function bbParsePublishPage(body: string): string[] {
  const encoded: RegExpExecArray | null = RE_ENC_DOMAINS.exec(body);
  const keyMatch: RegExpExecArray | null = RE_PAGE_KEY.exec(body);
  if (encoded === null || keyMatch === null) {
    return [];
  }
  const encodedValue: string = encoded.length >= 2 ? encoded[1] : '';
  const keyValue: string = keyMatch.length >= 2 ? keyMatch[1] : '';
  if (encodedValue.length === 0 || keyValue.length === 0 || keyValue.length > 64) {
    return [];
  }
  const raw: Uint8Array = qgBase64UrlDecode(encodedValue);
  if (raw.length === 0 || raw.length > 1048576) {
    return [];
  }
  const keyBytes: Uint8Array = qgUtf8Encode(keyValue);
  for (let i: number = 0; i < raw.length; i++) {
    raw[i] = raw[i] ^ keyBytes[i % keyBytes.length];
  }
  const parsed: Object | null = QgJson.parse(qgUtf8Decode(raw));
  if (parsed === null || !Array.isArray(parsed)) {
    return [];
  }
  const hosts: Object[] = parsed as Object[];
  if (hosts.length > 256) {
    return [];
  }
  const sites: string[] = [];
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; i < hosts.length; i++) {
    const host: string = QgJson.str(hosts[i]).toLowerCase().trim();
    if (host.length === 0 || !RE_HOST.test(host) || seen[host] === true) {
      continue;
    }
    seen[host] = true;
    sites.push(`https://${host}`);
  }
  return sites;
}

/** Go parseBeaboxEnvelope：JSON 对象且含 code 字段 */
function bbParseEnvelope(data: Uint8Array): Record<string, Object> | null {
  const value: Object | null = QgJson.parse(qgUtf8Decode(data));
  const envelope: Record<string, Object> | null = QgJson.obj(value);
  if (envelope === null) {
    return null;
  }
  const code: Object | undefined = envelope['code'];
  if (code === undefined || code === null) {
    return null;
  }
  return envelope;
}

/** Go isBeaboxCiphertext：≥64 位偶数长度纯 hex */
function bbIsCiphertext(value: string): boolean {
  if (value.length < 64 || value.length % 2 !== 0) {
    return false;
  }
  return RE_HEX.test(value);
}

/** Go beaboxDecodeData：hex → AES-128-CBC（前 16 字节 IV）→ JSON */
function bbDecodeData(encoded: string): Object | null {
  const raw: Uint8Array = qgFromHex(encoded);
  if (raw.length < 32 || (raw.length - 16) % 16 !== 0) {
    return null;
  }
  const plain: Uint8Array = qgAesCbcDecrypt(raw.slice(16), CIPHER_KEY, raw.slice(0, 16));
  if (plain.length === 0) {
    return null;
  }
  return QgJson.parse(qgUtf8Decode(plain));
}

/** Go beaboxEnvelopeData：code 校验 + data 密文解包；业务失败抛中文错误 */
function bbEnvelopeData(envelope: Record<string, Object>): Object | null {
  const code: number = bbWebInteger(envelope['code'], 1000000);
  if (code !== 200) {
    let message: string = bbTruncate(bbStripText(bbMapString(envelope, ['msg'])), 180);
    if (message.length === 0) {
      message = '请稍后重试';
    }
    throw new Error(`笔盒请求未完成：${message}`);
  }
  const data: Object | undefined = envelope['data'];
  if (typeof data === 'string' && bbIsCiphertext(data)) {
    const decoded: Object | null = bbDecodeData(data);
    if (decoded === null) {
      throw new Error('笔盒接口数据解码失败');
    }
    return decoded;
  }
  return data === undefined ? null : data;
}

/** Go beaboxPlayValue：vodPlaySource / vodPlay 首个非空值 */
function bbPlayValue(row: Record<string, Object>): Object | null {
  const keys: string[] = ['vodPlaySource', 'vodPlay'];
  for (let i: number = 0; i < keys.length; i++) {
    const value: Object | undefined = row[keys[i]];
    if (value === undefined || value === null) {
      continue;
    }
    if (Array.isArray(value)) {
      const items: Object[] = value as Object[];
      if (items.length > 0) {
        return value;
      }
      continue;
    }
    if (typeof value === 'string') {
      if (value.trim().length > 0) {
        return value;
      }
      continue;
    }
    const map: Record<string, Object> | null = QgJson.obj(value);
    if (map !== null && Object.keys(map).length > 0) {
      return value;
    }
  }
  return null;
}

/** Go beaboxPlayEntries：数组 → 记录列表 */
function bbPlayEntries(value: Object | undefined): Record<string, Object>[] {
  const entries: Record<string, Object>[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return entries;
  }
  const rows: Object[] = value as Object[];
  for (let i: number = 0; i < rows.length; i++) {
    const entry: Record<string, Object> | null = QgJson.obj(rows[i]);
    if (entry !== null) {
      entries.push(entry);
    }
  }
  return entries;
}

/** Go beaboxPlayGroups：按结构归一为播放分组列表 */
function bbPlayGroups(value: Object | null): BbPlayGroup[] {
  const groups: BbPlayGroup[] = [];
  if (value === null) {
    return groups;
  }
  if (Array.isArray(value)) {
    const group: BbPlayGroup = new BbPlayGroup();
    group.entries = bbPlayEntries(value as Object[]);
    groups.push(group);
    return groups;
  }
  if (typeof value === 'string') {
    if (value.trim().length === 0) {
      return groups;
    }
    const group: BbPlayGroup = new BbPlayGroup();
    const entry: Record<string, Object> = { 'url': value };
    group.entries.push(entry);
    groups.push(group);
    return groups;
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map === null) {
    return groups;
  }
  const names: string[] = Object.keys(map).sort();
  for (let i: number = 0; i < names.length; i++) {
    const group: BbPlayGroup = new BbPlayGroup();
    group.name = names[i];
    group.entries = bbPlayEntries(map[names[i]]);
    groups.push(group);
  }
  return groups;
}

/** Go beaboxEntryPlayable：url / playUrl 非空 */
function bbEntryPlayable(entry: Record<string, Object>): boolean {
  const address: string = bbFirstNonEmpty([bbMapString(entry, ['url']), bbMapString(entry, ['playUrl'])]);
  return address.trim().length > 0;
}

/** Go beaboxBestGroup：可播条目最多者优先，平局偏爱 beabox-app */
function bbBestGroup(groups: BbPlayGroup[]): BbPlayGroup {
  let best: BbPlayGroup = new BbPlayGroup();
  let bestScore: number = -1;
  for (let i: number = 0; i < groups.length; i++) {
    const group: BbPlayGroup = groups[i];
    let score: number = 0;
    for (let j: number = 0; j < group.entries.length; j++) {
      if (bbEntryPlayable(group.entries[j])) {
        score++;
      }
    }
    if (score > bestScore ||
      (score === bestScore && group.name === 'beabox-app' && best.name !== 'beabox-app')) {
      best = group;
      bestScore = score;
    }
  }
  return best;
}

/** Go beaboxEntryAt：按分组名 + 下标取分集 */
function bbEntryAt(row: Record<string, Object>, group: string, index: number): Record<string, Object> | null {
  const groups: BbPlayGroup[] = bbPlayGroups(bbPlayValue(row));
  for (let i: number = 0; i < groups.length; i++) {
    if (groups[i].name === group && index >= 0 && index < groups[i].entries.length) {
      return groups[i].entries[index];
    }
  }
  return null;
}

/** Go beaboxTags：vodClass → 标签列表 */
function bbTags(row: Record<string, Object>): string[] {
  const tags: string[] = [];
  const seen: Record<string, boolean> = {};
  const values: string[] = bbMapStringSlice(row, ['vodClass']);
  for (let i: number = 0; i < values.length; i++) {
    const tag: string = bbCleanText(values[i]).trim();
    if (tag.length === 0 || Array.from(tag).length > 48 || seen[tag] === true) {
      continue;
    }
    seen[tag] = true;
    tags.push(tag);
    if (tags.length >= 32) {
      break;
    }
  }
  return tags;
}

/** Go beaboxDramaFromMap：行记录 → QgDrama（资料不完整返回 null） */
function bbDramaFromMap(row: Record<string, Object> | null, site: string,
  fallbackCategory: string): QgDrama | null {
  if (row === null) {
    return null;
  }
  const id: string = bbMapString(row, ['vodId']);
  const title: string = bbTruncate(bbCleanText(bbMapString(row, ['vodName'])), 512);
  if (!bbValidID(id) || title.length === 0) {
    return null;
  }
  const cover: string = bbCoverAddress(row['vodPic'], `${site}/`);
  let heatText: string = bbMapString(row, ['heatValue']);
  if (heatText === '0') {
    heatText = '';
  }
  const heat: number = heatText.length > 0 ? Number(heatText) : 0;
  const tags: string[] = bbTags(row);
  let category: string = fallbackCategory;
  if (tags.length > 0) {
    category = tags[0];
  }
  const drama: QgDrama = new QgDrama(`beabox:${id}`, title, category);
  drama.sourceId = 'beabox';
  drama.cover = cover;
  drama.tags = tags;
  drama.heat = Number.isNaN(heat) ? 0 : heat;
  return drama;
}

/** Go beaboxChapters：取最优线路生成分集（QgEpisode.id = "分组名:下标"） */
function bbEpisodes(row: Record<string, Object>): QgEpisode[] {
  const best: BbPlayGroup = bbBestGroup(bbPlayGroups(bbPlayValue(row)));
  const episodes: QgEpisode[] = [];
  for (let index: number = 0; index < best.entries.length; index++) {
    const entry: Record<string, Object> = best.entries[index];
    if (!bbEntryPlayable(entry)) {
      continue;
    }
    const key: string = `${best.name}:${index}`;
    let title: string = bbCleanText(bbMapString(entry, ['flag'])).trim();
    if (title.length === 0) {
      title = `第 ${episodes.length + 1} 集`;
    }
    episodes.push(new QgEpisode(key, bbTruncate(title, 128), episodes.length + 1));
  }
  return episodes;
}

export class BeaboxSource extends QgSource {
  /** 上次成功站点（会话内复用，Go beaboxSite） */
  private static preferredSite: string = '';
  /** 发布页发现的域名池（Go beaboxPool；会话内存，不做文件持久化） */
  private static pool: string[] = [];
  /** 池下次刷新时间（Go beaboxPoolNext） */
  private static poolNextAt: number = 0;
  /** 分类缓存（categories() 为同步签名，首次目录/搜索请求时异步填充） */
  private static categoryCache: QgCategory[] = [];

  constructor() {
    super('beabox', '笔盒');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < BeaboxSource.categoryCache.length; i++) {
      all.push(BeaboxSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.bbCatalogPage(categoryId, '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.bbCatalogPage('', keyword, page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceId: string = (dramaId.startsWith('beabox:') ?
      dramaId.substring('beabox:'.length) : dramaId).trim();
    if (!bbValidID(sourceId)) {
      throw new Error('笔盒视频 ID 无效');
    }
    const result: BbCallResult = await this.bbCall(`/vod/detail/${encodeURIComponent(sourceId)}`, {}, null);
    const row: Record<string, Object> | null = QgJson.obj(result.data);
    if (row === null || bbMapString(row, ['vodId']) !== sourceId) {
      throw new Error('笔盒详情与请求视频不符');
    }
    const drama: QgDrama | null = bbDramaFromMap(row, result.site, '');
    if (drama === null) {
      throw new Error('笔盒视频资料不完整');
    }
    const episodes: QgEpisode[] = bbEpisodes(row);
    if (episodes.length === 0) {
      throw new Error('笔盒该视频暂无可播放线路');
    }
    drama.episodeCount = episodes.length;
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceId: string = (dramaId.startsWith('beabox:') ?
      dramaId.substring('beabox:'.length) : dramaId).trim();
    if (!bbValidID(sourceId)) {
      throw new Error('笔盒播放信息无效，请刷新详情');
    }
    const separator: number = episodeId.lastIndexOf(':');
    if (separator < 0) {
      throw new Error('笔盒播放信息无效，请刷新详情');
    }
    const group: string = episodeId.substring(0, separator);
    const indexText: string = episodeId.substring(separator + 1);
    if (!RE_INT.test(indexText)) {
      throw new Error('笔盒播放信息无效，请刷新详情');
    }
    const index: number = Number(indexText);
    if (index < 0) {
      throw new Error('笔盒播放信息无效，请刷新详情');
    }
    const result: BbCallResult = await this.bbCall(`/vod/detail/${encodeURIComponent(sourceId)}`, {}, null);
    const row: Record<string, Object> | null = QgJson.obj(result.data);
    if (row === null) {
      throw new Error('笔盒详情格式无效');
    }
    const entry: Record<string, Object> | null = bbEntryAt(row, group, index);
    if (entry === null) {
      throw new Error('笔盒分集已变化，请刷新详情');
    }
    let address: string = bbFirstNonEmpty([bbMapString(entry, ['url']), bbMapString(entry, ['playUrl'])]);
    if (bbFlag(entry['needParse']) || bbFlag(row['playNeedParse'])) {
      const payload: Record<string, Object> = {
        'playerFrom': bbMapString(entry, ['from']),
        'playUrl': bbMapString(entry, ['playUrl'])
      };
      const parsed: BbCallResult = await this.bbCall('/vod/parse-url', {}, payload);
      const parsedMap: Record<string, Object> | null = QgJson.obj(parsed.data);
      address = parsedMap !== null ? bbMapString(parsedMap, ['url']) : '';
    }
    if (!bbIsHttpUrl(address)) {
      throw new Error('笔盒未返回有效播放地址，请刷新详情后重试');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${result.site}/`;
    info.headers = { 'Referer': info.referer, 'User-Agent': UA };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    const site: string = BeaboxSource.preferredSite.length > 0 ? BeaboxSource.preferredSite : BASE_URL;
    return { 'User-Agent': UA, 'Referer': `${site}/` };
  }

  /** Go beaboxKnownSites：上次成功站点 + 兜底域名（应用无 BeaboxURL 自定义配置项） */
  private bbKnownSites(): string[] {
    const sites: string[] = [];
    const candidates: string[] = [BeaboxSource.preferredSite, BASE_URL];
    for (let i: number = 0; i < candidates.length; i++) {
      const value: string = candidates[i].trim().replace(/\/+$/, '');
      if (value.length > 0 && !sites.includes(value)) {
        sites.push(value);
      }
    }
    return sites;
  }

  /** Go beaboxFetch：统一 UA / Accept-Language / Referer（POST 加 JSON 头） */
  private async bbFetch(method: string, address: string, referer: string,
    payload: Uint8Array | null): Promise<BbFetchResult> {
    const headers: Record<string, string> = {
      'User-Agent': UA,
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer
    };
    if (payload !== null) {
      headers['Content-Type'] = 'application/json';
      headers['Accept'] = 'application/json';
    }
    const resp: QgHttpResponse = await QgHttp.request(address, method, headers, payload, TIMEOUT_MS, 0, 30, this.id);
    if (resp.data.length > MAX_BODY_BYTES) {
      throw new Error('笔盒返回的数据过大');
    }
    const result: BbFetchResult = new BbFetchResult();
    result.status = resp.status;
    result.data = resp.data;
    return result;
  }

  /** Go discoverBeaboxSites：依次抓发布页并解密域名池 */
  private async bbDiscoverSites(): Promise<string[]> {
    const seeds: string[] = [PUBLISH_URL, PERMANENT_URL];
    for (let i: number = 0; i < seeds.length; i++) {
      const seed: string = seeds[i];
      try {
        const result: BbFetchResult = await this.bbFetch('GET', `${seed}/`, `${seed}/`, null);
        if (result.status < 200 || result.status >= 300) {
          continue;
        }
        const sites: string[] = bbParsePublishPage(qgUtf8Decode(result.data));
        if (sites.length > 0) {
          return sites;
        }
      } catch (error) {
        continue;
      }
    }
    return [];
  }

  /** Go beaboxDiscoveredSites：域名池 30 分钟缓存，失败 1 分钟后重试 */
  private async bbDiscoveredSites(): Promise<string[]> {
    const now: number = Date.now();
    if (now >= BeaboxSource.poolNextAt) {
      const sites: string[] = await this.bbDiscoverSites();
      if (sites.length > 0) {
        BeaboxSource.pool = sites;
        BeaboxSource.poolNextAt = now + POOL_TTL_MS;
      } else {
        BeaboxSource.poolNextAt = now + POOL_RETRY_TTL_MS;
      }
    }
    return BeaboxSource.pool;
  }

  /** Go beaboxCall：先试已知站点，再试发现池；成功记忆站点并解包 envelope */
  private async bbCall(route: string, query: Record<string, string>,
    payload: Record<string, Object> | null): Promise<BbCallResult> {
    const ctx: BbCallContext = new BbCallContext();
    ctx.path = `/api${route}`;
    if (Object.keys(query).length > 0) {
      ctx.path += `?${qgBuildQuery(query)}`;
    }
    if (payload !== null) {
      ctx.method = 'POST';
      ctx.body = qgUtf8Encode(JSON.stringify(payload));
    }
    let hit: BbEnvelopeHit | null = await this.bbAttempt(ctx, this.bbKnownSites());
    if (hit === null) {
      hit = await this.bbAttempt(ctx, await this.bbDiscoveredSites());
    }
    if (hit === null) {
      throw ctx.lastError !== null ? ctx.lastError : new Error('笔盒线路暂不可用，请稍后重试');
    }
    BeaboxSource.preferredSite = hit.site;
    const result: BbCallResult = new BbCallResult();
    result.site = hit.site;
    result.data = bbEnvelopeData(hit.envelope);
    return result;
  }

  private async bbAttempt(ctx: BbCallContext, sites: string[]): Promise<BbEnvelopeHit | null> {
    for (let i: number = 0; i < sites.length; i++) {
      const site: string = sites[i];
      if (ctx.tried[site] === true) {
        continue;
      }
      ctx.tried[site] = true;
      try {
        const response: BbFetchResult = await this.bbFetch(ctx.method, `${site}${ctx.path}`,
          `${site}/home`, ctx.body);
        const envelope: Record<string, Object> | null = bbParseEnvelope(response.data);
        if (envelope === null) {
          ctx.lastError = new Error(`笔盒线路 ${site.replace(/^https:\/\//, '')} 不可用（HTTP ${response.status}）`);
          continue;
        }
        const hit: BbEnvelopeHit = new BbEnvelopeHit();
        hit.envelope = envelope;
        hit.site = site;
        return hit;
      } catch (error) {
        ctx.lastError = error as Error;
      }
    }
    return null;
  }

  /** 目录/搜索共用的分页取数（fetchBeaboxCatalogPage） */
  private async bbCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000 || query.length > 256 || !bbValidCategory(category)) {
      throw new Error('笔盒目录查询参数无效');
    }
    await this.bbEnsureCategories();
    let keyword: string = query.trim();
    let fallbackCategory: string = '';
    if (keyword.length === 0) {
      fallbackCategory = bbTagName(category);
      keyword = fallbackCategory;
    }
    let route: string = '/vod/latest';
    const values: Record<string, string> = {
      'page': `${page}`,
      'limit': `${PAGE_SIZE}`
    };
    if (keyword.length > 0) {
      route = '/vod/search';
      values['keyword'] = keyword;
      values['sort'] = 'latest';
    }
    const result: BbCallResult = await this.bbCall(route, values, null);
    const payload: Record<string, Object> | null = QgJson.obj(result.data);
    if (payload === null) {
      throw new Error('笔盒目录格式无效');
    }
    let rows: Object[] = [];
    const raw: Object | undefined = payload['data'];
    if (raw !== undefined && raw !== null) {
      if (!Array.isArray(raw)) {
        throw new Error('笔盒目录格式无效');
      }
      rows = raw as Object[];
    }
    if (rows.length > 500) {
      throw new Error('笔盒目录格式无效');
    }
    const totalPages: number = bbWebInteger(payload['totalPages'], 1000000);
    let hasMore: boolean = rows.length >= PAGE_SIZE;
    if (totalPages >= 0) {
      hasMore = page < totalPages;
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = bbDramaFromMap(QgJson.obj(rows[i]), result.site, fallbackCategory);
      if (drama === null || seen[drama.id] === true) {
        continue;
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return new QgPageResult(items, hasMore);
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async bbEnsureCategories(): Promise<void> {
    if (BeaboxSource.categoryCache.length > 0) {
      return;
    }
    try {
      BeaboxSource.categoryCache = await this.bbFetchCategories();
    } catch (error) {
      // 分类获取失败不阻塞目录；下次分页请求再试
    }
  }

  /** Go fetchBeaboxCategories：/configs 的 home_tags → tag 分类 */
  private async bbFetchCategories(): Promise<QgCategory[]> {
    const result: BbCallResult = await this.bbCall('/configs', { 'platformType': 'h5' }, null);
    const config: Record<string, Object> | null = QgJson.obj(result.data);
    if (config === null) {
      throw new Error('笔盒分类数据格式无效');
    }
    const homeTags: string = bbMapString(config, ['home_tags']);
    const categories: QgCategory[] = [];
    const seen: Record<string, boolean> = {};
    const names: string[] = homeTags.split(',');
    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i].trim();
      const id: string = `${TAG_PREFIX}${name}`;
      if (name.length === 0 || Array.from(name).length > 24 ||
        seen[id] === true || !bbValidCategory(id)) {
        continue;
      }
      seen[id] = true;
      categories.push(new QgCategory(id, name));
      if (categories.length >= 64) {
        break;
      }
    }
    if (categories.length === 0) {
      throw new Error('笔盒暂未返回内容分类');
    }
    return categories;
  }
}
