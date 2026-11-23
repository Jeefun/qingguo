import { QgTheme } from '../components/QgTheme';
/**
 * 搜索页 —— 「夜幕 · 青柠」。
 *
 * - 顶部返回钮 + 大号 24 圆角胶囊搜索框（surface 底、青柠搜索按钮）；
 * - 建议区：搜索历史胶囊流 + 巨型序号热门搜索卡片；
 * - 结果区：错落双列瀑布流（QgDramaCard），保留全部异步搜索与状态反馈。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { QgDrama, QgDetailParam, QgPageResult, QgPlayerParam, QgSearchParam } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgBackBtn, QgDramaCard, QgEmptyView, QgPrimaryButton, QgUi } from '../components/QgWidgets';

@Component
struct QgSearchPage {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  private stack: NavPathStack = new NavPathStack();
  @State keyword: string = '';
  @State history: string[] = [];
  @State hotWords: string[] = [];
  @State results: QgDrama[] = [];
  @State searched: boolean = false;
  @State searching: boolean = false;
  @State errMsg: string = '';
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 0;

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

  private colCount(): number {
    if (this.screenWidth >= 840) {
      return 4;
    }
    if (this.screenWidth >= 600) {
      return 3;
    }
    return 2;
  }

  private colIndices(): number[] {
    const out: number[] = [];
    for (let i: number = 0; i < this.colCount(); i++) {
      out.push(i);
    }
    return out;
  }

  private colResults(colIdx: number): QgDrama[] {
    const n: number = this.colCount();
    const out: QgDrama[] = [];
    for (let i: number = colIdx; i < this.results.length; i += n) {
      out.push(this.results[i]);
    }
    return out;
  }

  private cardRatio(colIdx: number, rowIdx: number): number {
    const p: number[] = [0.68, 0.78, 0.72, 0.66];
    return p[(colIdx + rowIdx) % p.length];
  }

  build() {
    NavDestination() {
      Column() {
        // 顶部返回 + 胶囊搜索框
        Row({ space: 10 }) {
          QgBackBtn({ solid: true, onBack: () => this.stack.pop() })
          Search({ value: this.keyword, placeholder: '搜索剧名、题材、标签…' })
            .searchButton('搜索', { fontColor: QgTheme.color('accentInk', this.themeId, this.darkOn) })
            .searchIcon({ color: QgTheme.color('textFaint', this.themeId, this.darkOn) })
            .placeholderColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
            .border({ width: 1, color: QgTheme.color('border', this.themeId, this.darkOn) })
            .borderRadius(24)
            .height(48)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.keyword = value;
              if (value.trim().length === 0 && this.searched) {
                this.searched = false;
                this.results = [];
                this.errMsg = '';
              }
            })
            .onSubmit((value: string) => {
              this.doSearch(value);
            })
        }
        .width('100%')
        .padding({ left: 16, right: QgUi.GUTTER, top: this.safeTop + 10, bottom: 16 })

        if (!this.searched && !this.searching) {
          this.SuggestBuilder()
        } else {
          this.ResultBuilder()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
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
        if (this.history.length > 0) {
          Row() {
            Column({ space: 3 }) {
              Text('RECENT')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .letterSpacing(2.2)
                .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
              Text('搜索历史')
                .fontSize(18)
                .fontWeight(FontWeight.Bolder)
                .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.trash')).fontSize(14).fontColor([QgTheme.color('textDim', this.themeId, this.darkOn)])
              Text('清空').fontSize(12).fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
            }
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
            .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
            .onClick(() => {
              QgStore.getInstance().clearSearchHistory();
              this.history = [];
            })
          }
          .width('100%')
          .padding({ top: 8, bottom: 14 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.history, (k: string) => {
              Text(k)
                .fontSize(13)
                .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
                .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
                .borderRadius(18)
                .margin({ right: 8, bottom: 8 })
                .onClick(() => this.doSearch(k))
            }, (k: string) => `history_${k}`)
          }
          .width('100%')
          .margin({ bottom: 20 })
        }

        if (this.hotWords.length > 0) {
          Column({ space: 3 }) {
            Text('TRENDING')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(2.2)
              .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            Text('热门搜索')
              .fontSize(18)
              .fontWeight(FontWeight.Bolder)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ top: 8, bottom: 14 })

          Column({ space: 2 }) {
            ForEach(this.hotWords, (k: string, idx: number) => {
              Row({ space: 14 }) {
                Text(idx < 9 ? `0${idx + 1}` : `${idx + 1}`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bolder)
                  .fontColor(idx === 0 ? QgTheme.color('rankOne', this.themeId, this.darkOn) :
                    (idx === 1 ? QgTheme.color('rankTwo', this.themeId, this.darkOn) :
                      (idx === 2 ? QgTheme.color('rankThree', this.themeId, this.darkOn) : QgTheme.color('textFaint', this.themeId, this.darkOn))))
                  .width(34)
                Text(k)
                  .fontSize(15)
                  .fontWeight(idx < 3 ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
                  .layoutWeight(1)
                if (idx < 3) {
                  SymbolGlyph($r('sys.symbol.flame'))
                    .fontSize(14)
                    .fontColor([QgTheme.color('rankOne', this.themeId, this.darkOn)])
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 13 })
              .borderRadius(14)
              .onClick(() => this.doSearch(k))
            }, (k: string, idx: number) => `hot_${idx}_${k}`)
          }
          .width('100%')
          .padding(8)
          .borderRadius(QgUi.R_CARD)
          .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
          .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
        }
      }
      .width('100%')
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + 32 })
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
          Column({ space: 12 }) {
            LoadingProgress().width(36).height(36).color(QgTheme.color('accentInk', this.themeId, this.darkOn))
            Text('正在搜索片库…').fontSize(13).fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
          }
          .width('100%')
          .padding({ top: 96, bottom: 96 })
          .justifyContent(FlexAlign.Center)
        } else if (this.errMsg.length > 0) {
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
              label: '重试',
              compact: true,
              onTap: () => this.doSearch(this.keyword)
            })
          }
          .width('100%')
          .padding({ top: 72, bottom: 72 })
          .justifyContent(FlexAlign.Center)
        } else if (this.results.length === 0) {
          QgEmptyView({
            iconRes: $r('sys.symbol.magnifyingglass'),
            message: `没有找到「${this.keyword}」相关的剧`,
            hint: '试试更换关键词或切换站源'
          })
        } else {
          Row() {
            Text(`共找到 ${this.results.length} 部短剧`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
          }
          .width('100%')
          .padding({ bottom: 14 })

          Row({ space: 14 }) {
            ForEach(this.colIndices(), (colIdx: number) => {
              Column({ space: 22 }) {
                ForEach(this.colResults(colIdx), (d: QgDrama, rowIdx: number) => {
                  QgDramaCard({
                    cover: d.cover,
                    cardTitle: d.title,
                    subText: `${d.genre.length > 0 ? d.genre + ' · ' : ''}${d.episodeCount} 集`,
                    badge: d.badge.length > 0 ? d.badge : d.viewsText,
                    sourceId: d.sourceId,
                    ratio: this.cardRatio(colIdx, rowIdx),
                    onTapCard: () => {
                      if (QgStore.getInstance().getSettings().directPlay) {
                        const watch = QgStore.getInstance().getWatch(d.id);
                        const pp: QgPlayerParam = { dramaId: d.id, episode: watch !== undefined && watch.episode >= 1 ? watch.episode : 1 };
                        this.stack.pushPathByName('player', pp);
                      } else {
                        const p: QgDetailParam = { dramaId: d.id };
                        this.stack.pushPathByName('detail', p);
                      }
                    }
                  })
                }, (d: QgDrama) => `sres_${colIdx}_${d.id}`)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }, (colIdx: number) => `scol_${this.colCount()}_${colIdx}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
      }
      .width('100%')
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + 36 })
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
