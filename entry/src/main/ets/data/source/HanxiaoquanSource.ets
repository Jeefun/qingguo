/**
 * 韩小圈站源（https://www.jennyhow.com）。
 * HTML 页面正则解析：目录 / 搜索 / 详情 / 播放页 m3u8 提取。
 * 移植自 guoapp provider_hanxiaoquan.go，正则按 JS 语义改写（i/s 标记）。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgHttp } from '../QgHttp';
import { QgSource } from './QgSource';

const SITE: string = 'https://www.jennyhow.com';
const UA: string = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const PAGE_SIZE: number = 24;
const TIMEOUT: number = 15000;

const RE_CARD_PIC: RegExp = /<a href="\/hanxiaoquan\/(\d+)\.html"[^>]*title="([^"]*)"[^>]*class="module-item-pic"/gis;
const RE_CARD_IMG: RegExp = /<img[^>]*data-src="([^"]+)"/is;
const RE_CARD_TEXT: RegExp = /<a href="\/hanxiaoquan\/\d+\.html"[^>]*class="module-item-title"[^>]*>([^<]*)<\/a>/is;
const RE_CARD_NOTE: RegExp = /class="module-item-text"[^>]*>([^<]*)</is;
const RE_AD: RegExp = /@[^@]{1,60}@/g;
const RE_TITLE: RegExp = /<h1 class="page-title"[^>]*>(.*?)<\/h1>/is;
const RE_OG_IMAGE: RegExp = /property="og:image"\s+content="([^"]+)"/is;
const RE_COVER_SRC: RegExp = /<div class="video-cover">.*?<img[^>]*data-src="([^"]+)"/is;
const RE_INFO_ITEM: RegExp = /<span class="video-info-itemtitle">([^<]*)<\/span>\s*<div class="video-info-item[^"]*">(.*?)<\/div>/gis;
const RE_LINE_TAB: RegExp = /href="#playlist(\d+)"[^>]*>\s*<i[^>]*><\/i>\s*([^<]+)/gis;
const RE_EPISODES: RegExp = /<a title="([^"]*)" href="(\/play\/\d+-\d+-\d+\.html)"/gis;
const RE_NOW: RegExp = /var\s+now\s*=\s*["']([^"']+)["']/is;
const RE_MEDIA_ANY: RegExp = /https?:\/\/[^"'\s<>\\]+\.(?:m3u8|mp4)(?:\?[^"'\s<>\\]*)?/is;
const RE_TAG: RegExp = /<[^>]+>/g;
const RE_LEAD_NUM: RegExp = /(\d+)/;

/** HTML 实体解码（对应 Go guipianUnescape 的常用子集） */
function unescapeHtml(text: string): string {
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
    next = decodeNumericEntities(next);
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

function decodeNumericEntities(text: string): string {
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

/** 清洗 HTML 片段文本 */
function cleanText(text: string): string {
  if (text.length === 0) {
    return '';
  }
  let out: string = text.replace(RE_TAG, '');
  out = unescapeHtml(out);
  out = out.split('\u3000').join(' ');
  return out.trim().split(/\s+/).join(' ');
}

/** 修正相对/协议相对 URL */
function fixUrl(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed.length === 0) {
    return '';
  }
  let url: string = trimmed;
  if (url.startsWith('//')) {
    url = `https:${url}`;
  } else if (url.startsWith('/')) {
    url = `${SITE}${url}`;
  }
  return /^https?:\/\/\S+$/.test(url) ? url : '';
}

/** 播放页 URL 校验（仅本站 /play/*.html） */
function playUrlOf(href: string): string {
  let url: string = href.trim();
  if (url.length === 0) {
    return '';
  }
  if (!url.startsWith('http')) {
    url = `${SITE}/${url.startsWith('/') ? url.substring(1) : url}`;
  }
  if (!url.startsWith(`${SITE}/play/`) || !url.toLowerCase().endsWith('.html')) {
    return '';
  }
  return url;
}

function numericId(value: string): boolean {
  const v: string = value.trim();
  if (v.length === 0 || v.length > 12) {
    return false;
  }
  return /^[0-9]+$/.test(v);
}

export class HanxiaoquanSource extends QgSource {
  constructor() {
    super('hanxiaoquan', '韩小圈');
  }

  categories(): QgCategory[] {
    return [
      new QgCategory('1', '最新韩剧'),
      new QgCategory('2', '韩国电影'),
      new QgCategory('3', '韩国综艺'),
      new QgCategory('4', '韩国动漫')
    ];
  }

  private headers(): Record<string, string> {
    return {
      'User-Agent': UA,
      'Referer': `${SITE}/`
    };
  }

  private async get(path: string): Promise<string> {
    return QgHttp.getText(path.startsWith('http') ? path : `${SITE}${path}`,
      this.headers(), TIMEOUT);
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 100000) {
      throw new Error('韩小圈目录页码无效');
    }
    let cat: string = categoryId;
    if (cat.length === 0) {
      cat = '1';
    }
    if (!['1', '2', '3', '4'].includes(cat)) {
      throw new Error('韩小圈内容分类无效');
    }
    const path: string = page > 1 ? `/hxq/${cat}-${page}.html` : `/hxq/${cat}.html`;
    const body: string = await this.get(path);
    const items: QgDrama[] = HanxiaoquanSource.parseCards(body);
    if (items.length === 0) {
      return new QgPageResult([], false);
    }
    return new QgPageResult(items, HanxiaoquanSource.hasMore(body, cat, page, items.length));
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    const kw: string = keyword.trim();
    if (kw.length === 0 || kw.length > 256) {
      throw new Error('韩小圈搜索关键词无效');
    }
    if (page > 1) {
      return new QgPageResult([], false);
    }
    const body: string = await this.get(`/search.php?searchword=${encodeURIComponent(kw)}`);
    return new QgPageResult(HanxiaoquanSource.parseCards(body), false);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceId: string = dramaId.startsWith('hanxiaoquan:') ?
      dramaId.substring('hanxiaoquan:'.length) : dramaId;
    if (!numericId(sourceId)) {
      throw new Error('韩小圈视频 ID 无效');
    }
    const body: string = await this.get(`/hanxiaoquan/${sourceId}.html`);
    const titleMatch: RegExpMatchArray | null = body.match(RE_TITLE);
    const name: string = titleMatch !== null ? cleanText(titleMatch[1]) : '';
    if (name.length === 0) {
      throw new Error('韩小圈详情缺少视频名称');
    }
    let cover: string = '';
    const ogMatch: RegExpMatchArray | null = body.match(RE_OG_IMAGE);
    if (ogMatch !== null) {
      cover = fixUrl(ogMatch[1]);
    }
    if (cover.length === 0) {
      const coverMatch: RegExpMatchArray | null = body.match(RE_COVER_SRC);
      if (coverMatch !== null) {
        cover = fixUrl(coverMatch[1]);
      }
    }
    const fields: Record<string, string> = HanxiaoquanSource.infoFields(body);
    let description: string = fields['剧情'] !== undefined ? fields['剧情'] : '';
    if (description.length === 0 && fields['简介'] !== undefined) {
      description = fields['简介'];
    }
    description = description.replace(RE_AD, '');

    const drama: QgDrama = new QgDrama(`hanxiaoquan:${sourceId}`, name, '韩剧');
    drama.sourceId = 'hanxiaoquan';
    drama.cover = cover;
    drama.intro = description;
    const update: string = fields['更新'] !== undefined ? fields['更新'] : '';
    const status: string = fields['状态'] !== undefined ? fields['状态'] : '';
    drama.remark = (update.length > 0 ? update : status).substring(0, 64);
    const tags: string[] = [];
    if (fields['上映'] !== undefined && fields['上映'].length > 0) {
      tags.push(`${fields['上映']}年`);
    }
    if (fields['导演'] !== undefined && fields['导演'].length > 0) {
      tags.push(`导演 ${fields['导演'].substring(0, 32)}`);
    }
    if (fields['主演'] !== undefined && fields['主演'].length > 0) {
      tags.push(`主演 ${fields['主演'].substring(0, 48)}`);
    }
    drama.tags = tags;
    drama.finished = drama.remark.includes('完结');

    const episodes: QgEpisode[] = HanxiaoquanSource.pickEpisodes(body);
    if (episodes.length === 0) {
      throw new Error('韩小圈暂无可播放分集');
    }
    drama.episodeCount = episodes.length;
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const pageUrl: string = playUrlOf(episodeId);
    if (pageUrl.length === 0) {
      throw new Error('韩小圈播放页地址无效');
    }
    const body: string = await this.get(pageUrl);
    let address: string = '';
    const nowMatch: RegExpMatchArray | null = body.match(RE_NOW);
    if (nowMatch !== null) {
      address = nowMatch[1].trim();
    }
    if (address.length === 0) {
      const mediaMatch: RegExpMatchArray | null = body.match(RE_MEDIA_ANY);
      if (mediaMatch !== null) {
        address = mediaMatch[0];
      }
    }
    if (address.length === 0) {
      throw new Error('韩小圈该集暂无可用播放地址');
    }
    if (address.startsWith('//')) {
      address = `https:${address}`;
    }
    if (!/^https?:\/\/\S+$/.test(address)) {
      throw new Error('韩小圈播放地址无效');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = address;
    info.referer = `${SITE}/`;
    info.headers = this.headers();
    return info;
  }

  /** 解析卡片列表（目录与搜索共用） */
  private static parseCards(body: string): QgDrama[] {
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    RE_CARD_PIC.lastIndex = 0;
    let match: RegExpExecArray | null = RE_CARD_PIC.exec(body);
    while (match !== null) {
      const id: string = match[1];
      let title: string = cleanText(match[2]);
      if (!numericId(id) || seen[id] === true) {
        match = RE_CARD_PIC.exec(body);
        continue;
      }
      const chunk: string = body.substring(match.index, match.index + 600);
      let cover: string = '';
      const imgMatch: RegExpMatchArray | null = chunk.match(RE_CARD_IMG);
      if (imgMatch !== null) {
        cover = fixUrl(imgMatch[1]);
      }
      let note: string = '';
      const noteMatch: RegExpMatchArray | null = chunk.match(RE_CARD_NOTE);
      if (noteMatch !== null) {
        note = cleanText(noteMatch[1]);
      }
      if (title.length === 0) {
        const textMatch: RegExpMatchArray | null = chunk.match(RE_CARD_TEXT);
        if (textMatch !== null) {
          title = cleanText(textMatch[1]);
        }
      }
      if (title.length > 0) {
        seen[id] = true;
        const drama: QgDrama = new QgDrama(`hanxiaoquan:${id}`, title.substring(0, 512), '韩剧');
        drama.sourceId = 'hanxiaoquan';
        drama.cover = cover;
        drama.remark = note.substring(0, 64);
        drama.finished = note.includes('完结');
        items.push(drama);
      }
      if (items.length > 500) {
        break;
      }
      match = RE_CARD_PIC.exec(body);
    }
    return items;
  }

  /** 是否还有下一页：页面分页链接最大页码，退化按每页条数判断 */
  private static hasMore(body: string, category: string, page: number, count: number): boolean {
    const re: RegExp = new RegExp(`/hxq/${category}-(\\d+)\\.html`, 'gis');
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
    return count >= PAGE_SIZE;
  }

  /** 详情字段（导演/主演/剧情...） */
  private static infoFields(body: string): Record<string, string> {
    const fields: Record<string, string> = {};
    RE_INFO_ITEM.lastIndex = 0;
    let match: RegExpExecArray | null = RE_INFO_ITEM.exec(body);
    while (match !== null) {
      let label: string = match[1].trim();
      if (label.endsWith('：')) {
        label = label.substring(0, label.length - 1);
      }
      label = label.trim();
      const value: string = cleanText(match[2]);
      if (label.length > 0 && value.length > 0 &&
        (fields[label] === undefined || fields[label].length === 0)) {
        fields[label] = value;
      }
      match = RE_INFO_ITEM.exec(body);
    }
    return fields;
  }

  /** 选择分集最多的播放线路 */
  private static pickEpisodes(body: string): QgEpisode[] {
    const lineIds: string[] = [];
    const lineNames: Record<string, string> = {};
    RE_LINE_TAB.lastIndex = 0;
    let tabMatch: RegExpExecArray | null = RE_LINE_TAB.exec(body);
    while (tabMatch !== null) {
      const lineId: string = tabMatch[1];
      if (lineNames[lineId] === undefined) {
        lineNames[lineId] = tabMatch[2].trim();
        lineIds.push(lineId);
      }
      tabMatch = RE_LINE_TAB.exec(body);
    }
    lineIds.sort((a: string, b: string): number => a < b ? -1 : (a > b ? 1 : 0));
    const candidates: string[] = [body];
    for (let i: number = 0; i < lineIds.length; i++) {
      const marker: string = `id="playlist${lineIds[i]}"`;
      const start: number = body.indexOf(marker);
      if (start < 0) {
        continue;
      }
      let segment: string = body.substring(start + marker.length);
      const end: number = segment.indexOf('id="playlist');
      const footer: number = segment.indexOf('class="module-footer"');
      if (end >= 0) {
        segment = segment.substring(0, end);
      } else if (footer >= 0) {
        segment = segment.substring(0, footer);
      }
      candidates.push(segment);
    }
    let best: QgEpisode[] = [];
    for (let c: number = 0; c < candidates.length; c++) {
      const episodes: QgEpisode[] = [];
      const seenPath: Record<string, boolean> = {};
      const segment: string = candidates[c];
      RE_EPISODES.lastIndex = 0;
      let epMatch: RegExpExecArray | null = RE_EPISODES.exec(segment);
      let index: number = 0;
      while (epMatch !== null) {
        index++;
        const epTitle: string = cleanText(epMatch[1]);
        const playUrl: string = playUrlOf(epMatch[2]);
        if (playUrl.length === 0 || seenPath[playUrl] === true) {
          epMatch = RE_EPISODES.exec(segment);
          continue;
        }
        seenPath[playUrl] = true;
        let order: number = index;
        const numMatch: RegExpMatchArray | null = epTitle.match(RE_LEAD_NUM);
        if (numMatch !== null) {
          const parsed: number = Number(numMatch[1]);
          if (parsed > 0 && parsed <= 100000) {
            order = parsed;
          }
        }
        episodes.push(new QgEpisode(playUrl,
          (epTitle.length > 0 ? epTitle : `第 ${order} 集`).substring(0, 128), order));
        epMatch = RE_EPISODES.exec(segment);
      }
      if (episodes.length > best.length) {
        best = episodes;
      }
    }
    best.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    return best;
  }
}
