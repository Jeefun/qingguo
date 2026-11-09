/**
 * 设置页：外观 + 站源切换 + 播放开关 + 网络代理 + 数据管理 + 关于。
 */
import { curves } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { QgAppSettings } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgSource } from '../data/source/QgSource';
import { QgStore } from '../data/QgStore';
import { QgBackBtn } from '../components/QgWidgets';

/** 外观选项 */
class QgModeOption {
  value: string = '';
  label: string = '';

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const MODE_OPTIONS: QgModeOption[] = [
  new QgModeOption('system', '跟随系统'),
  new QgModeOption('light', '浅色'),
  new QgModeOption('dark', '深色')
];

@Component
struct QgSettingsPage {
  private stack: NavPathStack = new NavPathStack();
  @State colorMode: string = 'system';
  @State sourceId: string = 'hongguo';
  @State autoPlay: boolean = true;
  @State autoNext: boolean = true;
  @State proxyOn: boolean = false;
  @State proxyHost: string = '';
  @State proxyPort: number = 7890;
  @StorageProp('safeTop') safeTop: number = 0;

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row({ space: 10 }) {
            QgBackBtn({
              onBack: () => {
                this.stack.pop();
              }
            })
            Text('设置')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text'))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.safeTop + 6, bottom: 12 })

          this.AppearanceBuilder()
          this.SourceBuilder()
          this.PlayBuilder()
          this.NetworkBuilder()
          this.DataBuilder()
          this.AboutBuilder()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const s: QgAppSettings = QgStore.getInstance().getSettings();
      this.colorMode = s.colorMode;
      this.sourceId = QgRepository.currentSourceId();
      this.autoPlay = s.autoPlay;
      this.autoNext = s.autoNext;
      this.proxyOn = s.proxyOn;
      this.proxyHost = s.proxyHost;
      this.proxyPort = s.proxyPort;
    })
  }

  /** 全量写回设置（QgAppSettings），保持未在页面展示的字段不变 */
  private persistSettings(): void {
    const cur: QgAppSettings = QgStore.getInstance().getSettings();
    const s: QgAppSettings = new QgAppSettings();
    s.colorMode = this.colorMode;
    s.sourceId = this.sourceId;
    s.autoPlay = this.autoPlay;
    s.autoNext = this.autoNext;
    s.playSpeed = cur.playSpeed;
    s.danmakuOn = cur.danmakuOn;
    s.danmakuOpacity = cur.danmakuOpacity;
    s.danmakuFontSize = cur.danmakuFontSize;
    s.downloadWifiOnly = cur.downloadWifiOnly;
    s.downloadParallel = cur.downloadParallel;
    s.proxyOn = this.proxyOn;
    s.proxyHost = this.proxyHost;
    s.proxyPort = this.proxyPort;
    QgStore.getInstance().updateSettings(s);
  }

  private applyColorMode(mode: string): void {
    const appCtx = getContext(this).getApplicationContext();
    try {
      if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        AppStorage.setOrCreate('darkMode', false);
      } else if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
        AppStorage.setOrCreate('darkMode', true);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
        const sysDark: boolean = AppStorage.get<boolean>('systemDark') === true;
        AppStorage.setOrCreate('darkMode', sysDark);
      }
    } catch (error) {
      // 颜色模式应用失败不阻塞设置保存
    }
  }

  @Builder
  SectionTitleBuilder(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.textFaint'))
      .width('100%')
      .padding({ top: 18, bottom: 8, left: 4 })
  }

  @Builder
  AppearanceBuilder() {
    Column() {
      this.SectionTitleBuilder('外观')
      Row({ space: 8 }) {
        ForEach(MODE_OPTIONS, (opt: QgModeOption) => {
          Text(opt.label)
            .fontSize(13)
            .fontColor(this.colorMode === opt.value ? $r('app.color.accentOn') : $r('app.color.textDim'))
            .padding({ left: 16, right: 16, top: 9, bottom: 9 })
            .borderRadius(18)
            .backgroundColor(this.colorMode === opt.value ? $r('app.color.accent') : $r('app.color.chipBg'))
            .animation({ duration: 240, curve: curves.springMotion(0.4, 0.8) })
            .onClick(() => {
              this.colorMode = opt.value;
              this.persistSettings();
              this.applyColorMode(opt.value);
            })
        }, (opt: QgModeOption) => `mode_${opt.value}`)
      }
      .width('100%')
      .padding({ top: 4, bottom: 16, left: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SourceBuilder() {
    Column() {
      this.SectionTitleBuilder('站源')
      Column() {
        ForEach(QgRepository.sources(), (src: QgSource) => {
          Row({ space: 12 }) {
            Text(src.name)
              .fontSize(15)
              .fontColor(this.sourceId === src.id ? $r('app.color.accent') : $r('app.color.text'))
              .layoutWeight(1)
            if (this.sourceId === src.id) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor([$r('app.color.accent')])
            }
          }
          .width('100%')
          .padding(16)
          .onClick(() => {
            this.selectSource(src.id);
          })
        }, (src: QgSource) => `source_${src.id}`)
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor($r('app.color.surface'))

      Text('各站源数据来自公开网页与接口，仅供学习交流；如加载失败可切换其他站源。')
        .fontSize(11)
        .fontColor($r('app.color.textFaint'))
        .lineHeight(16)
        .padding({ top: 8, left: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private selectSource(id: string): void {
    if (id === this.sourceId) {
      return;
    }
    QgRepository.setSource(id);
    this.sourceId = QgRepository.currentSourceId();
    AppStorage.setOrCreate('qgSourceTick', (AppStorage.get<number>('qgSourceTick') ?? 0) + 1);
  }

  @Builder
  PlayBuilder() {
    Column() {
      this.SectionTitleBuilder('播放')
      Column() {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('自动播放')
              .fontSize(15)
              .fontColor($r('app.color.text'))
            Text('打开播放页自动开始播放')
              .fontSize(11)
              .fontColor($r('app.color.textFaint'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoPlay })
            .selectedColor($r('app.color.accent'))
            .onChange((isOn: boolean) => {
              this.autoPlay = isOn;
              this.persistSettings();
            })
        }
        .width('100%')
        .padding(16)

        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16 })

        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('自动连播')
              .fontSize(15)
              .fontColor($r('app.color.text'))
            Text('播完一集自动播放下一集')
              .fontSize(11)
              .fontColor($r('app.color.textFaint'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoNext })
            .selectedColor($r('app.color.accent'))
            .onChange((isOn: boolean) => {
              this.autoNext = isOn;
              this.persistSettings();
            })
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor($r('app.color.surface'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  NetworkBuilder() {
    Column() {
      this.SectionTitleBuilder('网络')
      Column() {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text('HTTP 代理')
              .fontSize(15)
              .fontColor($r('app.color.text'))
            Text('站源请求经代理转发（播放器直连）')
              .fontSize(11)
              .fontColor($r('app.color.textFaint'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.proxyOn })
            .selectedColor($r('app.color.accent'))
            .onChange((isOn: boolean) => {
              this.proxyOn = isOn;
              this.persistSettings();
            })
        }
        .width('100%')
        .padding(16)

        if (this.proxyOn) {
          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 16 })

          Row({ space: 12 }) {
            Text('主机')
              .fontSize(14)
              .fontColor($r('app.color.text'))
              .width(48)
            TextInput({ text: this.proxyHost, placeholder: '127.0.0.1' })
              .fontSize(14)
              .fontColor($r('app.color.text'))
              .backgroundColor($r('app.color.chipBg'))
              .borderRadius(10)
              .height(40)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.proxyHost = value.trim();
                this.persistSettings();
              })
          }
          .width('100%')
          .padding(16)

          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 16 })

          Row({ space: 12 }) {
            Text('端口')
              .fontSize(14)
              .fontColor($r('app.color.text'))
              .width(48)
            TextInput({ text: `${this.proxyPort}`, placeholder: '7890' })
              .fontSize(14)
              .fontColor($r('app.color.text'))
              .backgroundColor($r('app.color.chipBg'))
              .borderRadius(10)
              .height(40)
              .layoutWeight(1)
              .type(InputType.Number)
              .onChange((value: string) => {
                const port: number = Number(value);
                if (!Number.isNaN(port) && port >= 1 && port <= 65535) {
                  this.proxyPort = Math.floor(port);
                  this.persistSettings();
                }
              })
          }
          .width('100%')
          .padding(16)
        }
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor($r('app.color.surface'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DataBuilder() {
    Column() {
      this.SectionTitleBuilder('数据管理')
      Column() {
        this.DataRowBuilder('清空观看记录', () => {
          this.confirmClear('观看记录', () => {
            QgStore.getInstance().clearWatch();
            AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
          });
        })
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 16 })
        this.DataRowBuilder('清空搜索历史', () => {
          this.confirmClear('搜索历史', () => {
            QgStore.getInstance().clearSearchHistory();
          });
        })
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor($r('app.color.surface'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DataRowBuilder(label: string, onTap: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(14)
        .fontColor([$r('app.color.textFaint')])
        .rotate({ angle: 180 })
    }
    .width('100%')
    .padding(16)
    .onClick(() => onTap())
  }

  private confirmClear(what: string, onConfirm: () => void): void {
    AlertDialog.show({
      title: `清空${what}`,
      message: `确定要清空全部${what}吗？该操作不可恢复。`,
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
          onConfirm();
        }
      }
    });
  }

  @Builder
  AboutBuilder() {
    Column() {
      this.SectionTitleBuilder('关于')
      Column({ space: 6 }) {
        Text('青果APP')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Text('版本 1.0.0')
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
        Text('一款 HarmonyOS 短剧应用，功能结构参考开源项目「真果鉴」（Xanerix/guoapp），演示数据与样例片源仅用于学习体验。')
          .fontSize(11)
          .fontColor($r('app.color.textFaint'))
          .lineHeight(18)
          .padding({ left: 24, right: 24, top: 6 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ top: 18, bottom: 10 })
      .borderRadius(14)
      .backgroundColor($r('app.color.surface'))
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Builder
export function QgSettingsBuilder() {
  QgSettingsPage()
}
