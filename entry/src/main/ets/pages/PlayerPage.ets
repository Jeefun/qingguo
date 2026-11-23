import { QgTheme } from '../components/QgTheme';
﻿/**
 * 播放页：Video 组件 + 自定义控制层。
 * - 播放地址经本地媒体网关（QgGateway）注入 Referer/UA；
 * - 弹幕（红果评论弹幕）：QgDanmakuController/View，设置面板可调开关/透明度/字号/区域/屏蔽词；
 * - 手势：单击唤控制层、双击点赞、长按 2x、水平拖动 seek、左半竖滑亮度、右半竖滑音量（AVVolumePanel）、快滑上/下切集；
 * - 断点续播（onPrepared seek）、自动下集（播完直接切下一集）、开播即预取下一集（解析缓存 + CENC 解密预热）、播放失败自动重试 + 换线路；
 * - 倍速 / 线路 / 清晰度 / 选集半模态；全屏横屏切换。
 */
import { curves, display, window } from '@kit.ArkUI';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { QgAppSettings, QgBookmarkRecord, QgDrama, QgDramaDetail, QgEpisode, QgPlayerParam, QgPlayInfo, QgWatchRecord, QgSeason, qgEpisodeLabel } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgGateway } from '../data/QgGateway';
import { QgDiag } from '../data/QgDiag';
import { qgCoverOf } from '../components/QgWidgets';
import { QgDanmakuController, QgDanmakuView } from '../components/QgDanmaku';
import { QgEpisodePicker } from '../components/QgEpisodePicker';

const PLAYER_TAG: string = 'QingGuoPlayer';
const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const HIDE_DELAY: number = 3500;
const RESUME_MIN_SEC: number = 3;
const RESUME_TAIL_SEC: number = 2;
const PRE_RESOLVE_TAIL_SEC: number = 30;
const SAVE_EVERY_SEC: number = 10;
const SEEK_SEC_PER_VP: number = 0.5;
const BRIGHTNESS_PER_VP: number = 0.006;
const BRIGHTNESS_MIN: number = 0.06;
const GESTURE_SETTLE_MS: number = 200;
const FLICK_MAX_MS: number = 320;
const FLICK_MIN_DY: number = 80;
const PAN_MODE_NONE: number = 0;
const PAN_MODE_SEEK: number = 1;
const PAN_MODE_BRIGHT: number = 2;
const PAN_MODE_VOLUME: number = 3;
const PAN_MODE_DEAD: number = 4;
const AREA_OPTIONS: number[] = [25, 50, 75, 100];
const RE_NUMERIC_ID: RegExp = /^[0-9]{1,32}$/;
/** 音频模式定时停止选项（分钟） */
const SLEEP_MINUTES: number[] = [15, 30, 60];

@Component
struct QgPlayerPage {
  @StorageProp('qgTheme') themeId: string = 'lime';
  private stack: NavPathStack = new NavPathStack();
  private controller: VideoController = new VideoController();
  private hideTimer: number = -1;
  private pendingPlay: boolean = false;
  private lastSavedSec: number = -1;
  private dramaId: string = '';
  private lastInfo: QgPlayInfo | undefined = undefined;
  private danmakuCtl: QgDanmakuController = new QgDanmakuController();
  private prewarmedOrder: number = -1;
  private preloadedPlay: Map<string, QgPlayInfo> = new Map<string, QgPlayInfo>();
  private autoRetried: boolean = false;
  private playAttempt: number = 0;
  private panMode: number = PAN_MODE_NONE;
  private panStartX: number = 0;
  private panStartMs: number = 0;
  private panSeekFrom: number = 0;
  private panSeekTarget: number = 0;
  private panBrightStart: number = 0;
  private panVolumeStart: number = 0;
  private brightnessVal: number = -1;
  private savedBrightness: number = -1;
  private volumeReady: boolean = false;
  private volumeMin: number = 0;
  private volumeMax: number = 15;
  private fullscreenChanging: boolean = false;
  private carWindowForPlayback: boolean = false;
  private maximizedForPlayback: boolean = false;
  private contentGeneration: number = 0;
  private seasonRequest: number = 0;
  private seasonListRequest: number = 0;
  private pageActive: boolean = true;
  private advanceWhenSeasonsReady: boolean = false;
  private videoPrepared: boolean = false;
  private seasonScroller: Scroller = new Scroller();
  private sheetScroller: Scroller = new Scroller();

  @State drama: QgDrama | undefined = undefined;
  @State episodes: QgEpisode[] = [];
  @State seasons: QgSeason[] = [];
  @State seasonsLoading: boolean = false;
  @State seasonsError: string = '';
  @State seasonSwitchError: string = '';
  @State switchingSeason: boolean = false;
  @State switchingSeasonId: string = '';
  @State episode: number = 1;
  @State playUrl: string = '';
  @State resolving: boolean = false;
  @State loadErr: string = '';
  @State playing: boolean = false;
  @State controlsShown: boolean = true;
  @State curSec: number = 0;
  @State totalSec: number = 0;
  @State speedIdx: number = 2;
  @State sheetOpen: boolean = false;
  @State sheetTab: string = 'episodes';
  @State seekDragging: boolean = false;
  @State routes: string[] = [];
  @State routeIdx: number = 0;
  @State qualities: number[] = [];
  @State quality: number = 0;
  @State danmakuId: string = '';
  @State danmakuOn: boolean = true;
  @State danmakuArea: number = 75;
  @State danmakuFont: number = 100;
  @State danmakuOpacity: number = 80;
  @State danmakuSheetOpen: boolean = false;
  @State danmakuStatus: string = '';
  @State blockWords: string[] = [];
  @State newWord: string = '';
  @State fullscreen: boolean = false;
  @State playFailed: boolean = false;
  @State playbackError: string = '';
  @State pendingResumeSec: number = 0;
  @State speedBoost: boolean = false;
  @State seekHintText: string = '';
  @State brightnessHintPct: number = -1;
  @State volumeHint: boolean = false;
  @State volumeLevel: number = 8;
  @State likeShow: boolean = false;
  @State likeScale: number = 1;
  @State likeOpacity: number = 0;
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @StorageProp('screenWidth') screenWidth: number = 360;
  @StorageProp('screenHeight') screenHeight: number = 640;
  @StorageProp('darkMode') darkOn: boolean = false;
  @StorageProp('carMode') carOn: boolean = false;
  /** 画幅：false=原始（等比完整显示），true=全屏（拉伸铺满，非等比放大，不裁字幕） */
  @State aspectFill: boolean = false;
  /** 音频分集（听书/广播剧）：隐藏视频画面，渲染大封面音频舞台 */
  @State audioMode: boolean = false;
  /** 定时停止：0=关闭，-1=播完本集停止，>0=分钟数 */
  @State sleepMode: number = 0;
  /** 定时剩余秒数，用于工具栏标签倒计时 */
  @State sleepRemainSec: number = 0;
  private sleepDeadline: number = 0;
  /** 媒体中心会话与后台连续任务：听书/播放锁屏后继续出声 */
  private mediaSession: avSession.AVSession | null = null;
  private bgRunning: boolean = false;
  private lastSessionSyncMs: number = 0;

  private getD(): QgDrama {
    return this.drama as QgDrama;
  }

  private episodeTotal(): number {
    if (this.episodes.length > 0) {
      return this.episodes.length;
    }
    return this.getD().episodeCount;
  }

  private currentEpisode(): QgEpisode | undefined {
    return this.episodes.find((ep: QgEpisode): boolean => ep.order === this.episode);
  }

  /** 当前分集展示名：有章节名用章节名，否则“第 N 集” */
  private episodeLabel(): string {
    const cur: QgEpisode | undefined = this.currentEpisode();
    return cur !== undefined ? qgEpisodeLabel(cur) : `第 ${this.episode} 集`;
  }

  /** 按当前分集的 mediaType 同步音频舞台；音频强制竖屏展示 */
  private syncAudioMode(): void {
    const cur: QgEpisode | undefined = this.currentEpisode();
    this.audioMode = cur !== undefined && cur.audio;
    if (this.audioMode && this.fullscreen) {
      this.exitFullscreen();
    }
  }

  private sleepLabel(): string {
    if (this.sleepMode === -1) {
      return '播完停止';
    }
    if (this.sleepMode > 0) {
      return this.sleepRemainSec > 0 ? `定时${Math.max(1, Math.ceil(this.sleepRemainSec / 60))}分` : `定时${this.sleepMode}分`;
    }
    return '定时';
  }

  private pickSleep(mode: number): void {
    this.sleepMode = mode;
    this.sleepDeadline = mode > 0 ? Date.now() + mode * 60000 : 0;
    this.sleepRemainSec = mode > 0 ? mode * 60 : 0;
    if (mode === 0) {
      this.toast('已取消定时停止');
    } else if (mode === -1) {
      this.toast('本集播完后停止播放');
    } else {
      this.toast(`${mode} 分钟后停止播放`);
    }
  }

  private fireSleepTimeout(): void {
    this.sleepDeadline = 0;
    this.sleepMode = 0;
    this.sleepRemainSec = 0;
    this.stopBgTask();
    try {
      this.controller.pause();
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '定时停止暂停失败');
    }
    this.toast('定时时间到，已停止播放');
  }

  /** 通知栏/媒体控制器点击时拉起应用 */
  private buildLaunchAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    });
  }

  /** 创建媒体中心会话并注册锁屏/耳机播控命令 */
  private async ensureSession(): Promise<void> {
    if (this.mediaSession !== null || !this.pageActive) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      const session: avSession.AVSession = await avSession.createAVSession(
        context, 'qingguoPlayer', this.audioMode ? 'audio' : 'video');
      if (!this.pageActive) {
        session.destroy();
        return;
      }
      this.mediaSession = session;
      session.on('play', () => {
        if (this.playUrl.length > 0) {
          this.controller.start();
        }
      });
      session.on('pause', () => {
        if (this.playUrl.length > 0) {
          this.controller.pause();
        }
      });
      session.on('stop', () => {
        if (this.playUrl.length > 0) {
          this.controller.stop();
        }
      });
      session.on('playNext', () => {
        if (this.episode < this.episodeTotal()) {
          this.pickEpisode(this.episode + 1);
        }
      });
      session.on('playPrevious', () => {
        if (this.episode > 1) {
          this.pickEpisode(this.episode - 1);
        }
      });
      session.on('seek', (time: number) => {
        if (this.playUrl.length > 0) {
          this.controller.setCurrentTime(Math.max(0, Math.round(time / 1000)));
        }
      });
      await session.setLaunchAbility(await this.buildLaunchAgent(context));
      await session.activate();
      await this.pushSessionMetadata();
      QgDiag.log(PLAYER_TAG, '媒体会话已创建');
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '媒体会话创建失败');
    }
  }

  /** 推送曲目元数据（标题/章节/时长）到媒体中心 */
  private async pushSessionMetadata(): Promise<void> {
    const session: avSession.AVSession | null = this.mediaSession;
    if (session === null || this.drama === undefined) {
      return;
    }
    try {
      const meta: avSession.AVMetadata = {
        assetId: `${this.getD().id}:${this.episode}`,
        title: this.getD().title,
        artist: this.episodeLabel(),
        duration: Math.round(this.totalSec * 1000)
      };
      await session.setAVMetadata(meta);
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '更新会话元数据失败');
    }
  }

  /** 推送播放状态（播放/暂停/进度/倍速）；播放中节流，切变时强制 */
  private async pushSessionState(force: boolean): Promise<void> {
    const session: avSession.AVSession | null = this.mediaSession;
    if (session === null) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastSessionSyncMs < 4000) {
      return;
    }
    this.lastSessionSyncMs = now;
    try {
      const state: avSession.AVPlaybackState = {
        state: this.playing
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: this.speedBoost ? 2 : SPEEDS[this.speedIdx],
        position: { elapsedTime: Math.round(this.curSec * 1000), updateTime: now },
        duration: Math.round(this.totalSec * 1000)
      };
      await session.setAVPlaybackState(state);
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '更新会话播放状态失败');
    }
  }

  /** 申请音频播放连续性任务：锁屏/后台继续出声 */
  private async startBgTask(): Promise<void> {
    if (this.bgRunning || !this.pageActive) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      const agent: WantAgent = await this.buildLaunchAgent(context);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgRunning = true;
      QgDiag.log(PLAYER_TAG, '后台播放任务已开启');
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '后台播放任务开启失败');
    }
  }

  /** 取消连续性任务：停止播放或离开播放页时调用 */
  private async stopBgTask(): Promise<void> {
    if (!this.bgRunning) {
      return;
    }
    this.bgRunning = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(getContext(this));
      QgDiag.log(PLAYER_TAG, '后台播放任务已停止');
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '后台播放任务停止失败');
    }
  }

  /** 离开播放页时释放媒体会话 */
  private async teardownSession(): Promise<void> {
    const session: avSession.AVSession | null = this.mediaSession;
    this.mediaSession = null;
    if (session === null) {
      return;
    }
    try {
      await session.deactivate();
      await session.destroy();
      QgDiag.log(PLAYER_TAG, '媒体会话已销毁');
    } catch (error) {
      QgDiag.log(PLAYER_TAG, '媒体会话销毁失败');
    }
  }

  private formatTime(sec: number): string {
    const s: number = Math.max(0, Math.floor(sec));
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = r < 10 ? `0${r}` : `${r}`;
    return `${mm}:${ss}`;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private scheduleHide(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    this.hideTimer = setTimeout(() => {
      if (this.playing) {
        this.controlsShown = false;
      }
    }, HIDE_DELAY);
  }

  private cancelHide(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private saveRecord(): void {
    if (this.drama === undefined || this.dramaId.length === 0 || this.drama.id !== this.dramaId) {
      return;
    }
    if (this.resolving || this.videoPrepared === false || (this.pendingResumeSec > 0 && this.curSec <= 0)) return;
    const r: QgWatchRecord = new QgWatchRecord();
    r.dramaId = this.dramaId;
    r.episode = this.episode;
    r.progress = Math.floor(this.curSec);
    r.duration = Math.floor(this.totalSec);
    r.updatedAt = Date.now();
    r.title = this.getD().title;
    r.cover = this.getD().cover;
    QgStore.getInstance().saveWatch(r);
    AppStorage.setOrCreate('qgWatchTick', (AppStorage.get<number>('qgWatchTick') ?? 0) + 1);
    this.lastSavedSec = this.curSec;
  }

  /** 设置写入（全量拷贝后修改，落盘 + 网络代理等副作用由 QgStore 处理） */
  private patchSettings(mutate: (s: QgAppSettings) => void): void {
    const cur: QgAppSettings = QgStore.getInstance().getSettings();
    const patch: QgAppSettings = new QgAppSettings();
    patch.colorMode = cur.colorMode;
    patch.sourceId = cur.sourceId;
    patch.autoPlay = cur.autoPlay;
    patch.autoNext = cur.autoNext;
    patch.directPlay = cur.directPlay;
    patch.playSpeed = cur.playSpeed;
    patch.videoAspect = cur.videoAspect;
    patch.danmakuOn = cur.danmakuOn;
    patch.danmakuOpacity = cur.danmakuOpacity;
    patch.danmakuFontSize = cur.danmakuFontSize;
    patch.danmakuArea = cur.danmakuArea;
    patch.danmakuBlockWords = cur.danmakuBlockWords.slice();
    patch.downloadWifiOnly = cur.downloadWifiOnly;
    patch.downloadParallel = cur.downloadParallel;
    patch.proxyOn = cur.proxyOn;
    patch.proxyHost = cur.proxyHost;
    patch.proxyPort = cur.proxyPort;
    patch.homeContinue = cur.homeContinue;
    patch.homeRank = cur.homeRank;
    patch.homeRecommendations = cur.homeRecommendations;
    mutate(patch);
    QgStore.getInstance().updateSettings(patch);
  }

  /** 详情加载 + 断点续播定位 */
  private bootstrap(dramaId: string, episode: number): void {
    const generation: number = ++this.contentGeneration;
    this.seasonRequest++;
    this.dramaId = dramaId;
    this.loadErr = '';
    this.loadSeasons(new QgDrama(dramaId, '', ''));
    QgRepository.detail(dramaId)
      .then((detail: QgDramaDetail) => {
        if (!this.pageActive || generation !== this.contentGeneration) return;
        if (detail.episodes.length === 0) throw new Error('本季暂无可播放分集');
        this.drama = detail.drama;
        this.episodes = detail.episodes;
        const total: number = this.episodeTotal();
        this.episode = episode >= 1 && episode <= total ? episode : 1;
        this.syncAudioMode();
        this.pendingResumeSec = 0;
        const rec: QgWatchRecord | undefined = QgStore.getInstance().getWatch(dramaId);
        if (rec !== undefined && rec.episode === this.episode && rec.progress > RESUME_MIN_SEC &&
          (rec.duration <= 0 || rec.progress < rec.duration - RESUME_TAIL_SEC)) {
          this.pendingResumeSec = rec.progress;
        }
        this.pendingPlay = QgStore.getInstance().getSettings().autoPlay;
        this.resolvePlay();
      })
      .catch((error: BusinessError) => {
        if (!this.pageActive || generation !== this.contentGeneration) return;
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  private loadSeasons(drama: QgDrama): void {
    const ticket: number = ++this.seasonListRequest;
    const generation: number = this.contentGeneration;
    this.seasonsLoading = true;
    this.seasonsError = '';
    QgRepository.seasons(drama).then((seasons: QgSeason[]): void => {
      if (!this.pageActive || ticket !== this.seasonListRequest || generation !== this.contentGeneration) return;
      this.seasons = seasons;
      this.seasonsLoading = false;
      if (this.advanceWhenSeasonsReady) {
        this.advanceWhenSeasonsReady = false;
        if (!this.switchingSeason && QgStore.getInstance().getSettings().autoNext &&
          this.drama !== undefined && this.episode === this.episodeTotal()) {
          const next: QgSeason | undefined = this.nextSeason();
          if (next !== undefined) this.selectSeason(next, false);
        }
      }
    }).catch((error: Error): void => {
      if (!this.pageActive || ticket !== this.seasonListRequest || generation !== this.contentGeneration) return;
      this.seasonsLoading = false;
      this.advanceWhenSeasonsReady = false;
      this.seasonsError = error.message || '分季信息加载失败';
    });
  }

  private nextSeason(): QgSeason | undefined {
    const index: number = this.seasons.findIndex((season: QgSeason): boolean => season.drama.id === this.dramaId);
    return index >= 0 ? this.seasons[index + 1] : undefined;
  }

  private seasonLabel(): string {
    const current: QgSeason | undefined = this.seasons.find((season: QgSeason): boolean => season.drama.id === this.dramaId);
    return current !== undefined ? `第 ${current.number} 季 · 共 ${this.seasons.length} 季` : '系列分季';
  }

  private currentSeasonNumber(): string {
    const current: QgSeason | undefined = this.seasons.find((season: QgSeason): boolean => season.drama.id === this.dramaId);
    return current !== undefined && this.seasons.length > 1 ? `第 ${current.number} 季 · ` : '';
  }

  private openPlayerSheet(tab: string): void {
    this.cancelHide();
    this.sheetTab = tab;
    this.sheetOpen = true;
  }

  private seasonProgress(season: QgSeason): string {
    if (season.drama.id === this.dramaId) return `正在看第 ${this.episode} 集`;
    const record: QgWatchRecord | undefined = QgStore.getInstance().getWatch(season.drama.id);
    return record !== undefined && record.episode > 0 ? `上次看到第 ${record.episode} 集` : '未观看';
  }

  private async selectSeason(season: QgSeason, resume: boolean = true): Promise<void> {
    if (!this.pageActive || this.drama === undefined) return;
    if (season.drama.id === this.dramaId) {
      this.seasonRequest++;
      this.switchingSeason = false;
      this.switchingSeasonId = '';
      this.seasonSwitchError = '';
      return;
    }
    if (!this.seasons.some((item: QgSeason): boolean => item.drama.id === season.drama.id)) return;
    const ticket: number = ++this.seasonRequest;
    const generation: number = this.contentGeneration;
    this.switchingSeason = true;
    this.switchingSeasonId = season.drama.id;
    this.seasonSwitchError = '';
    this.advanceWhenSeasonsReady = false;
    this.saveRecord();
    try {
      const detail: QgDramaDetail = await QgRepository.detail(season.drama.id);
      if (!this.pageActive || ticket !== this.seasonRequest || generation !== this.contentGeneration) return;
      if (detail.drama.id !== season.drama.id || detail.episodes.length === 0) {
        throw new Error('所选季暂时没有可播放分集');
      }
      this.saveRecord();
      this.playAttempt++;
      this.contentGeneration++;
      this.cancelHide();
      const wasPlaying: boolean = this.playUrl.length > 0;
      this.playUrl = '';
      this.pendingPlay = false;
      this.playing = false;
      if (wasPlaying) {
        try { this.controller.stop(); } catch (error) { QgDiag.log('Player', '切季时停止旧视频失败'); }
      }
      this.preloadedPlay.clear();
      this.prewarmedOrder = -1;
      this.lastInfo = undefined;
      this.routes = [];
      this.routeIdx = 0;
      this.qualities = [];
      this.quality = 0;
      this.curSec = 0;
      this.totalSec = 0;
      this.lastSavedSec = -1;
      this.pendingResumeSec = 0;
      this.seekDragging = false;
      this.panMode = PAN_MODE_NONE;
      this.speedBoost = false;
      this.danmakuId = '';
      this.danmakuCtl.setSource('', '');
      this.dramaId = detail.drama.id;
      this.drama = detail.drama;
      this.episodes = detail.episodes;
      const record: QgWatchRecord | undefined = resume ? QgStore.getInstance().getWatch(this.dramaId) : undefined;
      const episode: QgEpisode | undefined = record !== undefined ?
        this.episodes.find((item: QgEpisode): boolean => item.order === record.episode) : undefined;
      this.episode = episode !== undefined ? episode.order : this.episodes[0].order;
      this.syncAudioMode();
      if (record !== undefined && episode !== undefined && record.progress > RESUME_MIN_SEC &&
        (record.duration <= 0 || record.progress < record.duration - RESUME_TAIL_SEC)) {
        this.pendingResumeSec = record.progress;
      }
      this.playFailed = false;
      this.playbackError = '';
      this.autoRetried = false;
      this.controlsShown = true;
      this.pendingPlay = true;
      this.sheetOpen = false;
      this.danmakuSheetOpen = false;
      this.loadSeasons(detail.drama);
      this.resolvePlay();
    } catch (error) {
      if (!this.pageActive || ticket !== this.seasonRequest || generation !== this.contentGeneration) return;
      const failure: Error = error as Error;
      this.seasonSwitchError = failure.message || '切换分季失败，请重试';
      this.controlsShown = true;
      this.sheetTab = 'episodes';
      this.sheetOpen = true;
    } finally {
      if (ticket === this.seasonRequest) {
        this.switchingSeason = false;
        this.switchingSeasonId = '';
      }
    }
  }

  private onPlaybackFinished(): void {
    if (!this.pageActive) return;
    this.saveRecord();
    this.playing = false;
    this.driveDanmaku();
    this.controlsShown = true;
    // 定时停止（播完本集）：到本集末尾即停，不自动续播
    if (this.sleepMode === -1) {
      this.sleepMode = 0;
      this.sleepRemainSec = 0;
      this.stopBgTask();
      this.toast('本集播完，已停止播放');
      return;
    }
    if (!this.pageActive || this.switchingSeason || !QgStore.getInstance().getSettings().autoNext) {
      this.stopBgTask();
      return;
    }
    if (this.episode < this.episodeTotal()) {
      this.pickEpisode(this.episode + 1);
      return;
    }
    const next: QgSeason | undefined = this.nextSeason();
    if (next !== undefined) {
      this.selectSeason(next, false);
    } else {
      this.advanceWhenSeasonsReady = this.seasonsLoading;
      if (!this.seasonsLoading) {
        this.stopBgTask();
      }
    }
  }

  private videoIdentity(): string {
    return `${this.contentGeneration}:${this.playAttempt}:${this.playUrl}`;
  }

  private isCurrentVideo(identity: string): boolean {
    return this.pageActive && this.playUrl.length > 0 && identity === this.videoIdentity();
  }

  /** 解析当前分集播放地址（走网关）；命中预取缓存时跳过网络请求，切集秒开 */
  private resolvePlay(): void {
    const attempt: number = ++this.playAttempt;
    this.videoPrepared = false;
    const dramaId: string = this.dramaId;
    const ep: QgEpisode | undefined = this.currentEpisode();
    if (ep === undefined) {
      this.loadErr = '分集不存在';
      return;
    }
    const cached: QgPlayInfo | undefined = this.preloadedPlay.get(ep.id);
    if (cached !== undefined) {
      this.resolving = false;
      hilog.info(0x0001, PLAYER_TAG, `ep${ep.order} hit preloaded play info`);
      this.applyPlayInfo(cached);
      return;
    }
    this.resolving = true;
    this.playUrl = '';
    this.curSec = 0;
    this.totalSec = 0;
    this.lastSavedSec = -1;
    this.loadErr = '';
    this.playFailed = false;
    this.playbackError = '';
    this.autoRetried = false;
    QgGateway.ready()
      .then((): Promise<QgPlayInfo> => {
        if (!this.pageActive || attempt !== this.playAttempt || dramaId !== this.dramaId) {
          throw new Error('播放请求已取消');
        }
        return QgRepository.play(dramaId, ep.id);
      })
      .then((info: QgPlayInfo) => {
        if (!this.pageActive || attempt !== this.playAttempt || dramaId !== this.dramaId) return;
        this.resolving = false;
        this.applyPlayInfo(info);
      })
      .catch((error: BusinessError) => {
        if (!this.pageActive || attempt !== this.playAttempt || dramaId !== this.dramaId) return;
        this.resolving = false;
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '播放地址解析失败';
      });
  }

  /** 应用播放信息（网络解析与预取缓存共用） */
  private applyPlayInfo(info: QgPlayInfo): void {
    this.playUrl = '';
    this.curSec = 0;
    this.totalSec = 0;
    this.lastSavedSec = -1;
    this.loadErr = '';
    this.playFailed = false;
    this.playbackError = '';
    this.autoRetried = false;
    if (info.url.length === 0) {
      this.loadErr = '未能解析到播放地址';
      return;
    }
    this.lastInfo = info;
    this.routes = info.routes.length > 0 ? info.routes.slice() : [info.url];
    this.routeIdx = Math.min(Math.max(info.routeIndex, 0), this.routes.length - 1);
    this.qualities = info.qualities.slice();
    this.quality = info.quality;
    this.danmakuId = info.danmakuId;
    if (info.durationMs > 0) {
      this.totalSec = info.durationMs / 1000;
    }
    this.setupDanmaku();
    // 网关没起来时 mediaUrl 会退回原始地址，而 Video 组件无法注入防盗链头。
    // 明确告知，避免只看到「一直在转圈」却不知道原因。
    if (!QgGateway.isRunning() &&
      (info.referer.length > 0 || Object.keys(info.headers).length > 0)) {
      this.toast('媒体网关未启动，无法注入防盗链请求头，可能无法播放');
    }
    this.applyRoute(this.routeIdx, true);
  }

  /** 应用线路：包装网关地址；resume=true 用断点位置，false 保持当前进度 */
  private applyRoute(idx: number, resume: boolean, automaticRetry: boolean = false): void {
    const info: QgPlayInfo | undefined = this.lastInfo;
    if (info === undefined || idx < 0 || idx >= this.routes.length) {
      return;
    }
    if (!resume) {
      this.pendingResumeSec = this.curSec > 1 ? this.curSec : 0;
    }
    this.routeIdx = idx;
    this.videoPrepared = false;
    this.playAttempt++;
    this.playFailed = false;
    this.playbackError = '';
    if (!automaticRetry) {
      this.autoRetried = false;
    }
    this.loadErr = '';
    const headers: Record<string, string> = {};
    const keys: string[] = Object.keys(info.headers);
    for (let i: number = 0; i < keys.length; i++) {
      headers[keys[i]] = info.headers[keys[i]];
    }
    if (info.referer.length > 0 && headers['Referer'] === undefined) {
      headers['Referer'] = info.referer;
    }
    const needHeaders: boolean = info.referer.length > 0 || Object.keys(headers).length > 0;
    // CENC 加密媒体必须走网关解密端点（下载 + AES-CTR 就地解密 + Range 下发）。
    // 不需要注入请求头的 https 源直接交给 Video，绕开本地 http 网关：
    // HarmonyOS API 20+ 默认拦截明文流量，多一跳本地代理就多一个失败点。
    if (info.cencKey.length === 32) {
      this.playUrl = QgGateway.decryptedMediaUrl(this.routes[idx], headers, info.cencKey, this.sourceIdOf());
    } else if (!needHeaders && this.routes[idx].startsWith('https://')) {
      this.playUrl = this.routes[idx];
    } else {
      this.playUrl = QgGateway.mediaUrl(this.routes[idx], headers, this.sourceIdOf());
    }
    this.pendingPlay = true;
  }

  /** 当前剧集所属站源 ID（dramaId 形如 "源ID:站内ID"），按站源代理用 */
  private sourceIdOf(): string {
    const idx: number = this.dramaId.indexOf(':');
    return idx >= 0 ? this.dramaId.substring(0, idx) : '';
  }

  private onVideoError(error: BusinessError): void {
    this.playing = false;
    this.controlsShown = true;
    this.playbackError = error !== undefined && error.code !== undefined ? `播放失败（${error.code}）：${error.message}` :
      '播放失败，请重试或切换线路';
    QgDiag.log('Player', `episode=${this.episode} route=${this.routeIdx + 1} ${this.playbackError}`);
    if (!this.autoRetried && this.playUrl.length > 0) {
      this.autoRetried = true;
      const attempt: number = this.playAttempt;
      // 移除失败的 Video 实例，再用同一地址创建新实例才能真正重试。
      this.playUrl = '';
      setTimeout(() => {
        if (this.playAttempt === attempt) {
          this.applyRoute(this.routeIdx, false, true);
        }
      }, 1200);
    } else {
      this.playFailed = true;
    }
  }

  /** 播放失败后从头重试：同一集同一线路，清零进度与断点，从 0 开始播放 */
  private retryFromStart(): void {
    this.pendingResumeSec = 0;
    this.curSec = 0;
    this.applyRoute(this.routeIdx, true);
  }

  /** 车机（超级桌面）大屏触控放大：控制层字号/控件 ×1.5，方便车机上点选 */
  private ufs(size: number): number {
    return this.carOn ? Math.round(size * 1.5) : size;
  }

  /**
   * 画幅切换（底部按钮）：原始画幅 ⇄ 全屏。
   * - 原始：Contain 等比完整显示，多余区域由外层深色底承担；
   * - 全屏：Fill 拉伸铺满——是拉伸而非等比放大（等比放大到高度撑满会超出
   *   屏幕、裁掉底部内嵌字幕），拉伸保证画面与字幕完整可见。
   * 选择持久化到设置，换集/重启后保持。
   */
  private toggleAspect(): void {
    this.aspectFill = !this.aspectFill;
    this.patchSettings((s: QgAppSettings): void => {
      s.videoAspect = this.aspectFill ? 'fill' : 'original';
    });
    this.toast(this.aspectFill ? '全屏（拉伸铺满）' : '原始画幅');
  }

  /** 弹幕源与设置接线 */
  private setupDanmaku(): void {
    const settings: QgAppSettings = QgStore.getInstance().getSettings();
    this.danmakuCtl.setDanmakuOn(this.danmakuOn);
    this.danmakuCtl.setBlockWords(settings.danmakuBlockWords);
    this.danmakuStatus = this.danmakuCtl.statusText();
    if (this.danmakuId.length === 0) {
      return;
    }
    const idx: number = this.dramaId.indexOf(':');
    const seriesId: string = idx >= 0 ? this.dramaId.substring(idx + 1) : '';
    if (!RE_NUMERIC_ID.test(seriesId) || !RE_NUMERIC_ID.test(this.danmakuId)) {
      return;
    }
    this.danmakuCtl.setSource(seriesId, this.danmakuId);
    this.danmakuStatus = this.danmakuCtl.statusText();
  }

  private driveDanmaku(): void {
    this.danmakuCtl.update(this.curSec * 1000, this.totalSec * 1000,
      this.speedBoost ? 2 : SPEEDS[this.speedIdx], this.playing, false);
    this.danmakuStatus = this.danmakuCtl.statusText();
  }

  /**
   * 预取下一集，缩短切集等待：
   * - 解析结果存 preloadedPlay（按分集 id，≤3 条 FIFO），切集时直接命中、跳过源站解析；
   * - CENC 加密集同步预热网关解密缓存（下载 + 解密提前入内存，与播放共用 decCache）；
   * - 普通流式源（m3u8 等）由 Video 拉流，仅预解析地址，不缓存视频数据。
   * 播放开始即预取；片尾 30s 兜底重试（预取失败时）。
   */
  private prewarmNext(): void {
    const generation: number = this.contentGeneration;
    const dramaId: string = this.dramaId;
    const nextOrder: number = this.episode + 1;
    if (nextOrder > this.episodeTotal() || this.prewarmedOrder === nextOrder) {
      return;
    }
    const ep: QgEpisode | undefined = this.episodes.find((e: QgEpisode): boolean => e.order === nextOrder);
    if (ep === undefined) {
      return;
    }
    this.prewarmedOrder = nextOrder;
    // 每个 nextOrder 只预取一次（失败不重试，避免片尾兜底触发高频重试）；
    // 失败时切集回退常规解析，行为与无预取一致。
    QgRepository.play(dramaId, ep.id)
      .then((info: QgPlayInfo): void => {
        if (!this.pageActive || generation !== this.contentGeneration || dramaId !== this.dramaId) return;
        if (info.url.length === 0) {
          return;
        }
        this.preloadedPlay.set(ep.id, info);
        while (this.preloadedPlay.size > 3) {
          const oldest: string | undefined = this.preloadedPlay.keys().next().value;
          if (oldest === undefined) {
            break;
          }
          this.preloadedPlay.delete(oldest);
        }
        hilog.info(0x0001, PLAYER_TAG,
          `prewarmed ep${nextOrder} cenc=${info.cencKey.length === 32} cached=${this.preloadedPlay.size}`);
        if (info.cencKey.length === 32) {
          this.prewarmCenc(info);
        }
      })
      .catch((): void => {
        // 预取失败不重试（prewarmedOrder 保持已置位），切集走常规解析
      });
  }

  /** CENC 加密集：提前下载解密入网关内存缓存，切集时 Range 请求直接命中 */
  private prewarmCenc(info: QgPlayInfo): void {
    const headers: Record<string, string> = {};
    const keys: string[] = Object.keys(info.headers);
    for (let i: number = 0; i < keys.length; i++) {
      headers[keys[i]] = info.headers[keys[i]];
    }
    if (info.referer.length > 0 && headers['Referer'] === undefined) {
      headers['Referer'] = info.referer;
    }
    const upstream: string = info.routes.length > 0 ? info.routes[info.routeIndex] : info.url;
    QgGateway.prewarmDecrypted(upstream, headers, info.cencKey, this.sourceIdOf())
      .then((): void => {
        hilog.info(0x0001, PLAYER_TAG, `cenc prewarmed: ${info.danmakuId}`);
      })
      .catch((): void => {
        // 预热失败不影响正常切集（切集走网关时会重新下载解密）
      });
  }

  private togglePlay(): void {
    if (this.playing) {
      this.controller.pause();
    } else {
      this.controller.start();
    }
  }

  private addBookmark(): void {
    if (this.drama === undefined || this.curSec < 1) {
      this.toast('播放后才能添加片段书签');
      return;
    }
    const record: QgBookmarkRecord = new QgBookmarkRecord();
    record.dramaId = this.drama.id;
    record.title = this.drama.title;
    record.episode = this.episode;
    record.seconds = this.curSec;
    record.createdAt = Date.now();
    QgStore.getInstance().addBookmark(record);
    AppStorage.setOrCreate('qgBookmarkTick', (AppStorage.get<number>('qgBookmarkTick') ?? 0) + 1);
    this.toast(`已标记 ${this.formatTime(this.curSec)}`);
  }

  private skipIntro(): void {
    if (this.totalSec <= 0) {
      return;
    }
    const saved: number = this.drama === undefined ? 0 : QgStore.getInstance().getIntroMark(this.drama.id);
    const target: number = saved > 0 ? saved : Math.min(90, Math.max(0, this.totalSec - 2));
    if (saved <= 0 && this.drama !== undefined) {
      QgStore.getInstance().setIntroMark(this.drama.id, target);
    }
    if (this.curSec < target) {
      this.controller.setCurrentTime(target);
      this.curSec = target;
      this.saveRecord();
      this.toast(`已跳过片头 ${this.formatTime(target)}`);
    } else {
      this.toast('当前已超过片头位置');
    }
  }

  private pickEpisode(ep: number): void {
    if (!this.pageActive || this.switchingSeason || this.drama === undefined || ep < 1 ||
      ep > this.episodeTotal()) {
      return;
    }
    if (ep === this.episode) {
      this.sheetOpen = false;
      return;
    }
    this.saveRecord();
    this.advanceWhenSeasonsReady = false;
    this.episode = ep;
    this.syncAudioMode();
    this.pendingResumeSec = 0;
    this.pendingPlay = true;
    this.sheetOpen = false;
    this.resolvePlay();
  }

  private prevEpisode(): void {
    this.pickEpisode(this.episode - 1);
  }

  private nextEpisode(): void {
    if (this.episode < this.episodeTotal()) {
      this.pickEpisode(this.episode + 1);
    } else {
      const next: QgSeason | undefined = this.nextSeason();
      if (next !== undefined) this.selectSeason(next, false);
    }
  }

  private pickSpeed(idx: number): void {
    if (idx < 0 || idx >= SPEEDS.length || idx === this.speedIdx) {
      return;
    }
    this.speedIdx = idx;
    this.patchSettings((s: QgAppSettings): void => {
      s.playSpeed = SPEEDS[idx];
    });
    this.driveDanmaku();
  }

  private pickQuality(q: number): void {
    if (q === this.quality) {
      return;
    }
    this.pendingResumeSec = this.curSec > 1 ? this.curSec : 0;
    this.quality = q;
    this.sheetOpen = false;
    this.resolvePlay();
  }

  private speedIndexOf(playSpeed: number): number {
    let best: number = 2;
    let bestDiff: number = Number.MAX_SAFE_INTEGER;
    for (let i: number = 0; i < SPEEDS.length; i++) {
      const diff: number = Math.abs(SPEEDS[i] - playSpeed);
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  // ---------- 弹幕设置 ----------

  private toggleDanmaku(on: boolean): void {
    this.danmakuOn = on;
    this.danmakuCtl.setDanmakuOn(on);
    this.danmakuStatus = this.danmakuCtl.statusText();
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuOn = on;
    });
  }

  private setDanmakuOpacity(v: number): void {
    this.danmakuOpacity = v;
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuOpacity = v;
    });
  }

  private setDanmakuFont(v: number): void {
    this.danmakuFont = v;
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuFontSize = v;
    });
  }

  private setDanmakuArea(v: number): void {
    this.danmakuArea = v;
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuArea = v;
    });
  }

  private addBlockWord(): void {
    const w: string = this.newWord.trim();
    if (w.length === 0 || this.blockWords.includes(w)) {
      this.newWord = '';
      return;
    }
    const words: string[] = this.blockWords.slice();
    words.push(w);
    this.blockWords = words;
    this.newWord = '';
    this.danmakuCtl.setBlockWords(words);
    this.danmakuStatus = this.danmakuCtl.statusText();
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuBlockWords = words.slice();
    });
  }

  private removeBlockWord(w: string): void {
    const words: string[] = this.blockWords.filter((x: string): boolean => x !== w);
    this.blockWords = words;
    this.danmakuCtl.setBlockWords(words);
    this.danmakuStatus = this.danmakuCtl.statusText();
    this.patchSettings((s: QgAppSettings): void => {
      s.danmakuBlockWords = words.slice();
    });
  }

  // ---------- 手势 ----------

  private onSingleTap(): void {
    if (this.controlsShown) {
      this.cancelHide();
      this.controlsShown = false;
    } else {
      this.controlsShown = true;
      if (this.playing) {
        this.scheduleHide();
      }
    }
  }

  private onDoubleTap(): void {
    this.likeShow = true;
    this.likeScale = 0.5;
    this.likeOpacity = 1;
    this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseOut }, (): void => {
      this.likeScale = 1.2;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseIn }, (): void => {
        this.likeOpacity = 0;
        this.likeScale = 0.9;
      });
    }, 260);
    setTimeout(() => {
      this.likeShow = false;
    }, 620);
  }

  private startBoost(): void {
    if (!this.playing || this.speedBoost) {
      return;
    }
    this.speedBoost = true;
    this.cancelHide();
    this.driveDanmaku();
  }

  private stopBoost(): void {
    if (!this.speedBoost) {
      return;
    }
    this.speedBoost = false;
    this.driveDanmaku();
    if (this.playing) {
      this.scheduleHide();
    }
  }

  private initVolumeOnce(): void {
    if (this.volumeReady) {
      return;
    }
    try {
      const mgr: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
      this.volumeMin = mgr.getMinVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.volumeMax = mgr.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.volumeLevel = mgr.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.volumeReady = true;
    } catch (error) {
      this.volumeReady = false;
    }
  }

  private applyBrightness(v: number): void {
    window.getLastWindow(getContext(this))
      .then((win: window.Window): Promise<void> => {
        return win.setWindowBrightness(v);
      })
      .catch((): void => {
      });
  }

  private onPanStart(event: GestureEvent): void {
    this.panMode = PAN_MODE_NONE;
    const fingers: FingerInfo[] = event.fingerList;
    this.panStartX = fingers.length > 0 ? fingers[0].globalX : this.screenWidth / 2;
    this.panStartMs = Date.now();
    this.panSeekFrom = this.curSec;
    this.panSeekTarget = this.curSec;
  }

  private onPanUpdate(event: GestureEvent): void {
    if (this.panMode === PAN_MODE_NONE) {
      if (Date.now() - this.panStartMs < GESTURE_SETTLE_MS) {
        return;
      }
      const dx: number = event.offsetX;
      const dy: number = event.offsetY;
      if (Math.abs(dx) > Math.abs(dy)) {
        if (this.totalSec > 0) {
          this.panMode = PAN_MODE_SEEK;
          this.danmakuCtl.beginSeek();
          this.cancelHide();
        } else {
          this.panMode = PAN_MODE_DEAD;
        }
      } else if (this.brightnessVal >= 0 && this.panStartX < this.screenWidth / 2) {
        this.panMode = PAN_MODE_BRIGHT;
        this.panBrightStart = this.brightnessVal;
        this.cancelHide();
      } else {
        this.initVolumeOnce();
        this.panMode = this.volumeReady ? PAN_MODE_VOLUME : PAN_MODE_DEAD;
        this.panVolumeStart = this.volumeLevel;
        this.cancelHide();
      }
    }
    if (this.panMode === PAN_MODE_SEEK) {
      const delta: number = event.offsetX * SEEK_SEC_PER_VP;
      let target: number = this.panSeekFrom + delta;
      target = Math.max(0, Math.min(target, this.totalSec));
      this.panSeekTarget = target;
      this.curSec = target;
      this.seekHintText = `${delta >= 0 ? '快进' : '快退'} ${Math.abs(Math.round(delta))}秒（${this.formatTime(target)} / ${this.formatTime(this.totalSec)}）`;
    } else if (this.panMode === PAN_MODE_BRIGHT) {
      let v: number = this.panBrightStart - event.offsetY * BRIGHTNESS_PER_VP;
      v = Math.max(BRIGHTNESS_MIN, Math.min(v, 1));
      this.brightnessVal = v;
      this.brightnessHintPct = Math.round(v * 100);
      this.applyBrightness(v);
    } else if (this.panMode === PAN_MODE_VOLUME) {
      const span: number = this.volumeMax - this.volumeMin;
      if (span <= 0) {
        return;
      }
      const levelPerVp: number = span / 220;
      let lv: number = Math.round(this.panVolumeStart - event.offsetY * levelPerVp);
      lv = Math.max(this.volumeMin, Math.min(lv, this.volumeMax));
      this.volumeLevel = lv;
      this.volumeHint = true;
    }
  }

  private onPanEnd(event: GestureEvent): void {
    const duration: number = Date.now() - this.panStartMs;
    const dy: number = event.offsetY;
    if (this.panMode === PAN_MODE_NONE || this.panMode === PAN_MODE_DEAD) {
      if (duration < FLICK_MAX_MS && Math.abs(dy) > FLICK_MIN_DY && Math.abs(dy) > Math.abs(event.offsetX)) {
        if (dy < 0) {
          this.nextEpisode();
        } else {
          this.prevEpisode();
        }
      }
    } else if (this.panMode === PAN_MODE_SEEK) {
      this.controller.setCurrentTime(this.panSeekTarget);
      this.curSec = this.panSeekTarget;
      this.danmakuCtl.endSeek(this.panSeekTarget * 1000);
      this.seekHintText = '';
      this.saveRecord();
      this.driveDanmaku();
      if (this.playing) {
        this.scheduleHide();
      }
    } else if (this.panMode === PAN_MODE_BRIGHT) {
      setTimeout(() => {
        this.brightnessHintPct = -1;
      }, 600);
    } else if (this.panMode === PAN_MODE_VOLUME) {
      setTimeout(() => {
        this.volumeHint = false;
      }, 600);
    }
    this.panMode = PAN_MODE_NONE;
  }

  // ---------- 全屏 ----------

  private async isCarWindow(win: window.Window): Promise<boolean> {
    if (this.carOn) {
      return true;
    }
    const props: window.WindowProperties = win.getWindowProperties();
    if (typeof props.displayId === 'number' && props.displayId > 0) {
      return true;
    }
    try {
      const displays: display.Display[] = await display.getAllDisplays();
      if (displays.length > 1) {
        return true;
      }
      const activeDisplay: display.Display = displays.length > 0
        ? displays[0]
        : display.getDefaultDisplaySync();
      const widthVp: number = activeDisplay.width / Math.max(activeDisplay.densityPixels, 1);
      const landscape: boolean = activeDisplay.width > activeDisplay.height;
      const status: window.WindowStatusType = win.getWindowStatus();
      const freeformDesktop: boolean =
        status === window.WindowStatusType.FLOATING || status === window.WindowStatusType.MAXIMIZE;
      // 高 DPI 车机上宽屏 vp 可能不足 960，自由窗口状态同样说明是超级桌面。
      return landscape && (freeformDesktop || widthVp >= 960);
    } catch (error) {
      return false;
    }
  }

  private logWindowError(action: string, error: BusinessError): void {
    hilog.warn(0x0001, PLAYER_TAG, `${action} 失败 code=${error.code} message=${error.message}`);
  }

  private async requestPlaybackLandscape(win: window.Window): Promise<void> {
    try {
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
    } catch (primaryError) {
      this.logWindowError('setPreferredOrientation(LANDSCAPE)', primaryError as BusinessError);
      try {
        await win.setPreferredOrientation(window.Orientation.USER_ROTATION_LANDSCAPE);
      } catch (fallbackError) {
        this.logWindowError('setPreferredOrientation(USER_ROTATION_LANDSCAPE)', fallbackError as BusinessError);
      }
    }
  }

  private async findPlaybackDisplay(win: window.Window): Promise<display.Display | undefined> {
    const props: window.WindowProperties = win.getWindowProperties();
    const windowDisplayId: number = typeof props.displayId === 'number' ? props.displayId : 0;
    const displays: display.Display[] = await display.getAllDisplays();
    for (let i: number = 0; i < displays.length; i++) {
      if (displays[i].id === windowDisplayId) {
        return displays[i];
      }
    }
    let landscapeDisplay: display.Display | undefined = undefined;
    for (let i: number = 0; i < displays.length; i++) {
      const item: display.Display = displays[i];
      if (item.width <= item.height) {
        continue;
      }
      if (landscapeDisplay === undefined ||
        item.width * item.height > landscapeDisplay.width * landscapeDisplay.height) {
        landscapeDisplay = item;
      }
    }
    return landscapeDisplay;
  }

  /**
   * 超级桌面里的播放页可能是浮窗。resize/move 只在 FLOATING 状态有效，
   * 因此必须在 maximize 之前按车机显示尺寸预调整，最大化后不再改窗口矩形。
   */
  private async prepareFloatingPlaybackWindow(win: window.Window): Promise<void> {
    try {
      if (win.getWindowStatus() !== window.WindowStatusType.FLOATING) {
        return;
      }
      const target: display.Display | undefined = await this.findPlaybackDisplay(win);
      if (target === undefined) {
        hilog.warn(0x0001, PLAYER_TAG, 'floating prepare skipped: no display');
        return;
      }
      const rect: window.Rect = win.getWindowProperties().windowRect;
      if (target.width - rect.width <= 48 && target.height - rect.height <= 48) {
        return;
      }
      try {
        await win.setWindowLimits({
          maxWidth: target.width,
          maxHeight: target.height,
          minWidth: Math.min(320, target.width),
          minHeight: Math.min(320, target.height)
        } as window.WindowLimits);
      } catch (limitError) {
        this.logWindowError('setWindowLimits(playback)', limitError as BusinessError);
      }
      try {
        await win.resizeAsync(target.width, target.height);
        await win.moveWindowToAsync(0, 0);
      } catch (resizeError) {
        this.logWindowError('prepare floating playback', resizeError as BusinessError);
      }
      const after: window.Rect = win.getWindowProperties().windowRect;
      hilog.info(0x0001, PLAYER_TAG,
        `floating prepare display=${target.id} rect=${after.width}x${after.height} target=${target.width}x${target.height}`);
    } catch (error) {
      this.logWindowError('prepareFloatingPlaybackWindow', error as BusinessError);
    }
  }

  private async hideCarWindowDecor(win: window.Window): Promise<void> {
    try {
      win.setWindowDecorVisible(false);
    } catch (error) {
      this.logWindowError('setWindowDecorVisible(false)', error as BusinessError);
    }
    try {
      await win.setTitleAndDockHoverShown(false, false);
    } catch (error) {
      this.logWindowError('setTitleAndDockHoverShown(false)', error as BusinessError);
    }
  }

  private async showCarWindowDecor(win: window.Window): Promise<void> {
    try {
      win.setWindowDecorVisible(true);
    } catch (error) {
      this.logWindowError('setWindowDecorVisible(true)', error as BusinessError);
    }
    try {
      await win.setTitleAndDockHoverShown(true, true);
    } catch (error) {
      this.logWindowError('setTitleAndDockHoverShown(true)', error as BusinessError);
    }
  }

  private async hideSystemBars(win: window.Window): Promise<void> {
    try {
      await win.setWindowSystemBarEnable([]);
    } catch (error) {
      this.logWindowError('setWindowSystemBarEnable([])', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('status', false, false);
    } catch (error) {
      this.logWindowError('hide status bar', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('navigation', false, false);
    } catch (error) {
      this.logWindowError('hide navigation bar', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('navigationIndicator', false, false);
    } catch (error) {
      this.logWindowError('hide navigation indicator', error as BusinessError);
    }
  }

  private async showSystemBars(win: window.Window): Promise<void> {
    try {
      await win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (error) {
      this.logWindowError('setWindowSystemBarEnable(status,navigation)', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('status', true, false);
    } catch (error) {
      this.logWindowError('show status bar', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('navigation', true, false);
    } catch (error) {
      this.logWindowError('show navigation bar', error as BusinessError);
    }
    try {
      await win.setSpecificSystemBarEnabled('navigationIndicator', true, false);
    } catch (error) {
      this.logWindowError('show navigation indicator', error as BusinessError);
    }
  }

  private async enterFullscreen(): Promise<void> {
    if (this.fullscreenChanging) {
      return;
    }
    this.fullscreenChanging = true;
    this.fullscreen = true;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const status: window.WindowStatusType = win.getWindowStatus();
      this.carWindowForPlayback = await this.isCarWindow(win);
      this.maximizedForPlayback = status !== window.WindowStatusType.FULL_SCREEN;

      if (this.carWindowForPlayback) {
        try {
          await win.enableLandscapeMultiWindow();
        } catch (error) {
          this.logWindowError('enableLandscapeMultiWindow', error as BusinessError);
        }
      }

      try {
        await win.setWindowLayoutFullScreen(true);
      } catch (error) {
        this.logWindowError('setWindowLayoutFullScreen(true)', error as BusinessError);
      }
      await this.requestPlaybackLandscape(win);

      if (this.carWindowForPlayback) {
        await this.prepareFloatingPlaybackWindow(win);
      }

      if (this.carWindowForPlayback || this.maximizedForPlayback) {
        try {
          await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
        } catch (maxError) {
          this.logWindowError('maximize immersive', maxError as BusinessError);
          try {
            await win.maximize();
          } catch (retryError) {
            this.logWindowError('maximize fallback', retryError as BusinessError);
          }
        }
      }

      if (this.carWindowForPlayback) {
        // maximize 后再落标题栏/Dock 热区设置，保证这是最后一次生效的调用。
        await this.hideCarWindowDecor(win);
      }
      await this.hideSystemBars(win);
      const after: window.Rect = win.getWindowProperties().windowRect;
      hilog.info(0x0001, PLAYER_TAG,
        `enter fullscreen car=${this.carWindowForPlayback} status=${win.getWindowStatus()} rect=${after.width}x${after.height}`);
    } catch (error) {
      this.fullscreen = false;
      this.logWindowError('enterFullscreen', error as BusinessError);
    } finally {
      this.fullscreenChanging = false;
    }
  }

  private async exitFullscreen(restoreWindow: boolean = true): Promise<void> {
    if (this.fullscreenChanging) {
      return;
    }
    this.fullscreenChanging = true;
    this.fullscreen = false;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const onCar: boolean = this.carWindowForPlayback || await this.isCarWindow(win);
      if (onCar) {
        await this.showCarWindowDecor(win);
      }
      await this.showSystemBars(win);
      try {
        await win.setPreferredOrientation(onCar
          ? window.Orientation.LANDSCAPE
          : window.Orientation.AUTO_ROTATION_PORTRAIT);
      } catch (error) {
        this.logWindowError('restore playback orientation', error as BusinessError);
      }
      // 超级桌面退出播放后继续保持铺满；普通手机从多窗全屏返回时才恢复原窗口。
      if (restoreWindow && !onCar && this.maximizedForPlayback) {
        try {
          await win.restore();
        } catch (error) {
          this.logWindowError('restore window', error as BusinessError);
        }
      }
    } catch (error) {
      this.logWindowError('exitFullscreen', error as BusinessError);
    } finally {
      this.maximizedForPlayback = false;
      this.fullscreenChanging = false;
    }
  }

  private async toggleFullscreen(): Promise<void> {
    if (this.fullscreen) {
      await this.exitFullscreen();
    } else {
      await this.enterFullscreen();
    }
  }

  private restoreOrientation(): void {
    if (!this.fullscreen) {
      return;
    }
    this.exitFullscreen(false).catch((): void => {
    });
  }

  private async initBrightness(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const props: window.WindowProperties = win.getWindowProperties();
      this.brightnessVal = props.brightness;
      this.savedBrightness = props.brightness;
    } catch (error) {
      this.brightnessVal = -1;
    }
  }

  private restoreBrightness(): void {
    if (this.savedBrightness < 0) {
      return;
    }
    window.getLastWindow(getContext(this))
      .then((win: window.Window): Promise<void> => {
        return win.setWindowBrightness(this.savedBrightness);
      })
      .catch((): void => {
      });
  }

  private async applyPlayerBar(playerActive: boolean): Promise<void> {
    AppStorage.setOrCreate('playerActive', playerActive);
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const contentColor: string = playerActive || this.darkOn ? '#FFFFFF' : '#191919';
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      } as window.SystemBarProperties);
    } catch (error) {
      // 状态栏设置失败不影响播放
    }
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.contentGeneration++;
    this.seasonRequest++;
    this.seasonListRequest++;
    this.advanceWhenSeasonsReady = false;
    this.playAttempt++;
    this.saveRecord();
    this.cancelHide();
    this.stopBgTask();
    this.teardownSession();
    if (this.playUrl.length > 0) {
      this.controller.stop();
    }
    this.restoreOrientation();
    this.restoreBrightness();
    this.applyPlayerBar(false);
  }

  build() {
    NavDestination() {
      if (this.drama === undefined && this.loadErr.length > 0) {
        this.FullErrorBuilder()
      } else if (this.drama === undefined) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(38)
            .height(38)
            .color(QgTheme.color('accent', this.themeId, true))
          Text('正在准备影院舞台…')
            .fontSize(13)
            .fontColor(QgTheme.color('playerDim', this.themeId, true))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(QgTheme.color('playerBg', this.themeId, true))
      } else {
        this.StageBuilder()
      }
    }
    .hideTitleBar(true)
    .backgroundColor(QgTheme.color('playerBg', this.themeId, true))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .onBackPressed((): boolean => {
      if (this.fullscreen) {
        this.exitFullscreen();
        return true;
      }
      return false;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pageActive = true;
      this.stack = ctx.pathStack;
      const p = ctx.pathInfo.param as QgPlayerParam;
      if (p === undefined || p === null || typeof p.dramaId !== 'string' || p.dramaId.length === 0) {
        this.loadErr = '缺少播放参数';
        return;
      }
      const settings: QgAppSettings = QgStore.getInstance().getSettings();
      this.speedIdx = this.speedIndexOf(settings.playSpeed);
      this.aspectFill = settings.videoAspect === 'fill';
      this.danmakuOn = settings.danmakuOn;
      this.danmakuArea = settings.danmakuArea;
      this.danmakuFont = settings.danmakuFontSize;
      this.danmakuOpacity = settings.danmakuOpacity;
      this.blockWords = settings.danmakuBlockWords.slice();
      this.controlsShown = true;
      this.bootstrap(p.dramaId, p.episode);
      this.applyPlayerBar(true);
      this.initBrightness();
      this.scheduleHide();
    })
  }

  @Builder
  FullErrorBuilder() {
    Column({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.movie_slash'))
          .fontSize(38)
          .fontColor([QgTheme.color('playerDim', this.themeId, true)])
      }
      .width(80)
      .height(80)
      .borderRadius(40)
      .backgroundColor('#1AFFFFFF')

      Text(this.loadErr)
        .fontSize(14)
        .fontColor(QgTheme.color('playerDim', this.themeId, true))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })

      Row({ space: 12 }) {
        Text('返回')
          .fontSize(14)
          .fontColor(QgTheme.color('playerText', this.themeId, true))
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .borderRadius(20)
          .backgroundColor('#26FFFFFF')
          .onClick(() => this.stack.pop())

        Text('重试')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('accentOn', this.themeId, true))
          .padding({ left: 24, right: 24, top: 10, bottom: 10 })
          .borderRadius(20)
          .backgroundColor(QgTheme.color('accent', this.themeId, true))
          .onClick(() => {
            this.loadErr = '';
            this.bootstrap(this.dramaId, this.episode);
          })
      }
      .padding({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(QgTheme.color('playerBg', this.themeId, true))
  }

  @Builder
  StageBuilder() {
    Stack() {
      if (this.playUrl.length > 0) {
        ForEach([this.videoIdentity()], (identity: string) => {
        Video({
          src: this.playUrl,
          controller: this.controller,
          currentProgressRate: this.speedBoost ? 2 : SPEEDS[this.speedIdx],
          previewUri: qgCoverOf(this.getD().cover, this.getD().sourceId)
        })
          .autoPlay(false)
          .controls(false)
          .objectFit(this.aspectFill ? ImageFit.Fill : ImageFit.Contain)
          .width('100%')
          .height('100%')
          .onPrepared((info: PreparedInfo) => {
            if (!this.isCurrentVideo(identity)) return;
            this.videoPrepared = true;
            if (info.duration > 0) {
              this.totalSec = info.duration;
            }
            if (this.pendingResumeSec > 0) {
              if (this.totalSec <= 0 || this.pendingResumeSec < this.totalSec - 1) {
                this.controller.setCurrentTime(this.pendingResumeSec);
                this.curSec = this.pendingResumeSec;
                this.toast('已从上次位置继续播放');
              }
              this.pendingResumeSec = 0;
            }
            if (this.pendingPlay) {
              this.pendingPlay = false;
              this.controller.start();
            }
            this.driveDanmaku();
            this.prewarmNext();
            this.ensureSession();
          })
          .onUpdate((event) => {
            if (!this.isCurrentVideo(identity)) return;
            if (this.seekDragging || this.panMode === PAN_MODE_SEEK) {
              return;
            }
            this.curSec = event.time;
            if (this.sleepDeadline > 0) {
              this.sleepRemainSec = Math.max(0, Math.ceil((this.sleepDeadline - Date.now()) / 1000));
              if (Date.now() >= this.sleepDeadline) {
                this.fireSleepTimeout();
                return;
              }
            }
            this.driveDanmaku();
            if (this.lastSavedSec < 0 || Math.abs(this.curSec - this.lastSavedSec) >= SAVE_EVERY_SEC) {
              this.saveRecord();
            }
            if (this.totalSec > 0 && this.totalSec - this.curSec <= PRE_RESOLVE_TAIL_SEC) {
              this.prewarmNext();
            }
            this.pushSessionState(false);
          })
          .onStart(() => {
            if (!this.isCurrentVideo(identity)) return;
            this.advanceWhenSeasonsReady = false;
            this.playing = true;
            this.scheduleHide();
            this.driveDanmaku();
            this.ensureSession().then((): void => {
              this.pushSessionMetadata();
              this.pushSessionState(true);
            });
            this.startBgTask();
          })
          .onPause(() => {
            if (!this.isCurrentVideo(identity)) return;
            this.advanceWhenSeasonsReady = false;
            this.playing = false;
            this.controlsShown = true;
            this.cancelHide();
            this.saveRecord();
            this.driveDanmaku();
            this.pushSessionState(true);
          })
          .onFinish(() => {
            if (!this.isCurrentVideo(identity)) return;
            this.onPlaybackFinished();
          })
          .onError((error: BusinessError) => {
            if (!this.isCurrentVideo(identity)) return;
            this.onVideoError(error);
          })
        }, (identity: string) => identity)
      } else {
        Column({ space: 12 }) {
          if (this.loadErr.length > 0) {
            SymbolGlyph($r('sys.symbol.movie_slash'))
              .fontSize(44)
              .fontColor([QgTheme.color('playerDim', this.themeId, true)])
            Text(this.loadErr)
              .fontSize(13)
              .fontColor(QgTheme.color('playerDim', this.themeId, true))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Text('重试')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(QgTheme.color('accentOn', this.themeId, true))
              .padding({ left: 24, right: 24, top: 10, bottom: 10 })
              .borderRadius(20)
              .backgroundColor(QgTheme.color('accent', this.themeId, true))
              .onClick(() => {
                this.resolvePlay();
              })
          } else {
            LoadingProgress()
              .width(36)
              .height(36)
              .color(QgTheme.color('accent', this.themeId, true))
            Text('解析播放地址…')
              .fontSize(13)
              .fontColor(QgTheme.color('playerDim', this.themeId, true))
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 音频舞台：盖住视频表面，模糊封面背景 + 居中大封面 + 章节标题
      if (this.audioMode && this.playUrl.length > 0) {
        this.AudioStageBuilder()
      }

      if (!this.audioMode && this.danmakuOn && this.danmakuId.length > 0 && this.playUrl.length > 0) {
        Column() {
          QgDanmakuView({
            controller: this.danmakuCtl,
            areaPercent: this.danmakuArea,
            fontScale: this.danmakuFont,
            opacityPercent: this.danmakuOpacity
          })
        }
        .width('100%')
        .height('100%')
        .padding({
          top: this.fullscreen ? 12 : this.safeTop + 60,
          bottom: this.fullscreen ? 0 : this.safeBottom
        })
        .hitTestBehavior(HitTestMode.None)
      }

      AVVolumePanel({
        volumeLevel: this.volumeLevel,
        volumeParameter: { position: { x: -100, y: -100 } }
      })
        .width(1)
        .height(1)

      if (this.playUrl.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .gesture(GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 })
              .onAction(() => {
                this.onDoubleTap();
              }),
            TapGesture({ count: 1 })
              .onAction(() => {
                this.onSingleTap();
              }),
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.startBoost();
              })
              .onActionEnd(() => {
                this.stopBoost();
              }),
            PanGesture({ fingers: 1, distance: 8 })
              .onActionStart((event: GestureEvent) => {
                this.onPanStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onPanUpdate(event);
              })
              .onActionEnd((event: GestureEvent) => {
                this.onPanEnd(event);
              })
          ))
      }

      if (this.seekHintText.length > 0) {
        this.HintPillBuilder(this.seekHintText)
      }
      if (this.brightnessHintPct >= 0) {
        this.HintPillBuilder(`亮度 ${this.brightnessHintPct}%`)
      }
      if (this.volumeHint) {
        this.HintPillBuilder(`音量 ${this.volumeLevel}/${this.volumeMax}`)
      }
      if (this.speedBoost) {
        this.HintPillBuilder('2.0x 倍速快进中')
      }

      if (this.likeShow) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(68)
          .fontColor([QgTheme.color('accent', this.themeId, true)])
          .scale({ x: this.likeScale, y: this.likeScale })
          .opacity(this.likeOpacity)
      }

      if (this.playFailed) {
        this.PlayFailBuilder()
      }

      if (this.controlsShown) {
        this.OverlayBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetOpen, this.SheetInnerBuilder(), {
      detents: [SheetSize.LARGE],
      dragBar: true,
      backgroundColor: QgTheme.color('surface', this.themeId, true)
    })
  }

  @Builder
  HintPillBuilder(text: string) {
    Text(text)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(Color.White)
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .borderRadius(22)
      .backgroundColor('#CC101210')
      .backdropBlur(20)
      .border({ width: 1, color: '#33' + QgTheme.color('accent', this.themeId, true).substring(1) })
  }

  @Builder
  PlayFailBuilder() {
    Column({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.movie_slash'))
        .fontSize(44)
        .fontColor([QgTheme.color('playerDim', this.themeId, true)])
      Text(this.playbackError.length > 0 ? this.playbackError : '播放失败，请重试或切换线路')
        .fontSize(13)
        .fontColor(QgTheme.color('playerDim', this.themeId, true))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Row({ space: 10 }) {
        Text('重试')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('accentOn', this.themeId, true))
          .padding({ left: 22, right: 22, top: 9, bottom: 9 })
          .borderRadius(20)
          .backgroundColor(QgTheme.color('accent', this.themeId, true))
          .onClick(() => {
            this.applyRoute(this.routeIdx, false);
          })
        if (this.curSec > 0 || this.pendingResumeSec > 0) {
          Text('从头播放')
            .fontSize(14)
            .fontColor(QgTheme.color('playerText', this.themeId, true))
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .borderRadius(20)
            .backgroundColor('#33FFFFFF')
            .onClick(() => {
              this.retryFromStart();
            })
        }
        if (this.routes.length > 1) {
          Text('换线路')
            .fontSize(14)
            .fontColor(QgTheme.color('playerText', this.themeId, true))
            .padding({ left: 20, right: 20, top: 9, bottom: 9 })
            .borderRadius(20)
            .backgroundColor('#33FFFFFF')
            .onClick(() => {
              this.applyRoute((this.routeIdx + 1) % this.routes.length, false);
            })
        }
        Text('返回')
          .fontSize(14)
          .fontColor(QgTheme.color('playerDim', this.themeId, true))
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .borderRadius(20)
          .backgroundColor('#1FFFFFFF')
          .onClick(() => {
            this.stack.pop();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(QgTheme.veil('B3', this.themeId, true))
  }

  /** 音频（听书/广播剧）舞台：模糊封面铺底，居中大圆角封面 + 章节标题 + 剧集名 */
  @Builder
  AudioStageBuilder() {
    Stack() {
      Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(50)
        .opacity(0.55)

      Column() {
        Blank()
        Column({ space: this.ufs(16) }) {
          Stack() {
            Image(qgCoverOf(this.getD().cover, this.getD().sourceId))
              .width('52%')
              .aspectRatio(1)
              .objectFit(ImageFit.Cover)
              .borderRadius(this.ufs(18))
              .clip(true)
              .shadow({ radius: this.ufs(28), color: '#66000000', offsetX: 0, offsetY: this.ufs(10) })
              .opacity(this.playing ? 1 : 0.78)
              .animation({ duration: 260, curve: Curve.EaseOut })
            if (!this.playing) {
              SymbolGlyph($r('sys.symbol.pause'))
                .fontSize(this.ufs(34))
                .fontColor([Color.White])
            }
          }
          .width('100%')
          .alignContent(Alignment.Center)

          Text(this.episodeLabel())
            .fontSize(this.ufs(19))
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .padding({ left: this.ufs(28), right: this.ufs(28) })

          Text(this.getD().title)
            .fontSize(this.ufs(12))
            .fontColor(QgTheme.color('playerDim', this.themeId, true))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: this.ufs(28), right: this.ufs(28) })
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        Blank()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E6050507')
  }

  @Builder
  OverlayBuilder() {
    Column() {
      // 顶部悬浮玻璃栏
      Row({ space: this.ufs(12) }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(this.ufs(20))
            .fontColor([Color.White])
        }
        .width(this.ufs(42))
        .height(this.ufs(42))
        .borderRadius(this.ufs(21))
        .backgroundColor('#4D101210')
        .backgroundBlurStyle(BlurStyle.Thin)
        .border({ width: 1, color: '#38FFFFFF' })
        .accessibilityText('返回')
        .onClick(() => {
          this.saveRecord();
          if (this.fullscreen) {
            this.exitFullscreen();
          } else {
            this.stack.pop();
          }
        })

        Column({ space: this.ufs(3) }) {
          Text(this.getD().title)
            .fontSize(this.ufs(17))
            .fontWeight(FontWeight.Bolder)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.episodeLabel()} · 共 ${this.episodeTotal()} 集${this.carOn ? ' · 车机' : ''}`)
            .fontSize(this.ufs(12))
            .fontColor(QgTheme.color('playerDim', this.themeId, true))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.PlayerToolBuilder('设置', () => {
          this.openPlayerSheet('settings');
        })
      }
      .width('100%')
      .padding({
        left: this.ufs(18),
        right: this.ufs(18),
        top: this.fullscreen ? 12 : this.safeTop + 8,
        bottom: this.ufs(22)
      })
      .linearGradient({ angle: 180, colors: [['#CC000000', 0], ['#00000000', 1]] })

      Blank()

      // 中央播放控制器：仅在视频已就绪且未报错时显示，避免压住加载/错误提示
      if (this.playUrl.length > 0 && !this.playFailed) {
        Row({ space: this.ufs(32) }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(this.ufs(22))
              .fontColor([Color.White])
          }
          .width(this.ufs(48))
          .height(this.ufs(48))
          .borderRadius(this.ufs(24))
          .backgroundColor('#4D101210')
          .backgroundBlurStyle(BlurStyle.Thin)
          .border({ width: 1, color: '#38FFFFFF' })
          .opacity(this.episode > 1 ? 1 : 0.35)
          .enabled(this.episode > 1)
          .accessibilityText('上一集')
          .onClick(() => this.prevEpisode())

          Stack() {
            SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
              .fontSize(this.ufs(30))
              .fontColor([QgTheme.color('accentOn', this.themeId, true)])
          }
          .width(this.ufs(72))
          .height(this.ufs(72))
          .borderRadius(this.ufs(36))
          .backgroundColor(QgTheme.color('accent', this.themeId, true))
          .shadow({ radius: 24, color: '#55' + QgTheme.color('accent', this.themeId, true).substring(1), offsetX: 0, offsetY: 6 })
          .accessibilityText(this.playing ? '暂停' : '播放')
          .onClick(() => this.togglePlay())

          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(this.ufs(22))
              .fontColor([Color.White])
          }
          .width(this.ufs(48))
          .height(this.ufs(48))
          .borderRadius(this.ufs(24))
          .backgroundColor('#4D101210')
          .backgroundBlurStyle(BlurStyle.Thin)
          .border({ width: 1, color: '#38FFFFFF' })
          .opacity(this.episode < this.episodeTotal() || this.nextSeason() !== undefined ? 1 : 0.35)
          .enabled(this.episode < this.episodeTotal() || this.nextSeason() !== undefined)
          .accessibilityText(this.episode < this.episodeTotal() ? '下一集' : '下一季')
          .onClick(() => this.nextEpisode())
        }
      }

      Blank()

      // 底部进度条 + 玻璃胶囊工具条
      Column({ space: this.ufs(10) }) {
        Row() {
          Text(this.formatTime(this.curSec))
            .fontSize(this.ufs(12))
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
          Text(` / ${this.formatTime(this.totalSec)}`)
            .fontSize(this.ufs(12))
            .fontColor(QgTheme.color('playerDim', this.themeId, true))
          Blank()
          if (!this.audioMode) {
            Stack() {
              SymbolGlyph(this.fullscreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') :
                $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                .fontSize(this.ufs(18))
                .fontColor([Color.White])
            }
            .width(this.ufs(38))
            .height(this.ufs(38))
            .borderRadius(this.ufs(19))
            .backgroundColor('#66101210')
            .border({ width: 1, color: '#24FFFFFF' })
            .accessibilityText(this.fullscreen ? '退出全屏' : '全屏播放')
            .onClick(() => this.toggleFullscreen())
          }
        }
        .width('100%')

        Slider({ value: this.curSec, min: 0, max: this.totalSec > 0 ? this.totalSec : 100 })
          .selectedColor(QgTheme.color('accent', this.themeId, true))
          .trackColor(QgTheme.color('trackOff', this.themeId, true))
          .blockColor(Color.White)
          .trackThickness(this.ufs(3))
          .blockSize({ width: this.ufs(14), height: this.ufs(14) })
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              this.seekDragging = true;
              this.cancelHide();
              this.danmakuCtl.beginSeek();
            } else if (mode === SliderChangeMode.End) {
              this.seekDragging = false;
              this.controller.setCurrentTime(value);
              this.curSec = value;
              this.danmakuCtl.endSeek(value * 1000);
              this.driveDanmaku();
              this.saveRecord();
              if (this.playing) {
                this.scheduleHide();
              }
            }
          })

        Scroll() {
          Row({ space: this.ufs(8) }) {
            this.PlayerToolBuilder('选集', () => {
              this.openPlayerSheet('episodes');
            }, true)
            if (this.seasons.length > 1 || this.seasonsError.length > 0) {
              this.PlayerToolBuilder('分季', () => {
                this.openPlayerSheet('episodes');
              })
            }
            this.PlayerToolBuilder(`${SPEEDS[this.speedIdx]}x`, () => {
              this.openPlayerSheet('settings');
            })
            if (this.audioMode) {
              this.PlayerToolBuilder(this.sleepLabel(), () => {
                this.openPlayerSheet('settings');
              })
            }
            if (!this.audioMode && this.danmakuId.length > 0) {
              this.PlayerToolBuilder(this.danmakuOn ? '弹幕开' : '弹幕关', () => this.toggleDanmaku(!this.danmakuOn))
              this.PlayerToolBuilder('弹幕设置', () => {
                this.cancelHide();
                this.danmakuStatus = this.danmakuCtl.statusText();
                this.danmakuSheetOpen = true;
              })
            }
            if (!this.audioMode) {
              this.PlayerToolBuilder(this.aspectFill ? '全屏画幅' : '原始画幅', () => this.toggleAspect())
              this.PlayerToolBuilder(this.fullscreen ? '竖屏' : '横屏', () => this.toggleFullscreen())
            }
            this.PlayerToolBuilder('书签', () => this.addBookmark())
            this.PlayerToolBuilder('跳片头', () => this.skipIntro())
            if (this.routes.length > 1) {
              this.PlayerToolBuilder(`线路 ${this.routeIdx + 1}`, () => {
                this.openPlayerSheet('settings');
              })
            }
            if (this.qualities.length > 1) {
              this.PlayerToolBuilder(this.quality > 0 ? `${this.quality}P` : '清晰度', () => {
                this.openPlayerSheet('settings');
              })
            }
          }
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .padding({
        left: this.ufs(20),
        right: this.ufs(20),
        top: this.ufs(14),
        bottom: this.fullscreen ? this.ufs(16) : this.safeBottom + this.ufs(18)
      })
      .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#E6000000', 1]] })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .bindSheet($$this.danmakuSheetOpen, this.DanmakuSheetBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      backgroundColor: QgTheme.color('surface', this.themeId, true)
    })
  }

  @Builder
  PlayerToolBuilder(label: string, action: () => void, highlight: boolean = false) {
    Text(label)
      .fontSize(this.ufs(12))
      .fontWeight(highlight ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(highlight ? QgTheme.color('accentOn', this.themeId, true) : Color.White)
      .height(this.ufs(36))
      .padding({ left: this.ufs(14), right: this.ufs(14) })
      .borderRadius(this.ufs(18))
      .backgroundColor(highlight ? QgTheme.color('accent', this.themeId, true) : '#4D101210')
      .backgroundBlurStyle(highlight ? BlurStyle.NONE : BlurStyle.Thin)
      .border({ width: highlight ? 0 : 1, color: '#38FFFFFF' })
      .textAlign(TextAlign.Center)
      .onClick(() => action())
  }

  @Builder
  SectionTitleBuilder(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(QgTheme.color('text', this.themeId, true))
      .width('100%')
      .padding({ top: 16, bottom: 10 })
  }

  @Builder
  SeasonPickerBuilder() {
    if (this.seasonsLoading && this.seasons.length < 2) {
      Row({ space: 8 }) {
        LoadingProgress().width(18).height(18).color(QgTheme.color('accent', this.themeId, true))
        Text('正在获取分季').fontSize(12).fontColor(QgTheme.color('playerDim', this.themeId, true))
      }.width('100%').padding({ top: 14, bottom: 8 })
    }
    if (this.seasonsError.length > 0) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('分季信息暂不可用').fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(QgTheme.color('playerText', this.themeId, true))
          Text(this.seasonsError).fontSize(12).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(QgTheme.color('playerDim', this.themeId, true))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('重试').height(40).fontSize(13)
          .fontColor(QgTheme.color('accentOn', this.themeId, true))
          .backgroundColor(QgTheme.color('accent', this.themeId, true))
          .onClick(() => this.loadSeasons(this.getD()))
      }.width('100%').padding({ top: 14, bottom: 8 })
    }
    if (this.seasons.length > 1) {
      Row() {
        Text('分季').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(QgTheme.color('playerText', this.themeId, true))
        Blank()
        Text(`${this.seasonLabel()} · 左右滑动`).fontSize(11)
          .fontColor(QgTheme.color('playerDim', this.themeId, true))
      }.width('100%').padding({ top: 16, bottom: 10 })
      List({ space: 8, scroller: this.seasonScroller }) {
        ForEach(this.seasons, (season: QgSeason) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 7 }) {
                Row({ space: 6 }) {
                  Text(`第 ${season.number} 季`).fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor(QgTheme.color('text', this.themeId, true))
                  Blank()
                  if (this.switchingSeasonId === season.drama.id) {
                    LoadingProgress().width(16).height(16).color(QgTheme.color('accentInk', this.themeId, true))
                  } else if (season.drama.id === this.dramaId) {
                    Text('当前季').fontSize(10).fontWeight(FontWeight.Bold)
                      .fontColor(QgTheme.color('accentOn', this.themeId, true))
                      .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                      .borderRadius(8).backgroundColor(QgTheme.color('accent', this.themeId, true))
                  } else if (season.drama.episodeCount > 0) {
                    Text(`${season.drama.episodeCount} 集`).fontSize(11)
                      .fontColor(QgTheme.color('textDim', this.themeId, true))
                  }
                }.width('100%')
                Text(season.drama.title).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(QgTheme.color('textDim', this.themeId, true)).width('100%')
                Text(this.switchingSeasonId === season.drama.id ? '正在切换…' : this.seasonProgress(season))
                  .fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(QgTheme.color('accentInk', this.themeId, true)).width('100%')
              }.alignItems(HorizontalAlign.Start).width('100%').padding(12)
            }
            .width(164).height(104).padding(0).borderRadius(14)
            .backgroundColor(season.drama.id === this.dramaId ? QgTheme.color('accentSoft', this.themeId, true) :
              QgTheme.color('surfaceHigh', this.themeId, true))
            .border({ width: 1, color: season.drama.id === this.dramaId || this.switchingSeasonId === season.drama.id ?
              QgTheme.color('accentInk', this.themeId, true) : QgTheme.color('border', this.themeId, true) })
            .enabled(this.switchingSeasonId !== season.drama.id)
            .accessibilityText(`第 ${season.number} 季，${season.drama.title}，${this.seasonProgress(season)}${season.drama.id === this.dramaId ? '，当前季' : ''}`)
            .onClick(() => this.selectSeason(season))
          }
        }, (season: QgSeason) => season.drama.id)
      }
      .listDirection(Axis.Horizontal).scrollBar(BarState.Off).height(108).width('100%')
      .onAppear(() => {
        const index: number = this.seasons.findIndex((season: QgSeason): boolean => season.drama.id === this.dramaId);
        this.seasonScroller.scrollToIndex(Math.max(0, index), false, ScrollAlign.START);
      })
    }
    if (this.seasonSwitchError.length > 0) {
      Text(this.seasonSwitchError).fontSize(12).width('100%')
        .fontColor(QgTheme.color('danger', this.themeId, true)).padding({ top: 8, bottom: 8 })
    }
  }

  @Builder
  SheetInnerBuilder() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 5 }) {
          Text(this.sheetTab === 'episodes' ? '选季 · 选集' : '播放设置')
            .fontSize(23).fontWeight(FontWeight.Bolder)
            .fontColor(QgTheme.color('playerText', this.themeId, true))
          Text(`${this.currentSeasonNumber()}${this.episodeLabel()} · ${this.getD().title}`)
            .fontSize(12).fontColor(QgTheme.color('playerDim', this.themeId, true))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16)
            .fontColor([QgTheme.color('playerText', this.themeId, true)])
        }
        .width(40).height(40).padding(0)
        .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, true))
        .accessibilityText('关闭面板，返回播放')
        .onClick(() => this.sheetOpen = false)
      }.width('100%').padding({ top: 12, bottom: 16 })

      Row({ space: 6 }) {
        this.SheetTabBuilder('选集', 'episodes')
        this.SheetTabBuilder('播放设置', 'settings')
      }.width('100%').padding(4).borderRadius(16)
        .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, true))

      Scroll(this.sheetScroller) {
        Column() {
          if (this.sheetTab === 'episodes') {
            this.SeasonPickerBuilder()
            QgEpisodePicker({
              episodes: this.episodes,
              currentEpisode: this.episode,
              watchEpisode: QgStore.getInstance().getWatch(this.dramaId)?.episode ?? 0,
              playingMode: true,
              disabled: this.switchingSeason,
              themeId: this.themeId,
              darkOn: true,
              onPick: (order: number): void => this.pickEpisode(order)
            })
            this.BookmarkBuilder()
          } else {
            this.SectionTitleBuilder('倍速')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(SPEEDS, (sp: number) => {
                Text(`${sp}x`)
                  .fontSize(13)
                  .fontWeight(SPEEDS[this.speedIdx] === sp ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(SPEEDS[this.speedIdx] === sp ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                  .textAlign(TextAlign.Center)
                  .height(38)
                  .constraintSize({ minWidth: 54 })
                  .padding({ left: 10, right: 10 })
                  .borderRadius(19)
                  .backgroundColor(SPEEDS[this.speedIdx] === sp ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                  .margin({ right: 8, bottom: 8 })
                  .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
                  .onClick(() => {
                    this.pickSpeed(SPEEDS.indexOf(sp));
                  })
              }, (sp: number) => `speed_${sp}`)
            }
            .width('100%')

            if (this.audioMode) {
              this.SectionTitleBuilder('定时停止')
              Flex({ wrap: FlexWrap.Wrap }) {
                Text('关闭')
                  .fontSize(13)
                  .fontWeight(this.sleepMode === 0 ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(this.sleepMode === 0 ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                  .textAlign(TextAlign.Center)
                  .height(38)
                  .padding({ left: 16, right: 16 })
                  .borderRadius(19)
                  .backgroundColor(this.sleepMode === 0 ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                  .margin({ right: 8, bottom: 8 })
                  .accessibilityText('关闭定时停止')
                  .onClick(() => this.pickSleep(0))
                Text('播完本集')
                  .fontSize(13)
                  .fontWeight(this.sleepMode === -1 ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(this.sleepMode === -1 ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                  .textAlign(TextAlign.Center)
                  .height(38)
                  .padding({ left: 14, right: 14 })
                  .borderRadius(19)
                  .backgroundColor(this.sleepMode === -1 ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                  .margin({ right: 8, bottom: 8 })
                  .accessibilityText('本集播完后停止播放')
                  .onClick(() => this.pickSleep(-1))
                ForEach(SLEEP_MINUTES, (minutes: number) => {
                  Text(`${minutes} 分钟`)
                    .fontSize(13)
                    .fontWeight(this.sleepMode === minutes ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.sleepMode === minutes ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                    .textAlign(TextAlign.Center)
                    .height(38)
                    .padding({ left: 12, right: 12 })
                    .borderRadius(19)
                    .backgroundColor(this.sleepMode === minutes ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                    .margin({ right: 8, bottom: 8 })
                    .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
                    .accessibilityText(`${minutes} 分钟后停止播放`)
                    .onClick(() => this.pickSleep(minutes))
                }, (minutes: number) => `sleep_${minutes}`)
              }
              .width('100%')
            }

            if (this.routes.length > 1) {
              this.SectionTitleBuilder('线路')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.routes, (rt: string, idx: number) => {
                  Text(`线路 ${idx + 1}`)
                    .fontSize(13)
                    .fontWeight(this.routeIdx === idx ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.routeIdx === idx ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                    .textAlign(TextAlign.Center)
                    .height(38)
                    .padding({ left: 14, right: 14 })
                    .borderRadius(19)
                    .backgroundColor(this.routeIdx === idx ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                    .margin({ right: 8, bottom: 8 })
                    .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
                    .onClick(() => {
                      if (this.routeIdx !== idx) {
                        this.applyRoute(idx, false);
                        this.sheetOpen = false;
                      }
                    })
                }, (rt: string, idx: number) => `route_${idx}_${rt.length}`)
              }
              .width('100%')
            }

            if (this.qualities.length > 1) {
              this.SectionTitleBuilder('清晰度')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.qualities, (q: number) => {
                  Text(`${q}P`)
                    .fontSize(13)
                    .fontWeight(this.quality === q ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.quality === q ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
                    .textAlign(TextAlign.Center)
                    .height(38)
                    .constraintSize({ minWidth: 58 })
                    .padding({ left: 12, right: 12 })
                    .borderRadius(19)
                    .backgroundColor(this.quality === q ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
                    .margin({ right: 8, bottom: 8 })
                    .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
                    .onClick(() => {
                      this.pickQuality(q);
                    })
                }, (q: number) => `quality_${q}`)
              }
              .width('100%')
            }
          }
        }
        .width('100%').alignItems(HorizontalAlign.Start)
        .padding({ bottom: this.safeBottom + 24 })
      }
      .scrollBar(BarState.Off).width('100%').layoutWeight(1)
      .onAppear(() => this.sheetScroller.scrollTo({ xOffset: 0, yOffset: 0 }))
    }
    .width('100%').height('100%').padding({ left: 20, right: 20 })
  }

  @Builder
  SheetTabBuilder(label: string, tab: string) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1).height(40).fontSize(14).fontWeight(FontWeight.Bold).borderRadius(12)
      .fontColor(QgTheme.color(this.sheetTab === tab ? 'accentOn' : 'playerDim', this.themeId, true))
      .backgroundColor(this.sheetTab === tab ? QgTheme.color('accent', this.themeId, true) : Color.Transparent)
      .accessibilityText(`${label}${this.sheetTab === tab ? '，已选中' : ''}`)
      .onClick(() => {
        this.sheetTab = tab;
        this.sheetScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      })
  }

  @Builder
  BookmarkBuilder() {
    if (this.bookmarksForCurrentEpisode().length > 0) {
      this.SectionTitleBuilder('本集书签')
      Column() {
        ForEach(this.bookmarksForCurrentEpisode(), (mark: QgBookmarkRecord) => {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.bookmark'))
              .fontSize(15)
              .fontColor([QgTheme.color('accent', this.themeId, true)])
            Text(this.formatTime(mark.seconds))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(QgTheme.color('text', this.themeId, true))
            Text('跳转到这里')
              .fontSize(12)
              .fontColor(QgTheme.color('textFaint', this.themeId, true))
            Blank()
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(13)
              .fontColor([QgTheme.color('textFaint', this.themeId, true)])
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .onClick(() => {
            this.controller.setCurrentTime(mark.seconds);
            this.curSec = mark.seconds;
            this.sheetOpen = false;
          })
        }, (mark: QgBookmarkRecord) => `bookmark_${mark.createdAt}_${mark.seconds}`)
      }
      .width('100%')
      .padding({ left: 14, right: 14 })
      .borderRadius(16)
      .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, true))
    }
  }

  private bookmarksForCurrentEpisode(): QgBookmarkRecord[] {
    return this.drama === undefined ? [] : QgStore.getInstance().getBookmarks(this.drama.id, this.episode);
  }

  @Builder
  DanmakuSheetBuilder() {
    Scroll() {
      Column() {
        Row() {
          Column({ space: 3 }) {
            Text('DANMAKU')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(2.2)
              .fontColor(QgTheme.color('accent', this.themeId, true))
            Text('弹幕设置')
              .fontSize(22)
              .fontWeight(FontWeight.Bolder)
              .fontColor(QgTheme.color('text', this.themeId, true))
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text(this.danmakuStatus)
            .fontSize(12)
            .fontColor(QgTheme.color('textFaint', this.themeId, true))
            .maxLines(1)
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })

        Row() {
          Text('开启弹幕')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(QgTheme.color('text', this.themeId, true))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.danmakuOn })
            .selectedColor(QgTheme.color('accent', this.themeId, true))
            .onChange((isOn: boolean) => {
              this.toggleDanmaku(isOn);
            })
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })

        Row() {
          Text(`不透明度 ${this.danmakuOpacity}%`)
            .fontSize(13)
            .fontColor(QgTheme.color('textDim', this.themeId, true))
        }
        .width('100%')
        .padding({ top: 8 })
        Slider({ value: this.danmakuOpacity, min: 10, max: 100 })
          .selectedColor(QgTheme.color('accent', this.themeId, true))
          .trackColor(QgTheme.color('trackOff', this.themeId, true))
          .blockColor(QgTheme.color('accent', this.themeId, true))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.setDanmakuOpacity(Math.round(value));
            }
          })

        Row() {
          Text(`字号 ${this.danmakuFont}%`)
            .fontSize(13)
            .fontColor(QgTheme.color('textDim', this.themeId, true))
        }
        .width('100%')
        .padding({ top: 8 })
        Slider({ value: this.danmakuFont, min: 50, max: 150 })
          .selectedColor(QgTheme.color('accent', this.themeId, true))
          .trackColor(QgTheme.color('trackOff', this.themeId, true))
          .blockColor(QgTheme.color('accent', this.themeId, true))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.setDanmakuFont(Math.round(value));
            }
          })

        this.SectionTitleBuilder('显示区域')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(AREA_OPTIONS, (a: number) => {
            Text(a >= 100 ? '全屏' : `${a}%`)
              .fontSize(13)
              .fontWeight(this.danmakuArea === a ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.danmakuArea === a ? QgTheme.color('accentOn', this.themeId, true) : QgTheme.color('textDim', this.themeId, true))
              .textAlign(TextAlign.Center)
              .height(38)
              .padding({ left: 16, right: 16 })
              .borderRadius(19)
              .backgroundColor(this.danmakuArea === a ? QgTheme.color('accent', this.themeId, true) : QgTheme.color('surfaceHigh', this.themeId, true))
              .margin({ right: 8, bottom: 8 })
              .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
              .onClick(() => {
                this.setDanmakuArea(a);
              })
          }, (a: number) => `area_${a}`)
        }
        .width('100%')

        this.SectionTitleBuilder('屏蔽词')
        Row({ space: 8 }) {
          TextInput({ text: this.newWord, placeholder: '输入要屏蔽的词' })
            .fontSize(14)
            .fontColor(QgTheme.color('text', this.themeId, true))
            .placeholderColor(QgTheme.color('textFaint', this.themeId, true))
            .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, true))
            .borderRadius(16)
            .height(42)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.newWord = v;
            })
          Text('添加')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(QgTheme.color('accentOn', this.themeId, true))
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .borderRadius(20)
            .backgroundColor(QgTheme.color('accent', this.themeId, true))
            .onClick(() => {
              this.addBlockWord();
            })
        }
        .width('100%')

        if (this.blockWords.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.blockWords, (w: string) => {
              Row({ space: 6 }) {
                Text(w)
                  .fontSize(12)
                  .fontColor(QgTheme.color('textDim', this.themeId, true))
                  .maxLines(1)
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(11)
                  .fontColor([QgTheme.color('textFaint', this.themeId, true)])
                  .onClick(() => {
                    this.removeBlockWord(w);
                  })
              }
              .padding({ left: 12, right: 10, top: 6, bottom: 6 })
              .borderRadius(14)
              .backgroundColor(QgTheme.color('surfaceHigh', this.themeId, true))
              .margin({ right: 8, top: 8 })
            }, (w: string) => `word_${w}`)
          }
          .width('100%')
          .padding({ bottom: 8 })
        } else {
          Text('暂无屏蔽词')
            .fontSize(12)
            .fontColor(QgTheme.color('textFaint', this.themeId, true))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }
}

@Builder
export function QgPlayerBuilder() {
  QgPlayerPage()
}
