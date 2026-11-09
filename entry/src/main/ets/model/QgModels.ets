/**
 * 青果APP 数据模型。
 * 参照真果鉴（Xanerix/guoapp）的 models.dart / native_category 结构，适配 ArkTS 强类型。
 * 剧集 id 为全局唯一字符串（"源前缀:站点id"），封面为网络 URL。
 */

/** 剧集（一部短剧） */
export class QgDrama {
  /** 全局唯一 ID：sourceId + ':' + 站点内 ID */
  id: string = '';
  /** 所属站源 ID（hongguo / hanxiaoquan / sorani / huangdou / demo） */
  sourceId: string = '';
  title: string = '';
  genre: string = '';
  tags: string[] = [];
  /** 总集数 */
  episodeCount: number = 0;
  /** 是否完结 */
  finished: boolean = true;
  /** 展示用播放量（已格式化，如「2.3亿」） */
  viewsText: string = '';
  /** 热度值（榜单排序用） */
  heat: number = 0;
  intro: string = '';
  /** 封面 URL（网络地址或空） */
  cover: string = '';
  /** 更新说明（如「更新至第30集」） */
  remark: string = '';

  constructor(id: string, title: string, genre: string) {
    this.id = id;
    this.title = title;
    this.genre = genre;
  }
}

/** 分集信息 */
export class QgEpisode {
  /** 站点内视频/分集 ID */
  id: string = '';
  /** 展示标题 */
  title: string = '';
  /** 第几集（1 起） */
  order: number = 1;

  constructor(id: string, title: string, order: number) {
    this.id = id;
    this.title = title;
    this.order = order;
  }
}

/** 详情结果：剧集完整信息 + 分集列表 */
export class QgDramaDetail {
  drama: QgDrama = new QgDrama('', '', '');
  episodes: QgEpisode[] = [];

  constructor(drama: QgDrama, episodes: QgEpisode[]) {
    this.drama = drama;
    this.episodes = episodes;
  }
}

/** 源内分类（发现页筛选 chips） */
export class QgCategory {
  id: string = '';
  label: string = '';

  constructor(id: string, label: string) {
    this.id = id;
    this.label = label;
  }
}

/** 目录页结果 */
export class QgPageResult {
  dramas: QgDrama[] = [];
  hasMore: boolean = false;

  constructor(dramas: QgDrama[], hasMore: boolean) {
    this.dramas = dramas;
    this.hasMore = hasMore;
  }
}

/** 播放地址解析结果 */
export class QgPlayInfo {
  /** 可直连的媒体地址（http/https） */
  url: string = '';
  /** 播放/取流时携带的 Referer */
  referer: string = '';
  /** 额外请求头（如 UA） */
  headers: Record<string, string> = {};
  /** 时长（毫秒，0 未知） */
  durationMs: number = 0;
}

/** 观看记录 */
export class QgWatchRecord {
  dramaId: string = '';
  /** 看到第几集（1 起） */
  episode: number = 1;
  /** 本集播放位置（秒） */
  progress: number = 0;
  /** 本集总时长（秒） */
  duration: number = 0;
  /** 最后观看时间戳（毫秒） */
  updatedAt: number = 0;
  /** 剧集标题快照（跨源展示用） */
  title: string = '';
  /** 封面快照 */
  cover: string = '';
}

/** 追剧记录 */
export class QgFollowRecord {
  dramaId: string = '';
  addedAt: number = 0;
  /** 剧集标题快照 */
  title: string = '';
  /** 封面快照 */
  cover: string = '';
  /** 集数快照 */
  episodeCount: number = 0;
  finished: boolean = true;
  sourceId: string = '';
}

/** 应用设置 */
export class QgAppSettings {
  /** 外观：跟随系统 | 浅色 | 深色 */
  colorMode: string = 'system';
  /** 当前站源 ID */
  sourceId: string = 'hongguo';
  /** 播放：打开播放页自动开始播放 */
  autoPlay: boolean = true;
  /** 播放：播完自动连播下一集 */
  autoNext: boolean = true;
  /** 播放：默认倍速 */
  playSpeed: number = 1;
  /** 弹幕：播放页显示弹幕 */
  danmakuOn: boolean = true;
  /** 弹幕：不透明度 0-100 */
  danmakuOpacity: number = 80;
  /** 弹幕：字号缩放 50-150 */
  danmakuFontSize: number = 100;
  /** 下载：仅 Wi-Fi 下载 */
  downloadWifiOnly: boolean = true;
  /** 下载：同时下载任务数 */
  downloadParallel: number = 2;
  /** 网络：代理开关 */
  proxyOn: boolean = false;
  /** 网络：代理主机 */
  proxyHost: string = '';
  /** 网络：代理端口 */
  proxyPort: number = 7890;
}

/** 详情页路由参数 */
export interface QgDetailParam {
  dramaId: string;
}

/** 播放页路由参数 */
export interface QgPlayerParam {
  dramaId: string;
  episode: number;
}

/** 搜索页路由参数（可带初始关键词） */
export interface QgSearchParam {
  keyword: string;
}
