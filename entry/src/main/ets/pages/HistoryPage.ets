import { QgTheme } from '../components/QgTheme';
/**
 * 观看记录页 —— 「夜幕 · 青柠」。
 *
 * - 按今天 / 昨天 / 更早分组展示真实观看记录；
 * - 每行 24 圆角卡片，含海报、青柠进度条、集数与相对时间、单条删除与一键清空确认。
 */
import { QgPlayerParam, QgWatchRecord } from '../model/QgModels';
import { QgStore } from '../data/QgStore';
import { QgEmptyView, QgIconBtn, QgTopBar, QgUi, qgCoverOfDramaId } from '../components/QgWidgets';

function relativeTime(ts: number): string {
  const diff: number = Date.now() - ts;
  const minute: number = 60 * 1000;
  const hour: number = 60 * minute;
  const day: number = 24 * hour;
  if (diff < minute) {
    return '刚刚';
  }
  if (diff < hour) {
    return `${Math.floor(diff / minute)} 分钟前`;
  }
  if (diff < day) {
    return `${Math.floor(diff / hour)} 小时前`;
  }
  if (diff < 30 * day) {
    return `${Math.floor(diff / day)} 天前`;
  }
  return '更早';
}

interface HistoryGroup {
  label: string;
  items: QgWatchRecord[];
}

@Component
struct QgHistoryPage {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  private stack: NavPathStack = new NavPathStack();
  @State items: QgWatchRecord[] = [];
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;

  reload(): void {
    this.items = QgStore.getInstance().getWatchList();
  }

  private clearAll(): void {
    QgStore.getInstance().clearWatch();
    AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
    this.reload();
  }

  private groupedItems(): HistoryGroup[] {
    const now: Date = new Date();
    const todayStart: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const yesterdayStart: number = todayStart - 24 * 60 * 60 * 1000;
    const today: QgWatchRecord[] = [];
    const yesterday: QgWatchRecord[] = [];
    const earlier: QgWatchRecord[] = [];

    for (let i: number = 0; i < this.items.length; i++) {
      const r: QgWatchRecord = this.items[i];
      if (r.updatedAt >= todayStart) {
        today.push(r);
      } else if (r.updatedAt >= yesterdayStart) {
        yesterday.push(r);
      } else {
        earlier.push(r);
      }
    }

    const out: HistoryGroup[] = [];
    if (today.length > 0) {
      out.push({ label: '今天', items: today });
    }
    if (yesterday.length > 0) {
      out.push({ label: '昨天', items: yesterday });
    }
    if (earlier.length > 0) {
      out.push({ label: '更早', items: earlier });
    }
    return out;
  }

  private watchPct(item: QgWatchRecord): number {
    if (item.duration <= 0) {
      return 0;
    }
    const pct: number = Math.round(item.progress * 100 / item.duration);
    return pct > 100 ? 100 : (pct < 2 ? 2 : pct);
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空观看记录',
      message: '确定要清空全部观看记录吗？',
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: QgTheme.color('danger', this.themeId, this.darkOn),
        action: () => {
          this.clearAll();
        }
      }
    });
  }

  build() {
    NavDestination() {
      Column() {
        QgTopBar({
          title: '',
          safeTop: this.safeTop,
          onBack: () => this.stack.pop(),
          trailing: () => {
            this.ClearBtnBuilder();
          }
        })

        Row() {
          Column({ space: 4 }) {
            Text('HISTORY')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(2.4)
              .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            Text('观看记录')
              .fontSize(30)
              .fontWeight(FontWeight.Bolder)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          if (this.items.length > 0) {
            Text(`${this.items.length} 部`)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
          }
        }
        .width('100%')
        .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: 4, bottom: 16 })

        if (this.items.length === 0) {
          Column() {
            QgEmptyView({
              iconRes: $r('sys.symbol.clock'),
              message: '暂无观看记录',
              hint: '看过的短剧与集数进度会出现在这里'
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 20 }) {
              ForEach(this.groupedItems(), (group: HistoryGroup) => {
                Column({ space: 10 }) {
                  Text(group.label)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
                    .padding({ left: 4 })

                  Column({ space: 10 }) {
                    ForEach(group.items, (item: QgWatchRecord) => {
                      this.RowBuilder(item)
                    }, (item: QgWatchRecord) => `history_${item.dramaId}_${item.updatedAt}`)
                  }
                  .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (group: HistoryGroup) => `hgroup_${group.label}`)
            }
            .width('100%')
            .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + 40 })
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .onShown(() => {
      this.reload();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      this.reload();
    })
  }

  @Builder
  ClearBtnBuilder() {
    if (this.items.length > 0) {
      QgIconBtn({
        icon: $r('sys.symbol.trash'),
        label: '清空观看记录',
        solid: true,
        onTap: () => this.confirmClear()
      })
    }
  }

  @Builder
  RowBuilder(item: QgWatchRecord) {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(qgCoverOfDramaId(item.cover, item.dramaId))
          .width(82)
          .height(110)
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
        if (item.duration > 0) {
          Row()
            .width(`${this.watchPct(item)}%`)
            .height(3)
            .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
        }
      }
      .width(82)
      .height(110)
      .borderRadius(14)
      .clip(true)

      Column({ space: 6 }) {
        Text(item.title.length > 0 ? item.title : '未知剧集')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`看到第 ${item.episode} 集${item.duration > 0 ? ' · ' + this.watchPct(item) + '%' : ''}`)
          .fontSize(12)
          .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
          .fontWeight(FontWeight.Medium)
        Text(relativeTime(item.updatedAt))
          .fontSize(11)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(14)
            .fontColor([QgTheme.color('accentOn', this.themeId, this.darkOn)])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))

        Stack() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(15)
            .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
        .accessibilityText('删除这条观看记录')
        .onClick(() => {
          QgStore.getInstance().removeWatch(item.dramaId);
          AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
          this.reload();
        })
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(QgUi.R_CARD)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    .onClick(() => {
      const p: QgPlayerParam = { dramaId: item.dramaId, episode: item.episode };
      this.stack.pushPathByName('player', p);
    })
  }
}

@Builder
export function QgHistoryBuilder() {
  QgHistoryPage()
}
