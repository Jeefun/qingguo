/**
 * 我的页：用户卡片 + 追剧/观看统计 + 功能菜单（观看记录 / 设置 / 关于）。
 */
import { QgStore } from '../data/QgStore';
import { QgRepository } from '../data/QgRepository';

@Component
export struct MineTab {
  stack: NavPathStack = new NavPathStack();
  @State followCount: number = 0;
  @State watchCount: number = 0;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('carMode') carOn: boolean = false;
  /** 观看 / 追剧数据变化时刷新统计 */
  @StorageProp('qgFollowTick') @Watch('onTick') followTick: number = 0;
  @StorageProp('qgWatchTick') @Watch('onTick') watchTick: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  reload(): void {
    this.followCount = QgStore.getInstance().getFollowList().length;
    this.watchCount = QgStore.getInstance().getWatchList().length;
  }

  build() {
    Scroll() {
      Column() {
        Text('我的')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')
          .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 12 })

        this.ProfileBuilder()
        this.StatsBuilder()
        this.MenuBuilder()
        this.AboutBuilder()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  ProfileBuilder() {
    Row({ space: 14 }) {
      Image($r('app.media.startIcon'))
        .width(64)
        .height(64)
        .borderRadius(32)
        .interpolation(ImageInterpolation.Medium)

      Column({ space: 4 }) {
        Text('青果用户')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Text('短剧爱好者 · 青果APP')
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(18)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .margin({ top: 4 })
  }

  @Builder
  StatsBuilder() {
    Row() {
      this.StatCellBuilder(`${this.followCount}`, '追剧')
      Divider()
        .vertical(true)
        .height(28)
        .color($r('app.color.border'))
      this.StatCellBuilder(`${this.watchCount}`, '看过')
      Divider()
        .vertical(true)
        .height(28)
        .color($r('app.color.border'))
      this.StatCellBuilder(`${QgRepository.sources().length}`, '站源')
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .margin({ top: 12 })
  }

  @Builder
  StatCellBuilder(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.textFaint'))
    }
    .layoutWeight(1)
  }

  @Builder
  MenuBuilder() {
    Column() {
      this.MenuRowBuilder($r('sys.symbol.clock'), '观看记录', () => {
        this.stack.pushPathByName('history', '');
      })
      this.MenuDividerBuilder()
      this.MenuRowBuilder($r('sys.symbol.magnifyingglass'), '搜索', () => {
        this.stack.pushPathByName('search', '');
      })
      this.MenuDividerBuilder()
      this.MenuRowBuilder($r('sys.symbol.gearshape'), '设置', () => {
        this.stack.pushPathByName('settings', '');
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .margin({ top: 12 })
  }

  @Builder
  MenuRowBuilder(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([$r('app.color.accent')])
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(16)
        .fontColor([$r('app.color.textFaint')])
        .rotate({ angle: 180 })
    }
    .width('100%')
    .padding({ top: 16, bottom: 16 })
    .onClick(() => onTap())
  }

  @Builder
  MenuDividerBuilder() {
    Divider()
      .color($r('app.color.border'))
      .margin({ left: 32 })
  }

  @Builder
  AboutBuilder() {
    Column() {
      if (this.carOn) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(14)
            .fontColor([$r('app.color.accent')])
          Text('当前正通过超级桌面在车机上使用')
            .fontSize(12)
            .fontColor($r('app.color.textDim'))
        }
        .padding({ top: 12 })
      }
      Text('青果APP v1.0.0 · 参考开源项目「真果鉴」(Xanerix/guoapp)')
        .fontSize(11)
        .fontColor($r('app.color.textFaint'))
        .padding({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
