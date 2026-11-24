/**
 * 青果APP 数据门面。
 * 全部站源为 QuickJS JS 模块（rawfile 内置，经 QgModuleStore 安装），
 * 向 UI 提供统一的异步目录 / 搜索 / 详情 / 播放能力；
 * 当前站源由设置 sourceId 决定。
 * 门面方法失败时向上抛错，由 UI 捕获并展示错误态。
 */
import { QgAppSettings, QgCategory, QgDrama, QgDramaDetail, QgPageResult, QgPlayInfo, QgSeason, QgSourceDesc } from '../model/QgModels';
import { QgModulePackage, QgModuleStore } from './QgModuleStore';
import { QgModuleSource } from './source/QgModuleSource';
import { QgStore } from './QgStore';
import { QgSource, QgSourceManager } from './source/QgSource';

const DETAIL_CACHE_MS: number = 5 * 60 * 1000;
const DETAIL_CACHE_MAX: number = 32;
const FIRST_PAGE_MAX: number = 30;

export class QgRepository {
  private static inited: boolean = false;
  private static detailCache: Map<string, QgDramaDetail> = new Map<string, QgDramaDetail>();
  private static detailCacheAt: Map<string, number> = new Map<string, number>();
  /** 最近一次第 1 页目录（热门搜索 / 猜你喜欢 fallback） */
  private static firstPage: QgDrama[] = [];
  private static seasonCache: Map<string, QgSeason[]> = new Map();
  private static seasonCacheAt: Map<string, number> = new Map();

  /** 注册全部站源（幂等，首次访问任何方法时自动完成） */
  static init(): void {
    if (QgRepository.inited) {
      return;
    }
    QgRepository.inited = true;
    QgModuleStore.installed().forEach((pkg: QgModulePackage): void => {
      QgSourceManager.register(new QgModuleSource(pkg));
    });
  }

  static descriptions(): QgSourceDesc[] {
    return QgRepository.sources().map((source: QgSource): QgSourceDesc => {
      const description: string = source instanceof QgModuleSource ? source.pkg.manifest.description : '内置站源';
      return new QgSourceDesc(source.id, source.name, description);
    });
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

  static async loadCategories(): Promise<QgCategory[]> {
    return QgRepository.currentSource().loadCategories();
  }

  /** background=true 时（相邻分类预取）不回写 firstPage，避免污染热门搜索词来源 */
  static async catalogPage(categoryId: string, page: number, background: boolean = false): Promise<QgPageResult> {
    const source: QgSource = QgRepository.currentSource();
    const result: QgPageResult = await source.catalogPage(categoryId, page);
    if (!background && page === 1 && source === QgRepository.currentSource()) {
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

  static async seasons(drama: QgDrama): Promise<QgSeason[]> {
    QgRepository.init();
    const sourceId: string = QgSourceManager.sourceIdOf(drama.id);
    if (!/^[a-z0-9][a-z0-9_-]{0,31}:.+$/.test(drama.id)) throw new Error('分季剧集信息无效');
    const source: QgSource | undefined = QgSourceManager.byId(sourceId);
    if (source === undefined) throw new Error('未找到该剧所属的站源');
    const cached: QgSeason[] | undefined = QgRepository.seasonCache.get(drama.id);
    const cachedAt: number = QgRepository.seasonCacheAt.get(drama.id) ?? 0;
    if (cached !== undefined && Date.now() - cachedAt < DETAIL_CACHE_MS) return cached.slice();
    // 同一系列各季共享已验证的列表，切季时无需再次请求完整系列。
    // 保留按请求缓存的容量，只复用明确包含目标 ID 且仍有效的列表。
    for (const key of Array.from(QgRepository.seasonCache.keys())) {
      const seasons: QgSeason[] | undefined = QgRepository.seasonCache.get(key);
      const at: number = QgRepository.seasonCacheAt.get(key) ?? 0;
      if (seasons !== undefined && Date.now() - at < DETAIL_CACHE_MS &&
        seasons.some((season: QgSeason): boolean => season.drama.id === drama.id)) return seasons.slice();
    }
    const items: QgSeason[] = await source.seasons(drama.id);
    if (items.length > 200) throw new Error('分季列表过长');
    const ids: Set<string> = new Set();
    const numbers: Set<number> = new Set();
    const seasons: QgSeason[] = [];
    for (const item of items) {
      if (!Number.isInteger(item.number) || item.number < 1 || item.number > 200 ||
        QgSourceManager.sourceIdOf(item.drama.id) !== sourceId ||
        item.drama.id.length <= sourceId.length + 1 ||
        (item.drama.sourceId.length > 0 && item.drama.sourceId !== sourceId) ||
        ids.has(item.drama.id) || numbers.has(item.number)) throw new Error('分季列表包含无效或重复剧集');
      ids.add(item.drama.id);
      numbers.add(item.number);
      item.drama.sourceId = sourceId;
      seasons.push(item);
    }
    seasons.sort((left: QgSeason, right: QgSeason): number => left.number - right.number);
    const result: QgSeason[] = ids.has(drama.id) && seasons.length >= 2 ? seasons : [];
    if (QgRepository.seasonCache.size > DETAIL_CACHE_MAX) {
      QgRepository.seasonCache.clear();
      QgRepository.seasonCacheAt.clear();
    }
    QgRepository.seasonCache.set(drama.id, result);
    QgRepository.seasonCacheAt.set(drama.id, Date.now());
    return result.slice();
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
    for (let i = 0; i < base.length && out.length < 10; i++) {
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
    patch.videoAspect = s.videoAspect;
    patch.autoNext = s.autoNext;
    patch.directPlay = s.directPlay;
    patch.playSpeed = s.playSpeed;
    patch.danmakuOn = s.danmakuOn;
    patch.danmakuOpacity = s.danmakuOpacity;
    patch.danmakuFontSize = s.danmakuFontSize;
    patch.danmakuArea = s.danmakuArea;
    patch.danmakuBlockWords = s.danmakuBlockWords.slice();
    patch.downloadWifiOnly = s.downloadWifiOnly;
    patch.downloadParallel = s.downloadParallel;
    patch.proxyOn = s.proxyOn;
    patch.proxyHost = s.proxyHost;
    patch.proxyPort = s.proxyPort;
    patch.homeContinue = s.homeContinue;
    patch.homeRank = s.homeRank;
    patch.homeRecommendations = s.homeRecommendations;
    return patch;
  }
}
