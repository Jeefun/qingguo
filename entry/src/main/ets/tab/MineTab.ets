import { QgTheme } from '../components/QgTheme';
﻿/**
 * 我的页 —— 「夜幕 · 青柠」。
 *
 * - 大标题 + 24 圆角个人名片（带青柠标识点）+ 三联数据统计卡；
 * - 24 圆角菜单卡片（图标置于 38 圆角方块内）+ 车机状态提示 + 版本信息。
 */
import { QgStore } from '../data/QgStore';
import { QgRepository } from '../data/QgRepository';
import { QG_VERSION } from '../data/QgVersion';
import { QgUi } from '../components/QgWidgets';

@Component
export struct MineTab {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  stack: NavPathStack = new NavPathStack();
  @State followCount: number = 0;
  @State watchCount: number = 0;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('carMode') carOn: boolean = false;
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
        Column({ space: 4 }) {
          Text('PROFILE')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(2.4)
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
          Text('我的')
            .fontSize(30)
            .fontWeight(FontWeight.Bolder)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: this.safeTop + 16, bottom: 24 })

        this.ProfileBuilder()
        this.StatsBuilder()
        this.MenuBuilder()
        this.AboutBuilder()
      }
      .width('100%')
      .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + QgUi.TAB_BAR_SPACE })
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
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
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
  }

  @Builder
  ProfileBuilder() {
    Row({ space: 16 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.person_fill'))
            .fontSize(30)
            .fontColor([QgTheme.color('accentOn', this.themeId, this.darkOn)])
        }
        .width(64)
        .height(64)
        .borderRadius(32)
        .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
      }

      Column({ space: 6 }) {
        Text('青果影迷')
          .fontSize(22)
          .fontWeight(FontWeight.Bolder)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        Text(`当前片库：${QgRepository.currentSourceName()}`)
          .fontSize(13)
          .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(20)
    .borderRadius(QgUi.R_CARD)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    .margin({ bottom: 14 })
  }

  @Builder
  StatsBuilder() {
    Row({ space: 10 }) {
      this.StatCellBuilder(`${this.followCount}`, '正在追剧')
      this.StatCellBuilder(`${this.watchCount}`, '看过的剧')
      this.StatCellBuilder(`${QgRepository.sources().length}`, '可用片库')
    }
    .width('100%')
    .margin({ bottom: 24 })
  }

  @Builder
  StatCellBuilder(value: string, label: string) {
    Column({ space: 6 }) {
      Text(value)
        .fontSize(24)
        .fontWeight(FontWeight.Bolder)
        .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
      Text(label)
        .fontSize(12)
        .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
    }
    .layoutWeight(1)
    .padding({ top: 18, bottom: 18 })
    .borderRadius(QgUi.R_CARD)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
  }

  @Builder
  MenuBuilder() {
    Column() {
      this.MenuRowBuilder($r('sys.symbol.clock'), '观看记录', '回看历史进度', () => {
        this.stack.pushPathByName('history', '');
      })
      Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 68, right: 16 })
      this.MenuRowBuilder($r('sys.symbol.magnifyingglass'), '搜索短剧', '全片库关键词检索', () => {
        this.stack.pushPathByName('search', '');
      })
      Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 68, right: 16 })
      this.MenuRowBuilder($r('sys.symbol.gearshape'), '设置与偏好', '主题、播放、弹幕、站源与网络', () => {
        this.stack.pushPathByName('settings', '');
      })
      Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 68, right: 16 })
      this.MenuRowBuilder($r('sys.symbol.arrow_down_circle'), '站源商店', '安装与更新在线站源', () => {
        this.stack.pushPathByName('settings', 'modules');
      })
    }
    .width('100%')
    .borderRadius(QgUi.R_CARD)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
  }

  @Builder
  MenuRowBuilder(icon: Resource, label: string, sub: string, onTap: () => void) {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(19)
          .fontColor([QgTheme.color('text', this.themeId, this.darkOn)])
      }
      .width(38)
      .height(38)
      .borderRadius(12)
      .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))

      Column({ space: 3 }) {
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        Text(sub)
          .fontSize(12)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => onTap())
  }

  @Builder
  AboutBuilder() {
    Column({ space: 10 }) {
      if (this.carOn) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(13)
            .fontColor([QgTheme.color('accentInk', this.themeId, this.darkOn)])
          Text('当前正通过超级桌面在车机上使用')
            .fontSize(12)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        }
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(QgTheme.color('accentSoft', this.themeId, this.darkOn))
      }
      Text(`青果APP v${QG_VERSION} · 参考开源项目「真果鉴」(Xanerix/guoapp)`)
        .fontSize(12)
        .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 28 })
  }
}
