/**
 * 红果弹幕拉取（移植自 guoapp ui_playback_danmaku.go）。
 * 走匿名评论接口 /novel/commentapi/comment/list/<videoId>/v1/，
 * X-Gorgon/X-Argus/X-Ladon 使用评论签名（HongguoSign.hongguoCommentSignHeaders）。
 * 按时间窗分页拉取：startMs 起、30s 窗口，next 光标来自 extra.next_query_danmaku_list_time。
 */
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgJson } from '../QgJson';
import { qgUtf8Encode } from '../QgBytes';
import { APP_BASE, APP_UA, HongguoSource } from './HongguoSource';
import { hongguoCommentSignHeaders } from './HongguoSign';

const DANMAKU_MAX_DURATION_MS: number = 24 * 60 * 60 * 1000;
const DANMAKU_COUNT: number = 90;
const DANMAKU_TIMEOUT: number = 20000;
const DANMAKU_CACHE_TTL: number = 5 * 60 * 1000;
const DANMAKU_ERROR_TTL: number = 15 * 1000;
const DANMAKU_MAX_TEXT: number = 180;
const DANMAKU_MAX_ID: number = 120;
const RE_NUMERIC_ID: RegExp = /^[0-9]{1,32}$/;
const RE_CONTROL_CHARS: RegExp = /[\x00-\x1F\x7F-\x9F\u2028\u2029]/g;

/** 单条弹幕 */
export class HongguoDanmakuItem {
  readonly id: string = '';
  readonly text: string = '';
  /** 出现时间（毫秒，相对本集开头） */
  readonly timeMs: number = 0;

  constructor(id: string, text: string, timeMs: number) {
    this.id = id;
    this.text = text;
    this.timeMs = timeMs;
  }
}

/** 一页弹幕（一个时间窗） */
export class HongguoDanmakuPage {
  readonly episodeId: string = '';
  readonly items: HongguoDanmakuItem[] = [];
  readonly startMs: number = 0;
  /** 下一次拉取的起点（毫秒） */
  readonly nextMs: number = 0;
  /** 弹幕总数（服务端统计） */
  readonly total: number = 0;

  constructor(episodeId: string, items: HongguoDanmakuItem[], startMs: number, nextMs: number, total: number) {
    this.episodeId = episodeId;
    this.items = items;
    this.startMs = startMs;
    this.nextMs = nextMs;
    this.total = total;
  }
}

/** 缓存条目（成功缓存页面，失败缓存错误信息） */
class HongguoDanmakuCacheEntry {
  page: HongguoDanmakuPage | null = null;
  error: string = '';
  expiresAt: number = 0;
}

const danmakuCache: Map<string, HongguoDanmakuCacheEntry> = new Map<string, HongguoDanmakuCacheEntry>();

/**
 * 拉取一页弹幕（hongguoDanmaku）。
 * @param seriesId   剧集站内 ID（book_id）
 * @param videoId    分集视频 ID（评论 group_id，即 QgPlayInfo.danmakuId）
 * @param startMs    时间窗起点（毫秒）
 * @param durationMs 本集总时长（毫秒）
 */
export async function fetchHongguoDanmaku(seriesId: string, videoId: string,
  startMs: number, durationMs: number): Promise<HongguoDanmakuPage> {
  if (!RE_NUMERIC_ID.test(seriesId) || !RE_NUMERIC_ID.test(videoId) ||
    startMs < 0 || durationMs <= startMs || durationMs > DANMAKU_MAX_DURATION_MS) {
    throw new Error('弹幕请求参数无效');
  }
  const key: string = `${seriesId}:${videoId}:${startMs}:${durationMs}`;
  const now: number = Date.now();
  const cached: HongguoDanmakuCacheEntry | undefined = danmakuCache.get(key);
  if (cached !== undefined && now < cached.expiresAt) {
    if (cached.page !== null) {
      return cached.page;
    }
    throw new Error(cached.error);
  }
  let page: HongguoDanmakuPage;
  try {
    page = await requestDanmakuPage(seriesId, videoId, startMs, durationMs);
  } catch (error) {
    const err: Error = error as Error;
    const failEntry: HongguoDanmakuCacheEntry = new HongguoDanmakuCacheEntry();
    failEntry.error = err.message;
    failEntry.expiresAt = Date.now() + DANMAKU_ERROR_TTL;
    danmakuCache.set(key, failEntry);
    throw err;
  }
  const okEntry: HongguoDanmakuCacheEntry = new HongguoDanmakuCacheEntry();
  okEntry.page = page;
  okEntry.expiresAt = Date.now() + DANMAKU_CACHE_TTL;
  if (danmakuCache.size >= 128) {
    danmakuCache.clear();
  }
  danmakuCache.set(key, okEntry);
  return page;
}

/** 发起评论接口请求（匿名、低优先级；4xx 直接失败，其余重试 ≤3 次） */
async function requestDanmakuPage(seriesId: string, videoId: string,
  startMs: number, durationMs: number): Promise<HongguoDanmakuPage> {
  const needGuide: number[] = [1, 3, 4, 2];
  const businessParam: Record<string, Object> = {
    'book_id': seriesId,
    'start_offset_time': startMs,
    'playlet_item_duration': durationMs,
    'need_danmaku_guide_type': needGuide
  };
  const payload: Record<string, Object> = {
    'comment_source': 601,
    'server_channel': 1000,
    'group_id': videoId,
    'group_type': 30,
    'comment_type': 20,
    'sort': 1,
    'count': DANMAKU_COUNT,
    'cursor': '',
    'aid': 8662,
    'compliance_status': 0,
    'business_param': businessParam
  };
  const body: Uint8Array = qgUtf8Encode(JSON.stringify(payload));
  const params: Record<string, string> = HongguoSource.appQuery(
    HongguoSource.currentDeviceId(), HongguoSource.currentInstallId());
  params['_rticket'] = `${Date.now()}`;
  const rawQuery: string = qgBuildQueryStr(params);
  const url: string = `${APP_BASE}/novel/commentapi/comment/list/${videoId}/v1/?${rawQuery}`;
  const headers: Record<string, string> = {
    'User-Agent': APP_UA,
    'Accept': 'application/json',
    'X-XS-From-Web': '0',
    'Sdk-Version': '2',
    'Content-Type': 'application/json; charset=utf-8',
    'Comment-Source': '601',
    'Server-Channel': '1000'
  };
  const signed: Record<string, string> = hongguoCommentSignHeaders(rawQuery, '8662');
  const signKeys: string[] = Object.keys(signed);
  for (let i: number = 0; i < signKeys.length; i++) {
    headers[signKeys[i]] = signed[signKeys[i]];
  }
  let lastError: Error | null = null;
  for (let attempt: number = 0; attempt < 3; attempt++) {
    if (attempt > 0) {
      await danmakuSleep(attempt * 1000);
    }
    let resp: QgHttpResponse | null = null;
    try {
      resp = await QgHttp.request(url, 'POST', headers, body, DANMAKU_TIMEOUT, 0, 30, 'hongguo');
    } catch (error) {
      lastError = error as Error;
      continue;
    }
    if (resp === null) {
      lastError = new Error('红果弹幕接口无响应');
      continue;
    }
    if (resp.status !== 200) {
      lastError = new Error(`红果弹幕接口 HTTP ${resp.status}`);
      if (resp.status >= 400 && resp.status < 500) {
        throw lastError;
      }
      continue;
    }
    const parsed: Object | null = QgJson.parse(resp.text());
    if (parsed === null) {
      lastError = new Error('红果弹幕接口返回格式异常');
      continue;
    }
    return parseHongguoDanmaku(parsed, videoId, startMs, durationMs);
  }
  throw lastError !== null ? lastError : new Error('红果弹幕接口请求失败');
}

/** 解析一页弹幕（parseHongguoDanmaku） */
function parseHongguoDanmaku(result: Object, videoId: string,
  startMs: number, durationMs: number): HongguoDanmakuPage {
  const data: Record<string, Object> | null = QgJson.field(QgJson.obj(result), 'data');
  if (data === null || !Array.isArray(data['data_list'])) {
    throw new Error('红果弹幕时间段格式无效');
  }
  const rows: Object[] = QgJson.fieldArr(data, 'data_list');
  const extra: Record<string, Object> | null = QgJson.field(data, 'extra');
  const nextText: string = extra !== null ? QgJson.pick(extra, ['next_query_danmaku_list_time']) : '';
  const next: number = Number(nextText);
  if (nextText.trim().length === 0 || Number.isNaN(next) || next <= startMs ||
    next > DANMAKU_MAX_DURATION_MS) {
    throw new Error('红果弹幕时间段格式无效');
  }
  const nextMs: number = Math.min(next, durationMs);
  let total: number = 0;
  const listInfo: Record<string, Object> | null = QgJson.field(data, 'common_list_info');
  const cursorText: string = listInfo !== null ? QgJson.pick(listInfo, ['cursor']) : '';
  if (cursorText.length > 0 && cursorText.length <= 8192) {
    const cursorParsed: Object | null = QgJson.parse(cursorText);
    const cursorObj: Record<string, Object> | null = QgJson.obj(cursorParsed);
    if (cursorObj !== null) {
      const count: number = QgJson.num(cursorObj['danmaku_count']);
      if (count > 0) {
        total = count;
      }
    }
  }
  const items: HongguoDanmakuItem[] = [];
  const seen: Record<string, boolean> = {};
  for (let i: number = 0; i < rows.length; i++) {
    const row: Record<string, Object> | null = QgJson.obj(rows[i]);
    const comment: Record<string, Object> | null = row !== null ? QgJson.field(row, 'comment') : null;
    const common: Record<string, Object> | null = comment !== null ? QgJson.field(comment, 'common') : null;
    if (common === null) {
      continue;
    }
    if (QgJson.pick(common, ['group_id']) !== videoId || QgJson.pick(common, ['status']) !== '1') {
      continue;
    }
    const expand: Record<string, Object> | null = QgJson.field(comment, 'expand');
    const positionText: string = expand !== null ? QgJson.pick(expand, ['offset_time']) : '';
    const position: number = Number(positionText);
    if (positionText.trim().length === 0 || Number.isNaN(position) ||
      position < startMs || position >= nextMs) {
      continue;
    }
    const content: Record<string, Object> | null = QgJson.field(common, 'content');
    const rawText: string = content !== null ? QgJson.pick(content, ['text']) : '';
    const text: string = rawText.replace(RE_CONTROL_CHARS, ' ').trim();
    const id: string = QgJson.pick(comment, ['comment_id']);
    if (text.length === 0 || id.length === 0 || id.length > DANMAKU_MAX_ID || seen[id] === true) {
      continue;
    }
    let bounded: string = text;
    if (text.length > DANMAKU_MAX_TEXT) {
      bounded = `${text.substring(0, DANMAKU_MAX_TEXT)}…`;
    }
    seen[id] = true;
    items.push(new HongguoDanmakuItem(id, bounded, position));
    if (items.length === DANMAKU_COUNT) {
      break;
    }
  }
  items.sort((a: HongguoDanmakuItem, b: HongguoDanmakuItem): number => a.timeMs - b.timeMs);
  return new HongguoDanmakuPage(videoId, items, startMs, nextMs, total);
}

function danmakuSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 查询串构造（与 HongguoSource.buildQuery 同语义：键排序 + URL 编码） */
function qgBuildQueryStr(params: Record<string, string>): string {
  const keys: string[] = Object.keys(params).sort();
  const parts: string[] = [];
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`);
  }
  return parts.join('&');
}
