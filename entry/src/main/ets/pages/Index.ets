import { QgTheme } from '../components/QgTheme';
﻿/**
 * 青果APP 主框架 —— 「夜幕 · 青柠」。
 *
 * - Navigation(Stack) 承载路由，目的页走系统路由表 router_map.json；
 * - 底部为悬浮墨色胶囊岛：选中项展开为青柠胶囊（图标 + 文字），其余只显示图标；
 * - 列表下滑时胶囊岛下沉隐藏，停止滚动后浮回（qgTabBarVisible）；
 * - 超级桌面流转到车机时，胶囊岛上方显示「车机模式」玻璃角标（EntryAbility 实时写入 carMode）。
 */
import { curves } from '@kit.ArkUI';
import { ExploreTab } from '../tab/ExploreTab';
import { FollowTab } from '../tab/FollowTab';
import { MineTab } from '../tab/MineTab';

/** 底部页签项 */
class QgTabItem {
  label: string = '';
  iconNormal: Resource = $r('sys.symbol.house');
  iconActive: Resource = $r('sys.symbol.house_fill');

  constructor(label: string, iconNormal: Resource, iconActive: Resource) {
    this.label = label;
    this.iconNormal = iconNormal;
    this.iconActive = iconActive;
  }
}

const TAB_ITEMS: QgTabItem[] = [
  new QgTabItem('发现', $r('sys.symbol.house'), $r('sys.symbol.house_fill')),
  new QgTabItem('片单', $r('sys.symbol.heart'), $r('sys.symbol.heart_fill')),
  new QgTabItem('我的', $r('sys.symbol.person'), $r('sys.symbol.person_fill'))
];

@Entry
@Component
struct Index {
  @StorageProp('qgTheme') themeId: string = 'lime';
  pathStack: NavPathStack = new NavPathStack();
  @State tabIdx: number = 0;
  @State barPressed: number = -1;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 0;
  @StorageProp('carMode') carOn: boolean = false;
  @StorageProp('qgTabBarVisible') tabBarVisible: boolean = true;
  @StorageProp('darkMode') darkOn: boolean = false;
  private tabController: TabsController = new TabsController();

  aboutToAppear(): void {
    AppStorage.setOrCreate('qgTabBarVisible', true);
  }

  private selectTab(idx: number): void {
    this.tabController.changeIndex(idx);
    this.tabIdx = idx;
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        Tabs({ controller: this.tabController, index: this.tabIdx }) {
          TabContent() {
            ExploreTab({ stack: this.pathStack })
          }
          TabContent() {
            FollowTab({ stack: this.pathStack })
          }
          TabContent() {
            MineTab({ stack: this.pathStack })
          }
        }
        .barHeight(0)
        .scrollable(false)
        .animationDuration(0)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.tabIdx = index;
          AppStorage.setOrCreate('qgTabBarVisible', true);
        })

        this.TabBarBuilder()
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
    // 窗口已 setWindowLayoutFullScreen(true)；Navigation 不再二次避让状态栏，由各页面自行补 safeTop
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
  }

  /** 胶囊岛宽度：手机按屏宽留边，平板 / 车机限制最大宽度居中 */
  private barWidth(): string | number {
    if (this.screenWidth >= 600) {
      return 360;
    }
    return '100%';
  }

  @Builder
  TabBarBuilder() {
    Column({ space: 10 }) {
      if (this.carOn) {
        Row({ space: 6 }) {
          Row().width(6).height(6).borderRadius(3).backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
          Text('车机模式').fontSize(11).fontWeight(FontWeight.Medium).fontColor(QgTheme.color('text', this.themeId, true))
        }
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor(QgTheme.color('tabBarBg', this.themeId, this.darkOn))
      }

      Stack() {
        // 极轻玻璃高光棱线（不遮挡背后透光）
        Row()
          .width('100%')
          .height('100%')
          .borderRadius(32)
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: this.darkOn
              ? [['#1AFFFFFF', 0], ['#00FFFFFF', 0.35], ['#08FFFFFF', 1]]
              : [['#24FFFFFF', 0], ['#00FFFFFF', 0.35], ['#0DFFFFFF', 1]]
          })
          .hitTestBehavior(HitTestMode.None)

        Row() {
          ForEach(TAB_ITEMS, (item: QgTabItem, idx: number) => {
            this.TabItemBuilder(item, idx)
          }, (item: QgTabItem) => item.label)
        }
        .width('100%')
        .height('100%')
        .padding(7)
      }
      .width(this.barWidth())
      .height(64)
      .borderRadius(32)
      .clip(true)
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: 16,
        saturation: 1.7,
        brightness: 1.0,
        color: this.darkOn ? '#12000000' : '#08FFFFFF'
      })
      .border({ width: 0.8, color: this.darkOn ? '#4DFFFFFF' : '#CCFFFFFF' })
      .shadow({ radius: 24, color: '#24000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: this.safeBottom + 12 })
    .translate({ y: this.tabBarVisible ? 0 : 120 })
    .opacity(this.tabBarVisible ? 1 : 0)
    .hitTestBehavior(this.tabBarVisible ? HitTestMode.Default : HitTestMode.None)
    .animation({ duration: 260, curve: curves.springMotion(0.38, 0.85) })
  }

  @Builder
  TabItemBuilder(item: QgTabItem, idx: number) {
    Row({ space: 8 }) {
      SymbolGlyph(this.tabIdx === idx ? item.iconActive : item.iconNormal)
        .fontSize(21)
        .fontColor([this.tabIdx === idx ? QgTheme.color('accentOn', this.themeId, this.darkOn) :
          QgTheme.color('text', this.themeId, this.darkOn)])
      if (this.tabIdx === idx) {
        Text(item.label)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
          .maxLines(1)
          .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
      }
    }
    .layoutWeight(this.tabIdx === idx ? 1.6 : 1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(24)
    .backgroundColor(this.tabIdx === idx ? QgTheme.color('accent', this.themeId, this.darkOn) : Color.Transparent)
    .scale({ x: this.barPressed === idx ? 0.92 : 1, y: this.barPressed === idx ? 0.92 : 1 })
    .animation({ duration: 320, curve: curves.springMotion(0.4, 0.8) })
    .accessibilityText(item.label)
    .accessibilitySelected(this.tabIdx === idx)
    .onClick(() => this.selectTab(idx))
    .onTouch((event: TouchEvent) => {
      this.barPressed = event.type === TouchType.Down ? idx : -1;
    })
  }
}
