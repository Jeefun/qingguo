/**
 * 红果短剧站源（App 接口 api5-normal-sinfonlineb.fqnovel.com）。
 * 设备注册（log.snssdk.com）+ X-Gorgon/X-Argus/X-Ladon 签名请求；
 * 目录按分类维护 offset/session 游标；搜索 = 名称联想 + 综合搜索页合并排序；
 * 播放派生 CENC 内容密钥（hongguoContentKey），加密变体经网关解密端点播放；
 * bytevc2 编码跳过，密钥不可用（v2）或 App/网页取流全失败时报错。
 * 移植自 guoapp provider_hongguo_app.go / _catalog.go / _search.go / _detail.go /
 * _native_media.go / _device.go / _suggestions.go / _search_seasons.go。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo, QgSeason } from '../../model/QgModels';
import { qgSha256, qgMd5, qgSm3, qgSha512, qgAesCbcDecryptNoUnpad } from '../QgCrypto';
import { qgBase64Encode, qgRandomBytes, qgConcat } from '../QgBytes';
import { createPlaybackSigner, PlaybackHost, PlaybackSigner, PlaybackSignedRequest } from './HongguoPlaybackV5';
import { qgBase64Decode, qgFromHex, qgToHex, qgUtf8Decode, qgUtf8Encode, qgUuidLike, qgRandomHex } from '../QgBytes';
import { QgHttp, QgHttpResponse } from '../QgHttp';
import { QgGateway } from '../QgGateway';
import { QgJson } from '../QgJson';
import { hongguoSignHeaders, newHongguoDeviceId } from './HongguoSign';
import { QgSource } from './QgSource';

export const APP_BASE: string = 'https://api5-normal-sinfonlineb.fqnovel.com';
const PLAYBACK_BASE: string = 'https://api5-normal-sinfonlinea.fqnovel.com';
const PLAYBACK_PATH: string = '/novel/player/multi_video_model/player/v1';
const VIDEO_TAB_PATH: string = '/reading/bookapi/video_tab/multi_video_model/v1/';
const SERIES_PACK_PATH: string = '/reading/distribution/book_pack_fields/inner_feed_detail/v1/';
const PLAYBACK_UA: string = 'com.phoenix.read/74532 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)';
const playbackHost: PlaybackHost = {
  hexDecode: qgFromHex, hexEncode: qgToHex, utf8Encode: qgUtf8Encode,
  base64Encode: qgBase64Encode, randomBytes: qgRandomBytes, md5: qgMd5, sm3: qgSm3
};
const playbackSigner: PlaybackSigner = createPlaybackSigner(playbackHost);
const WEB_BASE: string = 'https://hongguoduanju.com';
const REGISTER_URL: string = 'https://log.snssdk.com/service/2/device_register/';
/** 与在线模块 manifest 1.0.7 的取流接口及设备回退对齐。 */
export const HONGGUO_MODULE_VERSION: string = '1.0.7';
export const APP_UA: string = 'com.phoenix.read/74532 (Linux; U; Android 16; zh_CN; 25053RT47C; ' +
  'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
const WEB_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1';
const RE_NUMERIC_ID: RegExp = /^[0-9]{1,32}$/;
const REQUEST_TIMEOUT: number = 20000;
const MAX_BODY_BYTES: number = 20 * 1024 * 1024;
const REGISTER_PAUSE_MS: number = 10 * 60 * 1000;
const DEVICE_ROTATIONS: number = 3;
const CURSOR_STALE_MS: number = 30 * 60 * 1000;
const DETAIL_CACHE_LIMIT: number = 128;
const DETAIL_TTL: number = 5 * 60 * 1000;
const SEARCH_CACHE_LIMIT: number = 64;
const SEARCH_TTL: number = 5 * 60 * 1000;
const SEARCH_PAGE_SIZE: number = 10;
const SEARCH_TAB: string = '29';
const SEARCH_PATH: string = '/reading/bookapi/search/tab/v/';
const SUGGEST_COUNT: number = 50;
const SUGGEST_TIMEOUT: number = 5000;
const SEASON_LIMIT: number = 200;
const SERIES_SEASON_LIMIT: number = 60;
const SERIES_SEASON_TIMEOUT: number = 25000;
/** 备用线路播放地址解密盐（hongguo 1.0.7 playUrlSalts） */
const PLAY_URL_SALTS: string[] = ['4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58'];
const PLAY_URL_HEADER_SIZE: number = 4;
const PLAY_URL_PATTERN: RegExp = /^https?:\/\/\S+$/;
/** 备用线路依次尝试的 codec_type（1=H.265，3=H.264） */
const FALLBACK_CODEC_TYPES: string[] = ['1', '3'];

/** 明确的注册拒绝才进入冷却；网络故障和网关错误可直接重试。 */
class HongguoRegisterRejection extends Error {
}

class HongguoNoCompatibleMedia extends Error {
}

/** 备用线路播放地址编码版本不支持（hongguo 1.0.7 unsupportedPlayUrl） */
class HongguoUnsupportedPlayUrl extends Error {
}

/** 分类/题材定义（hongguoAppGenres） */
class HongguoGenre {
  readonly key: string = '';
  readonly scene: string = '';
  readonly name: string = '';

  constructor(key: string, scene: string, name: string) {
    this.key = key;
    this.scene = scene;
    this.name = name;
  }
}

// 分类顺序 = 发现页 chips 顺序；第 1 项同时是首页默认展示的分类。
// 按用户偏好：AI剧 > 漫剧 > 真人剧（原顺序为真人剧 > 漫剧 > AI剧）。
const GENRES: HongguoGenre[] = [
  new HongguoGenre('ai_series', 'ai_series', 'AI剧'),
  new HongguoGenre('comic_series', 'comic_series', '漫剧'),
  new HongguoGenre('short_play', 'default', '真人剧')
];

/** 目录游标（hongguoCatalogCursor） */
class HongguoCursor {
  offset: number = 0;
  sessionId: string = '';
  lastId: string = '';
  pageSignature: string = '';
  initialized: boolean = false;
  exhausted: boolean = false;
  updatedAt: number = 0;
}

/** 季数解析结果（hongguoSearchSeason） */
class HongguoSeasonInfo {
  base: string = '';
  number: number = 0;
  unit: string = '';
  label: string = '';
}

/** 搜索建议记录（hongguoSuggestionRecord） */
class HongguoSuggestionRecord {
  name: string = '';
  wordType: string = '';
  keyword: string = '';
  videoData: Record<string, Object> | null = null;
}

/** 一次目录页解析结果 */
class HongguoCatalogPage {
  items: QgDrama[] = [];
  cursor: HongguoCursor = new HongguoCursor();
}

function firstNonEmpty2(a: string, b: string): string {
  return a.length > 0 ? a : b;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function preserveSeasonIntegers(text: string): string {
  return text.replace(/"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g, (token: string): string => {
    if (token.startsWith('"') || /[.eE]/.test(token) || Number.isSafeInteger(Number(token))) return token;
    return '"' + token + '"';
  });
}

function seasonPackBody(ids: string[], fields: string[]): string {
  return '{"book_pack_channel":"inner_feed_detail","req_ids":[' + ids.join(',') +
    '],"req_fields":' + JSON.stringify(fields) + '}';
}

function isSeasonId(value: string): boolean {
  return /^[1-9][0-9]{0,18}$/.test(value) && BigInt(value) <= 9223372036854775807n;
}

/** Go url.QueryEscape 兼容转义（空格 → +，保留 A-Za-z0-9-_.~） */
function goQueryEscape(value: string): string {
  return encodeURIComponent(value)
    .replace(/%20/g, '+')
    .replace(/!/g, '%21')
    .replace(/'/g, '%27')
    .replace(/\(/g, '%28')
    .replace(/\)/g, '%29')
    .replace(/\*/g, '%2A');
}

/** Go url.Values.Encode 兼容：key 排序后拼接 */
function buildQuery(params: Record<string, string>): string {
  const keys: string[] = Object.keys(params).sort();
  const parts: string[] = [];
  for (let i: number = 0; i < keys.length; i++) {
    parts.push(`${goQueryEscape(keys[i])}=${goQueryEscape(params[keys[i]])}`);
  }
  return parts.join('&');
}

/** 严格 base64 解码（Std 优先，失败按 RawStd；decodeHongguoBase64） */
function decodeBase64(value: string): Uint8Array {
  const clean: string = value.trim();
  if (clean.length === 0 || clean.length % 4 === 1 || !/^[A-Za-z0-9+/]+={0,2}$/.test(clean)) {
    throw new Error('红果 base64 数据无效');
  }
  return qgBase64Decode(clean);
}

/** 整数二进制 1 的个数（Go bits.OnesCount） */
function hongguoPopcount(v: number): number {
  let x: number = v >>> 0;
  let n: number = 0;
  while (x !== 0) {
    x &= x - 1;
    n++;
  }
  return n;
}

/**
 * 红果 CENC 内容密钥派生（hongguoContentKey）。
 * spade_a 结构：base64 → [头部1字节] [content] [tag^seed] [seed]；
 * tagLength = raw[0]^raw[1]^raw[2]-48；content 逐字节
 * decoded[i] = (previous ^ current) - 21 - popcount(i)（偶奇交替起始 250/85）；
 * decoded[0] 为 base36 padding 数字，decoded[1..33) 为 32 字符 hex 密钥。
 * app_v2 / web_v2 版本不支持（返回 null）。
 */
function hongguoContentKey(value: string): Uint8Array | null {
  const raw: Uint8Array = qgBase64Decode(value.trim());
  if (raw.length < 3) {
    return null;
  }
  const tagLength: number = (raw[0] ^ raw[1] ^ raw[2]) - 48;
  const contentLength: number = raw.length - tagLength - 1;
  if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
    return null;
  }
  const seed: number = raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
  const tagBytes: Uint8Array = new Uint8Array(tagLength);
  for (let i: number = 0; i < tagLength; i++) {
    tagBytes[i] = raw[raw.length - tagLength + i] ^ seed;
  }
  const tag: string = qgUtf8Decode(tagBytes);
  if (tag === 'app_v2' || tag === 'web_v2') {
    return null;
  }
  const decoded: Uint8Array = new Uint8Array(contentLength);
  let prevEven: number = 250;
  let prevOdd: number = 85;
  for (let i: number = 0; i < contentLength; i++) {
    const current: number = raw[1 + i];
    let previous: number;
    if (i % 2 === 0) {
      previous = prevEven;
      prevEven = current;
    } else {
      previous = prevOdd;
      prevOdd = current;
    }
    decoded[i] = ((previous ^ current) - 21 - hongguoPopcount(i)) & 0xff;
  }
  const padValue: number = parseInt(String.fromCharCode(decoded[0]), 36);
  if (Number.isNaN(padValue)) {
    return null;
  }
  if (contentLength - padValue - 1 !== 32) {
    return null;
  }
  let hexText: string = '';
  for (let i: number = 1; i < 33; i++) {
    hexText += String.fromCharCode(decoded[i]);
  }
  const key: Uint8Array = qgFromHex(hexText);
  if (key.length !== 16) {
    return null;
  }
  return key;
}

/** 是否 http(s) 媒体地址（isProviderHTTPMediaURL：无 userinfo、host 非空） */
function isHttpMediaUrl(raw: string): boolean {
  const value: string = raw.trim();
  const match: RegExpExecArray | null = /^https?:\/\/([^\/?#]*)/.exec(value);
  if (match === null) {
    return false;
  }
  const host: string = match[1];
  return host.length > 0 && !host.includes('@');
}

/** 定位 JSON 对象值在文本中的结束下标（括号深度 + 字符串转义感知） */
function routerJsonEnd(text: string, start: number): number {
  let depth: number = 0;
  let inString: boolean = false;
  let escaped: boolean = false;
  for (let i: number = start; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
    } else if (ch === '{' || ch === '[') {
      depth++;
    } else if (ch === '}' || ch === ']') {
      depth--;
      if (depth === 0) {
        return i + 1;
      }
    }
  }
  return -1;
}

/** 解析网页内嵌 _ROUTER_DATA（parseRouterData），返回 [JSON 原文, 解析结果] */
function parseRouterData(raw: string): RouterData {
  const marker: RegExpExecArray | null = /(?:window\.)?_ROUTER_DATA\s*=\s*/.exec(raw);
  if (marker === null) {
    return new RouterData('', null);
  }
  let first: number = marker.index + marker[0].length;
  while (first < raw.length && /\s/.test(raw.charAt(first))) {
    first++;
  }
  if (first >= raw.length || raw.charAt(first) !== '{') {
    return new RouterData('', null);
  }
  const end: number = routerJsonEnd(raw, first);
  if (end <= first) {
    return new RouterData('', null);
  }
  const jsonText: string = raw.substring(first, end);
  return new RouterData(jsonText, QgJson.obj(QgJson.parse(jsonText)));
}

/** _ROUTER_DATA 解析结果：原文 + 对象视图 */
class RouterData {
  rawJson: string = '';
  data: Record<string, Object> | null = null;

  constructor(rawJson: string, data: Record<string, Object> | null) {
    this.rawJson = rawJson;
    this.data = data;
  }
}

/** loaderData 内按名称（含前缀）查找页面对象（routerLoaderMap） */
function routerLoaderMap(data: Record<string, Object> | null, names: string[]): Record<string, Object> | null {
  if (data === null) {
    return null;
  }
  const loader: Record<string, Object> | null = QgJson.field(data, 'loaderData');
  if (loader === null) {
    return null;
  }
  for (let i: number = 0; i < names.length; i++) {
    const page: Record<string, Object> | null = QgJson.field(loader, names[i]);
    if (page !== null && Object.keys(page).length > 0) {
      return page;
    }
  }
  const keys: string[] = Object.keys(loader);
  for (let k: number = 0; k < keys.length; k++) {
    const key: string = keys[k];
    for (let i: number = 0; i < names.length; i++) {
      if (names[i].length > 0 && key.startsWith(names[i])) {
        const page: Record<string, Object> | null = QgJson.field(loader, key);
        if (page !== null && Object.keys(page).length > 0) {
          return page;
        }
      }
    }
  }
  return null;
}

/** 搜索文本规范化（hongguoSearchText：NFKC + 去空白标点 + 小写） */
function searchText(text: string): string {
  const normalized: string = text.normalize('NFKC').replace(/[\s\p{P}]/gu, '').toLowerCase();
  if (normalized.length === 0) {
    return text.trim().toLowerCase();
  }
  return normalized;
}

/** 标题搜索权重（hongguoTitleSearchRank）：0 全等 / 1 前缀 / 2 包含 / 3 分词全含 / 4 其他 */
function titleSearchRank(title: string, query: string): number {
  const words: string[] = query.normalize('NFKC').split(/[\s\p{P}]+/u);
  const normalizedQuery: string = searchText(query);
  const normalizedTitle: string = searchText(title);
  if (normalizedTitle === normalizedQuery) {
    return 0;
  }
  if (normalizedTitle.startsWith(normalizedQuery)) {
    return 1;
  }
  if (normalizedTitle.includes(normalizedQuery)) {
    return 2;
  }
  let matches: number = 0;
  let counted: number = 0;
  for (let i: number = 0; i < words.length; i++) {
    const word: string = searchText(words[i]);
    if (word.length === 0) {
      continue;
    }
    counted++;
    if (normalizedTitle.includes(word)) {
      matches++;
    }
  }
  if (counted > 0 && matches === counted) {
    return 3;
  }
  return 4;
}

/** 中文数字解析（hongguoSearchSeason 内部） */
function chineseNumber(label: string): number {
  const digits: Record<string, number> = {
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '兩': 2,
    '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9
  };
  let number: number = 0;
  if (!/.*[十百]/.test(label)) {
    for (let i: number = 0; i < label.length; i++) {
      const value: number | undefined = digits[label.charAt(i)];
      if (value === undefined) {
        return -1;
      }
      number = number * 10 + value;
      if (number > SEASON_LIMIT) {
        return -1;
      }
    }
    return number;
  }
  let digit: number = 0;
  let previous: number = 1000;
  for (let i: number = 0; i < label.length; i++) {
    const ch: string = label.charAt(i);
    const mapped: number | undefined = digits[ch];
    if (mapped !== undefined) {
      digit = digit * 10 + mapped;
      continue;
    }
    let unit: number = 10;
    if (ch === '百') {
      unit = 100;
    } else if (ch !== '十') {
      return -1;
    }
    if (unit >= previous || digit > 9) {
      return -1;
    }
    number += Math.max(digit, 1) * unit;
    digit = 0;
    previous = unit;
  }
  return number + digit;
}

/** 季数后缀解析（hongguoSearchSeason） */
function searchSeason(title: string): HongguoSeasonInfo | null {
  const value: string = title.normalize('NFKC').trim();
  const match: RegExpExecArray | null =
    /第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\p{P}\s]*$/u.exec(value);
  if (match === null) {
    return null;
  }
  const base: string = value.substring(0, match.index).replace(/[\s\p{P}]+$/u, '');
  const label: string = match[1];
  const unit: string = match[2];
  let number: number = Number(label);
  if (Number.isNaN(number)) {
    number = chineseNumber(label);
  }
  if (number < 0) {
    number = 0;
  }
  const info: HongguoSeasonInfo = new HongguoSeasonInfo();
  info.base = base;
  info.number = number;
  info.unit = unit;
  info.label = label;
  if (base.length === 0 || number < 1 || number > SEASON_LIMIT) {
    return null;
  }
  return info;
}

/** 行记录 → QgDrama（hongguoDramaFromAny） */
function dramaFromRow(value: Object, category: string): QgDrama | null {
  const m: Record<string, Object> | null = QgJson.obj(value);
  if (m === null) {
    return null;
  }
  let vd: Record<string, Object> | null = QgJson.field(m, 'video_data');
  if (vd === null || Object.keys(vd).length === 0) {
    vd = m;
  }
  const siteId: string = firstNonEmpty2(
    QgJson.pick(vd, ['series_id_str', 'series_id']),
    firstNonEmpty2(QgJson.pick(m, ['series_id_str', 'series_id']),
      firstNonEmpty2(QgJson.pick(vd, ['keyword']), QgJson.pick(m, ['keyword']))));
  if (!RE_NUMERIC_ID.test(siteId)) {
    return null;
  }
  const title: string = firstNonEmpty2(
    QgJson.pick(vd, ['series_title', 'series_name', 'title']),
    firstNonEmpty2(QgJson.pick(m, ['series_name', 'name']), siteId));
  const cover: string = firstNonEmpty2(QgJson.pick(vd, ['series_cover', 'cover']),
    QgJson.pick(m, ['series_cover']));
  const intro: string = firstNonEmpty2(QgJson.pick(vd, ['series_intro', 'video_desc']),
    QgJson.pick(m, ['series_intro']));
  const count: string = firstNonEmpty2(QgJson.pick(vd, ['episode_cnt']),
    QgJson.pick(m, ['episode_cnt']));
  let remark: string = firstNonEmpty2(QgJson.pick(vd, ['episode_right_text']),
    QgJson.pick(m, ['episode_right_text']));
  // 完结状态（releaseStatusFromRemark + series_status）
  let ongoing: boolean = remark.includes('未完结') || remark.includes('更新至') || remark.includes('连载');
  const finishedByRemark: boolean = /全\s*\d+\s*集/.test(remark) || /\d+\s*集全/.test(remark) ||
    remark.includes('完结') || remark.includes('大结局');
  const status: string = QgJson.pick(vd, ['series_status']);
  if (status === '1') {
    ongoing = false;
  } else if (status === '0') {
    ongoing = true;
  }
  if (remark.length === 0 && count.length > 0) {
    remark = `共${count}集`;
  }
  // 标签：tags + category_list + category_schema
  const tags: string[] = [];
  const tagValues: Object[] = QgJson.fieldArr(vd, 'tags');
  for (let i: number = 0; i < tagValues.length && tags.length < 16; i++) {
    const tag: string = QgJson.str(tagValues[i]).trim();
    if (tag.length > 0 && tag.length <= 48 && !tags.includes(tag)) {
      tags.push(tag);
    }
  }
  const categoryRows: Object[] = QgJson.fieldArr(vd, 'category_list');
  for (let i: number = 0; i < categoryRows.length && tags.length < 16; i++) {
    const row: Record<string, Object> | null = QgJson.obj(categoryRows[i]);
    const name: string = row !== null ? QgJson.pick(row, ['name']) : '';
    if (name.length > 0 && !tags.includes(name)) {
      tags.push(name);
    }
  }
  const schema: Object | null = QgJson.parse(QgJson.pick(vd, ['category_schema']));
  if (schema !== null) {
    const schemaRows: Object[] = QgJson.arr(schema);
    for (let i: number = 0; i < schemaRows.length && tags.length < 16; i++) {
      const row: Record<string, Object> | null = QgJson.obj(schemaRows[i]);
      const name: string = row !== null ? QgJson.pick(row, ['name']) : '';
      if (name.length > 0 && !tags.includes(name)) {
        tags.push(name);
      }
    }
  }
  let genre: string = QgJson.pick(vd, ['category_name', 'categoryName', 'category']);
  if (genre.length === 0 && tags.length > 0) {
    genre = tags[0];
  }
  const drama: QgDrama = new QgDrama(`hongguo:${siteId}`, title, firstNonEmpty2(genre, category));
  drama.sourceId = 'hongguo';
  drama.cover = cover;
  drama.intro = intro;
  drama.remark = remark;
  // 红果 1.0.4：听书结果增加「听书 · 共 N 章」角标。
  if (genre.includes('听书') || category.includes('听书')) {
    drama.badge = count.length > 0 ? `听书 · 共 ${count} 章` : '听书';
  }
  drama.tags = tags;
  const episodeCount: number = Number(count);
  drama.episodeCount = Number.isNaN(episodeCount) ? 0 : episodeCount;
  drama.finished = status === '1' || (status.length === 0 && !ongoing && finishedByRemark) ||
    (status.length === 0 && !ongoing && remark.length === 0);
  drama.viewsText = QgJson.pick(vd, ['series_play_cnt', 'play_cnt']);
  // 热度：hot_score_data.score 优先
  const hot: Record<string, Object> | null = QgJson.field(vd, 'hot_score_data');
  let heat: number = 0;
  if (hot !== null) {
    const score: string = firstNonEmpty2(QgJson.pick(hot, ['score']), QgJson.pick(vd, ['hot_score']));
    const parsed: number = Number(score);
    if (score.length > 0 && !Number.isNaN(parsed) && parsed >= 0) {
      heat = parsed;
    }
  }
  drama.heat = heat;
  return drama;
}

/** 合并两条同名剧集元数据（mergeDramaMetadata 简化版：空字段补齐） */
function mergeDramas(base: QgDrama, extra: QgDrama): void {
  if (base.title.length === 0) {
    base.title = extra.title;
  }
  if (base.cover.length === 0) {
    base.cover = extra.cover;
  }
  if (base.intro.length === 0) {
    base.intro = extra.intro;
  }
  if (base.remark.length === 0) {
    base.remark = extra.remark;
  }
  if (base.badge.length === 0) {
    base.badge = extra.badge;
  }
  if (base.viewsText.length === 0) {
    base.viewsText = extra.viewsText;
  }
  if (base.genre.length === 0) {
    base.genre = extra.genre;
  }
  if (base.episodeCount === 0) {
    base.episodeCount = extra.episodeCount;
  }
  for (let i: number = 0; i < extra.tags.length; i++) {
    if (!base.tags.includes(extra.tags[i])) {
      base.tags.push(extra.tags[i]);
    }
  }
}

export class HongguoSource extends QgSource {
  /** 设备注册状态（会话级） */
  private static deviceId: string = newHongguoDeviceId();
  private static installId: string = newHongguoDeviceId();
  private static registered: boolean = false;
  private static registerPausedUntil: number = 0;
  private static registerPauseErr: string = '';
  private static registerPromise: Promise<void> | null = null;
  private static helperDeviceId: string = newHongguoDeviceId();
  private static helperInstallId: string = newHongguoDeviceId();
  private static helperRegistered: boolean = false;
  private static helperRegisterPausedUntil: number = 0;
  private static helperRegisterPauseErr: string = '';
  private static helperRegisterPromise: Promise<void> | null = null;
  /** 目录游标（feedKey → cursor） */
  private static cursors: Map<string, HongguoCursor> = new Map<string, HongguoCursor>();
  /** 详情缓存 */
  private static detailCache: Map<string, QgDramaDetail> = new Map<string, QgDramaDetail>();
  private static detailCacheAt: Map<string, number> = new Map<string, number>();
  /** 搜索缓存 */
  private static searchCache: Map<string, QgDrama[]> = new Map<string, QgDrama[]>();
  private static searchCacheAt: Map<string, number> = new Map<string, number>();
  private static searchIds: Map<string, string> = new Map<string, string>();

  constructor() {
    super('hongguo', '红果短剧');
  }

  /** 当前设备 ID（弹幕匿名请求用，不触发注册） */
  static currentDeviceId(): string {
    return HongguoSource.deviceId;
  }

  /** 当前安装 ID（弹幕匿名请求用，不触发注册） */
  static currentInstallId(): string {
    return HongguoSource.installId;
  }

  categories(): QgCategory[] {
    const out: QgCategory[] = [];
    for (let i: number = 0; i < GENRES.length; i++) {
      out.push(new QgCategory(GENRES[i].key, GENRES[i].name));
    }
    return out;
  }

  /** 基础查询参数（hongguoAppQuery；弹幕等模块复用） */
  static appQuery(deviceId: string, installId: string): Record<string, string> {
    return {
      'aid': '8662',
      'app_name': 'novelread',
      'version_code': '74532',
      'version_name': '7.4.5.32',
      'manifest_version_code': '74532',
      'update_version_code': '74532',
      'channel': 'update_64',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': '25053RT47C',
      'device_brand': 'Redmi',
      'language': 'zh',
      'os_api': '36',
      'os_version': '16',
      'resolution': '1280*2772',
      'dpi': '520',
      'ac': 'wifi',
      'device_id': deviceId,
      'iid': installId
    };
  }

  /** 上游 1.0.3 播放接口使用独立客户端参数，与目录接口分开。 */
  private static playbackQuery(deviceId: string, installId: string): Record<string, string> {
    return {
      'aid': '8662', 'app_name': 'novelread', 'version_code': '74532', 'version_name': '7.4.5.32',
      'channel': 'vivo_8662_64', 'device_platform': 'android', 'device_type': 'PGT-AN10', 'os_version': '12',
      'update_version_code': '74532', 'iid': installId, 'cdid': qgUuidLike(), 'device_id': deviceId
    };
  }

  /** 设备注册（registerHongguoDevice；拒绝时暂停 10 分钟） */
  private static async registerDevice(helper: boolean = false): Promise<void> {
    const header: Record<string, Object> = {
      'display_name': '红果免费短剧', 'aid': 8662, 'app_version': '7.4.5.32', 'version_code': 74532,
      'manifest_version_code': 74532, 'update_version_code': 74532, 'channel': 'update_64',
      'package': 'com.phoenix.read',
      'app_language': 'zh', 'os': 'Android', 'os_version': '16', 'os_api': 36,
      'device_model': '25053RT47C', 'device_brand': 'Redmi', 'device_manufacturer': 'Xiaomi',
      'cpu_abi': 'arm64-v8a', 'density_dpi': 520,
      'display_density': 'xxhdpi', 'resolution': '2772x1280', 'language': 'zh', 'timezone': 8,
      'access': 'wifi', 'openudid': qgRandomHex(8), 'clientudid': qgUuidLike(), 'cdid': qgUuidLike(),
      'region': 'CN', 'tz_name': 'Asia/Shanghai', 'tz_offset': 28800, 'sim_region': 'cn',
      'device_platform': 'android', 'not_request_sender': 0, 'is_system_app': 0,
      'sdk_flavor': 'china', 'rom': 'OS2.0', 'rom_version': 'BP2A.250605.031.A3'
    };
    const body: Uint8Array = qgUtf8Encode(JSON.stringify({
      'magic_tag': 'ss_app_log', 'header': header, '_gen_time': Date.now()
    } as Record<string, Object>));
    const params: Record<string, string> = {};
    const full: Record<string, string> = HongguoSource.appQuery('', '');
    const fullKeys: string[] = Object.keys(full);
    for (let i: number = 0; i < fullKeys.length; i++) {
      if (fullKeys[i] !== 'device_id' && fullKeys[i] !== 'iid') {
        params[fullKeys[i]] = full[fullKeys[i]];
      }
    }
    params['req_id'] = qgUuidLike();
    params['_rticket'] = `${Date.now()}`;
    const url: string = `${REGISTER_URL}?${buildQuery(params)}`;
    const headers: Record<string, string> = {
      'User-Agent': APP_UA,
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8'
    };
    let resp = await QgHttp.request(url, 'POST', headers, body, REQUEST_TIMEOUT, 0, 30, 'hongguo');
    if (resp.status !== 200) {
      if (resp.status >= 400 && resp.status < 500 && resp.status !== 408 && resp.status !== 429) {
        throw new HongguoRegisterRejection(`红果设备注册 HTTP ${resp.status}`);
      }
      throw new Error(`红果设备注册 HTTP ${resp.status}`);
    }
    if (resp.data.length > 64 * 1024) {
      throw new Error('红果设备注册返回数据过大');
    }
    const parsed: Object | null = QgJson.parse(resp.text());
    const result: Record<string, Object> | null = QgJson.obj(parsed);
    if (result === null) {
      throw new Error('红果设备注册返回格式异常');
    }
    const newDeviceId: string = firstNonEmpty2(QgJson.pick(result, ['device_id_str', 'device_id']), '');
    const newInstallId: string = firstNonEmpty2(QgJson.pick(result, ['install_id_str', 'install_id']), '');
    if (!RE_NUMERIC_ID.test(newDeviceId) || !RE_NUMERIC_ID.test(newInstallId) ||
      newDeviceId === '0' || newInstallId === '0') {
      throw new HongguoRegisterRejection('红果设备注册未返回设备号');
    }
    if (helper) {
      HongguoSource.helperDeviceId = newDeviceId;
      HongguoSource.helperInstallId = newInstallId;
      HongguoSource.helperRegistered = true;
    } else {
      HongguoSource.deviceId = newDeviceId;
      HongguoSource.installId = newInstallId;
      HongguoSource.registered = true;
    }
  }

  /** 确保设备可用（ensureHongguoDevice：注册被拒后暂停 10 分钟） */
  private static async ensureDevice(rejected: string, helper: boolean = false): Promise<void> {
    const registered: boolean = helper ? HongguoSource.helperRegistered : HongguoSource.registered;
    const deviceId: string = helper ? HongguoSource.helperDeviceId : HongguoSource.deviceId;
    const settled: boolean = (rejected.length === 0 && registered) ||
      (rejected.length > 0 && rejected !== deviceId);
    if (settled) {
      return;
    }
    const pausedUntil: number = helper ? HongguoSource.helperRegisterPausedUntil : HongguoSource.registerPausedUntil;
    if (Date.now() < pausedUntil) {
      const reason: string = helper ? HongguoSource.helperRegisterPauseErr : HongguoSource.registerPauseErr;
      throw new Error(`红果设备注册暂不可用：${reason}`);
    }
    const existing: Promise<void> | null = helper ? HongguoSource.helperRegisterPromise : HongguoSource.registerPromise;
    if (existing !== null) {
      await existing;
      return;
    }
    const pending: Promise<void> = HongguoSource.registerDevice(helper);
    if (helper) {
      HongguoSource.helperRegisterPromise = pending;
    } else {
      HongguoSource.registerPromise = pending;
    }
    try {
      await pending;
    } catch (error) {
      const err: Error = error as Error;
      if (err instanceof HongguoRegisterRejection) {
        if (helper) {
          HongguoSource.helperRegisterPausedUntil = Date.now() + REGISTER_PAUSE_MS;
          HongguoSource.helperRegisterPauseErr = err.message;
        } else {
          HongguoSource.registerPausedUntil = Date.now() + REGISTER_PAUSE_MS;
          HongguoSource.registerPauseErr = err.message;
        }
      }
      throw err;
    } finally {
      if (helper) {
        HongguoSource.helperRegisterPromise = null;
      } else {
        HongguoSource.registerPromise = null;
      }
    }
  }

  /**
   * 签名 App 请求（hongguoAppRequest）。
   * 空响应轮换设备（≤3 次），4xx 直接失败，5xx/网络错误重试（≤3 次）。
   */
  private static async appRequest(method: string, path: string,
    extra: Record<string, string> | null, payload: Record<string, Object> | string | null,
    helper: boolean = false, deadline: number = 0): Promise<Object> {
    await HongguoSource.ensureDevice('', helper);
    let deviceId: string = helper ? HongguoSource.helperDeviceId : HongguoSource.deviceId;
    let installId: string = helper ? HongguoSource.helperInstallId : HongguoSource.installId;
    const playback: boolean = path === PLAYBACK_PATH;
    const signedV5: boolean = playback || path === VIDEO_TAB_PATH;
    const params: Record<string, string> = playback ? HongguoSource.playbackQuery(deviceId, installId) :
      HongguoSource.appQuery(deviceId, installId);
    if (extra !== null) {
      const keys: string[] = Object.keys(extra);
      for (let i: number = 0; i < keys.length; i++) {
        params[keys[i]] = extra[keys[i]];
      }
    }
    const body: Uint8Array | null = payload !== null ?
      qgUtf8Encode(typeof payload === 'string' ? payload : JSON.stringify(payload)) : null;
    const attempts: number = 3;
    let attempt: number = 0;
    let rotations: number = 0;
    let lastError: Error | null = null;
    while (attempt < attempts) {
      if (deadline > 0 && Date.now() >= deadline) throw new Error('红果分季请求超时');
      if (attempt > 0) {
        await sleep(deadline > 0 ? Math.max(0, Math.min(attempt * 1000, deadline - Date.now())) : attempt * 1000);
      }
      params['device_id'] = deviceId;
      params['iid'] = installId;
      params['_rticket'] = `${Date.now()}`;
      const rawQuery: string = buildQuery(params);
      let url: string = `${APP_BASE}${path}?${rawQuery}`;
      const headers: Record<string, string> = signedV5 ? { 'User-Agent': PLAYBACK_UA, 'Accept': 'application/json' } : {
        'User-Agent': APP_UA,
        'Accept': 'application/json',
        'X-XS-From-Web': '0',
        'Sdk-Version': '2'
      };
      let signed: Record<string, string>;
      if (signedV5) {
        const prepared: PlaybackSignedRequest = playbackSigner.sign((playback ? PLAYBACK_BASE : APP_BASE) + path,
          params, body, Date.now());
        url = prepared.url;
        headers['User-Agent'] = PLAYBACK_UA;
        signed = prepared.headers;
      } else {
        signed = hongguoSignHeaders(rawQuery, body, deviceId, '8662');
      }
      const signKeys: string[] = Object.keys(signed);
      for (let i: number = 0; i < signKeys.length; i++) {
        headers[signKeys[i]] = signed[signKeys[i]];
      }
      let resp: QgHttpResponse | null = null;
      try {
        resp = await QgHttp.request(url, method, headers, body,
          deadline > 0 ? Math.max(1, Math.min(REQUEST_TIMEOUT, deadline - Date.now())) : REQUEST_TIMEOUT,
          0, 30, 'hongguo');
      } catch (error) {
        lastError = error as Error;
        attempt++;
        continue;
      }
      if (resp === null) {
        attempt++;
        continue;
      }
      if (resp.status !== 200) {
        lastError = new Error(`红果 App 接口 HTTP ${resp.status}`);
        if (resp.status >= 400 && resp.status < 500) {
          throw lastError;
        }
        attempt++;
        continue;
      }
      if (resp.data.length === 0) {
        lastError = new Error('红果 App 接口未返回有效数据');
        if (rotations < DEVICE_ROTATIONS) {
          try {
            await HongguoSource.ensureDevice(deviceId, helper);
            rotations++;
            deviceId = helper ? HongguoSource.helperDeviceId : HongguoSource.deviceId;
            installId = helper ? HongguoSource.helperInstallId : HongguoSource.installId;
            continue;
          } catch (error) {
            lastError = new Error(`红果 App 接口未返回有效数据（设备注册失败：${(error as Error).message}）`);
          }
        }
        attempt++;
        continue;
      }
      if (resp.data.length > MAX_BODY_BYTES) {
        throw new Error('红果 App 接口未返回有效数据');
      }
      const parsed: Object | null = QgJson.parse(path === SERIES_PACK_PATH ? preserveSeasonIntegers(resp.text()) : resp.text());
      const result: Record<string, Object> | null = QgJson.obj(parsed);
      if (result === null) {
        throw new Error('红果 App 接口返回格式异常');
      }
      const baseResp: Record<string, Object> | null = QgJson.field(result, 'BaseResp');
      const code: string = firstNonEmpty2(
        QgJson.pick(result, ['code', 'Code', 'status_code']),
        baseResp !== null ? QgJson.pick(baseResp, ['StatusCode']) : '');
      if (code.length > 0 && code !== '0') {
        throw new Error(`红果 App 接口暂不可用（${code.substring(0, 20)}）`);
      }
      return result;
    }
    throw lastError !== null ? lastError : new Error('红果 App 请求失败');
  }

  /** 解析一页目录（parseHongguoCatalogPage） */
  private static parseCatalogPage(result: Object, cursor: HongguoCursor,
    genre: HongguoGenre): HongguoCatalogPage {
    const data: Record<string, Object> | null = QgJson.field(QgJson.obj(result), 'data');
    if (data === null || !Array.isArray(data['video_data'])) {
      throw new Error('App 分类数据格式异常');
    }
    const rows: Object[] = data['video_data'] as Object[];
    const page: HongguoCatalogPage = new HongguoCatalogPage();
    const ids: string[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const drama: QgDrama | null = dramaFromRow(rows[i], genre.name);
      if (drama !== null) {
        page.items.push(drama);
        if (!ids.includes(drama.id)) {
          ids.push(drama.id);
        }
      }
    }
    if (rows.length > 0 && page.items.length === 0) {
      throw new Error('App 分类未返回可识别的剧集');
    }
    const rawNext: string = QgJson.pick(data, ['next_offset']);
    const hasMoreValue: Object | undefined = data['has_more'];
    if (typeof hasMoreValue !== 'boolean') {
      throw new Error('App 分页标记无效，已保留上次位置');
    }
    const hasMore: boolean = hasMoreValue === true;
    let next: number = Number(rawNext);
    if (hasMore && rawNext.length > 0 && Number.isNaN(next)) {
      throw new Error('App 分页标记无效，已保留上次位置');
    }
    if (rawNext.length === 0 || Number.isNaN(next)) {
      next = cursor.offset + rows.length;
    }
    let lastId: string = '';
    let signature: string = '';
    if (page.items.length > 0) {
      lastId = page.items[page.items.length - 1].id;
      ids.sort();
      signature = qgToHex(qgSha256(qgUtf8Encode(ids.join('\n'))));
    }
    if (hasMore && (page.items.length === 0 || next <= cursor.offset || next > 1000000 ||
      signature === cursor.pageSignature)) {
      throw new Error('App 分页未前进，已保留上次位置');
    }
    if (!hasMore && (next < cursor.offset || next > 1000000)) {
      next = cursor.offset;
    }
    const session: string = QgJson.pick(data, ['session_id']);
    if (session.length > 4096 || /[\r\n\0]/.test(session)) {
      throw new Error('App 分页会话无效，已保留上次位置');
    }
    const nextCursor: HongguoCursor = new HongguoCursor();
    nextCursor.exhausted = !hasMore;
    nextCursor.initialized = true;
    nextCursor.offset = next;
    nextCursor.sessionId = session;
    nextCursor.lastId = lastId;
    nextCursor.pageSignature = signature;
    nextCursor.updatedAt = Date.now();
    page.cursor = nextCursor;
    return page;
  }

  /** 拉取某题材一页（失败重试一次：去掉 session_id） */
  private static async fetchFeedPage(genre: HongguoGenre, cursor: HongguoCursor): Promise<HongguoCatalogPage> {
    let sessionAttempt: string = cursor.sessionId;
    let lastError: Error | null = null;
    for (let retry: number = 0; retry < 2; retry++) {
      const selectItems: Record<string, Object> = {
        'genre': [genre.key],
        'sort': ['online_time'],
        'gender': [],
        'category_dim_theme': [],
        'category_dim_role': [],
        'category_dim_epoch': [],
        'online_time': [],
        'creation_status': []
      };
      const payload: Record<string, Object> = {
        'req_scene': genre.scene,
        'offset': cursor.offset,
        'limit': 54,
        'req_type': 'only_content',
        'need_selector_panel': false,
        'client_req_type': cursor.offset > 0 ? 2 : 3,
        'session_id': sessionAttempt,
        'filter_ids': '',
        'select_items': selectItems
      };
      try {
        const result: Object = await HongguoSource.appRequest('POST',
          '/reading/distribution/category/landpage/v/', null, payload);
        return HongguoSource.parseCatalogPage(result, cursor, genre);
      } catch (error) {
        lastError = error as Error;
        sessionAttempt = '';
      }
    }
    throw lastError !== null ? lastError : new Error('红果目录请求失败');
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (page < 1 || page > 100000) {
      throw new Error('红果目录页码无效');
    }
    let genres: HongguoGenre[] = [];
    if (categoryId.length === 0) {
      genres = GENRES;
    } else {
      for (let i: number = 0; i < GENRES.length; i++) {
        if (GENRES[i].key === categoryId) {
          genres.push(GENRES[i]);
        }
      }
      if (genres.length === 0) {
        throw new Error('红果分类无效');
      }
    }
    if (page === 1) {
      for (let i: number = 0; i < genres.length; i++) {
        HongguoSource.cursors.delete(`${categoryId}:${genres[i].key}`);
      }
    }
    const items: QgDrama[] = [];
    const seen: Record<string, number> = {};
    const failures: string[] = [];
    let anyExhausted: boolean = true;
    let anyOpen: boolean = false;
    for (let i: number = 0; i < genres.length; i++) {
      const feedKey: string = `${categoryId}:${genres[i].key}`;
      let cursor: HongguoCursor | undefined = HongguoSource.cursors.get(feedKey);
      if (cursor === undefined) {
        cursor = new HongguoCursor();
        HongguoSource.cursors.set(feedKey, cursor);
      }
      if (cursor.updatedAt > 0 && Date.now() - cursor.updatedAt > CURSOR_STALE_MS) {
        cursor.sessionId = '';
      }
      if (cursor.exhausted) {
        continue;
      }
      anyExhausted = false;
      try {
        const result: HongguoCatalogPage = await HongguoSource.fetchFeedPage(genres[i], cursor);
        HongguoSource.cursors.set(feedKey, result.cursor);
        if (result.cursor.exhausted) {
          // 该题材已取尽
        } else {
          anyOpen = true;
        }
        for (let j: number = 0; j < result.items.length; j++) {
          const drama: QgDrama = result.items[j];
          const position: number | undefined = seen[drama.id];
          if (position !== undefined) {
            mergeDramas(items[position], drama);
          } else {
            seen[drama.id] = items.length;
            items.push(drama);
          }
        }
      } catch (error) {
        failures.push(`${genres[i].name}: ${(error as Error).message}`);
      }
    }
    if (items.length === 0 && failures.length > 0) {
      throw new Error(failures.join('；'));
    }
    const hasMore: boolean = categoryId.length === 0 ? anyOpen : !anyExhausted;
    return new QgPageResult(items, hasMore);
  }

  /** 搜索词校验（hongguoSearchKeyword） */
  private static validateKeyword(keyword: string): string {
    const value: string = keyword.trim().normalize('NFKC');
    if (value.length === 0 || value.length > 80 || /[\x00-\x1f\x7f]/.test(value)) {
      throw new Error('请输入 1 至 80 个字符的搜索词');
    }
    return value;
  }

  /** 名称联想记录（fetchHongguoSuggestionRecords） */
  private static async fetchSuggestionRecords(query: string, count: number): Promise<HongguoSuggestionRecord[]> {
    const url: string = `${WEB_BASE}/incent_resource/suggestion?app_id=8662` +
      `&count=${count}&query=${goQueryEscape(query)}`;
    const headers: Record<string, string> = {
      'User-Agent': WEB_UA,
      'Referer': `${WEB_BASE}/`,
      'Accept': 'application/json',
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    const text: string = await QgHttp.getText(url, headers, SUGGEST_TIMEOUT, 'hongguo');
    const parsed: Object | null = QgJson.parse(text);
    const root: Record<string, Object> | null = QgJson.obj(parsed);
    if (root === null) {
      throw new Error('红果名称联想未返回有效数据');
    }
    let rows: Object[] = QgJson.fieldArr(root, 'suggest_list');
    if (rows.length === 0) {
      const data: Record<string, Object> | null = QgJson.field(root, 'data');
      if (data !== null) {
        rows = QgJson.fieldArr(data, 'suggest_list');
      }
    }
    const records: HongguoSuggestionRecord[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const row: Record<string, Object> | null = QgJson.obj(rows[i]);
      if (row === null) {
        continue;
      }
      const record: HongguoSuggestionRecord = new HongguoSuggestionRecord();
      record.name = QgJson.pick(row, ['name']);
      record.wordType = QgJson.pick(row, ['word_type']);
      record.keyword = QgJson.pick(row, ['keyword']);
      record.videoData = QgJson.field(row, 'video_data');
      records.push(record);
    }
    return records;
  }

  /** 名称匹配（fetchHongguoSearchNames） */
  private static async fetchSearchNames(keyword: string): Promise<QgDrama[]> {
    const records: HongguoSuggestionRecord[] =
      await HongguoSource.fetchSuggestionRecords(keyword, SUGGEST_COUNT);
    const dramas: QgDrama[] = [];
    for (let i: number = 0; i < records.length; i++) {
      const record: HongguoSuggestionRecord = records[i];
      if (record.wordType !== 'short_play_name' || record.videoData === null) {
        continue;
      }
      const siteId: string = QgJson.pick(record.videoData, ['series_id_str', 'series_id']);
      if (!RE_NUMERIC_ID.test(siteId)) {
        continue;
      }
      const wrapper: Record<string, Object> = {
        'video_data': record.videoData,
        'name': record.name,
        'keyword': record.keyword
      };
      const drama: QgDrama | null = dramaFromRow(wrapper, '短剧');
      if (drama !== null && drama.title !== siteId) {
        dramas.push(drama);
      }
    }
    return dramas;
  }

  /** 综合搜索页（fetchHongguoSearchPage，仅第 1 页） */
  private static async fetchSearchPage(keyword: string, pageNum: number): Promise<QgDrama[]> {
    const offset: number = (pageNum - 1) * SEARCH_PAGE_SIZE;
    const params: Record<string, string> = {
      'query': keyword,
      'offset': `${offset}`,
      'count': `${SEARCH_PAGE_SIZE}`,
      'tab_type': SEARCH_TAB
    };
    if (pageNum > 1) {
      params['passback'] = `${offset}`;
      const searchId: string | undefined = HongguoSource.searchIds.get(keyword);
      if (searchId !== undefined && searchId.length > 0) {
        params['search_id'] = searchId;
      }
    }
    const result: Object = await HongguoSource.appRequest('GET', SEARCH_PATH, params, null);
    const tabs: Object[] = QgJson.fieldArr(QgJson.obj(result), 'search_tabs');
    let tab: Record<string, Object> | null = null;
    for (let i: number = 0; i < tabs.length; i++) {
      const candidate: Record<string, Object> | null = QgJson.obj(tabs[i]);
      if (candidate !== null && QgJson.pick(candidate, ['tab_type']) === SEARCH_TAB) {
        tab = candidate;
      }
    }
    if (tab === null) {
      throw new Error('红果搜索未返回有效结果');
    }
    if (pageNum === 1) {
      const searchId: string = QgJson.pick(tab, ['search_id']);
      if (searchId.length > 0) {
        if (HongguoSource.searchIds.size >= 64) {
          HongguoSource.searchIds.clear();
        }
        HongguoSource.searchIds.set(keyword, searchId);
      }
    }
    const cells: Object[] = QgJson.fieldArr(tab, 'data');
    const dramas: QgDrama[] = [];
    const seen: Record<string, boolean> = {};
    for (let i: number = 0; i < cells.length; i++) {
      const cell: Record<string, Object> | null = QgJson.obj(cells[i]);
      if (cell === null) {
        continue;
      }
      const videos: Object[] = QgJson.fieldArr(cell, 'video_data');
      for (let j: number = 0; j < videos.length; j++) {
        const wrapper: Record<string, Object> = { 'video_data': videos[j] };
        const drama: QgDrama | null = dramaFromRow(wrapper, '短剧');
        if (drama !== null && seen[drama.id] !== true) {
          seen[drama.id] = true;
          dramas.push(drama);
        }
      }
    }
    if (cells.length > 0 && dramas.length === 0) {
      throw new Error('红果搜索结果中没有可识别的剧集');
    }
    return dramas;
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    const kw: string = HongguoSource.validateKeyword(keyword);
    if (page > 1) {
      return new QgPageResult([], false);
    }
    const now: number = Date.now();
    const cached: QgDrama[] | undefined = HongguoSource.searchCache.get(kw);
    const cachedAt: number | undefined = HongguoSource.searchCacheAt.get(kw);
    if (cached !== undefined && cachedAt !== undefined && now - cachedAt < SEARCH_TTL) {
      return new QgPageResult(cached, false);
    }
    const names: QgDrama[] = await HongguoSource.fetchSearchNames(kw);
    const pageDramas: QgDrama[] = await HongguoSource.fetchSearchPage(kw, 1);
    // 合并去重（mergeHongguoSearchDramas）
    const merged: QgDrama[] = [];
    const positions: Record<string, number> = {};
    const batches: QgDrama[][] = [pageDramas, names];
    for (let b: number = 0; b < batches.length; b++) {
      for (let i: number = 0; i < batches[b].length; i++) {
        const drama: QgDrama = batches[b][i];
        if (drama.id.length === 0) {
          continue;
        }
        const position: number | undefined = positions[drama.id];
        if (position !== undefined) {
          mergeDramas(merged[position], drama);
        } else {
          positions[drama.id] = merged.length;
          merged.push(drama);
        }
      }
    }
    // 排序：权重升序；同系列季数升序（fetchHongguoSearch 排序段）
    const decorate: HongguoSearchRanked[] = [];
    for (let i: number = 0; i < merged.length; i++) {
      const rank: number = titleSearchRank(merged[i].title, kw);
      const season: HongguoSeasonInfo | null = searchSeason(merged[i].title);
      decorate.push(new HongguoSearchRanked(merged[i], i, rank, season));
    }
    decorate.sort((a: HongguoSearchRanked, b: HongguoSearchRanked): number => {
      if (a.rank !== b.rank) {
        return a.rank - b.rank;
      }
      if (a.season !== null && b.season !== null && a.season.unit === b.season.unit &&
        searchText(a.season.base) === searchText(b.season.base)) {
        return a.season.number - b.season.number;
      }
      return a.index - b.index;
    });
    const sorted: QgDrama[] = [];
    for (let i: number = 0; i < decorate.length; i++) {
      sorted.push(decorate[i].drama);
    }
    if (HongguoSource.searchCache.size >= SEARCH_CACHE_LIMIT) {
      HongguoSource.searchCache.clear();
      HongguoSource.searchCacheAt.clear();
    }
    HongguoSource.searchCache.set(kw, sorted);
    HongguoSource.searchCacheAt.set(kw, Date.now());
    return new QgPageResult(sorted, false);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    let siteId: string = dramaId.startsWith('hongguo:') ? dramaId.substring('hongguo:'.length) : dramaId;
    siteId = siteId.trim();
    if (!RE_NUMERIC_ID.test(siteId)) {
      throw new Error('红果剧集 ID 无效');
    }
    const now: number = Date.now();
    const cached: QgDramaDetail | undefined = HongguoSource.detailCache.get(siteId);
    const cachedAt: number | undefined = HongguoSource.detailCacheAt.get(siteId);
    if (cached !== undefined && cachedAt !== undefined && now - cachedAt < DETAIL_TTL) {
      return cached;
    }
    const payload: Record<string, Object> = { 'series_id': siteId };
    const result: Object = await HongguoSource.appRequest('POST',
      '/novel/player/video_detail/v1/', null, payload);
    const detail: Record<string, Object> | null =
      QgJson.field(QgJson.field(QgJson.obj(result), 'data'), 'video_data');
    if (detail === null) {
      throw new Error('红果 App 未返回所请求的剧集');
    }
    const returnedId: string = QgJson.pick(detail, ['series_id_str', 'series_id']);
    if (returnedId !== siteId) {
      throw new Error('红果 App 未返回所请求的剧集');
    }
    const drama: QgDrama | null = dramaFromRow(detail, '短剧');
    const base: QgDrama = drama !== null ? drama : new QgDrama(`hongguo:${siteId}`, siteId, '短剧');
    base.sourceId = 'hongguo';
    const rows: Object[] = QgJson.fieldArr(detail, 'video_list');
    const episodes: QgEpisode[] = [];
    const seenVid: Record<string, boolean> = {};
    const seenIndex: Record<number, boolean> = {};
    for (let i: number = 0; i < rows.length; i++) {
      const video: Record<string, Object> | null = QgJson.obj(rows[i]);
      if (video === null) {
        continue;
      }
      const videoId: string = QgJson.pick(video, ['vid']);
      const index: number = Number(QgJson.pick(video, ['vid_index']));
      if (Number.isNaN(index) || index < 1 || !RE_NUMERIC_ID.test(videoId)) {
        throw new Error('红果 App 分集编号或视频 ID 无效');
      }
      const seriesRef: string = QgJson.pick(video, ['series_id']);
      if (seriesRef.length > 0 && seriesRef !== siteId) {
        throw new Error('红果 App 返回了其他剧集的分集');
      }
      if (seenVid[videoId] === true || seenIndex[index] === true) {
        throw new Error('红果 App 返回了重复分集');
      }
      seenVid[videoId] = true;
      seenIndex[index] = true;
      episodes.push(new QgEpisode(videoId, `第${index}集`, index));
    }
    episodes.sort((a: QgEpisode, b: QgEpisode): number => a.order - b.order);
    const total: number = Number(QgJson.pick(detail, ['episode_cnt']));
    if (episodes.length === 0 || (!Number.isNaN(total) && total > episodes.length)) {
      throw new Error('红果 App 未返回完整分集，已尝试其他详情入口');
    }
    for (let i: number = 0; i < episodes.length; i++) {
      if (episodes[i].order !== i + 1) {
        throw new Error('红果 App 分集列表不连续');
      }
    }
    base.episodeCount = episodes.length;
    const entry: QgDramaDetail = new QgDramaDetail(base, episodes);
    if (HongguoSource.detailCache.size >= DETAIL_CACHE_LIMIT) {
      HongguoSource.detailCache.clear();
      HongguoSource.detailCacheAt.clear();
    }
    HongguoSource.detailCache.set(siteId, entry);
    HongguoSource.detailCacheAt.set(siteId, Date.now());
    return entry;
  }

  async seasons(dramaId: string): Promise<QgSeason[]> {
    const deadline: number = Date.now() + SERIES_SEASON_TIMEOUT;
    let timer: number = -1;
    const timeout: Promise<QgSeason[]> = new Promise<QgSeason[]>((resolve, reject) => {
      timer = setTimeout(() => { reject(new Error('红果分季请求超时，请重试')); }, SERIES_SEASON_TIMEOUT);
    });
    try {
      return await Promise.race([this.loadSeasons(dramaId, deadline), timeout]);
    } finally {
      if (timer >= 0) clearTimeout(timer);
    }
  }

  private async loadSeasons(dramaId: string, deadline: number): Promise<QgSeason[]> {
    const siteId: string = dramaId.startsWith('hongguo:') ? dramaId.slice('hongguo:'.length) : '';
    if (siteId.startsWith('book-')) return [];
    if (!isSeasonId(siteId)) throw new Error('红果分季剧集 ID 无效');
    const raw: Object = await HongguoSource.appRequest('POST', SERIES_PACK_PATH, null,
      seasonPackBody([siteId], ['album_id', 'album_title', 'album_serial_count', 'series_in_album_order', 'album_series_ids']),
      false, deadline);
    const row: Record<string, Object> | null = QgJson.field(QgJson.field(QgJson.obj(raw), 'data'), siteId);
    const album: Record<string, Object> | null = QgJson.field(row, 'album_info');
    const rawIds: Object[] = QgJson.fieldArr(album, 'album_series_ids');
    if (rawIds.length < 2 || rawIds.length > SERIES_SEASON_LIMIT) return [];
    const ids: string[] = [];
    for (const value of rawIds) {
      const id: string = QgJson.str(value);
      if (!isSeasonId(id) || ids.includes(id)) {
        throw new Error('红果分季列表包含无效或重复剧集');
      }
      ids.push(id);
    }
    if (!ids.includes(siteId)) return [];
    let packed: Record<string, Object> | null = null;
    try {
      const result: Object = await HongguoSource.appRequest('POST', SERIES_PACK_PATH, null,
        seasonPackBody(ids, ['series_id', 'series_title', 'series_cover', 'series_intro', 'episode_cnt',
          'series_status', 'category_schema', 'series_play_cnt', 'publish_time']), false, deadline);
      packed = QgJson.field(QgJson.obj(result), 'data');
    } catch (error) {
      if (Date.now() >= deadline) throw new Error('红果分季请求超时');
    }
    const seasons: QgSeason[] = [];
    for (let index: number = 0; index < ids.length; index++) {
      if (Date.now() >= deadline) throw new Error('红果分季请求超时，请重试');
      const id: string = ids[index];
      const item: Record<string, Object> | null = QgJson.field(packed, id);
      const base: Record<string, Object> | null = QgJson.field(item, 'base_info');
      let drama: QgDrama | null = null;
      if (base !== null && QgJson.pick(base, ['series_id_str', 'series_id']) === id &&
        QgJson.pick(base, ['series_title']).length > 0) {
        drama = dramaFromRow(base, '短剧');
      }
      if (drama === null && Date.now() < deadline) {
        try {
          const payload: Record<string, Object> = { 'series_id': id };
          const result: Object = await HongguoSource.appRequest('POST', '/novel/player/video_detail/v1/',
            null, payload, false, deadline);
          const detail: Record<string, Object> | null =
            QgJson.field(QgJson.field(QgJson.obj(result), 'data'), 'video_data');
          if (detail !== null && QgJson.pick(detail, ['series_id_str', 'series_id']) === id &&
            QgJson.pick(detail, ['series_title', 'series_name', 'title']).length > 0) drama = dramaFromRow(detail, '短剧');
        } catch (error) {
        }
      }
      if (Date.now() >= deadline) throw new Error('红果分季请求超时，请重试');
      if (drama === null) throw new Error(`红果第${index + 1}季信息暂不可用，请重试`);
      seasons.push(new QgSeason(index + 1, drama));
    }
    return seasons.length >= 2 && seasons.some((season: QgSeason): boolean => season.drama.id === dramaId) ? seasons : [];
  }

  /** 变体地址提取（hongguoMediaAddresses） */
  private static mediaAddresses(variant: Record<string, Object>): string[] {
    const addresses: string[] = [];
    const seen: Record<string, boolean> = {};
    const keys: string[] = ['main_url', 'backup_url', 'backup_url_1', 'backup_url_2', 'backup_urls', 'url_list'];
    for (let k: number = 0; k < keys.length; k++) {
      const value: Object | undefined = variant[keys[k]];
      if (typeof value === 'string') {
        let address: string = value.trim();
        if (address.length > 8192) {
          continue;
        }
        if (!isHttpMediaUrl(address)) {
          try {
            address = qgUtf8Decode(decodeBase64(address)).trim();
          } catch (error) {
            continue;
          }
        }
        if (isHttpMediaUrl(address) && seen[address] !== true) {
          seen[address] = true;
          addresses.push(address);
        }
      } else if (Array.isArray(value)) {
        const list: Object[] = value as Object[];
        for (let i: number = 0; i < list.length; i++) {
          const item: Object | undefined = list[i];
          if (typeof item !== 'string') {
            continue;
          }
          let address: string = item.trim();
          if (address.length > 8192) {
            continue;
          }
          if (!isHttpMediaUrl(address)) {
            try {
              address = qgUtf8Decode(decodeBase64(address)).trim();
            } catch (error) {
              continue;
            }
          }
          if (isHttpMediaUrl(address) && seen[address] !== true) {
            seen[address] = true;
            addresses.push(address);
          }
        }
      }
    }
    return addresses;
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    let siteId: string = dramaId.startsWith('hongguo:') ? dramaId.substring('hongguo:'.length) : dramaId;
    siteId = siteId.trim();
    if (!RE_NUMERIC_ID.test(siteId)) {
      throw new Error('红果剧集 ID 无效');
    }
    const videoId: string = episodeId.trim();
    if (!RE_NUMERIC_ID.test(videoId)) {
      throw new Error('红果视频 ID 无效');
    }
    let info: QgPlayInfo;
    try {
      info = await HongguoSource.appMedia(videoId);
    } catch (appError) {
      const appErr: Error = appError as Error;
      try {
        info = await HongguoSource.webMedia(siteId, videoId);
      } catch (webError) {
        const webErr: Error = webError as Error;
        throw new Error(`红果 App 取流失败：${appErr.message}；网页取流失败：${webErr.message}`);
      }
    }
    // App 接口只返回加密流时，先试网页播放页的明文地址，避免走本地解密。
    // 网页流可能仅允许试看或 ID 校验失败，失败就保留 App 加密流。
    if (info.cencKey.length > 0) {
      try {
        const plain: QgPlayInfo = await HongguoSource.webMedia(siteId, videoId);
        if (plain.url.length > 0) {
          info = plain;
        }
      } catch (webError) {
        // 网页兜底不可用，继续用 App 加密流
      }
    }
    // 弹幕：评论接口按 videoId 分组（见 HongguoDanmaku.ets）
    info.danmakuId = videoId;
    return info;
  }

  /** App 接口取流（resolveHongguoAppMedia） */
  private static async appMedia(videoId: string): Promise<QgPlayInfo> {
    if (!RE_NUMERIC_ID.test(videoId)) {
      throw new Error('红果视频 ID 无效');
    }
    let lastErrorMessage: string = '红果 App 未返回兼容的媒体';
    for (const helper of [false, true]) {
      try {
        return await HongguoSource.fetchAppMedia(videoId, helper);
      } catch (error) {
        const err: Error = error as Error;
        if (!(err instanceof HongguoNoCompatibleMedia)) {
          throw err;
        }
        lastErrorMessage = err.message;
      }
    }
    try {
      await HongguoSource.ensureDevice(HongguoSource.helperDeviceId, true);
    } catch (error) {
      throw new Error(`${lastErrorMessage}；更换辅助设备也没有成功：${(error as Error).message}`);
    }
    return HongguoSource.fetchAppMedia(videoId, true);
  }

  private static async fetchAppMedia(videoId: string, helper: boolean): Promise<QgPlayInfo> {
    let tabError: Error = new Error('红果分集取流失败');
    try {
      const query: Record<string, string> = {
        'video_id': videoId, 'video_id_type': '0', 'device_level': '1',
        'need_all_video_definition': '1', 'need_mp4_align': '0',
        'use_os_player': '0', 'video_platform': '1024', 'source': '0', 'from_video_id': ''
      };
      const result: Object = await HongguoSource.appRequest('GET', VIDEO_TAB_PATH, query, null, helper);
      const root: Record<string, Object> | null = QgJson.field(QgJson.obj(result), 'data');
      const entries: Record<string, Object> | null = QgJson.field(root, 'video_model_data');
      return await HongguoSource.mediaFromData(QgJson.field(entries, videoId));
    } catch (error) {
      if (error instanceof HongguoNoCompatibleMedia) {
        throw error;
      }
      tabError = error as Error;
    }
    try {
      return await HongguoSource.playerMedia(videoId, helper);
    } catch (error) {
      if (error instanceof HongguoNoCompatibleMedia) {
        throw error;
      }
      throw new Error(`${tabError.message}；播放器接口：${(error as Error).message}`);
    }
  }

  private static async playerMedia(videoId: string, helper: boolean): Promise<QgPlayInfo> {
    const bizParam: Record<string, Object> = {
      'detail_page_version': 0, 'device_level': 1,
      'disable_digg_stat': false, 'disable_video_relate_book': false,
      'need_all_video_definition': true, 'need_mp4_align': false,
      'use_os_player': false, 'use_server_dns': false, 'video_platform': 1024
    };
    const videoMap: Record<string, Object> = { '1004': [videoId] };
    const payload: Record<string, Object> = {
      'biz_param': bizParam, 'mixed_video_id_map': videoMap, 'dr_scene': 'player'
    };
    const result: Object = await HongguoSource.appRequest('POST', PLAYBACK_PATH, null, payload, helper);
    const entries: Record<string, Object> | null = QgJson.field(QgJson.obj(result), 'data');
    const group: Record<string, Object> | null = QgJson.field(entries, '1004');
    const data: Record<string, Object> | null = QgJson.field(group !== null ? group : entries, videoId);
    return await HongguoSource.mediaFromData(data);
  }

  private static async mediaFromData(data: Record<string, Object> | null): Promise<QgPlayInfo> {
    if (data === null || Object.keys(data).length === 0) {
      throw new Error('红果 App 未返回所请求的分集播放信息');
    }
    // video_model：对象或 base64 编码 JSON（resolveHongguoAppMedia）
    let model: Record<string, Object> | null = QgJson.field(data, 'video_model');
    const encoded: Object | undefined = data['video_model'];
    if (model === null && typeof encoded === 'string' && encoded.length > 0) {
      model = QgJson.obj(QgJson.parse(encoded));
      if (model === null) {
        try {
          const raw: Uint8Array = decodeBase64(encoded);
          if (raw.length > 0) {
            model = QgJson.obj(QgJson.parse(qgUtf8Decode(raw)));
          }
        } catch (error) {
        }
      }
      if (model === null) {
        throw new Error('红果 App 播放信息格式异常');
      }
    }
    if (model === null || Object.keys(model).length === 0) {
      const fallback: Record<string, Object> = {
        'video_list': data['video_list'] ?? [],
        'video_duration': data['video_duration'] ?? 0,
        'duration': data['duration'] ?? 0
      };
      model = fallback;
    }
    return HongguoSource.selectMediaWithFallback(model);
  }

  /** selectMedia 失败且无兼容线路时走备用接口取 H.265/H.264 线路（mediaFromModel） */
  private static async selectMediaWithFallback(model: Record<string, Object>): Promise<QgPlayInfo> {
    try {
      return HongguoSource.selectMedia(model);
    } catch (error) {
      if (!(error instanceof HongguoNoCompatibleMedia)) {
        throw error as Error;
      }
      return HongguoSource.fallbackMedia(model, error);
    }
  }

  /** 备用线路取流（fallbackMedia）：按 codec_type 依次请求 fallback_api 端点 */
  private static async fallbackMedia(model: Record<string, Object>,
    original: HongguoNoCompatibleMedia): Promise<QgPlayInfo> {
    const api: Record<string, Object> | null = QgJson.field(model, 'fallback_api');
    const endpoint: string = api !== null ? QgJson.pick(api, ['fallback_api']) : '';
    if (endpoint.length === 0) {
      throw original;
    }
    let lastErrorMessage: string = original.message;
    for (let i: number = 0; i < FALLBACK_CODEC_TYPES.length; i++) {
      try {
        const data: Record<string, Object> = await HongguoSource.fetchFallbackPlay(endpoint, FALLBACK_CODEC_TYPES[i]);
        const fallbackModel: Record<string, Object> = {
          'video_list': HongguoSource.fallbackVariants(data),
          'video_duration': QgJson.pick(data, ['video_duration'])
        };
        return HongguoSource.selectMedia(fallbackModel);
      } catch (error) {
        const err: Error = error as Error;
        if (!(err instanceof HongguoNoCompatibleMedia)) {
          throw new Error(`${original.message}；备用线路：${err.message}`);
        }
        lastErrorMessage = err.message;
      }
    }
    throw new HongguoNoCompatibleMedia(`${original.message}；备用线路：${lastErrorMessage}`);
  }

  /** 请求备用线路端点（fetchFallbackPlay）：替换/追加 codec_type 参数 */
  private static async fetchFallbackPlay(endpoint: string, codecType: string): Promise<Record<string, Object>> {
    const pattern: RegExp = /([?&])codec_type=[^&]*/;
    const address: string = pattern.test(endpoint)
      ? endpoint.replace(pattern, `$1codec_type=${codecType}`)
      : endpoint + (endpoint.includes('?') ? '&' : '?') + 'codec_type=' + codecType;
    let resp: QgHttpResponse;
    try {
      resp = await QgHttp.request(address, 'GET', {
        'User-Agent': PLAYBACK_UA,
        'Accept': 'application/json'
      }, null, REQUEST_TIMEOUT, MAX_BODY_BYTES, 30, 'hongguo');
    } catch (error) {
      throw new Error(`红果备用线路请求失败：${(error as Error).message}`);
    }
    if (resp.status !== 200) {
      throw new Error(`红果备用线路 HTTP ${resp.status}`);
    }
    const result: Record<string, Object> | null = QgJson.obj(QgJson.parse(resp.text()));
    const info: Record<string, Object> | null = QgJson.field(result, 'video_info');
    const data: Record<string, Object> | null = QgJson.field(info, 'data');
    if (data === null || Object.keys(data).length === 0) {
      throw new Error('红果备用线路未返回有效数据');
    }
    return data;
  }

  /** 备用线路变体列表（fallbackVariants）：解码 main_url/backup_url_* 加密播放地址 */
  private static fallbackVariants(data: Record<string, Object>): Object[] {
    const seed: string = QgJson.pick(data, ['key_seed']);
    const variants: Object[] = [];
    let versionError: Error | null = null;
    let decoded: number = 0;
    const entries: Object[] = HongguoSource.fallbackEntries(data);
    const urlKeys: string[] = ['main_url', 'backup_url_1', 'backup_url_2'];
    for (let i: number = 0; i < entries.length; i++) {
      const entry: Record<string, Object> | null = QgJson.obj(entries[i]);
      if (entry === null) {
        continue;
      }
      const meta: Record<string, Object> = {
        'codec_type': QgJson.pick(entry, ['codec_type']),
        'definition': QgJson.pick(entry, ['definition']),
        'vwidth': QgJson.pick(entry, ['vwidth']),
        'vheight': QgJson.pick(entry, ['vheight'])
      };
      const variant: Record<string, Object> = {
        'gear_des_key': QgJson.pick(entry, ['gear_des_key']),
        'video_meta': meta
      };
      for (let j: number = 0; j < urlKeys.length; j++) {
        let address: string = '';
        try {
          address = HongguoSource.decodePlayUrl(QgJson.pick(entry, [urlKeys[j]]), seed);
        } catch (error) {
          if (!(error instanceof HongguoUnsupportedPlayUrl)) {
            throw error as Error;
          }
          versionError = error as Error;
          continue;
        }
        if (address.length > 0) {
          variant[urlKeys[j]] = address;
          decoded++;
        }
      }
      const spade: string = QgJson.pick(entry, ['spade_a']);
      const method: string = QgJson.pick(entry, ['encryption_method']);
      if (spade.length > 0 || method.length > 0 || entry['encrypt'] === true) {
        const encryption: Record<string, Object> = {
          'spade_a': spade,
          'encryption_method': method,
          'encrypt': entry['encrypt'] === true
        };
        variant['encrypt_info'] = encryption;
      }
      variants.push(variant);
    }
    if (versionError !== null && decoded === 0) {
      throw versionError;
    }
    return variants;
  }

  /** video_list 兼容数组/字典两种结构（fallbackEntries） */
  private static fallbackEntries(data: Record<string, Object>): Object[] {
    const list: Object | undefined = data['video_list'];
    if (Array.isArray(list)) {
      return list as Object[];
    }
    const rows: Record<string, Object> | null = QgJson.obj(list);
    if (rows !== null) {
      const keys: string[] = Object.keys(rows);
      const out: Object[] = [];
      for (let i: number = 0; i < keys.length; i++) {
        out.push(rows[keys[i]]);
      }
      return out;
    }
    return [];
  }

  /** 解码备用线路播放地址（decodePlayUrl）：a8 00 头 + AES-CBC(SHA512 派生密钥) */
  private static decodePlayUrl(encoded: string, seed: string): string {
    if (encoded.length === 0 || seed.length === 0) {
      return encoded;
    }
    let key: Uint8Array;
    let raw: Uint8Array;
    try {
      key = decodeBase64(seed);
      raw = decodeBase64(encoded);
    } catch (error) {
      return encoded;
    }
    if (raw.length < 20 || raw[0] !== 0xa8 || raw[1] !== 0x00 ||
      (raw.length - PLAY_URL_HEADER_SIZE) % 16 !== 0) {
      return encoded;
    }
    for (let i: number = 0; i < PLAY_URL_SALTS.length; i++) {
      const address: string = HongguoSource.decryptPlayUrl(raw, key, PLAY_URL_SALTS[i]);
      if (address.length > 0) {
        return address;
      }
    }
    throw new HongguoUnsupportedPlayUrl(`红果备用线路编码版本 ${raw[2] | (raw[3] << 8)} 暂不支持`);
  }

  /** 单盐播放地址解密（decryptPlayUrl）：digest = SHA512(SHA512(key)+salt)，key/iv 取前 32 字节 */
  private static decryptPlayUrl(raw: Uint8Array, key: Uint8Array, salt: string): string {
    try {
      const digest: Uint8Array = qgSha512(qgConcat([qgSha512(key), qgFromHex(salt)]));
      const plain: Uint8Array = qgAesCbcDecryptNoUnpad(raw.slice(PLAY_URL_HEADER_SIZE),
        digest.slice(0, 16), digest.slice(16, 32));
      if (plain.length === 0) {
        return '';
      }
      const pad: number = plain[plain.length - 1];
      if (pad < 1 || pad > 16 || pad > plain.length) {
        return '';
      }
      for (let i: number = plain.length - pad; i < plain.length; i++) {
        if (plain[i] !== pad) {
          return '';
        }
      }
      const address: string = qgUtf8Decode(plain.slice(0, plain.length - pad));
      return PLAY_URL_PATTERN.test(address) ? address : '';
    } catch (error) {
      return '';
    }
  }

  /** 网页播放页取流兜底（resolveHongguoWebMedia）：App 流全加密/失败时使用 */
  private static async webMedia(seriesId: string, videoId: string): Promise<QgPlayInfo> {
    const pageURL: string = `${WEB_BASE}/player/${seriesId}/${videoId}`;
    const headers: Record<string, string> = {
      'User-Agent': WEB_UA,
      'Referer': `${WEB_BASE}/`,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    const body: string = await QgHttp.getText(pageURL, headers, REQUEST_TIMEOUT, 'hongguo');
    const router: RouterData = parseRouterData(body);
    const page: Record<string, Object> | null = routerLoaderMap(router.data, ['player_', 'player_page']);
    // 校验剧集匹配：JSON 数字大 id 在 JS 下有精度损失，需辅以原文包含性校验
    const parsedVid: string = page !== null ? QgJson.pick(page, ['vid']) : '';
    const parsedSeries: string = page !== null ? QgJson.pick(page, ['series_id']) : '';
    const idsMatch: boolean = (parsedVid === videoId && parsedSeries === seriesId) ||
      (router.rawJson.includes(videoId) && router.rawJson.includes(seriesId));
    if (page === null || !idsMatch) {
      throw new Error('红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限');
    }
    const info2: Record<string, Object> | null = QgJson.field(page, 'video_player_info');
    const addresses: string[] = info2 !== null ? HongguoSource.mediaAddresses(info2) : [];
    if (addresses.length === 0) {
      throw new Error('红果该集未提供公开播放地址，可能需要登录或 App 授权');
    }
    const durationSeconds: number = Number(info2 !== null ? QgJson.pick(info2, ['duration']) : '');
    const out: QgPlayInfo = new QgPlayInfo();
    out.url = addresses[0];
    out.referer = `${WEB_BASE}/`;
    out.headers = { 'User-Agent': WEB_UA, 'Referer': out.referer };
    if (!Number.isNaN(durationSeconds) && durationSeconds > 0) {
      out.durationMs = durationSeconds * 1000;
    }
    out.routes = addresses.slice(0, 16);
    return out;
  }

  /** 选择最佳可播变体（selectHongguoAppMedia；加密变体派生 CENC 密钥后经网关解密播放） */
  private static selectMedia(model: Record<string, Object>): QgPlayInfo {
    let variants: Object[] = QgJson.fieldArr(model, 'video_list');
    if (variants.length === 0) {
      const rows: Record<string, Object> | null = QgJson.field(model, 'video_list');
      if (rows !== null) {
        const keys: string[] = Object.keys(rows).sort();
        for (let i: number = 0; i < keys.length; i++) {
          variants.push(rows[keys[i]]);
        }
      }
    }
    const durationSeconds: number = Number(QgJson.pick(model, ['video_duration', 'duration']));
    const choices: HongguoScored[] = [];
    let encryptedSkipped: number = 0;
    for (let i: number = 0; i < variants.length; i++) {
      const variant: Record<string, Object> | null = QgJson.obj(variants[i]);
      if (variant === null) {
        continue;
      }
      const meta: Record<string, Object> | null = QgJson.field(variant, 'video_meta');
      const codec: string = meta !== null ? QgJson.pick(meta, ['codec_type']).toLowerCase() : '';
      if (codec === 'bytevc2' || QgJson.pick(variant, ['gear_des_key']).toLowerCase().includes('bytevc2')) {
        continue;
      }
      const addresses: string[] = HongguoSource.mediaAddresses(variant);
      if (addresses.length === 0) {
        continue;
      }
      const encryption: Record<string, Object> | null = QgJson.field(variant, 'encrypt_info');
      const spade: string = encryption !== null ? QgJson.pick(encryption, ['spade_a', 'spade']) : '';
      const encrypted: boolean = spade.length > 0 ||
        (encryption !== null && encryption['encrypt'] === true) ||
        (encryption !== null && QgJson.pick(encryption, ['encryption_method']) === 'cenc-aes-ctr');
      let cencKeyHex: string = '';
      if (encrypted) {
        const contentKey: Uint8Array | null = spade.length > 0 ? hongguoContentKey(spade) : null;
        if (contentKey === null) {
          // v2 标签或结构异常：无法解密，跳过该变体
          encryptedSkipped++;
          continue;
        }
        cencKeyHex = qgToHex(contentKey);
      }
      let height: number = meta !== null ? Number(QgJson.pick(meta, ['vheight'])) : 0;
      if (Number.isNaN(height)) {
        height = 0;
      }
      const definitionMatch: RegExpMatchArray | null = meta !== null ?
        QgJson.pick(meta, ['definition']).match(/[0-9]+/) : null;
      if (definitionMatch !== null) {
        const definition: number = Number(definitionMatch[0]);
        if (definition > 0) {
          height = definition;
        }
      } else if (meta !== null) {
        const width: number = Number(QgJson.pick(meta, ['vwidth']));
        if (width > 0 && (height === 0 || width < height)) {
          height = width;
        }
      }
      let score: number = height * 10;
      if (codec === 'h264' || codec === 'avc1') {
        score++;
      }
      // 明文流优先：加密流需要在本地网关用纯 JS 对整个 MP4 做 AES-CTR 解密，
      // 实测会长时间占住主线程触发 THREAD_BLOCK_6S（AppFreeze 后被系统杀掉）。
      // 只要服务端给了任何明文变体就选它，宁可画质略低也要能直接播。
      if (cencKeyHex.length === 0) {
        score += 100000;
      }
      for (let j: number = 0; j < addresses.length; j++) {
        choices.push(new HongguoScored(addresses[j], score, height, cencKeyHex));
      }
    }
    if (choices.length === 0) {
      if (encryptedSkipped > 0) {
        throw new Error('红果该集为加密内容（CENC），内容密钥不可用');
      }
      throw new HongguoNoCompatibleMedia('红果 App 未返回兼容的媒体，已跳过不支持的编码或无地址的线路');
    }
    choices.sort((a: HongguoScored, b: HongguoScored): number => b.score - a.score);
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = choices[0].url;
    info.cencKey = choices[0].cencKey;
    info.referer = 'https://novel.snssdk.com/';
    info.headers = { 'User-Agent': APP_UA, 'Referer': info.referer };
    if (!Number.isNaN(durationSeconds) && durationSeconds > 0) {
      info.durationMs = durationSeconds * 1000;
    }
    // 候选线路（去重保序，最多 16 条）与清晰度列表
    const seenUrl: Record<string, boolean> = {};
    const seenQuality: Record<string, boolean> = {};
    for (let i: number = 0; i < choices.length; i++) {
      const c: HongguoScored = choices[i];
      // 线路需与所选线路使用同一内容密钥（跨密钥线路无法复用同一 cencKey 播放）
      if (c.cencKey !== choices[0].cencKey) {
        continue;
      }
      if (seenUrl[c.url] !== true) {
        seenUrl[c.url] = true;
        if (info.routes.length < 16) {
          info.routes.push(c.url);
        }
      }
      const heightKey: string = `${c.height}`;
      if (c.height > 0 && seenQuality[heightKey] !== true) {
        seenQuality[heightKey] = true;
        info.qualities.push(c.height);
      }
    }
    info.qualities.sort((a: number, b: number): number => b - a);
    info.quality = choices[0].height;
    return info;
  }
}

/** 播放变体打分项 */
class HongguoScored {
  url: string = '';
  score: number = 0;
  height: number = 0;
  /** CENC 内容密钥 hex（空 = 未加密） */
  cencKey: string = '';

  constructor(url: string, score: number, height: number, cencKey: string) {
    this.url = url;
    this.score = score;
    this.height = height;
    this.cencKey = cencKey;
  }
}

/** 搜索排序装饰 */
class HongguoSearchRanked {
  drama: QgDrama;
  index: number = 0;
  rank: number = 0;
  season: HongguoSeasonInfo | null = null;

  constructor(drama: QgDrama, index: number, rank: number, season: HongguoSeasonInfo | null) {
    this.drama = drama;
    this.index = index;
    this.rank = rank;
    this.season = season;
  }
}
