/**
 * 黄果旧版站源（cloudfront 旧 API）。
 * 访客会话：官网前端脚本解析 interfaceKey/parameterKey/parameterIv（24h 有效），
 * 随机 DevID + POST /api/app/mine/login/h5 换取匿名 token（仅内存，不落盘）；
 * 请求参数 AES-128-CBC 加密（GET ?data= / POST {"data":...}），
 * 响应 hash 启用时 base64 + SHA256 派生密钥 AES-CBC 解密（legacyDecryptResponse）；
 * API 域名两轮发现：静态 cloudfront 候选 + 官网脚本内 cloudfront 域名，探活 /api/app/ping/check；
 * 目录：每页拉 /api/app/playlet-tab/all 后逐 tab 请求 /api/app/playlet/home/tab/{id}；
 * 详情 /api/app/playlet/detail/{id}（分集空则 /api/app/playlet-chapter/list/{id}）；
 * 播放：非 http 分集地址改写为 {apiBase}/api/app/vid/h5/m3u8/{path}?c=&token=；
 * 搜索：目录第一页本地过滤。
 * 移植自 guoapp provider_legacy.go + provider_legacy_app.go + provider_legacy_session.go
 * + provider_legacy_cover.go + provider_discovery.go + app_runtime.go（cloudfront 分发）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { qgBase64Decode, qgBase64Encode, qgBuildQuery, qgConcat, qgRandomHex, qgSlice,
  qgUtf8Decode, qgUtf8Encode } from '../QgBytes';
import { qgAesCbcDecrypt, qgAesCbcEncrypt, qgSha256 } from '../QgCrypto';
import { QgSource } from './QgSource';

/** 官网前端（脚本发现 / Referer 基准） */
const LG_FRONTEND: string = 'https://d2pypzndaqisk.cloudfront.net';
/** 默认 API 域名（Go config_defaults.go defaultAPIBase） */
const LG_API_BASE: string = 'https://dr6skssi3nxbk.cloudfront.net';
/** API 备用域名（Go apiFallbackHosts） */
const LG_API_FALLBACK_HOSTS: string[] = ['https://d18ka9rqpfd3lo.cloudfront.net',
  'https://d37n0wjehmw08f.cloudfront.net'];
/** 旧 CDN（播放改写 c 参数，Go defaultCDNURL） */
const LG_CDN_URL: string = 'https://sjljsla.lkkwip.cn';
/** 接口 UA（Go config_defaults.go userAgent） */
const LG_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 加密协议 UA（Go config_defaults.go xUserAgent） */
const LG_X_USER_AGENT: string = 'BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;Terminal=1;IsH5=1;Sid=00000000000000000000000000000000';
/** 单次请求超时（Go providerTimeout） */
const LG_TIMEOUT_MS: number = 12000;
/** API 探活超时（Go probeAPIHost 4s） */
const LG_PROBE_TIMEOUT_MS: number = 4000;
/** 协议有效期（Go 24h） */
const LG_PROTOCOL_TTL_MS: number = 24 * 60 * 60 * 1000;
/** 失败域名冷却时间（Go resetAPIEndpoint 1 分钟） */
const LG_HOST_FAILURE_TTL_MS: number = 60 * 1000;
/** 目录分页大小（Go cfg.PageSize 默认 30） */
const LG_PAGE_SIZE: number = 30;
/** 响应体上限（Go providerMaxBodyBytes） */
const LG_MAX_BODY_BYTES: number = 20 * 1024 * 1024;
/** 单地址请求尝试次数（Go cfg.Retries 默认 2） */
const LG_ATTEMPTS: number = 2;

/** Go rankingSourceID：合法剧集/分集代码 */
const RE_LG_RANK_ID: RegExp = /^[a-zA-Z0-9_-]{1,100}$/;
/** Go reEpisodeNumber */
const RE_LG_EPISODE_NUMBER: RegExp =
  /(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))/i;
/** Go reFinishedEpisodeRemark */
const RE_LG_FINISHED: RegExp = /(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/;
/** currentEpisode 原始 JSON 为整数（含负号） */
const RE_LG_INT: RegExp = /^[+-]?[0-9]+$/;
/** token 禁止出现的空白字符（Go validLegacyToken） */
const RE_LG_TOKEN_WS: RegExp = /[\r\n\t ]/;
/** 官网脚本内 cloudfront API 域名（Go parseAPIHosts） */
const RE_LG_CLOUDFRONT_HOST: RegExp = /https:\/\/[a-z0-9]+\.cloudfront\.net/g;
/** 官网页面 script 标签 src（Go fetchLegacyFrontendScript） */
const RE_LG_SCRIPT_SRC: RegExp = /<script\b[^>]*\bsrc=["']([^"']+)["']/gi;
/** URL scheme 前缀 */
const RE_LG_SCHEME: RegExp = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

/** coverPathFromAny 的 map 键序（Go ui_server.go） */
const LG_COVER_MAP_KEYS: string[] = ['url', 'src', 'path', 'cover', 'coverUrl', 'cover_url',
  'image', 'pic', 'poster'];
/** 目录行封面键序（Go fetchLegacyCatalogCategoryPage） */
const LG_ROW_COVER_KEYS: string[] = ['coverUrl', 'coverurl', 'cover_url', 'cover', 'imageUrl',
  'imageurl', 'image_url', 'image', 'img', 'pic', 'picture', 'poster', 'thumb', 'thumbnail'];
/** 详情行封面键序（Go fetchLegacyDetail） */
const LG_DETAIL_COVER_KEYS: string[] = ['coverUrl', 'coverurl', 'cover_url', 'cover', 'imageUrl',
  'imageurl', 'image_url', 'image', 'img', 'pic', 'poster'];
/** 集数键序（Go nativeNormalize） */
const LG_COUNT_KEYS: string[] = ['totalEpisode', 'totalepisode', 'total_episode', 'episodeCount',
  'episodecount', 'episode_count', 'chapterCount', 'chaptercount', 'chapter_count', 'total', 'episodes'];

/** 黄果旧 API 业务错误（envelope code 非 200/0） */
class LgApiError extends Error {
  code: string = '';

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** 分类标签（Go Tab） */
class LgTab {
  id: string = '';
  name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/** 目录 tab 请求参数（Go map 键字典序：pageNumber/pageSize/tabSortType） */
class LgTabParams {
  pageNumber: string = '';
  pageSize: string = '';
  tabSortType: string = '1';

  constructor(pageNumber: string, pageSize: string) {
    this.pageNumber = pageNumber;
    this.pageSize = pageSize;
  }
}

/** 访客登录参数（Go map 键字典序：devID/isAppStore/sysType） */
class LgLoginParams {
  devID: string = '';
  isAppStore: boolean = false;
  sysType: string = 'ios';

  constructor(devID: string) {
    this.devID = devID;
  }
}

/** 分集（Go Chapter 精简） */
class LgChapter {
  id: string = '';
  title: string = '';
  videoUrl: string = '';
  /** currentEpisode 的原始 JSON 文本（缺省/null 为空） */
  currentEpisode: string = '';
  /** 分集键：firstNonEmpty(id, index+1) */
  epKey: string = '';
  /** 排序用集号 */
  order: number = 0;
}

/** 详情 + 分集抓取结果 */
class LgChapterData {
  row: Record<string, Object> = {};
  chapters: LgChapter[] = [];
}

/** API 域名状态（Go apiBase/apiFailures） */
let lgApiBase: string = '';
const lgApiFailures: Record<string, number> = {};
/** 协议与访客会话（仅内存，Go legacySessionState 简化） */
let lgInterfaceKey: string = '';
let lgParamKey: string = '';
let lgParamIv: string = '';
let lgProtocolAt: number = 0;
let lgDeviceId: string = '';
let lgToken: string = '';
/** 分类缓存（categories() 同步返回，目录请求时填充） */
let lgCachedTabs: LgTab[] = [];

/** Go firstNonEmpty */
function lgFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** 取首个匹配（不改变全局 regex 的共享状态） */
function lgFirstMatch(re: RegExp, text: string): RegExpExecArray | null {
  re.lastIndex = 0;
  const match: RegExpExecArray | null = re.exec(text);
  re.lastIndex = 0;
  return match;
}

/** 收集全部匹配（Go FindAllString* 对应） */
function lgAllMatches(re: RegExp, text: string): RegExpExecArray[] {
  const out: RegExpExecArray[] = [];
  re.lastIndex = 0;
  let match: RegExpExecArray | null = re.exec(text);
  while (match !== null) {
    out.push(match);
    if (match.index === re.lastIndex) {
      re.lastIndex = re.lastIndex + 1;
    }
    match = re.exec(text);
  }
  re.lastIndex = 0;
  return out;
}

/** 字符数（Unicode 码点，Go len([]rune)） */
function lgRuneCount(text: string): number {
  let count: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
      const next: number = text.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        i++;
      }
    }
    count++;
  }
  return count;
}

/** Go truncate：trim + 码点截断 + ... */
function lgTruncate(text: string, n: number): string {
  const s: string = text.trim();
  if (lgRuneCount(s) <= n) {
    return s;
  }
  let out: string = '';
  let count: number = 0;
  let i: number = 0;
  while (i < s.length && count < n) {
    const code: number = s.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
      const next: number = s.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        out += s.substring(i, i + 2);
        i += 2;
        count++;
        continue;
      }
    }
    out += s.charAt(i);
    i++;
    count++;
  }
  return `${out}...`;
}

/** 异步等待（重试退避） */
function lgSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** Go validLegacyToken */
function lgValidToken(token: string): boolean {
  return token.length <= 4096 && !RE_LG_TOKEN_WS.test(token);
}

/** Go validLegacyProtocol */
function lgValidProtocol(): boolean {
  return lgInterfaceKey.length > 0 && lgInterfaceKey.length <= 512 &&
    lgParamKey.length === 16 && lgParamIv.length === 16;
}

/** 访客 X-User-Agent（DevID 替换，Go legacyAccess.userAgent） */
function lgUserAgent(): string {
  if (lgDeviceId.length === 0) {
    return LG_X_USER_AGENT;
  }
  return LG_X_USER_AGENT.replace('DevID=00000000000000000000000000000', `DevID=${lgDeviceId}`);
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function lgDecodeNumericEntities(text: string): string {
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

/** HTML 实体解码（Go html.UnescapeString 常用子集，多轮展开） */
function lgUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = lgDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** 相对地址补全（url.ResolveReference 简化版，含 ./ 与 ../ 段处理） */
function lgResolveReference(pageURL: string, ref: string): string {
  const value: string = ref.trim();
  if (RE_LG_SCHEME.test(value) && value.includes('://')) {
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

/** Go resolveProviderURL：转义修复 + 相对补全 + http→https 升级 */
function lgResolveURL(baseURL: string, ref: string): string {
  let value: string = lgUnescapeHtml(ref).trim();
  if (value.length === 0) {
    return '';
  }
  value = value.replace(/\\\//g, '/');
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  if (RE_LG_SCHEME.test(value) && value.includes('://')) {
    if (value.startsWith('http://')) {
      return `https://${value.substring(7)}`;
    }
    return value;
  }
  const resolved: string = lgResolveReference(baseURL, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring(7)}`;
  }
  return resolved;
}

/** URL → 小写主机名 */
function lgUrlHostname(raw: string): string {
  let rest: string = raw.trim();
  const proto: number = rest.indexOf('://');
  if (proto >= 0) {
    rest = rest.substring(proto + 3);
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
  const at: number = hostPart.lastIndexOf('@');
  if (at >= 0) {
    hostPart = hostPart.substring(at + 1);
  }
  const colon: number = hostPart.lastIndexOf(':');
  const hostname: string = colon >= 0 ? hostPart.substring(0, colon) : hostPart;
  return hostname.toLowerCase();
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function lgIsHttpUrl(raw: string): boolean {
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

/** Go releaseStatusFromRemark：更新说明 → ongoing/finished/unknown */
function lgReleaseStatusFromRemark(remark: string): string {
  if (remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载')) {
    return 'ongoing';
  }
  if (RE_LG_FINISHED.test(remark) || remark.includes('完结')) {
    return 'finished';
  }
  return 'unknown';
}

/** 搜索文本规范化（hongguoSearchText 简化版） */
function lgSearchText(text: string): string {
  const normalized: string = text.normalize('NFKC').toLowerCase()
    .replace(/[\s!-/:-@[-`{-~。，、；：？！“”‘’（）《》〈〉【】〔〕…—·～「」『』]/g, '');
  return normalized;
}

/** Go episodeIndex：从文本提取分集号 */
function lgEpisodeIndex(text: string, fallback: number): number {
  const match: RegExpExecArray | null = RE_LG_EPISODE_NUMBER.exec(text);
  if (match !== null) {
    for (let g: number = 1; g <= 3; g++) {
      if (g >= match.length) {
        continue;
      }
      const group: string = match[g] || '';
      if (group.length === 0) {
        continue;
      }
      const n: number = Number(group);
      if (!Number.isNaN(n) && n > 0) {
        return n;
      }
    }
  }
  return fallback;
}

/** currentEpisode 原始 JSON 文本 → 字符串值（去引号，Go json.Unmarshal &s 简化） */
function lgUnquoteJsonString(text: string): string {
  if (text.length < 2) {
    return '';
  }
  return text.substring(1, text.length - 1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}

/** Go chapterEpisodeNumber：currentEpisode（整数/字符串）→ 标题 → fallback */
function lgChapterEpisodeNumber(ch: LgChapter, fallback: number): number {
  const text: string = ch.currentEpisode;
  if (text.length > 0 && text !== 'null') {
    if (RE_LG_INT.test(text)) {
      const n: number = parseInt(text, 10);
      if (n > 0) {
        return n;
      }
    } else if (text.startsWith('"')) {
      return lgEpisodeIndex(lgUnquoteJsonString(text), fallback);
    }
  }
  return lgEpisodeIndex(ch.title, fallback);
}

/** Go Chapter.EpisodeString：currentEpisode 的展示文本（字符串/整数/浮点） */
function lgEpisodeString(ch: LgChapter, fallback: number): string {
  const text: string = ch.currentEpisode;
  if (text.length > 0 && text !== 'null') {
    if (text.startsWith('"')) {
      const s: string = lgUnquoteJsonString(text).trim();
      if (s.length > 0) {
        return s;
      }
    } else if (RE_LG_INT.test(text)) {
      const n: number = parseInt(text, 10);
      if (n > 0) {
        return `${n}`;
      }
    } else {
      const f: number = Number(text);
      if (!Number.isNaN(f) && f > 0) {
        return `${Math.floor(f)}`;
      }
    }
  }
  return `${fallback}`;
}

/** Go coverPathFromAny：任意 JSON 值 → 封面路径 */
function lgCoverPathFromAny(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    const s: string = value.trim();
    if (s.length === 0) {
      return '';
    }
    if (s.startsWith('//')) {
      return `https:${s}`;
    }
    if (s.startsWith('/api/ui/image')) {
      const q: number = s.indexOf('?');
      if (q >= 0) {
        const pairs: string[] = s.substring(q + 1).split('&');
        for (let i: number = 0; i < pairs.length; i++) {
          const eq: number = pairs[i].indexOf('=');
          if (eq > 0 && pairs[i].substring(0, eq) === 'url') {
            const raw: string = decodeURIComponent(pairs[i].substring(eq + 1).replace(/\+/g, ' ')).trim();
            if (raw.length > 0) {
              return raw;
            }
          }
        }
      }
    }
    if (RE_LG_SCHEME.test(s)) {
      return s;
    }
    return s.replace(/^\/+/, '');
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const path: string = lgCoverPathFromAny(items[i]);
      if (path.length > 0) {
        return path;
      }
    }
    return '';
  }
  if (typeof value === 'object') {
    const row: Record<string, Object> = value as Record<string, Object>;
    for (let i: number = 0; i < LG_COVER_MAP_KEYS.length; i++) {
      const path: string = lgCoverPathFromAny(row[LG_COVER_MAP_KEYS[i]]);
      if (path.length > 0) {
        return path;
      }
    }
  }
  return '';
}

/** Go legacyCoverURL + repairLegacyCoverURL：封面路径规范化与旧 CDN 修复 */
function lgLegacyCoverURL(value: Object | undefined): string {
  let address: string = lgCoverPathFromAny(value).trim();
  if (address.length === 0) {
    return '';
  }
  if (address.startsWith('//')) {
    address = `https:${address}`;
  }
  const proto: number = address.indexOf('://');
  if (proto >= 0) {
    const scheme: string = address.substring(0, proto).toLowerCase();
    let rest: string = address.substring(proto + 3);
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
      return '';
    }
    const colon: number = hostPart.indexOf(':');
    const hostname: string = colon >= 0 ? hostPart.substring(0, colon) : hostPart;
    if (scheme !== 'http' && scheme !== 'https') {
      return '';
    }
    if (hostname.length === 0) {
      return '';
    }
    if (hostname === 'sjljsla.lkkwip.cn') {
      return lgLegacyCoverURL(rest.substring(cut));
    }
    return address;
  }
  if (RE_LG_SCHEME.test(address)) {
    return '';
  }
  if (address.includes('..') || address.includes('://')) {
    return '';
  }
  address = address.replace(/^\/+/, '');
  if (address.startsWith('upload/') || address.startsWith('upload_01/')) {
    return `https://pic.zdmhyg.cn/${address}`;
  }
  return `https://zzzznnn.lkkwip.cn/${address}`;
}

/** 行内首个可用封面（按键序尝试） */
function lgRowCover(row: Record<string, Object>, keys: string[]): string {
  for (let i: number = 0; i < keys.length; i++) {
    const address: string = lgLegacyCoverURL(row[keys[i]]);
    if (address.length > 0) {
      return address;
    }
  }
  return '';
}

/** 值 → 整数（Go strconv.Atoi(nativeText)） */
function lgCountOf(value: Object | undefined): number {
  const text: string = QgJson.str(value).trim();
  if (text.length === 0) {
    return 0;
  }
  const n: number = parseInt(text, 10);
  return Number.isNaN(n) ? 0 : n;
}

/** 行内最大集数（Go nativeNormalize episodes 取 max） */
function lgMaxCount(row: Record<string, Object>, keys: string[]): number {
  let max: number = 0;
  for (let i: number = 0; i < keys.length; i++) {
    const n: number = lgCountOf(row[keys[i]]);
    if (n > max) {
      max = n;
    }
  }
  return max;
}

/** 行 tags → 字符串数组（数组直取 / 字符串按分隔符切分） */
function lgTagsFrom(row: Record<string, Object>): string[] {
  const value: Object | undefined = row['tags'];
  const seen: Record<string, boolean> = {};
  const out: string[] = [];
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const tag: string = QgJson.str(items[i]).trim();
      if (tag.length > 0 && seen[tag] !== true) {
        seen[tag] = true;
        out.push(tag);
      }
    }
    return out;
  }
  const text: string = QgJson.str(value);
  if (text.trim().length > 0) {
    const parts: string[] = text.split(/[,/，、]/);
    for (let i: number = 0; i < parts.length; i++) {
      const tag: string = parts[i].trim();
      if (tag.length > 0 && seen[tag] !== true) {
        seen[tag] = true;
        out.push(tag);
      }
    }
  }
  return out;
}

/** 目录行分类（Go fetchLegacyCatalogCategoryPage 合并 + nativeDramaCategory） */
function lgCatalogGenre(row: Record<string, Object>, tabName: string): string {
  const primary: string = QgJson.pick(row, ['categoryName', 'categoryname', 'category_name', 'category']);
  if (primary.length > 0) {
    return primary;
  }
  if (tabName.length > 0) {
    return tabName;
  }
  return QgJson.pick(row, ['typeName', 'typename', 'type_name', 'sortName', 'sortname', 'sort_name']);
}

/** 详情行分类（Go detailResponse CategoryName mapString 键序） */
function lgDetailGenre(row: Record<string, Object>): string {
  return QgJson.pick(row, ['categoryName', 'categoryname', 'category_name', 'typeName', 'typename',
    'type_name', 'sortName', 'sortname', 'sort_name', 'category']);
}

/** 目录行 → 剧集（Go fetchLegacyCatalogCategoryPage + nativeNormalize） */
function lgDramaFromRow(row: Record<string, Object>, rawID: string, tabName: string): QgDrama {
  const drama: QgDrama = new QgDrama(`cloudfront:${rawID}`,
    lgFirstNonEmpty([QgJson.pick(row, ['title', 'name']), '短剧']), lgCatalogGenre(row, tabName));
  drama.sourceId = 'cloudfront';
  drama.intro = QgJson.pick(row, ['desc', 'description', 'summary', 'intro']);
  drama.cover = lgRowCover(row, LG_ROW_COVER_KEYS);
  drama.episodeCount = lgMaxCount(row, LG_COUNT_KEYS);
  drama.viewsText = QgJson.pick(row, ['views', 'play_count']);
  drama.heat = QgJson.num(row['heat']);
  drama.remark = QgJson.pick(row, ['remark', 'badge']);
  drama.tags = lgTagsFrom(row);
  drama.finished = QgJson.pick(row, ['releaseStatus', 'release_status']) !== 'ongoing';
  return drama;
}

/** 详情行 → 剧集（Go detailResponse + nativeNormalize） */
function lgDetailDramaFromRow(row: Record<string, Object>, sourceID: string): QgDrama {
  const drama: QgDrama = new QgDrama(`cloudfront:${sourceID}`,
    lgFirstNonEmpty([QgJson.pick(row, ['title']), QgJson.pick(row, ['name']), '短剧']),
    lgDetailGenre(row));
  drama.sourceId = 'cloudfront';
  drama.intro = QgJson.pick(row, ['desc', 'description', 'summary', 'intro']);
  drama.cover = lgRowCover(row, LG_DETAIL_COVER_KEYS);
  drama.episodeCount = lgMaxCount(row, LG_COUNT_KEYS);
  drama.viewsText = QgJson.pick(row, ['views', 'play_count']);
  drama.heat = QgJson.num(row['heat']);
  drama.remark = QgJson.pick(row, ['remark', 'badge']);
  drama.tags = lgTagsFrom(row);
  const status: string = QgJson.pick(row, ['releaseStatus', 'release_status']);
  const releaseStatus: string = status.length > 0 ? status :
    lgReleaseStatusFromRemark(QgJson.pick(row, ['remark']));
  drama.finished = releaseStatus !== 'ongoing';
  return drama;
}

/** 分类列表解析（Go legacyTabList：数组或 {list:[...]}） */
function lgParseTabs(payload: Object): LgTab[] {
  let rows: Object[] = [];
  if (Array.isArray(payload)) {
    rows = payload as Object[];
  } else {
    const row: Record<string, Object> = payload as Record<string, Object>;
    rows = QgJson.arr(row['list']);
  }
  const tabs: LgTab[] = [];
  for (let i: number = 0; i < rows.length; i++) {
    const row: Record<string, Object> = rows[i] as Record<string, Object>;
    const id: string = QgJson.str(row['id']).trim();
    const name: string = QgJson.str(row['name']).trim();
    if (id.length === 0) {
      continue;
    }
    tabs.push(new LgTab(id, name));
  }
  return tabs;
}

/** 记忆分类（categories() 懒加载缓存，Go nativeCategories 过滤 id/name 非空） */
function lgRememberTabs(tabs: LgTab[]): void {
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; i < lgCachedTabs.length; i++) {
    seen[lgCachedTabs[i].id] = true;
  }
  for (let i: number = 0; i < tabs.length; i++) {
    const tab: LgTab = tabs[i];
    if (tab.id.length === 0 || tab.name.length === 0 || seen[tab.id] === true) {
      continue;
    }
    seen[tab.id] = true;
    lgCachedTabs.push(new LgTab(tab.id, tab.name));
  }
}

/** 分集行 → LgChapter（Go Chapter JSON 键） */
function lgChapterFromRow(row: Record<string, Object>): LgChapter {
  const ch: LgChapter = new LgChapter();
  ch.id = QgJson.str(row['id']).trim();
  ch.title = QgJson.str(row['title']).trim();
  ch.videoUrl = QgJson.pick(row, ['videoUrl', 'videoURL', 'videourl', 'video_url']);
  const episode: Object | undefined = row['currentEpisode'];
  if (episode !== undefined && episode !== null) {
    const text: string = JSON.stringify(episode);
    ch.currentEpisode = text === 'null' ? '' : text;
  }
  return ch;
}

/** Go uniqueChapters：按 id → videoUrl → idx_N 去重 */
function lgUniqueChapters(rows: Object[]): LgChapter[] {
  const seen: Record<string, boolean> = {};
  const out: LgChapter[] = [];
  for (let i: number = 0; i < rows.length; i++) {
    const ch: LgChapter = lgChapterFromRow(rows[i] as Record<string, Object>);
    let key: string = ch.id;
    if (key.length === 0) {
      key = ch.videoUrl;
    }
    if (key.length === 0) {
      key = `idx_${i}`;
    }
    if (seen[key] === true) {
      continue;
    }
    seen[key] = true;
    out.push(ch);
  }
  return out;
}

/** Go encryptParam：JSON → AES-128-CBC(PKCS7) → base64 */
function lgEncryptParam(params: Object, key: string, iv: string): string {
  const plain: Uint8Array = qgUtf8Encode(JSON.stringify(params));
  const cipher: Uint8Array = qgAesCbcEncrypt(plain, qgUtf8Encode(key), qgUtf8Encode(iv));
  return qgBase64Encode(cipher);
}

/** Go decryptResponse：base64 → SHA256 派生 AES-256-CBC 密钥/IV → 解密 */
function lgDecryptResponse(dataStr: string, interfaceKey: string): string {
  const o: Uint8Array = qgBase64Decode(dataStr.trim());
  if (o.length < 12) {
    throw new Error('加密数据过短');
  }
  const i: Uint8Array = qgSlice(o, 0, 12);
  const r: Uint8Array = qgConcat([qgUtf8Encode(interfaceKey), i]);
  const l: number = r.length >> 1;
  const s: Uint8Array = qgSlice(qgSha256(r), 8, 24);
  const c: Uint8Array = qgConcat([s, qgSlice(r, 0, l)]);
  const a: Uint8Array = qgConcat([qgSlice(r, l, r.length), s]);
  const d: Uint8Array = qgSha256(c);
  const f: Uint8Array = qgSha256(a);
  const m: Uint8Array = qgConcat([qgSlice(d, 0, 8), qgSlice(f, 8, 24), qgSlice(d, 24, 32)]);
  const p: Uint8Array = qgConcat([qgSlice(f, 0, 4), qgSlice(d, 12, 20), qgSlice(f, 28, 32)]);
  const g: Uint8Array = qgSlice(o, 12, o.length);
  if (g.length % 16 !== 0) {
    throw new Error('密文未按块对齐');
  }
  const plain: Uint8Array = qgAesCbcDecrypt(g, m, p);
  return qgUtf8Decode(plain);
}

/** Go apiHashEnabled：hash 标志判定 */
function lgHashEnabled(value: Object | undefined): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'string') {
    const s: string = value.trim().toLowerCase();
    return s !== '' && s !== 'false' && s !== '0' && s !== 'null';
  }
  return true;
}

/** Go fetchProviderText（单候选）：3 次重试 + 退避，4xx 直接失败 */
async function lgFetchProviderText(rawURL: string, referer: string): Promise<string> {
  let lastError: Error | null = null;
  for (let attempt: number = 1; attempt <= 3; attempt++) {
    if (attempt > 1) {
      await lgSleep(attempt * 1000);
    }
    const headers: Record<string, string> = {
      'User-Agent': LG_UA,
      'Referer': referer.length > 0 ? referer : rawURL
    };
    let resp: QgHttpResponse;
    try {
      resp = await QgHttp.request(rawURL, 'GET', headers, null, LG_TIMEOUT_MS);
    } catch (error) {
      lastError = error as Error;
      continue;
    }
    if (resp.data.length > LG_MAX_BODY_BYTES) {
      lastError = new Error('黄果来源返回的数据过大');
      continue;
    }
    if (resp.status < 200 || resp.status >= 300) {
      lastError = new Error(`黄果来源请求失败（HTTP ${resp.status}）`);
      if (resp.status >= 400 && resp.status < 500 && resp.status !== 408) {
        break;
      }
      continue;
    }
    return resp.text();
  }
  if (lastError !== null) {
    throw lastError;
  }
  throw new Error('黄果来源请求失败');
}

/** Go parseAPIHosts：脚本内 cloudfront 域名（排除官网自身，最多 8 个） */
function lgParseApiHosts(script: string): string[] {
  const matches: RegExpExecArray[] = lgAllMatches(RE_LG_CLOUDFRONT_HOST, script);
  const seen: Record<string, boolean> = {};
  const hosts: string[] = [];
  for (let i: number = 0; i < matches.length; i++) {
    const host: string = matches[i][0];
    if (host === LG_FRONTEND || seen[host] === true) {
      continue;
    }
    seen[host] = true;
    hosts.push(host);
    if (hosts.length === 8) {
      break;
    }
  }
  return hosts;
}

/** Go discoverAPIHosts */
async function lgDiscoverApiHosts(): Promise<string[]> {
  const script: string = await lgFetchFrontendScript();
  const hosts: string[] = lgParseApiHosts(script);
  if (hosts.length === 0) {
    throw new Error('官网前端未提供可识别的 API 地址，请稍后重试或更新应用');
  }
  return hosts;
}

/** Go fetchLegacyFrontendScript：官网首页 main-*.js 脚本 */
async function lgFetchFrontendScript(): Promise<string> {
  const page: string = await lgFetchProviderText(`${LG_FRONTEND}/`, `${LG_FRONTEND}/`);
  const matches: RegExpExecArray[] = lgAllMatches(RE_LG_SCRIPT_SRC, page);
  for (let i: number = 0; i < matches.length; i++) {
    const src: string = matches[i][1] || '';
    if (!src.includes('/main-') || !src.endsWith('.js')) {
      continue;
    }
    const assetURL: string = lgResolveURL(`${LG_FRONTEND}/`, src);
    if (lgUrlHostname(assetURL) !== 'd2pypzndaqisk.cloudfront.net') {
      continue;
    }
    return await lgFetchProviderText(assetURL, `${LG_FRONTEND}/`);
  }
  throw new Error('黄果官网未提供可识别的接口脚本');
}

/** Go parseLegacyProtocol：脚本内 interfaceKey/parameterKey/parameterIv */
function lgParseProtocol(script: string): string[] {
  const names: string[] = ['interfaceKey', 'parameterKey', 'parameterIv'];
  const values: string[] = ['', '', ''];
  for (let i: number = 0; i < names.length; i++) {
    const re: RegExp = new RegExp(`["']${names[i]}["']\\s*[:,]\\s*["']([^"'\\\\\\r\\n]+)["']`);
    const match: RegExpExecArray | null = re.exec(script);
    if (match !== null && match.length > 1) {
      values[i] = match[1] || '';
    }
  }
  if (values[0].length === 0 || values[0].length > 512 ||
    values[1].length !== 16 || values[2].length !== 16) {
    throw new Error('黄果官网协议已变化，无法识别当前接口参数');
  }
  return values;
}

/** Go probeAPIHost：4s 探活 /api/app/ping/check */
async function lgProbeApiHost(host: string): Promise<void> {
  const resp: QgHttpResponse = await QgHttp.request(`${host}/api/app/ping/check`, 'GET',
    { 'User-Agent': LG_UA }, null, LG_PROBE_TIMEOUT_MS);
  if (resp.status !== 200) {
    throw new Error(`API 健康检查失败（HTTP ${resp.status}）`);
  }
  const parsed: Object | null = QgJson.parse(resp.text());
  if (parsed === null) {
    throw new Error('API 健康检查返回内容无法解析');
  }
  const row: Record<string, Object> = parsed as Record<string, Object>;
  if (QgJson.num(row['code']) !== 200) {
    throw new Error('API 健康检查未通过');
  }
}

/** Go resetAPIEndpoint：失败域名冷却 1 分钟 */
function lgResetApiEndpoint(failed: string): void {
  lgApiFailures[failed] = Date.now() + LG_HOST_FAILURE_TTL_MS;
  if (lgApiBase === failed) {
    lgApiBase = '';
  }
}

/** Go apiEndpoint：两轮候选（静态 + 官网发现），逐个探活 */
async function lgApiEndpoint(): Promise<string> {
  if (lgApiBase.length > 0) {
    return lgApiBase;
  }
  const seen: Record<string, boolean> = {};
  let lastError: Error | null = null;
  for (let pass: number = 0; pass < 2; pass++) {
    const candidates: string[] = [];
    if (pass === 0) {
      for (let i: number = 0; i < LG_API_FALLBACK_HOSTS.length; i++) {
        candidates.push(LG_API_FALLBACK_HOSTS[i]);
      }
      candidates.unshift(LG_API_BASE);
    } else {
      const discovered: string[] = await lgDiscoverApiHosts();
      for (let i: number = 0; i < discovered.length; i++) {
        candidates.push(discovered[i]);
      }
    }
    for (let i: number = 0; i < candidates.length; i++) {
      const candidate: string = candidates[i];
      if (seen[candidate] === true || Date.now() < lgApiFailures[candidate]) {
        continue;
      }
      seen[candidate] = true;
      try {
        await lgProbeApiHost(candidate);
      } catch (error) {
        lastError = error as Error;
        continue;
      }
      lgApiBase = candidate;
      return candidate;
    }
  }
  const suffix: string = lastError !== null ? `：${lastError.message}` : '';
  throw new Error(`黄果原 API 的候选域名均不可用${suffix}`);
}

/** Go legacyRequest：加密参数 + 请求 + envelope 校验 + 解密，返回 payload 文本 */
async function lgRequest(method: string, apiPath: string, params: Object | null): Promise<string> {
  let lastError: Error | null = null;
  for (let attempt: number = 1; attempt <= LG_ATTEMPTS; attempt++) {
    if (attempt > 1) {
      await lgSleep(attempt * 1000);
    }
    let fullPath: string = apiPath;
    let requestBody: Uint8Array | null = null;
    if (params !== null) {
      const enc: string = lgEncryptParam(params, lgParamKey, lgParamIv);
      if (method === 'GET') {
        const sep: string = fullPath.includes('?') ? '&' : '?';
        fullPath = `${fullPath}${sep}data=${encodeURIComponent(enc)}`;
      } else {
        requestBody = qgUtf8Encode(`{"data":${JSON.stringify(enc)}}`);
      }
    }
    const base: string = await lgApiEndpoint();
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'temp': 'test',
      'X-User-Agent': lgUserAgent(),
      'Origin': LG_FRONTEND,
      'Referer': `${LG_FRONTEND}/`,
      'User-Agent': LG_UA
    };
    if (lgToken.length > 0) {
      headers['Authorization'] = lgToken;
    }
    if (requestBody !== null) {
      headers['Content-Type'] = 'application/json';
    }
    let resp: QgHttpResponse;
    try {
      resp = await QgHttp.request(`${base}${fullPath}`, method, headers, requestBody, LG_TIMEOUT_MS);
    } catch (error) {
      lastError = error as Error;
      lgResetApiEndpoint(base);
      continue;
    }
    if (resp.data.length > LG_MAX_BODY_BYTES) {
      throw new Error('API 响应过大');
    }
    if (resp.status < 200 || resp.status >= 300) {
      lastError = new Error(`黄果 API 请求失败（HTTP ${resp.status}）`);
      if (resp.status >= 500) {
        lgResetApiEndpoint(base);
        continue;
      }
      if (resp.status >= 400) {
        throw lastError;
      }
      continue;
    }
    const env: Object | null = QgJson.parse(resp.text());
    if (env === null) {
      lastError = new Error('黄果 API 返回内容无法解析');
      continue;
    }
    const envRow: Record<string, Object> = env as Record<string, Object>;
    const code: string = QgJson.str(envRow['code']);
    if (code.length > 0 && code !== 'null' && code !== '200' && code !== '0') {
      let message: string = QgJson.str(envRow['msg']).trim();
      if (message.length === 0) {
        message = '请检查访问配置或刷新登录凭证';
      }
      if (lgToken.length > 0) {
        message = message.split(lgToken).join('[已隐藏]');
      }
      throw new LgApiError(lgTruncate(code, 20), lgTruncate(message, 160));
    }
    const dataValue: Object | undefined = envRow['data'];
    let payload: string = '';
    if (dataValue !== undefined && dataValue !== null) {
      if (lgHashEnabled(envRow['hash'])) {
        if (typeof dataValue !== 'string') {
          lastError = new Error('黄果 API 加密数据格式无效');
          continue;
        }
        try {
          payload = lgDecryptResponse(dataValue, lgInterfaceKey);
        } catch (error) {
          lastError = error as Error;
          continue;
        }
      } else {
        payload = JSON.stringify(dataValue);
      }
    }
    if (payload.length === 0 || payload === 'null') {
      throw new Error('黄果 API 未返回数据，请检查登录凭证或接口是否变更');
    }
    return payload;
  }
  if (lastError !== null) {
    throw lastError;
  }
  throw new Error('黄果 API 请求失败');
}

/** Go bootstrapLegacySession：协议解析（24h）+ DevID + 访客登录 */
async function lgEnsureCredentials(): Promise<void> {
  if (!lgValidProtocol() || Date.now() - lgProtocolAt > LG_PROTOCOL_TTL_MS) {
    let script: string = '';
    try {
      script = await lgFetchFrontendScript();
    } catch (error) {
      throw new Error(`获取黄果官网协议失败: ${(error as Error).message}`);
    }
    const protocol: string[] = lgParseProtocol(script);
    lgInterfaceKey = protocol[0];
    lgParamKey = protocol[1];
    lgParamIv = protocol[2];
    lgProtocolAt = Date.now();
  }
  if (!lgValidProtocol()) {
    throw new Error('黄果 API 协议配置无效，请更新应用后重试');
  }
  if (lgDeviceId.length === 0) {
    lgDeviceId = `${qgRandomHex(8).toUpperCase()}${Date.now()}`;
  }
  if (lgToken.length === 0 || !lgValidToken(lgToken)) {
    let payload: string = '';
    try {
      payload = await lgRequest('POST', '/api/app/mine/login/h5', new LgLoginParams(lgDeviceId));
    } catch (error) {
      throw new Error(`黄果访客登录失败: ${(error as Error).message}`);
    }
    const parsed: Object | null = QgJson.parse(payload);
    const row: Record<string, Object> = parsed !== null ? parsed as Record<string, Object> : {};
    const token: string = QgJson.str(row['token']).trim();
    if (token.length === 0 || !lgValidToken(token)) {
      throw new Error('黄果访客登录未返回有效令牌');
    }
    lgToken = token;
  }
}

/** Go fetchAPI：会话保证 + 5005 失效重登一次，返回解析后的 JSON */
async function lgFetchAPI(apiPath: string, params: Object | null): Promise<Object> {
  for (let attempt: number = 0; attempt < 2; attempt++) {
    await lgEnsureCredentials();
    let payload: string = '';
    try {
      payload = await lgRequest('GET', apiPath, params);
    } catch (error) {
      const err: Error = error as Error;
      if (attempt === 0 && err instanceof LgApiError && err.code === '5005') {
        lgToken = '';
        continue;
      }
      throw err;
    }
    const parsed: Object | null = QgJson.parse(payload);
    if (parsed === null) {
      throw new Error('黄果 API 返回内容无法解析');
    }
    return parsed;
  }
  throw new Error('黄果访客登录已失效，请稍后重试');
}

/** 详情 + 分集（Go fetchLegacyDetail：detail → 空则 chapter list → 去重 → 集号/标题 → 排序） */
async function lgFetchChapterData(sourceID: string): Promise<LgChapterData> {
  const data: LgChapterData = new LgChapterData();
  const detailPayload: Object = await lgFetchAPI(`/api/app/playlet/detail/${encodeURIComponent(sourceID)}`, null);
  data.row = detailPayload as Record<string, Object>;
  let rows: Object[] = QgJson.arr(data.row['chapters']);
  if (rows.length === 0) {
    const listPayload: Object = await lgFetchAPI(`/api/app/playlet-chapter/list/${encodeURIComponent(sourceID)}`, null);
    if (!Array.isArray(listPayload)) {
      throw new Error('黄果分集列表格式无效');
    }
    rows = listPayload as Object[];
  }
  const chapters: LgChapter[] = lgUniqueChapters(rows);
  for (let i: number = 0; i < chapters.length; i++) {
    const ch: LgChapter = chapters[i];
    if (lgChapterEpisodeNumber(ch, 0) <= 0) {
      ch.currentEpisode = `${i + 1}`;
    }
    ch.epKey = lgFirstNonEmpty([ch.id, `${i + 1}`]);
    ch.title = lgFirstNonEmpty([ch.title, `第${lgEpisodeString(ch, i + 1)}集`]);
    ch.order = lgChapterEpisodeNumber(ch, i + 1);
  }
  chapters.sort((a: LgChapter, b: LgChapter): number => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    return a.epKey < b.epKey ? -1 : (a.epKey > b.epKey ? 1 : 0);
  });
  data.chapters = chapters;
  return data;
}

export class LegacySource extends QgSource {
  constructor() {
    super('cloudfront', '黄果旧版');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < lgCachedTabs.length; i++) {
      all.push(new QgCategory(lgCachedTabs[i].id, lgCachedTabs[i].name));
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000) {
      throw new Error('黄果旧版目录页码无效');
    }
    const category: string = categoryId.trim();
    if (category.length > 128 || category.includes('|') || category.includes('/') ||
      category.includes('\\') || category.indexOf('\u0000') >= 0 ||
      category.includes('\r') || category.includes('\n')) {
      throw new Error('黄果旧版分类无效');
    }
    const tabsPayload: Object = await lgFetchAPI('/api/app/playlet-tab/all', null);
    const tabs: LgTab[] = lgParseTabs(tabsPayload);
    if (tabs.length === 0) {
      throw new Error('黄果旧 API 未返回可用分类');
    }
    lgRememberTabs(tabs);
    const seen: Record<string, boolean> = {};
    const items: QgDrama[] = [];
    const failures: Error[] = [];
    let hasMore: boolean = false;
    let found: boolean = false;
    for (let t: number = 0; t < tabs.length; t++) {
      const tab: LgTab = tabs[t];
      if (category.length > 0 && category === tab.id) {
        found = true;
      }
      if (tab.id.length === 0 || (category.length > 0 && category !== tab.id)) {
        continue;
      }
      try {
        const payload: Object = await lgFetchAPI(
          `/api/app/playlet/home/tab/${encodeURIComponent(tab.id)}`,
          new LgTabParams(`${page}`, `${LG_PAGE_SIZE}`));
        const row: Record<string, Object> = payload as Record<string, Object>;
        const list: Object[] = QgJson.arr(row['list']);
        hasMore = hasMore || list.length >= LG_PAGE_SIZE;
        for (let i: number = 0; i < list.length; i++) {
          const raw: Record<string, Object> = list[i] as Record<string, Object>;
          const rawID: string = QgJson.str(raw['id']).trim();
          if (rawID.length === 0 || seen[rawID] === true) {
            continue;
          }
          seen[rawID] = true;
          items.push(lgDramaFromRow(raw, rawID, tab.name));
        }
      } catch (error) {
        failures.push(new Error(`${tab.name}: ${(error as Error).message}`));
        hasMore = true;
      }
    }
    if (category.length > 0 && !found) {
      throw new Error('该分类已调整，请刷新分类列表');
    }
    if (items.length === 0 && failures.length > 0) {
      throw failures[0];
    }
    if (items.length === 0 && page === 1) {
      throw new Error('站源暂未返回剧集，请稍后刷新');
    }
    return new QgPageResult(items, hasMore);
  }

  /** 无服务端搜索：取目录第一页本地过滤 */
  async search(keyword: string, page: number): Promise<QgPageResult> {
    const query: string = keyword.trim();
    if (query.length === 0 || query.length > 256 || page < 1 || page > 1000000) {
      throw new Error('黄果旧版搜索关键词无效');
    }
    if (page > 1) {
      return new QgPageResult([], false);
    }
    const result: QgPageResult = await this.catalogPage('', 1);
    const normWords: string[] = [];
    const words: string[] = query.split(/\s+/);
    for (let w: number = 0; w < words.length; w++) {
      const normalized: string = lgSearchText(words[w]);
      if (normalized.length > 0) {
        normWords.push(normalized);
      }
    }
    const items: QgDrama[] = [];
    for (let i: number = 0; i < result.dramas.length; i++) {
      const drama: QgDrama = result.dramas[i];
      const haystack: string = lgSearchText(`${drama.title} ${drama.intro} ${drama.tags.join(' ')}`);
      let matched: boolean = true;
      for (let w: number = 0; w < normWords.length; w++) {
        if (!haystack.includes(normWords[w])) {
          matched = false;
          break;
        }
      }
      if (matched) {
        items.push(drama);
      }
    }
    return new QgPageResult(items, false);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    let sourceID: string = dramaId.startsWith('cloudfront:') ?
      dramaId.substring('cloudfront:'.length) : dramaId;
    sourceID = sourceID.trim();
    if (sourceID.length === 0 || sourceID.length > 512 || !RE_LG_RANK_ID.test(sourceID)) {
      throw new Error('无效的黄果旧版剧集 ID');
    }
    const data: LgChapterData = await lgFetchChapterData(sourceID);
    const rowID: string = QgJson.str(data.row['id']).trim();
    if (rowID.length > 0 && rowID !== sourceID && rowID !== `cloudfront:${sourceID}`) {
      throw new Error('黄果旧版详情与请求剧集不符');
    }
    const drama: QgDrama = lgDetailDramaFromRow(data.row, sourceID);
    const episodes: QgEpisode[] = [];
    for (let i: number = 0; i < data.chapters.length; i++) {
      const ch: LgChapter = data.chapters[i];
      episodes.push(new QgEpisode(ch.epKey, ch.title, ch.order));
    }
    if (episodes.length === 0) {
      throw new Error('该剧暂时没有可播放的分集');
    }
    if (drama.episodeCount < episodes.length) {
      drama.episodeCount = episodes.length;
    }
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    let sourceID: string = dramaId.startsWith('cloudfront:') ?
      dramaId.substring('cloudfront:'.length) : dramaId;
    sourceID = sourceID.trim();
    const episode: string = episodeId.trim();
    if (sourceID.length === 0 || sourceID.length > 512 || !RE_LG_RANK_ID.test(sourceID) ||
      episode.length === 0 || episode.length > 512) {
      throw new Error('黄果旧版分集无效');
    }
    await lgEnsureCredentials();
    const data: LgChapterData = await lgFetchChapterData(sourceID);
    let target: LgChapter | null = null;
    for (let i: number = 0; i < data.chapters.length; i++) {
      if (data.chapters[i].epKey === episode) {
        target = data.chapters[i];
        break;
      }
    }
    if (target === null) {
      throw new Error('未找到该分集，请刷新剧集详情');
    }
    if (target.videoUrl.length === 0) {
      throw new Error('此分集没有可用的播放地址');
    }
    let address: string = target.videoUrl;
    if (!lgIsHttpUrl(address)) {
      const base: string = await lgApiEndpoint();
      const trimmed: string = address.replace(/^\/+/, '').replace(/\/+$/, '');
      const playParams: Record<string, string> = { 'c': LG_CDN_URL, 'token': lgToken };
      address = `${base}/api/app/vid/h5/m3u8/${encodeURIComponent(trimmed)}?${qgBuildQuery(playParams)}`;
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${LG_FRONTEND}/`;
    info.headers = { 'User-Agent': LG_UA, 'Referer': `${LG_FRONTEND}/` };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    const hostname: string = lgUrlHostname(url);
    if (hostname.endsWith('.zdmhyg.cn') || hostname === 'pic.tuafjz.cn') {
      return { 'User-Agent': LG_UA, 'Referer': 'https://huangguoai.com/' };
    }
    return { 'User-Agent': LG_UA, 'Referer': `${LG_FRONTEND}/` };
  }
}
