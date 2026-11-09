/**
 * 发现页（首页）。
 * 参照真果鉴首页结构：顶部搜索入口 + 站源分类横滑 + 下拉刷新 + 焦点大卡 + 热播宫格 + 热播榜。
 * 数据来自当前站源（QgRepository），异步加载，含加载 / 错误 / 空态与触底翻页。
 */
import { curves } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { QgCategory, QgDrama, QgDetailParam, QgPageResult, QgPlayerParam } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgChip, QgDramaCard, QgEmptyView, QgSectionTitle, qgCoverOf } from '../components/QgWidgets';

@Component
export struct ExploreTab {
  stack: NavPathStack = new NavPathStack();
  @State categories: QgCategory[] = [];
  @State catIdx: number = 0;
  @State dramas: QgDrama[] = [];
  @State hasMore: boolean = false;
  @State page: number = 1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errMsg: string = '';
  @State refreshing: boolean = false;
  @State heroPressed: boolean = false;
  @State heroFollowed: boolean = false;
  @State sourceName: string = '';
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 0;
  /** 详情页追剧状态变化时刷新焦点卡 */
  @StorageProp('qgFollowTick') @Watch('onFollowTick') followTick: number = 0;
  /** 设置页切换站源后刷新分类与首页 */
  @StorageProp('qgSourceTick') @Watch('onSourceTick') sourceTick: number = 0;

  aboutToAppear(): void {
    this.reloadMeta();
    this.loadFirst();
  }

  onFollowTick(): void {
    this.refreshHeroFollow();
  }

  onSourceTick(): void {
    this.catIdx = 0;
    this.reloadMeta();
    this.loadFirst();
  }

  private reloadMeta(): void {
    this.categories = QgRepository.categories();
    this.sourceName = QgRepository.currentSourceName();
  }

  private currentCategoryId(): string {
    if (this.categories.length === 0) {
      return '';
    }
    const c: QgCategory | undefined = this.categories[this.catIdx];
    return c !== undefined ? c.id : '';
  }

  private heroDrama(): QgDrama | undefined {
    return this.dramas[0];
  }

  private refreshHeroFollow(): void {
    const hero: QgDrama | undefined = this.heroDrama();
    this.heroFollowed = hero !== undefined && QgStore.getInstance().isFollowed(hero.id);
  }

  private loadFirst(): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errMsg = '';
    this.page = 1;
    const catId: string = this.currentCategoryId();
    QgRepository.catalogPage(catId, 1)
      .then((result: QgPageResult) => {
        this.dramas = result.dramas;
        this.hasMore = result.hasMore;
        this.loading = false;
        this.refreshing = false;
        this.refreshHeroFollow();
      })
      .catch((error: BusinessError) => {
        this.dramas = [];
        this.hasMore = false;
        this.loading = false;
        this.refreshing = false;
        this.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  private loadMore(): void {
    if (this.loading || this.loadingMore || !this.hasMore || this.errMsg.length > 0) {
      return;
    }
    this.loadingMore = true;
    const nextPage: number = this.page + 1;
    QgRepository.catalogPage(this.currentCategoryId(), nextPage)
      .then((result: QgPageResult) => {
        this.dramas = this.mergeDramas(this.dramas, result.dramas);
        this.hasMore = result.hasMore;
        this.page = nextPage;
        this.loadingMore = false;
      })
      .catch((error: BusinessError) => {
        this.loadingMore = false;
        this.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  /** 追加去重 */
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

  private selectCategory(idx: number): void {
    if (idx === this.catIdx) {
      return;
    }
    this.catIdx = idx;
    this.loadFirst();
  }

  /** 宫格列数：手机 3 列，宽屏（车机/平板）自适应加密 */
  private gridColumnCount(): number {
    if (this.screenWidth >= 840) {
      return 6;
    }
    if (this.screenWidth >= 600) {
      return 4;
    }
    return 3;
  }

  private gridItemWidth(): string {
    const cols: number = this.gridColumnCount();
    const pct: number = cols === 6 ? 15.4 : (cols === 4 ? 23.4 : 31.8);
    return `${pct}%`;
  }

  private goDetail(id: string): void {
    const p: QgDetailParam = { dramaId: id };
    this.stack.pushPathByName('detail', p);
  }

  private goPlayer(d: QgDrama, episode: number): void {
    const p: QgPlayerParam = { dramaId: d.id, episode: episode };
    this.stack.pushPathByName('player', p);
  }

  /** 继续观看：优先观看记录，否则第 1 集 */
  private resumeEpisode(d: QgDrama): number {
    const rec = QgStore.getInstance().getWatch(d.id);
    if (rec !== undefined && rec.episode <= d.episodeCount) {
      return rec.episode;
    }
    return 1;
  }

  build() {
    Column() {
      this.HeaderBuilder()

      if (this.categories.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.categories, (c: QgCategory, idx: number) => {
              QgChip({
                label: c.label,
                selected: this.catIdx === idx,
                onSelectChip: () => {
                  this.selectCategory(idx);
                }
              })
            }, (c: QgCategory, idx: number) => `${c.id}_${idx}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 4 })
        .width('100%')
      }

      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            if (this.loading) {
              this.LoadingBuilder()
            } else if (this.errMsg.length > 0) {
              this.ErrorBuilder()
            } else if (this.dramas.length === 0) {
              QgEmptyView({
                iconRes: $r('sys.symbol.square_grid_2x2'),
                message: '暂无剧集',
                hint: '下拉刷新试试'
              })
            } else {
              this.ContentBuilder()
            }

            if (!this.loading && this.errMsg.length === 0 && this.dramas.length > 0) {
              if (this.loadingMore) {
                Text('加载中…')
                  .fontSize(12)
                  .fontColor($r('app.color.textFaint'))
                  .padding({ top: 8, bottom: 8 })
              } else if (!this.hasMore) {
                Text('没有更多了')
                  .fontSize(12)
                  .fontColor($r('app.color.textFaint'))
                  .padding({ top: 8, bottom: 8 })
              }
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.TopStart)
        .width('100%')
        .layoutWeight(1)
        .onReachEnd(() => {
          this.loadMore();
        })
      }
      .onRefreshing(() => {
        this.loadFirst();
      })
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  HeaderBuilder() {
    Row() {
      Column() {
        Row({ space: 8 }) {
          Text('青果')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
          Text(this.sourceName)
            .fontSize(11)
            .fontColor($r('app.color.accentOn'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor($r('app.color.accent'))
            .onClick(() => {
              this.stack.pushPathByName('settings', '');
            })
        }
        Text('短剧')
          .fontSize(11)
          .fontColor($r('app.color.textFaint'))
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.selectCategory(0);
      })

      Blank()

      Row({ space: 6 }) {
        Text('搜索剧名、题材')
          .fontSize(13)
          .fontColor($r('app.color.textFaint'))
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(16)
          .fontColor([$r('app.color.textDim')])
      }
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.chipBg'))
      .borderRadius(18)
      .onClick(() => {
        this.stack.pushPathByName('search', '');
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 8 })
  }

  @Builder
  LoadingBuilder() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color($r('app.color.accent'))
      Text('加载中…')
        .fontSize(13)
        .fontColor($r('app.color.textFaint'))
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorBuilder() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.wifi_slash'))
        .fontSize(48)
        .fontColor([$r('app.color.textFaint')])
      Text(this.errMsg)
        .fontSize(13)
        .fontColor($r('app.color.textDim'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Text('重试')
        .fontSize(14)
        .fontColor($r('app.color.accentOn'))
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .borderRadius(18)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          this.loadFirst();
        })
    }
    .width('100%')
    .padding({ top: 64, bottom: 64 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ContentBuilder() {
    Column() {
      if (this.catIdx === 0) {
        this.HeroBuilder(this.dramas[0])
        this.GridSectionBuilder('热播推荐', this.dramas.slice(1))
        this.RankSectionBuilder()
      } else {
        this.GridSectionBuilder(this.gridTitle(), this.dramas)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private gridTitle(): string {
    if (this.categories.length === 0) {
      return '剧集';
    }
    const c: QgCategory | undefined = this.categories[this.catIdx];
    return c !== undefined ? c.label : '剧集';
  }

  /** 热播榜：除焦点卡外按热度取前 5 */
  private rankedList(): QgDrama[] {
    const rest: QgDrama[] = this.dramas.slice(1);
    const sorted: QgDrama[] = rest.slice().sort((a: QgDrama, b: QgDrama): number => b.heat - a.heat);
    return sorted.slice(0, 5);
  }

  @Builder
  HeroBuilder(d: QgDrama) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(qgCoverOf(d.cover))
        .width('100%')
        .aspectRatio(1.6)
        .objectFit(ImageFit.Cover)
        .borderRadius(16)
        .interpolation(ImageInterpolation.Medium)

      Column() {
        Blank()
        Text(d.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        Text(`${d.genre} · ${d.episodeCount}集 · ${d.viewsText}`)
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.85)')
          .margin({ top: 4 })
        Text(d.intro)
          .fontSize(12)
          .fontColor('rgba(255,255,255,0.75)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 14, right: 14, bottom: 12 })
      .linearGradient({
        angle: 180,
        colors: [['rgba(0,0,0,0)', 0.45], ['rgba(0,0,0,0.55)', 1]]
      })

      Row({ space: 10 }) {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(15)
            .fontColor([Color.White])
          Text(this.heroFollowed ? '已追' : '追剧')
            .fontSize(13)
            .fontColor(Color.White)
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor('rgba(255,255,255,0.22)')
        .onClick(() => {
          this.heroFollowed = QgStore.getInstance().toggleFollow(d.id, d.title, d.cover,
            d.episodeCount, d.finished, d.sourceId);
          AppStorage.setOrCreate('qgFollowTick', this.followTick + 1);
        })

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(15)
            .fontColor([$r('app.color.accentOn')])
          Text('立即观看')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accentOn'))
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          this.goPlayer(d, this.resumeEpisode(d));
        })
      }
      .margin(12)
    }
    .width('100%')
    .aspectRatio(1.6)
    .borderRadius(16)
    .clip(true)
    .scale({ x: this.heroPressed ? 0.97 : 1, y: this.heroPressed ? 0.97 : 1 })
    .animation({ duration: 280, curve: curves.springMotion(0.42, 0.72) })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.heroPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.heroPressed = false;
      }
    })
    .onClick(() => {
      this.goDetail(d.id);
    })
    .margin({ top: 12 })
  }

  @Builder
  GridSectionBuilder(title: string, dramas: QgDrama[]) {
    if (dramas.length > 0) {
      Column() {
        QgSectionTitle({ title: title })
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(dramas, (d: QgDrama) => {
            QgDramaCard({
              cover: d.cover,
              cardTitle: d.title,
              subText: d.finished ? `${d.genre} · 已完结` : `更新至${d.episodeCount}集`,
              badge: d.viewsText,
              onTapCard: () => {
                this.goDetail(d.id);
              }
            })
            .width(this.gridItemWidth())
            .margin({ bottom: 14 })
          }, (d: QgDrama) => `grid_${d.id}`)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  RankSectionBuilder() {
    if (this.rankedList().length > 0) {
      Column() {
        QgSectionTitle({
          title: '热播榜',
          actionText: '换一批',
          onAction: () => {
            this.loadMore();
          }
        })
        Column() {
          ForEach(this.rankedList(), (d: QgDrama, idx: number) => {
            this.RankRowBuilder(d, idx)
          }, (d: QgDrama) => `rank_${d.id}`)
        }
        .width('100%')
        .padding(12)
        .borderRadius(16)
        .backgroundColor($r('app.color.surface'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  RankRowBuilder(d: QgDrama, idx: number) {
    Row({ space: 12 }) {
      Text(`${idx + 1}`)
        .fontSize(idx < 3 ? 18 : 15)
        .fontWeight(FontWeight.Bold)
        .fontColor(idx === 0 ? $r('app.color.rankOne') : (idx === 1 ? $r('app.color.rankTwo') :
          (idx === 2 ? $r('app.color.rankThree') : $r('app.color.textFaint'))))
        .width(22)
        .textAlign(TextAlign.Center)

      Image(qgCoverOf(d.cover))
        .width(48)
        .height(64)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .interpolation(ImageInterpolation.Medium)

      Column({ space: 3 }) {
        Text(d.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(d.finished ? '已完结' : `更新至${d.episodeCount}集`)
          .fontSize(11)
          .fontColor($r('app.color.textFaint'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.flame'))
          .fontSize(13)
          .fontColor([$r('app.color.rankOne')])
        Text(`${d.heat}`)
          .fontSize(11)
          .fontColor($r('app.color.textFaint'))
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .borderRadius(12)
    .onClick(() => {
      this.goDetail(d.id);
    })
  }
}
