/**
 * 演示站源：内置静态剧集数据，公开样例片源按集循环。
 * 无网络也可用，供功能演示与真实源故障时对照排查。
 */
import { QgCategory, QgDrama, QgDramaDetail, QgEpisode, QgPageResult, QgPlayInfo } from '../../model/QgModels';
import { QgSource } from './QgSource';

const SAMPLE_VIDEOS: string[] = [
  'https://media.w3.org/2010/05/sintel/trailer.mp4',
  'https://media.w3.org/2010/05/bunny/trailer.mp4',
  'https://media.w3.org/2010/05/bunny/movie.mp4',
  'https://media.w3.org/2010/05/video/movie_300.mp4'
];

const DEMO_TAGS: Record<string, string[]> = {
  '1': ['甜宠', '先婚后爱', '双向奔赴'],
  '2': ['逆袭', '赘婿', '商战'],
  '3': ['古装', '玄幻', '家国'],
  '4': ['都市', '职场', '成长'],
  '5': ['甜宠', '治愈', '年上'],
  '6': ['重生', '豪门', '复仇'],
  '7': ['田园', '美食', '种田'],
  '8': ['萌宠', '奇幻', '轻松'],
  '9': ['武侠', '江湖', '群像'],
  '10': ['校园', '青春', '暗恋'],
  '11': ['古装', '神医', '爽文'],
  '12': ['科幻', '末世', '爱情']
};

export class DemoSource extends QgSource {
  private dramas: QgDrama[] | null = null;

  constructor() {
    super('demo', '演示');
  }

  categories(): QgCategory[] {
    return [
      new QgCategory('all', '全部'),
      new QgCategory('ongoing', '连载中'),
      new QgCategory('甜宠', '甜宠'),
      new QgCategory('古装', '古装'),
      new QgCategory('武侠', '武侠'),
      new QgCategory('科幻', '科幻')
    ];
  }

  private all(): QgDrama[] {
    if (this.dramas === null) {
      this.dramas = DemoSource.build();
    }
    return this.dramas as QgDrama[];
  }

  async catalogPage(categoryId: string, page: number): Promise<QgPageResult> {
    const list: QgDrama[] = this.filterByCategory(categoryId);
    return new QgPageResult(list, false);
  }

  async search(keyword: string, page: number): Promise<QgPageResult> {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return new QgPageResult([], false);
    }
    const list: QgDrama[] = this.all().filter((d: QgDrama): boolean => {
      return d.title.includes(kw) || d.genre.includes(kw) ||
        d.tags.some((t: string): boolean => t.includes(kw));
    });
    return new QgPageResult(list, false);
  }

  async detail(dramaId: string): Promise<QgDramaDetail> {
    const found: QgDrama | undefined =
      this.all().find((d: QgDrama): boolean => d.id === dramaId);
    if (found === undefined) {
      throw new Error('演示剧集不存在');
    }
    const episodes: QgEpisode[] = [];
    for (let i: number = 1; i <= found.episodeCount; i++) {
      episodes.push(new QgEpisode(`${i}`, `第${i}集`, i));
    }
    return new QgDramaDetail(found, episodes);
  }

  async play(dramaId: string, episodeId: string): Promise<QgPlayInfo> {
    const idx: number = Number(episodeId);
    const index: number = Number.isNaN(idx) || idx < 1 ? 1 : idx;
    const info: QgPlayInfo = new QgPlayInfo();
    info.url = SAMPLE_VIDEOS[(index - 1) % SAMPLE_VIDEOS.length];
    return info;
  }

  private filterByCategory(categoryId: string): QgDrama[] {
    const list: QgDrama[] = this.all();
    if (categoryId === 'all' || categoryId === '') {
      return list;
    }
    if (categoryId === 'ongoing') {
      return list.filter((d: QgDrama): boolean => !d.finished);
    }
    return list.filter((d: QgDrama): boolean => d.genre === categoryId || d.tags.includes(categoryId));
  }

  private static one(id: number, title: string, genre: string, episodes: number,
    finished: boolean, views: string, heat: number, intro: string): QgDrama {
    const d: QgDrama = new QgDrama(`demo:${id}`, title, genre);
    d.sourceId = 'demo';
    d.tags = DEMO_TAGS[`${id}`] !== undefined ? DEMO_TAGS[`${id}`] : [];
    d.episodeCount = episodes;
    d.finished = finished;
    d.viewsText = views;
    d.heat = heat;
    d.intro = intro;
    d.cover = `res:cover_${id}`;
    d.remark = finished ? `全${episodes}集` : `更新至第${episodes}集`;
    return d;
  }

  private static build(): QgDrama[] {
    return [
      DemoSource.one(1, '青果之恋', '甜宠', 80, false, '2.3亿', 9800,
        '江南小城的青果巷里，落魄甜品师苏晚与高冷总裁顾青因一份「青果酥」契约结婚。假戏真做的两个人，在一次次深夜烘焙中把日子过成了糖。'),
      DemoSource.one(2, '逆袭之王', '逆袭', 60, true, '1.8亿', 9100,
        '被赶出家门三年的上门女婿林凡，摇身一变成为万亿集团的幕后掌舵人。这一次，他要拿回属于自己的一切。'),
      DemoSource.one(3, '山海归途', '古装', 100, false, '1.5亿', 8600,
        '大将军之女沈青崖女扮男装镇守边关十年，凯旋之日却遭满门抄斩。重生归来，她要在这山海之间走出一条归途。'),
      DemoSource.one(4, '都市之巅', '都市', 72, false, '1.2亿', 7900,
        '小职员陈默获得「读心」能力，从此在职场步步为营。但能力越大，他越明白：真正的都市之巅，从来不是算计出来的。'),
      DemoSource.one(5, '暖婚似火', '甜宠', 88, true, '1.1亿', 7500,
        '外科医生江暖在雨夜救了重度失眠的建筑师霍屿。她说「我治身」，他说「你治心」，一纸婚约温暖了两座孤岛。'),
      DemoSource.one(6, '重生千金', '重生', 64, true, '9800万', 7000,
        '含冤而死的名门千金重生回到十八岁。前世错付的真心、被夺走的一切，这一世她会一笔一笔全部收回。'),
      DemoSource.one(7, '田园小厨娘', '田园', 56, false, '8600万', 6400,
        '美食博主孟小满一睁眼成了古代山村里的小厨娘。一口铁锅、一方小院，她用美食征服全村，也唤醒了冷面猎户的心。'),
      DemoSource.one(8, '夜色萌宠', '萌宠', 40, true, '7600万', 5900,
        '深夜的宠物诊所里，兽医颜夏能听懂每一只小动物说话。直到某天夜里，一只会说话的黑猫带来了一个改变命运的委托。'),
      DemoSource.one(9, '剑影流光', '武侠', 96, false, '6800万', 5300,
        '江湖失传的「流光剑谱」重现世间，无名小卒谢惊鸿被迫卷入武林纷争。剑影流转处，是少年的一诺千金。'),
      DemoSource.one(10, '校园进行时', '校园', 48, true, '5200万', 4700,
        '高三转学生许星野同桌是全校第一的「冰山学霸」。一张借出的橡皮，开启了整个夏天的怦然心动。'),
      DemoSource.one(11, '神医小娘子', '古装', 84, false, '4500万', 4200,
        '现代中医博士穿越成古代乡下小娘子，一根银针起死回生。看弱女子如何凭借医术名动京城。'),
      DemoSource.one(12, '星河与你', '科幻', 52, true, '3800万', 3600,
        '末世之后，人类迁入地下城。宇航员林河最后一次任务中收到一段来自星河深处的信号——那是一个她以为早已消失的声音。')
    ];
  }
}
