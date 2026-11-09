/**
 * 站源基类与注册管理。
 * 每个站源实现目录分页 / 搜索 / 详情 / 播放地址解析四个能力。
 * 剧集 ID 全局唯一："源ID:站内ID"。
 */
import { QgCategory, QgDramaDetail, QgPageResult, QgPlayInfo } from '../../model/QgModels';

export abstract class QgSource {
  readonly id: string = '';
  readonly name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }

  /** 源内分类（发现页 chips），空数组表示无分类 */
  categories(): QgCategory[] {
    return [];
  }

  /** 目录分页（page 从 1 起） */
  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    return new QgPageResult([], false);
  }

  /** 搜索分页（page 从 1 起） */
  async search(keyword: string, page: number): Promise<QgPageResult> {
    return new QgPageResult([], false);
  }

  /** 剧集详情（含分集列表） */
  abstract detail(dramaId: string): Promise<QgDramaDetail>;

  /** 解析某分集的可播放地址 */
  abstract play(dramaId: string, episodeId: string): Promise<QgPlayInfo>;

  /** 封面/图片加载需要注入的请求头（Referer/UA），默认无 */
  coverHeaders(url: string): Record<string, string> {
    return {};
  }
}

/** 源注册中心 */
export class QgSourceManager {
  private static list: QgSource[] = [];

  static register(source: QgSource): void {
    for (let i: number = 0; i < QgSourceManager.list.length; i++) {
      if (QgSourceManager.list[i].id === source.id) {
        return;
      }
    }
    QgSourceManager.list.push(source);
  }

  static all(): QgSource[] {
    return QgSourceManager.list.slice();
  }

  static byId(id: string): QgSource | undefined {
    return QgSourceManager.list.find((s: QgSource): boolean => s.id === id);
  }

  /** 从全局剧集 ID 中取出站内 ID */
  static siteIdOf(dramaId: string): string {
    const index: number = dramaId.indexOf(':');
    return index >= 0 ? dramaId.substring(index + 1) : dramaId;
  }

  /** 从全局剧集 ID 中取出源 ID */
  static sourceIdOf(dramaId: string): string {
    const index: number = dramaId.indexOf(':');
    return index >= 0 ? dramaId.substring(0, index) : '';
  }
}
