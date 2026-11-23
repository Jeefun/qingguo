/**
 * 野果站源（内置入口 https://attract.vgbyziuz.cc；线路由备份域名与中转页 ygdj15.com 动态发现）。
 * 首页 __NUXT_DATA__ 提供可选 apiBase；入口/模块脚本内嵌公开配置（version/mode/padding/key/iv/sign_key），
 * key/iv/sign_key 支持下划线分隔十进制字节；envelope.data 为 AES-128-CBC base64 密文（空格代 '+'），
 * sign = md5hex(sha256hex(排序字段拼接 + signKey))；/api/playlet/play 返回直连播放地址。
 * 移植自 guoapp provider_yeguo.go / provider_yeguo_client.go（域名/密钥发现、目录、搜索、详情、播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBase64Decode, qgBuildQuery, qgConcat, qgRandomHex, qgToHex, qgUtf8Decode, qgUtf8Encode } from '../QgBytes';
import { qgAesCbcDecrypt, qgMd5, qgSha256 } from '../QgCrypto';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const YG_BASE_URL: string = 'https://attract.vgbyziuz.cc';
const YG_TRANSIT_URL: string = 'https://ygdj15.com';
const YG_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
const YG_PAGE_SIZE: number = 20;
const YG_ACCESS_TTL_MS: number = 60 * 60 * 1000;
const YG_API_TIMEOUT_MS: number = 30000;
const YG_PAGE_TIMEOUT_MS: number = 25000;
const YG_MAX_API_BYTES: number = 8 * 1024 * 1024;
const YG_MAX_PAGE_CHARS: number = 4 * 1024 * 1024;
const YG_MAX_SCRIPT_CHARS: number = 20 * 1024 * 1024;
/** 站内数字 ID（webProviderNumericID） */
const YG_RE_NUMERIC_ID: RegExp = /^[1-9][0-9]{0,17}$/;
const YG_RE_INT: RegExp = /^[+-]?[0-9]+$/;
const YG_RE_SCHEME_PREFIX: RegExp = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;
/** <script ...>...</script> 扫描（发现页脚本标签） */
const YG_RE_SCRIPT_TAG: RegExp = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
/** 标签属性键值对（id/type/src 提取） */
const YG_RE_ATTR: RegExp = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>\x60]+))/g;
/** ES import 语句（入口脚本的模块依赖） */
const YG_RE_MODULE_IMPORT: RegExp = /import\s*\{([^{};]+)\}\s*from\s*["'\x60]([^"'\x60]+)["'\x60]/g;
/** baseURL:NAME(x) 调用点（脚本内接口地址线索） */
const YG_RE_SCRIPT_BASE_CALL: RegExp = /baseURL:([a-zA-Z_$][a-zA-Z0-9_$]*)\([a-zA-Z_$]?[a-zA-Z0-9_$]*\)/g;
/** 公开配置字段（version/mode/padding/key/iv/sign_key） */
const YG_RE_PUBLIC_FIELD: RegExp =
  /\b(version|mode|padding|key|iv|sign_key)\s*:\s*(?:[a-zA-Z_$][a-zA-Z0-9_$]*\(\s*)?["'\x60]([^"'\x60\\\r\n]{1,512})["'\x60]/g;
/** 中转页 Base64 段（域名池密文线索） */
const YG_RE_TRANSIT_BASE64: RegExp = /Base64\.decode\(["']([A-Za-z0-9+/=]{128,})["']\)/g;
/** 中转页后缀拼接（".xxx.cc" 字面量） */
const YG_RE_TRANSIT_SUFFIX: RegExp = /\+\s*["']\.([a-z0-9-]+(?:\.[a-z0-9-]+)+)["']/gi;
/** 中转页种子词表（words = "a,b,c".split(",")） */
const YG_RE_TRANSIT_WORDS: RegExp = /\bwords\s*=\s*["']([^"']+)["']\s*\.split\(["'],["']\)/;
/** 中转页明文 URL 字面量 */
const YG_RE_TRANSIT_LITERAL: RegExp = /https?:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)+\/?/g;
/** 种子词 / 主机段合法形态 */
const YG_RE_HOST_LABEL: RegExp = /^[a-z0-9][a-z0-9-]{0,62}$/;
/** cleanText 用标签剔除正则 */
const YG_RE_CLEAN_SCRIPT: RegExp = /<script\b[\s\S]*?<\/script>/gi;
const YG_RE_CLEAN_STYLE: RegExp = /<style\b[\s\S]*?<\/style>/gi;
const YG_RE_ANY_TAG: RegExp = /<[^>]+>/g;
const YG_RE_SPACES: RegExp = /[\t\n\f\r ]+/g;
/** 分类字段顺序（video_filter） */
const YG_FILTER_FIELDS: string[] = ['theme', 'setting', 'background', 'time', 'recommend'];
/** 备用入口（yeguoBackupSites） */
const YG_BACKUP_SITES: string[] = ['https://as.vgbyziuz.cc', 'https://anyway.vgbyziuz.cc',
  'https://analyze.buxefaex.cc'];

/** 野果接口访问配置（yeguoAccess） */
class YgAccess {
  base: string = '';
  site: string = '';
  key: Uint8Array = new Uint8Array(0);
  iv: Uint8Array = new Uint8Array(0);
  signKey: Uint8Array = new Uint8Array(0);
  identifier: string = '';
  loadedAt: number = 0;
}

/** yeguoFlag 结果：value + 是否可识别 */
class YgFlagResult {
  value: boolean = false;
  known: boolean = false;
}

/** ES import 依赖（names + 模块路径） */
class YgModuleImport {
  names: string = '';
  path: string = '';
}

/** script 标签（属性原文 + 内联内容） */
class YgScriptTag {
  attrs: string = '';
  content: string = '';
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function ygDecodeNumericEntities(text: string): string {
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
function ygUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = ygDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go cleanText：去 script/style/标签 + 实体解码 + 空白折叠 */
function ygCleanText(text: string): string {
  let out: string = text.replace(YG_RE_CLEAN_SCRIPT, ' ');
  out = out.replace(YG_RE_CLEAN_STYLE, ' ');
  out = out.replace(YG_RE_ANY_TAG, ' ');
  out = ygUnescapeHtml(out);
  out = out.replace(YG_RE_SPACES, ' ');
  return out.trim();
}

/** Go truncate：超长截断加省略号（按码点计数） */
function ygTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go firstNonEmpty：第一个非空（trim 后）值 */
function ygFirstNonEmptyText(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Go nativeText：字符串 trim / 数字转文本，其余为空 */
function ygNativeText(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  if (typeof value === 'number') {
    return `${value}`;
  }
  return '';
}

/** Go mapString：依次取第一个非空字符串字段（自动 trim） */
function ygMapString(row: Record<string, Object> | null, keys: string[]): string {
  if (row === null) {
    return '';
  }
  for (let i: number = 0; i < keys.length; i++) {
    const value: Object | undefined = row[keys[i]];
    if (value === undefined || value === null) {
      continue;
    }
    if (typeof value === 'string') {
      const text: string = value.trim();
      if (text.length > 0) {
        return text;
      }
      continue;
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    if (typeof value === 'number') {
      return `${value}`;
    }
  }
  return '';
}

/** Go webProviderInteger：解析 0..maximum 整数，失败返回 -1 */
function ygInteger(value: Object | undefined, maximum: number): number {
  const text: string = ygNativeText(value);
  if (text.length === 0 || !YG_RE_INT.test(text)) {
    return -1;
  }
  const parsed: number = Number(text);
  if (parsed < 0 || parsed > maximum) {
    return -1;
  }
  return parsed;
}

/** Go yeguoFlag：bool / "0"/"false" / "1"/"true"，无法识别时 known=false */
function ygFlag(value: Object | undefined): YgFlagResult {
  const result: YgFlagResult = new YgFlagResult();
  if (typeof value === 'boolean') {
    result.value = value;
    result.known = true;
    return result;
  }
  const text: string = ygNativeText(value);
  if (text === '0' || text === 'false') {
    result.value = false;
    result.known = true;
    return result;
  }
  if (text === '1' || text === 'true') {
    result.value = true;
    result.known = true;
    return result;
  }
  return result;
}

/** Go firstPresent：第一个存在、非 null 且文本非空的字段值 */
function ygFirstPresent(row: Record<string, Object> | null, keys: string[]): Object | undefined {
  if (row === null) {
    return undefined;
  }
  for (let i: number = 0; i < keys.length; i++) {
    const value: Object | undefined = row[keys[i]];
    if (value !== undefined && value !== null && ygNativeText(value) !== '') {
      return value;
    }
  }
  return undefined;
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function ygIsHttpUrl(raw: string): boolean {
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

/** URL → 小写主机名（去端口） */
function ygHostnameOf(raw: string): string {
  const value: string = raw.trim();
  let rest: string = '';
  if (value.startsWith('https://')) {
    rest = value.substring(8);
  } else if (value.startsWith('http://')) {
    rest = value.substring(7);
  } else {
    return '';
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
  let hostPart: string = rest.substring(0, cut);
  const at: number = hostPart.indexOf('@');
  if (at >= 0) {
    hostPart = hostPart.substring(at + 1);
  }
  const colon: number = hostPart.indexOf(':');
  const hostname: string = colon >= 0 ? hostPart.substring(0, colon) : hostPart;
  return hostname.toLowerCase();
}

/** Go providerMediaOrigin：scheme://host（小写、去默认端口） */
function ygOriginOf(raw: string): string {
  const value: string = raw.trim();
  let scheme: string = '';
  let rest: string = '';
  if (value.startsWith('https://')) {
    scheme = 'https';
    rest = value.substring(8);
  } else if (value.startsWith('http://')) {
    scheme = 'http';
    rest = value.substring(7);
  } else {
    return '';
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
  let host: string = rest.substring(0, cut).toLowerCase();
  if (scheme === 'https' && host.endsWith(':443')) {
    host = host.substring(0, host.length - 4);
  } else if (scheme === 'http' && host.endsWith(':80')) {
    host = host.substring(0, host.length - 3);
  }
  return `${scheme}://${host}`;
}

/** URL → 路径（不含 query/fragment） */
function ygPathOf(raw: string): string {
  const value: string = raw.trim();
  let rest: string = '';
  if (value.startsWith('https://')) {
    rest = value.substring(8);
  } else if (value.startsWith('http://')) {
    rest = value.substring(7);
  } else {
    return '';
  }
  const slash: number = rest.indexOf('/');
  if (slash < 0) {
    return '';
  }
  let path: string = rest.substring(slash);
  let cut: number = path.length;
  const question: number = path.indexOf('?');
  if (question >= 0 && question < cut) {
    cut = question;
  }
  const hash: number = path.indexOf('#');
  if (hash >= 0 && hash < cut) {
    cut = hash;
  }
  return path.substring(0, cut);
}

/** 相对地址补全（url.ResolveReference 简化版，含 ./ 与 ../ 段处理，保留 query/fragment） */
function ygResolveUrl(base: string, ref: string): string {
  const value: string = ref.trim();
  if (value.length === 0) {
    return base;
  }
  if (YG_RE_SCHEME_PREFIX.test(value)) {
    return value;
  }
  const scheme: string = base.startsWith('http://') ? 'http' : 'https';
  if (value.startsWith('//')) {
    return `${scheme}:${value}`;
  }
  let rest: string = base;
  if (rest.startsWith('https://')) {
    rest = rest.substring(8);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring(7);
  }
  const slashIdx: number = rest.indexOf('/');
  const origin: string = slashIdx >= 0 ? rest.substring(0, slashIdx) : rest;
  const basePath: string = slashIdx >= 0 ? rest.substring(slashIdx) : '/';
  const baseDir: string = basePath.substring(0, basePath.lastIndexOf('/') + 1);
  const combined: string = value.startsWith('/') ? value : `${baseDir.length > 0 ? baseDir : '/'}${value}`;
  let working: string = combined;
  let suffix: string = '';
  let cutIdx: number = -1;
  const qIdx: number = combined.indexOf('?');
  const hIdx: number = combined.indexOf('#');
  if (qIdx >= 0 && hIdx >= 0) {
    cutIdx = Math.min(qIdx, hIdx);
  } else if (qIdx >= 0) {
    cutIdx = qIdx;
  } else if (hIdx >= 0) {
    cutIdx = hIdx;
  }
  if (cutIdx >= 0) {
    working = combined.substring(0, cutIdx);
    suffix = combined.substring(cutIdx);
  }
  const parts: string[] = working.split('/');
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
  let path: string = segments.join('/');
  if (!path.startsWith('/')) {
    path = `/${path}`;
  }
  return `${scheme}://${origin}${path}${suffix}`;
}

/** 提取全部 script 标签（属性原文 + 内联内容） */
function ygScriptTags(body: string): YgScriptTag[] {
  const tags: YgScriptTag[] = [];
  YG_RE_SCRIPT_TAG.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_SCRIPT_TAG.exec(body);
  while (match !== null) {
    const tag: YgScriptTag = new YgScriptTag();
    tag.attrs = match[1];
    tag.content = match[2];
    tags.push(tag);
    match = YG_RE_SCRIPT_TAG.exec(body);
  }
  return tags;
}

/** 标签属性取值（等价 Go providerHTMLAttr，值做实体解码） */
function ygTagAttr(attrs: string, name: string): string {
  YG_RE_ATTR.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_ATTR.exec(attrs);
  while (match !== null) {
    if (match[1] === name) {
      let value: string = '';
      if (match[2] !== undefined) {
        value = match[2];
      } else if (match[3] !== undefined) {
        value = match[3];
      } else if (match[4] !== undefined) {
        value = match[4];
      }
      return ygUnescapeHtml(value);
    }
    match = YG_RE_ATTR.exec(attrs);
  }
  return '';
}

/** Go regexp.QuoteMeta：非字母数字下划线全部转义 */
function ygQuoteMeta(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (/[A-Za-z0-9_]/.test(ch)) {
      out += ch;
    } else {
      out += `\\${ch}`;
    }
  }
  return out;
}

/** 野果 URL 判定（providerSourceForURL 的 yeguo 分支） */
function ygSourceForURL(raw: string): string {
  const host: string = ygHostnameOf(raw);
  if (host === '') {
    return '';
  }
  if (host === 'ygdj7.com' || host === 'www.ygdj7.com' || host === 'ygdj15.com' || host === 'www.ygdj15.com' ||
    host === 'analyze.buxefaex.cc' || host === 'delta.ygrwdsgt.cc' ||
    host === 'yeguodj.com' || host === 'www.yeguodj.com' ||
    host.endsWith('.buxefaex.cc') || host.endsWith('.fzchosdi.cc') ||
    host.endsWith('.lwblvxvy.cc') || host.endsWith('.vgbyziuz.cc')) {
    return 'yeguo';
  }
  return '';
}

/** Go validYeguoSite：野果域名、无查询/非空 fragment、路径为空，返回去尾斜杠地址 */
function ygValidSite(raw: string): string {
  const value: string = raw.trim();
  if (!ygIsHttpUrl(value)) {
    return '';
  }
  if (value.includes('?')) {
    return '';
  }
  const hashIdx: number = value.indexOf('#');
  if (hashIdx >= 0 && value.substring(hashIdx + 1).length > 0) {
    return '';
  }
  if (ygSourceForURL(value) !== 'yeguo') {
    return '';
  }
  const path: string = ygPathOf(value);
  if (path.replace(/\/+$/, '') !== '') {
    return '';
  }
  return value.replace(/\/+$/, '');
}

/** Go isYeguoActiveSite：当前活跃野果线路域名 */
function ygIsActiveSite(raw: string): boolean {
  const host: string = ygHostnameOf(raw);
  return host === 'analyze.buxefaex.cc' || host.endsWith('.buxefaex.cc') || host.endsWith('.fzchosdi.cc') ||
    host.endsWith('.lwblvxvy.cc') || host.endsWith('.vgbyziuz.cc');
}

/** Go yeguoValidAPIBase：http(s)、无查询/fragment，返回去尾斜杠地址 */
function ygValidApiBase(base: string): string {
  const value: string = base.trim();
  if (!ygIsHttpUrl(value)) {
    return '';
  }
  if (value.includes('?') || value.includes('#')) {
    return '';
  }
  return value.replace(/\/+$/, '');
}

/** __NUXT_DATA__ 中提取 apiBase（yeguoAPIBase 的 NUXT 分支） */
function ygApiBaseFromNuxt(body: string): string {
  const tags: YgScriptTag[] = ygScriptTags(body);
  for (let t: number = 0; t < tags.length; t++) {
    if (ygTagAttr(tags[t].attrs, 'id') !== '__NUXT_DATA__') {
      continue;
    }
    const text: string = tags[t].content;
    if (text.trim().length === 0) {
      continue;
    }
    const parsed: Object | null = QgJson.parse(text);
    if (parsed === null || !Array.isArray(parsed)) {
      continue;
    }
    const table: Object[] = parsed as Object[];
    if (table.length > 100000) {
      continue;
    }
    for (let i: number = 0; i < table.length; i++) {
      const fields: Record<string, Object> | null = QgJson.obj(table[i]);
      if (fields === null) {
        continue;
      }
      const reference: Object | undefined = fields['apiBaseURL'];
      if (reference === undefined || reference === null) {
        continue;
      }
      if (typeof reference !== 'number' || !Number.isInteger(reference) ||
        reference < 0 || reference >= table.length) {
        continue;
      }
      const target: Object = table[reference];
      if (typeof target === 'string' && target.length > 0) {
        return target;
      }
    }
  }
  return '';
}

/** Go yeguoScriptAPIBase：脚本内 baseURL 函数字面量 / 同源 api.php 模板提取 */
function ygScriptAPIBase(script: string, origin: string): string {
  const names: string[] = [];
  YG_RE_SCRIPT_BASE_CALL.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_SCRIPT_BASE_CALL.exec(script);
  while (match !== null && names.length < 16) {
    names.push(match[1]);
    match = YG_RE_SCRIPT_BASE_CALL.exec(script);
  }
  for (let i: number = 0; i < names.length; i++) {
    const definition: string = `(?:^|[^a-zA-Z0-9_$.])${ygQuoteMeta(names[i])}=`;
    const literal: RegExp =
      new RegExp(`${definition}\\(\\)=>["'\\x60](https?://[^"'\\x60\\s]{1,512})["'\\x60]`);
    const literalMatch: RegExpExecArray | null = literal.exec(script);
    if (literalMatch !== null) {
      const base: string = ygValidApiBase(literalMatch[1]);
      if (base !== '') {
        return base;
      }
    }
    if (origin.length === 0) {
      continue;
    }
    const sameOrigin: RegExp =
      new RegExp(`${definition}\\([^()]{0,40}\\)=>\\{[\\s\\S]{0,400}?origin:([a-zA-Z_$][a-zA-Z0-9_$]*)` +
        `[\\s\\S]{0,400}?\\x60\\$\\{([a-zA-Z_$][a-zA-Z0-9_$]*)\\}/api\\.php\\x60`);
    const sameMatch: RegExpExecArray | null = sameOrigin.exec(script);
    if (sameMatch !== null && sameMatch[1] === sameMatch[2]) {
      const base: string = ygValidApiBase(`${origin}/api.php`);
      if (base !== '') {
        return base;
      }
    }
  }
  return '';
}

/** Go yeguoScriptURL：同源 /_nuxt/*.js 模块地址（去 fragment，保留 query） */
function ygScriptURL(base: string, reference: string): string {
  const page: string = base.trim();
  if (!ygIsHttpUrl(page)) {
    return '';
  }
  const resolved: string = ygResolveUrl(page, reference.trim());
  if (!ygIsHttpUrl(resolved)) {
    return '';
  }
  if (ygOriginOf(resolved) !== ygOriginOf(page)) {
    return '';
  }
  const path: string = ygPathOf(resolved);
  if (!path.startsWith('/_nuxt/') || !path.endsWith('.js')) {
    return '';
  }
  const hashIdx: number = resolved.indexOf('#');
  return hashIdx >= 0 ? resolved.substring(0, hashIdx) : resolved;
}

/** Go yeguoPublicBytes：含 '_' 时按下划线分隔十进制字节（0-255）解码 */
function ygPublicBytes(value: string): Uint8Array | null {
  if (!value.includes('_')) {
    return qgUtf8Encode(value);
  }
  const parts: string[] = value.split('_');
  const out: number[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (!/^[0-9]{1,3}$/.test(part)) {
      return null;
    }
    const number: number = Number(part);
    if (number > 255) {
      return null;
    }
    out.push(number);
  }
  return Uint8Array.from(out);
}

/** Go parseYeguoPublicConfiguration：脚本内公开配置 → 密钥组（不匹配返回 null） */
function ygParsePublicConfig(script: string): YgAccess | null {
  const fields: Record<string, string> = {};
  YG_RE_PUBLIC_FIELD.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_PUBLIC_FIELD.exec(script);
  let count: number = 0;
  while (match !== null && count < 32) {
    fields[match[1]] = match[2];
    count++;
    match = YG_RE_PUBLIC_FIELD.exec(script);
  }
  const version: string = fields['version'] ?? '';
  const mode: string = fields['mode'] ?? '';
  const padding: string = fields['padding'] ?? '';
  if (version !== 'v0' || mode !== 'CBC' || padding !== 'Pkcs7') {
    return null;
  }
  const key: Uint8Array | null = ygPublicBytes(fields['key'] ?? '');
  const iv: Uint8Array | null = ygPublicBytes(fields['iv'] ?? '');
  const signKey: Uint8Array | null = ygPublicBytes(fields['sign_key'] ?? '');
  if (key === null || iv === null || signKey === null) {
    return null;
  }
  if ((key.length !== 16 && key.length !== 24 && key.length !== 32) ||
    iv.length !== 16 || signKey.length === 0 || signKey.length > 128) {
    return null;
  }
  const access: YgAccess = new YgAccess();
  access.key = key;
  access.iv = iv;
  access.signKey = signKey;
  return access;
}

/** 入口脚本的 import 依赖列表（≤64 个） */
function ygModuleImports(body: string): YgModuleImport[] {
  const imports: YgModuleImport[] = [];
  YG_RE_MODULE_IMPORT.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_MODULE_IMPORT.exec(body);
  while (match !== null && imports.length < 64) {
    const entry: YgModuleImport = new YgModuleImport();
    entry.names = match[1];
    entry.path = match[2];
    imports.push(entry);
    match = YG_RE_MODULE_IMPORT.exec(body);
  }
  return imports;
}

/** Go yeguoTransitDecodedText：正文 + Base64 解码段拼接 */
function ygTransitDecodedText(body: string): string {
  const parts: string[] = [body];
  YG_RE_TRANSIT_BASE64.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_TRANSIT_BASE64.exec(body);
  let count: number = 0;
  while (match !== null && count < 4) {
    parts.push(qgUtf8Decode(qgBase64Decode(match[1])));
    count++;
    match = YG_RE_TRANSIT_BASE64.exec(body);
  }
  return parts.join('\n');
}

/** 种子词去重追加（≤4 个） */
function ygAddSeedWord(word: string, seen: Record<string, boolean>, words: string[]): void {
  const value: string = word.toLowerCase().trim();
  if (YG_RE_HOST_LABEL.test(value) && seen[value] !== true && words.length < 4) {
    seen[value] = true;
    words.push(value);
  }
}

/** Go yeguoTransitSeedWords：优先 analyze/ability/abandon，最多 4 个 */
function ygTransitSeedWords(text: string): string[] {
  const words: string[] = [];
  const seen: Record<string, boolean> = {};
  const all: string[] = [];
  const match: RegExpExecArray | null = YG_RE_TRANSIT_WORDS.exec(text);
  if (match !== null && match.length > 1) {
    if (match[1].length > 20000) {
      return ['analyze'];
    }
    const parts: string[] = match[1].split(',');
    for (let i: number = 0; i < parts.length; i++) {
      const cleaned: string = parts[i].toLowerCase().trim();
      if (YG_RE_HOST_LABEL.test(cleaned)) {
        all.push(cleaned);
      }
    }
  }
  const available: Record<string, boolean> = {};
  for (let i: number = 0; i < all.length; i++) {
    available[all[i]] = true;
  }
  const preferred: string[] = ['analyze', 'ability', 'abandon'];
  for (let i: number = 0; i < preferred.length; i++) {
    if (all.length === 0 || available[preferred[i]] === true) {
      ygAddSeedWord(preferred[i], seen, words);
    }
  }
  for (let i: number = 0; i < all.length; i++) {
    ygAddSeedWord(all[i], seen, words);
  }
  if (words.length === 0) {
    words.push('analyze');
  }
  return words;
}

/** 中转站点去重追加（Go yeguoTransitSites 的 add 闭包） */
function ygAddTransitSite(raw: string, seen: Record<string, boolean>, sites: string[]): void {
  const site: string = ygValidSite(raw);
  if (site === '' || site === YG_TRANSIT_URL || seen[site] === true) {
    return;
  }
  seen[site] = true;
  sites.push(site);
}

/** Go yeguoTransitSites：明文 URL 字面量 + 种子词×后缀组合 */
function ygTransitSites(body: string): string[] {
  const text: string = ygTransitDecodedText(body);
  const sites: string[] = [];
  const seen: Record<string, boolean> = {};
  const literals: string[] = [];
  YG_RE_TRANSIT_LITERAL.lastIndex = 0;
  let match: RegExpExecArray | null = YG_RE_TRANSIT_LITERAL.exec(text);
  let count: number = 0;
  while (match !== null && count < 32) {
    literals.push(match[0]);
    count++;
    match = YG_RE_TRANSIT_LITERAL.exec(text);
  }
  for (let i: number = 0; i < literals.length; i++) {
    const host: string = ygHostnameOf(literals[i]);
    if (host.endsWith('.buxefaex.cc') || host.endsWith('.fzchosdi.cc') ||
      host.endsWith('.lwblvxvy.cc') || host.endsWith('.vgbyziuz.cc')) {
      ygAddTransitSite(literals[i], seen, sites);
    }
  }
  const words: string[] = ygTransitSeedWords(text);
  const suffixes: string[] = [];
  YG_RE_TRANSIT_SUFFIX.lastIndex = 0;
  match = YG_RE_TRANSIT_SUFFIX.exec(text);
  count = 0;
  while (match !== null && count < 8) {
    suffixes.push(match[1].toLowerCase());
    count++;
    match = YG_RE_TRANSIT_SUFFIX.exec(text);
  }
  for (let i: number = 0; i < suffixes.length; i++) {
    const suffix: string = suffixes[i];
    if (suffix.length === 0) {
      continue;
    }
    for (let j: number = 0; j < words.length; j++) {
      ygAddTransitSite(`https://${words[j]}.${suffix}`, seen, sites);
    }
  }
  return sites;
}

/** 发现站点去重追加（Go discoverConfiguration 的 add 闭包：校验 + 活跃 + 去重） */
function ygAddDiscoverSite(raw: string, seen: Record<string, boolean>, sites: string[]): void {
  const site: string = ygValidSite(raw);
  if (site !== '' && ygIsActiveSite(site) && seen[site] !== true) {
    seen[site] = true;
    sites.push(site);
  }
}

/** Go yeguoResponseSignature：sha256hex(字段拼接+signKey) 的 md5hex */
function ygResponseSignature(envelope: Record<string, Object>, signKey: Uint8Array): string {
  const names: string[] = [];
  const keys: string[] = Object.keys(envelope);
  for (let i: number = 0; i < keys.length; i++) {
    const name: string = keys[i];
    if (name === 'sign' || name === '_ver') {
      continue;
    }
    const value: Object | undefined = envelope[name];
    if (value !== undefined && value !== null) {
      names.push(name);
    }
  }
  names.sort();
  const pieces: string[] = [];
  for (let i: number = 0; i < names.length; i++) {
    const name: string = names[i];
    const field: Object | undefined = envelope[name];
    let text: string = '';
    if (typeof field === 'string') {
      text = field;
    } else if (typeof field === 'number') {
      text = `${field}`;
    } else if (typeof field === 'boolean') {
      text = field ? 'true' : 'false';
    } else {
      return '';
    }
    if (name === 'data') {
      text = text.replace(/ /g, '+');
    }
    pieces.push(`${name}=${text}`);
  }
  const digest: Uint8Array = qgSha256(qgConcat([qgUtf8Encode(pieces.join('&')), signKey]));
  return qgToHex(qgMd5(qgUtf8Encode(qgToHex(digest))));
}

/** Go decodeYeguoResponse：sign 校验 + data 密文 AES-128-CBC 解密，失败返回 null */
function ygDecodeResponse(body: Uint8Array, access: YgAccess): Record<string, Object> | null {
  const value: Object | null = QgJson.parse(qgUtf8Decode(body));
  const envelope: Record<string, Object> | null = QgJson.obj(value);
  if (envelope === null) {
    return null;
  }
  const signature: string = ygMapString(envelope, ['sign']);
  if (signature.length > 0) {
    const expected: string = ygResponseSignature(envelope, access.signKey);
    if (expected === '' || expected !== signature.toLowerCase()) {
      return null;
    }
  }
  const encoded: Object | undefined = envelope['data'];
  if (typeof encoded === 'string') {
    if (access.iv.length !== 16) {
      return null;
    }
    const cipherText: Uint8Array = qgBase64Decode(encoded.trim().replace(/ /g, '+'));
    if (cipherText.length === 0 || cipherText.length % 16 !== 0) {
      return null;
    }
    const plain: Uint8Array = qgAesCbcDecrypt(cipherText, access.key, access.iv);
    const inner: Object | null = QgJson.parse(qgUtf8Decode(plain));
    return QgJson.obj(inner);
  }
  return envelope;
}

/** Go normalizeViews：播放量归一（万/w 后缀、纯数字补「次播放」） */
function ygNormalizeViews(raw: string): string {
  const text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  if (text.includes('次播放')) {
    return text;
  }
  if (/[w万]/.test(text.toLowerCase())) {
    return `${text}次播放`;
  }
  const parsed: number = Number(text);
  if (Number.isNaN(parsed)) {
    return text;
  }
  if (parsed <= 0) {
    return '';
  }
  return `${parsed}次播放`;
}

/** Go providerCoverAddress：数组/对象/字符串取封面并相对补全 */
function ygCoverAddress(value: Object | undefined, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = ygCoverAddress(items[i], pageURL);
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
    const resolved: string = ygResolveUrl(pageURL, text);
    return ygIsHttpUrl(resolved) ? resolved : '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = ygCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go resolveProviderURL：实体解码 + `\/` 归一 + 协议相对/绝对地址解析（http 升 https） */
function ygResolveProviderUrl(baseURL: string, ref: string): string {
  let value: string = ygUnescapeHtml(ref).trim();
  if (value.length === 0) {
    return '';
  }
  value = value.replace(/\\\//g, '/');
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  const schemeMatch: RegExpExecArray | null = YG_RE_SCHEME_PREFIX.exec(value);
  if (schemeMatch !== null) {
    if (schemeMatch[0].toLowerCase() === 'http:') {
      return `https:${value.substring(schemeMatch[0].length)}`;
    }
    return value;
  }
  const resolved: string = ygResolveUrl(baseURL, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring(7)}`;
  }
  return resolved;
}

/** Go validYeguoCategory：field:value 且 value 为站内数字 ID */
function ygValidCategory(category: string): boolean {
  const sep: number = category.indexOf(':');
  if (sep < 0) {
    return false;
  }
  const field: string = category.substring(0, sep);
  const value: string = category.substring(sep + 1);
  if (!YG_RE_NUMERIC_ID.test(value)) {
    return false;
  }
  for (let i: number = 0; i < YG_FILTER_FIELDS.length; i++) {
    if (field === YG_FILTER_FIELDS[i]) {
      return true;
    }
  }
  return false;
}

/** Go yeguoDramaFromMap：行记录 → QgDrama（资料不完整抛错） */
function ygDramaFromMap(row: Record<string, Object> | null, site: string): QgDrama {
  if (row === null) {
    throw new Error('野果剧集资料不完整');
  }
  const id: string = ygMapString(row, ['video_id', 'id']);
  const title: string = ygMapString(row, ['title']);
  if (!YG_RE_NUMERIC_ID.test(id) || title.length === 0) {
    throw new Error('野果剧集资料不完整');
  }
  let episodes: number = 0;
  const countKeys: string[] = ['episode_count', 'episodes', 'total_serial'];
  for (let i: number = 0; i < countKeys.length; i++) {
    const count: number = ygInteger(row[countKeys[i]], 100000);
    if (count > episodes) {
      episodes = count;
    }
  }
  const tags: string[] = [];
  const seenTags: Record<string, boolean> = {};
  const rawTags: Object[] = QgJson.arr(row['tags']);
  for (let i: number = 0; i < rawTags.length && tags.length < 32; i++) {
    if (typeof rawTags[i] !== 'string') {
      continue;
    }
    const tag: string = (rawTags[i] as string).trim();
    if (tag.length > 0 && Array.from(tag).length <= 48 && seenTags[tag] !== true) {
      seenTags[tag] = true;
      tags.push(tag);
    }
  }
  const cover: string = ygCoverAddress(row['cover'], `${site}/`);
  const description: string = ygTruncate(ygMapString(row, ['description']), 12000);
  const drama: QgDrama = new QgDrama(`yeguo:${id}`, ygTruncate(title, 512), '短剧');
  drama.sourceId = 'yeguo';
  drama.episodeCount = episodes;
  drama.finished = ygMapString(row, ['serialize_status']) !== '1';
  drama.tags = tags;
  drama.intro = description;
  drama.cover = cover;
  drama.viewsText = ygNormalizeViews(ygMapString(row, ['play_count', 'play_count_text']));
  drama.heat = 0;
  drama.remark = '';
  return drama;
}

/** Go yeguoEpisodePage：分集页面地址（第 2 集起带 ep-N/） */
function ygEpisodePage(site: string, id: string, episode: number): string {
  let address: string = `${site}/drama/video/${id}/`;
  if (episode > 1) {
    address += `ep-${episode}/`;
  }
  return address;
}

/** Go yeguoMediaQuality：分辨率 WxH → 短边（上限 16384，无效 0） */
function ygMediaQuality(resolution: string): number {
  const parts: string[] = resolution.toLowerCase().split('x');
  if (parts.length !== 2) {
    return 0;
  }
  const width: number = ygInteger(parts[0], 16384);
  const height: number = ygInteger(parts[1], 16384);
  if (width < 1 || height < 1) {
    return 0;
  }
  return Math.min(width, height);
}

/** 统一页面/脚本文本抓取（fetchProviderText：UA + Referer + Accept-Language，2xx 校验） */
async function ygFetchText(address: string, referer: string, timeoutMs: number, maxChars: number): Promise<string> {
  const headers: Record<string, string> = {
    'User-Agent': YG_UA,
    'Referer': referer,
    'Accept-Language': 'zh-CN,zh;q=0.9'
  };
  const resp: QgHttpResponse = await QgHttp.request(address, 'GET', headers, null, timeoutMs, 0, 30, 'yeguo');
  if (resp.status < 200 || resp.status >= 300) {
    throw new Error(`野果页面请求失败：HTTP ${resp.status}`);
  }
  const text: string = resp.text();
  if (text.length > maxChars) {
    throw new Error('野果页面内容过大');
  }
  return text;
}

export class YeguoSource extends QgSource {
  /** 当前接口访问配置（1 小时缓存） */
  private static access: YgAccess | null = null;
  /** 进行中的配置发现（并发合并，Go pending） */
  private static pending: Promise<YgAccess> | null = null;
  /** 分类缓存（categories() 为同步签名，首次目录/搜索请求时异步填充） */
  private static categoryCache: QgCategory[] = [];

  constructor() {
    super('yeguo', '野果');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < YeguoSource.categoryCache.length; i++) {
      all.push(YeguoSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.ygCatalogPage(categoryId.trim(), '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.ygCatalogPage('', keyword.trim(), page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceID: string = (dramaId.startsWith('yeguo:') ?
      dramaId.substring('yeguo:'.length) : dramaId).trim();
    if (!YG_RE_NUMERIC_ID.test(sourceID)) {
      throw new Error('野果剧集 ID 无效');
    }
    const params: Record<string, string> = {
      'video_id': sourceID,
      'id': sourceID,
      'episode_id': '0',
      'related_limit': '0'
    };
    const row: Record<string, Object> = await this.ygCall('/api/playlet/detail', params);
    const site: string = this.ygSiteURL();
    const drama: QgDrama = ygDramaFromMap(row, site);
    if (drama.id !== `yeguo:${sourceID}`) {
      throw new Error('野果详情与请求剧集不符');
    }
    const rawEpisodes: Object | undefined = row['episodes'];
    if (rawEpisodes === undefined || rawEpisodes === null || !Array.isArray(rawEpisodes)) {
      throw new Error('野果分集目录格式无效');
    }
    const rows: Object[] = rawEpisodes as Object[];
    if (rows.length > 10000) {
      throw new Error('野果分集目录格式无效');
    }
    const episodes: QgEpisode[] = [];
    const seenIDs: Record<string, boolean> = {};
    const seenNumbers: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const episode: Record<string, Object> | null = QgJson.obj(rows[i]);
      const advertisement: YgFlagResult = ygFlag(episode !== null ? episode['is_adv'] : undefined);
      if (advertisement.value) {
        continue;
      }
      const id: string = ygMapString(episode, ['id']);
      const number: number = ygInteger(episode !== null ? episode['sort'] : undefined, 100000);
      if (!YG_RE_NUMERIC_ID.test(id) || number < 1 || seenIDs[id] === true ||
        seenNumbers[`${number}`] === true) {
        throw new Error('野果分集编号无效或重复，请刷新详情');
      }
      seenIDs[id] = true;
      seenNumbers[`${number}`] = true;
      const title: string = ygFirstNonEmptyText([ygMapString(episode, ['title']), `第 ${number} 集`]);
      episodes.push(new QgEpisode(id, ygTruncate(title, 256), number));
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceID: string = (dramaId.startsWith('yeguo:') ?
      dramaId.substring('yeguo:'.length) : dramaId).trim();
    const episodeID: string = episodeId.trim();
    if (!YG_RE_NUMERIC_ID.test(sourceID)) {
      throw new Error('野果播放分集信息无效，请刷新详情');
    }
    if (!YG_RE_NUMERIC_ID.test(episodeID)) {
      throw new Error('野果播放分集 ID 无效');
    }
    const params: Record<string, string> = {
      'playlet_id': sourceID,
      'video_id': sourceID,
      'episode_id': episodeID
    };
    const row: Record<string, Object> = await this.ygCall('/api/playlet/play', params);
    if (ygMapString(row, ['playlet_id']) !== sourceID || ygMapString(row, ['id']) !== episodeID) {
      throw new Error('野果返回的播放地址与请求分集不符');
    }
    const advertisement: YgFlagResult = ygFlag(row['is_adv']);
    if (advertisement.value) {
      throw new Error('野果未返回该集正片，请重试');
    }
    const number: number = ygInteger(row['episode_sort'], 100000);
    if (number < 1) {
      throw new Error('野果播放分集编号无效');
    }
    const site: string = this.ygSiteURL();
    const referer: string = ygEpisodePage(site, sourceID, number);
    const quality: number = ygMediaQuality(ygMapString(row, ['resolution']));
    const urls: string[] = [];
    const seen: Record<string, boolean> = {};
    const mediaKeys: string[] = ['video_url', 'video_url_h265'];
    for (let i: number = 0; i < mediaKeys.length; i++) {
      const raw: string = ygMapString(row, [mediaKeys[i]]);
      if (raw.length === 0) {
        continue;
      }
      const address: string = ygResolveProviderUrl(referer, raw);
      if (!ygIsHttpUrl(address) || seen[address] === true) {
        continue;
      }
      seen[address] = true;
      urls.push(address);
    }
    if (urls.length === 0) {
      throw new Error('野果未提供该集播放地址，请重试或确认站源权限');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = urls[0];
    info.referer = referer;
    info.headers = { 'User-Agent': YG_UA, 'Referer': referer, 'Origin': site };
    info.routes = urls;
    info.routeIndex = 0;
    info.quality = quality;
    const duration: number = Number(ygMapString(row, ['episode_duration']));
    if (!Number.isNaN(duration) && duration > 0 && duration <= 604800) {
      info.durationMs = Math.round(duration * 1000);
    }
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': YG_UA, 'Referer': `${this.ygSiteURL()}/` };
  }

  /** Go siteURL：发现站点优先，回退内置入口 */
  private ygSiteURL(): string {
    const access: YgAccess | null = YeguoSource.access;
    if (access !== null && access.site.length > 0) {
      return access.site;
    }
    return YG_BASE_URL;
  }

  /** Go configuration：1 小时缓存 + 并发合并（pending 单飞） */
  private async ygConfiguration(): Promise<YgAccess> {
    const current: YgAccess | null = YeguoSource.access;
    if (current !== null) {
      const elapsed: number = Date.now() - current.loadedAt;
      if (elapsed >= 0 && elapsed < YG_ACCESS_TTL_MS) {
        return current;
      }
    }
    if (YeguoSource.pending !== null) {
      return YeguoSource.pending;
    }
    const pending: Promise<YgAccess> = this.ygDiscoverConfiguration();
    YeguoSource.pending = pending;
    try {
      const fresh: YgAccess = await pending;
      YeguoSource.access = fresh;
      return fresh;
    } finally {
      YeguoSource.pending = null;
    }
  }

  /** Go discoverTransitSites：中转页域名池（失败返回空） */
  private async ygDiscoverTransit(): Promise<string[]> {
    try {
      const body: string = await ygFetchText(`${YG_TRANSIT_URL}/`, `${YG_TRANSIT_URL}/`,
        YG_PAGE_TIMEOUT_MS, YG_MAX_PAGE_CHARS);
      return ygTransitSites(body);
    } catch (error) {
      return [];
    }
  }

  /** Go discoverConfiguration：内置入口 + 备用域名 + 首站失败后追加中转站点 */
  private async ygDiscoverConfiguration(): Promise<YgAccess> {
    const sites: string[] = [];
    const seen: Record<string, boolean> = {};
    ygAddDiscoverSite(YG_BASE_URL, seen, sites);
    for (let i: number = 0; i < YG_BACKUP_SITES.length; i++) {
      ygAddDiscoverSite(YG_BACKUP_SITES[i], seen, sites);
    }
    let lastError: Error | null = null;
    for (let index: number = 0; index < sites.length; index++) {
      const site: string = sites[index];
      try {
        return await this.ygDiscoverAt(site);
      } catch (error) {
        lastError = error as Error;
        if (index === 0) {
          const transit: string[] = await this.ygDiscoverTransit();
          for (let i: number = 0; i < transit.length; i++) {
            ygAddDiscoverSite(transit[i], seen, sites);
          }
        }
      }
    }
    throw new Error('野果线路暂不可用，请稍后重试' +
      (lastError !== null ? `：${lastError.message}` : ''));
  }

  /** Go discoverConfigurationAt：首页 → NUXT apiBase + 入口脚本 → 模块脚本扫密钥 */
  private async ygDiscoverAt(site: string): Promise<YgAccess> {
    const pageURL: string = `${site}/`;
    const body: string = await ygFetchText(pageURL, pageURL, YG_PAGE_TIMEOUT_MS, YG_MAX_PAGE_CHARS);
    let apiBase: string = ygValidApiBase(ygApiBaseFromNuxt(body));
    const origin: string = ygOriginOf(pageURL);
    const tags: YgScriptTag[] = ygScriptTags(body);
    let entry: string = '';
    for (let i: number = 0; i < tags.length; i++) {
      if (ygTagAttr(tags[i].attrs, 'type') !== 'module') {
        continue;
      }
      entry = ygScriptURL(pageURL, ygTagAttr(tags[i].attrs, 'src'));
      if (entry !== '') {
        break;
      }
    }
    if (entry === '') {
      throw new Error('野果页面未提供接口配置脚本');
    }
    const entryBody: string = await ygFetchText(entry, pageURL, YG_PAGE_TIMEOUT_MS, YG_MAX_SCRIPT_CHARS);
    if (apiBase === '') {
      apiBase = ygScriptAPIBase(entryBody, origin);
    }
    const imports: YgModuleImport[] = ygModuleImports(entryBody);
    imports.sort((a: YgModuleImport, b: YgModuleImport): number =>
      (a.names.includes(',') ? 1 : 0) - (b.names.includes(',') ? 1 : 0));
    const seen: Record<string, boolean> = {};
    let lastError: Error | null = null;
    let found: YgAccess | null = null;
    for (let i: number = 0; i < imports.length; i++) {
      if (found !== null && apiBase !== '') {
        break;
      }
      const imported: YgModuleImport = imports[i];
      if (imported.names.length > 2400) {
        continue;
      }
      const address: string = ygScriptURL(entry, imported.path);
      if (address === '' || seen[address] === true) {
        continue;
      }
      if (Object.keys(seen).length >= 20) {
        break;
      }
      seen[address] = true;
      try {
        const scriptBody: string = await ygFetchText(address, pageURL, YG_PAGE_TIMEOUT_MS, YG_MAX_SCRIPT_CHARS);
        if (apiBase === '') {
          apiBase = ygScriptAPIBase(scriptBody, origin);
        }
        if (found === null) {
          found = ygParsePublicConfig(scriptBody);
        }
      } catch (error) {
        lastError = error as Error;
      }
    }
    if (found === null) {
      throw new Error('野果接口配置已变化，暂时无法解码，请稍后重试' +
        (lastError !== null ? `：${lastError.message}` : ''));
    }
    if (apiBase === '') {
      throw new Error('野果页面未提供有效的接口入口');
    }
    found.base = apiBase;
    found.site = site;
    found.identifier = qgRandomHex(16);
    found.loadedAt = Date.now();
    return found;
  }

  /** Go call：默认表单参数 + GET(contentOptions)/POST 表单 + 解码重试（清缓存一次） */
  private async ygCall(route: string, params: Record<string, string> | null): Promise<Record<string, Object>> {
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const access: YgAccess = await this.ygConfiguration();
      const values: Record<string, string> = {
        'bundleId': 'com.pwa.mater',
        'version': '1.3.2',
        'oauth_type': 'web',
        'language': 'zh',
        'via': 'pwa',
        'oauth_id': access.identifier,
        'trace_id': access.identifier,
        'token': ''
      };
      if (params !== null) {
        const keys: string[] = Object.keys(params);
        for (let i: number = 0; i < keys.length; i++) {
          values[keys[i]] = params[keys[i]];
        }
      }
      const isGet: boolean = route === '/api/home/contentOptions';
      let address: string = `${access.base}${route}`;
      let body: Uint8Array | null = null;
      if (isGet) {
        address += `?${qgBuildQuery(values)}`;
      } else {
        body = qgUtf8Encode(qgBuildQuery(values));
      }
      const site: string = access.site.length > 0 ? access.site : YG_BASE_URL;
      const headers: Record<string, string> = {
        'User-Agent': YG_UA,
        'Accept': 'application/json, text/plain, */*',
        'Origin': site,
        'Referer': `${site}/`
      };
      if (!isGet) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }
      const resp: QgHttpResponse = await QgHttp.request(address, isGet ? 'GET' : 'POST',
        headers, body, YG_API_TIMEOUT_MS, 0, 30, this.id);
      if (resp.status < 200 || resp.status >= 300) {
        throw new Error(`野果接口请求失败：HTTP ${resp.status}`);
      }
      if (resp.data.length > YG_MAX_API_BYTES) {
        throw new Error('野果接口数据过大或读取失败');
      }
      const decoded: Record<string, Object> | null = ygDecodeResponse(resp.data, access);
      if (decoded === null) {
        if (attempt === 0) {
          if (YeguoSource.access === access) {
            YeguoSource.access = null;
          }
          continue;
        }
        throw new Error('野果接口响应校验或解码失败');
      }
      const status: string = ygMapString(decoded, ['status']);
      if (status !== '1') {
        if (status === '-1') {
          throw new Error('野果当前内容需要站源授权');
        }
        const message: string = ygFirstNonEmptyText(
          [ygTruncate(ygCleanText(ygMapString(decoded, ['msg'])), 180), '请稍后重试']);
        throw new Error(`野果请求未完成：${message}`);
      }
      const data: Record<string, Object> | null = QgJson.obj(decoded['data']);
      if (data === null) {
        throw new Error('野果返回的数据格式无效');
      }
      return data;
    }
    throw new Error('野果接口响应校验或解码失败');
  }

  /** 目录/搜索共用的分页取数（fetchYeguoCatalogPage） */
  private async ygCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000 || query.length > 1024 ||
      (category.length > 0 && !ygValidCategory(category))) {
      throw new Error('野果目录查询参数无效');
    }
    await this.ygEnsureCategories();
    const values: Record<string, string> = {
      'page': `${page}`,
      'limit': `${YG_PAGE_SIZE}`
    };
    let route: string = '/api/theater/exploreList';
    if (query.length > 0) {
      route = '/api/search/result';
      values['keyword'] = query;
      values['tab'] = 'video';
    } else if (category.length > 0) {
      const sep: number = category.indexOf(':');
      values[category.substring(0, sep)] = category.substring(sep + 1);
    }
    const data: Record<string, Object> = await this.ygCall(route, values);
    const rawList: Object | undefined = data['list'];
    if (rawList === undefined || rawList === null || !Array.isArray(rawList)) {
      throw new Error('野果目录格式无效');
    }
    const rows: Object[] = rawList as Object[];
    if (rows.length > 500) {
      throw new Error('野果目录格式无效');
    }
    const pageKeys: string[] = ['page', 'page_num', 'pageNum', 'current_page', 'currentPage'];
    const actualPage: number = ygInteger(ygFirstPresent(data, pageKeys), 1000000);
    if (actualPage >= 0 && actualPage !== page) {
      throw new Error('野果分页信息无效，请重试');
    }
    const limitKeys: string[] = ['limit', 'page_size', 'pageSize', 'per_page', 'perPage'];
    let limit: number = ygInteger(ygFirstPresent(data, limitKeys), 500);
    if (limit < 1 || limit < rows.length) {
      limit = rows.length;
    }
    const totalKeys: string[] = ['total', 'total_count', 'totalCount'];
    let total: number = ygInteger(ygFirstPresent(data, totalKeys), 100000000);
    let totalValid: boolean = total >= 0;
    if (totalValid && total < rows.length) {
      totalValid = false;
    }
    let hasMore: boolean = limit > 0 && rows.length >= limit;
    if (totalValid && limit > 0) {
      hasMore = page < Math.floor((total + limit - 1) / limit);
    }
    const rawMore: Object | undefined = data['has_more'];
    if (rawMore !== undefined && rawMore !== null) {
      const more: YgFlagResult = ygFlag(rawMore);
      if (!more.known) {
        throw new Error('野果分页信息无效，请重试');
      }
      hasMore = more.value;
    }
    if (hasMore && rows.length === 0) {
      throw new Error('野果未返回应有的目录页，请重试');
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama = ygDramaFromMap(QgJson.obj(rows[i]), this.ygSiteURL());
      if (seen[drama.id] === true) {
        throw new Error('野果目录包含重复剧集');
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return new QgPageResult(items, hasMore);
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async ygEnsureCategories(): Promise<void> {
    if (YeguoSource.categoryCache.length > 0) {
      return;
    }
    try {
      YeguoSource.categoryCache = await this.ygFetchCategories();
    } catch (error) {
      // 分类获取失败不阻塞目录；下次分页请求再试
    }
  }

  /** Go fetchYeguoCategories：/api/home/contentOptions 的 video_filter → 分类 */
  private async ygFetchCategories(): Promise<QgCategory[]> {
    const data: Record<string, Object> = await this.ygCall('/api/home/contentOptions', null);
    const filters: Record<string, Object> | null = QgJson.obj(data['video_filter']);
    if (filters === null) {
      throw new Error('野果分类数据格式无效');
    }
    const categories: QgCategory[] = [];
    const seen: Record<string, boolean> = {};
    for (let f: number = 0; f < YG_FILTER_FIELDS.length; f++) {
      const field: string = YG_FILTER_FIELDS[f];
      const filter: Record<string, Object> | null = QgJson.obj(filters[field]);
      const options: Object[] = QgJson.arr(filter !== null ? filter['list'] : undefined);
      if (options.length > 300) {
        throw new Error('野果分类条目过多');
      }
      for (let i: number = 0; i < options.length; i++) {
        const optionRow: Record<string, Object> | null = QgJson.obj(options[i]);
        const value: string = ygMapString(optionRow, ['value']);
        const name: string = ygMapString(optionRow, ['name']);
        if (value === '0') {
          continue;
        }
        const id: string = `${field}:${value}`;
        if (!ygValidCategory(id) || name.length === 0 || Array.from(name).length > 48 ||
          seen[id] === true) {
          throw new Error('野果分类数据包含无效或重复条目');
        }
        seen[id] = true;
        categories.push(new QgCategory(id, name));
      }
    }
    if (categories.length === 0) {
      throw new Error('野果暂未返回分类');
    }
    return categories;
  }
}
