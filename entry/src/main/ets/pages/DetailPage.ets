import { QgTheme } from '../components/QgTheme';
﻿/**
 * 详情页 —— 「夜幕 · 青柠」。
 *
 * - 顶部全幅沉浸背景（模糊封面 + 渐变融合），悬浮玻璃返回与反馈钮；
 * - 清晰海报 + 超大标题 + 状态胶囊 + 青柠主播放胶囊 + 玻璃追剧/待看钮；
 * - 分季横向卡片常显；共享选集器支持区间、排序及集数定位。
 */
import { promptAction } from '@kit.ArkUI';
import { QgEpisodePicker } from '../components/QgEpisodePicker';
import { BusinessError } from '@kit.BasicServicesKit';
import { QgDrama, QgDramaDetail, QgDetailParam, QgEpisode, QgPlayerParam, QgSeason, qgSameImage } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import {
  QgBackBtn,
  QgGhostButton,
  QgIconBtn,
  QgPrimaryButton,
  QgSectionTitle,
  QgUi,
  qgCoverOf
} from '../components/QgWidgets';

@Component
struct QgDetailPage {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  private stack: NavPathStack = new NavPathStack();
  @State drama: QgDrama | undefined = undefined;
  @State episodes: QgEpisode[] = [];
  @State followed: boolean = false;
  @State queued: boolean = false;
  @State introExpanded: boolean = false;
  @State currentEp: number = 1;
  @State watchEp: number = 0;
  @State loading: boolean = true;
  @State errMsg: string = '';
  @State seasons: QgSeason[] = [];
  @State seasonsLoading: boolean = false;
  @State seasonsError: string = '';
  @State switchingSeasonId: string = '';
  @State seasonSwitchError: string = '';
  private requestedId: string = '';
  private loadSequence: number = 0;
  private seasonsSequence: number = 0;
  private visible: boolean = true;
  private seasonsCancelled: boolean = false;
  private seasonScroller: Scroller = new Scroller();
  private seasonRailReady: boolean = false;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;

  private getD(): QgDrama {
    return this.drama as QgDrama;
  }

  private goPlayer(episode: number): void {
    if (this.switchingSeasonId.length > 0) return;
    const d = this.getD();
    const p: QgPlayerParam = { dramaId: d.id, episode: episode };
    this.stack.pushPathByName('player', p);
  }

  private toggleFollow(): void {
    if (this.switchingSeasonId.length > 0) return;
    const d = this.getD();
    this.followed = QgStore.getInstance().toggleFollow(d.id, d.title, d.cover,
      d.episodeCount, d.finished, d.sourceId);
    AppStorage.setOrCreate('qgFollowTick', (AppStorage.get<number>('qgFollowTick') ?? 0) + 1);
  }

  private toggleQueue(): void {
    if (this.switchingSeasonId.length > 0) return;
    const d = this.getD();
    this.queued = QgStore.getInstance().toggleQueue(d.id, d.title, d.cover,
      d.episodeCount, d.finished, d.sourceId);
    AppStorage.setOrCreate('qgQueueTick', (AppStorage.get<number>('qgQueueTick') ?? 0) + 1);
  }

  private reportIssue(): void {
    promptAction.showToast({ message: '已记录反馈入口，后续可在设置中查看提交状态' });
  }

  private load(dramaId: string): void {
    const sequence: number = ++this.loadSequence;
    this.requestedId = dramaId;
    this.loading = this.drama === undefined;
    this.switchingSeasonId = this.drama !== undefined && this.drama.id !== dramaId ? dramaId : '';
    this.errMsg = '';
    this.seasonSwitchError = '';
    this.seasonsError = '';
    this.introExpanded = false;
    this.seasonsSequence++;
    if (!this.seasons.some((season: QgSeason): boolean => season.drama.id === dramaId)) {
      this.seasons = [];
      const anchor: QgDrama = new QgDrama(dramaId, '', '');
      anchor.sourceId = dramaId.split(':')[0];
      this.loadSeasons(anchor, sequence);
    } else {
      this.seasonsLoading = false;
    }
    QgRepository.detail(dramaId)
      .then((detail: QgDramaDetail) => {
        if (!this.visible || sequence !== this.loadSequence) return;
        // 同一张封面仅换签名地址时沿用旧地址，避免沉浸背景/海报闪重载
        if (this.drama !== undefined && qgSameImage(this.drama.cover, detail.drama.cover)) {
          detail.drama.cover = this.drama.cover;
        }
        this.drama = detail.drama;
        this.episodes = detail.episodes;
        this.loading = false;
        this.switchingSeasonId = '';
        this.followed = QgStore.getInstance().isFollowed(detail.drama.id);
        this.queued = QgStore.getInstance().isQueued(detail.drama.id);
        this.refreshWatch();
        this.revealCurrentSeason();
      })
      .catch((error: BusinessError) => {
        if (!this.visible || sequence !== this.loadSequence) return;
        this.loading = false;
        this.switchingSeasonId = '';
        const message: string = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
        if (this.drama !== undefined) {
          this.requestedId = this.drama.id;
          this.seasonSwitchError = message;
        } else {
          this.errMsg = message;
        }
      });
  }

  private refreshWatch(): void {
    if (this.drama === undefined) return;
    const rec = QgStore.getInstance().getWatch(this.drama.id);
    const total: number = this.episodes.length > 0 ? this.episodes.length : this.drama.episodeCount;
    if (rec !== undefined && rec.episode >= 1 && rec.episode <= total) {
      this.watchEp = rec.episode;
      this.currentEp = rec.episode;
    } else {
      this.watchEp = 0;
      this.currentEp = 1;
    }
  }

  private loadSeasons(anchor: QgDrama, detailSequence: number = this.loadSequence): void {
    const sequence: number = ++this.seasonsSequence;
    this.seasonsLoading = true;
    this.seasonsError = '';
    this.seasonsCancelled = false;
    QgRepository.seasons(anchor)
      .then((seasons: QgSeason[]) => {
        if (!this.visible || sequence !== this.seasonsSequence || detailSequence !== this.loadSequence) return;
        this.seasons = seasons;
        this.seasonsLoading = false;
        this.revealCurrentSeason();
      })
      .catch((error: BusinessError) => {
        if (!this.visible || sequence !== this.seasonsSequence || detailSequence !== this.loadSequence) return;
        this.seasonsLoading = false;
        this.seasonsError = error.message !== undefined && error.message.length > 0 ? error.message : '系列信息加载失败';
      });
  }

  private selectSeason(season: QgSeason): void {
    if (this.switchingSeasonId.length > 0 || this.drama?.id === season.drama.id) return;
    this.load(season.drama.id);
  }

  private seasonSubtitle(season: QgSeason): string {
    const parts: string[] = [];
    if (season.drama.episodeCount > 0) parts.push(`${season.drama.episodeCount} 集`);
    const record = QgStore.getInstance().getWatch(season.drama.id);
    parts.push(record !== undefined && record.episode >= 1 ? `已看到第 ${record.episode} 集` : '未观看');
    return parts.join(' · ');
  }

  private currentSeasonLabel(): string {
    const selected: QgSeason | undefined = this.seasons.find((season: QgSeason): boolean => season.drama.id === this.drama?.id);
    return selected !== undefined ? `第 ${selected.number} 季` : '';
  }

  private revealCurrentSeason(): void {
    if (!this.seasonRailReady) return;
    const index: number = this.seasons.findIndex((season: QgSeason): boolean => season.drama.id === this.drama?.id);
    if (index >= 0) this.seasonScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
  }

  private hideDestination(): void {
    this.visible = false;
    this.loadSequence++;
    this.seasonsSequence++;
    this.seasonsCancelled = this.seasonsCancelled || this.seasonsLoading;
    this.seasonsLoading = false;
    this.switchingSeasonId = '';
    if (this.drama !== undefined) this.requestedId = this.drama.id;
  }

  private showDestination(): void {
    const wasHidden: boolean = !this.visible;
    this.visible = true;
    if (wasHidden && this.loading && this.requestedId.length > 0) {
      this.load(this.requestedId);
      return;
    }
    this.refreshWatch();
    if (wasHidden && this.seasonsCancelled && this.drama !== undefined) this.loadSeasons(this.drama);
  }

  aboutToDisappear(): void {
    this.hideDestination();
  }

  private episodeTotal(): number {
    if (this.episodes.length > 0) {
      return this.episodes.length;
    }
    return this.getD().episodeCount;
  }

  private similarList(): QgDrama[] {
    const d = this.getD();
    const cached: QgDrama[] = QgRepository.cachedFirstPage();
    return cached.filter((x: QgDrama): boolean => x.id !== d.id).slice(0, 8);
  }

  build() {
    NavDestination() {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(QgTheme.color('accentInk', this.themeId, this.darkOn))
          Text('正在加载剧集详情…')
            .fontSize(13)
            .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
      } else if (this.errMsg.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column({ space: 14 }) {
            SymbolGlyph($r('sys.symbol.wifi_slash'))
              .fontSize(44)
              .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
            Text(this.errMsg)
              .fontSize(14)
              .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
            QgPrimaryButton({
              label: '返回',
              compact: true,
              onTap: () => this.stack.pop()
            })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)

          Row() {
            QgBackBtn({ solid: true, onBack: () => this.stack.pop() })
          }
          .padding({ left: 16, top: this.safeTop + 8 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
      } else {
        this.ContentBuilder()
      }
    }
    .hideTitleBar(true)
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .onShown(() => this.showDestination())
    .onHidden(() => this.hideDestination())
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const p = ctx.pathInfo.param as QgDetailParam;
      if (p === undefined || p === null || typeof p.dramaId !== 'string' || p.dramaId.length === 0) {
        this.loading = false;
        this.errMsg = '缺少剧集参数';
        return;
      }
      this.load(p.dramaId);
    })
  }

  @Builder
  ContentBuilder() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          this.ImmersiveHeaderBuilder()
          Column() {
            this.ActionRowBuilder()
            this.IntroCardBuilder()
            this.SeasonsBuilder()
            this.EpisodeBuilder()
            this.SimilarBuilder()
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + 44 })
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')

      // 悬浮玻璃顶栏
      Row() {
        QgBackBtn({ solid: false, onBack: () => this.stack.pop() })
        Blank()
        QgIconBtn({
          icon: $r('sys.symbol.exclamationmark_circle'),
          label: '反馈信息有误',
          solid: false,
          onTap: () => this.reportIssue()
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.safeTop + 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
  }

  @Builder
  ImmersiveHeaderBuilder() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 模糊氛围背景
      Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
        .width('100%')
        .height(320 + this.safeTop)
        .objectFit(ImageFit.Cover)
        .blur(46)
        .opacity(0.65)

      // 底部融合渐变
      Column()
        .width('100%')
        .height(320 + this.safeTop)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            ['#66000000', 0],
            [QgTheme.color('bgClear', this.themeId, this.darkOn), 0.35],
            [QgTheme.color('bg', this.themeId, this.darkOn), 1]
          ]
        })

      // 前景海报 + 标题与标签
      Row({ space: 18 }) {
        Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
          .width(126)
          .height(176)
          .objectFit(ImageFit.Cover)
          .borderRadius(QgUi.R_POSTER)
          .interpolation(ImageInterpolation.High)
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .shadow({ radius: 24, color: '#55000000', offsetX: 0, offsetY: 10 })

        Column({ space: 10 }) {
          Text(this.getD().title)
            .fontSize(26)
            .fontWeight(FontWeight.Bolder)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            .maxLines(3)
            .lineHeight(32)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Flex({ wrap: FlexWrap.Wrap }) {
            if (this.getD().genre.length > 0) {
              Text(this.getD().genre)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(10)
                .backgroundColor(QgTheme.color('glassBg', this.themeId, this.darkOn))
                .backgroundBlurStyle(BlurStyle.Thin)
                .border({ width: 1, color: QgTheme.color('glassStroke', this.themeId, this.darkOn) })
                .margin({ right: 6, bottom: 6 })
            }
            Text(`${this.episodeTotal()} 集 · ${this.getD().finished ? '已完结' : '连载中'}`)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(QgTheme.color('glassBg', this.themeId, this.darkOn))
              .border({ width: 1, color: QgTheme.color('glassStroke', this.themeId, this.darkOn) })
              .margin({ right: 6, bottom: 6 })
          }

          if (this.watchEp > 0) {
            Column({ space: 5 }) {
              Text(`已看到第 ${this.watchEp} 集`)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
              if (this.episodeTotal() > 0) {
                Progress({ value: this.watchEp, total: this.episodeTotal() })
                  .color(QgTheme.color('accent', this.themeId, this.darkOn))
                  .backgroundColor(QgTheme.color('divider', this.themeId, this.darkOn))
                  .height(3)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: this.safeTop + 68, bottom: 16 })
    }
    .width('100%')
  }

  @Builder
  ActionRowBuilder() {
    Row({ space: 10 }) {
      QgPrimaryButton({
        label: this.watchEp > 0 ? `继续看第 ${this.watchEp} 集` : '立即观看',
        icon: $r('sys.symbol.play_fill'),
        onTap: () => this.goPlayer(this.currentEp)
      })
      .layoutWeight(1)

      QgGhostButton({
        label: this.followed ? '已追剧' : '追剧',
        icon: this.followed ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
        active: this.followed,
        onTap: () => this.toggleFollow()
      })

      QgIconBtn({
        icon: this.queued ? $r('sys.symbol.checkmark') : $r('sys.symbol.plus'),
        btnSize: QgUi.BTN_H,
        iconSize: 19,
        label: this.queued ? '已加入待看' : '加入待看',
        solid: true,
        tint: this.queued ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('text', this.themeId, this.darkOn),
        onTap: () => this.toggleQueue()
      })
    }
    .width('100%')
    .padding({ top: 10, bottom: 16 })
    .enabled(this.switchingSeasonId.length === 0)
  }

  @Builder
  IntroCardBuilder() {
    if (this.getD().intro.length > 0 || this.getD().tags.length > 0) {
      Column({ space: 12 }) {
        if (this.getD().tags.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.getD().tags.slice(0, 6), (tag: string) => {
              Text(`# ${tag}`)
                .fontSize(12)
                .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
                .margin({ right: 8, bottom: 6 })
            }, (tag: string) => `tag_${tag}`)
          }
          .width('100%')
        }

        if (this.getD().intro.length > 0) {
          Text(this.getD().intro)
            .fontSize(13)
            .lineHeight(21)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
            .maxLines(this.introExpanded ? 12 : 3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.introExpanded ? '收起简介' : '展开全部简介')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            .onClick(() => {
              this.introExpanded = !this.introExpanded;
            })
        }
      }
      .width('100%')
      .padding(18)
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  SeasonsBuilder() {
    if (this.seasonsLoading || this.seasonsError.length > 0 || this.seasons.length > 1) {
      Column({ space: 10 }) {
        if (this.seasonsLoading && this.seasons.length <= 1) {
          Row({ space: 10 }) {
            LoadingProgress().width(20).height(20).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
            Text('正在读取系列信息…').fontSize(13).fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
          }.height(44)
        }
        if (this.seasonsError.length > 0) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('系列信息暂不可用').fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
              Text(this.seasonsError).fontSize(12).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            QgGhostButton({ label: '重试', compact: true, onTap: () => this.loadSeasons(this.getD()) })
          }.width('100%')
        }
        if (this.seasons.length > 1) {
          Row() {
            Text('分季').fontSize(18).fontWeight(FontWeight.Bold)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            Blank()
            Text(`共 ${this.seasons.length} 季 · ${this.currentSeasonLabel()}`).fontSize(12)
              .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
          }.width('100%')
          List({ space: 10, scroller: this.seasonScroller }) {
            ForEach(this.seasons, (season: QgSeason) => {
              ListItem() {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: 7 }) {
                    Row({ space: 6 }) {
                      Text(`第 ${season.number} 季`).fontSize(15).fontWeight(FontWeight.Bold)
                        .fontColor(QgTheme.color(this.drama?.id === season.drama.id ? 'accentOn' : 'text', this.themeId, this.darkOn))
                      Blank()
                      if (this.switchingSeasonId === season.drama.id) {
                        LoadingProgress().width(16).height(16).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
                      } else if (this.drama?.id === season.drama.id) {
                        Text('当前季').fontSize(10)
                          .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
                      }
                    }.width('100%')
                    Text(season.drama.title).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(QgTheme.color(this.drama?.id === season.drama.id ? 'accentOn' : 'text', this.themeId, this.darkOn))
                    Text(this.seasonSubtitle(season)).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(QgTheme.color(this.drama?.id === season.drama.id ? 'accentOn' : 'textDim', this.themeId, this.darkOn))
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
                .width(176).height(104).padding(14).borderRadius(16)
                .backgroundColor(QgTheme.color(this.drama?.id === season.drama.id ? 'accent' : 'surface', this.themeId, this.darkOn))
                .border({ width: 1, color: QgTheme.color(this.switchingSeasonId === season.drama.id ? 'accentInk' : 'divider', this.themeId, this.darkOn) })
                .enabled(this.switchingSeasonId.length === 0)
                .accessibilityText(`第 ${season.number} 季，${season.drama.title}，${this.seasonSubtitle(season)}${this.drama?.id === season.drama.id ? '，当前季' : ''}`)
                .onClick(() => this.selectSeason(season))
              }
            }, (season: QgSeason) => season.drama.id)
          }
          .listDirection(Axis.Horizontal).scrollBar(BarState.Off).height(108).width('100%')
          .onAppear(() => { this.seasonRailReady = true; this.revealCurrentSeason(); })
          .onDisAppear(() => { this.seasonRailReady = false; })
          .onAreaChange(() => this.revealCurrentSeason())
          if (this.switchingSeasonId.length > 0) {
            Text('正在切换分季，加载完成后显示该季分集…').fontSize(12)
              .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
          } else if (this.seasonSwitchError.length > 0) {
            Text(this.seasonSwitchError).fontSize(12).maxLines(3)
              .fontColor(QgTheme.color('danger', this.themeId, this.darkOn))
          }
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start).margin({ top: 18, bottom: 20 })
    }
  }

  @Builder
  EpisodeBuilder() {
    if (this.episodes.length > 0) {
      QgEpisodePicker({
        episodes: this.episodes,
        currentEpisode: this.currentEp,
        watchEpisode: this.watchEp,
        themeId: this.themeId,
        darkOn: this.darkOn,
        disabled: this.switchingSeasonId.length > 0,
        onPick: (order: number) => this.goPlayer(order)
      })
    } else {
      Text('本季暂无可播放分集').fontSize(13).width('100%').padding({ top: 16, bottom: 16 })
        .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
    }
  }

  @Builder
  SimilarBuilder() {
    if (this.similarList().length > 0) {
      Column() {
        QgSectionTitle({ title: '猜你喜欢', eyebrow: 'SIMILAR DRAMAS' })
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.similarList(), (d: QgDrama) => {
              Column({ space: 8 }) {
                Image(qgCoverOf(d.cover, d.sourceId))
                  .width(106)
                  .height(148)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(QgUi.R_POSTER)
                  .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
                  .interpolation(ImageInterpolation.Medium)
                Text(d.title)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(106)
              }
              .alignItems(HorizontalAlign.Start)
              .onClick(() => {
                const p: QgDetailParam = { dramaId: d.id };
                this.stack.pushPathByName('detail', p);
              })
            }, (d: QgDrama) => `similar_${d.id}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

@Builder
export function QgDetailBuilder() {
  QgDetailPage()
}
