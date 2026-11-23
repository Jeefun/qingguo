import { QgTheme } from '../components/QgTheme';
/**
 * 片单页（追剧 / 待看队列）—— 「夜幕 · 青柠」。
 *
 * - 顶部大标题 + 数量徽章 + QgSegmented 分段切换；
 * - 双列（大屏 3~4 列）海报卡：左上角玻璃集数角标、青柠进度条、全圆胶囊操作钮；
 * - 保留全部跨源追剧、待看队列管理与继续观看功能。
 */
import { QgDetailParam, QgFollowRecord, QgPlayerParam, QgQueueRecord } from '../model/QgModels';
import { QgStore } from '../data/QgStore';
import { QgEmptyView, QgSegmented, QgUi, qgCoverOf } from '../components/QgWidgets';

@Component
export struct FollowTab {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  stack: NavPathStack = new NavPathStack();
  @State follows: QgFollowRecord[] = [];
  @State queue: QgQueueRecord[] = [];
  @State queueMode: boolean = false;
  @StorageProp('screenWidth') screenWidth: number = 0;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('qgFollowTick') @Watch('onFollowTick') followTick: number = 0;
  @StorageProp('qgWatchTick') @Watch('onFollowTick') watchTick: number = 0;
  @StorageProp('qgQueueTick') @Watch('onFollowTick') queueTick: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onFollowTick(): void {
    this.reload();
  }

  reload(): void {
    this.follows = QgStore.getInstance().getFollowList();
    this.queue = QgStore.getInstance().getQueueList();
  }

  private visibleRecords(): QgFollowRecord[] {
    if (!this.queueMode) {
      return this.follows;
    }
    return this.queue.map((item: QgQueueRecord): QgFollowRecord => {
      const r: QgFollowRecord = new QgFollowRecord();
      r.dramaId = item.dramaId;
      r.addedAt = item.addedAt;
      r.title = item.title;
      r.cover = item.cover;
      r.episodeCount = item.episodeCount;
      r.finished = item.finished;
      r.sourceId = item.sourceId;
      return r;
    });
  }

  private goDetail(id: string): void {
    if (QgStore.getInstance().getSettings().directPlay) {
      const watch = QgStore.getInstance().getWatch(id);
      const p: QgPlayerParam = { dramaId: id, episode: watch !== undefined && watch.episode >= 1 ? watch.episode : 1 };
      this.stack.pushPathByName('player', p);
      return;
    }
    const p: QgDetailParam = { dramaId: id };
    this.stack.pushPathByName('detail', p);
  }

  private continueEpisode(rec: QgFollowRecord): number {
    const watch = QgStore.getInstance().getWatch(rec.dramaId);
    if (watch !== undefined && watch.episode <= rec.episodeCount) {
      return watch.episode;
    }
    return 1;
  }

  private followProgress(rec: QgFollowRecord): number {
    if (rec.episodeCount <= 0) {
      return 0;
    }
    const watch = QgStore.getInstance().getWatch(rec.dramaId);
    if (watch === undefined) {
      return 0;
    }
    return Math.min(100, Math.round(watch.episode * 100 / rec.episodeCount));
  }

  private watchLabel(rec: QgFollowRecord): string {
    const watch = QgStore.getInstance().getWatch(rec.dramaId);
    return watch === undefined ? '尚未开始' : `第 ${watch.episode} 集`;
  }

  private cardWidth(): string {
    if (this.screenWidth >= 840) {
      return '23.5%';
    }
    if (this.screenWidth >= 600) {
      return '31.5%';
    }
    return '48%';
  }

  build() {
    Column() {
      // 顶部标题区
      Row() {
        Column({ space: 4 }) {
          Text('WATCHLIST')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(2.4)
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
          Text('我的片单')
            .fontSize(30)
            .fontWeight(FontWeight.Bolder)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        if (this.visibleRecords().length > 0) {
          Text(`${this.visibleRecords().length} 部`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
        }
      }
      .width('100%')
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: this.safeTop + 16, bottom: 16 })

      // 分段切换
      Column() {
        QgSegmented({
          options: [`正在追 · ${this.follows.length}`, `待看队列 · ${this.queue.length}`],
          selectedIndex: this.queueMode ? 1 : 0,
          onSelect: (idx: number) => {
            this.queueMode = idx === 1;
          }
        })
      }
      .width('100%')
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: 10 })

      if (this.visibleRecords().length === 0) {
        Column() {
          QgEmptyView({
            iconRes: this.queueMode ? $r('sys.symbol.bookmark') : $r('sys.symbol.heart'),
            message: this.queueMode ? '待看队列还是空的' : '片单还是空的',
            hint: this.queueMode ? '把想看的短剧先收好，之后再慢慢挑' : '收藏喜欢的短剧，随时接着看',
            actionText: '去发现短剧',
            onAction: () => this.stack.pushPathByName('search', '')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: this.safeBottom + 70 })
      } else {
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
            ForEach(this.visibleRecords(), (rec: QgFollowRecord) => {
              this.FollowCardBuilder(rec)
            }, (rec: QgFollowRecord) => `${this.queueMode ? 'queue' : 'follow'}_${rec.dramaId}_${rec.addedAt}`)
          }
          .width('100%')
          .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: 14, bottom: this.safeBottom + QgUi.TAB_BAR_SPACE })
        }
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
          if (yOffset > 1.2) {
            AppStorage.setOrCreate('qgTabBarVisible', false);
          } else if (yOffset < -1.2) {
            AppStorage.setOrCreate('qgTabBarVisible', true);
          }
        })
        .onScrollStop(() => {
          AppStorage.setOrCreate('qgTabBarVisible', true);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
  }

  @Builder
  FollowCardBuilder(rec: QgFollowRecord) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(qgCoverOf(rec.cover, rec.sourceId))
          .width('100%')
          .aspectRatio(0.72)
          .objectFit(ImageFit.Cover)
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .borderRadius(QgUi.R_POSTER)

        // 底部渐变 + 进度条
        Column()
          .width('100%')
          .height(64)
          .borderRadius({ bottomLeft: QgUi.R_POSTER, bottomRight: QgUi.R_POSTER })
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#00000000', 0], ['#B3000000', 1]]
          })

        Column({ space: 6 }) {
          Text(this.watchLabel(rec))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor('#66000000')
            .backdropBlur(12)
          Progress({ value: this.followProgress(rec), total: 100 })
            .color(QgTheme.color('accent', this.themeId, this.darkOn))
            .backgroundColor('#4DFFFFFF')
            .height(3)
            .width('100%')
        }
        .width('100%')
        .padding(10)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .clip(true)
      .borderRadius(QgUi.R_POSTER)
      .onClick(() => this.goDetail(rec.dramaId))

      Text(rec.title.length > 0 ? rec.title : '未知剧集')
        .fontSize(15)
        .lineHeight(20)
        .constraintSize({ minHeight: 40 })
        .fontWeight(FontWeight.Bold)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => this.goDetail(rec.dramaId))

      Text(`${rec.finished ? '已完结' : '更新中'} · 共 ${rec.episodeCount} 集`)
        .fontSize(11)
        .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))

      Row({ space: 6 }) {
        if (!this.queueMode) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(13)
            .fontColor([QgTheme.color('accentOn', this.themeId, this.darkOn)])
        }
        Text(this.queueMode ? '移出待看' : '继续观看')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.queueMode ? QgTheme.color('text', this.themeId, this.darkOn) : QgTheme.color('accentOn', this.themeId, this.darkOn))
      }
      .width('100%')
      .height(40)
      .borderRadius(20)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.queueMode ? QgTheme.color('surfaceHigh', this.themeId, this.darkOn) : QgTheme.color('accent', this.themeId, this.darkOn))
      .border({ width: this.queueMode ? 1 : 0, color: QgTheme.color('border', this.themeId, this.darkOn) })
      .onClick(() => {
        if (this.queueMode) {
          QgStore.getInstance().removeQueue(rec.dramaId);
          this.queue = QgStore.getInstance().getQueueList();
          AppStorage.setOrCreate('qgQueueTick', this.queueTick + 1);
        } else {
          const p: QgPlayerParam = { dramaId: rec.dramaId, episode: this.continueEpisode(rec) };
          this.stack.pushPathByName('player', p);
        }
      })
    }
    .width(this.cardWidth())
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }
}
