/**
 * 黄果视频站源（https://huangguo.video）。
 * 纯 HTML 站点：目录 GET /videos?page=N[&category=X]（video-card 卡片解析），
 * 分类从 /videos 页锚点懒加载发现（category 查询参数须为正整数）；
 * 无服务端搜索：取目录前 3 页本地过滤；
 * 详情 GET /series/<code> 或 /video/<code>（h1/og:title 标题、og:image 封面、hg-tag 标签、
 * hg-web-detail__meta 播放量与连载状态）；分集解析 series 页 video-card 内 data-hls；
 * 播放按分集 id（video/<code> 或 1）重新请求对应页面取 data-hls。
 * 移植自 guoapp provider_huangguo.go + provider_huangguo_cards.go + provider_detail_metadata.go
 * + app_categories.go（parseHuangguoVideoCategories）+ app_runtime.go（hgv 目录分发）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgSource } from './QgSource';

/** 主站地址（页面/Referer/相对地址基准） */
const HGV_BASE: string = 'https://huangguo.video';
/** 接口 UA（Go config_defaults.go userAgent） */
const HGV_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
/** 单候选请求超时（Go providerTimeout） */
const HGV_TIMEOUT_MS: number = 12000;
const HGV_MAX_BODY_BYTES: number = 20 * 1024 * 1024;
/** 目录分页大小基准（Go hasMore = len(items) >= 20） */
const HGV_PAGE_SIZE: number = 20;
/** 本地搜索抓取的目录页数 */
const HGV_SEARCH_PAGES: number = 3;

/** Go rankingSourceID：合法剧集/分集代码 */
const RE_HGV_RANK_ID: RegExp = /^[a-zA-Z0-9_-]{1,100}$/;
/** Go reEpisodeNumber */
const RE_HGV_EPISODE_NUMBER: RegExp =
  /(?:第\s*0*(\d+)\s*(?:集|话|期)|(?:更新至|共|全)\s*0*(\d+)\s*(?:集|话|期)|(?:episode|ep)\s*#?\s*0*(\d+))/i;
/** Go reFinishedEpisodeRemark */
const RE_HGV_FINISHED: RegExp = /(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)/;
/** Go reVideoCard：含 video-card class 的 article 卡片 */
const RE_HGV_VIDEO_CARD: RegExp =
  /<article\b[^>]*class=["'][^"']*\bvideo-card\b[^"']*["'][^>]*>[\s\S]*?<\/article>/gi;
/** Go reVideoCardMeta：卡片内 font-mono-meta 段（连载状态） */
const RE_HGV_CARD_META: RegExp =
  /<p\b[^>]*class=["'][^"']*\bfont-mono-meta\b[^"']*["'][^>]*>([\s\S]*?)<\/p>/gi;
/** Go reVideoDetailMeta：</h1> 后首个 font-mono-meta 段 */
const RE_HGV_DETAIL_META: RegExp =
  /<\/h1>[\s\S]*?<p\b[^>]*class=["'][^"']*\bfont-mono-meta\b[^"']*["'][^>]*>([\s\S]*?)<\/p>/gi;
/** Go reAnyArticle：任意 article 块（video-card 缺失时回退） */
const RE_HGV_ANY_ARTICLE: RegExp = /<article\b[^>]*>[\s\S]*?<\/article>/gi;
/** Go reHuangguoLink：series/video 链接 */
const RE_HGV_LINK: RegExp =
  /<a\b[^>]*href=["']([^"']*\/(?:series|video)\/([^"'/?#]+)[^"']*)["'][^>]*>[\s\S]*?<\/a>/gi;
const RE_HGV_TITLE_TAG: RegExp = /<title[^>]*>([\s\S]*?)<\/title>/gi;
const RE_HGV_H1_TAG: RegExp = /<h1[^>]*>([\s\S]*?)<\/h1>/gi;
/** og:title 元标签（Go extractPageTitle） */
const RE_HGV_OG_TITLE: RegExp =
  /<meta\b[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["'][^>]*>/gi;
/** Go reDescMeta */
const RE_HGV_DESC_META: RegExp =
  /<meta\b[^>]*(?:name|property)=["'](?:description|og:description)["'][^>]*content=["']([^"']+)["'][^>]*>/gi;
/** Go reDataHLS */
const RE_HGV_DATA_HLS: RegExp = /data-hls=["']([^"']+)["']/gi;
/** Go reViewsText */
const RE_HGV_VIEWS: RegExp = /[0-9]+(?:\.[0-9]+)?\s*[w万]?\s*次播放/gi;
/** Go coverMetaTag：全部 meta 元标签（og:image 提取用） */
const RE_HGV_META_TAG: RegExp = /<meta\b[^>]*>/gi;
/** Go categoryAnchorPattern：分类锚点 */
const RE_HGV_ANCHOR: RegExp = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
/** 锚点文本内标签剥离（Go categoryTextPattern） */
const RE_HGV_ANCHOR_TEXT: RegExp = /<[^>]*>/g;
/** Go huangguoHTMLTag：标签词法（元素块深度匹配） */
const RE_HGV_HTML_TAG: RegExp = /<(\/?)([a-z][a-z0-9:-]*)\b(?:[^<>"']|"[^"]*"|'[^']*')*>/gi;
/** Go huangguoNonContent：注释/script/style 剥离 */
const RE_HGV_NON_CONTENT: RegExp =
  /<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?<\/script\s*>|<style\b[^>]*>[\s\S]*?<\/style\s*>/gi;
/** Go extractTags：hg-tag 元素 */
const RE_HGV_TAG: RegExp = /<[^>]+class=["'][^"']*hg-tag[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/gi;
const RE_HGV_SCRIPT: RegExp = /<script\b[\s\S]*?<\/script>/gi;
const RE_HGV_STYLE: RegExp = /<style\b[\s\S]*?<\/style>/gi;
const RE_HGV_ANY_TAG: RegExp = /<[^>]+>/g;
const RE_HGV_SPACES: RegExp = /\s+/g;
/** 分类 ID 须为正整数（Go validNativeCategory hgv 分支） */
const RE_HGV_INT_POS: RegExp = /^[0-9]+$/;
/** 分集 ID：video/<code> */
const RE_HGV_EPISODE_ID: RegExp = /^video\/[a-zA-Z0-9_-]{1,100}$/;

/** 分集候选（Go providerEpisode） */
class HgvEpisode {
  key: string = '';
  title: string = '';
  url: string = '';
  index: number = 0;
  hls: string = '';
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function hgvDecodeNumericEntities(text: string): string {
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
function hgvUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = hgvDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go cleanText：去 script/style/标签 + 实体解码 + 空白折叠 */
function hgvCleanText(text: string): string {
  let out: string = text.replace(RE_HGV_SCRIPT, ' ');
  out = out.replace(RE_HGV_STYLE, ' ');
  out = out.replace(RE_HGV_ANY_TAG, ' ');
  out = hgvUnescapeHtml(out);
  out = out.replace(RE_HGV_SPACES, ' ');
  return out.trim();
}

/** Go firstNonEmpty：第一个非空（trim 后）值 */
function hgvFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}

/** regexp.QuoteMeta：正则元字符转义 */
function hgvQuoteMeta(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (/[a-zA-Z0-9_]/.test(ch)) {
      out += ch;
    } else {
      out += `\\${ch}`;
    }
  }
  return out;
}

/** 取首个匹配（不改变全局 regex 的共享状态） */
function hgvFirstMatch(re: RegExp, text: string): RegExpExecArray | null {
  re.lastIndex = 0;
  const match: RegExpExecArray | null = re.exec(text);
  re.lastIndex = 0;
  return match;
}

/** 收集全部匹配（Go FindAllString* 对应） */
function hgvAllMatches(re: RegExp, text: string): RegExpExecArray[] {
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

/** Go firstMatchText：首个匹配原文（已 trim） */
function hgvFirstMatchText(re: RegExp, text: string): string {
  const match: RegExpExecArray | null = hgvFirstMatch(re, text);
  if (match === null) {
    return '';
  }
  return match[0].trim();
}

/** Go extractAttr：从 HTML 片段中提取属性值 */
function hgvExtractAttr(block: string, names: string[]): string {
  for (let i: number = 0; i < names.length; i++) {
    const re: RegExp = new RegExp(`\\b${hgvQuoteMeta(names[i])}\\s*=\\s*["']([^"']+)["']`, 'gi');
    const match: RegExpExecArray | null = hgvFirstMatch(re, block);
    if (match !== null && match.length > 1) {
      return hgvUnescapeHtml(match[1]).trim();
    }
  }
  return '';
}

/** Go extractByClassText：按 class 取元素内文本 */
function hgvByClassText(raw: string, className: string): string {
  if (className.length === 0) {
    return '';
  }
  const re: RegExp = new RegExp(
    `<[^>]+class=["'][^"']*${hgvQuoteMeta(className)}[^"']*["'][^>]*>([\\s\\S]*?)</[^>]+>`, 'gi');
  const match: RegExpExecArray | null = hgvFirstMatch(re, raw);
  if (match === null || match.length < 2) {
    return '';
  }
  return hgvCleanText(match[1]);
}

/** Go huangguoElementBlock：同名标签深度匹配取完整元素块 */
function hgvElementBlock(raw: string, start: number, end: number, tag: string): string {
  const rest: string = raw.substring(end);
  const tags: RegExpExecArray[] = hgvAllMatches(RE_HGV_HTML_TAG, rest);
  let depth: number = 1;
  for (let i: number = 0; i < tags.length; i++) {
    const match: RegExpExecArray = tags[i];
    const tagName: string = match[2] || '';
    if (tagName.toLowerCase() !== tag.toLowerCase()) {
      continue;
    }
    const slash: string = match[1] || '';
    if (slash.length > 0) {
      depth--;
    } else if (!match[0].trim().endsWith('/>')) {
      depth++;
    }
    if (depth === 0) {
      return raw.substring(start, end + match.index + match[0].length);
    }
  }
  return raw.substring(start, end);
}

/** Go huangguoClassBlock：按 class 取完整元素块 */
function hgvClassBlock(raw: string, className: string): string {
  if (className.length === 0) {
    return '';
  }
  const tags: RegExpExecArray[] = hgvAllMatches(RE_HGV_HTML_TAG, raw);
  for (let i: number = 0; i < tags.length; i++) {
    const match: RegExpExecArray = tags[i];
    const slash: string = match[1] || '';
    if (slash.length > 0) {
      continue;
    }
    const classes: string[] = hgvExtractAttr(match[0], ['class']).split(/\s+/);
    let hit: boolean = false;
    for (let c: number = 0; c < classes.length; c++) {
      if (classes[c] === className) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      continue;
    }
    return hgvElementBlock(raw, match.index, match.index + match[0].length, match[2] || '');
  }
  return '';
}

/** Go isProviderHTTPMediaURL：http/https、主机非空、无 userinfo */
function hgvIsHttpUrl(raw: string): boolean {
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
function hgvResolveReference(pageURL: string, ref: string): string {
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
function hgvResolveURL(baseURL: string, ref: string): string {
  let value: string = hgvUnescapeHtml(ref).trim();
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
  const resolved: string = hgvResolveReference(baseURL, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring(7)}`;
  }
  return resolved;
}

/** Go normalizeProviderMediaURL：播放地址规范化，非 m3u8/mp4 视为无效 */
function hgvNormalizeMediaURL(pageURL: string, raw: string): string {
  let value: string = hgvUnescapeHtml(raw).trim();
  value = value.replace(/^[\t\r\n "']+/, '').replace(/[\t\r\n "']+$/, '');
  if (value.length === 0) {
    return '';
  }
  value = value.replace(/\\\//g, '/');
  const resolved: string = hgvResolveURL(pageURL, value);
  const lowered: string = resolved.toLowerCase();
  if (!lowered.includes('.m3u8') && !lowered.includes('.mp4')) {
    return '';
  }
  return resolved;
}

/** Go cleanID：去首尾空白/斜杠/引号 + 截断 query/fragment */
function hgvCleanID(value: string): string {
  let s: string = hgvUnescapeHtml(value).trim();
  s = s.replace(/^[ \/\t\r\n"']+/, '').replace(/[ \/\t\r\n"']+$/, '');
  const cut: number = s.search(/[?#]/);
  if (cut >= 0) {
    s = s.substring(0, cut);
  }
  return s;
}

/** Go huangguoVideoSourceID：href → [series|video/<code>, series|video/<code>] */
function hgvVideoSourceID(href: string): string[] {
  let path: string = hgvUnescapeHtml(href);
  const hash: number = path.indexOf('#');
  if (hash >= 0) {
    path = path.substring(0, hash);
  }
  const question: number = path.indexOf('?');
  if (question >= 0) {
    path = path.substring(0, question);
  }
  const proto: number = path.indexOf('://');
  if (proto >= 0) {
    let rest: string = path.substring(proto + 3);
    const slash: number = rest.indexOf('/');
    path = slash >= 0 ? rest.substring(slash) : '';
  }
  path = path.replace(/^\/+/, '').replace(/\/+$/, '');
  const parts: string[] = path.split('/');
  for (let i: number = 0; i + 1 < parts.length; i++) {
    if (parts[i] === 'series' || parts[i] === 'video') {
      const code: string = hgvCleanID(parts[i + 1]);
      if (code.length === 0) {
        return ['', ''];
      }
      return [`${parts[i]}/${code}`, `${parts[i]}/${code}`];
    }
  }
  return ['', ''];
}

/** Go episodeIndex：从文本提取分集号 */
function hgvEpisodeIndex(text: string, fallback: number): number {
  const match: RegExpExecArray | null = RE_HGV_EPISODE_NUMBER.exec(text);
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

/** Go normalizeViews：播放量文本归一为「N次播放」 */
function hgvNormalizeViews(value: string): string {
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

/** Go releaseStatusFromRemark：更新说明 → ongoing/finished/unknown */
function hgvReleaseStatusFromRemark(remark: string): string {
  if (remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载')) {
    return 'ongoing';
  }
  if (RE_HGV_FINISHED.test(remark) || remark.includes('完结')) {
    return 'finished';
  }
  return 'unknown';
}

/** Go parseDataHLS：页面片段中取 data-hls 播放地址 */
function hgvParseDataHLS(rawHTML: string, pageURL: string): string {
  const match: RegExpExecArray | null = hgvFirstMatch(RE_HGV_DATA_HLS, rawHTML);
  if (match === null || match.length < 2) {
    return '';
  }
  return hgvNormalizeMediaURL(pageURL, match[1]);
}

/** Go extractPageTitle：h1 → og:title → title 标签 */
function hgvExtractPageTitle(body: string): string {
  const h1: RegExpExecArray | null = hgvFirstMatch(RE_HGV_H1_TAG, body);
  if (h1 !== null && h1.length > 1) {
    const t: string = hgvCleanText(h1[1]);
    if (t.length > 0) {
      return t;
    }
  }
  const og: RegExpExecArray | null = hgvFirstMatch(RE_HGV_OG_TITLE, body);
  if (og !== null && og.length > 1) {
    const t: string = hgvUnescapeHtml(og[1]).trim();
    if (t.length > 0) {
      return t;
    }
  }
  const title: RegExpExecArray | null = hgvFirstMatch(RE_HGV_TITLE_TAG, body);
  if (title !== null && title.length > 1) {
    return hgvCleanText(title[1]);
  }
  return '';
}

/** Go extractDescription：description/og:description 元标签 */
function hgvExtractDescription(body: string): string {
  const match: RegExpExecArray | null = hgvFirstMatch(RE_HGV_DESC_META, body);
  if (match === null || match.length < 2) {
    return '';
  }
  return hgvUnescapeHtml(match[1]).trim();
}

/** Go extractTags：hg-tag 元素文本（去重） */
function hgvExtractTags(body: string): string[] {
  const matches: RegExpExecArray[] = hgvAllMatches(RE_HGV_TAG, body);
  const seen: Record<string, boolean> = {};
  const out: string[] = [];
  for (let i: number = 0; i < matches.length; i++) {
    const match: RegExpExecArray = matches[i];
    if (match.length < 2) {
      continue;
    }
    const value: string = hgvCleanText(match[1]);
    if (value.length > 0 && seen[value] !== true) {
      seen[value] = true;
      out.push(value);
    }
  }
  return out;
}

/** og:image 元标签 → 封面地址（Go parseHuangguoSortDetail 的 og:image 回退） */
function hgvOgImage(body: string, pageURL: string): string {
  const metas: RegExpExecArray[] = hgvAllMatches(RE_HGV_META_TAG, body);
  for (let i: number = 0; i < metas.length; i++) {
    const attr: string = hgvExtractAttr(metas[i][0], ['property', 'name']).toLowerCase();
    if (attr !== 'og:image') {
      continue;
    }
    const content: string = hgvExtractAttr(metas[i][0], ['content']);
    if (content.trim().length === 0) {
      continue;
    }
    const address: string = hgvResolveURL(pageURL, content);
    if (hgvIsHttpUrl(address)) {
      return address;
    }
  }
  return '';
}

/** Go huangguoDetailMetadata：详情页 → 剧集元数据（JSON-LD 简化为 og:image） */
function hgvDetailMetadata(body: string, pageURL: string, sourceID: string): QgDrama {
  const title: string = hgvFirstNonEmpty([hgvExtractPageTitle(body), '短剧']);
  const desc: string = hgvExtractDescription(body);
  const tags: string[] = hgvExtractTags(body);
  const cover: string = hgvOgImage(body, pageURL);
  const drama: QgDrama = new QgDrama(`huangguo-video:${sourceID}`, title, '');
  drama.sourceId = 'huangguo-video';
  drama.intro = desc;
  drama.cover = cover;
  drama.tags = tags;
  const metaBlock: string = hgvClassBlock(body.replace(RE_HGV_NON_CONTENT, ''), 'hg-web-detail__meta');
  const meta: string = hgvCleanText(metaBlock);
  drama.viewsText = hgvNormalizeViews(hgvFirstMatchText(RE_HGV_VIEWS, meta));
  let status: string = hgvReleaseStatusFromRemark(meta);
  if (status === 'unknown' && !sourceID.startsWith('video/')) {
    const header: RegExpExecArray | null = hgvFirstMatch(RE_HGV_DETAIL_META, body);
    if (header !== null && header.length > 1) {
      status = hgvReleaseStatusFromRemark(hgvCleanText(header[1]));
    }
  }
  drama.finished = status !== 'ongoing';
  return drama;
}

/** Go parseHuangguoVideoCards：/videos 页卡片 → 剧集列表 */
function hgvParseVideoCards(rawHTML: string, pageURL: string): QgDrama[] {
  let blocks: string[] = [];
  const cards: RegExpExecArray[] = hgvAllMatches(RE_HGV_VIDEO_CARD, rawHTML);
  for (let i: number = 0; i < cards.length; i++) {
    blocks.push(cards[i][0]);
  }
  if (blocks.length === 0) {
    const articles: RegExpExecArray[] = hgvAllMatches(RE_HGV_ANY_ARTICLE, rawHTML);
    for (let i: number = 0; i < articles.length; i++) {
      if (articles[i][0].toLowerCase().includes('video-card')) {
        blocks.push(articles[i][0]);
      }
    }
  }
  const seen: Record<string, boolean> = {};
  const out: QgDrama[] = [];
  for (let b: number = 0; b < blocks.length; b++) {
    const block: string = blocks[b];
    const link: RegExpExecArray | null = hgvFirstMatch(RE_HGV_LINK, block);
    if (link === null || link.length < 3) {
      continue;
    }
    const ids: string[] = hgvVideoSourceID(link[1]);
    const path: string = ids[0];
    const sourceID: string = ids[1];
    if (sourceID.length === 0 || seen[sourceID] === true) {
      continue;
    }
    seen[sourceID] = true;
    const title: string = hgvFirstNonEmpty([hgvExtractAttr(block, ['title', 'alt', 'aria-label']),
      hgvCleanText(block)]);
    const cover: string = hgvResolveURL(pageURL, hgvExtractAttr(block, ['data-src', 'data-original', 'src']));
    const category: string = path.startsWith('series/') ? 'series' : 'video';
    const desc: string = hgvFirstNonEmpty([hgvExtractAttr(block, ['data-description', 'description']),
      hgvExtractDescription(block)]);
    let status: string = '';
    if (category === 'series') {
      const meta: RegExpExecArray | null = hgvFirstMatch(RE_HGV_CARD_META, block);
      if (meta !== null && meta.length > 1) {
        status = hgvReleaseStatusFromRemark(hgvCleanText(meta[1]));
      }
    }
    const drama: QgDrama = new QgDrama(`huangguo-video:${sourceID}`, title, category);
    drama.sourceId = 'huangguo-video';
    drama.intro = desc;
    drama.cover = cover;
    drama.finished = status !== 'ongoing';
    drama.remark = hgvFirstNonEmpty([hgvByClassText(block, 'bg-black/55'), hgvByClassText(block, 'text-gold-dim')]);
    out.push(drama);
  }
  return out;
}

/** Go nextUnusedEpisodeIndex：集号冲突时顺延 */
function hgvNextUnusedIndex(preferred: number, used: Map<number, boolean>): number {
  let p: number = preferred > 0 ? preferred : 1;
  if (used.get(p) !== true) {
    return p;
  }
  let i: number = 1;
  while (used.get(i) === true) {
    i++;
  }
  return i;
}

/** Go parseHuangguoVideoEpisodes：series 页分集卡片 → 分集候选（含 data-hls） */
function hgvParseVideoEpisodes(rawHTML: string, pageURL: string): HgvEpisode[] {
  let blocks: string[] = [];
  const cards: RegExpExecArray[] = hgvAllMatches(RE_HGV_VIDEO_CARD, rawHTML);
  for (let i: number = 0; i < cards.length; i++) {
    blocks.push(cards[i][0]);
  }
  if (blocks.length === 0) {
    const links: RegExpExecArray[] = hgvAllMatches(RE_HGV_LINK, rawHTML);
    for (let i: number = 0; i < links.length; i++) {
      blocks.push(links[i][0]);
    }
  }
  const positions: Map<string, number> = new Map<string, number>();
  const episodes: HgvEpisode[] = [];
  let numbered: boolean = false;
  for (let b: number = 0; b < blocks.length; b++) {
    const block: string = blocks[b];
    const link: RegExpExecArray | null = hgvFirstMatch(RE_HGV_LINK, block);
    if (link === null || link.length < 2) {
      continue;
    }
    const ids: string[] = hgvVideoSourceID(link[1]);
    const path: string = ids[0];
    const key: string = ids[1];
    if (key.length === 0 || !path.startsWith('video/')) {
      continue;
    }
    const fullURL: string = hgvResolveURL(pageURL, link[1]);
    const title: string = hgvFirstNonEmpty([hgvExtractAttr(block, ['title']),
      hgvExtractAttr(block, ['alt']), hgvCleanText(block)]);
    const index: number = hgvEpisodeIndex(hgvCleanText(block), hgvEpisodeIndex(title, 0));
    numbered = numbered || index > 0;
    const episode: HgvEpisode = new HgvEpisode();
    episode.key = key;
    episode.title = title;
    episode.url = fullURL;
    episode.index = index;
    episode.hls = hgvParseDataHLS(block, pageURL);
    const position: number | undefined = positions.get(fullURL);
    if (position !== undefined) {
      if (episodes[position].index <= 0 && index > 0) {
        episodes[position] = episode;
      }
    } else {
      positions.set(fullURL, episodes.length);
      episodes.push(episode);
    }
  }
  const result: HgvEpisode[] = [];
  const used: Map<number, boolean> = new Map<number, boolean>();
  for (let i: number = 0; i < episodes.length; i++) {
    const episode: HgvEpisode = episodes[i];
    if (numbered && episode.index <= 0) {
      continue;
    }
    episode.index = hgvNextUnusedIndex(episode.index, used);
    used.set(episode.index, true);
    result.push(episode);
  }
  result.sort((a: HgvEpisode, b: HgvEpisode): number => {
    if (a.index !== b.index) {
      return a.index - b.index;
    }
    return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0);
  });
  return result;
}

/** 字符数（Unicode 码点，Go len([]rune)） */
function hgvRuneCount(text: string): number {
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

/** href → [path, category 查询参数]（url.Parse 简化） */
function hgvParseHref(href: string): string[] {
  let rest: string = href;
  const hash: number = rest.indexOf('#');
  if (hash >= 0) {
    rest = rest.substring(0, hash);
  }
  const question: number = rest.indexOf('?');
  const left: string = question >= 0 ? rest.substring(0, question) : rest;
  const query: string = question >= 0 ? rest.substring(question + 1) : '';
  let path: string = left;
  const proto: number = path.indexOf('://');
  if (proto >= 0) {
    const after: string = path.substring(proto + 3);
    const slash: number = after.indexOf('/');
    path = slash >= 0 ? after.substring(slash) : '';
  }
  let category: string = '';
  const pairs: string[] = query.split('&');
  for (let i: number = 0; i < pairs.length; i++) {
    const eq: number = pairs[i].indexOf('=');
    if (eq < 0) {
      continue;
    }
    if (pairs[i].substring(0, eq) === 'category') {
      category = decodeURIComponent(pairs[i].substring(eq + 1).replace(/\+/g, ' '));
      break;
    }
  }
  return [path, category];
}

/** Go parseHuangguoVideoCategories：/videos 页锚点 → 分类（category 为正整数、名称 ≤ 24 码点） */
function hgvParseVideoCategories(body: string): QgCategory[] {
  const anchors: RegExpExecArray[] = hgvAllMatches(RE_HGV_ANCHOR, body);
  const seen: Record<string, boolean> = {};
  const out: QgCategory[] = [];
  for (let i: number = 0; i < anchors.length; i++) {
    const match: RegExpExecArray = anchors[i];
    const href: string = hgvUnescapeHtml(hgvExtractAttr(`<a ${match[1] || ''}>`, ['href']));
    const parsed: string[] = hgvParseHref(href);
    const path: string = parsed[0];
    const id: string = parsed[1];
    if (path.length > 0 && path.replace(/\/+$/, '') !== '/videos') {
      continue;
    }
    const name: string = hgvUnescapeHtml((match[2] || '').replace(RE_HGV_ANCHOR_TEXT, '')).trim();
    if (id.length === 0 || !RE_HGV_INT_POS.test(id) || Number(id) <= 0 ||
      seen[id] === true || name.length === 0 || hgvRuneCount(name) > 24) {
      continue;
    }
    seen[id] = true;
    out.push(new QgCategory(id, name));
  }
  return out;
}

/** 已发现的分类缓存（categories() 同步返回，目录请求时填充） */
let hgvCachedCategories: QgCategory[] = [];

/** 从 /videos 页面记忆新发现的分类 */
function hgvRememberCategories(body: string): void {
  const found: QgCategory[] = hgvParseVideoCategories(body);
  if (found.length === 0) {
    return;
  }
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; i < hgvCachedCategories.length; i++) {
    seen[hgvCachedCategories[i].id] = true;
  }
  for (let i: number = 0; i < found.length; i++) {
    if (seen[found[i].id] !== true) {
      seen[found[i].id] = true;
      hgvCachedCategories.push(found[i]);
    }
  }
}

/** 搜索文本规范化（hongguoSearchText 简化版） */
function hgvSearchText(text: string): string {
  const normalized: string = text.normalize('NFKC').toLowerCase()
    .replace(/[\s!-/:-@[-`{-~。，、；：？！“”‘’（）《》〈〉【】〔〕…—·～「」『』]/g, '');
  return normalized;
}

export class HuangguoVideoSource extends QgSource {
  constructor() {
    super('huangguo-video', '黄果视频');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < hgvCachedCategories.length; i++) {
      all.push(hgvCachedCategories[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000) {
      throw new Error('黄果目录页码无效');
    }
    const category: string = categoryId.trim();
    if (category.length > 0 && (!RE_HGV_INT_POS.test(category) || Number(category) <= 0)) {
      throw new Error('黄果分类无效');
    }
    let address: string = `${HGV_BASE}/videos?page=${page}`;
    if (category.length > 0) {
      address += `&category=${encodeURIComponent(category)}`;
    }
    const body: string = await this.hgvFetchText(address, `${HGV_BASE}/`);
    hgvRememberCategories(body);
    const items: QgDrama[] = hgvParseVideoCards(body, address);
    if (items.length === 0 && page === 1) {
      throw new Error('站源暂未返回剧集，请稍后刷新');
    }
    return new QgPageResult(items, items.length >= HGV_PAGE_SIZE);
  }

  /** 无服务端搜索：取目录前 3 页本地过滤 */
  async search(keyword: string, page: number): Promise<QgPageResult> {
    const query: string = keyword.trim();
    if (query.length === 0 || query.length > 256 || page < 1 || page > 1000000) {
      throw new Error('黄果搜索关键词无效');
    }
    if (page > 1) {
      return new QgPageResult([], false);
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    const words: string[] = query.split(/\s+/);
    const normWords: string[] = [];
    for (let w: number = 0; w < words.length; w++) {
      const normalized: string = hgvSearchText(words[w]);
      if (normalized.length > 0) {
        normWords.push(normalized);
      }
    }
    for (let p: number = 1; p <= HGV_SEARCH_PAGES; p++) {
      const address: string = `${HGV_BASE}/videos?page=${p}`;
      const body: string = await this.hgvFetchText(address, `${HGV_BASE}/`);
      if (p === 1) {
        hgvRememberCategories(body);
      }
      const cards: QgDrama[] = hgvParseVideoCards(body, address);
      for (let i: number = 0; i < cards.length; i++) {
        const drama: QgDrama = cards[i];
        if (seen[drama.id] === true) {
          continue;
        }
        seen[drama.id] = true;
        const haystack: string = hgvSearchText(`${drama.title} ${drama.intro} ${drama.tags.join(' ')}`);
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
    }
    return new QgPageResult(items, false);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    let sourceID: string = dramaId.startsWith('huangguo-video:') ?
      dramaId.substring('huangguo-video:'.length) : dramaId;
    sourceID = sourceID.trim().replace(/^\/+/, '').replace(/\/+$/, '');
    if (sourceID.length === 0 || sourceID.length > 512) {
      throw new Error('无效的黄果视频剧集 ID');
    }
    let detailPath: string = sourceID;
    if (!detailPath.startsWith('series/') && !detailPath.startsWith('video/')) {
      detailPath = `series/${sourceID}`;
    }
    const detailURL: string = `${HGV_BASE}/${detailPath}`;
    const body: string = await this.hgvFetchText(detailURL, `${HGV_BASE}/`);
    const drama: QgDrama = hgvDetailMetadata(body, detailURL, sourceID);
    const title: string = drama.title;
    let episodes: HgvEpisode[] = [];
    if (detailPath.startsWith('video/')) {
      const hls: string = hgvParseDataHLS(body, detailURL);
      if (hls.length > 0) {
        episodes = [this.hgvSingleEpisode('1', title, detailURL, hls)];
      }
    } else {
      episodes = hgvParseVideoEpisodes(body, detailURL);
    }
    if (episodes.length === 0) {
      const hls: string = hgvParseDataHLS(body, detailURL);
      if (hls.length > 0) {
        episodes = [this.hgvSingleEpisode('1', title, detailURL, hls)];
      }
    }
    if (episodes.length === 0) {
      throw new Error('该剧暂时没有可播放的分集');
    }
    const out: QgEpisode[] = [];
    for (let i: number = 0; i < episodes.length; i++) {
      const ep: HgvEpisode = episodes[i];
      let index: number = ep.index;
      if (index <= 0) {
        index = out.length + 1;
      }
      let chapterTitle: string = ep.title.trim();
      if (chapterTitle.length === 0) {
        chapterTitle = `第${index}集`;
      }
      let key: string = ep.key;
      if (key.length === 0) {
        key = `${index}`;
      }
      out.push(new QgEpisode(key, chapterTitle, index));
    }
    if (drama.episodeCount < out.length) {
      drama.episodeCount = out.length;
    }
    return new QgDramaDetail(drama, out);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    let sourceID: string = dramaId.startsWith('huangguo-video:') ?
      dramaId.substring('huangguo-video:'.length) : dramaId;
    sourceID = sourceID.trim().replace(/^\/+/, '').replace(/\/+$/, '');
    const episode: string = episodeId.trim();
    if (sourceID.length === 0 || sourceID.length > 512 || episode.length === 0 || episode.length > 512) {
      throw new Error('黄果视频分集无效');
    }
    let pageURL: string;
    if (RE_HGV_EPISODE_ID.test(episode)) {
      pageURL = `${HGV_BASE}/${episode}`;
    } else {
      let detailPath: string = sourceID;
      if (!detailPath.startsWith('series/') && !detailPath.startsWith('video/')) {
        detailPath = `series/${sourceID}`;
      }
      pageURL = `${HGV_BASE}/${detailPath}`;
    }
    const body: string = await this.hgvFetchText(pageURL, `${HGV_BASE}/`);
    const hls: string = hgvParseDataHLS(body, pageURL);
    if (!hgvIsHttpUrl(hls)) {
      throw new Error('huangguo-video 未返回有效播放地址，请刷新章节或确认站点访问权限');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = hls;
    info.referer = pageURL;
    info.headers = { 'User-Agent': HGV_UA, 'Referer': pageURL };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': HGV_UA, 'Referer': `${HGV_BASE}/` };
  }

  /** 构造单集候选（video 页 / data-hls 回退） */
  private hgvSingleEpisode(key: string, title: string, url: string, hls: string): HgvEpisode {
    const episode: HgvEpisode = new HgvEpisode();
    episode.key = key;
    episode.title = title;
    episode.url = url;
    episode.index = 1;
    episode.hls = hls;
    return episode;
  }

  /** Go fetchProviderRequest（单候选）：3 次重试 + 退避，4xx 直接失败 */
  private async hgvFetchText(rawURL: string, referer: string): Promise<string> {
    let lastError: Error | null = null;
    for (let attempt: number = 1; attempt <= 3; attempt++) {
      if (attempt > 1) {
        await hgvSleep(attempt * 1000);
      }
      const headers: Record<string, string> = {
        'User-Agent': HGV_UA,
        'Referer': referer.length > 0 ? referer : rawURL,
        'Accept-Language': 'zh-CN,zh;q=0.9'
      };
      let resp: QgHttpResponse;
      try {
        resp = await QgHttp.request(rawURL, 'GET', headers, null, HGV_TIMEOUT_MS, 0, 30, this.id);
      } catch (error) {
        lastError = error as Error;
        continue;
      }
      if (resp.data.length > HGV_MAX_BODY_BYTES) {
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
    throw lastError !== null ? lastError : new Error('黄果来源请求失败');
  }
}

/** 异步等待（重试退避） */
function hgvSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}
