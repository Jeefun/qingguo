/**
 * 青果APP 数据模型。
 * 参照真果鉴（Xanerix/guoapp）的 models.dart / native_category 结构，适配 ArkTS 强类型。
 * 剧集 id 为全局唯一字符串（"源前缀:站点id"），封面为网络 URL。
 */

/** 剧集（一部短剧） */
export class QgDrama {
  /** 全局唯一 ID：sourceId + ':' + 站点内 ID */
  id: string = '';
  /** 所属站源 ID（hongguo / hanxiaoquan / sorani / huangdou / …，见 QG_SOURCES） */
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
  /** 弹幕标识（红果评论组 id，空表示无弹幕） */
  danmakuId: string = '';
  /** 候选播放地址（多线路，第 1 个为默认线路） */
  routes: string[] = [];
  /** 当前使用的线路下标（routes 中的索引） */
  routeIndex: number = 0;
  /** 可选清晰度列表（如 480/720/1080，空表示无多清晰度） */
  qualities: number[] = [];
  /** 当前清晰度（0 未知） */
  quality: number = 0;
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
  /** 弹幕：显示区域（屏幕高度百分比 25/50/75/100） */
  danmakuArea: number = 75;
  /** 弹幕：屏蔽词列表 */
  danmakuBlockWords: string[] = [];
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

/** 站源描述（设置页 / 源切换展示用） */
export class QgSourceDesc {
  id: string = '';
  /** 展示名（红果 / 韩小圈 …） */
  name: string = '';
  /** 介绍文案 */
  desc: string = '';
  /** 所属分组 id（黄果三源归组 huangguo，其余与 id 相同） */
  groupId: string = '';
  /** 分组展示名 */
  groupName: string = '';
  /** 组内入口名（黄果组：视频/AI/旧版；其余与 name 相同） */
  entryName: string = '';

  constructor(id: string, name: string, desc: string) {
    this.id = id;
    this.name = name;
    this.desc = desc;
    this.groupId = id;
    this.groupName = name;
    this.entryName = name;
  }
}

/** 站源分组信息 */
export class QgSourceGroupInfo {
  id: string = '';
  name: string = '';
  memberIds: string[] = [];

  constructor(id: string, name: string, memberIds: string[]) {
    this.id = id;
    this.name = name;
    this.memberIds = memberIds;
  }
}

/** 全部 15 个站源（对照真果鉴 models.dart SourceSite） */
export const QG_SOURCES: QgSourceDesc[] = [
  qgSrc('hongguo', '红果', '短剧 · 漫剧 · AI 剧'),
  qgSrc('hanxiaoquan', '韩小圈', '韩剧 · 韩国电影 · 综艺动漫'),
  qgSrc('guipian', '鬼片', '鬼片 · 电视剧 · 动漫'),
  qgSrc('sorani', '青空', '番剧 · 剧场动画 · 特摄'),
  qgSrc('huangdou', '黄豆', '精选短剧'),
  qgSrc('huangju', '剧果', '热门 · 最新 · 分类短剧'),
  qgSrc('yeguo', '野果', '分类短剧 · 在线搜索'),
  qgSrc('dsd', '帝果', '分类视频 · 在线搜索'),
  qgSrc('jinguoduanju', '禁果短剧', '推荐 · 分类短剧 · 在线搜索'),
  qgSrc('jinguo', '禁果', '精选 · 最新 · 分类短剧 · 在线搜索'),
  qgSrc('heitao', '黑桃', '分类短剧 · 在线搜索'),
  qgSrc('beabox', '笔盒', '分类视频 · 在线搜索'),
  qgHuangguo('huangguo-video', '黄果视频', '视频剧集', '视频'),
  qgHuangguo('huangguoai', '黄果 AI', 'AI 短剧', 'AI'),
  qgHuangguo('cloudfront', '黄果旧版', '旧 API 剧库', '旧版')
];

function qgSrc(id: string, name: string, desc: string): QgSourceDesc {
  return new QgSourceDesc(id, name, desc);
}

function qgHuangguo(id: string, name: string, desc: string, entryName: string): QgSourceDesc {
  const d: QgSourceDesc = new QgSourceDesc(id, name, desc);
  d.groupId = 'huangguo';
  d.groupName = '黄果';
  d.entryName = entryName;
  return d;
}

/** 按源 id 查描述（找不到返回 undefined） */
export function qgSourceDescOf(id: string): QgSourceDesc | undefined {
  return QG_SOURCES.find((d: QgSourceDesc): boolean => d.id === id);
}

/** 是否为已知源 id */
export function qgIsKnownSource(id: string): boolean {
  return qgSourceDescOf(id) !== undefined;
}

/** 源分组列表（设置页展示顺序：黄果组三源排最后） */
export function qgSourceGroups(): QgSourceGroupInfo[] {
  const groups: QgSourceGroupInfo[] = [];
  const seen: Map<string, QgSourceGroupInfo> = new Map<string, QgSourceGroupInfo>();
  for (let i: number = 0; i < QG_SOURCES.length; i++) {
    const d: QgSourceDesc = QG_SOURCES[i];
    let g: QgSourceGroupInfo | undefined = seen.get(d.groupId);
    if (g === undefined) {
      g = new QgSourceGroupInfo(d.groupId, d.groupName, []);
      seen.set(d.groupId, g);
      groups.push(g);
    }
    g.memberIds.push(d.id);
  }
  return groups;
}
