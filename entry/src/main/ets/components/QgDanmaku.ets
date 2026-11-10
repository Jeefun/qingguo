/**
 * 通用弹幕渲染（移植自 Dart danmaku_controller.dart / danmaku_overlay.dart）。
 * QgDanmakuController：按 30s 时间窗从 HongguoDanmaku 拉取弹幕、去重、屏蔽词过滤、
 * 时钟外推（播放中按倍速推进，暂停冻结）。
 * QgDanmakuView：Canvas + displaySync(30fps) 逐帧绘制滚动弹幕，
 * 轨道分配 / 8s 全程滚动 / 显示区域 / 字号 / 不透明度可调。
 */
import { displaySync } from '@kit.ArkGraphics2D';
import { BusinessError } from '@kit.BasicServicesKit';
import { HongguoDanmakuItem, HongguoDanmakuPage, fetchHongguoDanmaku } from '../data/source/HongguoDanmaku';

const QG_DANMAKU_WINDOW_MS: number = 30000;
const QG_DANMAKU_LIFETIME_MS: number = 8000;
const QG_DANMAKU_MAX_ROWS: number = 64;
const QG_DANMAKU_MAX_CONCURRENT: number = 24;
const QG_DANMAKU_FAIL_RETRY_MS: number = 15000;
const QG_DANMAKU_KEEP_PAGES: number = 6;
const QG_DANMAKU_LANE_GAP: number = 24;
const QG_DANMAKU_MAX_CHARS: number = 100;

/** 通用弹幕条目（渲染层视角，与源解耦） */
export class QgDanmakuItem {
  readonly id: string = '';
  readonly text: string = '';
  readonly timeMs: number = 0;

  constructor(id: string, text: string, timeMs: number) {
    this.id = id;
    this.text = text;
    this.timeMs = timeMs;
  }
}

/** 已分配轨道的一次飞行 */
export class QgDanmakuFlight {
  readonly item: QgDanmakuItem;
  readonly text: string;
  readonly lane: number;
  readonly widthPx: number;

  constructor(item: QgDanmakuItem, text: string, lane: number, widthPx: number) {
    this.item = item;
    this.text = text;
    this.lane = lane;
    this.widthPx = widthPx;
  }
}

/**
 * 弹幕控制器：窗口加载 + 屏蔽词 + 时钟。
 * 由播放页持有并在 Video onUpdate / onStart / onPause 等回调中驱动。
 */
export class QgDanmakuController {
  private seriesId: string = '';
  private videoId: string = '';
  private pages: Map<number, HongguoDanmakuPage> = new Map<number, HongguoDanmakuPage>();
  private failures: Map<number, number> = new Map<number, number>();
  private loadingStart: number = -1;
  private generation: number = 0;
  private danmakuOn: boolean = true;
  private playing: boolean = false;
  private buffering: boolean = false;
  private seeking: boolean = false;
  private normalizedWords: string[] = [];
  positionMs: number = 0;
  durationMs: number = 0;
  rate: number = 1;
  dataRevision: number = 0;
  items: QgDanmakuItem[] = [];
  private blockedCount: number = 0;
  private anchorWall: number = 0;
  private anchorPos: number = 0;
  private anchorRate: number = 1;
  private anchorMoving: boolean = false;

  /** 是否具备弹幕条件（源 + 视频已就绪） */
  supported(): boolean {
    return this.seriesId.length > 0 && this.videoId.length > 0 && this.durationMs > 0;
  }

  blocked(): number {
    return this.blockedCount;
  }

  /** 状态文案（播放页弹幕开关旁展示） */
  statusText(): string {
    if (!this.danmakuOn) {
      return '弹幕已关闭';
    }
    if (!this.supported()) {
      return '本集暂不支持弹幕';
    }
    if (this.pages.size === 0) {
      return this.loadingStart >= 0 ? '正在加载弹幕' : '等待加载弹幕';
    }
    if (this.items.length > 0) {
      return `已载入 ${this.items.length} 条弹幕`;
    }
    return this.blockedCount > 0 ? '这段弹幕都被屏蔽了' : '这段暂无弹幕';
  }

  /** 设置弹幕来源（换集/换源时调用） */
  setSource(seriesId: string, videoId: string): void {
    if (this.seriesId === seriesId && this.videoId === videoId) {
      return;
    }
    this.seriesId = seriesId;
    this.videoId = videoId;
    this.resetData();
  }

  setDanmakuOn(on: boolean): void {
    if (this.danmakuOn === on) {
      return;
    }
    this.danmakuOn = on;
    this.generation++;
    this.loadingStart = -1;
    if (on) {
      this.ensureWindow();
    }
  }

  /** 设置屏蔽词（立即重建条目列表） */
  setBlockWords(words: string[]): void {
    const normalized: string[] = [];
    for (let i: number = 0; i < words.length; i++) {
      const w: string = normalizeDanmakuText(words[i]);
      if (w.length > 0 && normalized.indexOf(w) < 0) {
        normalized.push(w);
      }
    }
    this.normalizedWords = normalized;
    this.rebuild();
  }

  /** 播放状态更新（Video onUpdate / onStart / onPause 驱动，~1s 一次） */
  update(positionMs: number, durationMs: number, rate: number,
    playing: boolean, buffering: boolean): void {
    const jumped: boolean = !this.seeking &&
      (positionMs < this.positionMs || positionMs - this.positionMs > 2000);
    const durationChanged: boolean = durationMs !== this.durationMs && this.durationMs > 0;
    if (durationChanged) {
      this.generation++;
      this.pages.clear();
      this.failures.clear();
      this.loadingStart = -1;
      this.rebuild();
    } else if (jumped) {
      this.generation++;
      this.loadingStart = -1;
    }
    if (!this.seeking) {
      this.positionMs = positionMs;
    }
    this.durationMs = durationMs;
    this.rate = rate > 0 ? rate : 1;
    this.playing = playing;
    this.buffering = buffering;
    this.resetAnchor();
    this.ensureWindow();
  }

  beginSeek(): void {
    this.generation++;
    this.loadingStart = -1;
    this.seeking = true;
    this.resetAnchor();
  }

  endSeek(positionMs: number): void {
    this.seeking = false;
    this.positionMs = positionMs;
    this.resetAnchor();
    this.ensureWindow();
  }

  /** 当前弹幕时钟（播放中按 wall clock + 倍速外推） */
  currentClockMs(): number {
    if (!this.anchorMoving) {
      return this.anchorPos;
    }
    return this.anchorPos + (Date.now() - this.anchorWall) * this.anchorRate;
  }

  private resetAnchor(): void {
    this.anchorWall = Date.now();
    this.anchorPos = this.positionMs;
    this.anchorRate = this.rate;
    this.anchorMoving = this.danmakuOn && this.playing && !this.buffering && !this.seeking;
  }

  private resetData(): void {
    this.generation++;
    this.pages.clear();
    this.failures.clear();
    this.loadingStart = -1;
    this.positionMs = 0;
    this.durationMs = 0;
    this.playing = false;
    this.buffering = false;
    this.seeking = false;
    this.rate = 1;
    this.rebuild();
  }

  private covering(position: number): HongguoDanmakuPage | null {
    let found: HongguoDanmakuPage | null = null;
    this.pages.forEach((page: HongguoDanmakuPage, start: number) => {
      if (page.startMs <= position && position < page.nextMs &&
        (found === null || page.startMs > found.startMs)) {
        found = page;
      }
    });
    return found;
  }

  private ensureWindow(): void {
    if (!this.danmakuOn || !this.supported() || this.buffering || this.loadingStart >= 0) {
      return;
    }
    const pos: number = this.positionMs;
    const page: HongguoDanmakuPage | null = this.covering(pos);
    let start: number = Math.floor(pos / QG_DANMAKU_WINDOW_MS) * QG_DANMAKU_WINDOW_MS;
    if (page === null && this.pages.has(start)) {
      start = pos;
    }
    if (page !== null) {
      const moving: boolean = this.playing && !this.buffering;
      if (!moving || pos < page.nextMs - QG_DANMAKU_LIFETIME_MS ||
        page.nextMs >= this.durationMs || this.covering(page.nextMs) !== null) {
        return;
      }
      start = page.nextMs;
    }
    const retryAt: number | undefined = this.failures.get(start);
    if (retryAt !== undefined && Date.now() < retryAt) {
      return;
    }
    this.load(start);
  }

  private load(start: number): void {
    const ticket: number = this.generation;
    const seriesId: string = this.seriesId;
    const videoId: string = this.videoId;
    const duration: number = this.durationMs;
    this.loadingStart = start;
    fetchHongguoDanmaku(seriesId, videoId, start, duration)
      .then((page: HongguoDanmakuPage): void => {
        if (ticket !== this.generation) {
          return;
        }
        if (page.episodeId !== videoId || page.startMs !== start ||
          page.nextMs <= start || page.nextMs > duration) {
          this.failures.set(start, Date.now() + QG_DANMAKU_FAIL_RETRY_MS);
          return;
        }
        this.pages.set(start, page);
        this.failures.delete(start);
        this.prunePages();
        this.rebuild();
      })
      .catch((error: BusinessError): void => {
        if (ticket !== this.generation) {
          return;
        }
        this.failures.set(start, Date.now() + QG_DANMAKU_FAIL_RETRY_MS);
        while (this.failures.size > 8) {
          const oldest: number | undefined = this.failures.keys().next().value;
          if (oldest === undefined) {
            break;
          }
          this.failures.delete(oldest);
        }
      })
      .then((): void => {
        if (ticket !== this.generation) {
          return;
        }
        this.loadingStart = -1;
        this.ensureWindow();
      });
  }

  /** 只保留离当前播放位置最近的几页 */
  private prunePages(): void {
    if (this.pages.size <= QG_DANMAKU_KEEP_PAGES) {
      return;
    }
    const starts: number[] = [];
    this.pages.forEach((page: HongguoDanmakuPage, start: number) => {
      starts.push(start);
    });
    starts.sort((a: number, b: number): number =>
      Math.abs(a - this.positionMs) - Math.abs(b - this.positionMs));
    for (let i: number = QG_DANMAKU_KEEP_PAGES; i < starts.length; i++) {
      this.pages.delete(starts[i]);
    }
  }

  /** 合并各页 + 去重 + 屏蔽词过滤 */
  private rebuild(): void {
    const unique: Map<string, QgDanmakuItem> = new Map<string, QgDanmakuItem>();
    const starts: number[] = [];
    this.pages.forEach((page: HongguoDanmakuPage, start: number) => {
      starts.push(start);
    });
    starts.sort((a: number, b: number): number => a - b);
    for (let i: number = 0; i < starts.length; i++) {
      const page: HongguoDanmakuPage | undefined = this.pages.get(starts[i]);
      if (page === undefined) {
        continue;
      }
      for (let j: number = 0; j < page.items.length; j++) {
        const src: HongguoDanmakuItem = page.items[j];
        if (!unique.has(src.id)) {
          unique.set(src.id, new QgDanmakuItem(src.id, src.text, src.timeMs));
        }
      }
    }
    const sorted: QgDanmakuItem[] = [];
    unique.forEach((item: QgDanmakuItem) => {
      sorted.push(item);
    });
    sorted.sort((a: QgDanmakuItem, b: QgDanmakuItem): number => a.timeMs - b.timeMs);
    let blocked: number = 0;
    const kept: QgDanmakuItem[] = [];
    for (let i: number = 0; i < sorted.length; i++) {
      if (this.isBlocked(sorted[i].text)) {
        blocked++;
      } else {
        kept.push(sorted[i]);
      }
    }
    this.blockedCount = blocked;
    this.items = kept;
    this.dataRevision++;
  }

  private isBlocked(text: string): boolean {
    if (this.normalizedWords.length === 0) {
      return false;
    }
    const normalized: string = normalizeDanmakuText(text);
    if (normalized.length === 0) {
      return false;
    }
    for (let i: number = 0; i < this.normalizedWords.length; i++) {
      if (normalized.includes(this.normalizedWords[i])) {
        return true;
      }
    }
    return false;
  }
}

/** 屏蔽词归一化：小写 + 去空白 */
function normalizeDanmakuText(text: string): string {
  return text.toLowerCase().replace(/\s+/g, '');
}

/** 轨道分配（planDanmaku）：8s 全程滚动，同轨道保证不追尾 */
export function planDanmaku(items: QgDanmakuItem[], width: number, rows: number,
  measure: (text: string) => number): QgDanmakuFlight[] {
  if (width <= 0 || rows < 1) {
    return [];
  }
  const laneCount: number = Math.min(Math.max(rows, 1), QG_DANMAKU_MAX_ROWS);
  const lanes: (QgDanmakuFlight | null)[] = new Array<QgDanmakuFlight | null>(laneCount);
  for (let i: number = 0; i < laneCount; i++) {
    lanes[i] = null;
  }
  const sorted: QgDanmakuItem[] = items.slice();
  sorted.sort((a: QgDanmakuItem, b: QgDanmakuItem): number => a.timeMs - b.timeMs);
  const seen: Record<string, boolean> = {};
  const flights: QgDanmakuFlight[] = [];
  for (let i: number = 0; i < sorted.length; i++) {
    const item: QgDanmakuItem = sorted[i];
    if (item.id.length === 0 || item.text.trim().length === 0 || item.timeMs < 0 ||
      seen[item.id] === true) {
      continue;
    }
    seen[item.id] = true;
    // 同屏并发上限（最近 8s 内已安排 ≥24 条则丢弃）
    let recent: number = 0;
    let capped: boolean = false;
    for (let j: number = flights.length - 1; j >= 0; j--) {
      if (item.timeMs - flights[j].item.timeMs >= QG_DANMAKU_LIFETIME_MS) {
        break;
      }
      recent++;
      if (recent >= QG_DANMAKU_MAX_CONCURRENT) {
        capped = true;
        break;
      }
    }
    if (capped) {
      continue;
    }
    const chars: string[] = Array.from(item.text);
    const text: string = chars.length > QG_DANMAKU_MAX_CHARS ?
      `${chars.slice(0, QG_DANMAKU_MAX_CHARS).join('')}…` : item.text;
    const size: number = Math.ceil(measure(text)) + 8;
    let lane: number = -1;
    for (let l: number = 0; l < laneCount; l++) {
      const previous: QgDanmakuFlight | null = lanes[l];
      if (previous === null) {
        lane = l;
        break;
      }
      const gap: number = item.timeMs - previous.item.timeMs;
      if (gap >= QG_DANMAKU_LIFETIME_MS) {
        lane = l;
        break;
      }
      const headroom: number = (width + previous.widthPx) * gap / QG_DANMAKU_LIFETIME_MS -
        previous.widthPx;
      const tailroom: number = width -
        (width + size) * (QG_DANMAKU_LIFETIME_MS - gap) / QG_DANMAKU_LIFETIME_MS;
      if (headroom >= QG_DANMAKU_LANE_GAP && tailroom >= QG_DANMAKU_LANE_GAP) {
        lane = l;
        break;
      }
    }
    if (lane < 0) {
      continue;
    }
    const flight: QgDanmakuFlight = new QgDanmakuFlight(item, text, lane, size);
    lanes[lane] = flight;
    flights.push(flight);
  }
  return flights;
}

/** Canvas 弹幕渲染层（透明覆盖在 Video 上方，不响应点击） */
@Component
export struct QgDanmakuView {
  controller: QgDanmakuController | null = null;
  @Prop areaPercent: number = 75;
  @Prop fontScale: number = 100;
  @Prop opacityPercent: number = 80;
  private renderSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.renderSettings);
  private frameSync: displaySync.DisplaySync | null = null;
  private canvasW: number = 0;
  private canvasH: number = 0;
  private plan: QgDanmakuFlight[] = [];
  private planKey: string = '';

  aboutToAppear(): void {
    const sync: displaySync.DisplaySync = displaySync.create();
    const range: ExpectedFrameRateRange = { expected: 30, min: 0, max: 120 };
    sync.setExpectedFrameRateRange(range);
    sync.on('frame', () => {
      this.drawFrame();
    });
    this.frameSync = sync;
  }

  aboutToDisappear(): void {
    if (this.frameSync !== null) {
      this.frameSync.stop();
      this.frameSync = null;
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
      .onReady(() => {
        this.canvasW = this.ctx.width;
        this.canvasH = this.ctx.height;
        this.planKey = '';
        if (this.frameSync !== null) {
          this.frameSync.start();
        }
      })
  }

  private drawFrame(): void {
    const c: QgDanmakuController | null = this.controller;
    if (c === null || this.canvasW <= 0 || this.canvasH <= 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.clearRect(0, 0, this.canvasW, this.canvasH);
    if (!c.supported() || c.items.length === 0) {
      return;
    }
    const fontSize: number = (this.canvasW < 600 ? 16 : 20) * (this.fontScale / 100);
    const rowHeight: number = fontSize * 1.5;
    const area: number = Math.min(Math.max(this.areaPercent, 10), 100) / 100;
    let rows: number = Math.floor((this.canvasH * area - 8) / rowHeight);
    rows = Math.min(Math.max(rows, 0), QG_DANMAKU_MAX_ROWS);
    if (rows < 1) {
      return;
    }
    const key: string = `${c.dataRevision}_${Math.floor(this.canvasW)}_${rows}_${this.fontScale}`;
    if (key !== this.planKey) {
      this.planKey = key;
      ctx.font = `bold ${fontSize}px sans-serif`;
      this.plan = planDanmaku(c.items, this.canvasW, rows, (text: string): number => {
        return ctx.measureText(text).width;
      });
    }
    if (this.plan.length === 0) {
      return;
    }
    const now: number = c.currentClockMs();
    const alpha: number = Math.min(Math.max(this.opacityPercent, 10), 100) / 100;
    ctx.font = `bold ${fontSize}px sans-serif`;
    ctx.shadowColor = `rgba(0,0,0,${0.72 * alpha})`;
    ctx.shadowBlur = 3;
    ctx.shadowOffsetX = 1;
    ctx.shadowOffsetY = 1;
    ctx.fillStyle = `rgba(255,255,255,${alpha})`;
    for (let i: number = 0; i < this.plan.length; i++) {
      const f: QgDanmakuFlight = this.plan[i];
      const startMs: number = f.item.timeMs;
      if (now < startMs) {
        break;
      }
      if (now >= startMs + QG_DANMAKU_LIFETIME_MS) {
        continue;
      }
      const progress: number = (now - startMs) / QG_DANMAKU_LIFETIME_MS;
      const x: number = this.canvasW - (this.canvasW + f.widthPx) * progress;
      const y: number = 8 + f.lane * rowHeight + fontSize * 0.85;
      ctx.fillText(f.text, x, y);
    }
  }
}
