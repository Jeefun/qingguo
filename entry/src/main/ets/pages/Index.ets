/**
 * 青果APP 主框架。
 *
 * 结构参照真果鉴（发现 / 追剧 / 我的）：
 * - Navigation(Stack) 承载路由，目的页走系统路由表 router_map.json；
 * - 底部三页签：发现 / 追剧 / 我的，弹簧动效切换；
 * - 超级桌面流转到车机时右下角显示「车机」角标（EntryAbility 实时写入 carMode）。
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
  new QgTabItem('追剧', $r('sys.symbol.heart'), $r('sys.symbol.heart_fill')),
  new QgTabItem('我的', $r('sys.symbol.person'), $r('sys.symbol.person_fill'))
];

@Entry
@Component
struct Index {
  pathStack: NavPathStack = new NavPathStack();
  @State tabIdx: number = 0;
  @State barPressed: number = -1;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('carMode') carOn: boolean = false;
  private tabController: TabsController = new TabsController();

  build() {
    Navigation(this.pathStack) {
      Column() {
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
        .layoutWeight(1)
        .onChange((index: number) => {
          this.tabIdx = index;
        })

        this.TabBarBuilder()
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  TabBarBuilder() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Row() {
        ForEach(TAB_ITEMS, (item: QgTabItem, idx: number) => {
          Column({ space: 3 }) {
            SymbolGlyph(this.tabIdx === idx ? item.iconActive : item.iconNormal)
              .fontSize(24)
              .fontColor([this.tabIdx === idx ? $r('app.color.accent') : $r('app.color.textFaint')])
            Text(item.label)
              .fontSize(11)
              .fontColor(this.tabIdx === idx ? $r('app.color.accent') : $r('app.color.textFaint'))
              .fontWeight(this.tabIdx === idx ? FontWeight.Medium : FontWeight.Normal)
          }
          .flexShrink(1)
          .flexGrow(1)
          .padding({ top: 8, bottom: 4 })
          .scale({
            x: this.tabIdx === idx ? (this.barPressed === idx ? 0.92 : 1.06) : 1,
            y: this.tabIdx === idx ? (this.barPressed === idx ? 0.92 : 1.06) : 1
          })
          .animation({ duration: 300, curve: curves.springMotion(0.42, 0.72) })
          .onClick(() => {
            if (this.tabIdx !== idx) {
              this.tabController.changeIndex(idx);
              this.tabIdx = idx;
            }
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.barPressed = idx;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.barPressed = -1;
            }
          })
        }, (item: QgTabItem, idx: number) => `${item.label}_${idx}`)
      }
      .width('100%')
      .padding({ bottom: this.safeBottom })
      .backgroundColor($r('app.color.surface'))
      .border({ width: { top: 0.5 }, color: $r('app.color.border') })

      if (this.carOn) {
        Text('车机')
          .fontSize(10)
          .fontColor($r('app.color.accentOn'))
          .backgroundColor($r('app.color.accent'))
          .borderRadius(8)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .margin(10)
      }
    }
    .width('100%')
  }
}
