/**
 * 发现页（首页）—— 「夜幕 · 青柠」。
 *
 * - 固定顶栏与分类胶囊行，下方为分类间跟手横滑（Swiper）的独立数据泳道；
 * - 未加载分类展示骨架屏，滑入即懒加载并预取相邻分类；
 * - 焦点推荐、接着上次看、错落双列瀑布流、巨型序号热播榜、
 *   站源切换、下拉刷新、触底翻页、随机选剧等原有能力全部保留。
 */
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  QgCategory,
  QgDrama,
  QgDetailParam,
  QgPageResult,
  QgPlayerParam,
  QgSourceDesc,
  QgWatchRecord
} from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgTheme } from '../components/QgTheme';
import {
  QgChip,
  QgDramaCard,
  QgEmptyView,
  QgIconBtn,
  QgPrimaryButton,
  QgSectionTitle,
  QgUi,
  qgCoverOf,
  qgCoverOfDramaId
} from '../components/QgWidgets';

/** 发现页单分类泳道数据（@Observed 供子组件 @ObjectLink 感知变更） */
@Observed
class QgExploreLane {
  catId: string = '';
  label: string = '';
  dramas: QgDrama[] = [];
  page: number = 1;
  hasMore: boolean = false;
  loading: boolean = false;
  loadingMore: boolean = false;
  errMsg: string = '';
  featuredIdx: number = 0;
  loaded: boolean = false;
  seq: number = 0;

  constructor(catId: string, label: string) {
    this.catId = catId;
    this.label = label;
  }
}

/** 单分类泳道视图：焦点 Hero / 继续观看 / 瀑布流 / 热播榜 / 骨架与错误态 / 下拉刷新 / 触底加载 */
@Component
struct QgExploreLaneView {
  @ObjectLink @Watch('onLaneChanged') lane: QgExploreLane;
  isRecommend: boolean = false;
  stack: NavPathStack = new NavPathStack();
  onRefreshLane: () => void = (): void => {};
  onLoadMoreLane: () => void = (): void => {};
  onVerticalScroll: (yOffset: number) => void = (): void => {};
  onStopScroll: () => void = (): void => {};
  @State refreshing: boolean = false;
  @State heroFollowed: boolean = false;
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 0;
  @StorageProp('qgHomeTick') homeTick: number = 0;
  @StorageProp('qgWatchTick') watchTick: number = 0;
  @StorageProp('qgFollowTick') @Watch('onFollowTick') followTick: number = 0;

  aboutToAppear(): void {
    this.refreshHeroFollow();
  }

  onFollowTick(): void {
    this.refreshHeroFollow();
  }

  onLaneChanged(): void {
    if (!this.lane.loading) {
      this.refreshing = false;
    }
    this.refreshHeroFollow();
  }

  private heroDrama(): QgDrama | undefined {
    return this.lane.dramas[this.lane.featuredIdx] ?? this.lane.dramas[0];
  }

  private refreshHeroFollow(): void {
    const hero: QgDrama | undefined = this.heroDrama();
    this.heroFollowed = hero !== undefined && QgStore.getInstance().isFollowed(hero.id);
  }

  private goDetail(id: string): void {
    if (QgStore.getInstance().getSettings().directPlay) {
      const rec: QgWatchRecord | undefined = QgStore.getInstance().getWatch(id);
      const episode: number = rec !== undefined && rec.episode >= 1 ? rec.episode : 1;
      const pp: QgPlayerParam = { dramaId: id, episode: episode };
      this.stack.pushPathByName('player', pp);
      return;
    }
    const p: QgDetailParam = { dramaId: id };
    this.stack.pushPathByName('detail', p);
  }

  private goPlayer(d: QgDrama, episode: number): void {
    const p: QgPlayerParam = { dramaId: d.id, episode: episode };
    this.stack.pushPathByName('player', p);
  }

  private randomDrama(): void {
    if (this.lane.dramas.length === 0) {
      return;
    }
    const idx: number = Math.floor(Math.random() * this.lane.dramas.length);
    this.goDetail(this.lane.dramas[idx].id);
  }

  private resumeEpisode(d: QgDrama): number {
    const rec = QgStore.getInstance().getWatch(d.id);
    if (rec !== undefined && rec.episode <= d.episodeCount) {
      return rec.episode;
    }
    return 1;
  }

  private recentWatches(): QgWatchRecord[] {
    return QgStore.getInstance().getWatchList().slice(0, 6);
  }

  private watchPct(r: QgWatchRecord): number {
    if (r.duration <= 0) {
      return 6;
    }
    const pct: number = Math.round(r.progress * 100 / r.duration);
    return pct > 100 ? 100 : (pct < 3 ? 3 : pct);
  }

  private goWatch(r: QgWatchRecord): void {
    const p: QgPlayerParam = { dramaId: r.dramaId, episode: r.episode };
    this.stack.pushPathByName('player', p);
  }

  private gridColumnCount(): number {
    if (this.screenWidth >= 840) {
      return 4;
    }
    if (this.screenWidth >= 600) {
      return 3;
    }
    return 2;
  }

  /** 将剧集分配到 N 列，实现错落瀑布流 */
  private columnDramas(list: QgDrama[], colIdx: number, colCount: number): QgDrama[] {
    const out: QgDrama[] = [];
    for (let i: number = colIdx; i < list.length; i += colCount) {
      out.push(list[i]);
    }
    return out;
  }

  /** 错落海报比例：奇偶列交替不同高宽比 */
  private cardRatio(colIdx: number, rowIdx: number): number {
    const pattern: number[] = [0.68, 0.78, 0.72, 0.66];
    return pattern[(colIdx + rowIdx) % pattern.length];
  }

  private columnIndices(): number[] {
    const count: number = this.gridColumnCount();
    const out: number[] = [];
    for (let i: number = 0; i < count; i++) {
      out.push(i);
    }
    return out;
  }

  private rankedList(): QgDrama[] {
    const rest: QgDrama[] = this.lane.dramas.slice(1);
    const sorted: QgDrama[] = rest.slice().sort((a: QgDrama, b: QgDrama): number => b.heat - a.heat);
    return sorted.slice(0, 5);
  }

  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column() {
          if (this.lane.loading) {
            this.LoadingBuilder()
          } else if (this.lane.errMsg.length > 0) {
            this.ErrorBuilder()
          } else if (this.lane.dramas.length === 0) {
            QgEmptyView({
              iconRes: $r('sys.symbol.square_grid_2x2'),
              message: '暂无剧集',
              hint: '下拉刷新或切换其他站源试试',
              actionText: '重新加载',
              onAction: () => this.onRefreshLane()
            })
          } else {
            this.ContentBuilder()
          }

          if (!this.lane.loading && this.lane.errMsg.length === 0 && this.lane.dramas.length > 0) {
            if (this.lane.loadingMore) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
                Text('正在加载更多…').fontSize(12).fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 18, bottom: 18 })
            } else if (!this.lane.hasMore) {
              Text('— 已加载全部剧集 —')
                .fontSize(12)
                .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 18, bottom: 18 })
            }
          }
        }
        .width('100%')
        .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + QgUi.TAB_BAR_SPACE })
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.TopStart)
      .width('100%')
      .height('100%')
      .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
        this.onVerticalScroll(yOffset);
      })
      .onScrollStop(() => {
        this.onStopScroll();
      })
      .onReachEnd(() => {
        this.onLoadMoreLane();
      })
    }
    .onRefreshing(() => {
      this.onRefreshLane();
    })
    .width('100%')
    .height('100%')
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
  }

  /** 焦点推荐卡片（圆角卡面，底部渐变融入页面画布） */
  @Builder
  HeroBuilder(d: QgDrama) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(qgCoverOf(d.cover, d.sourceId))
        .width('100%')
        .height(this.screenWidth >= 600 ? 440 : 400)
        .objectFit(ImageFit.Cover)
        .interpolation(ImageInterpolation.High)
        .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
        .onClick(() => this.goDetail(d.id))

      Column()
        .width('100%')
        .height(300)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [[QgTheme.veil('00', this.themeId, this.darkOn), 0], [QgTheme.veil('D9', this.themeId, this.darkOn), 0.42], [QgTheme.color('bg', this.themeId, this.darkOn), 1]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text('焦点推荐')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
          Text(`${d.genre.length > 0 ? d.genre : '短剧'} · ${d.episodeCount} 集 · ${d.finished ? '已完结' : '连载中'}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 14 }) {
          Column({ space: 6 }) {
            Text(d.title)
              .fontSize(28)
              .fontWeight(FontWeight.Bolder)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
              .maxLines(2)
              .lineHeight(34)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => this.goDetail(d.id))
            if (d.intro.length > 0) {
              Text(d.intro)
                .fontSize(12)
                .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.lane.dramas.length > 1) {
            Column({ space: 4 }) {
              Stack({ alignContent: Alignment.BottomEnd }) {
                Image(qgCoverOf(this.lane.dramas[(this.lane.featuredIdx + 1) % this.lane.dramas.length].cover, d.sourceId))
                  .width(58)
                  .height(78)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(12)
                  .border({ width: 1.5, color: '#66FFFFFF' })
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(12)
                  .fontColor([Color.White])
                  .padding(4)
                  .borderRadius(10)
                  .backgroundColor('#88000000')
                  .margin(4)
              }
              Text('换一部')
                .fontSize(10)
                .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
            }
            .accessibilityText('切换下一部焦点推荐')
            .onClick(() => {
              this.lane.featuredIdx = (this.lane.featuredIdx + 1) % this.lane.dramas.length;
              this.refreshHeroFollow();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        Row({ space: 10 }) {
          QgPrimaryButton({
            label: this.resumeEpisode(d) > 1 ? `继续第 ${this.resumeEpisode(d)} 集` : '立即播放',
            icon: $r('sys.symbol.play_fill'),
            onTap: () => this.goPlayer(d, this.resumeEpisode(d))
          })
          .layoutWeight(1)

          QgIconBtn({
            icon: this.heroFollowed ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            btnSize: QgUi.BTN_H,
            iconSize: 20,
            label: this.heroFollowed ? '取消追剧' : '加入追剧',
            tint: this.heroFollowed ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('text', this.themeId, this.darkOn),
            onTap: () => {
              this.heroFollowed = QgStore.getInstance().toggleFollow(
                d.id, d.title, d.cover, d.episodeCount, d.finished, d.sourceId
              );
              AppStorage.setOrCreate('qgFollowTick', this.followTick + 1);
            }
          })

          QgIconBtn({
            icon: $r('sys.symbol.shuffle'),
            btnSize: QgUi.BTN_H,
            iconSize: 19,
            label: '随机选剧',
            onTap: () => this.randomDrama()
          })
        }
        .width('100%')
        .padding({ top: 4 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 14 })
    }
    .width('100%')
    .borderRadius(QgUi.R_CARD)
    .clip(true)
    .margin({ top: 4 })
  }

  @Builder
  ContentBuilder() {
    Column() {
      if (this.isRecommend) {
        this.HeroBuilder(this.heroDrama() as QgDrama)
        this.ContinueBuilder()
        if (QgStore.getInstance().getSettings().homeRecommendations) {
          this.MasonrySectionBuilder('值得一看', 'CURATED PICKS', this.lane.dramas.slice(1))
        }
        if (QgStore.getInstance().getSettings().homeRank) {
          this.RankSectionBuilder()
        }
      } else {
        this.MasonrySectionBuilder(this.lane.label, 'CATEGORY', this.lane.dramas)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 继续观看横滑卡片 */
  @Builder
  ContinueBuilder() {
    if (QgStore.getInstance().getSettings().homeContinue && this.recentWatches().length > 0) {
      Column() {
        QgSectionTitle({
          title: '接着上次看',
          eyebrow: 'CONTINUE WATCHING',
          actionText: '全部',
          onAction: () => this.stack.pushPathByName('history', '')
        })
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.recentWatches(), (r: QgWatchRecord) => {
              Row({ space: 12 }) {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Image(qgCoverOfDramaId(r.cover, r.dramaId))
                    .width(64)
                    .height(84)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(12)
                    .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
                  Row()
                    .width(`${this.watchPct(r)}%`)
                    .height(3)
                    .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
                }
                .width(64)
                .height(84)
                .clip(true)
                .borderRadius(12)

                Column({ space: 6 }) {
                  Text(r.title)
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`第 ${r.episode} 集 · ${this.watchPct(r)}%`)
                    .fontSize(12)
                    .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
                  Progress({ value: this.watchPct(r), total: 100 })
                    .color(QgTheme.color('accent', this.themeId, this.darkOn))
                    .backgroundColor(QgTheme.color('divider', this.themeId, this.darkOn))
                    .height(3)
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Stack() {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontSize(14)
                    .fontColor([QgTheme.color('accentOn', this.themeId, this.darkOn)])
                }
                .width(34)
                .height(34)
                .borderRadius(17)
                .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
              }
              .width(268)
              .padding(12)
              .borderRadius(QgUi.R_CARD)
              .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
              .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
              .onClick(() => this.goWatch(r))
            }, (r: QgWatchRecord) => `resume_${r.dramaId}_${r.updatedAt}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
      }
      .width('100%')
    }
  }

  /** 错落瀑布流剧集区 */
  @Builder
  MasonrySectionBuilder(title: string, eyebrow: string, list: QgDrama[]) {
    if (list.length > 0) {
      Column() {
        QgSectionTitle({ title: title, eyebrow: eyebrow })
        Row({ space: 14 }) {
          ForEach(this.columnIndices(), (colIdx: number) => {
            Column({ space: 22 }) {
              ForEach(this.columnDramas(list, colIdx, this.gridColumnCount()), (d: QgDrama, rowIdx: number) => {
                QgDramaCard({
                  cover: d.cover,
                  cardTitle: d.title,
                  subText: d.finished ? `${d.genre} · ${d.episodeCount}集` : `更新至${d.episodeCount}集`,
                  badge: d.badge.length > 0 ? d.badge : d.viewsText,
                  sourceId: d.sourceId,
                  ratio: this.cardRatio(colIdx, rowIdx),
                  onTapCard: () => this.goDetail(d.id)
                })
              }, (d: QgDrama) => `masonry_${colIdx}_${d.id}`)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }, (colIdx: number) => `col_${this.gridColumnCount()}_${colIdx}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 巨型序号热播榜 */
  @Builder
  RankSectionBuilder() {
    if (this.rankedList().length > 0) {
      Column() {
        QgSectionTitle({
          title: '热播榜',
          eyebrow: 'TOP CHART',
          actionText: '换一批',
          onAction: () => this.onLoadMoreLane()
        })
        Column({ space: 4 }) {
          ForEach(this.rankedList(), (d: QgDrama, idx: number) => {
            this.RankRowBuilder(d, idx)
          }, (d: QgDrama) => `rank_${d.id}`)
        }
        .width('100%')
        .padding(14)
        .borderRadius(QgUi.R_CARD)
        .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
        .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  RankRowBuilder(d: QgDrama, idx: number) {
    Row({ space: 14 }) {
      Text(`0${idx + 1}`)
        .fontSize(26)
        .fontWeight(FontWeight.Bolder)
        .fontColor(idx === 0 ? QgTheme.color('rankOne', this.themeId, this.darkOn) :
          (idx === 1 ? QgTheme.color('rankTwo', this.themeId, this.darkOn) :
            (idx === 2 ? QgTheme.color('rankThree', this.themeId, this.darkOn) : QgTheme.color('textFaint', this.themeId, this.darkOn))))
        .width(42)
        .textAlign(TextAlign.Start)

      Image(qgCoverOf(d.cover, d.sourceId))
        .width(50)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(10)
        .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
        .interpolation(ImageInterpolation.Medium)

      Column({ space: 5 }) {
        Text(d.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${d.genre.length > 0 ? d.genre + ' · ' : ''}${d.finished ? '已完结' : `更新至${d.episodeCount}集`}`)
          .fontSize(12)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.flame'))
          .fontSize(13)
          .fontColor([QgTheme.color('rankOne', this.themeId, this.darkOn)])
        Text(`${d.heat}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
      }
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(12)
      .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 6, right: 6 })
    .borderRadius(16)
    .onClick(() => this.goDetail(d.id))
  }

  @Builder
  LoadingBuilder() {
    Column({ space: 18 }) {
      Column()
        .width('100%')
        .height(340)
        .borderRadius(QgUi.R_CARD)
        .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      Row({ space: 14 }) {
        Column()
          .layoutWeight(1)
          .height(220)
          .borderRadius(QgUi.R_POSTER)
          .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
        Column()
          .layoutWeight(1)
          .height(190)
          .borderRadius(QgUi.R_POSTER)
          .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 8 }) {
        LoadingProgress().width(18).height(18).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
        Text('正在拉取片库…').fontSize(13).fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
      }
      .padding({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 16, bottom: 32 })
  }

  @Builder
  ErrorBuilder() {
    Column({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.wifi_slash'))
          .fontSize(36)
          .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
      }
      .width(80)
      .height(80)
      .borderRadius(40)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))

      Text(this.lane.errMsg)
        .fontSize(14)
        .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      QgPrimaryButton({ label: '重新加载', compact: true, onTap: () => this.onRefreshLane() })
    }
    .width('100%')
    .padding({ top: 72, bottom: 72 })
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct ExploreTab {
  @StorageProp('qgTheme') themeId: string = 'lime';
  stack: NavPathStack = new NavPathStack();
  @State categories: QgCategory[] = [];
  @State catIdx: number = 0;
  @State lanes: QgExploreLane[] = [];
  @State metaErr: string = '';
  @State sourceName: string = '';
  @State sourceId: string = '';
  @State sourceIndex: number = 0;
  @State sourceSelectEpoch: number = 0;
  @State sourceEpoch: number = 0;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('darkMode') darkOn: boolean = false;
  @StorageProp('qgSourceTick') @Watch('onSourceTick') sourceTick: number = 0;
  private loadSeq: number = 0;

  aboutToAppear(): void {
    this.reloadMeta();
    this.activateLane(this.catIdx);
    this.loadFirst();
  }

  onSourceTick(): void {
    this.catIdx = 0;
    this.sourceEpoch++;
    this.lanes = [];
    this.reloadMeta();
    this.loadFirst();
    this.activateLane(0);
    this.showTabBar();
  }

  private reloadMeta(): void {
    this.categories = QgRepository.categories();
    this.ensureLanes();
    this.sourceId = QgRepository.currentSourceId();
    this.sourceName = QgRepository.currentSourceName();
    this.sourceIndex = this.sourceIndexOf(this.sourceId);
  }

  private sourceIndexOf(id: string): number {
    const idx: number = QgRepository.descriptions().findIndex((source: QgSourceDesc): boolean => source.id === id);
    return idx >= 0 ? idx : 0;
  }

  private sourceSelectOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    const sources: QgSourceDesc[] = QgRepository.descriptions();
    for (let i: number = 0; i < sources.length; i++) {
      const option: SelectOption = { value: sources[i].name };
      options.push(option);
    }
    return options;
  }

  private showTabBar(): void {
    if (AppStorage.get<boolean>('qgTabBarVisible') !== true) {
      AppStorage.setOrCreate('qgTabBarVisible', true);
    }
  }

  private hideTabBar(): void {
    if (AppStorage.get<boolean>('qgTabBarVisible') !== false) {
      AppStorage.setOrCreate('qgTabBarVisible', false);
    }
  }

  private handleVerticalScroll(yOffset: number): void {
    if (yOffset > 1.2) {
      this.hideTabBar();
    } else if (yOffset < -1.2) {
      this.showTabBar();
    }
  }

  private requestSourceSwitch(id: string): void {
    this.sourceIndex = this.sourceIndexOf(this.sourceId);
    this.sourceSelectEpoch++;
    if (id.length === 0 || id === this.sourceId) {
      return;
    }
    QgRepository.setSource(id);
    this.sourceId = QgRepository.currentSourceId();
    this.sourceName = QgRepository.currentSourceName();
    this.sourceIndex = this.sourceIndexOf(this.sourceId);
    this.sourceSelectEpoch++;
    AppStorage.setOrCreate('qgSourceTick', (AppStorage.get<number>('qgSourceTick') ?? 0) + 1);
    promptAction.showToast({ message: '站源已切换' });
  }

  /** 按分类表重建泳道：保留同名泳道实例（已加载数据不丢），新增未加载泳道 */
  private ensureLanes(): void {
    const existing: Map<string, QgExploreLane> = new Map<string, QgExploreLane>();
    for (let i: number = 0; i < this.lanes.length; i++) {
      existing.set(this.lanes[i].catId, this.lanes[i]);
    }
    const next: QgExploreLane[] = [];
    for (let i: number = 0; i < this.categories.length; i++) {
      const c: QgCategory = this.categories[i];
      const kept: QgExploreLane | undefined = existing.get(c.id);
      if (kept !== undefined) {
        kept.label = c.label;
        next.push(kept);
      } else {
        next.push(new QgExploreLane(c.id, c.label));
      }
    }
    this.lanes = next;
  }

  private loadFirst(): void {
    this.loadSeq++;
    const seq: number = this.loadSeq;
    const sourceId: string = QgRepository.currentSourceId();
    QgRepository.loadCategories()
      .then((categories: QgCategory[]) => {
        if (seq !== this.loadSeq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        this.categories = categories;
        this.metaErr = '';
        this.ensureLanes();
        if (this.catIdx >= this.lanes.length) {
          this.catIdx = 0;
        }
        this.activateLane(this.catIdx);
      })
      .catch((error: BusinessError) => {
        if (seq !== this.loadSeq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        if (this.lanes.length === 0) {
          this.metaErr = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
        }
      });
  }

  /** 激活泳道：空/失败泳道重载，并预取相邻分类 */
  private activateLane(idx: number): void {
    if (this.lanes.length === 0) {
      return;
    }
    if (idx < 0 || idx >= this.lanes.length) {
      idx = 0;
    }
    const lane: QgExploreLane = this.lanes[idx];
    if (!lane.loading && lane.dramas.length === 0) {
      this.loadLane(lane, false);
    }
    this.prefetchNeighbors();
  }

  private loadLane(lane: QgExploreLane, background: boolean): void {
    lane.seq++;
    const seq: number = lane.seq;
    const sourceId: string = QgRepository.currentSourceId();
    lane.loading = true;
    lane.loadingMore = false;
    lane.errMsg = '';
    lane.page = 1;
    lane.featuredIdx = 0;
    QgRepository.catalogPage(lane.catId, 1, background)
      .then((result: QgPageResult) => {
        if (seq !== lane.seq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        lane.dramas = this.dedupeDramas(result.dramas);
        lane.hasMore = result.hasMore;
        lane.loading = false;
        lane.loaded = true;
        this.prefetchNeighbors();
      })
      .catch((error: BusinessError) => {
        if (seq !== lane.seq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        lane.dramas = [];
        lane.hasMore = false;
        lane.loading = false;
        lane.loaded = true;
        lane.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  private loadMoreLane(lane: QgExploreLane): void {
    if (lane.loading || lane.loadingMore || !lane.hasMore || lane.errMsg.length > 0) {
      return;
    }
    lane.loadingMore = true;
    const seq: number = lane.seq;
    const sourceId: string = QgRepository.currentSourceId();
    const nextPage: number = lane.page + 1;
    QgRepository.catalogPage(lane.catId, nextPage, true)
      .then((result: QgPageResult) => {
        if (seq !== lane.seq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        lane.dramas = this.dedupeDramas(this.mergeDramas(lane.dramas, result.dramas));
        lane.hasMore = result.hasMore;
        lane.page = nextPage;
        lane.loadingMore = false;
      })
      .catch((error: BusinessError) => {
        if (seq !== lane.seq || sourceId !== QgRepository.currentSourceId()) {
          return;
        }
        lane.loadingMore = false;
        lane.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  /** 当前泳道有内容且无错误时，预取相邻未加载泳道（骨架屏即数据就绪） */
  private prefetchNeighbors(): void {
    if (this.catIdx < 0 || this.catIdx >= this.lanes.length) {
      return;
    }
    const lane: QgExploreLane = this.lanes[this.catIdx];
    if (lane.loading || lane.loadingMore || lane.dramas.length === 0 || lane.errMsg.length > 0) {
      return;
    }
    const targets: number[] = [this.catIdx - 1, this.catIdx + 1];
    for (let t: number = 0; t < targets.length; t++) {
      const idx: number = targets[t];
      if (idx < 0 || idx >= this.lanes.length) {
        continue;
      }
      const neighbor: QgExploreLane = this.lanes[idx];
      if (neighbor.loaded || neighbor.loading) {
        continue;
      }
      this.loadLane(neighbor, true);
    }
  }

  private mergeDramas(base: QgDrama[], more: QgDrama[]): QgDrama[] {
    const seen: Set<string> = new Set<string>();
    const out: QgDrama[] = [];
    for (let i: number = 0; i < base.length; i++) {
      seen.add(base[i].id);
      out.push(base[i]);
    }
    for (let i: number = 0; i < more.length; i++) {
      if (!seen.has(more[i].id)) {
        seen.add(more[i].id);
        out.push(more[i]);
      }
    }
    return out;
  }

  private dedupeDramas(items: QgDrama[]): QgDrama[] {
    const seen: Set<string> = new Set<string>();
    const out: QgDrama[] = [];
    for (let i = 0; i < items.length; i++) {
      const key: string = items[i].title.replace(/[\s·:：，,。.!！?？]/g, '').toLowerCase();
      if (key.length === 0 || seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(items[i]);
    }
    return out;
  }

  private selectCategory(idx: number): void {
    if (idx !== this.catIdx) {
      this.catIdx = idx;
    }
    this.activateLane(idx);
    this.showTabBar();
  }

  private onSwiperChange(idx: number): void {
    if (idx !== this.catIdx) {
      this.catIdx = idx;
    }
    this.activateLane(idx);
    this.showTabBar();
  }

  build() {
    Column() {
      this.TopBarBuilder()

      if (this.categories.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.categories, (c: QgCategory, idx: number) => {
              QgChip({
                label: c.label,
                selected: this.catIdx === idx,
                onSelectChip: () => this.selectCategory(idx)
              })
            }, (c: QgCategory, idx: number) => `${c.id}_${idx}`)
          }
          .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 2, bottom: 8 })
        .width('100%')
      }

      if (this.lanes.length > 0) {
        Swiper() {
          ForEach(this.lanes, (lane: QgExploreLane, idx: number) => {
            QgExploreLaneView({
              lane: lane,
              isRecommend: idx === 0,
              stack: this.stack,
              onRefreshLane: () => this.loadLane(lane, false),
              onLoadMoreLane: () => this.loadMoreLane(lane),
              onVerticalScroll: (yOffset: number) => this.handleVerticalScroll(yOffset),
              onStopScroll: () => this.showTabBar()
            })
          }, (lane: QgExploreLane, idx: number) => `${this.sourceEpoch}_${idx}_${lane.catId}`)
        }
        .index(this.catIdx)
        .loop(false)
        .indicator(false)
        .cachedCount(1)
        .duration(280)
        .layoutWeight(1)
        .width('100%')
        .onChange((idx: number) => this.onSwiperChange(idx))
      } else if (this.metaErr.length > 0) {
        this.MetaErrorBuilder()
      } else {
        Column({ space: 8 }) {
          LoadingProgress().width(24).height(24).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
          Text('正在加载…')
            .fontSize(13)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
  }

  /** 顶部栏：品牌标识 + 站源选择 + 搜索钮（固定于页面顶部） */
  @Builder
  TopBarBuilder() {
    Row({ space: 10 }) {
      Row({ space: 8 }) {
        Row()
          .width(8)
          .height(22)
          .borderRadius(4)
          .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
        Text('青果')
          .fontSize(24)
          .fontWeight(FontWeight.Bolder)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .onClick(() => this.selectCategory(0))
      }

      ForEach([this.sourceSelectEpoch], (epoch: number) => {
        Select(this.sourceSelectOptions())
          .selected(this.sourceIndex)
          .value(this.sourceName)
          .font({ size: 12, weight: FontWeight.Medium })
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
          .border({ width: 1, color: QgTheme.color('border', this.themeId, this.darkOn) })
          .borderRadius(18)
          .height(36)
          .constraintSize({ maxWidth: 148 })
          .flexShrink(1)
          .space(4)
          .selectedOptionBgColor(QgTheme.color('accentSoft', this.themeId, this.darkOn))
          .selectedOptionFontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
          .optionBgColor(QgTheme.color('surface', this.themeId, this.darkOn))
          .optionFontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .optionWidth(180)
          .optionHeight(420)
          .menuBackgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
          .onSelect((index: number) => {
            const selected: QgSourceDesc | undefined = QgRepository.descriptions()[index];
            if (selected !== undefined) {
              this.requestSourceSwitch(selected.id);
            }
          })
      }, (epoch: number) => `source_${epoch}_${this.sourceId}`)

      Blank()

      QgIconBtn({
        icon: $r('sys.symbol.magnifyingglass'),
        label: '搜索短剧',
        solid: true,
        tint: QgTheme.color('text', this.themeId, this.darkOn),
        onTap: () => this.stack.pushPathByName('search', '')
      })
    }
    .width('100%')
    .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: this.safeTop + 10, bottom: 10 })
  }

  /** 分类表加载失败且无任何泳道时的整页错误态 */
  @Builder
  MetaErrorBuilder() {
    Column({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.wifi_slash'))
          .fontSize(36)
          .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
      }
      .width(80)
      .height(80)
      .borderRadius(40)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))

      Text(this.metaErr)
        .fontSize(14)
        .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      QgPrimaryButton({ label: '重新加载', compact: true, onTap: () => this.loadFirst() })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}
