import { QgEpisode, qgEpisodeLabel, qgEpisodesNamed } from '../model/QgModels';
import { QgTheme } from './QgTheme';
import { QgEpisodeCatalog } from './QgEpisodeCatalog';

/** 详情和播放器共用的选集器，每次最多展示 30 集。 */
@Component
export struct QgEpisodePicker {
  @Prop @Watch('resetSelection') episodes: QgEpisode[] = [];
  @Prop @Watch('focusCurrent') currentEpisode: number = 1;
  @Prop watchEpisode: number = 0;
  @Prop playingMode: boolean = false;
  @Prop disabled: boolean = false;
  @Prop themeId: string = 'lime';
  @Prop darkOn: boolean = false;
  onPick: (order: number) => void = () => {};
  @State groupIndex: number = 0;
  @State descending: boolean = false;
  @State jumpInput: string = '';
  @State jumpError: string = '';
  @State locatedOrder: number = 0;
  @State availableWidth: number = 320;
  private groupsScroller: Scroller = new Scroller();
  private jumpController: TextInputController = new TextInputController();
  private groupsReady: boolean = false;

  aboutToAppear(): void {
    this.focusCurrent();
  }

  private resetSelection(): void {
    this.jumpInput = '';
    this.jumpError = '';
    this.focusCurrent();
  }

  private focusCurrent(): void {
    this.locatedOrder = 0;
    this.groupIndex = QgEpisodeCatalog.groupOf(this.episodes, this.currentEpisode, this.descending);
    this.revealGroup();
  }

  private revealGroup(): void {
    if (this.groupsReady && this.labels().length > 1) {
      this.groupsScroller.scrollToIndex(this.groupIndex, false, ScrollAlign.CENTER);
    }
  }

  private labels(): string[] {
    return QgEpisodeCatalog.labels(this.episodes, this.descending);
  }

  private visibleEpisodes(): QgEpisode[] {
    return QgEpisodeCatalog.page(this.episodes, this.groupIndex, this.descending);
  }

  private toggleOrder(): void {
    const visible: QgEpisode[] = this.visibleEpisodes();
    const anchor: number = visible.some((ep: QgEpisode): boolean => ep.order === this.locatedOrder) ?
      this.locatedOrder : (visible.some((ep: QgEpisode): boolean => ep.order === this.currentEpisode) ?
        this.currentEpisode : (visible[0]?.order ?? this.currentEpisode));
    this.descending = !this.descending;
    this.groupIndex = QgEpisodeCatalog.groupOf(this.episodes, anchor, this.descending);
    this.revealGroup();
  }

  private locateEpisode(): void {
    const order: number = QgEpisodeCatalog.locate(this.episodes, this.jumpInput);
    if (order === 0) {
      this.jumpError = '请输入本季已有的集数';
      return;
    }
    this.jumpError = '';
    this.locatedOrder = order;
    this.groupIndex = QgEpisodeCatalog.groupOf(this.episodes, order, this.descending);
    this.jumpController.stopEditing();
    this.revealGroup();
  }

  private tileLabel(ep: QgEpisode): string {
    if (ep.order === this.currentEpisode && this.playingMode) return '当前播放';
    if (ep.order === this.watchEpisode) return '上次观看';
    if (ep.order === this.locatedOrder) return '点击播放';
    // 常见的“第 N 集”不再挤占数字位置；有实际章节名时保留。
    const title: string = ep.title.trim();
    return title === `${ep.order}` || /^第\s*\d+\s*[集话期]$/.test(title) ? '' : title;
  }

  private columns(): number {
    if (this.namedMode()) {
      return 1;
    }
    return this.availableWidth >= 700 ? 10 : (this.availableWidth >= 480 ? 7 : 5);
  }

  /** 多数分集有命名标题（听书/广播剧章节）时按单列章节列表展示 */
  private namedMode(): boolean {
    return qgEpisodesNamed(this.episodes);
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('分集').fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          Text(`共 ${this.episodes.length} 集${this.playingMode ? ` · 正在播放第 ${this.currentEpisode} 集` :
            (this.watchEpisode > 0 ? ` · 上次看到第 ${this.watchEpisode} 集` : ' · 选择一集开始观看')}`)
            .fontSize(12).maxLines(2)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.descending ? '倒序' : '正序')
          .height(40).fontSize(12).padding({ left: 14, right: 14 })
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .accessibilityText(`当前${this.descending ? '倒序' : '正序'}，点击切换排序`)
          .onClick(() => this.toggleOrder())
      }.width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.jumpInput, placeholder: '输入集数', controller: this.jumpController })
          .type(InputType.Number).enterKeyType(EnterKeyType.Search).maxLength(6)
          .fontSize(13).fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .placeholderColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .height(40).layoutWeight(1).borderRadius(12)
          .accessibilityText('输入要定位的集数')
          .onChange((value: string) => { this.jumpInput = value; this.jumpError = ''; })
          .onSubmit(() => this.locateEpisode())
        Button('定位').height(40).fontSize(12).padding({ left: 14, right: 14 })
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .onClick(() => this.locateEpisode())
        if (this.playingMode || this.watchEpisode > 0) {
          Button(this.playingMode ? '回到当前' : '上次观看')
            .height(40).fontSize(12).padding({ left: 12, right: 12 })
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            .backgroundColor(QgTheme.color('accentSoft', this.themeId, this.darkOn))
            .onClick(() => this.focusCurrent())
        }
      }.width('100%')

      if (this.jumpError.length > 0) {
        Text(this.jumpError).fontSize(12).width('100%')
          .fontColor(QgTheme.color('danger', this.themeId, this.darkOn))
      } else if (this.locatedOrder > 0) {
        Text(`已定位第 ${this.locatedOrder} 集，点击下方集数播放`).fontSize(12).width('100%')
          .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
      }

      if (this.labels().length > 1) {
        List({ space: 8, scroller: this.groupsScroller }) {
          ForEach(this.labels(), (label: string, index: number) => {
            ListItem() {
              Button(label).height(40).fontSize(12)
                .fontWeight(this.groupIndex === index ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(QgTheme.color(this.groupIndex === index ? 'accentOn' : 'textDim', this.themeId, this.darkOn))
                .backgroundColor(QgTheme.color(this.groupIndex === index ? 'accent' : 'surface', this.themeId, this.darkOn))
                .padding({ left: 14, right: 14 })
                .accessibilityText(`第 ${label} 集${this.groupIndex === index ? '，当前区间' : ''}`)
                .onClick(() => { this.groupIndex = index; this.locatedOrder = 0; })
            }
          }, (label: string, index: number) => `${this.descending}_${index}_${label}`)
        }
        .listDirection(Axis.Horizontal).scrollBar(BarState.Off).height(42).width('100%')
        .onAppear(() => { this.groupsReady = true; this.revealGroup(); })
        .onDisAppear(() => { this.groupsReady = false; })
        .onAreaChange(() => this.revealGroup())
      }

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.visibleEpisodes(), (ep: QgEpisode) => {
          Button({ type: ButtonType.Normal }) {
            if (this.namedMode()) {
              Row({ space: 10 }) {
                Text(`${ep.order}`)
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor(QgTheme.color(ep.order === this.currentEpisode ? 'accentOn' : 'textDim', this.themeId, this.darkOn))
                  .constraintSize({ minWidth: 24 }).textAlign(TextAlign.End)
                Text(qgEpisodeLabel(ep))
                  .fontSize(13).layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontWeight(ep.order === this.currentEpisode ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(QgTheme.color(ep.order === this.currentEpisode ? 'accentOn' : 'text', this.themeId, this.darkOn))
              }.width('100%').padding({ left: 12, right: 10 })
            } else {
              Column({ space: 3 }) {
                Text(`${ep.order}`).fontSize(17).fontWeight(FontWeight.Bold)
                  .fontColor(QgTheme.color(ep.order === this.currentEpisode ? 'accentOn' : 'text', this.themeId, this.darkOn))
                if (this.tileLabel(ep).length > 0) {
                  Text(this.tileLabel(ep)).fontSize(10).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(QgTheme.color(ep.order === this.currentEpisode ? 'accentOn' : 'textDim', this.themeId, this.darkOn))
                }
              }.width('100%').padding({ left: 3, right: 3 })
            }
          }
          .width(`${100 / this.columns() - 1.6}%`).height(this.namedMode() ? 46 : 58).padding(0).borderRadius(12)
          .backgroundColor(QgTheme.color(ep.order === this.currentEpisode ? 'accent' : 'surface', this.themeId, this.darkOn))
          .border({ width: ep.order === this.locatedOrder ? 2 : 1,
            color: QgTheme.color(ep.order === this.locatedOrder ? 'accentInk' : 'divider', this.themeId, this.darkOn) })
          .margin({ right: '1.5%', bottom: 8 })
          .accessibilityText(this.namedMode() ? `第 ${ep.order} 集，${qgEpisodeLabel(ep)}` :
            `第 ${ep.order} 集，${ep.title}，${this.tileLabel(ep)}`)
          .onClick(() => this.onPick(ep.order))
        }, (ep: QgEpisode) => `${ep.id}_${ep.order}`)
      }.width('100%')
    }
    .width('100%').alignItems(HorizontalAlign.Start).enabled(!this.disabled)
    .onAreaChange((_oldArea: Area, area: Area) => { this.availableWidth = Number(area.width); })
  }
}
