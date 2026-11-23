import { QgTheme } from './QgTheme';
/**
 * 青果APP 共享 UI 组件 —— 设计语言「夜幕 · 青柠」。
 *
 * 规则（详见仓库根目录 DESIGN.md）：
 * - 青柠 accent 只做「填充」（按钮、选中胶囊、进度），其上文字用 accentOn；
 *   需要青柠色的文字 / 图标落在背景上时一律用 accentInk（浅色模式下自动变深）。
 * - 浮层控件统一玻璃材质：glassBg + glassStroke 描边 + backdrop 模糊。
 * - 圆角：海报 18、卡片 24、面板 28、按钮 / 胶囊全圆。
 */
import { curves } from '@kit.ArkUI';
import { QgRepository } from '../data/QgRepository';
import { QgGateway } from '../data/QgGateway';

/**
 * 封面统一出口：http(s) 封面经本地媒体网关注入 Referer/UA 后加载；
 * "res:cover_N" 为旧演示源残留记录，统一回落占位图。
 */
export function qgCoverOf(cover: string, sourceId: string): ResourceStr {
  if (cover.startsWith('res:')) {
    return $r('app.media.cover_1');
  }
  if (cover.startsWith('http://') || cover.startsWith('https://')) {
    return QgGateway.imageUrl(cover, QgRepository.coverHeadersOf(sourceId, cover), sourceId);
  }
  return cover;
}

/** 按全局剧集 ID（"源ID:站内ID"）加载封面 */
export function qgCoverOfDramaId(cover: string, dramaId: string): ResourceStr {
  const idx: number = dramaId.indexOf(':');
  return qgCoverOf(cover, idx >= 0 ? dramaId.substring(0, idx) : '');
}

/** 设计令牌（vp / fp），页面内联使用，避免魔法数字四处漂移 */
export class QgUi {
  static readonly GUTTER: number = 20;
  static readonly R_POSTER: number = 18;
  static readonly R_CARD: number = 24;
  static readonly R_PANEL: number = 28;
  static readonly BTN_H: number = 52;
  static readonly TAB_BAR_SPACE: number = 112;
}

/** 海报卡：圆角海报 + 左上角玻璃角标 + 标题 / 副文案 */
@Component
export struct QgDramaCard {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop cover: string = '';
  @Prop cardTitle: string = '';
  @Prop subText: string = '';
  @Prop badge: string = '';
  @Prop sourceId: string = '';
  /** 海报宽高比（宽 / 高），错落瀑布流用不同比例 */
  @Prop ratio: number = 0.72;
  @State pressed: boolean = false;
  onTapCard: () => void = () => {
  };

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        Image(qgCoverOf(this.cover, this.sourceId))
          .width('100%')
          .aspectRatio(this.ratio)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.Medium)
          .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, this.darkOn))
          .borderRadius(QgUi.R_POSTER)

        if (this.badge.length > 0) {
          Text(this.badge)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10)
            .backgroundColor('#40000000')
            .backgroundBlurStyle(BlurStyle.Thin)
            .border({ width: 0.5, color: '#4DFFFFFF' })
            .margin(8)
        }
      }
      .width('100%')

      Text(this.cardTitle)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        .maxLines(2)
        .lineHeight(19)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })
        .padding({ left: 2, right: 2 })
      if (this.subText.length > 0) {
        Text(this.subText)
          .fontSize(11)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
          .padding({ left: 2, right: 2 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .animation({ duration: 260, curve: curves.springMotion(0.4, 0.78) })
    .accessibilityText(this.cardTitle)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onTapCard())
  }
}

/** 区块标题：英文眉题（青柠）+ 粗体中文标题 + 右侧操作 */
@Component
export struct QgSectionTitle {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop title: string = '';
  @Prop eyebrow: string = '';
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Row() {
      Column({ space: 4 }) {
        if (this.eyebrow.length > 0) {
          Text(this.eyebrow.toUpperCase())
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(2.4)
            .fontColor(QgTheme.color('accentInk', this.themeId, this.darkOn))
        }
        Text(this.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bolder)
          .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.actionText.length > 0) {
        Row({ space: 2 }) {
          Text(this.actionText)
            .fontSize(12)
            .fontColor(QgTheme.color('textDim', this.themeId, this.darkOn))
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([QgTheme.color('textDim', this.themeId, this.darkOn)])
        }
        .height(36)
        .padding({ left: 12, right: 8 })
        .borderRadius(18)
        .border({ width: 1, color: QgTheme.color('border', this.themeId, this.darkOn) })
        .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ top: 36, bottom: 16 })
  }
}

/** 空态：青柠圆徽 + 主文案 + 提示 + 可选操作 */
@Component
export struct QgEmptyView {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop iconRes: Resource = $r('sys.symbol.heart');
  @Prop message: string = '';
  @Prop hint: string = '';
  @Prop actionText: string = '';
  @Prop iconTint: ResourceColor | undefined = undefined;
  onAction: () => void = () => {
  };

  build() {
    Column({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.iconRes)
          .fontSize(36)
          .fontColor([this.iconTint !== undefined ? this.iconTint : QgTheme.color('accentInk', this.themeId, this.darkOn)])
      }
      .width(88)
      .height(88)
      .borderRadius(44)
      .backgroundColor(QgTheme.color('accentSoft', this.themeId, this.darkOn))
      .margin({ bottom: 8 })

      Text(this.message)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        .textAlign(TextAlign.Center)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .lineHeight(20)
          .fontColor(QgTheme.color('textFaint', this.themeId, this.darkOn))
          .textAlign(TextAlign.Center)
      }
      if (this.actionText.length > 0) {
        QgPrimaryButton({ label: this.actionText, compact: true, onTap: () => this.onAction() })
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding({ top: 64, bottom: 64, left: 32, right: 32 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 胶囊筛选：选中青柠实底，未选中描边 */
@Component
export struct QgChip {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onSelectChip: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(14)
      .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.selected ? QgTheme.color('accentOn', this.themeId, this.darkOn) : QgTheme.color('textDim', this.themeId, this.darkOn))
      .height(38)
      .padding({ left: 16, right: 16 })
      .borderRadius(19)
      .backgroundColor(this.selected ? QgTheme.color('accent', this.themeId, this.darkOn) : Color.Transparent)
      .border({ width: this.selected ? 0 : 1, color: QgTheme.color('border', this.themeId, this.darkOn) })
      .animation({ duration: 220, curve: curves.springMotion(0.35, 0.8) })
      .accessibilitySelected(this.selected)
      .onClick(() => this.onSelectChip())
  }
}

/** 玻璃圆形图标按钮（返回 / 搜索 / 更多 …） */
@Component
export struct QgIconBtn {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop icon: Resource = $r('sys.symbol.chevron_left');
  @Prop btnSize: number = 44;
  @Prop iconSize: number = 20;
  @Prop label: string = '';
  /** solid=true 用 surfaceHigh 实底（在纯色背景上），否则玻璃材质（压在图片上） */
  @Prop solid: boolean = false;
  @Prop tint: ResourceColor | undefined = undefined;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Stack() {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontWeight(FontWeight.Medium)
        .fontColor([this.tint !== undefined ? this.tint : QgTheme.color('text', this.themeId, this.darkOn)])
    }
    .width(this.btnSize)
    .height(this.btnSize)
    .borderRadius(this.btnSize / 2)
    .backgroundColor(this.solid ? QgTheme.color('surfaceHigh', this.themeId, this.darkOn) : QgTheme.color('glassBg', this.themeId, this.darkOn))
    .backgroundBlurStyle(this.solid ? BlurStyle.NONE : BlurStyle.Thin)
    .border({ width: this.solid ? 0 : 1, color: QgTheme.color('glassStroke', this.themeId, this.darkOn) })
    .alignContent(Alignment.Center)
    .scale({ x: this.pressed ? 0.9 : 1, y: this.pressed ? 0.9 : 1 })
    .animation({ duration: 200, curve: curves.springMotion(0.3, 0.75) })
    .accessibilityText(this.label)
    .onTouch((event: TouchEvent) => {
      this.pressed = event.type === TouchType.Down;
    })
    .onClick(() => this.onTap())
  }
}

/** 返回按钮（保留旧接口名） */
@Component
export struct QgBackBtn {
  @Prop solid: boolean = false;
  onBack: () => void = () => {
  };

  build() {
    QgIconBtn({
      icon: $r('sys.symbol.chevron_left'),
      label: '返回',
      solid: this.solid,
      onTap: () => this.onBack()
    })
  }
}

/** 主按钮：青柠实底全圆胶囊 */
@Component
export struct QgPrimaryButton {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop label: string = '';
  @Prop icon: Resource | undefined = undefined;
  @Prop compact: boolean = false;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 8 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon)
          .fontSize(this.compact ? 15 : 18)
          .fontColor([QgTheme.color('accentOn', this.themeId, this.darkOn)])
      }
      Text(this.label)
        .fontSize(this.compact ? 14 : 16)
        .fontWeight(FontWeight.Bold)
        .fontColor(QgTheme.color('accentOn', this.themeId, this.darkOn))
        .maxLines(1)
    }
    .height(this.compact ? 42 : QgUi.BTN_H)
    .padding({ left: this.compact ? 20 : 26, right: this.compact ? 20 : 26 })
    .borderRadius(this.compact ? 21 : QgUi.BTN_H / 2)
    .backgroundColor(QgTheme.color('accent', this.themeId, this.darkOn))
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
    .animation({ duration: 220, curve: curves.springMotion(0.32, 0.78) })
    .accessibilityText(this.label)
    .onTouch((event: TouchEvent) => {
      this.pressed = event.type === TouchType.Down;
    })
    .onClick(() => this.onTap())
  }
}

/** 次按钮：描边 / 玻璃胶囊 */
@Component
export struct QgGhostButton {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop label: string = '';
  @Prop icon: Resource | undefined = undefined;
  @Prop active: boolean = false;
  @Prop compact: boolean = false;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 7 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon)
          .fontSize(this.compact ? 15 : 17)
          .fontColor([this.active ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('text', this.themeId, this.darkOn)])
      }
      Text(this.label)
        .fontSize(this.compact ? 13 : 15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.active ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('text', this.themeId, this.darkOn))
        .maxLines(1)
    }
    .height(this.compact ? 42 : QgUi.BTN_H)
    .padding({ left: this.compact ? 16 : 22, right: this.compact ? 16 : 22 })
    .borderRadius(this.compact ? 21 : QgUi.BTN_H / 2)
    .backgroundColor(QgTheme.color('glassBg', this.themeId, this.darkOn))
    .backgroundBlurStyle(BlurStyle.Thin)
    .border({ width: 1, color: this.active ? QgTheme.color('accentInk', this.themeId, this.darkOn) : QgTheme.color('glassStroke', this.themeId, this.darkOn) })
    .justifyContent(FlexAlign.Center)
    .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
    .animation({ duration: 220, curve: curves.springMotion(0.32, 0.78) })
    .accessibilityText(this.label)
    .onTouch((event: TouchEvent) => {
      this.pressed = event.type === TouchType.Down;
    })
    .onClick(() => this.onTap())
  }
}

/** 分段控件：surface 胶囊槽 + 青柠选中块 */
@Component
export struct QgSegmented {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop options: string[] = [];
  @Prop selectedIndex: number = 0;
  onSelect: (index: number) => void = () => {
  };

  build() {
    Row() {
      ForEach(this.options, (label: string, idx: number) => {
        Text(label)
          .fontSize(13)
          .fontWeight(this.selectedIndex === idx ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.selectedIndex === idx ? QgTheme.color('accentOn', this.themeId, this.darkOn) : QgTheme.color('textDim', this.themeId, this.darkOn))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(38)
          .borderRadius(19)
          .backgroundColor(this.selectedIndex === idx ? QgTheme.color('accent', this.themeId, this.darkOn) : Color.Transparent)
          .animation({ duration: 240, curve: curves.springMotion(0.35, 0.8) })
          .accessibilitySelected(this.selectedIndex === idx)
          .onClick(() => this.onSelect(idx))
      }, (label: string, idx: number) => `${idx}_${label}`)
    }
    .width('100%')
    .height(46)
    .padding(4)
    .borderRadius(23)
    .backgroundColor(QgTheme.color('surface', this.themeId, this.darkOn))
    .border({ width: 1, color: QgTheme.color('divider', this.themeId, this.darkOn) })
  }
}

/** 页面顶栏：返回 + 标题 + 右侧插槽（纯色背景页使用） */
@Component
export struct QgTopBar {
  @StorageProp('qgTheme') themeId: string = 'lime';
  @StorageProp('darkMode') darkOn: boolean = false;
  @Prop title: string = '';
  @Prop safeTop: number = 0;
  onBack: () => void = () => {
  };
  @BuilderParam trailing: () => void = qgNoop;

  build() {
    Row({ space: 12 }) {
      QgBackBtn({ solid: true, onBack: () => this.onBack() })
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(QgTheme.color('text', this.themeId, this.darkOn))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      this.trailing()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: 8 })
  }
}

@Builder
function qgNoop() {
}
