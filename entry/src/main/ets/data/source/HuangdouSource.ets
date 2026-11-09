/**
 * 黄豆短剧站源（https://ferncider.cc 等 6 域名池）。
 * 请求/响应 AES-256-CBC 加密 + gzip；无搜索端点（本地过滤目录）。
 * 移植自 guoapp provider_huangdou.go / provider_huangdou_detail.go / provider_huangdou_vip.go。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { qgConcat, qgFromHex, qgRandomHex, qgToHex, qgUtf8Decode, qgUtf8Encode, qgUuidLike } from '../QgBytes';
import { qgAesCbcDecrypt, qgAesCbcEncrypt, qgHmacSha256, qgSha256 } from '../QgCrypto';
import { qgGzipStored, qgGunzip } from '../QgDeflate';
import { QgHttp } from '../QgHttp';
import { QgJson } from '../QgJson';
import { QgSource } from './QgSource';

const PLATFORM_KEY: string = '7961beb44246e3012ce228d6b5ced05a';
const HOST_POOL: string[] = ['ferncider.cc', 'onyxripple.cc', 'reeflumen.cc',
  'niniharbor.top', 'halomeadow.top', 'larksummit.icu'];
const UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36';
const FIRST_TIMEOUT: number = 12000;
const ATTEMPT_TIMEOUT: number = 8000;
const DETAIL_CACHE_LIMIT: number = 128;
const DETAIL_TTL: number = 5 * 60 * 1000;
const RE_SOURCE_ID: RegExp = /^[a-zA-Z0-9_-]{1,100}$/;
const ACCESS_ERROR_CODES: string[] = ['813004', '813005', '813006', '813103', 'preview'];

/** 黄豆接口业务错误（站点拒绝，不再换域名重试） */
class HuangdouApiError extends Error {
  code: string = '';

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function hostnameOf(candidate: string): string {
  let c: string = candidate.toLowerCase().trim();
  const scheme: number = c.indexOf('://');
  if (scheme >= 0) {
    c = c.substring(scheme + 3);
  }
  while (c.startsWith('//')) {
    c = c.substring(2);
  }
  const cut: number = Math.min(
    c.indexOf('/') >= 0 ? c.indexOf('/') : c.length,
    c.indexOf('?') >= 0 ? c.indexOf('?') : c.length,
    c.indexOf('#') >= 0 ? c.indexOf('#') : c.length
  );
  c = c.substring(0, cut);
  const at: number = c.lastIndexOf('@');
  if (at >= 0) {
    c = c.substring(at + 1);
  }
  const colon: number = c.lastIndexOf(':');
  if (colon >= 0) {
    c = c.substring(0, colon);
  }
  if (c.endsWith('.')) {
    c = c.substring(0, c.length - 1);
  }
  return c;
}

function nextHost(current: string): string {
  const host: string = hostnameOf(current);
  for (let i: number = 0; i < HOST_POOL.length; i++) {
    if (HOST_POOL[i] === host) {
      return `https://${HOST_POOL[(i + 1) % HOST_POOL.length]}`;
    }
  }
  return `https://${HOST_POOL[0]}`;
}

function firstNonEmpty(a: string, b: string): string {
  return a.length > 0 ? a : b;
}

function trimRp(value: string): string {
  return value.startsWith('rp_') ? value.substring(3) : value;
}

/** data 解包：{data:{...}} → 内层 */
function dataMap(value: Object): Record<string, Object> {
  const m: Record<string, Object> | null = QgJson.obj(value);
  if (m === null) {
    return {};
  }
  const inner: Record<string, Object> | null = QgJson.field(m, 'data');
  if (inner !== null) {
    return inner;
  }
  return m;
}

/** 列表提取：数组 / {list|items|data:[...]} 递归（huangdouList） */
function listRows(value: Object | undefined): Record<string, Object>[] {
  if (value === undefined || value === null) {
    return [];
  }
  if (Array.isArray(value)) {
    const arr: Object[] = value as Object[];
    const out: Record<string, Object>[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const row: Record<string, Object> | null = QgJson.obj(arr[i]);
      if (row !== null) {
        out.push(row);
      }
    }
    return out;
  }
  const map: Record<string, Object> | null = QgJson.obj(value);
  if (map !== null) {
    const keys: string[] = ['list', 'items', 'data'];
    for (let i: number = 0; i < keys.length; i++) {
      const rows: Record<string, Object>[] = listRows(map[keys[i]]);
      if (rows.length > 0) {
        return rows;
      }
    }
  }
  return [];
}

/** 完结状态推断（releaseStatusFromRemark）：true 完结 / false 连载 / null 未知 */
function finishedFromRemark(remark: string): boolean {
  if (remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载')) {
    return false;
  }
  return remark.includes('完结') || /全\s*\d+\s*集/.test(remark) || /\d+\s*集全/.test(remark) ||
    remark.includes('大结局');
}

/** 搜索文本规范化（hongguoSearchText 简化版） */
function searchText(text: string): string {
  const normalized: string = text.normalize('NFKC').toLowerCase()
    .replace(/[\s!-/:-@[-`{-~。，、；：？！“”‘’（）《》〈〉【】〔〕…—·～「」『』]/g, '');
  return normalized;
}

/** 行记录 → QgDrama（huangdouDramaFromMap） */
function dramaFromMap(item: Record<string, Object>): QgDrama | null {
  const sourceId: string = trimRp(firstNonEmpty(QgJson.pick(item, ['id']), QgJson.pick(item, ['drama_id'])));
  if (sourceId.length === 0) {
    return null;
  }
  const title: string = firstNonEmpty(QgJson.pick(item, ['name', 'title', 't']), sourceId);
  const cover: string = QgJson.pick(item, ['img_y', 'img_x', 'img', 'cover', 'pic']);
  let remark: string = firstNonEmpty(QgJson.pick(item, ['update_label']), QgJson.pick(item, ['corner']));
  const episodeCount: string = QgJson.pick(item, ['episode_count']);
  if (remark.length === 0 && episodeCount.length > 0) {
    remark = `全${episodeCount}集`;
  }
  let category: string = QgJson.pick(item, ['category', 'category_name', 'categoryName']);
  if (category.length === 0) {
    category = '未分类';
  }
  const intro: string = firstNonEmpty(QgJson.pick(item, ['description']), QgJson.pick(item, ['summary']));
  const tags: string[] = [];
  const tagValues: Object[] = QgJson.fieldArr(item, 'tags');
  for (let i: number = 0; i < tagValues.length && tags.length < 16; i++) {
    const v: string = QgJson.str(tagValues[i]).trim();
    if (v.length > 0 && v.length <= 48 && !tags.includes(v)) {
      tags.push(v);
    }
  }
  const heat: number = Number(QgJson.pick(item, ['hot_rate']).trim());
  const drama: QgDrama = new QgDrama(`huangdou:${sourceId}`, title, category);
  drama.sourceId = 'huangdou';
  drama.cover = cover;
  drama.intro = intro;
  drama.remark = remark;
  drama.tags = tags;
  drama.episodeCount = Number.isNaN(Number(episodeCount)) ? 0 : Number(episodeCount);
  drama.finished = finishedFromRemark(remark);
  drama.heat = Number.isNaN(heat) ? 0 : heat;
  drama.viewsText = QgJson.pick(item, ['click']);
  return drama;
}

/** VIP 分集序号列表（huangdouVIPEpisodes） */
function vipEpisodes(item: Record<string, Object>): number[] {
  const result: number[] = [];
  const values: Object[] = QgJson.fieldArr(item, 'vip_episodes');
  for (let i: number = 0; i < values.length; i++) {
    const index: number = Number(QgJson.str(values[i]).trim());
    if (!Number.isNaN(index) && index > 0 && index <= 10000) {
      result.push(index);
    }
  }
  return result;
}

/** 剧集级 VIP 判定（huangdouVIPFlag，返回 '' 表示未知） */
function vipFlagOf(item: Record<string, Object>): string {
  let known: string = '';
  const vipKeys: string[] = ['is_vip', 'isVip'];
  for (let i: number = 0; i < vipKeys.length; i++) {
    const value: string = QgJson.pick(item, [vipKeys[i]]).toLowerCase();
    if (value === 'true' || value === '1' || value === 'y') {
      return 'vip';
    }
    if (value === 'false' || value === '0' || value === 'n') {
      known = 'free';
    }
  }
  const payType: string = QgJson.pick(item, ['pay_type']).toLowerCase();
  if (payType === 'vip') {
    return 'vip';
  }
  if (payType === 'free') {
    known = 'free';
  }
  const episodes: number[] = vipEpisodes(item);
  for (let i: number = 0; i < episodes.length; i++) {
    if (episodes[i] > 0) {
      return 'vip';
    }
  }
  const rows: Record<string, Object>[] = listRows(item['episodes']);
  for (let i: number = 0; i < rows.length; i++) {
    if (QgJson.pick(rows[i], ['type']).toLowerCase() === 'vip') {
      return 'vip';
    }
  }
  return known;
}

/** 分集级 VIP 判定（huangdouEpisodeVIP） */
function episodeVip(detail: Record<string, Object>, episode: Record<string, Object> | null, seq: number): boolean {
  if (episode !== null) {
    const type: string = QgJson.pick(episode, ['type']).toLowerCase();
    if (type === 'vip') {
      return true;
    }
    if (type === 'free') {
      return false;
    }
  }
  const episodes: number[] = vipEpisodes(detail);
  for (let i: number = 0; i < episodes.length; i++) {
    if (episodes[i] === seq) {
      return true;
    }
  }
  if (episode !== null) {
    const flag: string = vipFlagOf(episode);
    if (flag === 'vip') {
      return true;
    }
    if (flag === 'free') {
      return false;
    }
  }
  if (QgJson.pick(detail, ['pay_type']).toLowerCase() === 'vip') {
    const free: number = Number(QgJson.pick(detail, ['free_episodes']).trim());
    return !Number.isNaN(free) && free >= 0 && seq > free;
  }
  return false;
}

export class HuangdouSource extends QgSource {
  /** 上次成功的域名（会话内复用） */
  private static preferredHost: string = '';
  /** 详情缓存（128 条 / 5 分钟） */
  private static detailCache: Map<string, QgDramaDetail> = new Map<string, QgDramaDetail>();
  private static detailCacheAt: Map<string, number> = new Map<string, number>();

  private host: string = '';
  private readonly sessionId: string = '';
  private readonly deviceId: string = '';

  constructor() {
    super('huangdou', '黄豆短剧');
    const id: string = qgRandomHex(16);
    this.sessionId = id;
    this.deviceId = id;
    this.host = HuangdouSource.preferredHost.length > 0 ?
      HuangdouSource.preferredHost : `https://${HOST_POOL[0]}`;
  }

  categories(): QgCategory[] {
    return [];
  }

  /** 单次加密调用（callOnce） */
  private async callOnce(apiPath: string, data: Record<string, Object>, timeoutMs: number): Promise<Object> {
    const path: string = `/${apiPath.replace(/^\/+/, '')}`;
    const rid: string = qgUuidLike();
    const key: Uint8Array = qgHmacSha256(qgUtf8Encode(PLATFORM_KEY), qgFromHex(rid.replace(/-/g, '')));
    const iv: Uint8Array = qgRandomBytesOf(16);
    const payload: Record<string, Object> = {
      'token': '',
      'deviceId': this.deviceId,
      'data': data
    };
    const plain: Uint8Array = qgUtf8Encode(JSON.stringify(payload));
    const cipher: Uint8Array = qgAesCbcEncrypt(qgGzipStored(plain), key, iv);
    const body: Uint8Array = qgConcat([iv, cipher]);
    const ts: string = `${Math.floor(Date.now() / 1000)}`;
    const signRaw: string = `Dart|${this.sessionId}|${rid}|${ts}|${path}`;
    const sign: string = `${qgToHex(qgSha256(qgUtf8Encode(signRaw)))}-${ts}`;
    const headers: Record<string, string> = {
      'User-Agent': UA,
      'Accept': '*/*',
      'Origin': this.host,
      'Referer': `${this.host}/home`,
      'Content-Type': 'application/octet-stream',
      'version': '2.0.0',
      'deviceType': 'web',
      'requestId': rid,
      'sessionId': this.sessionId,
      'time': ts,
      'sign': sign
    };
    const url: string = `${this.host.replace(/\/+$/, '')}/api${path}`;
    const resp = await QgHttp.request(url, 'POST', headers, body, timeoutMs);
    if (resp.status < 200 || resp.status >= 300) {
      throw new Error(`黄豆 HTTP ${resp.status}: ${resp.text().substring(0, 200)}`);
    }
    const decoded: Object = HuangdouSource.decodeResponse(resp.data, key);
    const envelope: Record<string, Object> | null = QgJson.obj(decoded);
    if (envelope !== null) {
      const status: string = QgJson.pick(envelope, ['status']);
      if (status.length > 0 && status !== 'y') {
        const code: string = QgJson.pick(envelope, ['errorCode', 'error_code', 'code']);
        let message: string = `黄豆接口拒绝请求: ${firstNonEmpty(
          QgJson.pick(envelope, ['msg', 'message', 'error']), status)}`;
        if (code !== 'preview' && ACCESS_ERROR_CODES.includes(code)) {
          message += '（站点权限限制，已停止自动重试；切换代理不会解锁）';
        }
        throw new HuangdouApiError(code, message);
      }
    }
    HuangdouSource.preferredHost = this.host;
    return decoded;
  }

  /** 带域名轮换的调用（call）：网络错误换下一个域名，业务错误直接抛 */
  private async call(apiPath: string, data: Record<string, Object>): Promise<Object> {
    const attempts: number = HOST_POOL.length;
    let lastError: Error | null = null;
    const hostsTried: Record<string, boolean> = {};
    for (let attempt: number = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        this.host = nextHost(this.host);
      }
      hostsTried[hostnameOf(this.host)] = true;
      const triedCount: number = Object.keys(hostsTried).length;
      const timeoutMs: number = triedCount === 1 ? FIRST_TIMEOUT : ATTEMPT_TIMEOUT;
      try {
        return await this.callOnce(apiPath, data, timeoutMs);
      } catch (error) {
        const err: Error = error as Error;
        lastError = err;
        if (err instanceof HuangdouApiError) {
          throw err;
        }
      }
    }
    const tried: number = Object.keys(hostsTried).length;
    if (lastError !== null && tried >= 2) {
      throw new Error(`黄豆站点连接失败：已尝试 ${tried} 个域名，最后错误：${lastError.message}`);
    }
    throw lastError !== null ? lastError : new Error('黄豆请求失败');
  }

  /** 响应解码：明文 JSON 或 iv+AES-CBC(+gzip)（huangdouDecode） */
  private static decodeResponse(blob: Uint8Array, key: Uint8Array): Object {
    const direct: Object | null = QgJson.parse(qgUtf8Decode(blob));
    if (direct !== null) {
      return direct;
    }
    if (blob.length < 32) {
      throw new Error('黄豆响应过短');
    }
    let plain: Uint8Array = qgAesCbcDecrypt(blob.slice(16), key, blob.slice(0, 16));
    if (plain.length >= 2 && plain[0] === 0x1f && plain[1] === 0x8b) {
      plain = qgGunzip(plain);
    }
    const decoded: Object | null = QgJson.parse(qgUtf8Decode(plain));
    if (decoded === null) {
      throw new Error('黄豆响应格式异常');
    }
    return decoded;
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 100000) {
      throw new Error('黄豆目录页码无效');
    }
    const decoded: Object = await this.call('/drama/list',
      { 'page': `${page}`, 'page_size': '30' });
    const rows: Record<string, Object>[] = listRows(decoded);
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = dramaFromMap(rows[i]);
      if (drama === null || seen[drama.id] === true) {
        continue;
      }
      seen[drama.id] = true;
      items.push(drama);
    }
    return new QgPageResult(items, rows.length >= 30);
  }

  /** 无服务端搜索：取目录前 3 页本地过滤 */
  async search(keyword: string, page: number): Promise<QgPageResult> {
    const kw: string = keyword.trim();
    if (kw.length === 0 || kw.length > 256) {
      throw new Error('黄豆搜索关键词无效');
    }
    if (page > 1) {
      return new QgPageResult([], false);
    }
    const items: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    const words: string[] = kw.split(/\s+/);
    const normWords: string[] = [];
    for (let w: number = 0; w < words.length; w++) {
      const normalized: string = searchText(words[w]);
      if (normalized.length > 0) {
        normWords.push(normalized);
      }
    }
    for (let p: number = 1; p <= 3; p++) {
      const decoded: Object = await this.call('/drama/list',
        { 'page': `${p}`, 'page_size': '30' });
      const rows: Record<string, Object>[] = listRows(decoded);
      for (let i: number = 0; i < rows.length; i++) {
        const drama: QgDrama | null = dramaFromMap(rows[i]);
        if (drama === null || seen[drama.id] === true) {
          continue;
        }
        seen[drama.id] = true;
        const haystack: string = searchText(`${drama.title} ${drama.intro} ${drama.tags.join(' ')}`);
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

  /** 详情（含缓存与回包校验） */
  async detail(dramaId: string): Promise<QgDramaDetail> {
    let sourceId: string = dramaId.startsWith('huangdou:') ?
      dramaId.substring('huangdou:'.length) : dramaId;
    sourceId = trimRp(sourceId.trim());
    if (!RE_SOURCE_ID.test(sourceId)) {
      throw new Error('无效的黄豆剧集 ID');
    }
    const now: number = Date.now();
    const cached: QgDramaDetail | undefined = HuangdouSource.detailCache.get(sourceId);
    const cachedAt: number | undefined = HuangdouSource.detailCacheAt.get(sourceId);
    if (cached !== undefined && cachedAt !== undefined && now - cachedAt < DETAIL_TTL) {
      return cached;
    }
    const decoded: Object = await this.call('/drama/detail', { 'id': sourceId });
    const row: Record<string, Object> = dataMap(decoded);
    if (trimRp(QgJson.pick(row, ['id', 'drama_id'])) !== sourceId) {
      throw new Error('黄豆详情返回了其他剧集');
    }
    const detail: QgDramaDetail = HuangdouSource.buildDetail(row, sourceId);
    if (HuangdouSource.detailCache.size >= DETAIL_CACHE_LIMIT) {
      HuangdouSource.detailCache.clear();
      HuangdouSource.detailCacheAt.clear();
    }
    HuangdouSource.detailCache.set(sourceId, detail);
    HuangdouSource.detailCacheAt.set(sourceId, now);
    return detail;
  }

  /** 详情 → 剧集 + 分集（fetchHuangdouChapters） */
  private static buildDetail(row: Record<string, Object>, sourceId: string): QgDramaDetail {
    const drama: QgDrama | null = dramaFromMap(row);
    const title: string = drama !== null ? drama.title : sourceId;
    const base: QgDrama = drama !== null ? drama : new QgDrama(`huangdou:${sourceId}`, title, '未分类');
    base.sourceId = 'huangdou';
    const episodeRows: Record<string, Object>[] = listRows(row['episodes']);
    let count: number = Number(firstNonEmpty(QgJson.pick(row, ['episode_count']),
      QgJson.pick(row, ['free_episodes'])).trim());
    if (Number.isNaN(count)) {
      count = episodeRows.length;
    }
    if (count <= 0) {
      count = episodeRows.length;
    }
    if (count <= 0 || count > 10000) {
      throw new Error(`黄豆返回了无效集数: ${count}`);
    }
    const episodes: QgEpisode[] = [];
    if (episodeRows.length > 0) {
      for (let i: number = 0; i < episodeRows.length; i++) {
        const ep: Record<string, Object> = episodeRows[i];
        let seq: number = Number(firstNonEmpty(QgJson.pick(ep, ['seq']),
          QgJson.pick(ep, ['episode'])).trim());
        if (Number.isNaN(seq) || seq <= 0) {
          seq = i + 1;
        }
        let titleText: string = firstNonEmpty(QgJson.pick(ep, ['name']), QgJson.pick(ep, ['title']));
        if (titleText.length === 0) {
          titleText = `第${seq}集`;
        }
        episodes.push(new QgEpisode(`${seq}`, titleText, seq));
      }
    } else {
      for (let i: number = 1; i <= count; i++) {
        episodes.push(new QgEpisode(`${i}`, `第${i}集`, i));
      }
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    const unique: QgEpisode[] = [];
    const seenIds: Record<string, boolean> = {};
    for (let i: number = 0; i < episodes.length; i++) {
      const key: string = episodes[i].id.length > 0 ? episodes[i].id : `idx_${i}`;
      if (seenIds[key] === true) {
        continue;
      }
      seenIds[key] = true;
      unique.push(episodes[i]);
    }
    base.episodeCount = unique.length;
    return new QgDramaDetail(base, unique);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    let sourceId: string = dramaId.startsWith('huangdou:') ?
      dramaId.substring('huangdou:'.length) : dramaId;
    sourceId = trimRp(sourceId.trim());
    if (!RE_SOURCE_ID.test(sourceId)) {
      throw new Error('无效的黄豆剧集 ID');
    }
    const seq: number = Number(episodeId.trim());
    if (Number.isNaN(seq) || seq < 1 || seq > 10000) {
      throw new Error('黄豆分集序号无效');
    }
    const decoded: Object = await this.call('/drama/play',
      { 'id': sourceId, 'seq': `${seq}` });
    const data: Record<string, Object> = dataMap(decoded);
    let media: string = QgJson.pick(data, ['m3u8', 'url', 'play_url', 'playUrl']);
    if (HuangdouSource.previewOnly(data, media)) {
      throw new HuangdouApiError('preview', '黄豆仅提供试看，未取得该集正片；不会把试看内容当作完整分集');
    }
    if (media.length === 0) {
      const fallback: string = `${this.host}/api/drama/hls/${encodeURIComponent(sourceId)}/${seq}/play.m3u8?line=free`;
      const playlist: string = await QgHttp.getText(fallback,
        { 'User-Agent': UA, 'Referer': `${this.host}/home` }, ATTEMPT_TIMEOUT);
      if (!playlist.trim().startsWith('#EXTM3U')) {
        throw new Error('黄豆未提供有效的播放地址，备用播放列表也不可用');
      }
      media = fallback;
    }
    media = HuangdouSource.resolveUrl(this.host, media);
    if (!/^https?:\/\/\S+$/.test(media)) {
      throw new Error('黄豆播放地址不是 HTTP/HTTPS URL');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = media;
    info.referer = `${this.host}/home`;
    info.headers = { 'User-Agent': UA, 'Referer': info.referer };
    const duration: number = Number(QgJson.pick(data, ['duration']).trim());
    if (!Number.isNaN(duration) && duration > 0) {
      info.durationMs = duration * 1000;
    }
    return info;
  }

  /** 试看判定（huangdouPreviewOnly） */
  private static previewOnly(data: Record<string, Object>, media: string): boolean {
    const flag: string = QgJson.pick(data, ['is_preview', 'isPreview']).toLowerCase();
    if (flag === 'true' || flag === '1' || flag === 'y') {
      return true;
    }
    const preview: string = QgJson.pick(data, ['preview_m3u8', 'preview_url']);
    if (preview.length > 0 &&
      (media.length === 0 ||
        HuangdouSource.resolveUrl('', media) === HuangdouSource.resolveUrl('', preview))) {
      return true;
    }
    if (media.length === 0) {
      return false;
    }
    const path: string = HuangdouSource.urlPath(media).toLowerCase();
    return path === 'preview.mp4' || path === 'preview.m3u8' ||
      path.endsWith('/preview.mp4') || path.endsWith('/preview.m3u8');
  }

  /** 相对地址补全（resolveProviderURL） */
  private static resolveUrl(host: string, media: string): string {
    const value: string = media.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) {
      return `https:${value}`;
    }
    const base: string = host.length > 0 ? host.replace(/\/+$/, '') : '';
    if (base.length === 0) {
      return value;
    }
    if (value.startsWith('/')) {
      return `${base}${value}`;
    }
    return `${base}/${value}`;
  }

  /** 提取 URL path（无内置 URL 解析器时手写） */
  private static urlPath(media: string): string {
    let rest: string = media;
    const scheme: number = rest.indexOf('://');
    if (scheme >= 0) {
      rest = rest.substring(scheme + 3);
    }
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return '';
    }
    rest = rest.substring(slash + 1);
    const query: number = rest.indexOf('?');
    if (query >= 0) {
      rest = rest.substring(0, query);
    }
    const hash: number = rest.indexOf('#');
    if (hash >= 0) {
      rest = rest.substring(0, hash);
    }
    return rest;
  }
}

/** 16 随机字节（IV 用） */
function qgRandomBytesOf(n: number): Uint8Array {
  const out: Uint8Array = new Uint8Array(n);
  for (let i: number = 0; i < n; i++) {
    out[i] = Math.floor(Math.random() * 256);
  }
  return out;
}
