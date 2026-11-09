/**
 * 青果APP 共享 UI 组件：剧集卡片 / 区块标题 / 空态视图 / 题材胶囊 / 返回按钮。
 */
import { curves } from '@kit.ArkUI';

/**
 * 封面统一出口：网络 URL 直接返回；
 * 演示源本地封面用 "res:cover_N" 约定，映射到打包资源。
 */
export function qgCoverOf(cover: string): ResourceStr {
  if (cover.startsWith('res:')) {
    switch (cover.substring(4)) {
      case 'cover_1': return $r('app.media.cover_1');
      case 'cover_2': return $r('app.media.cover_2');
      case 'cover_3': return $r('app.media.cover_3');
      case 'cover_4': return $r('app.media.cover_4');
      case 'cover_5': return $r('app.media.cover_5');
      case 'cover_6': return $r('app.media.cover_6');
      case 'cover_7': return $r('app.media.cover_7');
      case 'cover_8': return $r('app.media.cover_8');
      case 'cover_9': return $r('app.media.cover_9');
      case 'cover_10': return $r('app.media.cover_10');
      case 'cover_11': return $r('app.media.cover_11');
      case 'cover_12': return $r('app.media.cover_12');
      default: return $r('app.media.cover_1');
    }
  }
  return cover;
}

@Component
export struct QgDramaCard {
  @Prop cover: string = '';
  @Prop cardTitle: string = '';
  @Prop subText: string = '';
  @Prop badge: string = '';
  @Prop pressed: boolean = false;
  onTapCard: () => void = () => {
  };

  build() {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(qgCoverOf(this.cover))
          .width('100%')
          .aspectRatio(0.75)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .interpolation(ImageInterpolation.Medium)
        if (this.badge.length > 0) {
          Text(this.badge)
            .fontSize(10)
            .fontColor($r('app.color.accentOn'))
            .backgroundColor($r('app.color.accent'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
            .margin(6)
        }
      }
      Text(this.cardTitle)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
      Text(this.subText)
        .fontSize(11)
        .fontColor($r('app.color.textFaint'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
    .animation({ duration: 260, curve: curves.springMotion(0.42, 0.75) })
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

@Component
export struct QgSectionTitle {
  @Prop title: string = '';
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Row() {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
      Blank()
      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(13)
          .fontColor($r('app.color.textDim'))
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .padding({ top: 18, bottom: 10 })
  }
}

@Component
export struct QgEmptyView {
  @Prop iconRes: Resource = $r('sys.symbol.heart');
  @Prop message: string = '';
  @Prop hint: string = '';
  @Prop iconTint: Resource = $r('app.color.textFaint');

  build() {
    Column({ space: 10 }) {
      SymbolGlyph(this.iconRes)
        .fontSize(56)
        .fontColor([this.iconTint])
      Text(this.message)
        .fontSize(15)
        .fontColor($r('app.color.textDim'))
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor($r('app.color.textFaint'))
      }
    }
    .width('100%')
    .padding({ top: 72, bottom: 72 })
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct QgChip {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onSelectChip: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(13)
      .fontColor(this.selected ? $r('app.color.accentOn') : $r('app.color.textDim'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.selected ? $r('app.color.accent') : $r('app.color.chipBg'))
      .borderRadius(16)
      .animation({ duration: 240, curve: curves.springMotion(0.4, 0.8) })
      .onClick(() => this.onSelectChip())
  }
}

@Component
export struct QgBackBtn {
  onBack: () => void = () => {
  };

  build() {
    Stack() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor([$r('app.color.text')])
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor($r('app.color.chipBg'))
    .alignContent(Alignment.Center)
    .onClick(() => this.onBack())
  }
}
