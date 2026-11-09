/**
 * 观看记录页：按时间倒序的观看历史，支持单个删除与清空。
 * 直接展示观看记录快照（标题/封面），跨站源可用。
 */
import { QgPlayerParam, QgWatchRecord } from '../model/QgModels';
import { QgStore } from '../data/QgStore';
import { QgBackBtn, QgEmptyView, qgCoverOf } from '../components/QgWidgets';

/** 相对时间文案 */
function relativeTime(ts: number): string {
  const diff: number = Date.now() - ts;
  const minute: number = 60 * 1000;
  const hour: number = 60 * minute;
  const day: number = 24 * hour;
  if (diff < minute) {
    return '刚刚';
  }
  if (diff < hour) {
    return `${Math.floor(diff / minute)}分钟前`;
  }
  if (diff < day) {
    return `${Math.floor(diff / hour)}小时前`;
  }
  if (diff < 30 * day) {
    return `${Math.floor(diff / day)}天前`;
  }
  return '更早';
}

@Component
struct QgHistoryPage {
  private stack: NavPathStack = new NavPathStack();
  @State items: QgWatchRecord[] = [];
  @StorageProp('safeTop') safeTop: number = 0;

  reload(): void {
    this.items = QgStore.getInstance().getWatchList();
  }

  private clearAll(): void {
    QgStore.getInstance().clearWatch();
    AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
    this.reload();
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 10 }) {
          QgBackBtn({
            onBack: () => {
              this.stack.pop();
            }
          })
          Text('观看记录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .layoutWeight(1)
          if (this.items.length > 0) {
            Text('清空')
              .fontSize(13)
              .fontColor($r('app.color.textDim'))
              .onClick(() => {
                this.confirmClear();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 8 })

        if (this.items.length === 0) {
          Column() {
            QgEmptyView({
              iconRes: $r('sys.symbol.clock'),
              message: '暂无观看记录',
              hint: '看过的剧会出现在这里'
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 12 }) {
            ForEach(this.items, (item: QgWatchRecord) => {
              ListItem() {
                this.RowBuilder(item)
              }
            }, (item: QgWatchRecord) => `history_${item.dramaId}_${item.updatedAt}`)
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, bottom: 24 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.reload();
    })
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      this.reload();
    })
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
        fontColor: $r('app.color.accent'),
        action: () => {
          this.clearAll();
        }
      }
    });
  }

  @Builder
  RowBuilder(item: QgWatchRecord) {
    Row({ space: 12 }) {
      Image(qgCoverOf(item.cover))
        .width(76)
        .height(100)
        .objectFit(ImageFit.Cover)
        .borderRadius(10)
        .interpolation(ImageInterpolation.Medium)

      Column({ space: 5 }) {
        Text(item.title.length > 0 ? item.title : '未知剧集')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`看到第${item.episode}集`)
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
        if (item.duration > 0) {
          Progress({
            value: item.progress,
            total: item.duration
          })
            .style({ strokeWidth: 4 })
            .color($r('app.color.accent'))
            .backgroundColor($r('app.color.chipBg'))
            .borderRadius(2)
            .height(4)
            .width('100%')
        }
        Blank()
        Text(relativeTime(item.updatedAt))
          .fontSize(11)
          .fontColor($r('app.color.textFaint'))
      }
      .alignItems(HorizontalAlign.Start)
      .height(100)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(17)
        .fontColor([$r('app.color.textFaint')])
        .padding(6)
        .onClick(() => {
          QgStore.getInstance().removeWatch(item.dramaId);
          AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
          this.reload();
        })
    }
    .width('100%')
    .padding(10)
    .borderRadius(14)
    .backgroundColor($r('app.color.surface'))
    .alignItems(VerticalAlign.Center)
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
