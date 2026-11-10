/**
 * 鬼片站源（https://guipianwu.com）。
 * HTML 页面正则解析：目录（/list/{分类}_{页}.html）/ 搜索（/xml/rss.xml 客户端过滤分页）/
 * 详情（/nv/{id}.html）/ 播放页（var now / m3u8|mp4 直链提取）。
 * 移植自 guoapp provider_guipian.go，正则按 JS 语义改写（i/s 标记）。
 * 封面请求注入 Referer = 站点根 + 全局 UA（Go app_covers.go nativeCoverReferer/download 行为）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgHttp } from '../QgHttp';
import { QgSource } from './QgSource';

const GP_SITE: string = 'https://guipianwu.com';
const GP_UA: string = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
/** 封面请求 UA（Go config_defaults.go 全局 userAgent，封面下载固定使用） */
const GP_COVER_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
const GP_PAGE_SIZE: number = 24;
const GP_TIMEOUT_MS: number = 15000;

const GP_CATEGORIES: QgCategory[] = [
  new QgCategory('3', '恐怖片'),
  new QgCategory('6', '大陆鬼片'),
  new QgCategory('7', '日韩鬼片'),
  new QgCategory('8', '林正英鬼片'),
  new QgCategory('9', '港台鬼片'),
  new QgCategory('10', '泰国鬼片'),
  new QgCategory('11', '欧美鬼片'),
  new QgCategory('31', '剧情片'),
  new QgCategory('12', '国产剧'),
  new QgCategory('13', '美剧'),
  new QgCategory('14', '韩剧'),
  new QgCategory('15', '日剧'),
  new QgCategory('16', '泰剧'),
  new QgCategory('17', '港台剧'),
  new QgCategory('18', '其他剧'),
  new QgCategory('23', '日韩动漫'),
  new QgCategory('24', '国产动漫'),
  new QgCategory('25', '欧美动漫'),
  new QgCategory('26', '港台动漫')
];

const GP_RE_MAIN_LIST: RegExp = /<ul class="row video-list video-film-list[^"]*">(.*?)<\/ul>/is;
const GP_RE_CARD: RegExp = /<a class="video-link" href="\/nv\/(\d+)\.html"[^>]*title="([^"]*)"(.*?)<\/a>/gis;
const GP_RE_COVER: RegExp = /data-(?:original|background)="([^"]+)"/is;
const GP_RE_REMARK: RegExp = /<div class="video-duration">(.*?)<\/div>/is;
const GP_RE_TITLE: RegExp = /<h1 class="media-title[^"]*">(.*?)<\/h1>/is;
const GP_RE_TITLE_TAG: RegExp = /<title>(.*?)<\/title>/is;
const GP_RE_TITLE_BOOK: RegExp = /《(.*?)》.*/g;
const GP_RE_DETAIL_PIC: RegExp = /<div class="detail-img"><img[^>]+src="([^"]+)"/is;
const GP_RE_DETAIL_PIC2: RegExp = /<div class="detail-cover[^"]*"[^>]*data-original="([^"]+)"/is;
const GP_RE_CONTENT: RegExp = /简介：(.*?)<\/li>/is;
const GP_RE_YEAR: RegExp = /年份：<span>(.*?)<\/span>/is;
const GP_RE_DIRECTOR: RegExp = /导演：(.*?)<\/span>/is;
const GP_RE_ACTOR: RegExp = /主演：(.*?)<\/span>/is;
const GP_RE_ANCHOR: RegExp = /<a[^>]*>([^<]+)<\/a>/gis;
const GP_RE_AREA: RegExp = /地区：<span><a[^>]*>(.*?)<\/a>/is;
const GP_RE_STATUS: RegExp = /状态：(.*?)<\/span>/is;
const GP_RE_TAB: RegExp = /<li class="swiper-slide ewave-tab[^"]*" data-target="#(ewave-playlist-\d+)">([^<]+)<\/li>/gis;
const GP_RE_EPISODE: RegExp = /<li><a title='([^']*)' href='([^']+)'/gis;
const GP_RE_NOW: RegExp = /var\s+now\s*=\s*["']([^"']+)["']/is;
const GP_RE_MEDIA_ANY: RegExp = /https?:\/\/[^"'\s<>\\]+\.(?:m3u8|mp4)(?:\?[^"'\s<>\\]*)?/i;
const GP_RE_LEAD_NUM: RegExp = /(\d+)/;
const GP_RE_RSS_ITEM: RegExp = /<item>(.*?)<\/item>/gis;
const GP_RE_RSS_TITLE: RegExp = /<title>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*<\/title>/is;
const GP_RE_RSS_LINK: RegExp = /\/nv\/(\d+)\.html/is;
const GP_RE_TAG: RegExp = /<[^>]+>/g;
const GP_RE_CATEGORY_FORBIDDEN: RegExp = /[\|/\\\x00\r\n]/;

/** HTML 数字实体解码（&#x...; / &#...;） */
function gpDecodeNumericEntities(text: string): string {
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

/** HTML 实体解码（Go guipianUnescape 的常用子集，多轮展开） */
function gpUnescapeHtml(text: string): string {
  let out: string = text;
  for (let round: number = 0; round < 3; round++) {
    let next: string = out;
    next = next.replace(/&amp;/g, '&');
    next = next.replace(/&lt;/g, '<');
    next = next.replace(/&gt;/g, '>');
    next = next.replace(/&quot;/g, '"');
    next = next.replace(/&apos;/g, '\'');
    next = next.replace(/&#39;/g, '\'');
    next = next.replace(/&nbsp;/g, ' ');
    next = gpDecodeNumericEntities(next);
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** Go guipianClean：去标签 + 实体解码 + 全角空格转半角 + 空白折叠 */
function gpClean(text: string): string {
  if (text.length === 0) {
    return '';
  }
  let out: string = text.replace(GP_RE_TAG, '');
  out = gpUnescapeHtml(out);
  out = out.split('\u3000').join(' ');
  return out.trim().split(/\s+/).join(' ');
}

/** Go truncate：超长截断加省略号（按码点计数） */
function gpTruncate(text: string, limit: number): string {
  const trimmed: string = text.trim();
  const chars: string[] = Array.from(trimmed);
  if (chars.length <= limit) {
    return trimmed;
  }
  return `${chars.slice(0, limit).join('')}...`;
}

/** Go guipianNumericID：非空纯数字、长度 ≤ 12、数值 > 0 */
function gpNumericId(value: string): boolean {
  const v: string = value.trim();
  if (v.length === 0 || v.length > 12) {
    return false;
  }
  if (!/^[0-9]+$/.test(v)) {
    return false;
  }
  return Number(v) > 0;
}

/** Go validGuipianCategory：空串合法，其余必须是内置分类 ID */
function gpValidCategory(category: string): boolean {
  if (category.length === 0) {
    return true;
  }
  if (category.length > 16 || GP_RE_CATEGORY_FORBIDDEN.test(category)) {
    return false;
  }
  for (let i: number = 0; i < GP_CATEGORIES.length; i++) {
    if (GP_CATEGORIES[i].id === category) {
      return true;
    }
  }
  return false;
}

/** http/https、主机非空、无 userinfo（Go validNativeCoverURL / isProviderHTTPMediaURL 语义） */
function gpIsHttpUrl(raw: string): boolean {
  const value: string = raw.trim();
  let rest: string = '';
  if (value.startsWith('https://')) {
    rest = value.substring(8);
  } else if (value.startsWith('http://')) {
    rest = value.substring(7);
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

/** Go guipianFixURL：协议相对/站点相对地址补全并校验 */
function gpFixCoverUrl(raw: string): string {
  let url: string = raw.trim();
  if (url.length === 0) {
    return '';
  }
  if (url.startsWith('//')) {
    url = `https:${url}`;
  } else if (url.startsWith('/')) {
    url = `${GP_SITE}${url}`;
  }
  return gpIsHttpUrl(url) ? url : '';
}

/** Go guipianPlayURL：仅接受本站 /play/*.html 播放页地址 */
function gpPlayUrl(href: string): string {
  let url: string = href.trim();
  if (url.length === 0) {
    return '';
  }
  if (!url.startsWith('http')) {
    url = `${GP_SITE}/${url.startsWith('/') ? url.substring(1) : url}`;
  }
  let rest: string = '';
  if (url.startsWith('https://')) {
    rest = url.substring(8);
  } else if (url.startsWith('http://')) {
    rest = url.substring(7);
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
  const authority: string = rest.substring(0, cut);
  if (authority.includes('@')) {
    return '';
  }
  const colon: number = authority.indexOf(':');
  const host: string = (colon >= 0 ? authority.substring(0, colon) : authority).toLowerCase();
  if (host !== 'guipianwu.com' && host !== 'www.guipianwu.com') {
    return '';
  }
  if (slash < 0) {
    return '';
  }
  let pathEnd: number = rest.length;
  const q2: number = rest.indexOf('?');
  if (q2 >= 0 && q2 < pathEnd) {
    pathEnd = q2;
  }
  const h2: number = rest.indexOf('#');
  if (h2 >= 0 && h2 < pathEnd) {
    pathEnd = h2;
  }
  const path: string = rest.substring(slash, pathEnd);
  if (!path.toLowerCase().endsWith('.html') || !path.includes('/play/')) {
    return '';
  }
  return url;
}

/** Go guipianExtractField：正则取首个捕获组并清洗 */
function gpExtractField(body: string, re: RegExp): string {
  const match: RegExpExecArray | null = re.exec(body);
  if (match !== null) {
    return gpClean(match[1]);
  }
  return '';
}

/** Go guipianActors：主演字段的锚点逐个提取，无锚点时整体清洗 */
function gpActors(body: string): string {
  const match: RegExpExecArray | null = GP_RE_ACTOR.exec(body);
  if (match === null) {
    return '';
  }
  const names: string[] = [];
  GP_RE_ANCHOR.lastIndex = 0;
  let anchor: RegExpExecArray | null = GP_RE_ANCHOR.exec(match[1]);
  while (anchor !== null) {
    const name: string = gpClean(anchor[1]);
    if (name.length > 0) {
      names.push(name);
    }
    anchor = GP_RE_ANCHOR.exec(match[1]);
  }
  if (names.length === 0) {
    return gpClean(match[1]);
  }
  return names.join(' ');
}

/** Go parseGuipianCards：列表页卡片解析（目录与列表页共用） */
function gpParseCards(body: string): QgDrama[] {
  let segment: string = body;
  const listMatch: RegExpExecArray | null = GP_RE_MAIN_LIST.exec(body);
  if (listMatch !== null) {
    segment = listMatch[1];
  }
  const items: QgDrama[] = [];
  const seen: Record<string, boolean> = {};
  GP_RE_CARD.lastIndex = 0;
  let match: RegExpExecArray | null = GP_RE_CARD.exec(segment);
  while (match !== null) {
    const id: string = match[1];
    const title: string = gpClean(match[2]);
    if (!gpNumericId(id) || seen[id] === true || title.length === 0) {
      match = GP_RE_CARD.exec(segment);
      continue;
    }
    seen[id] = true;
    const chunk: string = match[3];
    let cover: string = '';
    const coverMatch: RegExpExecArray | null = GP_RE_COVER.exec(chunk);
    if (coverMatch !== null) {
      cover = gpFixCoverUrl(coverMatch[1]);
    }
    let remark: string = '';
    const remarkMatch: RegExpExecArray | null = GP_RE_REMARK.exec(chunk);
    if (remarkMatch !== null) {
      remark = gpClean(remarkMatch[1]);
    }
    const drama: QgDrama = new QgDrama(`guipian:${id}`, gpTruncate(title, 512), '影视');
    drama.sourceId = 'guipian';
    drama.cover = cover;
    drama.remark = gpTruncate(remark, 64);
    items.push(drama);
    if (items.length > 500) {
      break;
    }
    match = GP_RE_CARD.exec(segment);
  }
  return items;
}

/** Go guipianPageCount：分页链接最大页码推断是否还有下一页，退化按每页条数判断 */
function gpHasMore(body: string, category: string, page: number, count: number): boolean {
  const re: RegExp = new RegExp(`/list/${category}_(\\d+)\\.html`, 'gis');
  let maxPage: number = page;
  let match: RegExpExecArray | null = re.exec(body);
  while (match !== null) {
    const value: number = Number(match[1]);
    if (!Number.isNaN(value) && value > maxPage && value < 100000) {
      maxPage = value;
    }
    match = re.exec(body);
  }
  if (maxPage > page) {
    return true;
  }
  return count >= GP_PAGE_SIZE;
}

/** 详情标签追加（Go addTag：去重、码点 ≤ 48、总数 ≤ 16） */
function gpAddTag(tags: string[], seen: Record<string, boolean>, value: string): void {
  const v: string = value.trim();
  if (v.length === 0 || seen[v] === true || Array.from(v).length > 48 || tags.length >= 16) {
    return;
  }
  seen[v] = true;
  tags.push(v);
}

/** Go guipianPickPlaylist：解析全部播放线路，取分集最多的一条并按集号稳定排序 */
function gpPickPlaylist(body: string): QgEpisode[] {
  const tabs: RegExpExecArray[] = [];
  GP_RE_TAB.lastIndex = 0;
  let tabMatch: RegExpExecArray | null = GP_RE_TAB.exec(body);
  while (tabMatch !== null) {
    tabs.push(tabMatch);
    tabMatch = GP_RE_TAB.exec(body);
  }
  if (tabs.length === 0) {
    throw new Error('鬼片未找到可用播放线路');
  }
  let best: QgEpisode[] = [];
  const seenAnchor: Record<string, boolean> = {};
  for (let i: number = 0; i < tabs.length; i++) {
    const anchor: string = tabs[i][1];
    if (anchor.length === 0 || seenAnchor[anchor] === true) {
      continue;
    }
    seenAnchor[anchor] = true;
    const marker: string = `id="${anchor}"`;
    const start: number = body.indexOf(marker);
    if (start < 0) {
      continue;
    }
    let segment: string = body.substring(start + marker.length);
    const endSlide: number = segment.indexOf('<div class="playlist-slide');
    const endSection: number = segment.indexOf('</section>');
    if (endSlide >= 0) {
      segment = segment.substring(0, endSlide);
    } else if (endSection >= 0) {
      segment = segment.substring(0, endSection);
    }
    const episodes: QgEpisode[] = [];
    const seenPath: Record<string, boolean> = {};
    let index: number = 0;
    GP_RE_EPISODE.lastIndex = 0;
    let ep: RegExpExecArray | null = GP_RE_EPISODE.exec(segment);
    while (ep !== null) {
      index++;
      const epTitle: string = gpClean(ep[1]);
      const href: string = ep[2].trim();
      const playUrl: string = href.length > 0 ? gpPlayUrl(href) : '';
      if (playUrl.length === 0 || seenPath[playUrl] === true) {
        ep = GP_RE_EPISODE.exec(segment);
        continue;
      }
      seenPath[playUrl] = true;
      let order: number = index;
      const numMatch: RegExpMatchArray | null = epTitle.match(GP_RE_LEAD_NUM);
      if (numMatch !== null) {
        const parsed: number = Number(numMatch[1]);
        if (parsed > 0 && parsed <= 100000) {
          order = parsed;
        }
      }
      const title: string = epTitle.length > 0 ? epTitle : `第 ${order} 集`;
      episodes.push(new QgEpisode(playUrl, gpTruncate(title, 128), order));
      ep = GP_RE_EPISODE.exec(segment);
    }
    if (episodes.length > best.length) {
      best = episodes;
    }
  }
  if (best.length === 0) {
    throw new Error('鬼片线路暂无可播放分集');
  }
  best.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
  return best;
}

export class GuipianSource extends QgSource {
  constructor() {
    super('guipian', '鬼片');
  }

  categories(): QgCategory[] {
    const all: QgCategory[] = [];
    for (let i: number = 0; i < GP_CATEGORIES.length; i++) {
      all.push(new QgCategory(GP_CATEGORIES[i].id, GP_CATEGORIES[i].label));
    }
    return all;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 100000) {
      throw new Error('鬼片目录页码无效');
    }
    if (!gpValidCategory(categoryId)) {
      throw new Error('鬼片内容分类无效');
    }
    let category: string = categoryId;
    if (category.length === 0) {
      category = GP_CATEGORIES[0].id;
    }
    const path: string = page > 1 ? `/list/${category}_${page}.html` : `/list/${category}.html`;
    const body: string = await this.gpGet(path);
    const items: QgDrama[] = gpParseCards(body);
    if (items.length === 0) {
      return new QgPageResult([], false);
    }
    return new QgPageResult(items, gpHasMore(body, category, page, items.length));
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    const query: string = keyword.trim();
    if (query.length === 0 || query.length > 256) {
      throw new Error('鬼片搜索关键词无效');
    }
    if (page < 1 || page > 100000) {
      throw new Error('鬼片搜索页码无效');
    }
    const body: string = await this.gpGet('/xml/rss.xml');
    const needle: string = query.toLowerCase();
    const matched: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    GP_RE_RSS_ITEM.lastIndex = 0;
    let item: RegExpExecArray | null = GP_RE_RSS_ITEM.exec(body);
    while (item !== null) {
      const segment: string = item[1];
      const titleMatch: RegExpExecArray | null = GP_RE_RSS_TITLE.exec(segment);
      const idMatch: RegExpExecArray | null = GP_RE_RSS_LINK.exec(segment);
      if (titleMatch !== null && idMatch !== null) {
        const title: string = gpClean(titleMatch[1]);
        const id: string = idMatch[1];
        if (title.length > 0 && gpNumericId(id) && seen[id] !== true &&
          title.toLowerCase().includes(needle)) {
          seen[id] = true;
          const drama: QgDrama = new QgDrama(`guipian:${id}`, gpTruncate(title, 512), '影视');
          drama.sourceId = 'guipian';
          matched.push(drama);
        }
      }
      item = GP_RE_RSS_ITEM.exec(body);
    }
    const start: number = (page - 1) * GP_PAGE_SIZE;
    if (start >= matched.length) {
      return new QgPageResult([], false);
    }
    const end: number = Math.min(start + GP_PAGE_SIZE, matched.length);
    return new QgPageResult(matched.slice(start, end), end < matched.length);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceId: string = (dramaId.startsWith('guipian:') ?
      dramaId.substring('guipian:'.length) : dramaId).trim();
    if (!gpNumericId(sourceId)) {
      throw new Error('鬼片视频 ID 无效');
    }
    const body: string = await this.gpGet(`/nv/${sourceId}.html`);
    let name: string = gpExtractField(body, GP_RE_TITLE);
    if (name.length === 0) {
      const tagMatch: RegExpExecArray | null = GP_RE_TITLE_TAG.exec(body);
      if (tagMatch !== null) {
        const raw: string = gpClean(tagMatch[1]);
        if (raw.includes('提示信息') || raw.includes('影片不存在')) {
          throw new Error('鬼片影片不存在');
        }
        name = raw.replace(GP_RE_TITLE_BOOK, '$1').trim();
      }
    }
    if (name.length === 0) {
      throw new Error('鬼片详情缺少视频名称');
    }
    let cover: string = '';
    const picMatch: RegExpExecArray | null = GP_RE_DETAIL_PIC.exec(body);
    if (picMatch !== null) {
      cover = gpFixCoverUrl(picMatch[1]);
    }
    if (cover.length === 0) {
      const pic2Match: RegExpExecArray | null = GP_RE_DETAIL_PIC2.exec(body);
      if (pic2Match !== null) {
        cover = gpFixCoverUrl(pic2Match[1]);
      }
    }
    const description: string = gpExtractField(body, GP_RE_CONTENT);
    const year: string = gpExtractField(body, GP_RE_YEAR);
    const director: string = gpExtractField(body, GP_RE_DIRECTOR);
    const area: string = gpExtractField(body, GP_RE_AREA);
    const status: string = gpExtractField(body, GP_RE_STATUS);
    const actors: string = gpActors(body);

    const drama: QgDrama = new QgDrama(`guipian:${sourceId}`, gpTruncate(name, 512), '影视');
    drama.sourceId = 'guipian';
    drama.intro = gpTruncate(description, 12000);
    drama.cover = cover;
    drama.remark = gpTruncate(status, 64);
    drama.finished = status.includes('完结');

    const tags: string[] = [];
    const seenTag: Record<string, boolean> = {};
    if (year.length > 0) {
      gpAddTag(tags, seenTag, `${year}年`);
    }
    if (area.length > 0) {
      gpAddTag(tags, seenTag, area);
    }
    if (director.length > 0) {
      gpAddTag(tags, seenTag, `导演 ${gpTruncate(director, 32)}`);
    }
    if (actors.length > 0) {
      gpAddTag(tags, seenTag, `主演 ${gpTruncate(actors, 48)}`);
    }
    drama.tags = tags;

    const episodes: QgEpisode[] = gpPickPlaylist(body);
    drama.episodeCount = episodes.length;
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const sourceId: string = (dramaId.startsWith('guipian:') ?
      dramaId.substring('guipian:'.length) : dramaId).trim();
    if (!gpNumericId(sourceId)) {
      throw new Error('鬼片播放分集信息无效，请刷新详情');
    }
    const playUrl: string = episodeId.trim();
    if (gpPlayUrl(playUrl).length === 0) {
      throw new Error('鬼片播放页地址无效');
    }
    const body: string = await this.gpGet(playUrl);
    let address: string = '';
    const nowMatch: RegExpExecArray | null = GP_RE_NOW.exec(body);
    if (nowMatch !== null) {
      address = nowMatch[1].trim();
    }
    if (address.length === 0) {
      const mediaMatch: RegExpExecArray | null = GP_RE_MEDIA_ANY.exec(body);
      if (mediaMatch !== null) {
        address = mediaMatch[0];
      }
    }
    if (address.length === 0) {
      throw new Error('鬼片该集暂无可用播放地址');
    }
    if (address.startsWith('//')) {
      address = `https:${address}`;
    }
    if (!gpIsHttpUrl(address)) {
      throw new Error('鬼片播放地址无效');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${GP_SITE}/`;
    info.headers = { 'User-Agent': GP_UA, 'Referer': info.referer };
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return { 'User-Agent': GP_COVER_UA, 'Referer': `${GP_SITE}/` };
  }

  /** 页面抓取：统一站源 UA + Referer + Accept-Language（Go guipianGet/fetchProviderText） */
  private async gpGet(path: string): Promise<string> {
    const address: string = path.startsWith('http') ? path : `${GP_SITE}${path}`;
    const headers: Record<string, string> = {
      'User-Agent': GP_UA,
      'Referer': `${GP_SITE}/`,
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    return QgHttp.getText(address, headers, GP_TIMEOUT_MS);
  }
}
