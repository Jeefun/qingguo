import { QgEpisode } from '../model/QgModels';

/** 分组按真实分集排序；倒序、定位均不改变分集的播放编号。 */
export class QgEpisodeCatalog {
  static readonly PAGE_SIZE: number = 30;

  static ordered(episodes: QgEpisode[], descending: boolean): QgEpisode[] {
    return episodes.slice().sort((left: QgEpisode, right: QgEpisode): number =>
      descending ? right.order - left.order : left.order - right.order);
  }

  static groupOf(episodes: QgEpisode[], order: number, descending: boolean): number {
    const index: number = QgEpisodeCatalog.ordered(episodes, descending)
      .findIndex((episode: QgEpisode): boolean => episode.order === order);
    return index < 0 ? 0 : Math.floor(index / QgEpisodeCatalog.PAGE_SIZE);
  }

  static page(episodes: QgEpisode[], group: number, descending: boolean): QgEpisode[] {
    const ordered: QgEpisode[] = QgEpisodeCatalog.ordered(episodes, descending);
    const last: number = Math.max(0, Math.ceil(ordered.length / QgEpisodeCatalog.PAGE_SIZE) - 1);
    const start: number = Math.min(last, Math.max(0, group)) * QgEpisodeCatalog.PAGE_SIZE;
    return ordered.slice(start, start + QgEpisodeCatalog.PAGE_SIZE);
  }

  static labels(episodes: QgEpisode[], descending: boolean): string[] {
    const ordered: QgEpisode[] = QgEpisodeCatalog.ordered(episodes, descending);
    const labels: string[] = [];
    for (let start: number = 0; start < ordered.length; start += QgEpisodeCatalog.PAGE_SIZE) {
      const first: number = ordered[start].order;
      const last: number = ordered[Math.min(start + QgEpisodeCatalog.PAGE_SIZE, ordered.length) - 1].order;
      labels.push(`${Math.min(first, last)}–${Math.max(first, last)}`);
    }
    return labels;
  }

  static locate(episodes: QgEpisode[], input: string): number {
    if (!/^\d+$/.test(input.trim())) return 0;
    const order: number = Number(input.trim());
    return episodes.some((episode: QgEpisode): boolean => episode.order === order) ? order : 0;
  }
}
