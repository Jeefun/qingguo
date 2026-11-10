/**
 * 禁果站源（双域名：cloudfront 主线 + rlkfus 备线，成功线路会话内记忆）。
 * 请求参数 AES-128-CBC（key=IV=BxJand%xf5h3sycH）加密为 base64 放入 data（GET 查询 / POST JSON 体）；
 * 响应 envelope.hash 开启时 data 为 base64 密文，用 InterfaceKey 派生 AES-256 密钥解密。
 * 访客会话：POST /api/app/mine/login/h5（devID）换 token，5005 失效自动重登一次。
 * 移植自 guoapp provider_jinguo.go / provider_jinguo_client.go（目录、搜索、详情、播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBase64Decode, qgBase64Encode, qgConcat, qgRandomHex, qgUtf8Decode, qgUtf8Encode } from '../QgBytes';
import { qgAesCbcDecrypt, qgAesCbcEncrypt, qgSha256 } from '../QgCrypto';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

/** API 域名池（Go jinguoAPIHosts，主备双线） */
const JG_API_HOSTS: string[] = ['https://d1wyuxwdrlykj1.cloudfront.net', 'https://hghts.rlkfus.cn'];
/** 响应 data 解密密钥种子（Go jinguoProtocol.InterfaceKey） */
const JG_INTERFACE_KEY: string = '65dc07d1b7915c6b2937432b091837a7';
/** 请求参数加密 key / IV（Go jinguoProtocol.ParamKey / ParamIV，utf8 恰 16 字节） */
const JG_PARAM_KEY: string = 'BxJand%xf5h3sycH';
const JG_PARAM_IV: string = 'BxJand%xf5h3sycH';
const JG_PARAM_KEY_BYTES: Uint8Array = qgUtf8Encode(JG_PARAM_KEY);
const JG_PARAM_IV_BYTES: Uint8Array = qgUtf8Encode(JG_PARAM_IV);
/** 全局 UA（Go userAgent，iPhone Safari） */
const JG_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 禁果 App 身份头模板（Go jinguoXUserAgent，%s 为设备 ID） */
const JG_X_USER_AGENT: string = 'BuildID=com.hgaidj.ozThree;SysType=android;DevID=%s;Ver=1.0.8;DevType=Android;DeviceBrand=google;DeviceModel=Pixel;SystemName=Android;SystemVersion=14;Terminal=1;IsH5=1;Sid=00000000000000000000000000000';
/** 目录分页大小（Go defaultConfig.PageSize） */
const JG_PAGE_SIZE: number = 30;
/** 接口超时（Go providerTimeout 12s） */
const JG_TIMEOUT_MS: number = 12000;
/** 媒体请求超时（Go http client 45s） */
const JG_MEDIA_TIMEOUT_MS: number = 45000;
/** 接口响应体上限（Go providerMaxBodyBytes 20MB） */
const JG_MAX_BODY_BYTES: number = 20 * 1024 * 1024;
/** 播放列表大小上限（Go fetchMediaPlaylist 4MB） */
const JG_PLAYLIST_MAX_BYTES: number = 4 * 1024 * 1024;
/** 分类前缀（Go jinguoChooseCategory / jinguoNewCategory / jinguoTabPrefix） */
const JG_CHOOSE: string = 'choose';
const JG_NEW: string = 'new';
const JG_TAB_PREFIX: string = 'tab:';
/** 站内剧集/分类 ID 格式（Go jinguoID） */
const RE_ID: RegExp = /^[A-Za-z0-9]{1,64}$/;
/** 集数正则（Go reEpisodeNumber） */
const RE_EPISODE: RegExp = /(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))/i;
/** 完结状态判定（Go finishedEpisodeRemark） */
const RE_FINISHED_REMARK: RegExp = /(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/;
/** 封面候选字段（Go jinguoDrama covers 列表） */
const JG_COVER_KEYS: string[] = ['cover', 'coverUrl', 'cover_url', 'image', 'imageUrl', 'image_url',
  'img', 'pic', 'picture', 'poster', 'thumb', 'thumbnail'];
/** 集数候选字段（Go nativeNormalize episodes 列表） */
const JG_COUNT_KEYS: string[] = ['totalEpisode', 'total_episode', 'episodeCount', 'episode_count',
  'chapterCount', 'chapter_count', 'total', 'episodes'];

/** 禁果接口业务错误（code != 200），不切换域名（Go jinguoAPIError） */
class JgApiError extends Error {
  code: string = '';

  constructor(code: string, message: string) {
    super(`禁果接口返回错误 ${code}：${message}`);
    this.code = code;
  }
}

/** 线路级错误（连接失败 / 5xx / 响应过大），切换下一个域名重试（Go jinguoLineError） */
class JgLineError extends Error {
}

/** 分类标签（Go Tab） */
class JgTab {
  id: string = '';
  name: string = '';
}

/** 分集中间结构（fetchJinguoDetail 的 Chapter 加工结果） */
class JgChapter {
  /** 去重键：row.id 或序号（Go providerChapterID 的本地部分） */
  key: string = '';
  title: string = '';
  /** 原始相对播放地址（row.videoUrl），VIP 集为空串 */
  videoURL: string = '';
  /** 金币/会员锁定集 */
  vip: boolean = false;
  /** 排序集数（chapterEpisodeNumber 结果） */
  sortNumber: number = 0;
}

/** 播放列表抓取结果（fetchMediaPlaylist） */
class JgPlaylistResult {
  text: string = '';
  url: string = '';
}

/** 手写 URL 解析结果（项目无内置 URL API，按 Go url.Parse 所需子集实现） */
class JgURLInfo {
  scheme: string = '';
  host: string = '';
  path: string = '';
  query: string = '';
  /** 是否携带 scheme（Go IsAbs） */
  isAbs: boolean = false;
  /** authority 是否含 userinfo */
  hasUser: boolean = false;

  hostname(): string {
    const colon: number = this.host.indexOf(':');
    return colon >= 0 ? this.host.substring(0, colon) : this.host;
  }
}

/** Go firstNonEmpty：第一个 trim 后非空的值（返回 trim 结果） */
function jgFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Go truncate：trim 后按码点截断加省略号 */
function jgTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go validLegacyToken：长度 ≤4096 且不含空白字符 */
function jgValidToken(token: string): boolean {
  return token.length <= 4096 && !/[\r\n\t ]/.test(token);
}

/** Go mapString：依次取第一个非空字符串字段（string/bool/number，自动 trim） */
function jgMapString(row: Record<string, Object> | null, keys: string[]): string {
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

/** mapStringSlice 的去重追加 */
function jgAddSlicePart(part: string, seen: Record<string, boolean>, out: string[]): void {
  const value: string = part.trim();
  if (value.length > 0 && seen[value] !== true) {
    seen[value] = true;
    out.push(value);
  }
}

/** Go mapStringSlice：字符串按 ,/，、 切分，数组取 name/title/label/tag 或元素文本 */
function jgMapStringSlice(row: Record<string, Object> | null, keys: string[]): string[] {
  const seen: Record<string, boolean> = {};
  const out: string[] = [];
  if (row === null) {
    return out;
  }
  for (let k: number = 0; k < keys.length; k++) {
    const value: Object | undefined = row[keys[k]];
    if (value === undefined || value === null) {
      continue;
    }
    if (typeof value === 'string') {
      const parts: string[] = value.split(/[,/，、]/);
      for (let i: number = 0; i < parts.length; i++) {
        jgAddSlicePart(parts[i], seen, out);
      }
    } else if (Array.isArray(value)) {
      const items: Object[] = value as Object[];
      for (let i: number = 0; i < items.length; i++) {
        const entry: Record<string, Object> | null = QgJson.obj(items[i]);
        if (entry !== null) {
          jgAddSlicePart(jgMapString(entry, ['name', 'title', 'label', 'tag']), seen, out);
          continue;
        }
        jgAddSlicePart(QgJson.str(items[i]), seen, out);
      }
    }
  }
  return out;
}

/** Go episodeIndex：从文案中提取集数（第X集/共X集/epX），失败返回 fallback */
function jgEpisodeIndex(s: string, fallback: number): number {
  const m: RegExpExecArray | null = RE_EPISODE.exec(s);
  if (m !== null) {
    for (let g: number = 1; g < m.length; g++) {
      if (!m[g]) {
        continue;
      }
      const n: number = Number(m[g]);
      if (!Number.isNaN(n) && n > 0) {
        return n;
      }
    }
  }
  return fallback;
}

/** Go chapterEpisodeNumber：currentEpisode（数字>0）→ 文案提取 → 标题提取 → fallback */
function jgChapterEpisodeNumber(currentEpisode: Object | undefined, title: string, fallback: number): number {
  if (currentEpisode !== undefined && currentEpisode !== null) {
    if (typeof currentEpisode === 'number' && Number.isInteger(currentEpisode) && currentEpisode > 0) {
      return currentEpisode;
    }
    if (typeof currentEpisode === 'string') {
      return jgEpisodeIndex(currentEpisode, fallback);
    }
  }
  return jgEpisodeIndex(title, fallback);
}

/** Go Chapter.EpisodeString：currentEpisode 转展示文案，失败返回 fallback 数字串 */
function jgEpisodeString(currentEpisode: Object | undefined, fallback: number): string {
  if (currentEpisode !== undefined && currentEpisode !== null) {
    if (typeof currentEpisode === 'string' && currentEpisode.trim().length > 0) {
      return currentEpisode.trim();
    }
    if (typeof currentEpisode === 'number' && currentEpisode > 0) {
      return `${Math.trunc(currentEpisode)}`;
    }
  }
  return `${fallback}`;
}

/** Go releaseStatusFromRemark：remark 推断连载状态 */
function jgReleaseStatusFromRemark(remark: string): string {
  if (remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载')) {
    return 'ongoing';
  }
  if (RE_FINISHED_REMARK.test(remark) || remark.includes('完结')) {
    return 'finished';
  }
  return 'unknown';
}

/** 手写 URL 解析（Go url.Parse 所需子集：fragment → scheme → query → authority/path） */
function jgParseURL(raw: string): JgURLInfo | null {
  if (/[\x00-\x1f\x7f]/.test(raw) || raw.includes(' ') || /%(?![0-9a-fA-F]{2})/.test(raw)) {
    return null;
  }
  const info: JgURLInfo = new JgURLInfo();
  let rest: string = raw;
  const hash: number = rest.indexOf('#');
  if (hash >= 0) {
    rest = rest.substring(0, hash);
  }
  const schemeMatch: RegExpExecArray | null = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(rest);
  if (schemeMatch !== null) {
    info.scheme = schemeMatch[1].toLowerCase();
    rest = rest.substring(schemeMatch[0].length);
  }
  const question: number = rest.indexOf('?');
  if (question >= 0) {
    info.query = rest.substring(question + 1);
    rest = rest.substring(0, question);
  }
  if (rest.startsWith('//')) {
    rest = rest.substring(2);
    const slash: number = rest.indexOf('/');
    let authority: string = slash >= 0 ? rest.substring(0, slash) : rest;
    info.path = slash >= 0 ? rest.substring(slash) : '';
    const at: number = authority.lastIndexOf('@');
    if (at >= 0) {
      info.hasUser = true;
      authority = authority.substring(at + 1);
    }
    info.host = authority;
  } else {
    info.path = rest;
  }
  info.isAbs = info.scheme.length > 0;
  return info;
}

/** 查询串取值（Go url.Values.Get：+ 转空格，%XX 解码） */
function jgQueryGet(query: string, key: string): string {
  const pairs: string[] = query.split('&');
  for (let i: number = 0; i < pairs.length; i++) {
    const pair: string = pairs[i];
    const eq: number = pair.indexOf('=');
    const k: string = eq >= 0 ? pair.substring(0, eq) : pair;
    if (k !== key) {
      continue;
    }
    const v: string = eq >= 0 ? pair.substring(eq + 1) : '';
    try {
      return decodeURIComponent(v.replace(/\+/g, ' '));
    } catch (error) {
      return '';
    }
  }
  return '';
}

/** 取 URL hostname（错误信息展示用） */
function jgHostnameOf(address: string): string {
  const parsed: JgURLInfo | null = jgParseURL(address);
  return parsed !== null ? parsed.hostname() : address;
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function jgIsHttpUrl(raw: string): boolean {
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

/** Go coverPathFromAny：字符串/对象/数组递归取封面路径（含 // 补全与 /api/ui/image 解包） */
function jgCoverPathFromAny(value: Object | undefined): string {
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
      const parsed: JgURLInfo | null = jgParseURL(s);
      if (parsed !== null) {
        const raw: string = jgQueryGet(parsed.query, 'url').trim();
        if (raw.length > 0) {
          return raw;
        }
      }
    }
    const absolute: JgURLInfo | null = jgParseURL(s);
    if (absolute !== null && absolute.isAbs) {
      return s;
    }
    return s.replace(/^\/+/, '');
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = jgCoverPathFromAny(items[i]);
      if (address.length > 0) {
        return address;
      }
    }
    return '';
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'src', 'path', 'cover', 'coverUrl', 'cover_url', 'image', 'pic', 'poster'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = jgCoverPathFromAny(map[keys[i]]);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go legacyCoverURL：相对路径补全（upload* → pic.zdmhyg.cn，其余 → zzzznnn.lkkwip.cn） */
function jgLegacyCoverURL(value: Object | undefined): string {
  let address: string = jgCoverPathFromAny(value).trim();
  if (address.length === 0) {
    return '';
  }
  if (address.startsWith('//')) {
    address = `https:${address}`;
  }
  const parsed: JgURLInfo | null = jgParseURL(address);
  if (parsed === null || parsed.hasUser) {
    return '';
  }
  if (parsed.isAbs) {
    if ((parsed.scheme === 'https' || parsed.scheme === 'http') && parsed.hostname().length > 0) {
      return address;
    }
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

/** Go encryptParam：JSON → AES-128-CBC（PKCS7）→ base64 */
function jgEncryptParam(params: Record<string, Object>): string {
  const plain: Uint8Array = qgUtf8Encode(JSON.stringify(params));
  const cipher: Uint8Array = qgAesCbcEncrypt(plain, JG_PARAM_KEY_BYTES, JG_PARAM_IV_BYTES);
  return qgBase64Encode(cipher);
}

/** Go decryptResponse：base64 → salt 派生 AES-256 密钥/IV → CBC 解密（解密失败抛错） */
function jgDecryptResponse(dataStr: string): Uint8Array {
  const o: Uint8Array = qgBase64Decode(dataStr.trim());
  if (o.length < 12) {
    throw new Error('encrypted payload too short');
  }
  const i: Uint8Array = o.slice(0, 12);
  const r: Uint8Array = qgConcat([qgUtf8Encode(JG_INTERFACE_KEY), i]);
  const l: number = r.length >> 1;
  const s: Uint8Array = qgSha256(r).slice(8, 24);
  const c: Uint8Array = qgConcat([s, r.slice(0, l)]);
  const a: Uint8Array = qgConcat([r.slice(l), s]);
  const d: Uint8Array = qgSha256(c);
  const f: Uint8Array = qgSha256(a);
  const m: Uint8Array = qgConcat([d.slice(0, 8), f.slice(8, 24), d.slice(24)]);
  const p: Uint8Array = qgConcat([f.slice(0, 4), d.slice(12, 20), f.slice(28)]);
  const g: Uint8Array = o.slice(12);
  if (g.length % 16 !== 0) {
    throw new Error('ciphertext is not block aligned');
  }
  return qgAesCbcDecrypt(g, m, p);
}

/** Go apiHashEnabled：hash 标志判定（缺省/null → false，字符串按内容判定，其余 true） */
function jgHashEnabled(value: Object | undefined): boolean {
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

/** envelope.code → 文本（数字/字符串皆可，去引号），Go strings.Trim(string(Code), `"`） */
function jgCodeText(envelope: Record<string, Object>): string {
  const code: Object | undefined = envelope['code'];
  if (typeof code === 'string') {
    return code.replace(/^"+/, '').replace(/"+$/, '');
  }
  if (typeof code === 'number') {
    return `${code}`;
  }
  return '';
}

/** Go catalogResponseBlockReason：Cloudflare 拦截页识别（截断 64KB） */
function jgBlockReason(bodyText: string, headers: Record<string, string>): string {
  const limited: string = bodyText.length > 64 * 1024 ? bodyText.substring(0, 64 * 1024) : bodyText;
  const page: string = limited.toLowerCase();
  if (page.includes('cloudflare') &&
    (page.includes('sorry, you have been blocked') || page.includes('you are unable to access'))) {
    return 'Cloudflare 拒绝了当前请求';
  }
  const mitigated: string = headers['cf-mitigated'] !== undefined ? headers['cf-mitigated'].toLowerCase() : '';
  if (mitigated === 'challenge' || page.includes('_cf_chl_opt') ||
    (page.includes('<title>just a moment') && page.includes('cloudflare'))) {
    return '站点要求浏览器验证，当前请求无法通过';
  }
  return '';
}

/** Go jinguoSessionExpired：业务码 5005（会话失效） */
function jgSessionExpired(err: Error): boolean {
  return err instanceof JgApiError && err.code === '5005';
}

/** Go m3u8Duration：累加 #EXTINF 秒数（返回毫秒） */
function jgM3u8DurationMs(raw: string): number {
  let total: number = 0;
  const lines: string[] = raw.split('\n');
  for (let i: number = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (!line.startsWith('#EXTINF:')) {
      continue;
    }
    let value: string = line.substring('#EXTINF:'.length).trim();
    const comma: number = value.indexOf(',');
    if (comma >= 0) {
      value = value.substring(0, comma);
    }
    const seconds: number = Number(value.trim());
    if (Number.isNaN(seconds) || seconds < 0 || !Number.isFinite(seconds)) {
      continue;
    }
    total += seconds * 1000;
  }
  return Math.round(total);
}

/** Go jinguoPlaylistPath：相对播放路径校验 + 逐段转义（空串为非法） */
function jgPlaylistPath(videoURL: string): string {
  const trimmed: string = videoURL.trim().replace(/^\/+/, '').replace(/\/+$/, '');
  if (trimmed.length === 0) {
    return '';
  }
  if (trimmed.includes('?') || trimmed.includes('#') || trimmed.includes('\\') || trimmed.includes('://')) {
    return '';
  }
  const segments: string[] = trimmed.split('/');
  const escaped: string[] = [];
  for (let i: number = 0; i < segments.length; i++) {
    const segment: string = segments[i];
    if (segment.length === 0 || segment === '.' || segment === '..') {
      return '';
    }
    escaped.push(encodeURIComponent(segment));
  }
  return escaped.join('/');
}

/** Go mediaRequestHeaders：媒体请求头（UA/Referer/Accept/Sec-Fetch/Origin） */
function jgMediaHeaders(referer: string): Record<string, string> {
  const headers: Record<string, string> = {
    'User-Agent': JG_UA,
    'Referer': referer,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Dest': 'empty'
  };
  const parsed: JgURLInfo | null = jgParseURL(referer);
  if (parsed !== null && parsed.host.length > 0) {
    headers['Origin'] = `${parsed.scheme}://${parsed.host}`;
  }
  return headers;
}

/** Go nativeNormalize 集数提取：候选字段取最大整数值 */
function jgEpisodeCountOf(row: Record<string, Object>): number {
  let episodes: number = 0;
  for (let i: number = 0; i < JG_COUNT_KEYS.length; i++) {
    const value: Object | undefined = row[JG_COUNT_KEYS[i]];
    let count: number = 0;
    if (typeof value === 'number' && Number.isFinite(value)) {
      count = Math.trunc(value);
    } else if (typeof value === 'string') {
      const text: string = value.trim();
      if (/^[0-9]+$/.test(text)) {
        count = Number(text);
      }
    }
    if (count > episodes) {
      episodes = count;
    }
  }
  return episodes;
}

/** Go validJinguoCategory：'' / choose / new / tab:<合法ID> */
function jgValidCategory(category: string): boolean {
  if (category === '' || category === JG_CHOOSE || category === JG_NEW) {
    return true;
  }
  if (!category.startsWith(JG_TAB_PREFIX)) {
    return false;
  }
  return RE_ID.test(category.substring(JG_TAB_PREFIX.length));
}

/** Go jinguoRow + jinguoDrama + nativeNormalize：行记录 → QgDrama（ID 非法返回 null） */
function jgDramaFromRow(row: Record<string, Object> | null, tabName: string): QgDrama | null {
  if (row === null) {
    return null;
  }
  const sourceID: string = jgMapString(row, ['id']);
  if (!RE_ID.test(sourceID)) {
    return null;
  }
  const title: string = jgFirstNonEmpty([jgMapString(row, ['title']), jgMapString(row, ['name']), '短剧']);
  const genre: string = jgFirstNonEmpty([
    jgMapString(row, ['categoryName', 'category_name', 'typeName', 'type_name', 'sortName', 'sort_name', 'category']),
    tabName
  ]);
  let cover: string = '';
  for (let i: number = 0; i < JG_COVER_KEYS.length; i++) {
    const address: string = jgLegacyCoverURL(row[JG_COVER_KEYS[i]]);
    if (address.length > 0) {
      cover = address;
      break;
    }
  }
  let releaseStatus: string = jgMapString(row, ['releaseStatus', 'release_status']);
  if (releaseStatus.length === 0) {
    releaseStatus = jgReleaseStatusFromRemark(jgMapString(row, ['remark']));
  }
  const heatText: string = jgMapString(row, ['heat']);
  const heat: number = heatText.length > 0 ? Number(heatText) : 0;
  const drama: QgDrama = new QgDrama(`jinguo:${sourceID}`, title, genre);
  drama.sourceId = 'jinguo';
  drama.cover = cover;
  drama.intro = jgFirstNonEmpty([jgMapString(row, ['desc', 'description', 'summary']),
    jgMapString(row, ['intro'])]);
  drama.tags = jgMapStringSlice(row, ['tagNames']);
  drama.viewsText = jgMapString(row, ['views', 'play_count']);
  drama.heat = Number.isNaN(heat) ? 0 : heat;
  drama.episodeCount = jgEpisodeCountOf(row);
  drama.finished = releaseStatus !== 'ongoing';
  drama.remark = jgMapString(row, ['badge']);
  return drama;
}

export class JinguoSource extends QgSource {
  /** 访客设备 ID（随机 hex(8) 大写 + 毫秒时间戳，会话内固定） */
  private static deviceId: string = '';
  /** 访客令牌（会话内存，不做文件持久化，失效自动重登） */
  private static token: string = '';
  /** 上次成功的 API 域名（Go client.base） */
  private static preferredBase: string = '';
  /** 分类缓存（categories() 为同步签名，首次目录/搜索请求时异步填充） */
  private static categoryCache: QgCategory[] = [];
  /** 进行中的登录请求（并发去重） */
  private static loginPending: Promise<string> | null = null;

  constructor() {
    super('jinguo', '禁果');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < JinguoSource.categoryCache.length; i++) {
      all.push(JinguoSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.jgCatalogPage(categoryId, '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.jgCatalogPage('', keyword, page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceID: string = (dramaId.startsWith('jinguo:') ?
      dramaId.substring('jinguo:'.length) : dramaId).trim();
    if (!RE_ID.test(sourceID)) {
      throw new Error('无效的禁果剧集 ID');
    }
    const raw: Object | null = await JinguoSource.jgGet(`/api/app/playlet/detail/${encodeURIComponent(sourceID)}`, null);
    const row: Record<string, Object> | null = QgJson.obj(raw);
    if (row === null) {
      throw new Error('禁果详情数据格式无效');
    }
    const drama: QgDrama | null = jgDramaFromRow(row, '');
    if (drama === null || drama.id !== `jinguo:${sourceID}`) {
      throw new Error('禁果详情与请求剧集不符');
    }
    const chaptersRaw: Object | undefined = row['chapters'];
    if (chaptersRaw !== undefined && chaptersRaw !== null && !Array.isArray(chaptersRaw)) {
      throw new Error('禁果详情数据格式无效');
    }
    let rows: Object[] = QgJson.arr(chaptersRaw);
    if (rows.length === 0) {
      const fallback: Object | null =
        await JinguoSource.jgGet(`/api/app/playlet-chapter/list/${encodeURIComponent(sourceID)}`, null);
      if (fallback !== null && !Array.isArray(fallback)) {
        throw new Error('禁果返回的数据格式无效');
      }
      rows = QgJson.arr(fallback);
    }
    const chapters: JgChapter[] = this.jgBuildChapters(rows, '禁果详情数据格式无效');
    // Go uniqueChapters：按 key 去重
    const unique: JgChapter[] = [];
    const seenKeys: Record<string, boolean> = {};
    for (let i: number = 0; i < chapters.length; i++) {
      if (seenKeys[chapters[i].key] === true) {
        continue;
      }
      seenKeys[chapters[i].key] = true;
      unique.push(chapters[i]);
    }
    // Go sortProviderChapters：稳定排序（集数，key）
    unique.sort((a: JgChapter, b: JgChapter): number => {
      if (a.sortNumber !== b.sortNumber) {
        return a.sortNumber - b.sortNumber;
      }
      if (a.key !== b.key) {
        return a.key < b.key ? -1 : 1;
      }
      return 0;
    });
    const episodes: QgEpisode[] = [];
    for (let i: number = 0; i < unique.length; i++) {
      const ch: JgChapter = unique[i];
      const id: string = ch.vip ? `locked:${ch.key}` : ch.videoURL;
      episodes.push(new QgEpisode(id, ch.title, i + 1));
    }
    if (episodes.length > drama.episodeCount) {
      drama.episodeCount = episodes.length;
    }
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceID: string = (dramaId.startsWith('jinguo:') ?
      dramaId.substring('jinguo:'.length) : dramaId).trim();
    if (!RE_ID.test(sourceID)) {
      throw new Error('无效的禁果剧集 ID');
    }
    const videoURL: string = episodeId;
    if (videoURL.trim().length === 0 || videoURL.startsWith('locked:')) {
      throw new Error('禁果该集需要金币或会员解锁后才能播放');
    }
    const path: string = jgPlaylistPath(videoURL);
    if (path.length === 0) {
      throw new Error('禁果分集播放地址无效');
    }
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const token: string = await JinguoSource.jgCredentials();
      const bases: string[] = JinguoSource.jgBases();
      let lastError: Error | null = null;
      let expired: boolean = false;
      for (let i: number = 0; i < bases.length; i++) {
        const base: string = bases[i];
        const referer: string = `${base}/`;
        const address: string = `${base}/api/app/vid/h5/m3u8/${path}?token=${encodeURIComponent(token)}`;
        try {
          const playlist: JgPlaylistResult = await this.jgFetchPlaylist(address, referer);
          JinguoSource.preferredBase = base;
          const info: QgPlayInfo = new QgPlayInfo();
          info.url = playlist.url;
          info.referer = referer;
          info.headers = jgMediaHeaders(referer);
          info.durationMs = jgM3u8DurationMs(playlist.text);
          return info;
        } catch (error) {
          const err: Error = error as Error;
          lastError = err;
          expired = jgSessionExpired(err);
          if (expired) {
            break;
          }
        }
      }
      if (attempt === 0 && expired) {
        JinguoSource.jgInvalidate(token);
        continue;
      }
      throw lastError !== null ? lastError : new Error('禁果播放信息无效，请刷新详情');
    }
    throw new Error('禁果播放会话已失效，请稍后重试');
  }

  coverHeaders(url: string): Record<string, string> {
    const base: string = JinguoSource.preferredBase.length > 0 ? JinguoSource.preferredBase : JG_API_HOSTS[0];
    return { 'User-Agent': JG_UA, 'Referer': `${base}/` };
  }

  /** Go fetchJinguoCatalogPage：目录/搜索共用分页（搜索走 keyword/search 路由） */
  private async jgCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    const trimmedQuery: string = query.trim();
    if (!jgValidCategory(category) || trimmedQuery.length > 256) {
      throw new Error('禁果目录查询参数无效');
    }
    await this.jgEnsureCategories();
    const params: Record<string, Object> = {
      'pageNumber': `${Math.max(1, Math.trunc(page))}`,
      'pageSize': `${JG_PAGE_SIZE}`
    };
    if (trimmedQuery.length > 0) {
      params['keyword'] = trimmedQuery;
      return this.jgFetchList('/api/app/playlet/keyword/search', params, '');
    }
    if (category === JG_CHOOSE) {
      return this.jgFetchList('/api/app/playlet-recommend/home/choose', params, '');
    }
    if (category === JG_NEW) {
      return this.jgFetchList('/api/app/playlet-recommend/home/new', params, '');
    }
    // '' 合并全部 tab，tab:<id> 选定单个 tab
    const tabs: JgTab[] = await this.jgFetchTabs();
    params['tabSortType'] = '1';
    const selected: string = category.startsWith(JG_TAB_PREFIX) ? category.substring(JG_TAB_PREFIX.length) : '';
    const seen: Record<string, boolean> = {};
    const items: QgDrama[] = [];
    const failures: Error[] = [];
    let hasMore: boolean = false;
    let found: boolean = false;
    for (let i: number = 0; i < tabs.length; i++) {
      const tab: JgTab = tabs[i];
      if (category.length > 0 && tab.id !== selected) {
        continue;
      }
      found = true;
      try {
        const result: QgPageResult =
          await this.jgFetchList(`/api/app/playlet/home/tab/${encodeURIComponent(tab.id)}`, params, tab.name);
        hasMore = hasMore || result.hasMore;
        for (let j: number = 0; j < result.dramas.length; j++) {
          const drama: QgDrama = result.dramas[j];
          if (seen[drama.id] !== true) {
            seen[drama.id] = true;
            items.push(drama);
          }
        }
      } catch (error) {
        failures.push(error as Error);
        hasMore = true;
      }
    }
    if (!found) {
      throw new Error('此分类已调整，请刷新分类列表');
    }
    // Go errors.Join：仍有结果时忽略单 tab 失败，全部失败时抛首个错误
    if (failures.length > 0 && items.length === 0) {
      throw failures[0];
    }
    return new QgPageResult(items, hasMore);
  }

  /** Go fetchJinguoList：单路由取列表并转 QgDrama */
  private async jgFetchList(route: string, params: Record<string, Object>, tabName: string): Promise<QgPageResult> {
    const payload: Object | null = await JinguoSource.jgGet(route, params);
    const map: Record<string, Object> | null = QgJson.obj(payload);
    if (payload !== null && map === null) {
      throw new Error('禁果返回的数据格式无效');
    }
    const rows: Object[] = map !== null ? QgJson.fieldArr(map, 'list') : [];
    const items: QgDrama[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = jgDramaFromRow(QgJson.obj(rows[i]), tabName);
      if (drama !== null) {
        items.push(drama);
      }
    }
    return new QgPageResult(items, rows.length >= JG_PAGE_SIZE);
  }

  /** Go fetchJinguoTabs：playlet-tab/all → 合法分类 tab */
  private async jgFetchTabs(): Promise<JgTab[]> {
    const payload: Object | null = await JinguoSource.jgGet('/api/app/playlet-tab/all', null);
    let rows: Object[] = [];
    if (Array.isArray(payload)) {
      rows = payload as Object[];
    } else {
      const map: Record<string, Object> | null = QgJson.obj(payload);
      if (payload !== null && map === null) {
        throw new Error('禁果返回的数据格式无效');
      }
      if (map !== null) {
        rows = QgJson.fieldArr(map, 'list');
      }
    }
    const valid: JgTab[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const row: Record<string, Object> | null = QgJson.obj(rows[i]);
      if (row === null) {
        throw new Error('禁果返回的数据格式无效');
      }
      const id: string = QgJson.str(row['id']);
      const name: string = QgJson.str(row['name']).trim();
      if (RE_ID.test(id) && name.length > 0) {
        const tab: JgTab = new JgTab();
        tab.id = id;
        tab.name = name;
        valid.push(tab);
      }
    }
    if (valid.length === 0) {
      throw new Error('禁果未返回可用分类');
    }
    return valid;
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async jgEnsureCategories(): Promise<void> {
    if (JinguoSource.categoryCache.length > 0) {
      return;
    }
    try {
      const tabs: JgTab[] = await this.jgFetchTabs();
      const categories: QgCategory[] = [new QgCategory(JG_CHOOSE, '精选'), new QgCategory(JG_NEW, '最新')];
      for (let i: number = 0; i < tabs.length; i++) {
        categories.push(new QgCategory(`${JG_TAB_PREFIX}${tabs[i].id}`, tabs[i].name));
      }
      JinguoSource.categoryCache = categories;
    } catch (error) {
      // 分类获取失败不阻塞目录；下次分页请求再试
    }
  }

  /** fetchJinguoDetail 分集构建：VIP 判定 + 排序集数 + 标题回退（非对象/canPlay 非 bool 抛格式错误） */
  private jgBuildChapters(rows: Object[], formatError: string): JgChapter[] {
    const chapters: JgChapter[] = [];
    for (let index: number = 0; index < rows.length; index++) {
      const row: Record<string, Object> | null = QgJson.obj(rows[index]);
      if (row === null) {
        throw new Error(formatError);
      }
      const canPlay: Object | undefined = row['canPlay'];
      if (canPlay !== undefined && canPlay !== null && typeof canPlay !== 'boolean') {
        throw new Error(formatError);
      }
      const rawTitle: string = QgJson.str(row['title']);
      const ch: JgChapter = new JgChapter();
      ch.videoURL = QgJson.str(row['videoUrl']);
      ch.vip = ch.videoURL === '' || canPlay === false;
      ch.key = jgFirstNonEmpty([QgJson.str(row['id']), `${index + 1}`]);
      let currentEpisode: Object | undefined = row['currentEpisode'];
      let sortNumber: number = jgChapterEpisodeNumber(currentEpisode, rawTitle, 0);
      if (sortNumber <= 0) {
        currentEpisode = index + 1;
        sortNumber = index + 1;
      }
      ch.sortNumber = sortNumber;
      ch.title = jgFirstNonEmpty([rawTitle, `第${jgEpisodeString(currentEpisode, index + 1)}集`]);
      chapters.push(ch);
    }
    return chapters;
  }

  /** Go fetchMediaPlaylist：取 m3u8 文本（非 m3u8 时识别 5005 会话失效） */
  private async jgFetchPlaylist(address: string, referer: string): Promise<JgPlaylistResult> {
    if (!jgIsHttpUrl(address)) {
      throw new Error('播放列表地址无效');
    }
    const resp: QgHttpResponse =
      await QgHttp.request(address, 'GET', jgMediaHeaders(referer), null, JG_MEDIA_TIMEOUT_MS);
    if (resp.data.length > JG_PLAYLIST_MAX_BYTES) {
      throw new Error('播放列表过大或读取失败');
    }
    const body: string = resp.text();
    if (resp.status !== 200 || jgBlockReason(body, resp.headers).length > 0) {
      const reason: string = jgBlockReason(body, resp.headers);
      const host: string = jgHostnameOf(address);
      throw new Error(reason.length > 0 ? `${host} HTTP ${resp.status}：${reason}` : `${host} HTTP ${resp.status}`);
    }
    const text: string = body.replace(/^\ufeff/, '').trim();
    if (!text.startsWith('#EXTM3U')) {
      const envelope: Record<string, Object> | null = QgJson.obj(QgJson.parse(body));
      if (envelope !== null && jgCodeText(envelope) === '5005') {
        throw new JgApiError('5005', '播放会话已失效');
      }
      throw new Error('站源未返回有效的播放列表，链接可能已失效');
    }
    const result: JgPlaylistResult = new JgPlaylistResult();
    result.text = text;
    result.url = address;
    return result;
  }

  /** 设备 ID（随机 hex(8) 大写 + 毫秒时间戳，会话内固定） */
  private static jgEnsureDeviceId(): string {
    if (JinguoSource.deviceId.length === 0) {
      JinguoSource.deviceId = `${qgRandomHex(8).toUpperCase()}${Date.now()}`;
    }
    return JinguoSource.deviceId;
  }

  /** Go client.credentials：取访客 token，无则登录（并发去重） */
  private static async jgCredentials(): Promise<string> {
    const deviceID: string = JinguoSource.jgEnsureDeviceId();
    if (JinguoSource.token.length > 0) {
      return JinguoSource.token;
    }
    let pending: Promise<string> | null = JinguoSource.loginPending;
    if (pending === null) {
      pending = JinguoSource.jgLogin(deviceID);
      JinguoSource.loginPending = pending;
    }
    try {
      const token: string = await pending;
      JinguoSource.token = token;
      return token;
    } finally {
      if (JinguoSource.loginPending === pending) {
        JinguoSource.loginPending = null;
      }
    }
  }

  /** Go client.login：POST /api/app/mine/login/h5（无 Authorization 头）换 token */
  private static async jgLogin(deviceID: string): Promise<string> {
    const params: Record<string, Object> = {
      'devID': deviceID,
      'sysType': 'ios',
      'isAppStore': false
    };
    let payload: Object | null = null;
    try {
      payload = await JinguoSource.jgRequest('POST', '/api/app/mine/login/h5', params, '', deviceID);
    } catch (error) {
      const err: Error = error as Error;
      throw new Error(`禁果访客登录失败：${err.message}`);
    }
    const map: Record<string, Object> | null = QgJson.obj(payload);
    const token: string = map !== null ? QgJson.pick(map, ['token']) : '';
    if (token.length === 0 || !jgValidToken(token)) {
      throw new Error('禁果访客登录未返回有效令牌');
    }
    return token;
  }

  private static jgInvalidate(token: string): void {
    if (JinguoSource.token === token) {
      JinguoSource.token = '';
    }
  }

  /** Go client.bases：记忆域名优先 + 域名池去重 */
  private static jgBases(): string[] {
    const bases: string[] = [];
    if (JinguoSource.preferredBase.length > 0) {
      bases.push(JinguoSource.preferredBase);
    }
    for (let i: number = 0; i < JG_API_HOSTS.length; i++) {
      if (!bases.includes(JG_API_HOSTS[i])) {
        bases.push(JG_API_HOSTS[i]);
      }
    }
    return bases;
  }

  /** Go client.get：会话失效（5005）自动重登一次后重试 */
  private static async jgGet(apiPath: string, params: Record<string, Object> | null): Promise<Object | null> {
    for (let attempt: number = 0; attempt < 2; attempt++) {
      const token: string = await JinguoSource.jgCredentials();
      const deviceID: string = JinguoSource.deviceId;
      try {
        return await JinguoSource.jgRequest('GET', apiPath, params, token, deviceID);
      } catch (error) {
        const err: Error = error as Error;
        if (attempt === 0 && jgSessionExpired(err)) {
          JinguoSource.jgInvalidate(token);
          continue;
        }
        throw err;
      }
    }
    throw new Error('禁果访客登录已失效，请稍后重试');
  }

  /** Go client.request：参数加密 + 域名轮换（仅线路级错误切换） */
  private static async jgRequest(method: string, apiPath: string,
    params: Record<string, Object> | null, token: string, deviceID: string): Promise<Object | null> {
    let query: string = '';
    let body: Uint8Array | null = null;
    if (params !== null) {
      const encrypted: string = jgEncryptParam(params);
      if (method === 'GET') {
        query = `?data=${encodeURIComponent(encrypted)}`;
      } else {
        const bodyMap: Record<string, string> = { 'data': encrypted };
        body = qgUtf8Encode(JSON.stringify(bodyMap));
      }
    }
    const bases: string[] = JinguoSource.jgBases();
    let lastError: Error | null = null;
    for (let i: number = 0; i < bases.length; i++) {
      try {
        const payload: Object | null =
          await JinguoSource.jgRequestBase(bases[i], method, apiPath + query, body, token, deviceID);
        JinguoSource.preferredBase = bases[i];
        return payload;
      } catch (error) {
        const err: Error = error as Error;
        if (!(err instanceof JgLineError)) {
          throw err;
        }
        lastError = error as Error;
      }
    }
    throw lastError !== null ? lastError : new Error('禁果线路暂不可用，请稍后重试');
  }

  /** Go client.requestBase：单域名请求（envelope 校验 + hash 解密），线路级错误抛 JgLineError */
  private static async jgRequestBase(base: string, method: string, route: string,
    body: Uint8Array | null, token: string, deviceID: string): Promise<Object | null> {
    const headers: Record<string, string> = {};
    if (token.length > 0) {
      headers['Authorization'] = token;
    }
    if (body !== null) {
      headers['Content-Type'] = 'application/json';
    }
    headers['Accept'] = 'application/json';
    headers['temp'] = 'test';
    headers['X-User-Agent'] = JG_X_USER_AGENT.split('%s').join(deviceID);
    headers['User-Agent'] = JG_UA;
    let resp: QgHttpResponse;
    try {
      resp = await QgHttp.request(base + route, method, headers, body, JG_TIMEOUT_MS);
    } catch (error) {
      const err: Error = error as Error;
      throw new JgLineError(`禁果连接失败：${err.message}`);
    }
    const text: string = resp.text();
    if (resp.data.length > JG_MAX_BODY_BYTES) {
      throw new JgLineError('禁果返回的数据过大或读取失败');
    }
    if (resp.status < 200 || resp.status >= 300) {
      const host: string = jgHostnameOf(base);
      const reason: string = jgBlockReason(text, resp.headers);
      const message: string = reason.length > 0 ?
        `${host} HTTP ${resp.status}：${reason}` : `${host} HTTP ${resp.status}`;
      if (resp.status >= 500 || reason.length > 0) {
        throw new JgLineError(message);
      }
      throw new Error(message);
    }
    const envelope: Record<string, Object> | null = QgJson.obj(QgJson.parse(text));
    if (envelope === null) {
      throw new Error('禁果返回的数据格式无效');
    }
    const code: string = jgCodeText(envelope);
    if (code !== '200') {
      let message: string = jgFirstNonEmpty([QgJson.pick(envelope, ['msg']), '未知错误']);
      if (token.length > 0) {
        message = message.split(token).join('[已隐藏]');
      }
      throw new JgApiError(jgTruncate(code, 20), jgTruncate(message, 160));
    }
    let payload: Object | null = null;
    const rawData: Object | undefined = envelope['data'];
    if (rawData !== undefined && rawData !== null) {
      payload = rawData;
    }
    if (jgHashEnabled(envelope['hash']) && payload !== null) {
      if (typeof payload !== 'string') {
        throw new Error('禁果返回的加密数据格式无效');
      }
      let plain: Uint8Array;
      try {
        plain = jgDecryptResponse(payload);
      } catch (error) {
        throw new Error('禁果返回的数据无法解密，接口可能已变更');
      }
      payload = QgJson.parse(qgUtf8Decode(plain));
    }
    return payload;
  }
}
