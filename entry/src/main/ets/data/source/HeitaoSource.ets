/**
 * 黑桃站源（https://heitaodj.com，DSD 风格 /index.php/vod 路由）。
 * 站点为纯 HTML 页面：目录/搜索解析 a.thumb 卡片，分页从页内路由锚点推最大页码；
 * 详情页解析 ld+json TVSeries 元数据（剧名/简介/封面）与分集链接（按 sid 分组取最优线路）；
 * 播放页（需 heitao_age_confirmed=1 Cookie）提取 player_aaaa 配置，
 * 按 encrypt 0/1/2 解码（明文 / PathUnescape / base64+PathUnescape），http 统一升级 https。
 * 移植自 guoapp provider_heitao.go（分类/目录/搜索/详情/播放全链路）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgBase64Decode, qgUtf8Decode } from '../QgBytes';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const HT_HOST: string = 'https://heitaodj.com';
const HT_UA: string = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const HT_AGE_COOKIE: string = 'heitao_age_confirmed=1';
const HT_TIMEOUT_MS: number = 15000;
const HT_MAX_BODY_BYTES: number = 4 * 1024 * 1024;
const HT_VOID_TAGS: string[] = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'];

/** Go webProviderNumericID：非零开头的纯数字 ID */
const HT_RE_NUMERIC_ID: RegExp = /^[1-9][0-9]{0,17}$/;
const HT_RE_INT: RegExp = /^[0-9]+$/;
const HT_RE_HEX2: RegExp = /^[0-9a-fA-F]{2}$/;
const HT_RE_WHITESPACE: RegExp = /\s/;
const HT_RE_CLASSIC_URL: RegExp = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//;
const HT_RE_TAG_NAME_START: RegExp = /^[a-zA-Z]/;
/** Go reHeitaoEpisodeHref：/index.php/vod/play/id/(\d+)/sid/(\d+)/nid/(\d+).html */
const HT_RE_EPISODE_HREF: RegExp = /\/index\.php\/vod\/play\/id\/(\d+)\/sid\/(\d+)\/nid\/(\d+)\.html/i;
/** Go reHeitaoSearchPage：搜索分页锚点 */
const HT_RE_SEARCH_PAGE: RegExp = /\/vod\/search\/page\/(\d+)\/wd\//i;
/** Go reHeitaoEpisodeCount：备注 "N集" → 总集数 */
const HT_RE_EPISODE_COUNT: RegExp = /^(\d+)集$/;

/** HTML 节点（htParseHtml 产物；文本节点 tag 为 '#text'） */
class HtNode {
  tag: string = '';
  attrs: Record<string, string> = {};
  text: string = '';
  children: HtNode[] = [];
  parent: HtNode | null = null;
}

/** URL 拆解结果（scheme://host + path + query） */
class HtUrlParts {
  scheme: string = '';
  host: string = '';
  path: string = '';
  query: string = '';
}

/** dsdRouteParameters 解析结果：动作 + 路由参数 */
class HtRoute {
  action: string = '';
  params: Record<string, string> = {};
}

/** ld+json TVSeries 元数据（heitaoSeriesMeta） */
class HtMeta {
  name: string = '';
  description: string = '';
  image: Object | null = null;
}

/** player_aaaa 配置（heitaoPlayerEntry） */
class HtPlayerEntry {
  url: string = '';
  encrypt: Object | null = null;
}

/** 分集链接条目（sid 线路下的 nid 分集） */
class HtEpisodeItem {
  sid: number = 0;
  nid: number = 0;
  title: string = '';
}

/** HTML 数字实体解码（&#x...; / &#...;） */
function htDecodeNumericEntities(text: string): string {
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
function htUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = htDecodeNumericEntities(next);
    next = next.replace(/&amp;/g, '&');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go truncate：超长截断加省略号（按码点计数） */
function htTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** 追加文本节点（script/style 内容为 raw text，不做实体解码） */
function htAppendText(parent: HtNode, text: string, decodeEntities: boolean): void {
  if (text.length === 0) {
    return;
  }
  const node: HtNode = new HtNode();
  node.tag = '#text';
  node.text = decodeEntities ? htUnescapeHtml(text) : text;
  node.parent = parent;
  parent.children.push(node);
}

/** 标签内定位 '>'（跳过引号内的尖括号） */
function htTagEnd(body: string, start: number): number {
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
function htParseTag(raw: string): HtNode {
  const node: HtNode = new HtNode();
  let i: number = 0;
  while (i < raw.length && HT_RE_WHITESPACE.test(raw.charAt(i))) {
    i++;
  }
  const nameStart: number = i;
  while (i < raw.length && !HT_RE_WHITESPACE.test(raw.charAt(i))) {
    i++;
  }
  node.tag = raw.substring(nameStart, i).toLowerCase();
  while (i < raw.length) {
    while (i < raw.length && HT_RE_WHITESPACE.test(raw.charAt(i))) {
      i++;
    }
    if (i >= raw.length) {
      break;
    }
    const attrStart: number = i;
    while (i < raw.length && !HT_RE_WHITESPACE.test(raw.charAt(i)) && raw.charAt(i) !== '=') {
      i++;
    }
    const attrName: string = raw.substring(attrStart, i).toLowerCase();
    while (i < raw.length && HT_RE_WHITESPACE.test(raw.charAt(i))) {
      i++;
    }
    let attrValue: string = '';
    if (i < raw.length && raw.charAt(i) === '=') {
      i++;
      while (i < raw.length && HT_RE_WHITESPACE.test(raw.charAt(i))) {
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
        while (i < raw.length && !HT_RE_WHITESPACE.test(raw.charAt(i))) {
          i++;
        }
        attrValue = raw.substring(valueStart, i);
      }
    }
    if (attrName.length > 0) {
      node.attrs[attrName] = htUnescapeHtml(attrValue);
    }
  }
  return node;
}

/** 轻量 HTML 树解析（Go x/net/html 的替代）：文档序 DFS 构建 */
function htParseHtml(body: string): HtNode {
  const root: HtNode = new HtNode();
  root.tag = '#root';
  const stack: HtNode[] = [root];
  const lower: string = body.toLowerCase();
  let i: number = 0;
  while (i < body.length) {
    const top: HtNode = stack[stack.length - 1];
    // script/style 为 raw text 元素：内容原样保留直到闭合标签
    if (top.tag === 'script' || top.tag === 'style') {
      const closeIdx: number = lower.indexOf(`</${top.tag}`, i);
      if (closeIdx < 0) {
        htAppendText(top, body.substring(i), false);
        break;
      }
      if (closeIdx > i) {
        htAppendText(top, body.substring(i, closeIdx), false);
      }
      const gt: number = body.indexOf('>', closeIdx);
      i = gt < 0 ? body.length : gt + 1;
      stack.pop();
      continue;
    }
    const lt: number = body.indexOf('<', i);
    if (lt < 0) {
      htAppendText(top, body.substring(i), true);
      break;
    }
    if (lt > i) {
      htAppendText(top, body.substring(i, lt), true);
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
    if (!HT_RE_TAG_NAME_START.test(nextChar)) {
      htAppendText(top, '<', true);
      i = lt + 1;
      continue;
    }
    const end: number = htTagEnd(body, lt);
    const rawTag: string = body.substring(lt + 1, end < 0 ? body.length : end);
    const selfClose: boolean = rawTag.endsWith('/');
    const cleaned: string = selfClose ? rawTag.substring(0, rawTag.length - 1) : rawTag;
    const node: HtNode = htParseTag(cleaned);
    const parent: HtNode = stack[stack.length - 1];
    node.parent = parent;
    parent.children.push(node);
    if (!selfClose && !HT_VOID_TAGS.includes(node.tag)) {
      stack.push(node);
    }
    i = end < 0 ? body.length : end + 1;
  }
  return root;
}

/** Go providerHTMLAttr：取属性值 */
function htAttr(node: HtNode | null, name: string): string {
  if (node === null) {
    return '';
  }
  const value: string | undefined = node.attrs[name];
  return value === undefined ? '' : value;
}

/** Go providerHTMLClass：class 列表包含指定类名 */
function htHasClass(node: HtNode, name: string): boolean {
  const value: string = htAttr(node, 'class');
  if (value.trim().length === 0) {
    return false;
  }
  return value.split(/\s+/).includes(name);
}

/** Go providerHTMLNodes：文档序遍历 root 及全部后代，收集满足条件的节点 */
function htCollect(root: HtNode | null, want: (node: HtNode) => boolean): HtNode[] {
  const found: HtNode[] = [];
  if (root === null) {
    return found;
  }
  const pending: HtNode[] = [root];
  while (pending.length > 0) {
    const node: HtNode = pending[pending.length - 1];
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

/** Go providerHTMLFirstClass：第一个含指定类名的节点 */
function htFirstClass(root: HtNode | null, name: string): HtNode | null {
  const found: HtNode[] = htCollect(root, (node: HtNode): boolean => htHasClass(node, name));
  return found.length > 0 ? found[0] : null;
}

/** Go providerHTMLText：后代文本拼接（跳过 script/style），空白折叠 */
function htText(root: HtNode | null): string {
  if (root === null) {
    return '';
  }
  let out: string = '';
  const pending: HtNode[] = [root];
  while (pending.length > 0) {
    const node: HtNode = pending[pending.length - 1];
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

/** Go heitaoScriptText：script 直接文本子节点拼接 */
function htScriptText(node: HtNode): string {
  let out: string = '';
  for (let i: number = 0; i < node.children.length; i++) {
    const child: HtNode = node.children[i];
    if (child.tag === '#text') {
      out += child.text;
    }
  }
  return out.trim();
}

/** URL 拆解：scheme://host + path + query（非绝对地址返回 null） */
function htUrlParts(raw: string): HtUrlParts | null {
  const value: string = raw.trim();
  const match: RegExpMatchArray | null = value.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^#]*)/);
  if (match === null) {
    return null;
  }
  const parts: HtUrlParts = new HtUrlParts();
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
function htResolveReference(page: HtUrlParts, ref: string): string {
  const origin: string = `${page.scheme}://${page.host}`;
  if (HT_RE_CLASSIC_URL.test(ref)) {
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
function htQueryUnescape(text: string): string | null {
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
      if (!HT_RE_HEX2.test(hex)) {
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
function htParseQuery(query: string): Record<string, string> {
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
    const key: string | null = htQueryUnescape(rawKey);
    if (key === null || key.length === 0 || out[key] !== undefined) {
      continue;
    }
    const value: string | null = htQueryUnescape(rawValue);
    out[key] = value === null ? '' : value;
  }
  return out;
}

/**
 * Go dsdRouteParameters：解析 /index.php/vod/{action}/k/v...html 路由。
 * 要求与 pageURL 同源且无 userinfo；action ∈ type/show/search/play/detail；
 * 路径按 k/v 成对取参，查询参数补充路径未提供的键。
 */
function htRouteParameters(pageURL: string, reference: string): HtRoute | null {
  if (reference.length === 0) {
    return null;
  }
  const page: HtUrlParts | null = htUrlParts(pageURL);
  if (page === null) {
    return null;
  }
  const absolute: string = htResolveReference(page, reference);
  const address: HtUrlParts | null = htUrlParts(absolute);
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
  const route: HtRoute = new HtRoute();
  route.action = action;
  for (let i: number = 2; i + 1 < parts.length; i += 2) {
    route.params[parts[i]] = parts[i + 1];
  }
  const query: Record<string, string> = htParseQuery(address.query);
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
function htIsHttpUrl(raw: string): boolean {
  const parts: HtUrlParts | null = htUrlParts(raw.trim());
  if (parts === null) {
    return false;
  }
  if (parts.scheme !== 'http' && parts.scheme !== 'https') {
    return false;
  }
  return parts.host.length > 0 && !parts.host.includes('@');
}

/** 封面地址解析（字符串分支）：相对补全 + 合法性校验 */
function htCoverSrc(raw: string, pageURL: string): string {
  const text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  const page: HtUrlParts | null = htUrlParts(pageURL);
  const resolved: string = page !== null ? htResolveReference(page, text) : text;
  return htIsHttpUrl(resolved) ? resolved : '';
}

/** Go providerCoverAddress：数组/对象/字符串取封面并相对补全 */
function htCoverAddress(value: Object | undefined | null, pageURL: string): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (Array.isArray(value)) {
    const items: Object[] = value as Object[];
    for (let i: number = 0; i < items.length; i++) {
      const address: string = htCoverAddress(items[i], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
    return '';
  }
  if (typeof value === 'string') {
    return htCoverSrc(value, pageURL);
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['url', 'contentUrl', 'thumbnailUrl'];
    for (let i: number = 0; i < keys.length; i++) {
      const address: string = htCoverAddress(map[keys[i]], pageURL);
      if (address.length > 0) {
        return address;
      }
    }
  }
  return '';
}

/** Go heitaoSeriesMetadata：ld+json 中找 TVSeries 元数据 */
function htSeriesMetadata(root: HtNode): HtMeta {
  const scripts: HtNode[] = htCollect(root, (node: HtNode): boolean => {
    if (node.tag !== 'script') {
      return false;
    }
    return htAttr(node, 'type').toLowerCase().includes('ld+json');
  });
  for (let i: number = 0; i < scripts.length; i++) {
    const text: string = htScriptText(scripts[i]);
    if (text.length === 0) {
      continue;
    }
    const parsed: Object | null = QgJson.parse(text);
    if (parsed === null) {
      continue;
    }
    if (Array.isArray(parsed)) {
      const items: Object[] = parsed as Object[];
      for (let j: number = 0; j < items.length; j++) {
        const meta: HtMeta | null = htMetaFrom(items[j]);
        if (meta !== null) {
          return meta;
        }
      }
      continue;
    }
    const meta: HtMeta | null = htMetaFrom(parsed);
    if (meta !== null) {
      return meta;
    }
  }
  return new HtMeta();
}

/** 单条 ld+json 记录 → TVSeries 元数据（非 TVSeries 返回 null） */
function htMetaFrom(value: Object): HtMeta | null {
  const row: Record<string, Object> | null = QgJson.obj(value);
  if (row === null) {
    return null;
  }
  if (QgJson.str(row['@type']).toLowerCase() !== 'tvseries') {
    return null;
  }
  const meta: HtMeta = new HtMeta();
  meta.name = QgJson.str(row['name']);
  meta.description = QgJson.str(row['description']);
  const image: Object | undefined = row['image'];
  meta.image = image === undefined ? null : image;
  return meta;
}

/** Go heitaoCategoryName：li 文本 "分类：X" 取 X */
function htCategoryName(root: HtNode): string {
  const items: HtNode[] = htCollect(root, (node: HtNode): boolean => node.tag === 'li');
  for (let i: number = 0; i < items.length; i++) {
    const text: string = htText(items[i]);
    if (text.startsWith('分类：')) {
      const name: string = text.substring('分类：'.length).trim();
      if (name.length > 0) {
        return name;
      }
    }
  }
  return '';
}

/** Go heitaoTags：detail-tags 块内锚点文本 → 标签列表 */
function htTags(root: HtNode): string[] {
  const tags: string[] = [];
  const block: HtNode | null = htFirstClass(root, 'detail-tags');
  if (block === null) {
    return tags;
  }
  const seen: Record<string, boolean> = {};
  const anchors: HtNode[] = htCollect(block, (node: HtNode): boolean => node.tag === 'a');
  for (let i: number = 0; i < anchors.length; i++) {
    const value: string = htText(anchors[i]);
    if (value.length === 0 || Array.from(value).length > 48 || seen[value] === true) {
      continue;
    }
    seen[value] = true;
    tags.push(value);
    if (tags.length >= 32) {
      break;
    }
  }
  return tags;
}

/** Go heitaoEpisodeCount：备注 "N集" → 总集数（1..100000 之外为 0） */
function htEpisodeCountOf(remark: string): number {
  const match: RegExpMatchArray | null = remark.trim().match(HT_RE_EPISODE_COUNT);
  if (match === null || match.length < 2) {
    return 0;
  }
  const parsed: number = Number(match[1]);
  if (parsed < 1 || parsed > 100000) {
    return 0;
  }
  return parsed;
}

/** Go validHeitaoCategory：空串合法，其余为 ≤6 位非零开头数字 */
function htValidCategory(category: string): boolean {
  if (category.length === 0) {
    return true;
  }
  if (category.length > 6) {
    return false;
  }
  return HT_RE_NUMERIC_ID.test(category);
}

/** Go parseHeitaoCards：a.thumb 卡片 → QgDrama 列表 */
function htParseCards(root: HtNode, pageURL: string): QgDrama[] {
  const items: QgDrama[] = [];
  const seen: Record<string, boolean> = {};
  const cards: HtNode[] = htCollect(root, (node: HtNode): boolean =>
    node.tag === 'a' && htHasClass(node, 'thumb'));
  for (let i: number = 0; i < cards.length; i++) {
    const card: HtNode = cards[i];
    const route: HtRoute | null = htRouteParameters(pageURL, htAttr(card, 'href'));
    if (route === null || route.action !== 'detail') {
      continue;
    }
    const id: string = route.params['id'] === undefined ? '' : route.params['id'];
    if (!HT_RE_NUMERIC_ID.test(id) || seen[id] === true) {
      continue;
    }
    const images: HtNode[] = htCollect(card, (node: HtNode): boolean => node.tag === 'img');
    let title: string = htAttr(card, 'title').trim();
    if (title.length === 0) {
      for (let j: number = 0; j < images.length; j++) {
        const alt: string = htAttr(images[j], 'alt').trim();
        if (alt.length > 0) {
          title = alt;
          break;
        }
      }
    }
    if (title.length === 0) {
      title = htText(card);
    }
    if (title.length === 0) {
      continue;
    }
    seen[id] = true;
    let cover: string = '';
    for (let j: number = 0; j < images.length && cover.length === 0; j++) {
      const attrNames: string[] = ['src', 'data-src', 'data-original'];
      for (let k: number = 0; k < attrNames.length; k++) {
        const candidate: string = htCoverSrc(htAttr(images[j], attrNames[k]), pageURL);
        if (candidate.length > 0) {
          cover = candidate;
          break;
        }
      }
    }
    let remark: string = '';
    const label: HtNode | null = htFirstClass(card, 'label');
    if (label !== null) {
      remark = htTruncate(htText(label), 64);
    }
    const drama: QgDrama = new QgDrama(`heitao:${id}`, htTruncate(title, 512), '短剧');
    drama.sourceId = 'heitao';
    drama.cover = cover;
    drama.remark = remark;
    const count: number = htEpisodeCountOf(remark);
    if (count > 0) {
      drama.episodeCount = count;
    }
    items.push(drama);
    if (items.length >= 500) {
      break;
    }
  }
  return items;
}

/** Go heitaoCatalogAddress：目录/搜索分页地址 */
function htCatalogAddress(page: number, category: string, query: string): string {
  if (query.length > 0) {
    const escaped: string = encodeURIComponent(query);
    if (page <= 1) {
      return `${HT_HOST}/index.php/vod/search/wd/${escaped}.html`;
    }
    return `${HT_HOST}/index.php/vod/search/page/${page}/wd/${escaped}.html`;
  }
  let show: string = `${HT_HOST}/index.php/vod/show`;
  if (category.length > 0) {
    show += `/id/${category}`;
  }
  if (page <= 1) {
    return `${show}.html`;
  }
  return `${show}/page/${page}.html`;
}

/** Go heitaoPageCount：页内分页锚点推最大页码（搜索走专用正则，目录走路由参数） */
function htPageCount(root: HtNode, pageURL: string, category: string, query: string, page: number): number {
  let pages: number = page;
  const anchors: HtNode[] = htCollect(root, (node: HtNode): boolean => node.tag === 'a');
  for (let i: number = 0; i < anchors.length; i++) {
    const href: string = htAttr(anchors[i], 'href');
    let value: string = '';
    if (query.length > 0) {
      const match: RegExpMatchArray | null = href.match(HT_RE_SEARCH_PAGE);
      if (match !== null && match.length >= 2) {
        value = match[1];
      }
    } else {
      const route: HtRoute | null = htRouteParameters(pageURL, href);
      if (route !== null && (route.action === 'show' || route.action === 'type')) {
        const id: string = route.params['id'] === undefined ? '' : route.params['id'];
        if (id === category) {
          value = route.params['page'] === undefined ? '' : route.params['page'];
        }
      }
    }
    if (HT_RE_INT.test(value)) {
      const parsed: number = Number(value);
      if (parsed > pages && parsed < 100000) {
        pages = parsed;
      }
    }
  }
  return pages;
}

/** Go heitaoChapters：分集 href 按 sid 分组，取分集最多的线路（平局取小 sid） */
function htEpisodes(root: HtNode, sourceId: string): QgEpisode[] {
  const anchors: HtNode[] = htCollect(root, (node: HtNode): boolean => node.tag === 'a');
  const groups: Record<string, HtEpisodeItem[]> = {};
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; i < anchors.length; i++) {
    const match: RegExpMatchArray | null = htAttr(anchors[i], 'href').match(HT_RE_EPISODE_HREF);
    if (match === null || match.length < 4 || match[1] !== sourceId) {
      continue;
    }
    const sid: number = Number(match[2]);
    const nid: number = Number(match[3]);
    if (sid < 1 || nid < 1) {
      continue;
    }
    const key: string = `${sid}:${nid}`;
    if (seen[key] === true) {
      continue;
    }
    seen[key] = true;
    let title: string = htText(anchors[i]);
    if (title.length === 0) {
      title = `第 ${nid} 集`;
    }
    const item: HtEpisodeItem = new HtEpisodeItem();
    item.sid = sid;
    item.nid = nid;
    item.title = title;
    const groupKey: string = `${sid}`;
    if (groups[groupKey] === undefined) {
      groups[groupKey] = [];
    }
    groups[groupKey].push(item);
  }
  let best: HtEpisodeItem[] = [];
  let bestSid: number = 0;
  const groupKeys: string[] = Object.keys(groups);
  for (let i: number = 0; i < groupKeys.length; i++) {
    const items: HtEpisodeItem[] = groups[groupKeys[i]];
    const sid: number = Number(groupKeys[i]);
    if (items.length > best.length || (items.length === best.length && sid < bestSid)) {
      best = items;
      bestSid = sid;
    }
  }
  const episodes: QgEpisode[] = [];
  for (let i: number = 0; i < best.length; i++) {
    const item: HtEpisodeItem = best[i];
    episodes.push(new QgEpisode(`${item.sid}:${item.nid}`, htTruncate(item.title, 128), item.nid));
  }
  episodes.sort((a: QgEpisode, b: QgEpisode): number => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
  });
  return episodes;
}

/** Go heitaoReadPlayerConfig：定位 player_aaaa 并括号扫描提取 JSON 配置 */
function htReadPlayerConfig(body: string): HtPlayerEntry {
  const index: number = body.indexOf('player_aaaa');
  if (index < 0) {
    throw new Error('黑桃播放器未返回配置');
  }
  const text: string = body.substring(index);
  const open: number = text.indexOf('{');
  if (open < 0) {
    throw new Error('黑桃播放器配置无效');
  }
  let depth: number = 0;
  let inString: boolean = false;
  let escaped: boolean = false;
  let end: number = -1;
  for (let i: number = open; i < text.length; i++) {
    const value: string = text.charAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (value === '\\') {
        escaped = true;
        continue;
      }
      if (value === '"') {
        inString = false;
      }
      continue;
    }
    if (value === '"') {
      inString = true;
      continue;
    }
    if (value === '{') {
      depth++;
      continue;
    }
    if (value === '}') {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) {
    throw new Error('黑桃播放器配置不完整');
  }
  const parsed: Object | null = QgJson.parse(text.substring(open, end + 1));
  const row: Record<string, Object> | null = parsed === null ? null : QgJson.obj(parsed);
  if (row === null) {
    throw new Error('黑桃播放器配置解析失败');
  }
  const entry: HtPlayerEntry = new HtPlayerEntry();
  entry.url = QgJson.str(row['url']);
  const encrypt: Object | undefined = row['encrypt'];
  entry.encrypt = encrypt === undefined ? null : encrypt;
  if (entry.url.trim().length === 0) {
    throw new Error('黑桃该集暂无可用播放地址');
  }
  return entry;
}

/** Go encrypt 取值：number / 数字字符串 / bool */
function htEncryptOf(value: Object | null): number {
  if (typeof value === 'number') {
    return Math.trunc(value);
  }
  if (typeof value === 'boolean') {
    return value ? 1 : 0;
  }
  if (typeof value === 'string') {
    const text: string = value.trim();
    if (!HT_RE_INT.test(text)) {
      return 0;
    }
    return Number(text);
  }
  return 0;
}

/** Go url.PathUnescape（UTF-8 感知，非法转义抛错） */
function htPathUnescape(text: string): string {
  let out: string = '';
  let bytes: number[] = [];
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '%') {
      const hex: string = text.substring(i + 1, i + 3);
      if (!HT_RE_HEX2.test(hex)) {
        throw new Error('黑桃播放地址解码失败');
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

/** Go heitaoDecryptMediaURL：encrypt 0 明文 / 1 PathUnescape / 2 base64+PathUnescape */
function htDecryptMediaUrl(raw: string, encrypt: number): string {
  const value: string = raw.trim();
  if (encrypt === 0) {
    return value;
  }
  if (encrypt === 1) {
    return htPathUnescape(value);
  }
  if (encrypt === 2) {
    const decoded: Uint8Array = qgBase64Decode(value);
    if (decoded.length === 0) {
      throw new Error('黑桃播放地址解码失败');
    }
    return htPathUnescape(qgUtf8Decode(decoded));
  }
  throw new Error('黑桃播放地址加密方式暂不支持');
}

/** Go resolveProviderURL：实体解码 + `\/` 修正 + 相对补全 + http 统一升级 https */
function htResolveProviderUrl(baseURL: string, ref: string): string {
  const value: string = htUnescapeHtml(ref).trim().replace(/\\\//g, '/');
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('//')) {
    return `https:${value}`;
  }
  const parts: HtUrlParts | null = htUrlParts(value);
  if (parts !== null) {
    if (parts.scheme === 'http') {
      return `https://${value.substring('http://'.length)}`;
    }
    return value;
  }
  const base: HtUrlParts | null = htUrlParts(baseURL);
  if (base === null) {
    return value;
  }
  const resolved: string = htResolveReference(base, value);
  if (resolved.startsWith('http://')) {
    return `https://${resolved.substring('http://'.length)}`;
  }
  return resolved;
}

export class HeitaoSource extends QgSource {
  /** 分类缓存（categories() 为同步签名，首次目录请求时异步填充） */
  private static categoryCache: QgCategory[] = [];

  constructor() {
    super('heitao', '黑桃');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [new QgCategory('', '全部')];
    for (let i: number = 0; i < HeitaoSource.categoryCache.length; i++) {
      all.push(HeitaoSource.categoryCache[i]);
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.htCatalogPage(categoryId, '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.htCatalogPage('', keyword, page);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceId: string = (dramaId.startsWith('heitao:') ?
      dramaId.substring('heitao:'.length) : dramaId).trim();
    if (!HT_RE_NUMERIC_ID.test(sourceId)) {
      throw new Error('黑桃视频 ID 无效');
    }
    const address: string = `${HT_HOST}/index.php/vod/detail/id/${sourceId}.html`;
    const body: string = await this.htFetchPage(address, `${HT_HOST}/`, '');
    const root: HtNode = htParseHtml(body);
    const meta: HtMeta = htSeriesMetadata(root);
    let name: string = meta.name.trim();
    if (name.length === 0) {
      const heading: HtNode | null = htFirstClass(root, 'title');
      if (heading !== null) {
        name = htText(heading);
      }
    }
    if (name.length === 0) {
      throw new Error('黑桃详情缺少剧名');
    }
    const episodes: QgEpisode[] = htEpisodes(root, sourceId);
    if (episodes.length === 0) {
      throw new Error('黑桃该剧暂无可播分集');
    }
    let cover: string = htCoverAddress(meta.image, address);
    if (cover.length === 0) {
      const block: HtNode | null = htFirstClass(root, 'albumDetailImg');
      if (block !== null) {
        const images: HtNode[] = htCollect(block, (node: HtNode): boolean => node.tag === 'img');
        for (let i: number = 0; i < images.length; i++) {
          const candidate: string = htCoverSrc(htAttr(images[i], 'src'), address);
          if (candidate.length > 0) {
            cover = candidate;
            break;
          }
        }
      }
    }
    const categoryName: string = htCategoryName(root);
    const drama: QgDrama = new QgDrama(`heitao:${sourceId}`, htTruncate(name, 512),
      categoryName.length > 0 ? categoryName : '短剧');
    drama.sourceId = 'heitao';
    drama.intro = htTruncate(meta.description, 12000);
    drama.cover = cover;
    drama.tags = htTags(root);
    drama.episodeCount = episodes.length;
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceId: string = (dramaId.startsWith('heitao:') ?
      dramaId.substring('heitao:'.length) : dramaId).trim();
    if (!HT_RE_NUMERIC_ID.test(sourceId)) {
      throw new Error('黑桃播放分集信息无效，请刷新详情');
    }
    const parts: string[] = episodeId.split(':');
    if (parts.length !== 2 || !HT_RE_INT.test(parts[0]) || !HT_RE_INT.test(parts[1])) {
      throw new Error('黑桃播放分集信息无效，请刷新详情');
    }
    const sid: number = Number(parts[0]);
    const nid: number = Number(parts[1]);
    if (sid < 1 || nid < 1) {
      throw new Error('黑桃播放分集信息无效，请刷新详情');
    }
    const playerURL: string = `${HT_HOST}/index.php/vod/player/id/${sourceId}/nid/${nid}/sid/${sid}.html`;
    const playURL: string = `${HT_HOST}/index.php/vod/play/id/${sourceId}/sid/${sid}/nid/${nid}.html`;
    const body: string = await this.htFetchPage(playerURL, playURL, HT_AGE_COOKIE);
    const entry: HtPlayerEntry = htReadPlayerConfig(body);
    const address: string = htDecryptMediaUrl(entry.url, htEncryptOf(entry.encrypt));
    const resolved: string = htResolveProviderUrl(playerURL, address);
    if (!htIsHttpUrl(resolved)) {
      throw new Error('黑桃播放地址无效');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = resolved;
    info.referer = `${HT_HOST}/`;
    info.headers = { 'Referer': info.referer, 'User-Agent': HT_UA };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': HT_UA, 'Referer': `${HT_HOST}/` };
  }

  /** 统一页面抓取：heitao UA / Accept-Language / Referer（播放页加年龄确认 Cookie） */
  private async htFetchPage(address: string, referer: string, cookie: string): Promise<string> {
    const headers: Record<string, string> = {
      'User-Agent': HT_UA,
      'Referer': referer,
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
    }
    const resp: QgHttpResponse = await QgHttp.request(address, 'GET', headers, null, HT_TIMEOUT_MS);
    if (resp.data.length > HT_MAX_BODY_BYTES) {
      throw new Error('黑桃页面数据过大');
    }
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`黑桃页面请求失败（HTTP ${resp.status}）`);
    }
    return resp.text();
  }

  /** Go fetchHeitaoCategories：首页路由锚点中 action=type 的分类 */
  private async htFetchCategories(): Promise<QgCategory[]> {
    const body: string = await this.htFetchPage(`${HT_HOST}/`, `${HT_HOST}/`, '');
    const root: HtNode = htParseHtml(body);
    const categories: QgCategory[] = [];
    const seen: Record<string, boolean> = {};
    const anchors: HtNode[] = htCollect(root, (node: HtNode): boolean => node.tag === 'a');
    for (let i: number = 0; i < anchors.length; i++) {
      const route: HtRoute | null = htRouteParameters(`${HT_HOST}/`, htAttr(anchors[i], 'href'));
      if (route === null || route.action !== 'type') {
        continue;
      }
      const id: string = route.params['id'] === undefined ? '' : route.params['id'];
      const name: string = htText(anchors[i]);
      if (!htValidCategory(id) || id.length === 0 || seen[id] === true ||
        name.length === 0 || Array.from(name).length > 48) {
        continue;
      }
      seen[id] = true;
      categories.push(new QgCategory(id, name));
      if (categories.length >= 32) {
        break;
      }
    }
    if (categories.length === 0) {
      throw new Error('黑桃未返回有效的内容分类');
    }
    return categories;
  }

  /** 分类懒加载：categories() 为同步签名，首次分页请求时填充缓存 */
  private async htEnsureCategories(): Promise<void> {
    if (HeitaoSource.categoryCache.length > 0) {
      return;
    }
    try {
      HeitaoSource.categoryCache = await this.htFetchCategories();
    } catch (error) {
      // 分类获取失败不阻塞目录；下次分页请求再试
    }
  }

  /** 目录/搜索共用的分页取数（fetchHeitaoCatalogPage） */
  private async htCatalogPage(category: string, query: string, page: number): Promise<QgPageResult> {
    const keyword: string = query.trim();
    if (page < 1 || page > 100000 || keyword.length > 256 || !htValidCategory(category)) {
      throw new Error('黑桃目录查询参数无效');
    }
    await this.htEnsureCategories();
    const address: string = htCatalogAddress(page, category, keyword);
    const body: string = await this.htFetchPage(address, `${HT_HOST}/`, '');
    const root: HtNode = htParseHtml(body);
    const items: QgDrama[] = htParseCards(root, address);
    const pages: number = htPageCount(root, address, category, keyword, page);
    return new QgPageResult(items, pages > page);
  }
}
