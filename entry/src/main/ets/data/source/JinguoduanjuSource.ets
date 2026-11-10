/**
 * 禁果短剧站源（站点 https://jinguoduanju.app，接口 /api/v1，备用线路 jgdj.app / play.jinguoduanju.app）。
 * 设备授权：随机 deviceId 换取 Bearer token（401 自动刷新重试一次，并发合并单飞）；
 * 多线路候选：任一线路成功后固定；分类（top-navigation / filter-config）懒加载；
 * 目录/搜索共用一条列表接口，客户端按 24 条/页分页（列表缓存 10 分钟）；
 * 播放走 /episodes/{id}/play，allowance 拒绝时提示会员/解锁。
 * 移植自 guoapp provider_jinguoduanju.go + provider_jinguoduanju_client.go（目录/搜索/详情/播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBuildQuery, qgRandomBytes, qgToHex, qgUtf8Encode } from '../QgBytes';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

/** 站点地址（Go jinguoDuanjuBaseURL） */
const JD_SITE: string = 'https://jinguoduanju.app';
/** 接口 UA（Go jinguoDuanjuUserAgent） */
const JD_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
/** 封面/播放请求 UA（Go config_defaults.go userAgent） */
const JD_MEDIA_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 「推荐」「热度」特殊分类 ID（Go jinguoDuanjuHomeCategory / jinguoDuanjuHeatCategory） */
const JD_HOME: string = 'home';
const JD_HEAT: string = 'heat';
/** 客户端分页每页条数（Go jinguoDuanjuPageSize） */
const JD_PAGE_SIZE: number = 24;
/** 目录列表缓存时长（Go storeListing 10 分钟） */
const JD_LISTING_TTL_MS: number = 10 * 60 * 1000;
const JD_TIMEOUT_MS: number = 15000;
/** 授权过期哨兵（Go errJinguoDuanjuAuthExpired，精确匹配） */
const JD_AUTH_EXPIRED: string = '禁果短剧访问授权已失效，请重试';
/** 接口业务失败前缀（Go jinguoDuanjuStatusError 带 API 消息时的文案） */
const JD_STATUS_PREFIX: string = '禁果短剧接口返回失败：';

/** Go webProviderNumericID：1 开头的纯数字站内 ID */
const RE_JD_ID: RegExp = /^[1-9][0-9]{0,17}$/;
const RE_JD_INT: RegExp = /^[+-]?[0-9]+$/;
/** token 仅允许可见 ASCII（Go IndexFunc r<=32||r>=127 判非法） */
const RE_JD_TOKEN_CHARS: RegExp = /^[\x21-\x7e]+$/;
/** 状态错误形态：`host HTTP nnn[:reason]`（Go catalogResponseError） */
const RE_JD_STATUS_HOST: RegExp = /^[a-zA-Z0-9.-]+ HTTP [0-9]{3}/;

/** Go webProviderInteger 结果：value 为解析值（失败为 0），valid 表示 0..maximum */
class JdIntResult {
  value: number = 0;
  valid: boolean = false;
}

/** 目录列表缓存条目（Go jinguoDuanjuListing） */
class JdListing {
  items: QgDrama[] = [];
  expiresAt: number = 0;
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function jdDecodeNumericEntities(text: string): string {
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
function jdUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = jdDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go truncate：超长截断加省略号（按码点计数） */
function jdTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go nativeText：字符串 trim / 数字取整 / 数组与对象（url/src/cover/image/pic）下钻 */
function jdNativeText(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  if (typeof value === 'number') {
    return `${Math.trunc(value)}`;
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const text: string = jdNativeText(items[i]);
      if (text.length > 0) {
        return text;
      }
    }
    return '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'src', 'cover', 'image', 'pic'];
    for (let i: number = 0; i < keys.length; i++) {
      const text: string = jdNativeText(map[keys[i]]);
      if (text.length > 0) {
        return text;
      }
    }
  }
  return '';
}

/** Go mapString：依次取第一个非空字符串字段（字符串/数字/布尔，自动 trim） */
function jdMapString(row: Record<string, Object> | null, keys: string[]): string {
  if (row === null) {
    return '';
  }
  for (let i: number = 0; i < keys.length; i++) {
    const value: string = QgJson.str(row[keys[i]]).trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Go firstNonEmpty：取第一个 trim 后非空的值 */
function jdFirstNonEmpty(first: string, second: string): string {
  const a: string = first.trim();
  if (a.length > 0) {
    return a;
  }
  return second.trim();
}

/** Go webProviderInteger：解析整数；value 为解析值（失败 0），valid 表示 0..maximum */
function jdInteger(value: Object | undefined, maximum: number): JdIntResult {
  const result: JdIntResult = new JdIntResult();
  const text: string = jdNativeText(value);
  if (!RE_JD_INT.test(text)) {
    return result;
  }
  const parsed: number = Number(text);
  result.value = parsed;
  result.valid = parsed >= 0 && parsed <= maximum;
  return result;
}

/** Go jinguoDuanjuActive：字段缺失/null 视为启用，存在时必须为 true */
function jdActive(row: Record<string, Object> | null, key: string): boolean {
  if (row === null) {
    return true;
  }
  const value: Object | undefined = row[key];
  if (value === undefined || value === null) {
    return true;
  }
  return value === true;
}

/** Go validJinguoDuanjuCategory：'' / home / heat / nav:数字 / tag:数字 */
function jdValidCategory(category: string): boolean {
  if (category === '' || category === JD_HOME || category === JD_HEAT) {
    return true;
  }
  const colon: number = category.indexOf(':');
  if (colon < 0) {
    return false;
  }
  const kind: string = category.substring(0, colon);
  const id: string = category.substring(colon + 1);
  return (kind === 'nav' || kind === 'tag') && RE_JD_ID.test(id);
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function jdIsHttpUrl(raw: string): boolean {
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

/** 取 URL 的 origin（scheme://host，含端口；Go jinguoDuanjuOrigin） */
function jdOriginOf(base: string): string {
  const schemeIdx: number = base.indexOf('://');
  if (schemeIdx <= 0) {
    return '';
  }
  const scheme: string = base.substring(0, schemeIdx);
  const rest: string = base.substring(schemeIdx + 3);
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
  const host: string = rest.substring(0, cut);
  if (host.length === 0) {
    return '';
  }
  return `${scheme}://${host}`;
}

/** 取 URL 的主机名（小写、去端口） */
function jdHostOf(raw: string): string {
  let rest: string = raw.trim();
  const schemeIdx: number = rest.indexOf('://');
  if (schemeIdx >= 0) {
    rest = rest.substring(schemeIdx + 3);
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
  const colon: number = hostPart.indexOf(':');
  if (colon >= 0) {
    hostPart = hostPart.substring(0, colon);
  }
  return hostPart.toLowerCase();
}

/** 相对地址补全（url.ResolveReference 简化版，含 ./ 与 ../ 段处理） */
function jdResolveReference(pageURL: string, ref: string): string {
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

/** 去除首尾指定字符集合 */
function jdTrimChars(text: string, chars: string): string {
  let start: number = 0;
  let end: number = text.length;
  while (start < end && chars.includes(text.charAt(start))) {
    start++;
  }
  while (end > start && chars.includes(text.charAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/** Go resolveProviderURL：实体解码 + `\/` 修正 + 协议相对补全 + http→https 升级 */
function jdResolveProviderUrl(pageURL: string, ref: string): string {
  let value: string = jdUnescapeHtml(ref).trim();
  if (value.length === 0) {
    return '';
  }
  value = value.replaceAll('\\/', '/');
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
    if (value.startsWith('http://')) {
      return `https://${value.substring(7)}`;
    }
    return value;
  }
  let resolved: string = jdResolveReference(pageURL, value);
  if (resolved.startsWith('http://')) {
    resolved = `https://${resolved.substring(7)}`;
  }
  return resolved;
}

/** Go normalizeProviderMediaURL：解码/去引号/JSON 反转义/补全，须含 .m3u8 或 .mp4 */
function jdNormalizeMediaUrl(pageURL: string, raw: string): string {
  let value: string = jdUnescapeHtml(raw).trim();
  value = jdTrimChars(value, ' \t\r\n"\'');
  if (value.length === 0) {
    return '';
  }
  const quoted: string = `"${value.replaceAll('"', '\\"')}"`;
  const unquoted: Object | null = QgJson.parse(quoted);
  if (typeof unquoted === 'string') {
    value = unquoted;
  }
  value = value.replaceAll('\\/', '/');
  const resolved: string = jdResolveProviderUrl(pageURL, value);
  const lower: string = resolved.toLowerCase();
  if (!lower.includes('.m3u8') && !lower.includes('.mp4')) {
    return '';
  }
  return resolved;
}

/** Go providerCoverAddress：数组/对象/字符串取封面并相对补全 */
function jdCoverAddress(value: Object | undefined, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = jdCoverAddress(items[i], pageURL);
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
    const resolved: string = jdResolveReference(pageURL, text);
    return jdIsHttpUrl(resolved) ? resolved : '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = jdCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go firstPresent：第一个存在且 nativeText 非空的字段（返回原始值） */
function jdFirstPresent(row: Record<string, Object> | null, keys: string[]): Object | undefined {
  if (row === null) {
    return undefined;
  }
  for (let i: number = 0; i < keys.length; i++) {
    const value: Object | undefined = row[keys[i]];
    if (value !== undefined && value !== null && jdNativeText(value).length > 0) {
      return value;
    }
  }
  return undefined;
}

/** Go jinguoDuanjuDramaRows：数组或 {dramas/list/items/records} 数组 */
function jdDramaRows(value: Object): Object[] {
  if (Array.isArray(value)) {
    const rows: Object[] = value as Object[];
    if (rows.length > 20000) {
      throw new Error('禁果短剧目录格式无效');
    }
    return rows;
  }
  const row: Record<string, Object> | null = QgJson.obj(value);
  if (row !== null) {
    const keys: string[] = ['dramas', 'list', 'items', 'records'];
    for (let i: number = 0; i < keys.length; i++) {
      const candidate: Object | undefined = row[keys[i]];
      if (Array.isArray(candidate)) {
        const rows: Object[] = candidate as Object[];
        if (rows.length > 20000) {
          throw new Error('禁果短剧目录格式无效');
        }
        return rows;
      }
    }
  }
  throw new Error('禁果短剧目录格式无效');
}

/** Go jinguoDuanjuErrorMessage：接口错误 message/msg/tip（≤180 码点、无换行） */
function jdErrorMessage(bodyText: string): string {
  const parsed: Object | null = QgJson.parse(bodyText);
  if (parsed === null) {
    return '';
  }
  const message: string = jdMapString(QgJson.obj(parsed), ['message', 'msg', 'tip']);
  if (message.length === 0 || Array.from(message).length > 180 ||
    message.includes('\r') || message.includes('\n')) {
    return '';
  }
  return message;
}

/** Go catalogResponseBlockReason：Cloudflare 拦截/人机验证识别 */
function jdBlockReason(headers: Record<string, string>, bodyText: string): string {
  let page: string = bodyText;
  if (page.length > 64 * 1024) {
    page = page.substring(0, 64 * 1024);
  }
  page = page.toLowerCase();
  if (page.includes('cloudflare') &&
    (page.includes('sorry, you have been blocked') || page.includes('you are unable to access'))) {
    return 'Cloudflare 拒绝了当前请求';
  }
  const mitigated: string = headers['cf-mitigated'] !== undefined ? headers['cf-mitigated'] : '';
  if (mitigated.toLowerCase() === 'challenge' || page.includes('_cf_chl_opt') ||
    (page.includes('<title>just a moment') && page.includes('cloudflare'))) {
    return '站点要求浏览器验证，当前请求无法通过';
  }
  return '';
}

/** Go jinguoDuanjuDramaFromMap：行记录 → QgDrama（资料不完整抛错） */
function jdDramaFromMap(row: Record<string, Object> | null, site: string, sourceID: string): QgDrama {
  const id: string = jdMapString(row, ['id']);
  const title: string = jdMapString(row, ['title']);
  if (!RE_JD_ID.test(id) || title.length === 0) {
    throw new Error('禁果短剧剧集资料不完整');
  }
  if (sourceID.length > 0 && sourceID !== id) {
    throw new Error('禁果短剧详情与请求剧集不符');
  }
  const episodeResult: JdIntResult = jdInteger(row !== null ? row['episodeCount'] : undefined, 100000);
  const tags: string[] = [];
  const seenTags: Record<string, boolean> = {};
  const tagValues: Object[] = row !== null ? QgJson.fieldArr(row, 'tags') : [];
  for (let i: number = 0; i < tagValues.length; i++) {
    const tag: string = jdNativeText(tagValues[i]).trim();
    if (tag.length === 0 || Array.from(tag).length > 24 || seenTags[tag] === true || tags.length >= 32) {
      continue;
    }
    seenTags[tag] = true;
    tags.push(tag);
  }
  const description: string = jdTruncate(
    jdFirstNonEmpty(jdMapString(row, ['description']), jdMapString(row, ['subtitle'])), 12000);
  const cover: string = jdCoverAddress(
    row !== null ? jdFirstPresent(row, ['coverUrl', 'cover']) : undefined, `${site}/`);
  const genre: string = tags.length > 0 ? tags[0] : '短剧';
  const drama: QgDrama = new QgDrama(`jinguoduanju:${id}`, jdTruncate(title, 512), genre);
  drama.sourceId = 'jinguoduanju';
  drama.episodeCount = episodeResult.value;
  drama.tags = tags;
  drama.intro = description;
  drama.cover = cover;
  const heatResult: JdIntResult = jdInteger(row !== null ? row['heat'] : undefined, 1000000000);
  if (heatResult.valid && heatResult.value > 0) {
    drama.heat = heatResult.value;
  }
  return drama;
}

/** 目录行解析（Go err != nil 时 continue 的对应物）：失败返回 null */
function jdTryDramaFromMap(row: Record<string, Object> | null, site: string, sourceID: string): QgDrama | null {
  try {
    return jdDramaFromMap(row, site, sourceID);
  } catch (error) {
    return null;
  }
}

/** Go jinguoDuanjuCatalogQuery：分类/关键词 → 查询参数（非法抛错） */
function jdCatalogQuery(category: string, query: string): Record<string, string> {
  const trimmed: string = query.trim();
  if (!jdValidCategory(category) || trimmed.length > 256) {
    throw new Error('禁果短剧目录查询参数无效');
  }
  const values: Record<string, string> = { 'sort': 'latest' };
  if (trimmed.length > 0) {
    values['q'] = trimmed;
    return values;
  }
  if (category === JD_HOME) {
    values['displayArea'] = 'HOME_FEED';
  } else if (category === JD_HEAT) {
    values['sort'] = 'heat';
  } else if (category.startsWith('nav:')) {
    values['navigationId'] = category.substring(4);
  } else if (category.startsWith('tag:')) {
    values['tags'] = category.substring(4);
  }
  return values;
}

/** 分类收集（Go fetchJinguoDuanjuCategories 的 add 闭包）：≤64 个、名 ≤24 码点、去重 */
function jdAddCategory(id: string, name: string, categories: QgCategory[],
  seenIds: Record<string, boolean>, seenNames: Record<string, boolean>): void {
  const trimmed: string = name.trim();
  if (categories.length >= 64 || !jdValidCategory(id) || trimmed.length === 0 ||
    Array.from(trimmed).length > 24 || seenIds[id] === true || seenNames[trimmed] === true) {
    return;
  }
  seenIds[id] = true;
  seenNames[trimmed] = true;
  categories.push(new QgCategory(id, trimmed));
}

export class JinguoduanjuSource extends QgSource {
  /** 固定线路（成功过的 /api/v1 基址，Go client.base） */
  private static pinnedBase: string = '';
  /** 站点 origin（封面/Referer 基准，Go client.site） */
  private static siteOrigin: string = '';
  /** 随机设备标识（UUID v4 形态） */
  private static deviceId: string = '';
  /** 设备授权 Bearer token（会话内缓存） */
  private static token: string = '';
  /** 进行中的授权请求（并发合并，Go jinguoDuanjuAuthCall pending） */
  private static authPending: Promise<string> | null = null;
  /** 目录列表缓存（Go client.listings） */
  private static listings: Map<string, JdListing> = new Map<string, JdListing>();
  /** 分类缓存（推荐/热度 静态打底，nav/tag 动态补充） */
  private static categoryCache: QgCategory[] =
    [new QgCategory(JD_HOME, '推荐'), new QgCategory(JD_HEAT, '热度')];
  private static categoriesLoaded: boolean = false;
  private static categoriesPromise: Promise<void> | null = null;

  constructor() {
    super('jinguoduanju', '禁果短剧');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < JinguoduanjuSource.categoryCache.length; i++) {
      all.push(JinguoduanjuSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.jdCatalogPage(categoryId.trim(), '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.jdCatalogPage('', keyword.trim(), page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceID: string = (dramaId.startsWith('jinguoduanju:') ?
      dramaId.substring('jinguoduanju:'.length) : dramaId).trim();
    if (!RE_JD_ID.test(sourceID)) {
      throw new Error('禁果短剧剧集 ID 无效');
    }
    const decoded: Object = await this.jdGet(`/dramas/${encodeURIComponent(sourceID)}`, {}, 4 * 1024 * 1024);
    const object: Record<string, Object> | null = QgJson.obj(decoded);
    let row: Record<string, Object> | null = object !== null ? QgJson.obj(object['drama']) : null;
    if (row === null) {
      row = object;
    }
    if (object !== null) {
      const description: string = jdMapString(object, ['description']);
      if (description.length > 0 && row !== null && jdMapString(row, ['description']).length === 0) {
        row['description'] = description;
      }
    }
    const drama: QgDrama = jdDramaFromMap(row, JinguoduanjuSource.jdSiteURL(), sourceID);
    const rawEpisodes: Object | undefined = object !== null ? object['episodes'] : undefined;
    if (!Array.isArray(rawEpisodes)) {
      throw new Error('禁果短剧分集目录格式无效');
    }
    const rows: Object[] = rawEpisodes as Object[];
    if (rows.length > 10000) {
      throw new Error('禁果短剧分集目录格式无效');
    }
    const episodes: QgEpisode[] = [];
    const seenIds: Record<string, boolean> = {};
    const seenNumbers: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const episode: Record<string, Object> | null = QgJson.obj(rows[i]);
      const id: string = jdMapString(episode, ['id']);
      const numberResult: JdIntResult = jdInteger(episode !== null ? episode['number'] : undefined, 100000);
      if (!RE_JD_ID.test(id) || !numberResult.valid || numberResult.value < 1 ||
        seenIds[id] === true || seenNumbers[`${numberResult.value}`] === true) {
        throw new Error('禁果短剧分集编号无效或重复，请刷新详情');
      }
      seenIds[id] = true;
      seenNumbers[`${numberResult.value}`] = true;
      const title: string = jdFirstNonEmpty(jdMapString(episode, ['title']), `第${numberResult.value}集`);
      episodes.push(new QgEpisode(id, jdTruncate(title, 256), numberResult.value));
    }
    if (episodes.length > 0) {
      const listedValid: boolean = drama.episodeCount >= 0 && drama.episodeCount <= 100000;
      if (!listedValid || episodes.length > drama.episodeCount) {
        drama.episodeCount = episodes.length;
      }
    }
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceID: string = (dramaId.startsWith('jinguoduanju:') ?
      dramaId.substring('jinguoduanju:'.length) : dramaId).trim();
    const episodeID: string = episodeId.trim();
    if (!RE_JD_ID.test(sourceID)) {
      throw new Error('禁果短剧播放分集信息无效，请刷新详情');
    }
    if (!RE_JD_ID.test(episodeID)) {
      throw new Error('禁果短剧播放分集 ID 无效');
    }
    const decoded: Object =
      await this.jdGet(`/episodes/${encodeURIComponent(episodeID)}/play`, {}, 256 * 1024);
    const row: Record<string, Object> | null = QgJson.obj(decoded);
    const echoed: string = jdMapString(row, ['episodeId']);
    if (echoed.length > 0 && echoed !== episodeID) {
      throw new Error('禁果短剧返回的播放地址与请求分集不符');
    }
    const allowance: Record<string, Object> | null = QgJson.field(row, 'allowance');
    if (allowance !== null && allowance['allowed'] === false) {
      throw new Error('禁果短剧该集需要会员或解锁后才能播放');
    }
    const referer: string = `${JinguoduanjuSource.jdSiteURL()}/`;
    const address: string = jdNormalizeMediaUrl(referer, jdMapString(row, ['videoUrl']));
    if (!jdIsHttpUrl(address)) {
      throw new Error('禁果短剧未提供该集播放地址，请确认是否需要会员或解锁');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = referer;
    info.headers = { 'User-Agent': JD_MEDIA_UA, 'Referer': referer };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': JD_MEDIA_UA, 'Referer': `${JinguoduanjuSource.jdSiteURL()}/` };
  }

  /** 站点 origin（未探测到线路前用默认站点） */
  private static jdSiteURL(): string {
    return JinguoduanjuSource.siteOrigin.length > 0 ? JinguoduanjuSource.siteOrigin : JD_SITE;
  }

  /** 目录/搜索共用的客户端分页（Go fetchJinguoDuanjuCatalogPage） */
  private async jdCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    const trimmedQuery: string = query.trim();
    if (!jdValidCategory(category) || trimmedQuery.length > 256) {
      throw new Error('禁果短剧目录查询参数无效');
    }
    if (page < 1 || page > 1000000) {
      throw new Error('禁果短剧目录页码无效');
    }
    await this.jdEnsureCategories();
    const key: string = `${category}\u0000${trimmedQuery}`;
    let items: QgDrama[] | null = null;
    const cached: JdListing | undefined = JinguoduanjuSource.listings.get(key);
    if (cached !== undefined && Date.now() <= cached.expiresAt) {
      items = cached.items;
    }
    if (page === 1 || items === null) {
      items = await this.jdFetchDramas(category, trimmedQuery);
      if (JinguoduanjuSource.listings.size >= 32) {
        JinguoduanjuSource.listings.clear();
      }
      const fresh: JdListing = new JdListing();
      fresh.items = items;
      fresh.expiresAt = Date.now() + JD_LISTING_TTL_MS;
      JinguoduanjuSource.listings.set(key, fresh);
    }
    const start: number = (page - 1) * JD_PAGE_SIZE;
    if (start >= items.length) {
      return new QgPageResult([], false);
    }
    const end: number = Math.min(start + JD_PAGE_SIZE, items.length);
    return new QgPageResult(items.slice(start, end), end < items.length);
  }

  /** Go fetchJinguoDuanjuDramas：/dramas → 去重剧集列表（坏行跳过） */
  private async jdFetchDramas(category: string, query: string): Promise<QgDrama[]> {
    const queryValues: Record<string, string> = jdCatalogQuery(category, query);
    const decoded: Object = await this.jdGet('/dramas', queryValues, 8 * 1024 * 1024);
    const rows: Object[] = jdDramaRows(decoded);
    const site: string = JinguoduanjuSource.jdSiteURL();
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = jdTryDramaFromMap(QgJson.obj(rows[i]), site, '');
      if (drama === null || seen[drama.id] === true) {
        continue;
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return items;
  }

  /** Go client.get：带 Bearer 的 GET，授权过期清 token 重试一次 */
  private async jdGet(route: string, query: Record<string, string>, limitBytes: number): Promise<Object> {
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const token: string = await this.jdAccessToken();
      try {
        const decoded: Object =
          await this.jdRequest('GET', route, query, null, token, attempt === 0, limitBytes);
        return decoded;
      } catch (error) {
        const err: Error = error as Error;
        if (attempt === 0 && err.message === JD_AUTH_EXPIRED) {
          if (JinguoduanjuSource.token === token) {
            JinguoduanjuSource.token = '';
          }
          continue;
        }
        throw err;
      }
    }
    throw new Error(JD_AUTH_EXPIRED);
  }

  /** Go client.request：逐线路尝试；授权过期/接口业务失败即停，网络错误换线路 */
  private async jdRequest(method: string, route: string, query: Record<string, string>,
    body: Uint8Array | null, token: string, retryAuth: boolean, limitBytes: number): Promise<Object> {
    const bases: string[] = this.jdCandidates();
    let lastError: Error | null = null;
    for (let i: number = 0; i < bases.length; i++) {
      try {
        const decoded: Object = await this.jdRequestBase(
          bases[i], method, route, query, body, token, retryAuth, limitBytes);
        this.jdRememberBase(bases[i]);
        return decoded;
      } catch (error) {
        const err: Error = error as Error;
        if (err.message === JD_AUTH_EXPIRED || err.message.startsWith(JD_STATUS_PREFIX) ||
          RE_JD_STATUS_HOST.test(err.message)) {
          throw err;
        }
        lastError = err;
      }
    }
    if (lastError === null) {
      lastError = new Error('禁果短剧线路暂不可用，请稍后重试');
    }
    throw lastError;
  }

  /** Go client.requestBase：单线路请求（UA/Referer/Origin/Bearer + 401/拦截/限额/JSON 校验） */
  private async jdRequestBase(base: string, method: string, route: string, query: Record<string, string>,
    body: Uint8Array | null, token: string, retryAuth: boolean, limitBytes: number): Promise<Object> {
    if (!jdIsHttpUrl(base)) {
      throw new Error('禁果短剧接口地址无效');
    }
    const origin: string = jdOriginOf(base);
    let address: string = `${base.replace(/\/+$/, '')}${route}`;
    if (Object.keys(query).length > 0) {
      address += `?${qgBuildQuery(query)}`;
    }
    const headers: Record<string, string> = {
      'User-Agent': JD_UA,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': `${origin}/`,
      'Origin': origin
    };
    if (body !== null) {
      headers['Content-Type'] = 'application/json';
    }
    if (token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    let resp: QgHttpResponse;
    try {
      resp = await QgHttp.request(address, method, headers, body, JD_TIMEOUT_MS);
    } catch (error) {
      const err: Error = error as Error;
      throw new Error(`禁果短剧连接失败：${err.message}`);
    }
    const bodyText: string = resp.text();
    const blockReason: string = jdBlockReason(resp.headers, bodyText);
    if (retryAuth && token.length > 0 && resp.status === 401 &&
      resp.data.length <= limitBytes && blockReason.length === 0) {
      throw new Error(JD_AUTH_EXPIRED);
    }
    if (resp.status < 200 || resp.status >= 300 || blockReason.length > 0) {
      if (blockReason.length === 0) {
        const message: string = jdErrorMessage(bodyText);
        if (message.length > 0) {
          throw new Error(`${JD_STATUS_PREFIX}${message}`);
        }
      }
      const host: string = jdHostOf(base);
      const reason: string = blockReason.length > 0 ? `：${blockReason}` : '';
      throw new Error(`${host} HTTP ${resp.status}${reason}`);
    }
    if (resp.data.length > limitBytes) {
      throw new Error('禁果短剧返回的数据过大或读取失败');
    }
    const parsed: Object | null = QgJson.parse(bodyText);
    if (parsed === null) {
      throw new Error('禁果短剧返回的数据格式无效');
    }
    return parsed;
  }

  /** Go client.candidates：固定线路优先，默认线路兜底，去重 */
  private jdCandidates(): string[] {
    const raw: string[] = [JinguoduanjuSource.pinnedBase, `${JD_SITE}/api/v1`,
      'https://jgdj.app/api/v1', 'https://play.jinguoduanju.app/api/v1'];
    const bases: string[] = [];
    for (let i: number = 0; i < raw.length; i++) {
      const base: string = raw[i];
      if (base.length === 0 || base === '/api/v1') {
        continue;
      }
      let exists: boolean = false;
      for (let j: number = 0; j < bases.length; j++) {
        if (bases[j] === base) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        bases.push(base);
      }
    }
    return bases;
  }

  /** Go client.rememberBase：记住成功线路与站点 origin */
  private jdRememberBase(base: string): void {
    JinguoduanjuSource.pinnedBase = base;
    const origin: string = jdOriginOf(base);
    if (origin.length > 0) {
      JinguoduanjuSource.siteOrigin = origin;
    }
  }

  /** 设备授权 token：缓存 + 并发合并（Go client.accessToken） */
  private async jdAccessToken(): Promise<string> {
    if (JinguoduanjuSource.token.length > 0) {
      return JinguoduanjuSource.token;
    }
    if (JinguoduanjuSource.authPending !== null) {
      return JinguoduanjuSource.authPending;
    }
    const fetcher: Promise<string> = this.jdAuthorize();
    JinguoduanjuSource.authPending = fetcher;
    try {
      const token: string = await fetcher;
      JinguoduanjuSource.token = token;
      return token;
    } finally {
      JinguoduanjuSource.authPending = null;
    }
  }

  /** Go client.accessToken 授权段：POST /auth/device {deviceId:h5:uuid} → token */
  private async jdAuthorize(): Promise<string> {
    const payload: Record<string, string> = {
      'deviceId': `h5:${this.jdDeviceId()}`,
      'channelCode': '',
      'attributionToken': ''
    };
    const body: Uint8Array = qgUtf8Encode(JSON.stringify(payload));
    const decoded: Object = await this.jdRequest('POST', '/auth/device', {}, body, '', false, 64 * 1024);
    const row: Record<string, Object> | null = QgJson.obj(decoded);
    const token: string = jdMapString(row, ['token']);
    if (token.length === 0 || token.length > 8192 || !RE_JD_TOKEN_CHARS.test(token)) {
      throw new Error('禁果短剧未返回有效的访问授权');
    }
    return token;
  }

  /** 随机 deviceId（UUID v4 形态，会话内固定） */
  private jdDeviceId(): string {
    if (JinguoduanjuSource.deviceId.length > 0) {
      return JinguoduanjuSource.deviceId;
    }
    const raw: Uint8Array = qgRandomBytes(16);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex: string = qgToHex(raw);
    const id: string = `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}`;
    JinguoduanjuSource.deviceId = id;
    return id;
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async jdEnsureCategories(): Promise<void> {
    if (JinguoduanjuSource.categoriesLoaded) {
      return;
    }
    if (JinguoduanjuSource.categoriesPromise === null) {
      JinguoduanjuSource.categoriesPromise = this.jdFetchCategories()
        .then((cats: QgCategory[]): void => {
          JinguoduanjuSource.categoryCache = cats;
          JinguoduanjuSource.categoriesLoaded = true;
          JinguoduanjuSource.categoriesPromise = null;
        })
        .catch((): void => {
          // 分类获取失败不阻塞目录；下次分页请求再试
          JinguoduanjuSource.categoriesPromise = null;
        });
    }
    await JinguoduanjuSource.categoriesPromise;
  }

  /** Go fetchJinguoDuanjuCategories：top-navigation（nav:*）+ filter-config（tag:*） */
  private async jdFetchCategories(): Promise<QgCategory[]> {
    const navigation: Object = await this.jdGet('/top-navigation', {}, 1024 * 1024);
    if (!Array.isArray(navigation)) {
      throw new Error('禁果短剧分类数据格式无效');
    }
    const navRows: Object[] = navigation as Object[];
    if (navRows.length > 200) {
      throw new Error('禁果短剧分类数据格式无效');
    }
    let filters: Object | null = null;
    try {
      filters = await this.jdGet('/filter-config', {}, 1024 * 1024);
    } catch (error) {
      filters = null;
    }
    const categories: QgCategory[] = [new QgCategory(JD_HOME, '推荐'), new QgCategory(JD_HEAT, '热度')];
    const seenIds: Record<string, boolean> = {};
    const seenNames: Record<string, boolean> = {};
    seenIds[JD_HOME] = true;
    seenIds[JD_HEAT] = true;
    seenNames['推荐'] = true;
    seenNames['热度'] = true;
    seenNames['全部'] = true;
    for (let i: number = 0; i < navRows.length; i++) {
      const row: Record<string, Object> | null = QgJson.obj(navRows[i]);
      if (!jdActive(row, 'active') || !jdActive(row, 'valid') ||
        jdMapString(row, ['targetType']).toLowerCase() === 'system') {
        continue;
      }
      const id: string = jdMapString(row, ['id']);
      if (!RE_JD_ID.test(id)) {
        continue;
      }
      jdAddCategory(`nav:${id}`, jdMapString(row, ['frontendName']), categories, seenIds, seenNames);
    }
    if (filters !== null && Array.isArray(filters)) {
      const groups: Object[] = filters as Object[];
      if (groups.length > 80) {
        throw new Error('禁果短剧分类数据格式无效');
      }
      for (let g: number = 0; g < groups.length; g++) {
        const group: Record<string, Object> | null = QgJson.obj(groups[g]);
        if (!jdActive(group, 'active') || !jdActive(group, 'frontendVisible')) {
          continue;
        }
        const tags: Object[] = group !== null ? QgJson.fieldArr(group, 'tags') : [];
        if (tags.length > 300) {
          throw new Error('禁果短剧分类条目过多');
        }
        for (let t: number = 0; t < tags.length; t++) {
          const tag: Record<string, Object> | null = QgJson.obj(tags[t]);
          if (!jdActive(tag, 'active') || !jdActive(tag, 'frontendVisible')) {
            continue;
          }
          const id: string = jdMapString(tag, ['id']);
          if (!RE_JD_ID.test(id)) {
            continue;
          }
          jdAddCategory(`tag:${id}`, jdMapString(tag, ['name']), categories, seenIds, seenNames);
        }
      }
    }
    return categories;
  }
}
