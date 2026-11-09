/**
 * 搜索页：搜索框 + 搜索历史 + 热门搜索 + 异步结果宫格。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { QgDrama, QgDetailParam, QgPageResult, QgSearchParam } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgBackBtn, QgEmptyView, qgCoverOf } from '../components/QgWidgets';

@Component
struct QgSearchPage {
  private stack: NavPathStack = new NavPathStack();
  @State keyword: string = '';
  @State history: string[] = [];
  @State hotWords: string[] = [];
  @State results: QgDrama[] = [];
  @State searched: boolean = false;
  @State searching: boolean = false;
  @State errMsg: string = '';
  @StorageProp('safeTop') safeTop: number = 0;

  aboutToAppear(): void {
    this.history = QgStore.getInstance().getSearchHistory();
    this.loadHotWords();
  }

  private loadHotWords(): void {
    QgRepository.hotKeywords()
      .then((words: string[]) => {
        this.hotWords = words;
      })
      .catch((error: BusinessError) => {
        this.hotWords = [];
      });
  }

  private doSearch(word: string): void {
    const kw: string = word.trim();
    this.keyword = kw;
    if (kw.length === 0) {
      this.results = [];
      this.searched = false;
      this.searching = false;
      this.errMsg = '';
      return;
    }
    if (this.searching) {
      return;
    }
    this.searching = true;
    this.errMsg = '';
    QgRepository.search(kw, 1)
      .then((result: QgPageResult) => {
        this.results = result.dramas;
        this.searched = true;
        this.searching = false;
        QgStore.getInstance().pushSearchHistory(kw);
        this.history = QgStore.getInstance().getSearchHistory();
      })
      .catch((error: BusinessError) => {
        this.results = [];
        this.searched = true;
        this.searching = false;
        this.errMsg = error.message !== undefined && error.message.length > 0 ? error.message : '搜索失败，请重试';
      });
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
          Search({ value: this.keyword, placeholder: '搜索剧名、题材、标签' })
            .searchButton('搜索')
            .searchIcon({ color: $r('app.color.textFaint') })
            .placeholderColor($r('app.color.textFaint'))
            .fontColor($r('app.color.text'))
            .backgroundColor($r('app.color.chipBg'))
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.keyword = value;
            })
            .onSubmit((value: string) => {
              this.doSearch(value);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 8 })

        if (!this.searched) {
          this.SuggestBuilder()
        } else {
          this.ResultBuilder()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const p = ctx.pathInfo.param as QgSearchParam;
      if (p !== undefined && p !== null && typeof p.keyword === 'string' && p.keyword.length > 0) {
        this.doSearch(p.keyword);
      }
    })
  }

  @Builder
  SuggestBuilder() {
    Scroll() {
      Column() {
        // 搜索历史
        if (this.history.length > 0) {
          Row() {
            Text('搜索历史')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text'))
            Blank()
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(16)
              .fontColor([$r('app.color.textFaint')])
              .onClick(() => {
                QgStore.getInstance().clearSearchHistory();
                this.history = [];
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 10 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.history, (k: string) => {
              Text(k)
                .fontSize(13)
                .fontColor($r('app.color.textDim'))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor($r('app.color.chipBg'))
                .borderRadius(16)
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.doSearch(k);
                })
            }, (k: string) => `history_${k}`)
          }
          .width('100%')
        }

        // 热门搜索
        if (this.hotWords.length > 0) {
          Text('热门搜索')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .padding({ top: 16, bottom: 10 })

          Column() {
            ForEach(this.hotWords, (k: string, idx: number) => {
              Row({ space: 12 }) {
                Text(`${idx + 1}`)
                  .fontSize(idx < 3 ? 16 : 14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(idx === 0 ? $r('app.color.rankOne') : (idx === 1 ? $r('app.color.rankTwo') :
                    (idx === 2 ? $r('app.color.rankThree') : $r('app.color.textFaint'))))
                  .width(20)
                  .textAlign(TextAlign.Center)
                Text(k)
                  .fontSize(14)
                  .fontColor($r('app.color.text'))
                  .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.flame'))
                  .fontSize(13)
                  .fontColor([$r('app.color.rankOne')])
                  .visibility(idx < 3 ? Visibility.Visible : Visibility.None)
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                this.doSearch(k);
              })
            }, (k: string, idx: number) => `hot_${idx}_${k}`)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .borderRadius(14)
          .backgroundColor($r('app.color.surface'))
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  ResultBuilder() {
    Scroll() {
      Column() {
        if (this.searching) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.accent'))
            Text('搜索中…')
              .fontSize(13)
              .fontColor($r('app.color.textFaint'))
          }
          .width('100%')
          .padding({ top: 72, bottom: 72 })
          .justifyContent(FlexAlign.Center)
        } else if (this.errMsg.length > 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.wifi_slash'))
              .fontSize(44)
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
                this.doSearch(this.keyword);
              })
          }
          .width('100%')
          .padding({ top: 56, bottom: 56 })
          .justifyContent(FlexAlign.Center)
        } else if (this.results.length === 0) {
          QgEmptyView({
            iconRes: $r('sys.symbol.magnifyingglass'),
            message: `没有找到「${this.keyword}」相关的剧`,
            hint: '换个关键词试试'
          })
        } else {
          Text(`共 ${this.results.length} 部结果`)
            .fontSize(13)
            .fontColor($r('app.color.textFaint'))
            .width('100%')
            .padding({ top: 8, bottom: 4 })
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
            ForEach(this.results, (d: QgDrama) => {
              Column() {
                Image(qgCoverOf(d.cover))
                  .width('100%')
                  .aspectRatio(0.75)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(12)
                  .interpolation(ImageInterpolation.Medium)
                Text(d.title)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 6 })
                Text(d.genre)
                  .fontSize(11)
                  .fontColor($r('app.color.textFaint'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .width('31.8%')
              .margin({ bottom: 14 })
              .onClick(() => {
                const p: QgDetailParam = { dramaId: d.id };
                this.stack.pushPathByName('detail', p);
              })
            }, (d: QgDrama) => `result_${d.id}`)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .layoutWeight(1)
  }
}

@Builder
export function QgSearchBuilder() {
  QgSearchPage()
}
