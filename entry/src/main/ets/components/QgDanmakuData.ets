/**
 * 弹幕数据模型（与渲染组件分离，供站源模块层与弹幕控制器共用）。
 */

/** 通用弹幕条目（渲染层视角，与源解耦） */
export class QgDanmakuItem {
  readonly id: string = '';
  readonly text: string = '';
  readonly timeMs: number = 0;

  constructor(id: string, text: string, timeMs: number) {
    this.id = id;
    this.text = text;
    this.timeMs = timeMs;
  }
}

/** 一页弹幕（一个 30s 时间窗，由站源模块返回） */
export class QgDanmakuPage {
  readonly episodeId: string = '';
  readonly items: QgDanmakuItem[] = [];
  readonly startMs: number = 0;
  /** 下一次拉取的起点（毫秒） */
  readonly nextMs: number = 0;
  /** 弹幕总数（服务端统计） */
  readonly total: number = 0;

  constructor(episodeId: string, items: QgDanmakuItem[], startMs: number, nextMs: number, total: number) {
    this.episodeId = episodeId;
    this.items = items;
    this.startMs = startMs;
    this.nextMs = nextMs;
    this.total = total;
  }
}
