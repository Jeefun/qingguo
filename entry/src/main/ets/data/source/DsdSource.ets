/**
 * 帝果站源（https://www.dsd.com.se，/index.php/vod 路由的 MacCMS 风格视频站）。
 * 分类/目录/搜索：首页路由锚点取分类（action=type），目录页解析 a.video-item / a.video-surface
 * 卡片，分页容器（el-pagination/pagination/mac_pages）校验当前页并推最大页码；
 * "全部"（空分类）并发 2 路抓取所有分类页后按位交错去重合并，任一分类失败即整页报错。
 * 详情/播放：播放页内嵌 player_xxxx JSON 配置（括号深度扫描提取），
 * 分集 id 为 "line-episode"；播放地址按 encrypt 0/1/2 解码（明文 / PathUnescape /
 * base64+PathUnescape），http 统一升级 https；
 * 无 sign= 的地址经 /addons/vplayer/ 签名页（aaencode 乱码解码 + var vPath 提取）取得直链，
 * 播放 Referer 在签名后切换为 vplayer 页；封面回退规则：同源 /video…/1.jpg → /1000k/index.m3u8。
 * 移植自 guoapp provider_dsd_catalog.go / provider_dsd_playback.go（分类/目录/搜索/详情/播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBase64Decode, qgBuildQuery, qgUtf8Decode } from '../QgBytes';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const DSD_SITE: string = 'https://www.dsd.com.se';
const DSD_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
/** 封面下载 UA（Go 全局 userAgent，app_covers 下载封面时使用） */
const DSD_COVER_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
const DSD_TIMEOUT_MS: number = 12000;
const DSD_MAX_TEXT_BYTES: number = 20 * 1024 * 1024;
const DSD_MAX_PAGE_BYTES: number = 4 * 1024 * 1024;
/** 分类缓存 TTL（Go fetchDSDCategories：1 小时） */
const DSD_CATEGORY_TTL_MS: number = 60 * 60 * 1000;
/** 目录页数限制缓存 TTL（Go dsdPageLimit：15 分钟） */
const DSD_PAGE_LIMIT_TTL_MS: number = 15 * 60 * 1000;
const DSD_VOID_TAGS: string[] = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'];

/** Go webProviderNumericID：非零开头的纯数字 ID */
const DSD_RE_NUMERIC_ID: RegExp = /^[1-9][0-9]{0,17}$/;
/** Go strconv.Atoi 可解析的整数字符串 */
const DSD_RE_INT: RegExp = /^[+-]?[0-9]+$/;
const DSD_RE_HEX2: RegExp = /^[0-9a-fA-F]{2}$/;
const DSD_RE_WHITESPACE: RegExp = /\s/;
const DSD_RE_CLASSIC_URL: RegExp = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//;
const DSD_RE_TAG_NAME_START: RegExp = /^[a-zA-Z]/;
/** Go dsdBackgroundURL：style 内 url(...) 取首个地址 */
const DSD_RE_BACKGROUND_URL: RegExp = /url\(\s*["']?([^"')]+)/i;
/** Go dsdPlayerAssignment：player_xxxx = 赋值点 */
const DSD_RE_PLAYER_ASSIGN: RegExp = /\bplayer_[a-zA-Z0-9_]+\s*=\s*/g;
/** Go dsdVideoDirectory：封面目录 /video…/ */
const DSD_RE_VIDEO_DIR: RegExp = /^\/video[0-9]*\//;
/** Go dsdPosterFilename：封面文件 /1.jpg|jpeg|png|webp */
const DSD_RE_POSTER_FILE: RegExp = /\/1\.(?:jpg|jpeg|png|webp)$/i;
/** Go dsdScriptBlock：script 块原文（vplayer 签名页用） */
const DSD_RE_SCRIPT_BLOCK: RegExp = /<script\b[^>]*>([\s\S]*?)<\/script>/gi;
/** Go dsdVPathAssignment：签名后的 var vPath = "..." */
const DSD_RE_VPATH: RegExp = /\bvar\s+vPath\s*=\s*["']([^"']+)["']/;
/** 标准 base64（字母表 + 正确 padding） */
const DSD_RE_BASE64_STD: RegExp = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
/** 无 padding base64 字母表（RawStdEncoding，长度 %4 != 1） */
const DSD_RE_BASE64_CHARS: RegExp = /^[A-Za-z0-9+/]+$/;
/** aaencode 编码特征（marker / 结尾标记 / token 分隔） */
const DSD_AA_MARKER: string = "(ﾟДﾟ) ['_'] ( (ﾟДﾟ) ['_']";
const DSD_AA_TAIL: string = '+ (ﾟДﾟ)[ﾟoﾟ]';
const DSD_AA_SEP: string = '(ﾟДﾟ)[ﾟεﾟ]+';

/** HTML 节点（dsdParseHtml 产物；文本节点 tag 为 '#text'） */
class DsdNode {
  tag: string = '';
  attrs: Record<string, string> = {};
  text: string = '';
  children: DsdNode[] = [];
  parent: DsdNode | null = null;
}

/** URL 拆解结果（scheme://host + path + query） */
class DsdUrlParts {
  scheme: string = '';
  host: string = '';
  path: string = '';
  query: string = '';
}

/** Go dsdRouteParameters 解析结果：动作 + 路由参数 */
class DsdRoute {
  action: string = '';
  params: Record<string, string> = {};
}

/** parseDSDPlayer 结果：player_xxxx 配置（未命中为空对象） */
class DsdPlayerResult {
  player: Record<string, Object> = {};
  found: boolean = false;
}

/** dsdPlayerIdentity 结果：线路 + 分集 */
class DsdIdentity {
  line: number = 1;
  episode: number = 1;
}

/** 详情分集条目（dsdChapter） */
class DsdEpisodeEntry {
  line: number = 1;
  episode: number = 1;
  title: string = '';

  constructor(line: number, episode: number, title: string) {
    this.line = line;
    this.episode = episode;
    this.title = title;
  }
}

/** 单个目录页抓取结果（fetchDSDPage） */
class DsdFetchResult {
  items: QgDrama[] = [];
  more: boolean = false;

  constructor(items: QgDrama[], more: boolean) {
    this.items = items;
    this.more = more;
  }
}

/** "全部"合并时单分类的抓取结局 */
class DsdFetchOutcome {
  items: QgDrama[] = [];
  more: boolean = false;
  error: Error | null = null;
}

/** signDSDMedia 结果：签名后地址 + 是否经 vplayer 签名 */
class DsdSignedResult {
  address: string = '';
  byVplayer: boolean = false;

  constructor(address: string, byVplayer: boolean) {
    this.address = address;
    this.byVplayer = byVplayer;
  }
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function dsdDecodeNumericEntities(text: string): string {
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
function dsdUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = dsdDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go truncate：超长截断加省略号（按码点计数） */
function dsdTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go firstNonEmpty：首个非空白串（返回 trim 后的值） */
function dsdFirstNonEmpty(values: string[]): string {
  for (let i: number = 0; i < values.length; i++) {
    const trimmed: string = values[i].trim();
    if (trimmed !== '') {
      return trimmed;
    }
  }
  return '';
}

/** 追加文本节点（script/style 内容为 raw text，不做实体解码） */
function dsdAppendText(parent: DsdNode, text: string, decodeEntities: boolean): void {
  if (text.length === 0) {
    return;
  }
  const node: DsdNode = new DsdNode();
  node.tag = '#text';
  node.text = decodeEntities ? dsdUnescapeHtml(text) : text;
  node.parent = parent;
  parent.children.push(node);
}

/** 标签内定位 '>'（跳过引号内的尖括号） */
function dsdTagEnd(body: string, start: number): number {
  let quote: string = '';
  for (let i: number = start + 1; i < body.length; i++) {
    const ch: string = body.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === '\'') {
      quote = ch;
      continue;
    }
    if (ch === '>') {
      return i;
    }
  }
  return -1;
}

/** 解析标签名与属性（属性值做实体解码） */
function dsdParseTag(raw: string): DsdNode {
  const node: DsdNode = new DsdNode();
  let i: number = 0;
  while (i < raw.length && DSD_RE_WHITESPACE.test(raw.charAt(i))) {
    i++;
  }
  const nameStart: number = i;
  while (i < raw.length && !DSD_RE_WHITESPACE.test(raw.charAt(i))) {
    i++;
  }
  node.tag = raw.substring(nameStart, i).toLowerCase();
  while (i < raw.length) {
    while (i < raw.length && DSD_RE_WHITESPACE.test(raw.charAt(i))) {
      i++;
    }
    if (i >= raw.length) {
      break;
    }
    const attrStart: number = i;
    while (i < raw.length && !DSD_RE_WHITESPACE.test(raw.charAt(i)) && raw.charAt(i) !== '=') {
      i++;
    }
    const attrName: string = raw.substring(attrStart, i).toLowerCase();
    while (i < raw.length && DSD_RE_WHITESPACE.test(raw.charAt(i))) {
      i++;
    }
    let attrValue: string = '';
    if (i < raw.length && raw.charAt(i) === '=') {
      i++;
      while (i < raw.length && DSD_RE_WHITESPACE.test(raw.charAt(i))) {
        i++;
      }
      if (i < raw.length && (raw.charAt(i) === '"' || raw.charAt(i) === '\'')) {
        const quote: string = raw.charAt(i);
        i++;
        const valueStart: number = i;
        while (i < raw.length && raw.charAt(i) !== quote) {
          i++;
        }
        attrValue = raw.substring(valueStart, i);
        if (i < raw.length) {
          i++;
        }
      } else {
        const valueStart: number = i;
        while (i < raw.length && !DSD_RE_WHITESPACE.test(raw.charAt(i))) {
          i++;
        }
        attrValue = raw.substring(valueStart, i);
      }
    }
    if (attrName.length > 0) {
      node.attrs[attrName] = dsdUnescapeHtml(attrValue);
    }
  }
  return node;
}

/** 轻量 HTML 树解析（Go x/net/html 的替代）：文档序 DFS 构建 */
function dsdParseHtml(body: string): DsdNode {
  const root: DsdNode = new DsdNode();
  root.tag = '#root';
  const stack: DsdNode[] = [root];
  const lower: string = body.toLowerCase();
  let i: number = 0;
  while (i < body.length) {
    const top: DsdNode = stack[stack.length - 1];
    // script/style 为 raw text 元素：内容原样保留直到闭合标签
    if (top.tag === 'script' || top.tag === 'style') {
      const closeIdx: number = lower.indexOf(`</${top.tag}`, i);
      if (closeIdx < 0) {
        dsdAppendText(top, body.substring(i), false);
        break;
      }
      if (closeIdx > i) {
        dsdAppendText(top, body.substring(i, closeIdx), false);
      }
      const gt: number = body.indexOf('>', closeIdx);
      i = gt < 0 ? body.length : gt + 1;
      stack.pop();
      continue;
    }
    const lt: number = body.indexOf('<', i);
    if (lt < 0) {
      dsdAppendText(top, body.substring(i), true);
      break;
    }
    if (lt > i) {
      dsdAppendText(top, body.substring(i, lt), true);
    }
    if (body.startsWith('<!--', lt)) {
      const end: number = body.indexOf('-->', lt + 4);
      i = end < 0 ? body.length : end + 3;
      continue;
    }
    const nextChar: string = lt + 1 < body.length ? body.charAt(lt + 1) : '';
    if (nextChar === '!' || nextChar === '?') {
      const end: number = body.indexOf('>', lt + 2);
      i = end < 0 ? body.length : end + 1;
      continue;
    }
    if (nextChar === '/') {
      const end: number = body.indexOf('>', lt + 2);
      const name: string = lower.substring(lt + 2, end < 0 ? body.length : end).trim();
      for (let s: number = stack.length - 1; s > 0; s--) {
        if (stack[s].tag === name) {
          stack.splice(s);
          break;
        }
      }
      i = end < 0 ? body.length : end + 1;
      continue;
    }
    if (!DSD_RE_TAG_NAME_START.test(nextChar)) {
      dsdAppendText(top, '<', true);
      i = lt + 1;
      continue;
    }
    const end: number = dsdTagEnd(body, lt);
    const rawTag: string = body.substring(lt + 1, end < 0 ? body.length : end);
    const selfClose: boolean = rawTag.endsWith('/');
    const cleaned: string = selfClose ? rawTag.substring(0, rawTag.length - 1) : rawTag;
    const node: DsdNode = dsdParseTag(cleaned);
    const parent: DsdNode = stack[stack.length - 1];
    node.parent = parent;
    parent.children.push(node);
    if (!selfClose && !DSD_VOID_TAGS.includes(node.tag)) {
      stack.push(node);
    }
    i = end < 0 ? body.length : end + 1;
  }
  return root;
}

/** Go providerHTMLAttr：取属性值 */
function dsdAttr(node: DsdNode | null, name: string): string {
  if (node === null) {
    return '';
  }
  const value: string | undefined = node.attrs[name];
  return value === undefined ? '' : value;
}

/** Go providerHTMLClass：class 列表包含指定类名 */
function dsdHasClass(node: DsdNode, name: string): boolean {
  const value: string = dsdAttr(node, 'class');
  if (value.trim().length === 0) {
    return false;
  }
  return value.split(/\s+/).includes(name);
}

/** Go providerHTMLNodes：文档序遍历 root 及全部后代，收集满足条件的节点 */
function dsdCollect(root: DsdNode | null, want: (node: DsdNode) => boolean): DsdNode[] {
  const found: DsdNode[] = [];
  if (root === null) {
    return found;
  }
  const pending: DsdNode[] = [root];
  while (pending.length > 0) {
    const node: DsdNode = pending[pending.length - 1];
    pending.pop();
    if (want(node)) {
      found.push(node);
    }
    for (let c: number = node.children.length - 1; c >= 0; c--) {
      pending.push(node.children[c]);
    }
  }
  return found;
}

/** Go providerHTMLFirstClass（可变参数）：按名字顺序取第一个含指定类名的节点 */
function dsdFirstClass(root: DsdNode | null, names: string[]): DsdNode | null {
  for (let n: number = 0; n < names.length; n++) {
    const name: string = names[n];
    const matches: DsdNode[] = dsdCollect(root, (node: DsdNode): boolean => dsdHasClass(node, name));
    if (matches.length > 0) {
      return matches[0];
    }
  }
  return null;
}

/** Go providerHTMLText：后代文本拼接（跳过 script/style），空白折叠 */
function dsdText(root: DsdNode | null): string {
  if (root === null) {
    return '';
  }
  let out: string = '';
  const pending: DsdNode[] = [root];
  while (pending.length > 0) {
    const node: DsdNode = pending[pending.length - 1];
    pending.pop();
    if (node.tag === '#text') {
      if (node.parent !== null && (node.parent.tag === 'script' || node.parent.tag === 'style')) {
        continue;
      }
      out += node.text;
      out += ' ';
      continue;
    }
    for (let c: number = node.children.length - 1; c >= 0; c--) {
      pending.push(node.children[c]);
    }
  }
  return out.trim().split(/\s+/).join(' ');
}

/** URL 拆解：scheme://host + path + query（非绝对地址返回 null） */
function dsdUrlParts(raw: string): DsdUrlParts | null {
  const value: string = raw.trim();
  const match: RegExpMatchArray | null = value.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^#]*)/);
  if (match === null) {
    return null;
  }
  const parts: DsdUrlParts = new DsdUrlParts();
  parts.scheme = match[1].toLowerCase();
  parts.host = match[2];
  if (parts.host.length === 0) {
    return null;
  }
  const rest: string = match[3];
  const qIdx: number = rest.indexOf('?');
  if (qIdx >= 0) {
    parts.path = rest.substring(0, qIdx);
    parts.query = rest.substring(qIdx + 1);
  } else {
    parts.path = rest;
  }
  return parts;
}

/** url.ResolveReference 简化版：相对地址基于 page 补全（含 ./ 与 ../ 段处理） */
function dsdResolveReference(page: DsdUrlParts, ref: string): string {
  const origin: string = `${page.scheme}://${page.host}`;
  if (DSD_RE_CLASSIC_URL.test(ref)) {
    return ref;
  }
  if (ref.startsWith('//')) {
    return `${page.scheme}:${ref}`;
  }
  if (ref.startsWith('/')) {
    return `${origin}${ref}`;
  }
  if (ref.startsWith('?')) {
    return `${origin}${page.path}${ref}`;
  }
  if (ref.startsWith('#') || ref.length === 0) {
    return `${origin}${page.path}${page.query.length > 0 ? `?${page.query}` : ''}`;
  }
  let dir: string = page.path.substring(0, page.path.lastIndexOf('/') + 1);
  if (dir.length === 0) {
    dir = '/';
  }
  const combined: string = `${dir}${ref}`;
  const segments: string[] = combined.split('/');
  const kept: string[] = [];
  for (let i: number = 0; i < segments.length; i++) {
    const seg: string = segments[i];
    if (seg === '.') {
      continue;
    }
    if (seg === '..') {
      if (kept.length > 1) {
        kept.pop();
      }
      continue;
    }
    kept.push(seg);
  }
  const resolved: string = kept.join('/');
  return `${origin}${resolved.startsWith('/') ? resolved : `/${resolved}`}`;
}

/** 查询串 unescape（%XX 与 +，非法转义返回 null） */
function dsdQueryUnescape(text: string): string | null {
  let out: string = '';
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '+') {
      out += ' ';
      i++;
      continue;
    }
    if (ch === '%') {
      const hex: string = text.substring(i + 1, i + 3);
      if (!DSD_RE_HEX2.test(hex)) {
        return null;
      }
      out += String.fromCharCode(parseInt(hex, 16));
      i += 3;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

/** 解析查询串为 Record（首个值；非法转义的键值对跳过） */
function dsdParseQuery(query: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (query.length === 0) {
    return out;
  }
  const pairs: string[] = query.split('&');
  for (let i: number = 0; i < pairs.length; i++) {
    const pair: string = pairs[i];
    if (pair.length === 0) {
      continue;
    }
    const eq: number = pair.indexOf('=');
    const rawKey: string = eq < 0 ? pair : pair.substring(0, eq);
    const rawValue: string = eq < 0 ? '' : pair.substring(eq + 1);
    const key: string | null = dsdQueryUnescape(rawKey);
    if (key === null || key.length === 0 || out[key] !== undefined) {
      continue;
    }
    const value: string | null = dsdQueryUnescape(rawValue);
    out[key] = value === null ? '' : value;
  }
  return out;
}

/**
 * Go dsdRouteParameters：解析 /index.php/vod/{action}/k/v...html 路由。
 * 要求与 pageURL 同源且无 userinfo；action ∈ type/show/search/play/detail；
 * 路径按 k/v 成对取参，查询参数补充路径未提供的键。
 */
function dsdRouteParameters(pageURL: string, reference: string): DsdRoute | null {
  if (reference.length === 0) {
    return null;
  }
  const page: DsdUrlParts | null = dsdUrlParts(pageURL);
  if (page === null) {
    return null;
  }
  const absolute: string = dsdResolveReference(page, reference);
  const address: DsdUrlParts | null = dsdUrlParts(absolute);
  if (address === null) {
    return null;
  }
  if (address.host.includes('@')) {
    return null;
  }
  if (address.scheme !== page.scheme || address.host !== page.host) {
    return null;
  }
  let path: string = address.path;
  if (path.startsWith('/index.php')) {
    path = path.substring('/index.php'.length);
  }
  let trimmed: string = path;
  if (trimmed.endsWith('.html')) {
    trimmed = trimmed.substring(0, trimmed.length - '.html'.length);
  }
  trimmed = trimmed.replace(/^\/+/, '').replace(/\/+$/, '');
  const parts: string[] = trimmed.length === 0 ? [] : trimmed.split('/');
  if (parts.length < 2 || parts[0] !== 'vod' || parts.length % 2 !== 0) {
    return null;
  }
  const action: string = parts[1];
  if (action !== 'type' && action !== 'show' && action !== 'search' &&
    action !== 'play' && action !== 'detail') {
    return null;
  }
  const route: DsdRoute = new DsdRoute();
  route.action = action;
  for (let i: number = 2; i + 1 < parts.length; i += 2) {
    route.params[parts[i]] = parts[i + 1];
  }
  const query: Record<string, string> = dsdParseQuery(address.query);
  const keys: string[] = Object.keys(query);
  for (let i: number = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const existing: string | undefined = route.params[key];
    if (existing === undefined || existing.length === 0) {
      route.params[key] = query[key];
    }
  }
  return route;
}

/** http/https、主机非空、无 userinfo（isProviderHTTPMediaURL / validNativeCoverURL） */
function dsdIsHttpUrl(raw: string): boolean {
  const parts: DsdUrlParts | null = dsdUrlParts(raw.trim());
  if (parts === null) {
    return false;
  }
  if (parts.scheme !== 'http' && parts.scheme !== 'https') {
    return false;
  }
  return parts.host.length > 0 && !parts.host.includes('@');
}

/** Go providerMediaOrigin：scheme://host（默认端口已在拆解时保留原文） */
function dsdOriginOf(url: string): string {
  const parts: DsdUrlParts | null = dsdUrlParts(url.trim());
  if (parts === null) {
    return '';
  }
  return `${parts.scheme}://${parts.host}`;
}

/** URL 路径小写（后缀 .m3u8/.mp4 校验用） */
function dsdLowerPath(url: string): string {
  const parts: DsdUrlParts | null = dsdUrlParts(url.trim());
  if (parts === null) {
    return url.toLowerCase();
  }
  return parts.path.toLowerCase();
}

/** Go mapString：按序取首个非空字符串字段（trim） */
function dsdMapString(row: Record<string, Object> | null, keys: string[]): string {
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

/** Go webProviderInteger（nativeText + Atoi 语义）：解析失败或越界返回 -1 */
function dsdInteger(value: Object | undefined | null, maximum: number): number {
  let text: string = '';
  if (typeof value === 'string') {
    text = value.trim();
  } else if (typeof value === 'number') {
    text = `${Math.trunc(value)}`;
  } else {
    return -1;
  }
  if (!DSD_RE_INT.test(text)) {
    return -1;
  }
  const number: number = Number(text);
  if (number < 0 || number > maximum) {
    return -1;
  }
  return number;
}

/** 封面地址解析（字符串分支）：相对补全 + 合法性校验 */
function dsdCoverSrc(raw: string, pageURL: string): string {
  const text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  const page: DsdUrlParts | null = dsdUrlParts(pageURL);
  const resolved: string = page !== null ? dsdResolveReference(page, text) : text;
  return dsdIsHttpUrl(resolved) ? resolved : '';
}

/** Go providerCoverAddress：数组/对象/字符串取封面并相对补全 */
function dsdCoverAddress(value: Object | undefined | null, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = dsdCoverAddress(items[i], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
    return '';
  }
  if (typeof value === 'string') {
    return dsdCoverSrc(value, pageURL);
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = dsdCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go parseDSDCategories：首页路由锚点中 action=type 的分类（1..32 个） */
function dsdParseCategories(root: DsdNode, pageURL: string): QgCategory[] {
  const categories: QgCategory[] = [];
  const seen: Record<string, boolean> = {};
  const anchors: DsdNode[] = dsdCollect(root, (node: DsdNode): boolean => node.tag === 'a');
  for (let i: number = 0; i < anchors.length; i++) {
    const route: DsdRoute | null = dsdRouteParameters(pageURL, dsdAttr(anchors[i], 'href'));
    if (route === null || route.action !== 'type') {
      continue;
    }
    const id: string = route.params['id'] ?? '';
    const name: string = dsdText(anchors[i]);
    if (!DSD_RE_NUMERIC_ID.test(id) || seen[id] === true || name === '' ||
      Array.from(name).length > 48) {
      continue;
    }
    seen[id] = true;
    categories.push(new QgCategory(id, name));
  }
  if (categories.length === 0 || categories.length > 32) {
    throw new Error('帝果未返回有效的内容分类');
  }
  return categories;
}

/** Go dsdCardCover：img[data-src|data-original] → style url() 背景 → 受限 img[src] */
function dsdCardCover(card: DsdNode | null, pageURL: string): string {
  if (card === null) {
    return '';
  }
  const images: DsdNode[] = dsdCollect(card, (node: DsdNode): boolean => node.tag === 'img');
  for (let i: number = 0; i < images.length; i++) {
    const attrNames: string[] = ['data-src', 'data-original'];
    for (let j: number = 0; j < attrNames.length; j++) {
      const address: string = dsdCoverAddress(dsdAttr(images[i], attrNames[j]), pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  const nodes: DsdNode[] = dsdCollect(card, (node: DsdNode): boolean =>
    node === card || dsdHasClass(node, 'img-bg') || dsdHasClass(node, 'surface-img') ||
    dsdHasClass(node, 'openVip') || dsdHasClass(node, 'video-before-ad'));
  for (let i: number = 0; i < nodes.length; i++) {
    const match: RegExpExecArray | null = DSD_RE_BACKGROUND_URL.exec(dsdAttr(nodes[i], 'style'));
    if (match !== null && match.length > 1) {
      const address: string = dsdCoverAddress(match[1].trim(), pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  for (let i: number = 0; i < images.length; i++) {
    const raw: string = dsdAttr(images[i], 'src');
    if (raw.startsWith('/video') || raw.includes('/upload')) {
      const address: string = dsdCoverAddress(raw, pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go parseDSDCards：a.video-item / a.video-surface 卡片 → QgDrama 列表 */
function dsdParseCards(root: DsdNode, pageURL: string, category: string): QgDrama[] {
  const items: QgDrama[] = [];
  const seen: Record<string, boolean> = {};
  const cards: DsdNode[] = dsdCollect(root, (node: DsdNode): boolean =>
    node.tag === 'a' && (dsdHasClass(node, 'video-item') || dsdHasClass(node, 'video-surface')));
  for (let i: number = 0; i < cards.length; i++) {
    const card: DsdNode = cards[i];
    const route: DsdRoute | null = dsdRouteParameters(pageURL, dsdAttr(card, 'href'));
    if (route === null) {
      continue;
    }
    const id: string = route.params['id'] ?? '';
    if ((route.action !== 'play' && route.action !== 'detail') ||
      !DSD_RE_NUMERIC_ID.test(id) || seen[id] === true) {
      continue;
    }
    const titleNode: DsdNode | null = dsdFirstClass(card,
      ['video-desc', 'surface-title', 'video-title', 'title']);
    let title: string = dsdFirstNonEmpty([dsdText(titleNode), dsdAttr(card, 'title')]);
    if (title === '') {
      const images: DsdNode[] = dsdCollect(card, (node: DsdNode): boolean => node.tag === 'img');
      for (let j: number = 0; j < images.length; j++) {
        const alt: string = dsdAttr(images[j], 'alt').trim();
        if (alt !== '') {
          title = alt;
          break;
        }
      }
    }
    if (title === '') {
      throw new Error('帝果目录缺少视频名称');
    }
    seen[id] = true;
    const cover: string = dsdCardCover(card, pageURL);
    const viewsNode: DsdNode | null = dsdFirstClass(card, ['video-item-tag-hits', 'counts']);
    let views: string = dsdText(viewsNode);
    if (views.endsWith('次')) {
      views = views.substring(0, views.length - 1);
    }
    const drama: QgDrama = new QgDrama(`dsd:${id}`, dsdTruncate(title, 1024),
      category !== '' ? category : '视频');
    drama.sourceId = 'dsd';
    drama.cover = cover;
    drama.viewsText = views;
    if (dsdFirstClass(card, ['video-item-tag-is-vip', 'vip-tag']) !== null) {
      drama.remark = 'VIP';
    }
    items.push(drama);
    if (items.length > 500) {
      throw new Error('帝果目录条目过多');
    }
  }
  return items;
}

/** Go dsdPagination：分页容器校验当前页并取路由锚点最大页码 */
function dsdPagination(root: DsdNode, pageURL: string, category: string,
  query: string, page: number): number {
  const pagination: DsdNode | null = dsdFirstClass(root, ['el-pagination', 'pagination', 'mac_pages']);
  if (pagination === null) {
    if (page !== 1) {
      throw new Error('帝果未返回请求页码，请重试');
    }
    return 1;
  }
  let activePage: number = 0;
  const actives: DsdNode[] = dsdCollect(pagination, (node: DsdNode): boolean =>
    (dsdHasClass(node, 'active') && dsdHasClass(node, 'number')) || dsdHasClass(node, 'page-current'));
  for (let i: number = 0; i < actives.length; i++) {
    const current: number = dsdInteger(dsdText(actives[i]), 1000000);
    if (current >= 0) {
      activePage = current;
      break;
    }
  }
  if (activePage !== page) {
    throw new Error('帝果返回的页码与请求不符');
  }
  let pages: number = page;
  const anchors: DsdNode[] = dsdCollect(pagination, (node: DsdNode): boolean => node.tag === 'a');
  for (let i: number = 0; i < anchors.length; i++) {
    const route: DsdRoute | null = dsdRouteParameters(pageURL, dsdAttr(anchors[i], 'href'));
    if (route === null) {
      continue;
    }
    if (query !== '') {
      if (route.action !== 'search' || (route.params['wd'] ?? '') !== query) {
        continue;
      }
    } else {
      if ((route.action !== 'type' && route.action !== 'show') ||
        (route.params['id'] ?? '') !== category) {
        continue;
      }
    }
    const value: number = dsdInteger(route.params['page'], 1000000);
    if (value >= 0 && value > pages) {
      pages = value;
    }
  }
  return pages;
}

/** Go dsdEpisodePage：播放/详情页地址 */
function dsdEpisodePage(site: string, sourceID: string, line: number, episode: number): string {
  return `${site}/index.php/vod/play/id/${sourceID}/sid/${line}/nid/${episode}.html`;
}

/** 括号深度扫描提取首个 JSON 对象（Go json.Decoder 单值语义，非对象返回 null） */
function dsdExtractJsonMap(text: string): Record<string, Object> | null {
  let start: number = 0;
  while (start < text.length && ' \t\r\n'.includes(text.charAt(start))) {
    start++;
  }
  if (start >= text.length || text.charAt(start) !== '{') {
    return null;
  }
  let depth: number = 0;
  let inString: boolean = false;
  let escaped: boolean = false;
  let end: number = -1;
  for (let i: number = start; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === '{') {
      depth++;
      continue;
    }
    if (ch === '}') {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) {
    return null;
  }
  const parsed: Object | null = QgJson.parse(text.substring(start, end + 1));
  if (parsed === null) {
    return null;
  }
  return QgJson.obj(parsed);
}

/** Go parseDSDPlayer：script 内 player_xxxx = {...} 提取（每 script 最多 8 处，解码失败报错） */
function dsdParsePlayer(root: DsdNode): DsdPlayerResult {
  const result: DsdPlayerResult = new DsdPlayerResult();
  const scripts: DsdNode[] = dsdCollect(root, (node: DsdNode): boolean => node.tag === 'script');
  for (let i: number = 0; i < scripts.length; i++) {
    if (scripts[i].children.length === 0) {
      continue;
    }
    const body: string = scripts[i].children[0].text;
    DSD_RE_PLAYER_ASSIGN.lastIndex = 0;
    let match: RegExpExecArray | null = DSD_RE_PLAYER_ASSIGN.exec(body);
    let matched: number = 0;
    while (match !== null && matched < 8) {
      matched++;
      const player: Record<string, Object> | null =
        dsdExtractJsonMap(body.substring(match.index + match[0].length));
      if (player === null) {
        throw new Error('帝果播放器参数格式无效');
      }
      const hasId: boolean = player['id'] !== undefined && player['id'] !== null;
      const hasUrl: boolean = player['url'] !== undefined && player['url'] !== null;
      if (hasId && hasUrl) {
        result.player = player;
        result.found = true;
        return result;
      }
      match = DSD_RE_PLAYER_ASSIGN.exec(body);
    }
  }
  return result;
}

/** Go dsdPlayerIdentity：校验 player 的 id/sid/nid，返回线路与分集 */
function dsdPlayerIdentity(player: Record<string, Object>, sourceID: string): DsdIdentity {
  const line: number = dsdInteger(player['sid'], 1000000);
  const episode: number = dsdInteger(player['nid'], 1000000);
  if (dsdMapString(player, ['id']) !== sourceID || line < 1 || episode < 1) {
    throw new Error('帝果播放器与请求视频不符');
  }
  const identity: DsdIdentity = new DsdIdentity();
  identity.line = line;
  identity.episode = episode;
  return identity;
}

/** Go dsdDetailIdentity：播放器身份校验或 .video-info 内 data-id + btn-favs 校验 */
function dsdDetailIdentity(root: DsdNode, sourceID: string,
  player: Record<string, Object>, found: boolean): void {
  if (found) {
    dsdPlayerIdentity(player, sourceID);
    return;
  }
  const info: DsdNode | null = dsdFirstClass(root, ['video-info']);
  if (info !== null) {
    const nodes: DsdNode[] = dsdCollect(info,
      (node: DsdNode): boolean => dsdAttr(node, 'data-id') === sourceID);
    for (let i: number = 0; i < nodes.length; i++) {
      if (dsdHasClass(nodes[i], 'btn-favs')) {
        return;
      }
    }
  }
  throw new Error('帝果未返回所请求视频的详情');
}

/** 详情标签收拢（Go parseDSDDetail 的 addTag 闭包）：trim、≤48 码点、≤32 个、去重 */
function dsdAddTag(tags: string[], seen: Record<string, boolean>, tag: string): void {
  const trimmed: string = tag.trim();
  if (trimmed === '' || Array.from(trimmed).length > 48 || tags.length >= 32 ||
    seen[trimmed] === true) {
    return;
  }
  seen[trimmed] = true;
  tags.push(trimmed);
}

/** 详情分集收集（Go parseDSDDetail 的 addEpisode 闭包） */
function dsdAddEpisode(entries: DsdEpisodeEntry[], seen: Record<string, boolean>,
  pageURL: string, reference: string, title: string, sourceID: string, line: number): void {
  const route: DsdRoute | null = dsdRouteParameters(pageURL, reference);
  if (route === null || route.action !== 'play') {
    return;
  }
  const id: string = route.params['id'] ?? '';
  const sid: number = dsdInteger(route.params['sid'], 1000000);
  const episode: number = dsdInteger(route.params['nid'], 1000000);
  if (id !== sourceID || sid < 1 || sid !== line || episode < 1 || seen[`${episode}`] === true) {
    return;
  }
  seen[`${episode}`] = true;
  entries.push(new DsdEpisodeEntry(line, episode, title));
}

/** Go parseDSDDetail：播放页 → 剧集详情 + 分集列表 */
function dsdParseDetail(root: DsdNode, pageURL: string, sourceID: string): QgDramaDetail {
  const pr: DsdPlayerResult = dsdParsePlayer(root);
  dsdDetailIdentity(root, sourceID, pr.player, pr.found);
  let line: number = 1;
  let current: number = 1;
  if (pr.found) {
    const identity: DsdIdentity = dsdPlayerIdentity(pr.player, sourceID);
    line = identity.line;
    current = identity.episode;
  }
  const info: DsdNode | null = dsdFirstClass(root, ['video-info']);
  const box: DsdNode | null = dsdFirstClass(root, ['video-box']);
  const data: Record<string, Object> | null = QgJson.obj(pr.player['vod_data']);
  let title: string = dsdMapString(data, ['vod_name']);
  if (title === '') {
    const headings: DsdNode[] = info === null ? [] : dsdCollect(info, (node: DsdNode): boolean =>
      node.tag === 'h1' || node.tag === 'h2' || node.tag === 'h3');
    for (let i: number = 0; i < headings.length; i++) {
      const text: string = dsdText(headings[i]);
      if (text !== '') {
        title = text;
        break;
      }
    }
  }
  if (title === '') {
    throw new Error('帝果详情缺少视频名称');
  }
  const cover: string = dsdFirstNonEmpty([
    dsdCoverAddress(pr.player['poster'], pageURL),
    dsdCardCover(box, pageURL)
  ]);
  const descBlock: DsdNode | null = info === null ? null : dsdFirstClass(info, ['desc']);
  const description: string = dsdTruncate(dsdText(descBlock), 12000);
  const vip: boolean = box !== null && dsdFirstClass(box, ['noVip', 'openVip']) !== null;
  const drama: QgDrama = new QgDrama(`dsd:${sourceID}`, dsdTruncate(title, 1024), '');
  drama.sourceId = 'dsd';
  drama.intro = description;
  drama.cover = cover;
  drama.remark = vip ? 'VIP' : '';
  const tags: string[] = [];
  const seenTags: Record<string, boolean> = {};
  const vodClass: string = dsdMapString(data, ['vod_class']);
  const classParts: string[] = vodClass.split(',');
  for (let i: number = 0; i < classParts.length; i++) {
    dsdAddTag(tags, seenTags, classParts[i]);
  }
  const labelsBlock: DsdNode | null = info === null ? null : dsdFirstClass(info, ['labels']);
  if (labelsBlock !== null) {
    const labelAnchors: DsdNode[] = dsdCollect(labelsBlock, (node: DsdNode): boolean => node.tag === 'a');
    for (let i: number = 0; i < labelAnchors.length; i++) {
      dsdAddTag(tags, seenTags, dsdText(labelAnchors[i]));
    }
  }
  drama.tags = tags;
  // 分集：当前集 + 页内 play 路由锚点 + link_pre/link_next
  const entries: DsdEpisodeEntry[] = [];
  entries.push(new DsdEpisodeEntry(line, current, ''));
  const seen: Record<string, boolean> = {};
  seen[`${current}`] = true;
  const anchors: DsdNode[] = dsdCollect(root, (node: DsdNode): boolean => node.tag === 'a');
  for (let i: number = 0; i < anchors.length; i++) {
    dsdAddEpisode(entries, seen, pageURL, dsdAttr(anchors[i], 'href'),
      dsdText(anchors[i]), sourceID, line);
  }
  dsdAddEpisode(entries, seen, pageURL, dsdMapString(pr.player, ['link_pre']), '', sourceID, line);
  dsdAddEpisode(entries, seen, pageURL, dsdMapString(pr.player, ['link_next']), '', sourceID, line);
  if (entries.length > 10000) {
    throw new Error('帝果分集目录过大');
  }
  entries.sort((a: DsdEpisodeEntry, b: DsdEpisodeEntry): number => a.episode - b.episode);
  if (entries.length === 1) {
    entries[0].title = '正片';
  }
  const episodes: QgEpisode[] = [];
  for (let i: number = 0; i < entries.length; i++) {
    const entry: DsdEpisodeEntry = entries[i];
    const fallback: string = `第 ${entry.episode} 集`;
    episodes.push(new QgEpisode(`${entry.line}-${entry.episode}`,
      entry.title.length > 0 ? dsdTruncate(entry.title, 256) : fallback, entry.episode));
  }
  drama.episodeCount = episodes.length;
  return new QgDramaDetail(drama, episodes);
}

/** Go url.PathUnescape（UTF-8 感知，非法转义抛错） */
function dsdPathUnescape(text: string): string {
  let out: string = '';
  let bytes: number[] = [];
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '%') {
      const hex: string = text.substring(i + 1, i + 3);
      if (!DSD_RE_HEX2.test(hex)) {
        throw new Error('帝果播放地址编码无效');
      }
      bytes.push(parseInt(hex, 16));
      i += 3;
      continue;
    }
    if (bytes.length > 0) {
      out += qgUtf8Decode(Uint8Array.from(bytes));
      bytes = [];
    }
    out += ch;
    i++;
  }
  if (bytes.length > 0) {
    out += qgUtf8Decode(Uint8Array.from(bytes));
  }
  return out;
}

/** base64 严格解码（Go base64.StdEncoding 失败回退 RawStdEncoding，均失败返回 null） */
function dsdDecodeBase64Strict(text: string): Uint8Array | null {
  if (DSD_RE_BASE64_STD.test(text)) {
    return qgBase64Decode(text);
  }
  if (text.length % 4 !== 1 && DSD_RE_BASE64_CHARS.test(text)) {
    return qgBase64Decode(text);
  }
  return null;
}

/** Go resolveProviderURL：实体解码 + `\/` 修正 + 相对补全 + http 统一升级 https */
function dsdResolveProviderUrl(baseURL: string, ref: string): string {
  const value: string = dsdUnescapeHtml(ref).trim().replace(/\\\//g, '/');
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  const parts: DsdUrlParts | null = dsdUrlParts(value);
  if (parts !== null) {
    if (parts.scheme === 'http') {
      return `https://${value.substring('http://'.length)}`;
    }
    return value;
  }
  const base: DsdUrlParts | null = dsdUrlParts(baseURL);
  if (base === null) {
    return value;
  }
  const resolved: string = dsdResolveReference(base, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring('http://'.length)}`;
  }
  return resolved;
}

/** Go dsdIssuedMedia：按 encrypt 解码播放地址并校验 http 与 .m3u8/.mp4 后缀 */
function dsdIssuedMedia(player: Record<string, Object>, pageURL: string): string {
  let address: string = dsdMapString(player, ['url']);
  if (address === '') {
    return '';
  }
  const encrypt: string = dsdMapString(player, ['encrypt']);
  if (encrypt === '' || encrypt === '0') {
    // 明文，原样使用
  } else if (encrypt === '1') {
    address = dsdPathUnescape(address);
  } else if (encrypt === '2') {
    const decoded: Uint8Array | null = dsdDecodeBase64Strict(address);
    if (decoded === null) {
      throw new Error('帝果播放地址编码无效');
    }
    address = dsdPathUnescape(qgUtf8Decode(decoded));
  } else {
    throw new Error('帝果播放地址编码已变化');
  }
  address = dsdResolveProviderUrl(pageURL, address);
  if (!dsdIsHttpUrl(address)) {
    throw new Error('帝果播放地址无效');
  }
  const path: string = dsdLowerPath(address);
  if (!path.endsWith('.m3u8') && !path.endsWith('.mp4')) {
    throw new Error('帝果暂未提供可直接播放的媒体');
  }
  return address;
}

/** Go dsdSplitTopLevel：顶层（括号深度 0）按 '+' 切分 */
function dsdSplitTopLevel(value: string): string[] {
  const parts: string[] = [];
  let depth: number = 0;
  let start: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const ch: string = value.charAt(index);
    if (ch === '(') {
      depth++;
    } else if (ch === ')') {
      if (depth > 0) {
        depth--;
      }
    } else if (ch === '+' && depth === 0) {
      const part: string = value.substring(start, index).trim();
      if (part.length > 0) {
        parts.push(part);
      }
      start = index + 1;
    }
  }
  const last: string = value.substring(start).trim();
  if (last.length > 0) {
    parts.push(last);
  }
  return parts;
}

/** Go dsdExpressionParser：递归下降整数表达式求值（NaN 表示失败） */
class DsdExprParser {
  text: string = '';
  index: number = 0;
  depth: number = 0;

  constructor(text: string) {
    this.text = text;
  }

  skipSpaces(): void {
    while (this.index < this.text.length && ' \t\r\n'.includes(this.text.charAt(this.index))) {
      this.index++;
    }
  }

  parseExpression(): number {
    let value: number = this.parseTerm();
    if (Number.isNaN(value)) {
      return NaN;
    }
    while (true) {
      this.skipSpaces();
      if (this.index >= this.text.length) {
        return value;
      }
      const ch: string = this.text.charAt(this.index);
      if (ch !== '+' && ch !== '-') {
        return value;
      }
      this.index++;
      const right: number = this.parseTerm();
      if (Number.isNaN(right)) {
        return NaN;
      }
      value = ch === '+' ? value + right : value - right;
    }
  }

  parseTerm(): number {
    let value: number = this.parseFactor();
    if (Number.isNaN(value)) {
      return NaN;
    }
    while (true) {
      this.skipSpaces();
      if (this.index >= this.text.length) {
        return value;
      }
      const ch: string = this.text.charAt(this.index);
      if (ch !== '*' && ch !== '/' && ch !== '%') {
        return value;
      }
      this.index++;
      const right: number = this.parseFactor();
      if (Number.isNaN(right) || (right === 0 && ch !== '*')) {
        return NaN;
      }
      if (ch === '*') {
        value = value * right;
      } else if (ch === '/') {
        if (value % right !== 0) {
          return NaN;
        }
        value = Math.trunc(value / right);
      } else {
        value = value % right;
      }
    }
  }

  parseFactor(): number {
    this.skipSpaces();
    let sign: number = 1;
    while (this.index < this.text.length &&
      (this.text.charAt(this.index) === '+' || this.text.charAt(this.index) === '-')) {
      if (this.text.charAt(this.index) === '-') {
        sign = -sign;
      }
      this.index++;
      this.skipSpaces();
    }
    if (this.index >= this.text.length) {
      return NaN;
    }
    if (this.text.charAt(this.index) === '(') {
      if (this.depth >= 32) {
        return NaN;
      }
      this.depth++;
      this.index++;
      const value: number = this.parseExpression();
      this.depth--;
      this.skipSpaces();
      if (Number.isNaN(value) || this.index >= this.text.length || this.text.charAt(this.index) !== ')') {
        return NaN;
      }
      this.index++;
      return sign * value;
    }
    const start: number = this.index;
    while (this.index < this.text.length && this.text.charAt(this.index) >= '0' &&
      this.text.charAt(this.index) <= '9') {
      this.index++;
    }
    if (start === this.index) {
      return NaN;
    }
    return sign * Number(this.text.substring(start, this.index));
  }
}

/** Go dsdEvaluateDigitExpression：字符集校验 + 表达式求值 + 全串消费（NaN 表示失败） */
function dsdEvaluateDigitExpression(value: string): number {
  if (value.length > 4096 || !/^[0123456789()+\-*/% \t\r\n]*$/.test(value)) {
    return NaN;
  }
  const parser: DsdExprParser = new DsdExprParser(value);
  const result: number = parser.parseExpression();
  if (Number.isNaN(result)) {
    return NaN;
  }
  parser.skipSpaces();
  return parser.index === value.length ? result : NaN;
}

/** Go dsdAaDigit：单 token → 数字字符（u/b 特判 + 特征替换 + 表达式求值），失败返回 null */
function dsdAaDigit(part: string): string | null {
  let replaced: string = part.trim();
  if (replaced === '') {
    return null;
  }
  if (replaced.includes('(oﾟｰﾟo)')) {
    return 'u';
  }
  if (replaced.includes('(ﾟДﾟ).ﾟΘﾟﾉ')) {
    return 'b';
  }
  replaced = replaced.split('(c^_^o)').join('0');
  replaced = replaced.split('(ﾟΘﾟ)').join('1');
  replaced = replaced.split('(o^_^o)').join('3');
  replaced = replaced.split('(ﾟｰﾟ)').join('4');
  const value: number = dsdEvaluateDigitExpression(replaced);
  if (Number.isNaN(value)) {
    return null;
  }
  return `${value}`;
}

/** Unicode 码点 → 字符串（代理区/越界替换为 U+FFFD，Go WriteRune 语义） */
function dsdRuneOf(code: number): string {
  if (code < 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
    return String.fromCharCode(0xfffd);
  }
  if (code > 0xffff) {
    const offset: number = code - 0x10000;
    return String.fromCharCode(0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff));
  }
  return String.fromCharCode(code);
}

/** Go decodeDSDAaencode：aaencode 乱码解码（u 前缀十六进制 / 八进制），失败返回 null */
function dsdDecodeAaencode(raw: string): string | null {
  if (raw.length > 1 << 20) {
    return null;
  }
  const start: number = raw.indexOf(DSD_AA_MARKER);
  if (start < 0) {
    return null;
  }
  const body: string = raw.substring(start);
  const end: number = body.lastIndexOf(DSD_AA_TAIL);
  if (end < 0) {
    return null;
  }
  const tokens: string[] = body.substring(0, end).split(DSD_AA_SEP);
  let decoded: string = '';
  for (let i: number = 1; i < tokens.length; i++) {
    if (decoded.length > 64 * 1024) {
      return null;
    }
    let digits: string = '';
    const parts: string[] = dsdSplitTopLevel(tokens[i]);
    for (let j: number = 0; j < parts.length; j++) {
      const digit: string | null = dsdAaDigit(parts[j]);
      if (digit === null) {
        return null;
      }
      digits += digit;
    }
    if (digits.startsWith('u') && digits.length === 5) {
      const code: number = parseInt(digits.substring(1), 16);
      if (Number.isNaN(code) || code > 0x7fffffff) {
        return null;
      }
      decoded += dsdRuneOf(code);
    } else if (digits.length > 0 && /^[01234567]+$/.test(digits)) {
      const code: number = parseInt(digits, 8);
      if (Number.isNaN(code) || code > 0x7fffffff) {
        return null;
      }
      decoded += dsdRuneOf(code);
    }
  }
  return decoded;
}

/** Go dsdSignedPathFromVplayer：script 块 aaencode 解码后取 var vPath 值 */
function dsdSignedPathFromVplayer(body: string): string {
  DSD_RE_SCRIPT_BLOCK.lastIndex = 0;
  let match: RegExpExecArray | null = DSD_RE_SCRIPT_BLOCK.exec(body);
  while (match !== null) {
    const content: string = match[1];
    if (content.includes('(ﾟДﾟ)')) {
      const decoded: string | null = dsdDecodeAaencode(content);
      if (decoded !== null) {
        const found: RegExpExecArray | null = DSD_RE_VPATH.exec(decoded);
        if (found !== null && found.length > 1) {
          return found[1].trim();
        }
      }
    }
    match = DSD_RE_SCRIPT_BLOCK.exec(body);
  }
  return '';
}

/** Go dsdVplayerMediaPath：绝对地址取转义 path（空则 /）+ query */
function dsdVplayerMediaPath(address: string): string {
  const parts: DsdUrlParts | null = dsdUrlParts(address);
  if (parts === null) {
    return address;
  }
  let path: string = parts.path.length > 0 ? parts.path : '/';
  if (parts.query.length > 0) {
    path += `?${parts.query}`;
  }
  return path;
}

/** Go dsdVplayerReferer：vplayer 签名页 Referer */
function dsdVplayerReferer(site: string): string {
  let trimmed: string = site;
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return `${trimmed}/addons/vplayer/`;
}

/** Go dsdMediaFromPagePath：同源 /video…/1.jpg 封面 → /1000k/index.m3u8 媒体地址 */
function dsdMediaFromPagePath(cover: string, pageURL: string): string {
  const coverParts: DsdUrlParts | null = dsdUrlParts(cover);
  const pageParts: DsdUrlParts | null = dsdUrlParts(pageURL);
  if (coverParts === null || pageParts === null) {
    return '';
  }
  if (!dsdIsHttpUrl(cover)) {
    return '';
  }
  if (coverParts.scheme !== pageParts.scheme || coverParts.host !== pageParts.host) {
    return '';
  }
  const path: string = coverParts.path;
  if (!DSD_RE_VIDEO_DIR.test(path) || !DSD_RE_POSTER_FILE.test(path)) {
    return '';
  }
  const replaced: string = path.replace(DSD_RE_POSTER_FILE, '/1000k/index.m3u8');
  return `${coverParts.scheme}://${coverParts.host}${replaced}`;
}

export class DsdSource extends QgSource {
  /** 分类缓存（categories() 为同步签名，首次目录/搜索请求时异步填充；1 小时 TTL） */
  private static categoryCache: QgCategory[] = [];
  private static categoriesAt: number = 0;
  /** 进行中的分类请求（并发合并） */
  private static categoriesPromise: Promise<void> | null = null;
  /** 各分类已知最大页数（Go dsdCatalog.limits，15 分钟 TTL） */
  private static pageLimits: Record<string, number> = {};
  private static pageLimitsAt: Record<string, number> = {};

  constructor() {
    super('dsd', '帝果');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < DsdSource.categoryCache.length; i++) {
      all.push(DsdSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.dsdCatalogPage(categoryId, '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.dsdCatalogPage('', keyword, page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceID: string = dramaId.startsWith('dsd:') ?
      dramaId.substring('dsd:'.length) : dramaId;
    if (!DSD_RE_NUMERIC_ID.test(sourceID)) {
      throw new Error('帝果视频 ID 无效');
    }
    const address: string = dsdEpisodePage(DSD_SITE, sourceID, 1, 1);
    const body: string = await this.dsdFetchPage(address);
    return dsdParseDetail(dsdParseHtml(body), address, sourceID);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceID: string = dramaId.startsWith('dsd:') ?
      dramaId.substring('dsd:'.length) : dramaId;
    if (!DSD_RE_NUMERIC_ID.test(sourceID)) {
      throw new Error('帝果播放信息无效，请刷新详情');
    }
    const parts: string[] = episodeId.split('-');
    if (parts.length !== 2) {
      throw new Error('帝果播放分集无效');
    }
    const line: number = dsdInteger(parts[0], 1000000);
    const episode: number = dsdInteger(parts[1], 1000000);
    if (line < 1 || episode < 1) {
      throw new Error('帝果播放分集无效');
    }
    const address: string = dsdEpisodePage(DSD_SITE, sourceID, line, episode);
    const body: string = await this.dsdFetchPage(address);
    const root: DsdNode = dsdParseHtml(body);
    const pr: DsdPlayerResult = dsdParsePlayer(root);
    dsdDetailIdentity(root, sourceID, pr.player, pr.found);
    let media: string = '';
    if (pr.found) {
      const identity: DsdIdentity = dsdPlayerIdentity(pr.player, sourceID);
      if (line !== identity.line || episode !== identity.episode) {
        throw new Error('帝果返回的播放地址与请求分集不符');
      }
      const preview: number = dsdInteger(pr.player['trysee'], 86400);
      if (preview > 0) {
        throw new Error('帝果仅提供试看，暂未取得正片播放地址');
      }
      media = dsdIssuedMedia(pr.player, address);
    }
    if (media === '') {
      if (line !== 1 || episode !== 1) {
        throw new Error('帝果未提供该分集的播放地址');
      }
      const box: DsdNode | null = dsdFirstClass(root, ['video-box']);
      const cover: string = dsdFirstNonEmpty([
        dsdCoverAddress(pr.player['poster'], address),
        dsdCardCover(box, address)
      ]);
      media = dsdMediaFromPagePath(cover, address);
    }
    if (media === '') {
      throw new Error('帝果未提供播放地址，请重试或确认站源权限');
    }
    const signed: DsdSignedResult = await this.dsdSignMedia(media, address);
    let referer: string = address;
    if (signed.byVplayer || signed.address.includes('sign=')) {
      referer = dsdVplayerReferer(DSD_SITE);
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = signed.address;
    info.referer = referer;
    info.headers = { 'User-Agent': DSD_UA, 'Referer': referer };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': DSD_COVER_UA, 'Referer': `${DSD_SITE}/` };
  }

  /** Go fetchProviderText：UA/Referer/Accept-Language，20MB 上限，非 2xx 报错 */
  private async dsdFetchResponse(address: string, referer: string): Promise<QgHttpResponse> {
    const headers: Record<string, string> = {
      'User-Agent': DSD_UA,
      'Referer': referer,
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    const resp: QgHttpResponse = await QgHttp.request(address, 'GET', headers, null, DSD_TIMEOUT_MS);
    if (resp.data.length > DSD_MAX_TEXT_BYTES) {
      throw new Error('帝果返回的数据过大');
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`帝果页面请求失败（HTTP ${resp.status}）`);
    }
    return resp;
  }

  /** Go fetchProviderPage：取页面 HTML（4MB 上限） */
  private async dsdFetchPage(address: string): Promise<string> {
    const resp: QgHttpResponse = await this.dsdFetchResponse(address, `${DSD_SITE}/`);
    if (resp.data.length > DSD_MAX_PAGE_BYTES) {
      throw new Error('站源页面过大');
    }
    return resp.text();
  }

  /** Go fetchDSDCategories：分类懒加载 + 并发合并（1 小时 TTL） */
  private async dsdEnsureCategories(): Promise<void> {
    if (DsdSource.categoryCache.length > 0 &&
      Date.now() - DsdSource.categoriesAt < DSD_CATEGORY_TTL_MS) {
      return;
    }
    if (DsdSource.categoriesPromise !== null) {
      await DsdSource.categoriesPromise;
      return;
    }
    const fetcher: Promise<void> = this.dsdFetchCategoriesIntoCache();
    DsdSource.categoriesPromise = fetcher;
    try {
      await fetcher;
    } finally {
      DsdSource.categoriesPromise = null;
    }
  }

  private async dsdFetchCategoriesIntoCache(): Promise<void> {
    const body: string = await this.dsdFetchPage(`${DSD_SITE}/`);
    DsdSource.categoryCache = dsdParseCategories(dsdParseHtml(body), `${DSD_SITE}/`);
    DsdSource.categoriesAt = Date.now();
  }

  /** Go dsdPageLimit：分类已知最大页数（15 分钟内有效，未知返回 -1） */
  private static dsdPageLimit(categoryId: string): number {
    const at: number | undefined = DsdSource.pageLimitsAt[categoryId];
    if (at === undefined || Date.now() - at >= DSD_PAGE_LIMIT_TTL_MS) {
      return -1;
    }
    const limit: number | undefined = DsdSource.pageLimits[categoryId];
    return limit === undefined ? -1 : limit;
  }

  /** Go fetchDSDPage：单分类/搜索分页取数（页数限制预取 + 卡片解析 + 分页校验） */
  private async dsdFetchPageData(page: number, category: QgCategory, query: string): Promise<DsdFetchResult> {
    if (query === '' && page > 1) {
      let limit: number = DsdSource.dsdPageLimit(category.id);
      if (limit < 0) {
        await this.dsdFetchPageData(1, category, '');
        limit = DsdSource.dsdPageLimit(category.id);
      }
      if (limit >= 0 && page > limit) {
        return new DsdFetchResult([], false);
      }
    }
    let address: string =
      `${DSD_SITE}/index.php/vod/type/id/${category.id}/page/${page}.html`;
    if (query !== '') {
      address = `${DSD_SITE}/index.php/vod/search.html?${qgBuildQuery({ 'page': `${page}`, 'wd': query })}`;
    }
    const body: string = await this.dsdFetchPage(address);
    const root: DsdNode = dsdParseHtml(body);
    const items: QgDrama[] = dsdParseCards(root, address, category.label);
    if (items.length === 0 && dsdFirstClass(root,
      ['video-contaner', 'nvyou-wrap', 'van-list', 'search-page', 'lists']) === null) {
      throw new Error('帝果未返回内容列表，页面可能已变化');
    }
    const pages: number = dsdPagination(root, address, category.id, query, page);
    if (items.length === 0 && pages > page) {
      throw new Error('帝果未返回应有的视频条目，请重试');
    }
    if (query === '') {
      DsdSource.pageLimits[category.id] = pages;
      DsdSource.pageLimitsAt[category.id] = Date.now();
    }
    return new DsdFetchResult(items, pages > page);
  }

  /** Go fetchDSDCatalogPage：参数校验 + 搜索直通 / 单分类 / 全部分类并发(2)交错合并 */
  private async dsdCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 1000000 || query.length > 1024 ||
      (category !== '' && !DSD_RE_NUMERIC_ID.test(category))) {
      throw new Error('帝果目录查询参数无效');
    }
    if (query !== '') {
      const result: DsdFetchResult =
        await this.dsdFetchPageData(page, new QgCategory('', ''), query);
      return new QgPageResult(result.items, result.more);
    }
    await this.dsdEnsureCategories();
    if (category !== '') {
      for (let i: number = 0; i < DsdSource.categoryCache.length; i++) {
        if (DsdSource.categoryCache[i].id === category) {
          const result: DsdFetchResult =
            await this.dsdFetchPageData(page, DsdSource.categoryCache[i], '');
          return new QgPageResult(result.items, result.more);
        }
      }
      throw new Error('帝果分类已变化，请刷新分类');
    }
    const categories: QgCategory[] = DsdSource.categoryCache;
    const results: DsdFetchOutcome[] = [];
    for (let i: number = 0; i < categories.length; i++) {
      results.push(new DsdFetchOutcome());
    }
    let next: number = 0;
    const worker = async (): Promise<void> => {
      while (true) {
        const index: number = next;
        next++;
        if (index >= categories.length) {
          return;
        }
        try {
          const result: DsdFetchResult = await this.dsdFetchPageData(page, categories[index], '');
          results[index].items = result.items;
          results[index].more = result.more;
        } catch (error) {
          results[index].error = error as Error;
        }
      }
    };
    await Promise.all([worker(), worker()]);
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    let hasMore: boolean = false;
    let count: number = 0;
    const failures: string[] = [];
    for (let i: number = 0; i < results.length; i++) {
      hasMore = hasMore || results[i].more || results[i].error !== null;
      count = Math.max(count, results[i].items.length);
      const failure: Error | null = results[i].error;
      if (failure !== null) {
        failures.push(`${categories[i].label}：${failure.message}`);
      }
    }
    for (let index: number = 0; index < count; index++) {
      for (let i: number = 0; i < results.length; i++) {
        if (index < results[i].items.length) {
          const item: QgDrama = results[i].items[index];
          if (seen[item.id] !== true) {
            seen[item.id] = true;
            items.push(item);
          }
        }
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join('\n'));
    }
    return new QgPageResult(items, hasMore);
  }

  /** Go signDSDMedia：含 sign= 直用；否则经 /addons/vplayer/ 签名页取直链 */
  private async dsdSignMedia(address: string, pageURL: string): Promise<DsdSignedResult> {
    if (address.includes('sign=')) {
      return new DsdSignedResult(address, false);
    }
    const mediaPath: string = dsdVplayerMediaPath(address);
    const vplayerURL: string =
      `${DSD_SITE}/addons/vplayer/?url=${encodeURIComponent(mediaPath)}&jump=`;
    const resp: QgHttpResponse = await this.dsdFetchResponse(vplayerURL, `${DSD_SITE}/`);
    const signed: string = dsdSignedPathFromVplayer(resp.text());
    if (signed === '') {
      return new DsdSignedResult(address, false);
    }
    const resolved: string = dsdResolveProviderUrl(dsdVplayerReferer(DSD_SITE), signed);
    if (!dsdIsHttpUrl(resolved)) {
      throw new Error('帝果播放签名地址无效');
    }
    const path: string = dsdLowerPath(resolved);
    if (!path.endsWith('.m3u8') && !path.endsWith('.mp4')) {
      throw new Error('帝果签名后未返回可播放媒体');
    }
    if (dsdOriginOf(resolved) === '' || pageURL === '') {
      throw new Error('帝果播放签名缺少来源信息');
    }
    return new DsdSignedResult(resolved, true);
  }
}
