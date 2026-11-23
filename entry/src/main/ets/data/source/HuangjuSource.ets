/**
 * 剧果站源（站点 https://huangju.net，接口 https://api.huangju.net）。
 * 访客会话：随机 deviceId 换取 Bearer token（401/403 自动刷新重试一次）；
 * 接口响应 {data:...} 且无 id/items/url 字段时自动解包；
 * 播放凭证：/play 响应 Set-Cookie 中的 CloudFront-Policy/Signature/Key-Pair-Id
 * 三件套签名 Cookie，随播放头注入。
 * 移植自 guoapp provider_huangju.go + provider_huangju_client.go（目录/搜索/详情/播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBuildQuery, qgRandomBytes, qgToHex, qgUtf8Encode } from '../QgBytes';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

/** 站点地址（封面/Referer/Origin 基准） */
const HJ_SITE: string = 'https://huangju.net';
/** 接口地址（Go HuangjuAPIURL 默认值） */
const HJ_API_BASE: string = 'https://api.huangju.net';
/** 接口 UA（Go huangjuUserAgent） */
const HJ_UA: string = 'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36';
/** 封面请求 UA（Go config_defaults.go userAgent） */
const HJ_COVER_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 「最新」特殊分类 ID（Go huangjuNewestCategory） */
const HJ_NEWEST: string = '@new';
const HJ_TIMEOUT_MS: number = 15000;

const RE_HJ_INT: RegExp = /^[+-]?[0-9]+$/;
const RE_HJ_ID_FORBIDDEN: RegExp = /[/\\:?#%|"<>]/;
const RE_HJ_CONTROL: RegExp = /[\x00-\x1f\x7f-\u009f]/;
const RE_HJ_CAT_FORBIDDEN: RegExp = /[|/\\\x00\r\n]/;
const RE_HJ_TOKEN_CHARS: RegExp = /^[\x21-\x7e]+$/;
const RE_HJ_COOKIE: RegExp = /(?:^|[,;\s])CloudFront-(Policy|Signature|Key-Pair-Id)\s*=\s*([^;,\s"']+)/g;
const RE_HJ_COOKIE_BAD: RegExp = /[,;"\\]/;

/** hjGet 结果：解包后的 payload + 响应头（播放凭证需要 Set-Cookie） */
class HjCallResult {
  payload: Object | null = null;
  headers: Record<string, string> = {};
}

/** 值是否为 null/undefined（对应 Go 的 nil 判断） */
function hjNil(value: Object | undefined): boolean {
  return value === undefined || value === null;
}

/** Go nativeText 子集：字符串 trim / 数字取整转字符串 */
function hjText(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value.trim();
  }
  if (typeof value === 'number') {
    return `${Math.trunc(value)}`;
  }
  return '';
}

/** Go huangjuInteger：解析 0..maximum 整数，失败返回 -1 */
function hjInteger(value: Object | undefined, maximum: number): number {
  const text: string = hjText(value);
  if (!RE_HJ_INT.test(text)) {
    return -1;
  }
  const parsed: number = Number(text);
  if (parsed < 0 || parsed > maximum) {
    return -1;
  }
  return parsed;
}

/** Go validHuangjuID */
function hjValidID(value: string): boolean {
  if (value.length === 0 || value.length > 450) {
    return false;
  }
  if (value.trim() !== value) {
    return false;
  }
  if (value === '.' || value === '..') {
    return false;
  }
  return !RE_HJ_ID_FORBIDDEN.test(value) && !RE_HJ_CONTROL.test(value);
}

/** Go validNativeCategory(huangju)：空串 / @new / 普通合法 ID（不带 @ 前缀） */
function hjValidCategory(category: string): boolean {
  if (category.length === 0) {
    return true;
  }
  if (category.length > 128 || RE_HJ_CAT_FORBIDDEN.test(category)) {
    return false;
  }
  if (category === HJ_NEWEST) {
    return true;
  }
  return hjValidID(category) && !category.startsWith('@');
}

/** Go mapString：依次取第一个非空字符串字段（自动 trim） */
function hjMapString(row: Record<string, Object> | null, keys: string[]): string {
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

/** 严格字符串读取（对应 Go 的 `row["x"].(string)`，非字符串返回空） */
function hjStrictString(value: Object | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** Go truncate：超长截断加省略号（按码点计数） */
function hjTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function hjIsHttpUrl(raw: string): boolean {
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
function hjResolveReference(pageURL: string, ref: string): string {
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
function hjCoverAddress(value: Object | undefined, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = hjCoverAddress(items[i], pageURL);
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
    const resolved: string = hjResolveReference(pageURL, text);
    return hjIsHttpUrl(resolved) ? resolved : '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = hjCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** 单个分类名收拢（Go huangjuCategoryNames 的 add 闭包） */
function hjAddCategoryName(value: Object | undefined, seen: Record<string, boolean>, out: string[]): void {
  let name: string = '';
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    name = hjMapString(map, ['name']);
  } else if (typeof value === 'string') {
    name = value;
  }
  name = name.trim();
  if (name.length > 0 && Array.from(name).length <= 48 &&
    seen[name] !== true && out.length < 24) {
    seen[name] = true;
    out.push(name);
  }
}

/** Go huangjuCategoryNames：category + categories → 去重分类名列表 */
function hjCategoryNames(row: Record<string, Object> | null): string[] {
  const names: string[] = [];
  const seen: Record<string, boolean> = {};
  hjAddCategoryName(row !== null ? row['category'] : undefined, seen, names);
  const entries: Object[] = row !== null ? QgJson.fieldArr(row, 'categories') : [];
  for (let i: number = 0; i < entries.length; i++) {
    hjAddCategoryName(entries[i], seen, names);
  }
  return names;
}

/** Go huangjuPayload：{data:...} 且无 id/items/url 字段时解包 data */
function hjPayload(value: Object): Object {
  const row: Record<string, Object> | null = QgJson.obj(value);
  if (row !== null && !hjNil(row['data']) && hjNil(row['id']) &&
    hjNil(row['items']) && hjNil(row['url'])) {
    return row['data'];
  }
  return value;
}

/** Go huangjuExpiration：秒/毫秒时间戳或 RFC3339 字符串 → 毫秒（0 未知） */
function hjExpiration(value: Object | undefined): number {
  const text: string = hjText(value);
  if (text.length > 0 && RE_HJ_INT.test(text)) {
    const stamp: number = Number(text);
    if (stamp > 0 && stamp <= 253402300799000) {
      return stamp > 100000000000 ? stamp : stamp * 1000;
    }
    return 0;
  }
  const parsed: number = Date.parse(text);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/**
 * Go huangjuMediaCredentials：从 Set-Cookie 提取 CloudFront 三件套签名 Cookie。
 * 校验完整性/字符合法性/有效期与播放地址，返回拼好的 Cookie 头。
 */
function hjMediaCredentials(headers: Record<string, string>, address: string,
  expiresAt: Object | undefined): string {
  const rawCookie: string = headers['set-cookie'] !== undefined ? headers['set-cookie'] : '';
  const cookies: Record<string, string> = {};
  RE_HJ_COOKIE.lastIndex = 0;
  let match: RegExpExecArray | null = RE_HJ_COOKIE.exec(rawCookie);
  let count: number = 0;
  while (match !== null && count < 12) {
    cookies[`CloudFront-${match[1]}`] = match[2];
    count++;
    match = RE_HJ_COOKIE.exec(rawCookie);
  }
  const parts: string[] = [];
  const names: string[] = ['CloudFront-Policy', 'CloudFront-Signature', 'CloudFront-Key-Pair-Id'];
  for (let i: number = 0; i < names.length; i++) {
    const value: string = cookies[names[i]] !== undefined ? cookies[names[i]] : '';
    if (value.length === 0 || value.length > 8192 ||
      RE_HJ_COOKIE_BAD.test(value) || !RE_HJ_TOKEN_CHARS.test(value)) {
      throw new Error('剧果未返回完整的媒体凭证，请重试');
    }
    parts.push(`${names[i]}=${value}`);
  }
  const expires: number = hjExpiration(expiresAt);
  if (expires !== 0 && Date.now() >= expires) {
    throw new Error('剧果媒体凭证已过期，请检查设备时间后重试');
  }
  if (!hjIsHttpUrl(address)) {
    throw new Error('剧果播放地址无效');
  }
  return parts.join('; ');
}

/** Go huangjuDramaFromMap：行记录 → QgDrama（资料不完整抛错） */
function hjDramaFromMap(row: Record<string, Object> | null, sourceID: string): QgDrama {
  const id: string = hjMapString(row, ['id']);
  const slug: string = hjMapString(row, ['slug']);
  const title: string = hjStrictString(row !== null ? row['title'] : undefined);
  if (row === null || !hjValidID(id) || title.trim().length === 0) {
    throw new Error('剧果返回的剧集信息不完整');
  }
  if (sourceID.length === 0) {
    if (!hjValidID(slug)) {
      throw new Error('剧果返回的剧集地址无效');
    }
    sourceID = `${slug}-${id}`;
  }
  if (!hjValidID(sourceID) || !sourceID.endsWith(`-${id}`)) {
    throw new Error('剧果详情与请求剧集不符');
  }
  let episodes: number = 0;
  if (!hjNil(row['totalEpisodes'])) {
    episodes = hjInteger(row['totalEpisodes'], 100000);
    if (episodes < 0) {
      throw new Error('剧果集数格式无效');
    }
  }
  const categories: string[] = hjCategoryNames(row);
  const category: string = categories.length > 0 ? categories[0] : '短剧';
  const tags: string[] = categories.slice();
  const region: string = hjMapString(row, ['region']);
  if (region.length > 0) {
    tags.push(hjTruncate(region, 48));
  }
  const year: number = hjInteger(row['year'], 9999);
  if (year >= 1000) {
    tags.push(`${year}年`);
  }
  let status: string = hjMapString(row, ['status']);
  if (status === 'completed') {
    status = 'finished';
  }
  if (status !== 'finished' && status !== 'ongoing') {
    status = '';
  }
  const description: string = hjStrictString(row['description']);
  const cover: string = hjCoverAddress(row['coverUrl'], `${HJ_SITE}/`);
  const drama: QgDrama = new QgDrama(`huangju:${sourceID}`, hjTruncate(title, 256), category);
  drama.sourceId = 'huangju';
  drama.intro = hjTruncate(description, 12000);
  drama.cover = cover;
  drama.episodeCount = episodes;
  drama.finished = status !== 'ongoing';
  drama.tags = tags;
  drama.viewsText = hjMapString(row, ['views']);
  drama.heat = QgJson.num(row['heat']);
  drama.remark = hjTruncate(hjMapString(row, ['badge']), 128);
  return drama;
}

/** 统一接口请求（Go huangjuAPIClient.request）：注入 UA/Referer/Origin/Bearer */
async function hjRequest(method: string, route: string, query: Record<string, string>,
  body: Uint8Array | null, token: string, limitBytes: number): Promise<QgHttpResponse> {
  let address: string = `${HJ_API_BASE}${route}`;
  if (Object.keys(query).length > 0) {
    address += `?${qgBuildQuery(query)}`;
  }
  const headers: Record<string, string> = {
    'User-Agent': HJ_UA,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': `${HJ_SITE}/`,
    'Origin': HJ_SITE
  };
  if (body !== null) {
    headers['Content-Type'] = 'application/json';
  }
  if (token.length > 0) {
    headers['Authorization'] = `Bearer ${token}`;
  }
  const resp: QgHttpResponse = await QgHttp.request(address, method, headers, body, HJ_TIMEOUT_MS, 0, 30, 'huangju');
  if (resp.data.length > limitBytes) {
    throw new Error('剧果返回的数据过大或读取失败');
  }
  return resp;
}

export class HuangjuSource extends QgSource {
  /** 访客 Bearer token（会话内缓存） */
  private static token: string = '';
  /** 进行中的取 token 请求（并发合并，Go huangjuGuestCall pending） */
  private static tokenPromise: Promise<string> | null = null;
  /** 随机设备标识（UUID v4 形态） */
  private static deviceId: string = '';
  /** 分类缓存（categories() 为同步签名，首次目录/搜索请求时异步填充） */
  private static categoryCache: QgCategory[] = [];
  /** 进行中的分类请求（并发合并） */
  private static categoriesPromise: Promise<void> | null = null;

  constructor() {
    super('huangju', '剧果');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < HuangjuSource.categoryCache.length; i++) {
      all.push(HuangjuSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.hjCatalogPage(categoryId.trim(), '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.hjCatalogPage('', keyword.trim(), page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceID: string = (dramaId.startsWith('huangju:') ?
      dramaId.substring('huangju:'.length) : dramaId).trim();
    if (!hjValidID(sourceID)) {
      throw new Error('剧果剧集地址无效');
    }
    const result: HjCallResult = await this.hjGet(`/dramas/${encodeURIComponent(sourceID)}`, {},
      8 * 1024 * 1024);
    const row: Record<string, Object> | null = QgJson.obj(result.payload);
    const drama: QgDrama = hjDramaFromMap(row, sourceID);
    const rawEpisodes: Object | undefined = row !== null ? row['episodes'] : undefined;
    if (hjNil(rawEpisodes) || !Array.isArray(rawEpisodes) || (rawEpisodes as Object[]).length > 10000) {
      throw new Error('剧果分集目录格式无效');
    }
    const rows: Object[] = rawEpisodes as Object[];
    const episodes: QgEpisode[] = [];
    const seenIds: Record<string, boolean> = {};
    const seenNumbers: Record<string, boolean> = {};
    for (let index: number = 0; index < rows.length; index++) {
      const episode: Record<string, Object> | null = QgJson.obj(rows[index]);
      if (episode !== null && episode['playable'] === false) {
        continue;
      }
      const id: string = hjMapString(episode, ['id']);
      if (!hjValidID(id) || seenIds[id] === true) {
        throw new Error('剧果分集目录包含无效或重复分集');
      }
      let number: number = index + 1;
      if (episode !== null && !hjNil(episode['epNo'])) {
        const parsedNo: number = hjInteger(episode['epNo'], 100000);
        if (parsedNo < 0) {
          throw new Error('剧果分集编号无效');
        }
        if (parsedNo !== 0) {
          number = parsedNo;
        }
      }
      if (seenNumbers[`${number}`] === true) {
        throw new Error('剧果分集编号重复，请刷新目录');
      }
      seenIds[id] = true;
      seenNumbers[`${number}`] = true;
      episodes.push(new QgEpisode(id, `第 ${number} 集`, number));
    }
    if (episodes.length === 0) {
      throw new Error('剧果该剧暂时没有可播放的分集');
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    drama.episodeCount = Math.max(episodes.length, drama.episodeCount);
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceID: string = (dramaId.startsWith('huangju:') ?
      dramaId.substring('huangju:'.length) : dramaId).trim();
    const id: string = episodeId.trim();
    if (!hjValidID(sourceID) || !hjValidID(id)) {
      throw new Error('剧果播放分集信息无效，请刷新详情');
    }
    const result: HjCallResult = await this.hjGet(`/play/${encodeURIComponent(id)}`, {}, 64 * 1024);
    const row: Record<string, Object> | null = QgJson.obj(result.payload);
    const address: string = row !== null ? hjStrictString(row['url']) : '';
    const cookie: string = hjMediaCredentials(result.headers, address,
      row !== null ? row['expiresAt'] : undefined);
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${HJ_SITE}/`;
    info.headers = {
      'User-Agent': HJ_UA,
      'Referer': info.referer,
      'Origin': HJ_SITE,
      'Cookie': cookie
    };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': HJ_COVER_UA, 'Referer': `${HJ_SITE}/` };
  }

  /** 目录/搜索共用的分页取数（Go fetchHuangjuCatalogPage） */
  private async hjCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000 || query.length > 1024 || !hjValidCategory(category)) {
      throw new Error('剧果目录查询参数无效');
    }
    await this.hjEnsureCategories();
    const values: Record<string, string> = { 'page': `${page}` };
    if (query.length > 0) {
      values['q'] = query;
    } else if (category === HJ_NEWEST) {
      values['sort'] = 'new';
    } else if (category.length === 0) {
      values['sort'] = 'hot';
    } else {
      values['category'] = category;
    }
    const result: HjCallResult = await this.hjGet('/dramas', values, 4 * 1024 * 1024);
    const row: Record<string, Object> | null = QgJson.obj(result.payload);
    const rows: Object[] = row !== null ? QgJson.fieldArr(row, 'items') : [];
    if (row === null || rows.length > 500) {
      throw new Error('剧果目录数据格式无效');
    }
    let pageSize: number = 20;
    if (!hjNil(row['pageSize'])) {
      pageSize = hjInteger(row['pageSize'], 500);
      if (pageSize < 1) {
        throw new Error('剧果分页数据格式无效');
      }
    }
    if (!hjNil(row['page'])) {
      const actualPage: number = hjInteger(row['page'], 1000000);
      if (actualPage !== page) {
        throw new Error('剧果返回的页码与请求不符');
      }
    }
    if (rows.length > pageSize) {
      throw new Error('剧果分页数据格式无效');
    }
    let hasMore: boolean = rows.length >= pageSize;
    if (!hjNil(row['total'])) {
      const total: number = hjInteger(row['total'], 100000000);
      if (total < rows.length) {
        throw new Error('剧果分页总数无效');
      }
      hasMore = page < Math.ceil(total / pageSize);
    }
    if (hasMore && rows.length === 0) {
      throw new Error('剧果未返回应有的目录页，请重试');
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama = hjDramaFromMap(QgJson.obj(rows[i]), '');
      if (seen[drama.id] === true) {
        throw new Error('剧果目录包含重复剧集，请重试');
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return new QgPageResult(items, hasMore);
  }

  /** Go huangjuClient.get：带访客 token 的 GET，401/403 且 JSON 响应时刷新 token 重试一次 */
  private async hjGet(route: string, query: Record<string, string>,
    limitBytes: number): Promise<HjCallResult> {
    const token: string = await this.hjGuestToken();
    let resp: QgHttpResponse = await hjRequest('GET', route, query, null, token, limitBytes);
    if ((resp.status === 401 || resp.status === 403) && QgJson.parse(resp.text()) !== null) {
      if (HuangjuSource.token === token) {
        HuangjuSource.token = '';
      }
      const fresh: string = await this.hjGuestToken();
      resp = await hjRequest('GET', route, query, null, fresh, limitBytes);
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`剧果接口请求失败（HTTP ${resp.status}）`);
    }
    const parsed: Object | null = QgJson.parse(resp.text());
    if (parsed === null) {
      throw new Error('剧果返回的数据格式无效');
    }
    const result: HjCallResult = new HjCallResult();
    result.payload = hjPayload(parsed);
    result.headers = resp.headers;
    return result;
  }

  /** 访客 token：缓存 + 并发合并（Go guestToken） */
  private async hjGuestToken(): Promise<string> {
    if (HuangjuSource.token.length > 0) {
      return HuangjuSource.token;
    }
    if (HuangjuSource.tokenPromise !== null) {
      return HuangjuSource.tokenPromise;
    }
    const fetcher: Promise<string> = this.hjFetchGuestToken();
    HuangjuSource.tokenPromise = fetcher;
    try {
      const token: string = await fetcher;
      HuangjuSource.token = token;
      return token;
    } finally {
      HuangjuSource.tokenPromise = null;
    }
  }

  /** Go guestToken：POST /auth/guest {deviceId} → token（或 data.token） */
  private async hjFetchGuestToken(): Promise<string> {
    const payload: Record<string, string> = { 'deviceId': this.hjDeviceId() };
    const body: Uint8Array = qgUtf8Encode(JSON.stringify(payload));
    const resp: QgHttpResponse = await hjRequest('POST', '/auth/guest', {}, body, '', 64 * 1024);
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`剧果访客授权失败（HTTP ${resp.status}）`);
    }
    const parsed: Object | null = QgJson.parse(resp.text());
    if (parsed === null) {
      throw new Error('剧果返回的数据格式无效');
    }
    const row: Record<string, Object> | null = QgJson.obj(parsed);
    let token: string = row !== null ? hjStrictString(row['token']) : '';
    if (token.length === 0 && row !== null) {
      const data: Record<string, Object> | null = QgJson.obj(row['data']);
      token = data !== null ? hjStrictString(data['token']) : '';
    }
    if (token.length === 0 || token.length > 8192 || !RE_HJ_TOKEN_CHARS.test(token)) {
      throw new Error('剧果未返回有效的访客授权');
    }
    return token;
  }

  /** 随机 deviceId（UUID v4 形态，会话内固定） */
  private hjDeviceId(): string {
    if (HuangjuSource.deviceId.length > 0) {
      return HuangjuSource.deviceId;
    }
    const raw: Uint8Array = qgRandomBytes(16);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex: string = qgToHex(raw);
    const id: string = `${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}`;
    HuangjuSource.deviceId = id;
    return id;
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async hjEnsureCategories(): Promise<void> {
    if (HuangjuSource.categoryCache.length > 0) {
      return;
    }
    if (HuangjuSource.categoriesPromise === null) {
      HuangjuSource.categoriesPromise = this.hjFetchCategories()
        .then((cats: QgCategory[]): void => {
          HuangjuSource.categoryCache = cats;
          HuangjuSource.categoriesPromise = null;
        })
        .catch((): void => {
          // 分类获取失败不阻塞目录；下次分页请求再试
          HuangjuSource.categoriesPromise = null;
        });
    }
    await HuangjuSource.categoriesPromise;
  }

  /** Go fetchHuangjuCategories：/categories → [最新, slug 分类...]（跳过 hot） */
  private async hjFetchCategories(): Promise<QgCategory[]> {
    const result: HjCallResult = await this.hjGet('/categories', {}, 256 * 1024);
    if (!Array.isArray(result.payload) || (result.payload as Object[]).length > 300) {
      throw new Error('剧果分类数据格式无效');
    }
    const rows: Object[] = result.payload as Object[];
    const categories: QgCategory[] = [new QgCategory(HJ_NEWEST, '最新')];
    const seen: Record<string, boolean> = {};
    seen[HJ_NEWEST] = true;
    for (let i: number = 0; i < rows.length; i++) {
      const row: Record<string, Object> | null = QgJson.obj(rows[i]);
      const id: string = hjMapString(row, ['slug']);
      const name: string = hjMapString(row, ['name']);
      if (id === 'hot') {
        continue;
      }
      if (!hjValidCategory(id) || id.length === 0 || name.length === 0 ||
        Array.from(name).length > 48 || seen[id] === true) {
        throw new Error('剧果分类数据包含无效或重复条目');
      }
      seen[id] = true;
      categories.push(new QgCategory(id, name));
    }
    return categories;
  }
}
