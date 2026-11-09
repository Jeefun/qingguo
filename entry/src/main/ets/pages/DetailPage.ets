/**
 * 详情页：毛玻璃封面 + 剧集信息 + 选集 + 追剧 + 立即观看。
 * 详情与分集来自站源异步接口（QgRepository.detail）。
 */
import { curves } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { QgDrama, QgDramaDetail, QgDetailParam, QgEpisode, QgPlayerParam } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgBackBtn, qgCoverOf } from '../components/QgWidgets';

@Component
struct QgDetailPage {
  private stack: NavPathStack = new NavPathStack();
  @State drama: QgDrama | undefined = undefined;
  @State episodes: QgEpisode[] = [];
  @State followed: boolean = false;
  @State introExpanded: boolean = false;
  @State currentEp: number = 1;
  @State watchEp: number = 0;
  @State loading: boolean = true;
  @State errMsg: string = '';
  @StorageProp('safeTop') safeTop: number = 0;

  private getD(): QgDrama {
    return this.drama as QgDrama;
  }

  private goPlayer(episode: number): void {
    const d = this.getD();
    const p: QgPlayerParam = { dramaId: d.id, episode: episode };
    this.stack.pushPathByName('player', p);
  }

  private toggleFollow(): void {
    const d = this.getD();
    this.followed = QgStore.getInstance().toggleFollow(d.id, d.title, d.cover,
      d.episodeCount, d.finished, d.sourceId);
    AppStorage.setOrCreate('qgFollowTick', (AppStorage.get<number>('qgFollowTick') ?? 0) + 1);
  }

  private load(dramaId: string): void {
    this.loading = true;
    this.errMsg = '';
    QgRepository.detail(dramaId)
      .then((detail: QgDramaDetail) => {
        this.drama = detail.drama;
        this.episodes = detail.episodes;
        this.loading = false;
        this.followed = QgStore.getInstance().isFollowed(detail.drama.id);
        const rec = QgStore.getInstance().getWatch(detail.drama.id);
        const total: number = detail.episodes.length > 0 ? detail.episodes.length : detail.drama.episodeCount;
        if (rec !== undefined && rec.episode <= total) {
          this.watchEp = rec.episode;
          this.currentEp = rec.episode;
        } else {
          this.watchEp = 0;
          this.currentEp = 1;
        }
      })
      .catch((error: BusinessError) => {
        this.loading = false;
        this.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  build() {
    NavDestination() {
      if (this.loading) {
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
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errMsg.length > 0) {
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
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        this.ContentBuilder()
      }
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg'))
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
    Stack() {
      // 背景毛玻璃封面 + 半透明遮罩
      Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(40)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.detailScrim'))

      Scroll() {
        Column() {
          this.TopBarBuilder()
          this.InfoCardBuilder()
          this.ActionBuilder()
          this.EpisodeBuilder()
          this.SimilarBuilder()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TopBarBuilder() {
    Row() {
      QgBackBtn({
        onBack: () => {
          this.stack.pop();
        }
      })
      Blank()
      Text('详情')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
      Blank()
      Row()
        .width(36)
    }
    .width('100%')
    .padding({ top: this.safeTop + 6, bottom: 10 })
  }

  @Builder
  InfoCardBuilder() {
    Row({ space: 14 }) {
      Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
        .width(112)
        .aspectRatio(0.75)
        .objectFit(ImageFit.Cover)
        .borderRadius(12)
        .interpolation(ImageInterpolation.Medium)
        .shadow({ radius: 12, color: 'rgba(0,0,0,0.3)', offsetY: 4 })

      Column({ space: 6 }) {
        Text(this.getD().title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (this.getD().genre.length > 0) {
            Text(this.getD().genre)
              .fontSize(11)
              .fontColor($r('app.color.accentOn'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor($r('app.color.accent'))
          }
          ForEach(this.getD().tags, (t: string) => {
            Text(t)
              .fontSize(11)
              .fontColor($r('app.color.textDim'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor($r('app.color.chipBg'))
          }, (t: string) => `tag_${t}`)
        }
        Text(this.getD().finished ? `已完结 · 共${this.episodeTotal()}集` :
          `连载中 · 更新至${this.episodeTotal()}集`)
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
        if (this.getD().viewsText.length > 0) {
          Text(`${this.getD().viewsText}播放`)
            .fontSize(12)
            .fontColor($r('app.color.textFaint'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  ActionBuilder() {
    Column({ space: 8 }) {
      Text(this.getD().intro)
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.textDim'))
        .maxLines(this.introExpanded ? 10 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.getD().intro.length > 0) {
        Text(this.introExpanded ? '收起' : '展开')
          .fontSize(12)
          .fontColor($r('app.color.accent'))
          .padding({ top: 2, bottom: 2 })
          .onClick(() => {
            this.introExpanded = !this.introExpanded;
          })
      }

      Row({ space: 12 }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.followed ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(17)
            .fontColor([this.followed ? $r('app.color.accent') : $r('app.color.textDim')])
          Text(this.followed ? '已追剧' : '追剧')
            .fontSize(14)
            .fontColor(this.followed ? $r('app.color.accent') : $r('app.color.textDim'))
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .borderRadius(22)
        .backgroundColor($r('app.color.chipBg'))
        .scale({ x: this.followed ? 1.03 : 1, y: this.followed ? 1.03 : 1 })
        .animation({ duration: 300, curve: curves.springMotion(0.4, 0.6) })
        .onClick(() => {
          this.toggleFollow();
        })

        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(16)
            .fontColor([$r('app.color.accentOn')])
          Text(this.watchEp > 0 ? `继续看第${this.watchEp}集` : '立即观看')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accentOn'))
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1.6)
        .padding({ top: 12, bottom: 12 })
        .borderRadius(22)
        .backgroundColor($r('app.color.accent'))
        .onClick(() => {
          this.goPlayer(this.currentEp);
        })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  EpisodeBuilder() {
    if (this.episodes.length > 0) {
      Column() {
        Row() {
          Text('选集')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
          Blank()
          Text(`共${this.episodeTotal()}集`)
            .fontSize(12)
            .fontColor($r('app.color.textFaint'))
        }
        .width('100%')
        .padding({ top: 16, bottom: 10 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.episodes, (ep: QgEpisode) => {
            Text(ep.title.length > 0 ? ep.title : `${ep.order}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(ep.order === this.currentEp ? $r('app.color.accentOn') : $r('app.color.textDim'))
              .textAlign(TextAlign.Center)
              .minFontScale(0.8)
              .maxFontScale(1.0)
              .height(34)
              .constraintSize({ minWidth: 40 })
              .padding({ left: 8, right: 8 })
              .borderRadius(10)
              .backgroundColor(ep.order === this.currentEp ? $r('app.color.accent') : $r('app.color.chipBg'))
              .margin({ right: 8, bottom: 8 })
              .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
              .onClick(() => {
                this.goPlayer(ep.order);
              })
          }, (ep: QgEpisode) => `ep_${ep.id}_${ep.order}`)
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .margin({ top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 分集总数：优先分集列表，否则剧集元数据 */
  private episodeTotal(): number {
    if (this.episodes.length > 0) {
      return this.episodes.length;
    }
    return this.getD().episodeCount;
  }

  @Builder
  SimilarBuilder() {
    if (this.similarList().length > 0) {
      Column() {
        Text('猜你喜欢')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
          .padding({ top: 16, bottom: 10 })
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.similarList(), (d: QgDrama) => {
              Column() {
                Image(qgCoverOf(d.cover, d.sourceId))
                  .width(96)
                  .aspectRatio(0.75)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                  .interpolation(ImageInterpolation.Medium)
                Text(d.title)
                  .fontSize(12)
                  .fontColor($r('app.color.textDim'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 4 })
                  .width(96)
              }
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
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .margin({ top: 12 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 猜你喜欢：当前源最近第 1 页目录中排除本剧 */
  private similarList(): QgDrama[] {
    const d = this.getD();
    const cached: QgDrama[] = QgRepository.cachedFirstPage();
    return cached.filter((x: QgDrama): boolean => x.id !== d.id).slice(0, 8);
  }
}

@Builder
export function QgDetailBuilder() {
  QgDetailPage()
}
