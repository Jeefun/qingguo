/**
 * 青果APP 数据门面。
 * 注册全部站源（红果 / 韩小圈 / 鬼片 / 青空 / 黄豆 / 剧果 / 野果 / 帝果 /
 * 禁果短剧 / 禁果 / 黑桃 / 笔盒 / 黄果三源），向 UI 提供统一的
 * 异步目录 / 搜索 / 详情 / 播放能力；当前站源由设置 sourceId 决定。
 * 门面方法失败时向上抛错，由 UI 捕获并展示错误态。
 */
import { QgAppSettings, QgCategory, QgDrama, QgDramaDetail, QgPageResult, QgPlayInfo } from '../model/QgModels';
import { QgStore } from './QgStore';
import { QgSource, QgSourceManager } from './source/QgSource';
import { HongguoSource } from './source/HongguoSource';
import { HanxiaoquanSource } from './source/HanxiaoquanSource';
import { SoraniSource } from './source/SoraniSource';
import { HuangdouSource } from './source/HuangdouSource';

const DETAIL_CACHE_MS: number = 5 * 60 * 1000;
const DETAIL_CACHE_MAX: number = 32;
const FIRST_PAGE_MAX: number = 30;

export class QgRepository {
  private static inited: boolean = false;
  private static detailCache: Map<string, QgDramaDetail> = new Map<string, QgDramaDetail>();
  private static detailCacheAt: Map<string, number> = new Map<string, number>();
  /** 最近一次第 1 页目录（热门搜索 / 猜你喜欢 fallback） */
  private static firstPage: QgDrama[] = [];

  /** 注册全部站源（幂等，首次访问任何方法时自动完成） */
  static init(): void {
    if (QgRepository.inited) {
      return;
    }
    QgRepository.inited = true;
    QgSourceManager.register(new HongguoSource());
    QgSourceManager.register(new HanxiaoquanSource());
    QgSourceManager.register(new SoraniSource());
    QgSourceManager.register(new HuangdouSource());
  }

  /** 全部已注册站源 */
  static sources(): QgSource[] {
    QgRepository.init();
    return QgSourceManager.all();
  }

  static currentSourceId(): string {
    QgRepository.init();
    const id: string = QgStore.getInstance().getSettings().sourceId;
    if (QgSourceManager.byId(id) !== undefined) {
      return id;
    }
    return 'hongguo';
  }

  static currentSource(): QgSource {
    QgRepository.init();
    const found: QgSource | undefined = QgSourceManager.byId(QgRepository.currentSourceId());
    if (found !== undefined) {
      return found;
    }
    const all: QgSource[] = QgSourceManager.all();
    return all[0];
  }

  static currentSourceName(): string {
    return QgRepository.currentSource().name;
  }

  /** 切换站源：写回设置并清空门面缓存 */
  static setSource(id: string): void {
    QgRepository.init();
    if (QgSourceManager.byId(id) === undefined) {
      return;
    }
    const store: QgStore = QgStore.getInstance();
    const patch: QgAppSettings = QgRepository.copySettings(store.getSettings());
    patch.sourceId = id;
    store.updateSettings(patch);
    QgRepository.firstPage = [];
    QgRepository.detailCache.clear();
    QgRepository.detailCacheAt.clear();
  }

  /** 当前源分类（发现页 chips） */
  static categories(): QgCategory[] {
    return QgRepository.currentSource().categories();
  }

  static async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    const source: QgSource = QgRepository.currentSource();
    const result: QgPageResult = await source.catalogPage(categoryId, page);
    if (page === 1) {
      QgRepository.firstPage = result.dramas.slice(0, FIRST_PAGE_MAX);
    }
    return result;
  }

  static async search(keyword: string, page: number): Promise<QgPageResult> {
    return QgRepository.currentSource().search(keyword, page);
  }

  static async detail(dramaId: string): Promise<QgDramaDetail> {
    QgRepository.init();
    const now: number = Date.now();
    const hit: QgDramaDetail | undefined = QgRepository.detailCache.get(dramaId);
    const cachedAt: number = QgRepository.detailCacheAt.get(dramaId) ?? 0;
    if (hit !== undefined && now - cachedAt < DETAIL_CACHE_MS) {
      return hit;
    }
    const source: QgSource | undefined = QgSourceManager.byId(QgSourceManager.sourceIdOf(dramaId));
    if (source === undefined) {
      throw new Error('未找到该剧所属的站源');
    }
    const detail: QgDramaDetail = await source.detail(dramaId);
    QgRepository.detailCache.set(dramaId, detail);
    QgRepository.detailCacheAt.set(dramaId, now);
    if (QgRepository.detailCache.size > DETAIL_CACHE_MAX) {
      QgRepository.evictOldestDetail();
    }
    return detail;
  }

  static async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    QgRepository.init();
    const source: QgSource | undefined = QgSourceManager.byId(QgSourceManager.sourceIdOf(dramaId));
    if (source === undefined) {
      throw new Error('未找到该剧所属的站源');
    }
    return source.play(dramaId, episodeId);
  }

  /** 某源封面/图片加载需要注入的请求头 */
  static coverHeadersOf(sourceId: string, url: string): Record<string, string> {
    QgRepository.init();
    const source: QgSource | undefined = QgSourceManager.byId(sourceId);
    if (source === undefined) {
      return {};
    }
    return source.coverHeaders(url);
  }

  /** 最近第 1 页目录缓存（猜你喜欢 / 热门搜索兜底，可能为空） */
  static cachedFirstPage(): QgDrama[] {
    return QgRepository.firstPage.slice();
  }

  /** 热门搜索词：优先用第 1 页目录标题，无缓存则拉取一次 */
  static async hotKeywords(): Promise<string[]> {
    let base: QgDrama[] = QgRepository.firstPage;
    if (base.length === 0) {
      const result: QgPageResult = await QgRepository.catalogPage('', 1);
      base = result.dramas;
    }
    const out: string[] = [];
    for (let i: number = 0; i < base.length && out.length < 10; i++) {
      const title: string = base[i].title;
      if (title.length > 0 && !out.includes(title)) {
        out.push(title);
      }
    }
    return out;
  }

  private static evictOldestDetail(): void {
    let oldestKey: string = '';
    let oldestAt: number = Number.MAX_SAFE_INTEGER;
    QgRepository.detailCache.forEach((value: QgDramaDetail, key: string) => {
      const at: number = QgRepository.detailCacheAt.get(key) ?? 0;
      if (at < oldestAt) {
        oldestAt = at;
        oldestKey = key;
      }
    });
    if (oldestKey.length > 0) {
      QgRepository.detailCache.delete(oldestKey);
      QgRepository.detailCacheAt.delete(oldestKey);
    }
  }

  private static copySettings(s: QgAppSettings): QgAppSettings {
    const patch: QgAppSettings = new QgAppSettings();
    patch.colorMode = s.colorMode;
    patch.sourceId = s.sourceId;
    patch.autoPlay = s.autoPlay;
    patch.autoNext = s.autoNext;
    patch.playSpeed = s.playSpeed;
    patch.danmakuOn = s.danmakuOn;
    patch.danmakuOpacity = s.danmakuOpacity;
    patch.danmakuFontSize = s.danmakuFontSize;
    patch.downloadWifiOnly = s.downloadWifiOnly;
    patch.downloadParallel = s.downloadParallel;
    patch.proxyOn = s.proxyOn;
    patch.proxyHost = s.proxyHost;
    patch.proxyPort = s.proxyPort;
    return patch;
  }
}
