/**
 * 追剧页：我的追剧列表。
 * 直接展示追剧记录快照（标题/封面/集数），跨站源可用；
 * 继续观看读取观看记录，无记录则从第 1 集开始。
 */
import { QgDetailParam, QgFollowRecord, QgPlayerParam } from '../model/QgModels';
import { QgStore } from '../data/QgStore';
import { QgEmptyView, qgCoverOf } from '../components/QgWidgets';

@Component
export struct FollowTab {
  stack: NavPathStack = new NavPathStack();
  @State follows: QgFollowRecord[] = [];
  @StorageProp('safeTop') safeTop: number = 0;
  /** 详情页追剧状态变化时刷新 */
  @StorageProp('qgFollowTick') @Watch('onFollowTick') followTick: number = 0;
  @StorageProp('qgWatchTick') @Watch('onFollowTick') watchTick: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onFollowTick(): void {
    this.reload();
  }

  reload(): void {
    this.follows = QgStore.getInstance().getFollowList();
  }

  private goDetail(id: string): void {
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

  build() {
    Column() {
      Text('我的追剧')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .width('100%')
        .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 8 })

      if (this.follows.length === 0) {
        Column() {
          QgEmptyView({
            iconRes: $r('sys.symbol.heart'),
            message: '还没有追的剧',
            hint: '去发现页把喜欢的剧加入追剧吧'
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.follows, (rec: QgFollowRecord) => {
              this.FollowRowBuilder(rec)
            }, (rec: QgFollowRecord) => `follow_${rec.dramaId}_${rec.addedAt}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  FollowRowBuilder(rec: QgFollowRecord) {
    Row({ space: 12 }) {
      Image(qgCoverOf(rec.cover, rec.sourceId))
        .width(72)
        .height(96)
        .objectFit(ImageFit.Cover)
        .borderRadius(10)
        .interpolation(ImageInterpolation.Medium)

      Column({ space: 5 }) {
        Text(rec.title.length > 0 ? rec.title : '未知剧集')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(rec.finished ? `已完结 · 共${rec.episodeCount}集` : `更新至${rec.episodeCount}集`)
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(12)
            .fontColor([$r('app.color.accentOn')])
          Text(`第${this.continueEpisode(rec)}集`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accentOn'))
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          const p: QgPlayerParam = { dramaId: rec.dramaId, episode: this.continueEpisode(rec) };
          this.stack.pushPathByName('player', p);
        })
      }
      .alignItems(HorizontalAlign.Start)
      .height(96)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .borderRadius(14)
    .backgroundColor($r('app.color.surface'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.goDetail(rec.dramaId);
    })
  }
}
