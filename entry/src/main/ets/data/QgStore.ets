/**
 * 青果APP 本地存储（Preferences 持久化）。
 * 参照真果鉴 local_store.dart 的职责划分：观看记录 / 追剧 / 搜索历史 / 应用设置。
 * 全部同步读内存、写时落盘，init 一次后即可同步使用。
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { QgAppSettings, QgBookmarkRecord, QgFollowRecord, QgQueueRecord, QgWatchRecord } from '../model/QgModels';
import { QgHttp } from './QgHttp';
import { QgTheme } from '../components/QgTheme';

const KEY_WATCH: string = 'qg_watch';
const KEY_FOLLOWS: string = 'qg_follows';
const KEY_SEARCH: string = 'qg_search_history';
const KEY_SETTINGS: string = 'qg_settings';
const KEY_QUEUE: string = 'qg_watch_queue';
const KEY_BOOKMARKS: string = 'qg_bookmarks';
const KEY_INTRO_MARKS: string = 'qg_intro_marks';

export class QgStore {
  private static instance: QgStore | null = null;

  private pref: preferences.Preferences | null = null;
  private watchList: QgWatchRecord[] = [];
  private followList: QgFollowRecord[] = [];
  private searchList: string[] = [];
  private settings: QgAppSettings = new QgAppSettings();
  private queueList: QgQueueRecord[] = [];
  private bookmarkList: QgBookmarkRecord[] = [];
  private introMarks: Record<string, number> = {};

  static getInstance(): QgStore {
    if (QgStore.instance === null) {
      QgStore.instance = new QgStore();
    }
    return QgStore.instance as QgStore;
  }

  /**
   * 初始化（EntryAbility onCreate 调用），幂等。
   * 必须同步：UI 在 onCreate 之后立即渲染，原来的异步 getPreferences 会让首页
   * 先读到默认设置（站源回退 hongguo、代理开关丢失），表现为「切换站源重启后失效」。
   */
  init(context: Context): void {
    if (this.pref !== null) {
      return;
    }
    try {
      this.pref = preferences.getPreferencesSync(context, { name: 'qingguo_store' });
      this.loadAll();
    } catch (error) {
      this.pref = null;
    }
  }

  // ---------- 观看记录 ----------

  getWatchList(): QgWatchRecord[] {
    return this.watchList.slice().sort((a: QgWatchRecord, b: QgWatchRecord): number => b.updatedAt - a.updatedAt);
  }

  getWatch(dramaId: string): QgWatchRecord | undefined {
    return this.watchList.find((r: QgWatchRecord): boolean => r.dramaId === dramaId);
  }

  saveWatch(record: QgWatchRecord): void {
    if (record.dramaId.length === 0) {
      return;
    }
    const idx: number = this.watchList.findIndex((r: QgWatchRecord): boolean => r.dramaId === record.dramaId);
    const saved: QgWatchRecord = new QgWatchRecord();
    saved.dramaId = record.dramaId;
    saved.episode = record.episode;
    saved.progress = record.progress;
    saved.duration = record.duration;
    saved.updatedAt = record.updatedAt;
    saved.title = record.title;
    saved.cover = record.cover;
    if (idx >= 0) {
      this.watchList[idx] = saved;
    } else {
      this.watchList.push(saved);
    }
    this.persist(KEY_WATCH, JSON.stringify(this.watchList));
  }

  removeWatch(dramaId: string): void {
    this.watchList = this.watchList.filter((r: QgWatchRecord): boolean => r.dramaId !== dramaId);
    this.persist(KEY_WATCH, JSON.stringify(this.watchList));
  }

  clearWatch(): void {
    this.watchList = [];
    this.persist(KEY_WATCH, JSON.stringify(this.watchList));
  }

  // ---------- 待看队列 ----------

  getQueueList(): QgQueueRecord[] {
    return this.queueList.slice().sort((a: QgQueueRecord, b: QgQueueRecord): number => a.addedAt - b.addedAt);
  }

  isQueued(dramaId: string): boolean {
    return this.queueList.some((r: QgQueueRecord): boolean => r.dramaId === dramaId);
  }

  toggleQueue(dramaId: string, title: string, cover: string, episodeCount: number,
    finished: boolean, sourceId: string): boolean {
    const idx = this.queueList.findIndex((r: QgQueueRecord): boolean => r.dramaId === dramaId);
    if (idx >= 0) {
      this.queueList.splice(idx, 1);
      this.persist(KEY_QUEUE, JSON.stringify(this.queueList));
      return false;
    }
    const rec: QgQueueRecord = new QgQueueRecord();
    rec.dramaId = dramaId;
    rec.addedAt = Date.now();
    rec.title = title;
    rec.cover = cover;
    rec.episodeCount = episodeCount;
    rec.finished = finished;
    rec.sourceId = sourceId;
    this.queueList.push(rec);
    this.persist(KEY_QUEUE, JSON.stringify(this.queueList));
    return true;
  }

  removeQueue(dramaId: string): void {
    this.queueList = this.queueList.filter((r: QgQueueRecord): boolean => r.dramaId !== dramaId);
    this.persist(KEY_QUEUE, JSON.stringify(this.queueList));
  }

  // ---------- 片段书签 ----------

  getBookmarks(dramaId: string, episode: number): QgBookmarkRecord[] {
    return this.bookmarkList.filter((r: QgBookmarkRecord): boolean => r.dramaId === dramaId && r.episode === episode)
      .sort((a: QgBookmarkRecord, b: QgBookmarkRecord): number => a.seconds - b.seconds);
  }

  addBookmark(record: QgBookmarkRecord): void {
    if (record.dramaId.length === 0 || record.seconds < 0) {
      return;
    }
    const exists = this.bookmarkList.some((r: QgBookmarkRecord): boolean =>
      r.dramaId === record.dramaId && r.episode === record.episode && Math.abs(r.seconds - record.seconds) < 3);
    if (exists) {
      return;
    }
    const saved: QgBookmarkRecord = new QgBookmarkRecord();
    saved.dramaId = record.dramaId;
    saved.title = record.title;
    saved.episode = record.episode;
    saved.seconds = record.seconds;
    saved.createdAt = record.createdAt > 0 ? record.createdAt : Date.now();
    this.bookmarkList.push(saved);
    this.persist(KEY_BOOKMARKS, JSON.stringify(this.bookmarkList));
  }

  removeBookmark(record: QgBookmarkRecord): void {
    this.bookmarkList = this.bookmarkList.filter((r: QgBookmarkRecord): boolean =>
      !(r.dramaId === record.dramaId && r.episode === record.episode && r.createdAt === record.createdAt));
    this.persist(KEY_BOOKMARKS, JSON.stringify(this.bookmarkList));
  }

  getIntroMark(dramaId: string): number {
    return this.introMarks[dramaId] ?? 0;
  }

  setIntroMark(dramaId: string, seconds: number): void {
    if (dramaId.length === 0 || seconds < 1) return;
    this.introMarks[dramaId] = Math.floor(seconds);
    this.persist(KEY_INTRO_MARKS, JSON.stringify(this.introMarks));
  }

  // ---------- 追剧 ----------

  getFollowList(): QgFollowRecord[] {
    return this.followList.slice().sort((a: QgFollowRecord, b: QgFollowRecord): number => b.addedAt - a.addedAt);
  }

  isFollowed(dramaId: string): boolean {
    return this.followList.some((r: QgFollowRecord): boolean => r.dramaId === dramaId);
  }

  /** 返回切换后的状态：true=已追 */
  toggleFollow(dramaId: string, title: string, cover: string, episodeCount: number,
    finished: boolean, sourceId: string): boolean {
    const idx: number = this.followList.findIndex((r: QgFollowRecord): boolean => r.dramaId === dramaId);
    if (idx >= 0) {
      this.followList.splice(idx, 1);
      this.persist(KEY_FOLLOWS, JSON.stringify(this.followList));
      return false;
    }
    const rec: QgFollowRecord = new QgFollowRecord();
    rec.dramaId = dramaId;
    rec.addedAt = Date.now();
    rec.title = title;
    rec.cover = cover;
    rec.episodeCount = episodeCount;
    rec.finished = finished;
    rec.sourceId = sourceId;
    this.followList.push(rec);
    this.persist(KEY_FOLLOWS, JSON.stringify(this.followList));
    return true;
  }

  // ---------- 搜索历史 ----------

  getSearchHistory(): string[] {
    return this.searchList.slice();
  }

  pushSearchHistory(keyword: string): void {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.searchList = this.searchList.filter((k: string): boolean => k !== kw);
    this.searchList.unshift(kw);
    if (this.searchList.length > 10) {
      this.searchList = this.searchList.slice(0, 10);
    }
    this.persist(KEY_SEARCH, JSON.stringify(this.searchList));
  }

  clearSearchHistory(): void {
    this.searchList = [];
    this.persist(KEY_SEARCH, JSON.stringify(this.searchList));
  }

  getTheme(): string {
    try {
      const value: string = this.pref !== null ? this.pref.getSync('qg_theme', 'lime') as string : 'lime';
      return QgTheme.normalize(value);
    } catch (error) {
      return 'lime';
    }
  }

  getString(key: string, fallback: string = ''): string {
    try {
      return this.pref !== null ? this.pref.getSync(key, fallback) as string : fallback;
    } catch (error) {
      return fallback;
    }
  }

  setString(key: string, value: string): void {
    this.persist(key, value);
  }
  setTheme(value: string): void {
    const theme: string = QgTheme.normalize(value);
    this.persist('qg_theme', theme);
    AppStorage.setOrCreate('qgTheme', theme);
  }

  // ---------- 应用设置 ----------

  getSettings(): QgAppSettings {
    return this.settings;
  }

  updateSettings(patch: QgAppSettings): void {
    this.settings.colorMode = patch.colorMode;
    this.settings.sourceId = patch.sourceId;
    this.settings.autoPlay = patch.autoPlay;
    this.settings.autoNext = patch.autoNext;
    this.settings.directPlay = patch.directPlay;
    this.settings.playSpeed = patch.playSpeed;
    this.settings.videoAspect = patch.videoAspect === 'fill' ? 'fill' : 'original';
    this.settings.danmakuOn = patch.danmakuOn;
    this.settings.danmakuOpacity = patch.danmakuOpacity;
    this.settings.danmakuFontSize = patch.danmakuFontSize;
    this.settings.danmakuArea = patch.danmakuArea;
    this.settings.danmakuBlockWords = patch.danmakuBlockWords.slice();
    this.settings.downloadWifiOnly = patch.downloadWifiOnly;
    this.settings.downloadParallel = patch.downloadParallel;
    this.settings.proxyOn = patch.proxyOn;
    this.settings.proxyHost = patch.proxyHost;
    this.settings.proxyPort = patch.proxyPort;
    this.settings.homeContinue = patch.homeContinue;
    this.settings.homeRank = patch.homeRank;
    this.settings.homeRecommendations = patch.homeRecommendations;
    this.applyNetwork();
    this.persist(KEY_SETTINGS, JSON.stringify(this.settings));
  }

  /** 代理设置 → QgHttp 全局代理 */
  private applyNetwork(): void {
    QgHttp.proxy.enabled = this.settings.proxyOn;
    QgHttp.proxy.host = this.settings.proxyHost;
    QgHttp.proxy.port = this.settings.proxyPort;
  }

  // ---------- 内部 ----------

  private loadAll(): void {
    const p = this.pref;
    if (p === null) {
      return;
    }
    this.watchList = QgStore.parseWatch(p.getSync(KEY_WATCH, '[]') as string);
    this.followList = QgStore.parseFollows(p.getSync(KEY_FOLLOWS, '[]') as string);
    this.queueList = QgStore.parseQueue(p.getSync(KEY_QUEUE, '[]') as string);
    this.bookmarkList = QgStore.parseBookmarks(p.getSync(KEY_BOOKMARKS, '[]') as string);
    this.introMarks = QgStore.parseNumberMap(p.getSync(KEY_INTRO_MARKS, '{}') as string);
    this.searchList = QgStore.parseStrings(p.getSync(KEY_SEARCH, '[]') as string);
    this.settings = QgStore.parseSettings(p.getSync(KEY_SETTINGS, '') as string);
    this.applyNetwork();
  }

  private persist(key: string, value: string): void {
    const p = this.pref;
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (error) {
      // 落盘失败不影响内存数据
    }
  }

  private static parseWatch(raw: string): QgWatchRecord[] {
    const out: QgWatchRecord[] = [];
    try {
      const arr: object[] = JSON.parse(raw) as object[];
      for (let i: number = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const r: QgWatchRecord = new QgWatchRecord();
        r.dramaId = `${item['dramaId'] ?? ''}`;
        r.episode = Number(item['episode'] ?? 1);
        r.progress = Number(item['progress'] ?? 0);
        r.duration = Number(item['duration'] ?? 0);
        r.updatedAt = Number(item['updatedAt'] ?? 0);
        const title: Object | undefined = item['title'];
        if (typeof title === 'string') {
          r.title = title;
        }
        const cover: Object | undefined = item['cover'];
        if (typeof cover === 'string') {
          r.cover = cover;
        }
        if (r.dramaId.length > 0) {
          out.push(r);
        }
      }
    } catch (error) {
      return [];
    }
    return out;
  }

  private static parseFollows(raw: string): QgFollowRecord[] {
    const out: QgFollowRecord[] = [];
    try {
      const arr: object[] = JSON.parse(raw) as object[];
      for (let i: number = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const r: QgFollowRecord = new QgFollowRecord();
        r.dramaId = `${item['dramaId'] ?? ''}`;
        r.addedAt = Number(item['addedAt'] ?? 0);
        const title: Object | undefined = item['title'];
        if (typeof title === 'string') {
          r.title = title;
        }
        const cover: Object | undefined = item['cover'];
        if (typeof cover === 'string') {
          r.cover = cover;
        }
        r.episodeCount = Number(item['episodeCount'] ?? 0);
        r.finished = item['finished'] !== false;
        const sourceId: Object | undefined = item['sourceId'];
        if (typeof sourceId === 'string') {
          r.sourceId = sourceId;
        }
        if (r.dramaId.length > 0) {
          out.push(r);
        }
      }
    } catch (error) {
      return [];
    }
    return out;
  }

  private static parseQueue(raw: string): QgQueueRecord[] {
    const out: QgQueueRecord[] = [];
    try {
      const arr: object[] = JSON.parse(raw) as object[];
      for (let i = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const r: QgQueueRecord = new QgQueueRecord();
        r.dramaId = `${item['dramaId'] ?? ''}`;
        r.addedAt = Number(item['addedAt'] ?? 0);
        r.title = `${item['title'] ?? ''}`;
        r.cover = `${item['cover'] ?? ''}`;
        r.episodeCount = Number(item['episodeCount'] ?? 0);
        r.finished = item['finished'] !== false;
        r.sourceId = `${item['sourceId'] ?? ''}`;
        if (r.dramaId.length > 0) out.push(r);
      }
    } catch (error) {
      return [];
    }
    return out;
  }

  private static parseBookmarks(raw: string): QgBookmarkRecord[] {
    const out: QgBookmarkRecord[] = [];
    try {
      const arr: object[] = JSON.parse(raw) as object[];
      for (let i = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const r: QgBookmarkRecord = new QgBookmarkRecord();
        r.dramaId = `${item['dramaId'] ?? ''}`;
        r.title = `${item['title'] ?? ''}`;
        r.episode = Number(item['episode'] ?? 1);
        r.seconds = Number(item['seconds'] ?? 0);
        r.createdAt = Number(item['createdAt'] ?? 0);
        if (r.dramaId.length > 0) out.push(r);
      }
    } catch (error) {
      return [];
    }
    return out;
  }

  private static parseNumberMap(raw: string): Record<string, number> {
    const out: Record<string, number> = {};
    try {
      const item: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const keys: string[] = Object.keys(item);
      for (let i = 0; i < keys.length; i++) {
        const value: number = Number(item[keys[i]]);
        if (!Number.isNaN(value) && value > 0) out[keys[i]] = value;
      }
    } catch (error) {
      return {};
    }
    return out;
  }

  private static parseStrings(raw: string): string[] {
    const out: string[] = [];
    try {
      const arr: object[] = JSON.parse(raw) as object[];
      for (let i: number = 0; i < arr.length; i++) {
        const v: Object | undefined = arr[i];
        if (typeof v === 'string') {
          out.push(v);
        }
      }
    } catch (error) {
      return [];
    }
    return out;
  }

  private static parseSettings(raw: string): QgAppSettings {
    const s: QgAppSettings = new QgAppSettings();
    if (raw.length === 0) {
      return s;
    }
    try {
      const item: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const mode: Object | undefined = item['colorMode'];
      if (typeof mode === 'string' && (mode === 'system' || mode === 'light' || mode === 'dark')) {
        s.colorMode = mode;
      }
      const sourceId: Object | undefined = item['sourceId'];
      if (typeof sourceId === 'string' && /^[a-z0-9][a-z0-9_-]{0,31}$/.test(sourceId)) {
        s.sourceId = sourceId;
      }
      s.autoPlay = item['autoPlay'] !== false;
      s.autoNext = item['autoNext'] !== false;
      s.directPlay = item['directPlay'] === true;
      const playSpeed: number = Number(item['playSpeed'] ?? 1);
      if (!Number.isNaN(playSpeed) && playSpeed >= 0.5 && playSpeed <= 3) {
        s.playSpeed = playSpeed;
      }
      const videoAspect: Object | undefined = item['videoAspect'];
      if (typeof videoAspect === 'string' && (videoAspect === 'original' || videoAspect === 'fill')) {
        s.videoAspect = videoAspect;
      }
      s.danmakuOn = item['danmakuOn'] !== false;
      const opacity: number = Number(item['danmakuOpacity'] ?? 80);
      if (!Number.isNaN(opacity) && opacity >= 10 && opacity <= 100) {
        s.danmakuOpacity = opacity;
      }
      const fontSize: number = Number(item['danmakuFontSize'] ?? 100);
      if (!Number.isNaN(fontSize) && fontSize >= 50 && fontSize <= 150) {
        s.danmakuFontSize = fontSize;
      }
      const area: number = Number(item['danmakuArea'] ?? 75);
      if (!Number.isNaN(area) && area >= 25 && area <= 100) {
        s.danmakuArea = area;
      }
      const blockWords: Object | undefined = item['danmakuBlockWords'];
      if (blockWords !== null && blockWords !== undefined && typeof blockWords === 'object') {
        const arr: object[] = blockWords as object[];
        const words: string[] = [];
        for (let i: number = 0; i < arr.length; i++) {
          const w: Object | undefined = arr[i];
          if (typeof w === 'string' && w.length > 0 && !words.includes(w)) {
            words.push(w);
          }
        }
        s.danmakuBlockWords = words;
      }
      s.downloadWifiOnly = item['downloadWifiOnly'] !== false;
      const parallel: number = Number(item['downloadParallel'] ?? 2);
      if (!Number.isNaN(parallel) && parallel >= 1 && parallel <= 5) {
        s.downloadParallel = parallel;
      }
      s.proxyOn = item['proxyOn'] === true;
      const host: Object | undefined = item['proxyHost'];
      if (typeof host === 'string') {
        s.proxyHost = host;
      }
      const port: number = Number(item['proxyPort'] ?? 7890);
      if (!Number.isNaN(port) && port > 0 && port < 65536) {
        s.proxyPort = port;
      }
      s.homeContinue = item['homeContinue'] !== false;
      s.homeRank = item['homeRank'] !== false;
      s.homeRecommendations = item['homeRecommendations'] !== false;
    } catch (error) {
      return new QgAppSettings();
    }
    return s;
  }
}
