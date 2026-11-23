/**
 * 青空次元站源（https://www.sorani.net，API https://api.sorani.cc/sorani-cms/api）。
 * 本期提供 目录/搜索/详情；播放需网页滑块验证码登录，返回明确错误。
 * 移植自 guoapp provider_sorani.go。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgHttp } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const SITE: string = 'https://www.sorani.net';
const API: string = 'https://api.sorani.cc/sorani-cms/api';
const UA: string = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const PAGE_SIZE: number = 24;
const TIMEOUT: number = 15000;

function headers(): Record<string, string> {
  return {
    'User-Agent': UA,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': `${SITE}/`,
    'Origin': SITE
  };
}

function numericId(value: string): boolean {
  const v: string = value.trim();
  if (v.length === 0 || v.length > 64) {
    return false;
  }
  const n: number = Number(v);
  return !Number.isNaN(n) && n > 0 && /^[0-9]+$/.test(v);
}

function validCategory(category: string): boolean {
  if (category.length === 0) {
    return true;
  }
  if (category.length > 128 || /[\|\/\\\x00\r\n]/.test(category)) {
    return false;
  }
  return ['1', '2', '5'].includes(category);
}

/** 封面地址：相对路径补站点前缀 */
function coverOf(value: string): string {
  const v: string = value.trim();
  if (v.length === 0) {
    return '';
  }
  if (v.startsWith('http://') || v.startsWith('https://')) {
    return v;
  }
  if (v.startsWith('//')) {
    return `https:${v}`;
  }
  if (v.startsWith('/')) {
    return `${SITE}${v}`;
  }
  return `${SITE}/${v}`;
}

function truncate(text: string, limit: number): string {
  return text.length > limit ? text.substring(0, limit) : text;
}

/** 行记录 → QgDrama（字段映射见 provider_sorani.go soraniDramaFromMap） */
function dramaFromMap(row: Record<string, Object> | null): QgDrama | null {
  if (row === null) {
    return null;
  }
  const id: string = QgJson.pick(row, ['id', 'videoId']);
  const title: string = QgJson.pick(row, ['title', 'name', 'videoTitle']);
  if (!numericId(id) || title.trim().length === 0) {
    return null;
  }
  const description: string = QgJson.pick(row, ['summary', 'description', 'intro', 'desc']);
  let cover: string = '';
  const coverKeys: string[] = ['cover', 'coverLarge', 'coverSmall', 'coverThumb', 'backgroundImage'];
  for (let i: number = 0; i < coverKeys.length && cover.length === 0; i++) {
    const value: string = QgJson.str(row[coverKeys[i]]);
    if (value.trim().length > 0) {
      cover = coverOf(value);
    }
  }
  let episodes: number = 0;
  const countKeys: string[] = ['episodeCount', 'totalEpisode', 'episodes', 'total'];
  for (let i: number = 0; i < countKeys.length; i++) {
    const value: Object | undefined = row[countKeys[i]];
    if (value === undefined) {
      continue;
    }
    const count: number = Number(QgJson.str(value).trim());
    if (!Number.isNaN(count) && count > episodes && count <= 100000) {
      episodes = count;
    }
  }
  let category: string = QgJson.pick(row, ['categoryName', 'category']);
  const tags: string[] = [];
  const seen: Record<string, boolean> = {};
  const tagKeys: string[] = ['tags', 'tagList', 'categoryTags'];
  for (let g: number = 0; g < tagKeys.length; g++) {
    const values: Object[] = QgJson.fieldArr(row, tagKeys[g]);
    for (let j: number = 0; j < values.length; j++) {
      const v: string = QgJson.str(values[j]).trim();
      if (v.length > 0 && v.length <= 48 && seen[v] !== true && tags.length < 16) {
        seen[v] = true;
        tags.push(v);
      }
    }
  }
  const alias: string = QgJson.pick(row, ['alias']);
  if (alias.length > 0) {
    const v: string = truncate(alias, 48);
    if (seen[v] !== true && tags.length < 16) {
      seen[v] = true;
      tags.push(v);
    }
  }
  const area: string = QgJson.pick(row, ['area']);
  if (area.length > 0) {
    const v: string = truncate(area, 48);
    if (seen[v] !== true && tags.length < 16) {
      seen[v] = true;
      tags.push(v);
    }
  }
  const year: string = QgJson.pick(row, ['year', 'publishDate']).trim();
  if (year.length >= 4) {
    const digits: string = year.substring(0, 4);
    if (/^[0-9]+$/.test(digits)) {
      const yearNum: number = Number(digits);
      if (yearNum >= 1900 && yearNum <= 2200) {
        const v: string = `${digits}年`;
        if (seen[v] !== true && tags.length < 16) {
          seen[v] = true;
          tags.push(v);
        }
      }
    }
  }
  const actor: string = QgJson.pick(row, ['actors', 'actor']);
  if (actor.length > 0) {
    const v: string = `声优 ${truncate(actor, 32)}`;
    if (seen[v] !== true && tags.length < 16) {
      seen[v] = true;
      tags.push(v);
    }
  }
  if (category.length === 0) {
    category = '番剧';
  }
  const drama: QgDrama = new QgDrama(`sorani:${id}`, truncate(title, 256), category);
  drama.sourceId = 'sorani';
  drama.intro = truncate(description, 12000);
  drama.cover = cover;
  drama.episodeCount = episodes;
  drama.tags = tags;
  drama.finished = true;
  drama.remark = episodes > 0 ? `共${episodes}话` : '';
  return drama;
}

export class SoraniSource extends QgSource {
  constructor() {
    super('sorani', '青空次元');
  }

  categories(): QgCategory[] {
    return [
      new QgCategory('1', 'TV番剧'),
      new QgCategory('2', '剧场动画'),
      new QgCategory('5', '特摄剧场')
    ];
  }

  /** GET API 并解析 JSON（含 code!=200 错误与 data 解包） */
  private async call(route: string, query: string): Promise<Object> {
    const text: string = await QgHttp.getText(`${API}${route}${query}`, headers(), TIMEOUT, this.id);
    const root: Record<string, Object> | null = QgJson.obj(QgJson.parse(text));
    if (root === null) {
      throw new Error('青空次元返回的数据格式无效');
    }
    const code: string = QgJson.str(root['code']);
    if (code.length > 0 && code !== '200') {
      const message: string = QgJson.pick(root, ['message', 'msg']);
      throw new Error(`青空次元接口错误：${message.length > 0 ? message : `错误码 ${code}`}`);
    }
    const data: Object | undefined = root['data'];
    return data !== undefined ? data : root;
  }

  /** 载荷 → 记录数组 */
  private static recordList(payload: Object): Object[] {
    if (Array.isArray(payload)) {
      return payload as Object[];
    }
    const map: Record<string, Object> | null = QgJson.obj(payload);
    if (map !== null) {
      const keys: string[] = ['records', 'list', 'items', 'rows'];
      for (let i: number = 0; i < keys.length; i++) {
        const value: Object | undefined = map[keys[i]];
        if (Array.isArray(value)) {
          return value as Object[];
        }
      }
    }
    return [];
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return this.fetchPage(categoryId, '', page);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    return this.fetchPage('', keyword, page);
  }

  private async fetchPage(category: string, keyword: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 100000) {
      throw new Error('青空次元目录页码无效');
    }
    if (!validCategory(category)) {
      throw new Error('青空次元内容分类无效');
    }
    if (keyword.length > 256) {
      throw new Error('青空次元搜索关键词过长');
    }
    let route: string = '/video';
    let query: string = `page=${page}&size=${PAGE_SIZE}`;
    if (keyword.length > 0) {
      route = '/video/search';
      query += `&keyword=${encodeURIComponent(keyword)}`;
    } else if (category.length > 0) {
      query += `&categoryId=${encodeURIComponent(category)}`;
    }
    const payload: Object = await this.call(route, query);
    const rows: Object[] = SoraniSource.recordList(payload);
    if (rows.length > 500) {
      throw new Error('青空次元目录数据格式无效');
    }
    let hasMore: boolean = rows.length >= PAGE_SIZE;
    const meta: Record<string, Object> | null = QgJson.obj(payload);
    if (meta !== null) {
      const totalValue: Object | undefined = meta['total'];
      if (totalValue !== undefined) {
        const total: number = Number(QgJson.str(totalValue).trim());
        if (!Number.isNaN(total) && total >= 0 && total <= 100000000) {
          hasMore = page * PAGE_SIZE < total;
        }
      }
    }
    if (hasMore && rows.length === 0) {
      throw new Error('青空次元未返回应有的目录页，请重试');
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = dramaFromMap(QgJson.obj(rows[i]));
      if (drama === null) {
        throw new Error('青空次元返回的剧集信息不完整');
      }
      if (seen[drama.id] === true) {
        throw new Error('青空次元目录包含重复剧集，请重试');
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return new QgPageResult(items, hasMore);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const sourceId: string = dramaId.startsWith('sorani:') ?
      dramaId.substring('sorani:'.length) : dramaId;
    if (!numericId(sourceId)) {
      throw new Error('青空次元剧集 ID 无效');
    }
    const payload: Object = await this.call(`/video/${encodeURIComponent(sourceId)}`, '');
    const row: Record<string, Object> | null = QgJson.obj(payload);
    if (row === null) {
      throw new Error('青空次元详情数据格式无效');
    }
    const drama: QgDrama | null = dramaFromMap(row);
    if (drama === null) {
      throw new Error('青空次元返回的剧集信息不完整');
    }
    if (drama.id !== `sorani:${sourceId}`) {
      throw new Error('青空次元详情与请求剧集不符');
    }
    const episodesValue: Object | undefined = row['episodes'];
    if (!Array.isArray(episodesValue)) {
      throw new Error('青空次元分集目录格式无效');
    }
    const rows: Object[] = episodesValue as Object[];
    if (rows.length > 10000) {
      throw new Error('青空次元分集目录格式无效');
    }
    const episodes: QgEpisode[] = [];
    const seenIds: Record<string, boolean> = {};
    const seenOrders: Record<string, boolean> = {};
    for (let index: number = 0; index < rows.length; index++) {
      const episode: Record<string, Object> | null = QgJson.obj(rows[index]);
      if (episode === null) {
        continue;
      }
      const enabled: Object | undefined = episode['enabled'];
      if (typeof enabled === 'boolean' && !enabled) {
        continue;
      }
      const episodeId: string = QgJson.pick(episode, ['episodeId', 'id']);
      if (!numericId(episodeId) || seenIds[episodeId] === true) {
        throw new Error('青空次元分集目录包含无效或重复分集');
      }
      let order: number = index + 1;
      const orderValue: Object | undefined = episode['episodeOrder'];
      if (orderValue !== undefined && orderValue !== null) {
        const parsed: number = Number(QgJson.str(orderValue).trim());
        if (!Number.isNaN(parsed) && parsed > 0 && parsed <= 100000) {
          order = parsed;
        }
      }
      if (seenOrders[`${order}`] === true) {
        throw new Error('青空次元分集编号重复，请刷新目录');
      }
      seenIds[episodeId] = true;
      seenOrders[`${order}`] = true;
      let title: string = QgJson.pick(episode, ['episodeLabel', 'title', 'displayTitle']);
      if (title.length === 0) {
        title = `第 ${order} 集`;
      }
      episodes.push(new QgEpisode(episodeId, truncate(title, 128), order));
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    if (episodes.length === 0) {
      throw new Error('青空次元分集目录为空');
    }
    drama.episodeCount = episodes.length;
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    throw new Error('青空次元播放需要网页滑块验证码登录，当前版本暂不支持在线播放；可正常浏览与搜索');
  }

  coverHeaders(url: string): Record<string, string> {
    return {
      'User-Agent': UA,
      'Referer': `${SITE}/`
    };
  }
}
