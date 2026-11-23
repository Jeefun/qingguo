/**
 * 黄果 AI 站源（主站 https://huangguoai.com）。
 * 接口走 edge envelope：POST /api/edge/request，body 为 {body,content_type,method,path}；
 * 多镜像候选（静态镜像 + SHA256 种子生成的动态子域），单候选 5s 超时，成功记忆镜像；
 * 目录按 4 个 AI 分类并行取数合并，搜索 /api/search，详情 /api/videos/{id}，
 * 播放 /api/videos/{id}/play?ep=N，地址必须含 .m3u8/.mp4。
 * 移植自 guoapp provider_huangguo.go + provider_huangguo_api.go + app_categories.go（全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgToHex, qgUtf8Encode } from '../QgBytes';
import { qgSha256 } from '../QgCrypto';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

/** 主站地址（接口/Referer/封面基准） */
const HGA_BASE: string = 'https://huangguoai.com';
/** 接口 UA（Go config_defaults.go userAgent） */
const HGA_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 静态镜像列表（Go huangguoAIBaseMirrors） */
const HGA_MIRRORS: string[] = ['https://huangguoai.com', 'https://thu.lbvrhyir.cc', 'https://pku.xxbgwypx.cc',
  'https://ttvoij.ediayikma.cc', 'https://thu.ediayikma.cc', 'https://pku.ediayikma.cc',
  'https://fdu.ediayikma.cc', 'https://thu.agdkczeyx.cc'];
/** 动态镜像子域的后缀域名池（Go huangguoAIMirrorDomains） */
const HGA_MIRROR_DOMAINS: string[] = ['lbvrhyir.cc', 'xxbgwypx.cc', 'ediayikma.cc', 'agdkczeyx.cc'];
/** AI 分类（Go nativeAICategories） */
const HGA_AI_CATEGORY_IDS: string[] = ['ai-duanju', 'ai-manju', 'ai-huanlian', 'ai-mogai'];
const HGA_AI_CATEGORY_NAMES: string[] = ['AI 短剧', 'AI 漫剧', 'AI 换脸', 'AI 魔改'];
/** 目录分页大小（Go fetchHuangguoAICatalogPage size=24） */
const HGA_CATALOG_SIZE: number = 24;
/** 搜索分页大小（Go huangguoAISearchPageSize） */
const HGA_SEARCH_SIZE: number = 20;
/** 单候选超时（Go providerTimeout） */
const HGA_TIMEOUT_MS: number = 12000;
/** 多候选时单次超时（Go fetchProviderRequest） */
const HGA_CANDIDATE_TIMEOUT_MS: number = 5000;
const HGA_MAX_BODY_BYTES: number = 20 * 1024 * 1024;

/** Go rankingSourceID：合法剧集 ID */
const RE_HGA_RANK_ID: RegExp = /^[a-zA-Z0-9_-]{1,100}$/;
/** Go huangguoTitleFragment：标题疑似站点模板片段 */
const RE_HGA_TITLE_FRAGMENT: RegExp = /(?:\b(?:class|type|title|aria-label)\s*=|(?:data|ata)-search-input|hg-search(?:__|-))/i;
/** Go reEpisodeNumber */
const RE_HGA_EPISODE_NUMBER: RegExp =
  /(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))/i;
/** Go reFinishedEpisodeRemark */
const RE_HGA_FINISHED: RegExp = /(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/;
const RE_HGA_SCRIPT: RegExp = /<script\b[\s\S]*?<\/script>/gi;
const RE_HGA_STYLE: RegExp = /<style\b[\s\S]*?<\/style>/gi;
const RE_HGA_ANY_TAG: RegExp = /<[^>]+>/g;
const RE_HGA_SPACES: RegExp = /\s+/g;
const RE_HGA_INT: RegExp = /^[+-]?[0-9]+$/;

/** huangguoAIAPI envelope（Go json.Marshal map 按键排序：body, content_type, method, path） */
class HgaEnvelope {
  body: string = '';
  content_type: string = '';
  method: string = 'GET';
  path: string = '';
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function hgaDecodeNumericEntities(text: string): string {
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
function hgaUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = hgaDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go cleanText：去 script/style/标签 + 实体解码 + 空白折叠 */
function hgaStripText(text: string): string {
  let out: string = text.replace(RE_HGA_SCRIPT, ' ');
  out = out.replace(RE_HGA_STYLE, ' ');
  out = out.replace(RE_HGA_ANY_TAG, ' ');
  out = hgaUnescapeHtml(out);
  out = out.replace(RE_HGA_SPACES, ' ');
  return out.trim();
}

/** Go firstNonEmpty：第一个非空（trim 后）值 */
function hgaFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** Go mapString：依次取第一个非空字符串字段（自动 trim） */
function hgaMapString(row: Record<string, Object> | null, keys: string[]): string {
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
function hgaAddSlicePart(part: string, seen: Record<string, boolean>, out: string[]): void {
  const value: string = part.trim();
  if (value.length > 0 && seen[value] !== true) {
    seen[value] = true;
    out.push(value);
  }
}

/** Go mapStringSlice：字符串按 ,/，、 切分，数组取 name/title/label/tag */
function hgaMapStringSlice(row: Record<string, Object> | null, keys: string[]): string[] {
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
        hgaAddSlicePart(parts[i], seen, out);
      }
    } else if (Array.isArray(value)) {
      const items: Object[] = value as Object[];
      for (let i: number = 0; i < items.length; i++) {
        const entry: Record<string, Object> | null = QgJson.obj(items[i]);
        if (entry !== null) {
          hgaAddSlicePart(hgaMapString(entry, ['name', 'title', 'label', 'tag']), seen, out);
          continue;
        }
        hgaAddSlicePart(QgJson.str(items[i]), seen, out);
      }
    }
  }
  return out;
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function hgaIsHttpUrl(raw: string): boolean {
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

/** URL 拆解：[scheme, host, path+query+fragment]；非法返回 null */
function hgaSplitURL(raw: string): string[] | null {
  const match: RegExpExecArray | null =
    /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([\s\S]*)$/.exec(raw);
  if (match === null) {
    return null;
  }
  return [match[1], match[2], match[3]];
}

/** host 部分取小写主机名（去端口） */
function hgaHostnameOf(hostPart: string): string {
  const colon: number = hostPart.indexOf(':');
  return (colon >= 0 ? hostPart.substring(0, colon) : hostPart).toLowerCase();
}

/** Go rehostProviderURL：URL 换 scheme + host */
function hgaRehost(rawURL: string, mirror: string): string {
  const parts: string[] | null = hgaSplitURL(rawURL);
  const mp: string[] | null = hgaSplitURL(mirror);
  if (parts === null || mp === null || mp[2].length === 0) {
    return '';
  }
  return `${mp[1]}://${mp[2]}${parts[3]}`;
}

/** Go generatedHuangguoAIMirrors：SHA256(seed:i) 生成镜像子域 */
function hgaGeneratedMirrors(seed: string, count: number): string[] {
  const out: string[] = [];
  if (count <= 0) {
    return out;
  }
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; out.length < count && i < count * 4; i++) {
    const sum: Uint8Array = qgSha256(qgUtf8Encode(`${seed}:${i}`));
    const hexText: string = qgToHex(sum);
    let sub: string = hexText.substring(0, 6).replace(/^[0-9]+/, '');
    if (sub.length < 4) {
      sub = hexText.substring(6, 12);
    }
    if (sub.length > 6) {
      sub = sub.substring(0, 6);
    }
    if (sub.length < 3 || seen[sub] === true) {
      continue;
    }
    seen[sub] = true;
    out.push(`https://${sub}.${HGA_MIRROR_DOMAINS[out.length % HGA_MIRROR_DOMAINS.length]}`);
  }
  return out;
}

/** 候选去重追加 */
function hgaAddCandidate(candidate: string, seen: Record<string, boolean>, out: string[]): void {
  if (candidate.length > 0 && seen[candidate] !== true) {
    seen[candidate] = true;
    out.push(candidate);
  }
}

/** 最近成功的镜像（Go providerHosts[huangguoai]，会话内静态记忆） */
let hgaPreferredHost: string = '';

/** Go providerURLCandidates：记忆镜像 → 主站 → 8 个生成镜像 → 静态镜像 */
function hgaCandidates(rawURL: string): string[] {
  const parts: string[] | null = hgaSplitURL(rawURL);
  if (parts === null || hgaHostnameOf(parts[2]) !== 'huangguoai.com') {
    return [rawURL];
  }
  const out: string[] = [];
  const seen: Record<string, boolean> = {};
  hgaAddCandidate(hgaRehost(rawURL, hgaPreferredHost), seen, out);
  hgaAddCandidate(hgaRehost(rawURL, HGA_BASE), seen, out);
  const generated: string[] = hgaGeneratedMirrors(rawURL, 8);
  for (let i: number = 0; i < generated.length; i++) {
    hgaAddCandidate(hgaRehost(rawURL, generated[i]), seen, out);
  }
  for (let i: number = 0; i < HGA_MIRRORS.length; i++) {
    hgaAddCandidate(hgaRehost(rawURL, HGA_MIRRORS[i]), seen, out);
  }
  if (out.length === 0) {
    return [rawURL];
  }
  return out;
}

/** Go providerRefererForURL：黄果请求的 Referer 跟随候选域名 */
function hgaRefererFor(candidate: string, fallback: string): string {
  const target: string[] | null = hgaSplitURL(candidate);
  const previous: string[] | null = hgaSplitURL(fallback);
  if (target === null || previous === null || target[2].length === 0 || previous[2].length === 0) {
    return fallback;
  }
  return `${target[1]}://${target[2]}/`;
}

/** 相对地址补全（url.ResolveReference 简化版，含 ./ 与 ../ 段处理） */
function hgaResolveReference(pageURL: string, ref: string): string {
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

/** Go resolveProviderURL：转义修复 + 相对补全 + http→https 升级 */
function hgaResolveURL(baseURL: string, ref: string): string {
  let value: string = hgaUnescapeHtml(ref).trim();
  if (value.length === 0) {
    return '';
  }
  value = value.replace(/\\\//g, '/');
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(value)) {
    if (value.startsWith('http://')) {
      return `https://${value.substring(7)}`;
    }
    return value;
  }
  const resolved: string = hgaResolveReference(baseURL, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring(7)}`;
  }
  return resolved;
}

/** Go normalizeProviderMediaURL：播放地址规范化，非 m3u8/mp4 视为无效 */
function hgaNormalizeMediaURL(pageURL: string, raw: string): string {
  let value: string = hgaUnescapeHtml(raw).trim();
  value = value.replace(/^[\t\r\n "']+/, '').replace(/[\t\r\n "']+$/, '');
  if (value.length === 0) {
    return '';
  }
  value = value.replace(/\\\//g, '/');
  const resolved: string = hgaResolveURL(pageURL, value);
  const lowered: string = resolved.toLowerCase();
  if (!lowered.includes('.m3u8') && !lowered.includes('.mp4')) {
    return '';
  }
  return resolved;
}

/** Go cleanID：去首尾空白/斜杠/引号 + 截断 query/fragment */
function hgaCleanID(value: string): string {
  let s: string = hgaUnescapeHtml(value).trim();
  s = s.replace(/^[ \/\t\r\n"']+/, '').replace(/[ \/\t\r\n"']+$/, '');
  const cut: number = s.search(/[?#]/);
  if (cut >= 0) {
    s = s.substring(0, cut);
  }
  return s;
}

/** Go detailIDFromString：从任意字符串中提取 detail/<id> 的 id */
function hgaDetailIDFromString(value: string): string {
  let path: string = hgaUnescapeHtml(value);
  const cut: number = path.search(/[?#]/);
  if (cut >= 0) {
    path = path.substring(0, cut);
  }
  const parts: string[] = path.split('/');
  for (let i: number = 0; i + 1 < parts.length; i++) {
    if (parts[i] === 'detail') {
      return hgaCleanID(parts[i + 1]);
    }
  }
  return '';
}

/** Go huangguoTitleNeedsRepair：标题为空/等于 ID/站点模板片段时需修复 */
function hgaTitleNeedsRepair(title: string, sourceID: string): boolean {
  const value: string = title.trim();
  return value.length === 0 || value === sourceID || value === '短剧' || value === '搜索' ||
    RE_HGA_TITLE_FRAGMENT.test(value) ||
    (value.includes('搜索记录') && value.includes('暂无搜索记录'));
}

/** Go huangguoMapEpisodes：集数字段 → 正整数（0 未知） */
function hgaMapEpisodes(row: Record<string, Object> | null): number {
  const keys: string[] = ['episode_count', 'episodeCount', 'total_episodes', 'totalEpisodes',
    'totalEpisode', 'total_episode', 'episodes', 'total'];
  for (let i: number = 0; i < keys.length; i++) {
    const text: string = hgaMapString(row, [keys[i]]);
    if (text.length > 0 && RE_HGA_INT.test(text)) {
      const count: number = Number(text);
      if (count > 0) {
        return Math.trunc(count);
      }
    }
  }
  return 0;
}

/** Go normalizeViews：播放量文本归一为「N次播放」 */
function hgaNormalizeViews(value: string): string {
  const s: string = value.trim();
  if (s.length === 0) {
    return '';
  }
  if (s.includes('次播放')) {
    return s;
  }
  if (s.toLowerCase().includes('w') || s.includes('万')) {
    return `${s}次播放`;
  }
  const n: number = Number(s);
  if (Number.isNaN(n)) {
    return s;
  }
  if (n <= 0) {
    return '';
  }
  return `${n}次播放`;
}

/** Go episodeIndex：从文本提取分集号 */
function hgaEpisodeIndex(text: string, fallback: number): number {
  const match: RegExpExecArray | null = RE_HGA_EPISODE_NUMBER.exec(text);
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

/** Go releaseStatusFromRemark：更新说明 → ongoing/finished/unknown */
function hgaReleaseStatusFromRemark(remark: string): string {
  if (remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载')) {
    return 'ongoing';
  }
  if (RE_HGA_FINISHED.test(remark) || remark.includes('完结')) {
    return 'finished';
  }
  return 'unknown';
}

/** Go dramaFromAIMap：行记录 → QgDrama（资料不完整返回 null） */
function hgaDramaFromMap(row: Record<string, Object> | null, pageURL: string,
  category: string): QgDrama | null {
  if (row === null) {
    return null;
  }
  let sourceID: string = hgaFirstNonEmpty([hgaMapString(row, ['id']),
    hgaMapString(row, ['videoId']), hgaMapString(row, ['video_id']),
    hgaMapString(row, ['vid']), hgaMapString(row, ['slug'])]);
  if (sourceID.length === 0) {
    const keys: string[] = Object.keys(row);
    for (let i: number = 0; i < keys.length; i++) {
      const value: Object | undefined = row[keys[i]];
      if (typeof value === 'string') {
        const id: string = hgaDetailIDFromString(value);
        if (id.length > 0) {
          sourceID = id;
          break;
        }
      }
    }
  }
  if (sourceID.length > 0) {
    const detailID: string = hgaDetailIDFromString(sourceID);
    if (detailID.length > 0) {
      sourceID = detailID;
    }
  }
  sourceID = hgaCleanID(sourceID);
  if (sourceID.length === 0) {
    return null;
  }
  const title: string = hgaFirstNonEmpty([hgaMapString(row, ['title']),
    hgaMapString(row, ['name']), hgaMapString(row, ['videoTitle']),
    hgaMapString(row, ['video_title']), hgaMapString(row, ['videoName']),
    hgaMapString(row, ['video_name'])]);
  if (hgaTitleNeedsRepair(title, sourceID)) {
    return null;
  }
  const cover: string = hgaResolveURL(pageURL, hgaFirstNonEmpty([hgaMapString(row, ['cover']),
    hgaMapString(row, ['coverUrl']), hgaMapString(row, ['cover_url']),
    hgaMapString(row, ['coverImage']), hgaMapString(row, ['cover_image']),
    hgaMapString(row, ['image']), hgaMapString(row, ['imageUrl']),
    hgaMapString(row, ['thumbnail']), hgaMapString(row, ['poster']),
    hgaMapString(row, ['posterUrl'])]));
  const desc: string = hgaFirstNonEmpty([hgaMapString(row, ['desc']),
    hgaMapString(row, ['description']), hgaMapString(row, ['intro']),
    hgaMapString(row, ['summary'])]);
  const episodes: number = hgaMapEpisodes(row);
  let status: string = '';
  const finishedFlag: string = hgaMapString(row, ['is_finished']).toLowerCase();
  if (finishedFlag === 'true' || finishedFlag === '1') {
    status = 'finished';
  } else if (finishedFlag === 'false' || finishedFlag === '0') {
    status = 'ongoing';
  }
  let remark: string = hgaFirstNonEmpty([hgaMapString(row, ['vod_remarks']),
    hgaMapString(row, ['remark']), hgaMapString(row, ['remarks'])]);
  if (remark.length === 0 && episodes > 0) {
    remark = status === 'finished' ? `全${episodes}集` : `更新至 ${episodes} 集`;
  }
  const views: string = hgaNormalizeViews(hgaFirstNonEmpty([hgaMapString(row, ['views']),
    hgaMapString(row, ['view_count']), hgaMapString(row, ['viewCount']),
    hgaMapString(row, ['view_num']), hgaMapString(row, ['viewNum']),
    hgaMapString(row, ['views_text']), hgaMapString(row, ['view_count_text']),
    hgaMapString(row, ['play_count']), hgaMapString(row, ['playCount']),
    hgaMapString(row, ['play_num']), hgaMapString(row, ['playNum']),
    hgaMapString(row, ['play_count_text']), hgaMapString(row, ['hits']),
    hgaMapString(row, ['hit_count']), hgaMapString(row, ['plays']),
    hgaMapString(row, ['play'])]));
  const tags: string[] = hgaMapStringSlice(row, ['tags', 'tag', 'categories', 'category']);
  const drama: QgDrama = new QgDrama(`huangguoai:${sourceID}`, title, category);
  drama.sourceId = 'huangguoai';
  drama.intro = desc;
  drama.cover = cover;
  drama.episodeCount = episodes;
  drama.finished = status !== 'ongoing';
  drama.tags = tags;
  drama.viewsText = views;
  drama.remark = remark;
  return drama;
}

/** Go parseHuangguoAIJSONCards：递归遍历 JSON 收集剧集卡片（按站内 ID 去重） */
function hgaParseCards(value: Object | null, pageURL: string, category: string,
  out: QgDrama[], seen: Record<string, boolean>): void {
  if (value === null) {
    return;
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      hgaParseCards(items[i], pageURL, category, out, seen);
    }
    return;
  }
  const row: Record<string, Object> | null = QgJson.obj(value);
  if (row === null) {
    return;
  }
  const drama: QgDrama | null = hgaDramaFromMap(row, pageURL, category);
  if (drama !== null) {
    const siteID: string = drama.id.substring('huangguoai:'.length);
    if (seen[siteID] !== true) {
      seen[siteID] = true;
      out.push(drama);
    }
    return;
  }
  const keys: string[] = Object.keys(row);
  for (let i: number = 0; i < keys.length; i++) {
    const child: Object | undefined = row[keys[i]];
    if (child !== undefined && child !== null && typeof child === 'object') {
      hgaParseCards(child, pageURL, category, out, seen);
    }
  }
}

export class HuangguoaiSource extends QgSource {
  constructor() {
    super('huangguoai', '黄果 AI');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < HGA_AI_CATEGORY_IDS.length; i++) {
      all.push(new QgCategory(HGA_AI_CATEGORY_IDS[i], HGA_AI_CATEGORY_NAMES[i]));
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000) {
      throw new Error('黄果目录页码无效');
    }
    const category: string = categoryId.trim();
    if (category.length > 128 || category.includes('|') || category.includes('/') ||
      category.includes('\\') || category.includes('\r') || category.includes('\n')) {
      throw new Error('黄果分类无效');
    }
    const selected: number[] = [];
    for (let i: number = 0; i < HGA_AI_CATEGORY_IDS.length; i++) {
      if (category.length === 0 || category === HGA_AI_CATEGORY_IDS[i]) {
        selected.push(i);
      }
    }
    if (selected.length === 0) {
      throw new Error('黄果分类无效');
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    const failures: Error[] = [];
    let hasMore: boolean = false;
    for (let s: number = 0; s < selected.length; s++) {
      const index: number = selected[s];
      const path: string = `/api/videos/category/${encodeURIComponent(HGA_AI_CATEGORY_IDS[index])}` +
        `?sort=hot&page=${page}&size=${HGA_CATALOG_SIZE}`;
      try {
        const data: Object = await this.hgaApi(path);
        const cards: QgDrama[] = [];
        hgaParseCards(data, `${HGA_BASE}/`, HGA_AI_CATEGORY_NAMES[index], cards, {});
        hasMore = hasMore || cards.length >= HGA_CATALOG_SIZE;
        for (let i: number = 0; i < cards.length; i++) {
          if (seen[cards[i].id] !== true) {
            seen[cards[i].id] = true;
            items.push(cards[i]);
          }
        }
      } catch (error) {
        failures.push(error as Error);
        hasMore = true;
      }
    }
    if (failures.length === selected.length && items.length === 0) {
      throw failures[0];
    }
    if (items.length === 0 && page === 1) {
      throw new Error('站源暂未返回剧集，请稍后刷新');
    }
    return new QgPageResult(items, hasMore);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    const query: string = keyword.trim();
    if (query.length === 0 || query.length > 256 || page < 1 || page > 1000000) {
      throw new Error('黄果搜索关键词无效');
    }
    const path: string = `/api/search?q=${encodeURIComponent(query)}&page=${page}&size=${HGA_SEARCH_SIZE}`;
    const data: Object = await this.hgaApi(path);
    const cards: QgDrama[] = [];
    hgaParseCards(data, `${HGA_BASE}/`, '', cards, {});
    const row: Record<string, Object> | null = QgJson.obj(data);
    const pagination: Record<string, Object> | null = row !== null ? QgJson.field(row, 'pagination') : null;
    const pages: number = pagination !== null ? QgJson.num(pagination['pages']) : 0;
    return new QgPageResult(cards, page < pages);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    let sourceID: string = dramaId.startsWith('huangguoai:') ?
      dramaId.substring('huangguoai:'.length) : dramaId;
    sourceID = sourceID.trim().replace(/^\/+/, '').replace(/\/+$/, '');
    if (sourceID.startsWith('detail/')) {
      sourceID = sourceID.substring('detail/'.length);
    }
    if (!RE_HGA_RANK_ID.test(sourceID)) {
      throw new Error('无效的黄果剧集 ID');
    }
    const data: Object = await this.hgaApi(`/api/videos/${encodeURIComponent(sourceID)}`);
    const row: Record<string, Object> | null = QgJson.obj(data);
    const drama: QgDrama | null = hgaDramaFromMap(row, `${HGA_BASE}/`, '');
    if (drama === null || drama.id !== `huangguoai:${sourceID}`) {
      throw new Error('黄果详情与请求剧集不符');
    }
    const rows: Object[] = row !== null ? QgJson.fieldArr(row, 'episodes') : [];
    const episodes: QgEpisode[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const episodeRow: Record<string, Object> | null = QgJson.obj(rows[i]);
      const episode: number = Number(hgaMapString(episodeRow, ['ep_num']));
      if (Number.isNaN(episode) || episode < 1) {
        continue;
      }
      const key: string = `${episode}`;
      if (seen[key] === true) {
        continue;
      }
      seen[key] = true;
      const title: string = hgaMapString(episodeRow, ['title']);
      episodes.push(new QgEpisode(key, title.length > 0 ? title : `第${episode}集`, episode));
    }
    if (rows.length === 0) {
      episodes.push(new QgEpisode('1', drama.title, 1));
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => {
      if (a.order !== b.order) {
        return a.order - b.order;
      }
      return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
    });
    if (drama.episodeCount < episodes.length) {
      drama.episodeCount = episodes.length;
    }
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    let sourceID: string = dramaId.startsWith('huangguoai:') ?
      dramaId.substring('huangguoai:'.length) : dramaId;
    sourceID = sourceID.trim().replace(/^\/+/, '').replace(/\/+$/, '');
    const episode: number = Number(episodeId.trim());
    if (!RE_HGA_RANK_ID.test(sourceID) || Number.isNaN(episode) || episode < 1) {
      throw new Error('黄果集数无效');
    }
    const path: string = `/api/videos/${encodeURIComponent(sourceID)}/play?ep=${episode}&page_texts=0`;
    const data: Object = await this.hgaApi(path);
    const row: Record<string, Object> | null = QgJson.obj(data);
    const videoURL: string = row !== null ? QgJson.pick(row, ['video_url']) : '';
    const address: string = hgaNormalizeMediaURL(`${HGA_BASE}/`, videoURL);
    if (!hgaIsHttpUrl(address)) {
      throw new Error('huangguoai 未返回有效播放地址，请刷新章节或确认站点访问权限');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${HGA_BASE}/`;
    info.headers = { 'User-Agent': HGA_UA, 'Referer': info.referer, 'Origin': HGA_BASE };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': HGA_UA, 'Referer': `${HGA_BASE}/` };
  }

  /** Go huangguoAIAPI：envelope POST /api/edge/request → status 1 → data */
  private async hgaApi(path: string): Promise<Object> {
    const envelope: HgaEnvelope = new HgaEnvelope();
    envelope.method = 'GET';
    envelope.path = path;
    const body: Uint8Array = qgUtf8Encode(JSON.stringify(envelope));
    const text: string = await this.hgaFetchText(`${HGA_BASE}/api/edge/request`, `${HGA_BASE}/`, body);
    const parsed: Object | null = QgJson.parse(text);
    const row: Record<string, Object> | null = QgJson.obj(parsed);
    if (row === null) {
      throw new Error('黄果接口返回格式无效');
    }
    const status: number = QgJson.num(row['status']);
    if (status !== 1) {
      const msg: string = QgJson.str(row['msg']).trim();
      throw new Error(`黄果接口返回失败：${msg.length > 0 ? msg : '未知错误'}`);
    }
    const data: Object | undefined = row['data'];
    if (data === undefined || data === null) {
      throw new Error('黄果接口数据格式已变化');
    }
    return data;
  }

  /** Go fetchProviderRequest：多镜像候选轮换，成功记忆镜像 */
  private async hgaFetchText(rawURL: string, referer: string,
    payload: Uint8Array | null): Promise<string> {
    const candidates: string[] = hgaCandidates(rawURL);
    const multi: boolean = candidates.length > 1;
    const attempts: number = multi ? 1 : 3;
    let lastError: Error | null = null;
    let tried: number = 0;
    for (let c: number = 0; c < candidates.length; c++) {
      const candidate: string = candidates[c];
      for (let attempt: number = 1; attempt <= attempts; attempt++) {
        tried++;
        if (attempt > 1) {
          await hgaSleep(attempt * 1000);
        }
        const headers: Record<string, string> = {
          'User-Agent': HGA_UA,
          'Referer': hgaRefererFor(candidate, referer),
          'Accept-Language': 'zh-CN,zh;q=0.9'
        };
        if (payload !== null) {
          headers['Content-Type'] = 'application/json';
          headers['Accept'] = 'application/json';
        }
        let resp: QgHttpResponse;
        try {
          resp = await QgHttp.request(candidate, payload !== null ? 'POST' : 'GET', headers, payload,
            multi ? HGA_CANDIDATE_TIMEOUT_MS : HGA_TIMEOUT_MS, 0, 30, this.id);
        } catch (error) {
          lastError = error as Error;
          continue;
        }
        if (resp.data.length > HGA_MAX_BODY_BYTES) {
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
        const parts: string[] | null = hgaSplitURL(candidate);
        if (parts !== null && hgaHostnameOf(parts[2]) === 'huangguoai.com') {
          hgaPreferredHost = `${parts[1]}://${parts[2]}`;
        }
        return resp.text();
      }
    }
    if (multi && lastError !== null) {
      throw new Error(`黄果来源请求失败：已尝试 ${tried} 次，最后错误：${lastError.message}`);
    }
    throw lastError !== null ? lastError : new Error('黄果来源请求失败');
  }
}

/** 异步等待（重试退避） */
function hgaSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}
