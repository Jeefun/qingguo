import { run } from 'libqgmodule.so';
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo, QgSeason } from '../../model/QgModels';
import { QgModulePackage } from '../QgModuleStore';
import { QgModuleHost } from '../QgModuleHost';
import { QgJson } from '../QgJson';
import { QgDiag } from '../QgDiag';
import { QgGateway } from '../QgGateway';
import { qgBase64Decode, qgToHex } from '../QgBytes';
import { QgSource, QgSourceManager } from './QgSource';

export class QgModuleSource extends QgSource {
  readonly pkg: QgModulePackage;
  private host: QgModuleHost;
  private categoryList: QgCategory[] = [];
  private chapters: Map<string, Object[]> = new Map();
  private exported: string[] = [];
  private serial: Promise<void> = Promise.resolve();
  private knownPages: Map<string, Set<string>> = new Map();

  constructor(pkg: QgModulePackage) {
    super(pkg.manifest.id, pkg.manifest.name);
    this.pkg = pkg;
    this.host = new QgModuleHost(pkg);
  }

  async validate(): Promise<void> {
    this.exported = JSON.parse(await this.invoke('', [])) as string[];
    const required: string[] = ['categories', 'catalogPage', 'detail', 'resolveMedia'];
    if (this.pkg.manifest.capabilities.includes('search')) required.push('search');
    if (this.pkg.manifest.capabilities.includes('seasons')) required.push('seasons');
    for (const name of required) {
      if (!this.exported.includes(name)) {
        throw new Error(`站源缺少 ${name} 接口`);
      }
    }
  }

  private invoke(method: string, args: Object[]): Promise<string> {
    this.host.beginCall();
    return run(this.pkg.code, this.id, method, JSON.stringify(args),
      (name: string, encoded: string, respond: (response: string) => void): void => {
        this.host.handle(name, encoded, respond);
      });
  }

  private async call(method: string, args: Object[]): Promise<Object | null> {
    const previous: Promise<void> = this.serial;
    let release: () => void = (): void => {};
    this.serial = new Promise<void>((resolve: () => void): void => { release = resolve; });
    await previous;
    try {
      const category: string = QgJson.str(args[1]);
      let known: Set<string> = this.knownPages.get(category) ?? new Set();
      if (method === 'catalogPage') {
        if (QgJson.num(args[0]) === 1) known = new Set();
        this.host.setKnown(Array.from(known), QgJson.num(args[0]) > 1);
      } else {
        this.host.setKnown([], false);
      }
      const text: string = await this.invoke(method, args);
      QgDiag.log('Module', `${this.id}@${this.pkg.manifest.version} ${method} 完成`);
      const result: Object | null = QgJson.parse(text);
      if (method === 'catalogPage') {
        for (const value of QgJson.arr(QgJson.obj(result)?.['items'])) {
          known.add(QgJson.str(QgJson.obj(value)?.['id']));
        }
        if (this.knownPages.size > 32) this.knownPages.clear();
        this.knownPages.set(category, known);
      }
      return result;
    } finally {
      release();
    }
  }

  categories(): QgCategory[] {
    return this.categoryList.slice();
  }

  async loadCategories(): Promise<QgCategory[]> {
    const raw: Object | null = await this.call('categories', [false]);
    const items: Object[] = Array.isArray(raw) ? raw as Object[] : QgJson.arr(QgJson.obj(raw)?.['items']);
    this.categoryList = items.map((value: Object): QgCategory => {
      const row: Record<string, Object> | null = QgJson.obj(value);
      return new QgCategory(QgJson.str(row?.['id']), QgJson.pick(row, ['name', 'label']));
    }).filter((item: QgCategory): boolean => item.label.length > 0);
    return this.categories();
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    if (this.categoryList.length === 0) {
      await this.loadCategories();
    }
    return this.page(await this.call('catalogPage', [page, categoryId]));
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    if (!this.pkg.manifest.capabilities.includes('search')) {
      throw new Error('该站源不支持搜索');
    }
    return this.page(await this.call('search', [page, keyword]));
  }

  async seasons(dramaId: string): Promise<QgSeason[]> {
    if (!this.pkg.manifest.capabilities.includes('seasons')) return [];
    if (QgSourceManager.sourceIdOf(dramaId) !== this.id) throw new Error('分季剧集不属于当前站源');
    const raw: Object | null = await this.call('seasons', [QgSourceManager.siteIdOf(dramaId)]);
    if (!Array.isArray(raw) || raw.length > 200) throw new Error('站源返回了无效的分季列表');
    const rows: Object[] = raw as Object[];
    const result: QgSeason[] = [];
    for (const value of rows) {
      const row: Record<string, Object> | null = QgJson.obj(value);
      const drama: Record<string, Object> | null = QgJson.obj(row?.['drama']);
      const number: number = QgJson.num(row?.['number']);
      if (row === null || drama === null || !Number.isInteger(number) || number < 1 || number > 200 ||
        QgJson.pick(drama, ['title', 'name']).length === 0) {
        throw new Error('站源返回了无效的分季信息');
      }
      const id: string = QgJson.str(drama['id']);
      const source: string = QgJson.str(drama['source']);
      if (!id.startsWith(`${this.id}:`) || id.length === this.id.length + 1 ||
        (source.length > 0 && source !== this.id)) throw new Error('站源返回了其他站源的分季');
      result.push(new QgSeason(number, this.drama(drama)));
    }
    return result;
  }

  private page(raw: Object | null): QgPageResult {
    const row: Record<string, Object> | null = QgJson.obj(raw);
    if (row === null || !Array.isArray(row['items'])) {
      throw new Error('站源返回了无效的目录');
    }
    const items: QgDrama[] = QgJson.arr(row['items']).map((value: Object): QgDrama => this.drama(value));
    if (items.length === 0 && QgJson.str(row['warning'])) {
      throw new Error(QgJson.str(row['warning']));
    }
    return new QgPageResult(items, row['hasMore'] === true);
  }

  private drama(raw: Object): QgDrama {
    const row: Record<string, Object> | null = QgJson.obj(raw);
    const rawId: string = QgJson.pick(row, ['id', 'sourceId']);
    const id: string = rawId.startsWith(`${this.id}:`) ? rawId : `${this.id}:${rawId}`;
    const drama: QgDrama = new QgDrama(id, QgJson.pick(row, ['title', 'name']),
      QgJson.pick(row, ['categoryName', 'category', 'channelName', 'typeName']));
    drama.sourceId = this.id;
    drama.cover = QgJson.pick(row, ['coverUrl', 'cover', 'cover_url', 'poster', 'image', 'pic']);
    if (drama.cover) {
      try {
        this.host.validateCoverUrl(drama.cover);
      } catch (error) {
        drama.cover = '';
      }
    }
    drama.episodeCount = QgJson.num(row?.['episodeCount']) || QgJson.num(row?.['totalEpisode']) ||
      QgJson.num(row?.['chapterCount']);
    drama.intro = QgJson.pick(row, ['intro', 'desc']);
    drama.remark = QgJson.str(row?.['remark']);
    drama.badge = QgJson.str(row?.['badge']);
    drama.tags = QgJson.arr(row?.['tags']).map((tag: Object): string => QgJson.str(tag));
    drama.viewsText = QgJson.str(row?.['views']);
    drama.heat = QgJson.num(row?.['heat']);
    drama.finished = !/连载|更新中/.test(QgJson.str(row?.['releaseStatus']) + drama.remark);
    return drama;
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const raw: Record<string, Object> | null = QgJson.obj(await this.call('detail', [QgSourceManager.siteIdOf(dramaId)]));
    if (raw === null || QgJson.obj(raw['drama']) === null || !Array.isArray(raw['chapters'])) {
      throw new Error('站源返回了无效的详情');
    }
    const chapters: Object[] = QgJson.arr(raw['chapters']);
    const episodes: QgEpisode[] = chapters.map((value: Object, index: number): QgEpisode => {
      const chapter: Record<string, Object> | null = QgJson.obj(value);
      const item: QgEpisode = new QgEpisode(QgJson.str(chapter?.['id']), QgJson.str(chapter?.['title']) || `第${index + 1}集`,
        QgJson.num(chapter?.['currentEpisode']) || index + 1);
      item.audio = QgJson.str(chapter?.['mediaType']) === 'audio';
      return item;
    });
    const drama: QgDrama = this.drama(raw['drama']);
    if (drama.id !== dramaId) {
      throw new Error('站源返回的剧集与请求不符');
    }
    this.chapters.set(dramaId, chapters);
    if (this.chapters.size > 16) {
      this.chapters.delete(Array.from(this.chapters.keys())[0]);
    }
    drama.episodeCount = Math.max(drama.episodeCount, episodes.length);
    return new QgDramaDetail(drama, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    if (!this.chapters.has(dramaId)) {
      await this.detail(dramaId);
    }
    let chapters: Object[] = this.chapters.get(dramaId) ?? [];
    let chapter: Object | undefined = chapters.find((item: Object): boolean =>
      QgJson.str(QgJson.obj(item)?.['id']) === episodeId);
    if (chapter === undefined) {
      await this.detail(dramaId);
      chapters = this.chapters.get(dramaId) ?? [];
      chapter = chapters.find((item: Object): boolean =>
        QgJson.str(QgJson.obj(item)?.['id']) === episodeId);
    }
    if (chapter === undefined) {
      throw new Error('分集已变更，请重新打开剧集');
    }
    const task: Record<string, Object> = {};
    task['dramaId'] = dramaId;
    task['chapter'] = chapter;
    task['index'] = chapters.indexOf(chapter);
    task['total'] = chapters.length;
    task['downloadQuality'] = 0;
    const media: Record<string, Object> | null = QgJson.obj(await this.call('resolveMedia', [task]));
    if (media === null || !/^https?:\/\//i.test(QgJson.str(media['url']))) {
      throw new Error('站源未返回可播放地址');
    }
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = QgJson.str(media['url']);
    await this.host.validateMediaUrl(info.url);
    info.referer = QgJson.str(media['referer']);
    info.durationMs = QgJson.num(media['durationMs']);
    info.quality = QgJson.num(media['quality']);
    const credentials: Record<string, Object> | null = QgJson.field(media, 'credentials');
    for (const key of ['cookie', 'origin', 'referer', 'userAgent']) {
      const value: string = QgJson.str(credentials?.[key]);
      if (value) {
        const name: string = key === 'userAgent' ? 'User-Agent' : key.charAt(0).toUpperCase() + key.slice(1);
        info.headers[name] = value;
      }
    }
    const key: Object | undefined = media['cencKey'];
    info.cencKey = typeof key === 'string' ? qgToHex(qgBase64Decode(key)) :
      Array.isArray(key) ? qgToHex(Uint8Array.from(key as number[])) : '';
    info.routes = [info.url];
    for (const value of QgJson.arr(media['variants'])) {
      const variant: Record<string, Object> | null = QgJson.obj(value);
      const address: string = QgJson.str(variant?.['url']);
      if (/^https?:\/\//i.test(address) && !info.routes.includes(address) &&
        JSON.stringify(variant?.['cencKey'] ?? null) === JSON.stringify(media['cencKey'] ?? null) &&
        JSON.stringify(variant?.['credentials'] ?? null) === JSON.stringify(media['credentials'] ?? null)) {
        await this.host.validateMediaUrl(address);
        info.routes.push(address);
      }
    }
    const playlist: string = QgJson.str(media['playlist']);
    const hlsValue: Object | undefined = media['hlsKey'];
    const hlsKey: Uint8Array = typeof hlsValue === 'string' ? qgBase64Decode(hlsValue) :
      Array.isArray(hlsValue) ? Uint8Array.from(hlsValue as number[]) : new Uint8Array(0);
    if (playlist || hlsKey.length) {
      if (info.referer) info.headers['Referer'] = info.referer;
      info.url = await QgGateway.playlistMediaUrl(playlist, info.url, info.headers, hlsKey, this.id);
      info.routes = [info.url];
      info.headers = {};
      info.referer = '';
    }
    const videoUrl: string = QgJson.str(QgJson.obj(chapter)?.['videoUrl']);
    if (this.id === 'hongguo' && videoUrl.startsWith('hongguo-cenc://')) {
      info.danmakuId = videoUrl.slice('hongguo-cenc://'.length);
    }
    return info;
  }

  coverHeaders(url: string): Record<string, string> {
    return this.pkg.manifest.baseUrl ? { 'Referer': `${this.pkg.manifest.baseUrl}/` } : {};
  }
}
