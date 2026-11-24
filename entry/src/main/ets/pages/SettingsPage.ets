import { QgTheme, QgThemeOption } from '../components/QgTheme';
/**
 * 设置页 —— 「夜幕 · 青柠」。
 *
 * - 顶部返回 + 大标题 + QgSegmented 分类导航（外观 / 播放 / 更多）；
 * - 外观提供深浅双景主题画廊；
 * - 保留代理配置、数据清空等全部原有逻辑。
 */
import { curves, promptAction } from '@kit.ArkUI';
import { ConfigurationConstant, OpenLinkOptions, common } from '@kit.AbilityKit';
import { QgAppSettings } from '../model/QgModels';
import { QgStore } from '../data/QgStore';
import { QG_VERSION, QG_ANDROID_BASE } from '../data/QgVersion';
import { QgSegmented, QgTopBar, QgUi } from '../components/QgWidgets';

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
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  private stack: NavPathStack = new NavPathStack();
  @State colorMode: string = 'system';
  @State paletteAreaWidth: number = 320;
  @State settingsSection: number = 0;
  @State sourceId: string = 'hongguo';
  @State autoPlay: boolean = true;
  @State autoNext: boolean = true;
  @State directPlay: boolean = false;
  @State proxyOn: boolean = false;
  @State proxyHost: string = '';
  @State proxyPort: number = 7890;
  @State homeContinue: boolean = true;
  @State homeRank: boolean = true;
  @State homeRecommendations: boolean = true;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 0;

  private persistSettings(): void {
    const cur: QgAppSettings = QgStore.getInstance().getSettings();
    const s: QgAppSettings = new QgAppSettings();
    s.colorMode = this.colorMode;
    s.sourceId = this.sourceId;
    s.autoPlay = this.autoPlay;
    s.autoNext = this.autoNext;
    s.directPlay = this.directPlay;
    s.playSpeed = cur.playSpeed;
    s.videoAspect = cur.videoAspect;
    s.danmakuOn = cur.danmakuOn;
    s.danmakuOpacity = cur.danmakuOpacity;
    s.danmakuFontSize = cur.danmakuFontSize;
    s.danmakuArea = cur.danmakuArea;
    s.danmakuBlockWords = cur.danmakuBlockWords.slice();
    s.downloadWifiOnly = cur.downloadWifiOnly;
    s.downloadParallel = cur.downloadParallel;
    s.proxyOn = this.proxyOn;
    s.proxyHost = this.proxyHost;
    s.proxyPort = this.proxyPort;
    s.homeContinue = this.homeContinue;
    s.homeRank = this.homeRank;
    s.homeRecommendations = this.homeRecommendations;
    AppStorage.setOrCreate('qgHomeTick', (AppStorage.get<number>('qgHomeTick') ?? 0) + 1);
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
        fontColor: QgTheme.color('danger', this.themeId, this.darkOn),
        action: () => {
          onConfirm();
        }
      }
    });
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          QgTopBar({
            title: '',
            safeTop: this.safeTop,
            onBack: () => this.stack.pop()
          })

          Column({ space: 4 }) {
            Text('PREFERENCES')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(2.4)
              .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            Text('设置')
              .fontSize(30)
              .fontWeight(FontWeight.Bolder)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, top: 2, bottom: 16 })

          Column() {
            QgSegmented({
              options: ['外观', '播放', '更多'],
              selectedIndex: this.settingsSection,
              onSelect: (idx: number) => {
                this.settingsSection = idx;
              }
            })
          }
          .width('100%')
          .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: 10 })

          Scroll() {
            Column() {
              if (this.settingsSection === 0) {
                this.AppearanceBuilder()
                this.HomeBuilder()
              } else if (this.settingsSection === 1) {
                this.PlayBuilder()
              } else {
                this.NetworkBuilder()
                this.DataBuilder()
                this.AboutBuilder()
              }
            }
            .width('100%')
            .padding({ left: QgUi.GUTTER, right: QgUi.GUTTER, bottom: this.safeBottom + 44 })
            .alignItems(HorizontalAlign.Start)
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(QgTheme.color('bg', this.themeId, this.darkOn))
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const s: QgAppSettings = QgStore.getInstance().getSettings();
      this.colorMode = s.colorMode;
      this.sourceId = s.sourceId;
      this.autoPlay = s.autoPlay;
      this.autoNext = s.autoNext;
      this.directPlay = s.directPlay;
      this.proxyOn = s.proxyOn;
      this.proxyHost = s.proxyHost;
      this.proxyPort = s.proxyPort;
      this.homeContinue = s.homeContinue;
      this.homeRank = s.homeRank;
      this.homeRecommendations = s.homeRecommendations;
    })
  }

  @Builder
  GroupHeaderBuilder(eyebrow: string, title: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bolder)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 18, bottom: 12 })
  }

  @Builder
  AppearanceBuilder() {
    Column() {
      this.GroupHeaderBuilder('', '主题配色')
      Text('熟悉的青果，换一种心情。').fontSize(13)
        .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
        .width('100%').margin({ bottom: 6 })
      Text('每款都有日与夜，点击即可应用').fontSize(11)
        .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
        .width('100%').margin({ bottom: 16 })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(QgTheme.options(), (opt: QgThemeOption) => {
          this.PaletteCardBuilder(opt)
        }, (opt: QgThemeOption) => opt.id)
      }
      .width('100%')
      .onAreaChange((_oldArea: Area, area: Area) => { this.paletteAreaWidth = Number(area.width); })
      this.GroupHeaderBuilder('', '明暗模式')
      Row({ space: 10 }) {
        ForEach(MODE_OPTIONS, (opt: QgModeOption) => {
          this.ThemeCardBuilder(opt)
        }, (opt: QgModeOption) => `mode_${opt.value}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private paletteCardWidth(): string {
    if (this.paletteAreaWidth < 280) return '100%';
    if (this.paletteAreaWidth >= 920) return '23.5%';
    return this.paletteAreaWidth >= 640 ? '31.8%' : '48.2%';
  }

  @Builder
  PaletteCardBuilder(opt: QgThemeOption) {
    Button({ type: ButtonType.Normal }) {
      Column() {
        Row() {
          this.PalettePreviewBuilder(opt.id, false)
          this.PalettePreviewBuilder(opt.id, true)
        }.width('100%').height(104).clip(true)
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(opt.title).fontSize(16).fontWeight(FontWeight.Bold).layoutWeight(1)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.themeId === opt.id) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18)
                .fontColor([QgTheme.color('accentInk', opt.id, this.darkOn)])
            } else {
              Text(opt.tag).fontSize(9).fontWeight(FontWeight.Medium)
                .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
                .maxLines(1)
            }
          }.width('100%')
          Text(opt.subtitle).fontSize(11).lineHeight(16).height(32).textAlign(TextAlign.Start)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      }
      .width('100%').borderRadius(20).clip(true)
    }
      .width(this.paletteCardWidth()).padding(0).margin({ bottom: 12 }).borderRadius(20).clip(true)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: this.themeId === opt.id ? 2 : 1, radius: 20,
        color: this.themeId === opt.id ? QgTheme.color('accentInk', opt.id, this.darkOn) :
          QgTheme.color('divider', this.themeId, this.darkOn) })
      .accessibilityText(`${opt.title}主题，${opt.subtitle}，${this.themeId === opt.id ? '已选中' : '点击应用'}，预览包含日间与夜间配色`)
      .onClick(() => { QgStore.getInstance().setTheme(opt.id); })
  }

  @Builder
  PalettePreviewBuilder(id: string, dark: boolean) {
    Column({ space: 7 }) {
      Row() {
        Row().width(20).height(4).borderRadius(2).backgroundColor(QgTheme.color('text', id, dark))
        Blank()
        Text(dark ? '夜' : '日').fontSize(8).fontColor(QgTheme.color('textDim', id, dark))
      }.width('100%')
      Row({ space: 4 }) {
        Column().layoutWeight(1.35).height(40).borderRadius(6)
          .linearGradient({ angle: 135,
            colors: [[QgTheme.color('accent', id, dark), 0], [QgTheme.color('accentDim', id, dark), 1]] })
        Column({ space: 4 }) {
          Row().width('100%').height(18).borderRadius(5).backgroundColor(QgTheme.color('accentSoft', id, dark))
          Row().width('100%').height(18).borderRadius(5).backgroundColor(QgTheme.color('surfaceHigh', id, dark))
        }.layoutWeight(1)
      }.width('100%')
      Row({ space: 5 }) {
        Row().width(18).height(10).borderRadius(5).backgroundColor(QgTheme.color('accent', id, dark))
        Row().width(5).height(5).borderRadius(3).backgroundColor(QgTheme.color('textFaint', id, dark))
        Row().width(5).height(5).borderRadius(3).backgroundColor(QgTheme.color('textFaint', id, dark))
      }.width('100%').height(18).justifyContent(FlexAlign.Center).borderRadius(9)
        .backgroundColor(QgTheme.color('surface', id, dark))
    }
    .layoutWeight(1).height('100%').padding(10).alignItems(HorizontalAlign.Start)
    .backgroundColor(QgTheme.color('bg', id, dark))
  }

  @Builder
  ThemeCardBuilder(opt: QgModeOption) {
    Column({ space: 10 }) {
      // 迷你屏幕预览
      Row() {
        if (opt.value === 'system') {
          Column().layoutWeight(1).height('100%').backgroundColor(QgTheme.color('bg', this.themeId, false))
          Column().layoutWeight(1).height('100%').backgroundColor(QgTheme.color('bg', this.themeId, true))
        } else if (opt.value === 'light') {
          Column({ space: 4 }) {
            Row().width('60%').height(5).borderRadius(3).backgroundColor(QgTheme.color('text', this.themeId, false))
            Row().width('40%').height(6).borderRadius(3).backgroundColor(QgTheme.color('accent', this.themeId, false))
          }
          .width('100%')
          .height('100%')
          .padding(8)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.End)
          .backgroundColor(QgTheme.color('bg', this.themeId, false))
        } else {
          Column({ space: 4 }) {
            Row().width('60%').height(5).borderRadius(3).backgroundColor(QgTheme.color('text', this.themeId, true))
            Row().width('40%').height(6).borderRadius(3).backgroundColor(QgTheme.color('accent', this.themeId, true))
          }
          .width('100%')
          .height('100%')
          .padding(8)
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.End)
          .backgroundColor(QgTheme.color('bg', this.themeId, true))
        }
      }
      .width('100%')
      .height(54)
      .borderRadius(12)
      .clip(true)
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })

      Row({ space: 4 }) {
        Text(opt.label)
          .fontSize(12)
          .fontWeight(this.colorMode === opt.value ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.colorMode === opt.value ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('text', this.themeId, this.darkOn))
          .maxLines(1)
        if (this.colorMode === opt.value) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(13)
            .fontColor([QgTheme.color('accentInk', this.themeId, this.darkOn)])
        }
      }
    }
    .layoutWeight(1)
    .padding(10)
    .borderRadius(18)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({
      width: this.colorMode === opt.value ? 2 : 1,
      color: this.colorMode === opt.value ? QgTheme.color('accent', this.themeId, this.darkOn) : QgTheme.color('divider', this.themeId, this.darkOn)
    })
    .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
    .onClick(() => {
      this.colorMode = opt.value;
      this.persistSettings();
      this.applyColorMode(opt.value);
    })
  }

  @Builder
  HomeBuilder() {
    Column() {
      this.GroupHeaderBuilder('DISCOVERY', '首页模块')
      Column() {
        this.SwitchRowBuilder($r('sys.symbol.clock'), '继续观看', '显示最近播放的剧集', this.homeContinue,
          (value: boolean) => {
            this.homeContinue = value;
            this.persistSettings();
          })
        Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 66, right: 16 })
        this.SwitchRowBuilder($r('sys.symbol.square_grid_2x2'), '热播推荐', '显示推荐短剧瀑布流',
          this.homeRecommendations, (value: boolean) => {
            this.homeRecommendations = value;
            this.persistSettings();
          })
        Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 66, right: 16 })
        this.SwitchRowBuilder($r('sys.symbol.flame'), '热播榜', '显示按热度排序的榜单', this.homeRank,
          (value: boolean) => {
            this.homeRank = value;
            this.persistSettings();
          })
      }
      .width('100%')
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PlayBuilder() {
    Column() {
      this.GroupHeaderBuilder('PLAYBACK', '播放行为')
      Column() {
        this.SwitchRowBuilder($r('sys.symbol.play_fill'), '自动播放', '打开播放页自动开始播放', this.autoPlay,
          (isOn: boolean) => {
            this.autoPlay = isOn;
            this.persistSettings();
          })
        Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 66, right: 16 })
        this.SwitchRowBuilder($r('sys.symbol.forward_end_fill'), '自动连播', '播完一集自动播放下一集',
          this.autoNext, (isOn: boolean) => {
            this.autoNext = isOn;
            this.persistSettings();
          })
        Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 66, right: 16 })
        this.SwitchRowBuilder($r('sys.symbol.play_fill'), '点开剧集直接播放', '跳过详情页直接进入播放，返回时回到列表',
          this.directPlay, (isOn: boolean) => {
            this.directPlay = isOn;
            this.persistSettings();
          })
      }
      .width('100%')
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SwitchRowBuilder(icon: Resource, title: string, detail: string, value: boolean, onChange: (v: boolean) => void) {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(icon).fontSize(18).fontColor([QgTheme.color('text', this.themeId, this.darkOn)])
      }
      .width(36)
      .height(36)
      .borderRadius(11)
      .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))

      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        Text(detail)
          .fontSize(12)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(QgTheme.color('accent', this.themeId, this.darkOn))
        .onChange((isOn: boolean) => onChange(isOn))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  @Builder
  NetworkBuilder() {
    Column() {
      this.GroupHeaderBuilder('NETWORK', '网络代理')
      Column() {
        this.SwitchRowBuilder($r('sys.symbol.globe_badge_heart'), 'HTTP 代理', '站源请求经代理转发（播放器直连）',
          this.proxyOn, (isOn: boolean) => {
            this.proxyOn = isOn;
            this.persistSettings();
          })

        if (this.proxyOn) {
          Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 16, right: 16 })
          Row({ space: 12 }) {
            Text('主机').fontSize(14).fontColor(QgTheme.color('textDim', this.themeId, this.darkOn)).width(48)
            TextInput({ text: this.proxyHost, placeholder: '127.0.0.1' })
              .fontSize(14)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
              .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
              .borderRadius(12)
              .height(42)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.proxyHost = value.trim();
                this.persistSettings();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })

          Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 16, right: 16 })
          Row({ space: 12 }) {
            Text('端口').fontSize(14).fontColor(QgTheme.color('textDim', this.themeId, this.darkOn)).width(48)
            TextInput({ text: `${this.proxyPort}`, placeholder: '7890' })
              .fontSize(14)
              .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
              .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
              .borderRadius(12)
              .height(42)
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
          .padding({ left: 16, right: 16, top: 12, bottom: 14 })
        }
      }
      .width('100%')
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DataBuilder() {
    Column() {
      this.GroupHeaderBuilder('STORAGE', '数据管理')
      Column() {
        this.ActionRowBuilder($r('sys.symbol.clock'), '清空观看记录', () => {
          this.confirmClear('观看记录', () => {
            QgStore.getInstance().clearWatch();
            AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
          });
        })
        Divider().color(QgTheme.color('divider', this.themeId, this.darkOn)).margin({ left: 66, right: 16 })
        this.ActionRowBuilder($r('sys.symbol.magnifyingglass'), '清空搜索历史', () => {
          this.confirmClear('搜索历史', () => {
            QgStore.getInstance().clearSearchHistory();
          });
        })
      }
      .width('100%')
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ActionRowBuilder(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(icon).fontSize(18).fontColor([QgTheme.color('text', this.themeId, this.darkOn)])
      }
      .width(36)
      .height(36)
      .borderRadius(11)
      .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))

      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .onClick(() => onTap())
  }

  @Builder
  AboutBuilder() {
    Column() {
      this.GroupHeaderBuilder('ABOUT', '关于青果')
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Row().width(8).height(20).borderRadius(4).backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
          Text('青果APP')
            .fontSize(18)
            .fontWeight(FontWeight.Bolder)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
          Text(`v${QG_VERSION}`)
            .fontSize(12)
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
            .fontWeight(FontWeight.Bold)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(QgTheme.color('accentSoft', this.themeId, this.darkOn))
        }
        Text(`HarmonyOS 原生版本 · Android 同步基线 ${QG_ANDROID_BASE} · 站源接口 API 1`)
          .fontSize(12)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
          .lineHeight(19)
        Divider()
          .strokeWidth(1)
          .color(QgTheme.color('divider', this.themeId, this.darkOn))
          .margin({ top: 4 })
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.heart_fill'))
            .fontSize(16)
            .fontColor([QgTheme.color('accentInk', this.themeId, this.darkOn)])
          Text('感谢赞助 · mnyyds')
            .fontSize(14)
            .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(14)
            .fontColor([QgTheme.color('textFaint', this.themeId, this.darkOn)])
        }
        .width('100%')
        .onClick(() => {
          this.openSponsorLink();
        })
      }
      .width('100%')
      .padding(20)
      .borderRadius(QgUi.R_CARD)
      .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
      .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private openSponsorLink(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const options: OpenLinkOptions = { appLinkingOnly: false };
    ctx.openLink('https://github.com/mnyyds', options)
      .catch(() => {
        promptAction.showToast({ message: '暂时无法打开赞助链接' });
      });
  }
}

@Builder
export function QgSettingsBuilder() {
  QgSettingsPage()
}
