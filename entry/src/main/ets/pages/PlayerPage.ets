/**
 * 播放页：Video 组件 + 自定义控制层（播放/暂停/上下集/进度/倍速/选集半模态）。
 * 分集与播放地址通过站源异步解析（QgRepository.play）；
 * 观看进度落 Preferences，支持自动连播；进入时状态栏图标强制白色。
 */
import { curves, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { QgDrama, QgDramaDetail, QgEpisode, QgPlayerParam, QgPlayInfo, QgWatchRecord } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { qgCoverOf } from '../components/QgWidgets';

const SPEEDS: number[] = [0.75, 1, 1.25, 1.5, 2];
const HIDE_DELAY: number = 3500;

@Component
struct QgPlayerPage {
  private stack: NavPathStack = new NavPathStack();
  private controller: VideoController = new VideoController();
  private hideTimer: number = -1;
  private pendingPlay: boolean = false;
  private lastSavedSec: number = -1;
  private dramaId: string = '';

  @State drama: QgDrama | undefined = undefined;
  @State episodes: QgEpisode[] = [];
  @State episode: number = 1;
  @State playUrl: string = '';
  @State resolving: boolean = false;
  @State loadErr: string = '';
  @State playing: boolean = false;
  @State controlsShown: boolean = true;
  @State curSec: number = 0;
  @State totalSec: number = 0;
  @State speedIdx: number = 1;
  @State sheetOpen: boolean = false;
  @State seekDragging: boolean = false;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('darkMode') darkOn: boolean = false;
  @StorageProp('carMode') carOn: boolean = false;

  private getD(): QgDrama {
    return this.drama as QgDrama;
  }

  private episodeTotal(): number {
    if (this.episodes.length > 0) {
      return this.episodes.length;
    }
    return this.getD().episodeCount;
  }

  private currentEpisode(): QgEpisode | undefined {
    return this.episodes.find((ep: QgEpisode): boolean => ep.order === this.episode);
  }

  private formatTime(sec: number): string {
    const s: number = Math.max(0, Math.floor(sec));
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = r < 10 ? `0${r}` : `${r}`;
    return `${mm}:${ss}`;
  }

  private scheduleHide(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      if (this.playing) {
        this.controlsShown = false;
      }
    }, HIDE_DELAY);
  }

  private cancelHide(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private saveRecord(): void {
    if (this.drama === undefined || this.dramaId.length === 0) {
      return;
    }
    const r: QgWatchRecord = new QgWatchRecord();
    r.dramaId = this.dramaId;
    r.episode = this.episode;
    r.progress = Math.floor(this.curSec);
    r.duration = Math.floor(this.totalSec);
    r.updatedAt = Date.now();
    r.title = this.getD().title;
    r.cover = this.getD().cover;
    QgStore.getInstance().saveWatch(r);
    AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
    this.lastSavedSec = this.curSec;
  }

  /** 详情加载 + 分集定位 */
  private bootstrap(dramaId: string, episode: number): void {
    this.dramaId = dramaId;
    this.loadErr = '';
    QgRepository.detail(dramaId)
      .then((detail: QgDramaDetail) => {
        this.drama = detail.drama;
        this.episodes = detail.episodes;
        const total: number = this.episodeTotal();
        this.episode = episode >= 1 && episode <= total ? episode : 1;
        this.pendingPlay = QgStore.getInstance().getSettings().autoPlay;
        this.resolvePlay();
      })
      .catch((error: BusinessError) => {
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  /** 解析当前分集播放地址 */
  private resolvePlay(): void {
    const ep: QgEpisode | undefined = this.currentEpisode();
    if (ep === undefined) {
      this.loadErr = '分集不存在';
      return;
    }
    this.resolving = true;
    this.playUrl = '';
    this.curSec = 0;
    this.totalSec = 0;
    this.lastSavedSec = -1;
    this.loadErr = '';
    QgRepository.play(this.dramaId, ep.id)
      .then((info: QgPlayInfo) => {
        this.resolving = false;
        if (info.url.length === 0) {
          this.loadErr = '未能解析到播放地址';
          return;
        }
        this.playUrl = info.url;
      })
      .catch((error: BusinessError) => {
        this.resolving = false;
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '播放地址解析失败';
      });
  }

  private togglePlay(): void {
    if (this.playing) {
      this.controller.pause();
    } else {
      this.controller.start();
    }
  }

  private pickEpisode(ep: number): void {
    if (this.drama === undefined || ep < 1 || ep > this.episodeTotal() || ep === this.episode) {
      return;
    }
    this.saveRecord();
    this.episode = ep;
    this.pendingPlay = true;
    this.sheetOpen = false;
    this.controlsShown = true;
    this.resolvePlay();
  }

  private prevEpisode(): void {
    this.pickEpisode(this.episode - 1);
  }

  private nextEpisode(): void {
    this.pickEpisode(this.episode + 1);
  }

  private cycleSpeed(): void {
    this.speedIdx = (this.speedIdx + 1) % SPEEDS.length;
  }

  private speedIndexOf(playSpeed: number): number {
    let best: number = 1;
    let bestDiff: number = Number.MAX_SAFE_INTEGER;
    for (let i: number = 0; i < SPEEDS.length; i++) {
      const diff: number = Math.abs(SPEEDS[i] - playSpeed);
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  private async applyPlayerBar(playerActive: boolean): Promise<void> {
    AppStorage.setOrCreate('playerActive', playerActive);
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const contentColor: string = playerActive || this.darkOn ? '#FFFFFF' : '#17211A';
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      } as window.SystemBarProperties);
    } catch (error) {
      // 状态栏设置失败不影响播放
    }
  }

  aboutToDisappear(): void {
    this.saveRecord();
    this.cancelHide();
    if (this.playUrl.length > 0) {
      this.controller.stop();
    }
    this.applyPlayerBar(false);
  }

  build() {
    NavDestination() {
      if (this.drama === undefined && this.loadErr.length > 0) {
        this.FullErrorBuilder()
      } else if (this.drama === undefined) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.playerDim'))
          Text('加载中…')
            .fontSize(14)
            .fontColor($r('app.color.playerDim'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.playerBg'))
      } else {
        this.StageBuilder()
      }
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.playerBg'))
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const p = ctx.pathInfo.param as QgPlayerParam;
      if (p === undefined || p === null || typeof p.dramaId !== 'string' || p.dramaId.length === 0) {
        this.loadErr = '缺少播放参数';
        return;
      }
      this.speedIdx = this.speedIndexOf(QgStore.getInstance().getSettings().playSpeed);
      this.controlsShown = true;
      this.bootstrap(p.dramaId, p.episode);
      this.applyPlayerBar(true);
      this.scheduleHide();
    })
  }

  @Builder
  FullErrorBuilder() {
    Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.movie_slash'))
        .fontSize(52)
        .fontColor([$r('app.color.playerDim')])
      Text(this.loadErr)
        .fontSize(14)
        .fontColor($r('app.color.playerDim'))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Text('重试')
        .fontSize(14)
        .fontColor($r('app.color.playerText'))
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .borderRadius(18)
        .backgroundColor('#33000000')
        .onClick(() => {
          this.loadErr = '';
          this.bootstrap(this.dramaId, this.episode);
        })
      Text('返回')
        .fontSize(14)
        .fontColor($r('app.color.playerDim'))
        .padding({ top: 4, bottom: 4 })
        .onClick(() => {
          this.stack.pop();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  StageBuilder() {
    Stack() {
      if (this.playUrl.length > 0) {
        Video({
          src: this.playUrl,
          controller: this.controller,
          currentProgressRate: SPEEDS[this.speedIdx],
          previewUri: qgCoverOf(this.getD().cover, this.getD().sourceId)
        })
          .autoPlay(false)
          .controls(false)
          .objectFit(ImageFit.Cover)
          .onPrepared((info: PreparedInfo) => {
            this.totalSec = info.duration;
            if (this.pendingPlay) {
              this.pendingPlay = false;
              this.controller.start();
            }
          })
          .onStart(() => {
            this.playing = true;
            this.scheduleHide();
          })
          .onPause(() => {
            this.playing = false;
            this.controlsShown = true;
            this.cancelHide();
            this.saveRecord();
          })
          .onFinish(() => {
            const autoNext: boolean = QgStore.getInstance().getSettings().autoNext;
            if (autoNext && this.episode < this.episodeTotal()) {
              this.nextEpisode();
            } else {
              this.playing = false;
              this.controlsShown = true;
              this.saveRecord();
            }
          })
          .onError(() => {
            this.playing = false;
            this.controlsShown = true;
          })
      } else {
        Column({ space: 10 }) {
          if (this.loadErr.length > 0) {
      SymbolGlyph($r('sys.symbol.movie_slash'))
              .fontSize(44)
              .fontColor([$r('app.color.playerDim')])
            Text(this.loadErr)
              .fontSize(13)
              .fontColor($r('app.color.playerDim'))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Text('重试')
              .fontSize(14)
              .fontColor($r('app.color.playerText'))
              .padding({ left: 24, right: 24, top: 9, bottom: 9 })
              .borderRadius(18)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.resolvePlay();
              })
          } else {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.playerDim'))
            Text('解析播放地址…')
              .fontSize(13)
              .fontColor($r('app.color.playerDim'))
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 点击层：切换控制层显隐
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          if (this.controlsShown) {
            this.cancelHide();
            this.controlsShown = false;
          } else {
            this.controlsShown = true;
            if (this.playing) {
              this.scheduleHide();
            }
          }
        })

      if (this.controlsShown) {
        this.OverlayBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetOpen, this.SheetInnerBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      backgroundColor: $r('app.color.surface')
    })
  }

  @Builder
  OverlayBuilder() {
    Column() {
      // 顶部：返回 + 标题 + 集数
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor([Color.White])
          .onClick(() => {
            this.saveRecord();
            this.stack.pop();
          })
        Column({ space: 2 }) {
          Text(this.getD().title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`第${this.episode}集 / 共${this.episodeTotal()}集${this.carOn ? ' · 车机' : ''}`)
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: 10 })
      .linearGradient({
        angle: 180,
        colors: [['#66000000', 0], ['#00000000', 1]]
      })

      Blank()

      // 中央控制
      Row({ space: 44 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.episode > 1 ? Color.White : $r('app.color.trackOff')])
          .rotate({ angle: 180 })
          .onClick(() => {
            this.prevEpisode();
          })

        SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(44)
          .fontColor([Color.White])
          .onClick(() => {
            this.togglePlay();
          })

        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.episode < this.episodeTotal() ? Color.White : $r('app.color.trackOff')])
          .onClick(() => {
            this.nextEpisode();
          })
      }

      Blank()

      // 底部：进度 + 倍速 + 选集
      Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text(this.formatTime(this.curSec))
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
          Slider({
            value: this.curSec,
            min: 0,
            max: this.totalSec > 0 ? this.totalSec : 100
          })
            .selectedColor($r('app.color.accent'))
            .trackColor($r('app.color.trackOff'))
            .blockColor(Color.White)
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.Begin) {
                this.seekDragging = true;
                this.cancelHide();
              } else if (mode === SliderChangeMode.End) {
                this.seekDragging = false;
                this.controller.setCurrentTime(value);
                if (this.playing) {
                  this.scheduleHide();
                }
              }
            })
          Text(this.formatTime(this.totalSec))
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
        }
        .width('100%')

        Row({ space: 14 }) {
          Text(`${SPEEDS[this.speedIdx]}x`)
            .fontSize(12)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.cycleSpeed();
            })
          Text('选集')
            .fontSize(12)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.cancelHide();
              this.sheetOpen = true;
            })
          Blank()
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: this.safeBottom + 12 })
      .linearGradient({
        angle: 0,
        colors: [['#00000000', 0], ['#66000000', 1]]
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SheetInnerBuilder() {
    Column() {
      Row() {
        Text('选集')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text(`共${this.episodeTotal()}集`)
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })

      Scroll() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.episodes, (ep: QgEpisode) => {
            Text(ep.title.length > 0 ? ep.title : `${ep.order}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(ep.order === this.episode ? $r('app.color.accentOn') : $r('app.color.textDim'))
              .textAlign(TextAlign.Center)
              .height(38)
              .constraintSize({ minWidth: 44 })
              .padding({ left: 8, right: 8 })
              .borderRadius(10)
              .backgroundColor(ep.order === this.episode ? $r('app.color.accent') : $r('app.color.chipBg'))
              .margin({ right: 8, bottom: 8 })
              .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
              .onClick(() => {
                this.pickEpisode(ep.order);
              })
          }, (ep: QgEpisode) => `sheet_ep_${ep.id}_${ep.order}`)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function QgPlayerBuilder() {
  QgPlayerPage()
}
