/**
 * 播放页：Video 组件 + 自定义控制层。
 * - 播放地址经本地媒体网关（QgGateway）注入 Referer/UA；
 * - 弹幕（红果评论弹幕）：QgDanmakuController/View，设置面板可调开关/透明度/字号/区域/屏蔽词；
 * - 手势：单击唤控制层、双击点赞、长按 2x、水平拖动 seek、左半竖滑亮度、右半竖滑音量（AVVolumePanel）、快滑上/下切集；
 * - 断点续播（onPrepared seek）、自动下集 5s 倒计时、片尾 30s 预解析下一集、播放失败自动重试 + 换线路；
 * - 倍速 / 线路 / 清晰度 / 选集半模态；全屏横屏切换。
 */
import { curves, window } from '@kit.ArkUI';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { QgAppSettings, QgDrama, QgDramaDetail, QgEpisode, QgPlayerParam, QgPlayInfo, QgWatchRecord } from '../model/QgModels';
import { QgRepository } from '../data/QgRepository';
import { QgStore } from '../data/QgStore';
import { QgGateway } from '../data/QgGateway';
import { qgCoverOf } from '../components/QgWidgets';
import { QgDanmakuController, QgDanmakuView } from '../components/QgDanmaku';

const SPEEDS: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const HIDE_DELAY: number = 3500;
const RESUME_MIN_SEC: number = 3;
const RESUME_TAIL_SEC: number = 2;
const COUNTDOWN_SEC: number = 5;
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

@Component
struct QgPlayerPage {
  private stack: NavPathStack = new NavPathStack();
  private controller: VideoController = new VideoController();
  private hideTimer: number = -1;
  private countdownTimer: number = -1;
  private pendingPlay: boolean = false;
  private lastSavedSec: number = -1;
  private dramaId: string = '';
  private lastInfo: QgPlayInfo | undefined = undefined;
  private danmakuCtl: QgDanmakuController = new QgDanmakuController();
  private preResolved: boolean = false;
  private autoRetried: boolean = false;
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

  @State drama: QgDrama | undefined = undefined;
  @State episodes: QgEpisode[] = [];
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
  @State pendingResumeSec: number = 0;
  @State countdownSec: number = 0;
  @State countdownToEp: number = 0;
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
  @StorageProp('darkMode') darkOn: boolean = false;
  @StorageProp('carMode') carOn: boolean = false;

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
    if (this.drama === undefined || this.dramaId.length === 0) {
      return;
    }
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
    patch.playSpeed = cur.playSpeed;
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
    mutate(patch);
    QgStore.getInstance().updateSettings(patch);
  }

  /** 详情加载 + 断点续播定位 */
  private bootstrap(dramaId: string, episode: number): void {
    this.dramaId = dramaId;
    this.loadErr = '';
    QgRepository.detail(dramaId)
      .then((detail: QgDramaDetail) => {
        this.drama = detail.drama;
        this.episodes = detail.episodes;
        const total: number = this.episodeTotal();
        this.episode = episode >= 1 && episode <= total ? episode : 1;
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
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '加载失败，请重试';
      });
  }

  /** 解析当前分集播放地址（走网关） */
  private resolvePlay(): void {
    const ep: QgEpisode | undefined = this.currentEpisode();
    if (ep === undefined) {
      this.loadErr = '分集不存在';
      return;
    }
    this.resolving = true;
    this.playUrl = '';
    this.curSec = 0;
    this.totalSec = 0;
    this.lastSavedSec = -1;
    this.loadErr = '';
    this.playFailed = false;
    this.autoRetried = false;
    this.preResolved = false;
    QgGateway.ready()
      .then((): Promise<QgPlayInfo> => {
        return QgRepository.play(this.dramaId, ep.id);
      })
      .then((info: QgPlayInfo) => {
        this.resolving = false;
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
        this.applyRoute(this.routeIdx, true);
      })
      .catch((error: BusinessError) => {
        this.resolving = false;
        this.loadErr = error.message !== undefined && error.message.length > 0 ? error.message : '播放地址解析失败';
      });
  }

  /** 应用线路：包装网关地址；resume=true 用断点位置，false 保持当前进度 */
  private applyRoute(idx: number, resume: boolean): void {
    const info: QgPlayInfo | undefined = this.lastInfo;
    if (info === undefined || idx < 0 || idx >= this.routes.length) {
      return;
    }
    if (!resume) {
      this.pendingResumeSec = this.curSec > 1 ? this.curSec : 0;
    }
    this.routeIdx = idx;
    this.playFailed = false;
    this.autoRetried = false;
    this.loadErr = '';
    const headers: Record<string, string> = {};
    const keys: string[] = Object.keys(info.headers);
    for (let i: number = 0; i < keys.length; i++) {
      headers[keys[i]] = info.headers[keys[i]];
    }
    if (info.referer.length > 0 && headers['Referer'] === undefined) {
      headers['Referer'] = info.referer;
    }
    this.playUrl = QgGateway.mediaUrl(this.routes[idx], headers);
    this.pendingPlay = true;
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

  /** 片尾预解析下一集（仅预热，不接管播放） */
  private preResolveNext(): void {
    if (this.preResolved || this.totalSec <= 0 || !QgStore.getInstance().getSettings().autoNext) {
      return;
    }
    if (this.totalSec - this.curSec > PRE_RESOLVE_TAIL_SEC) {
      return;
    }
    const nextOrder: number = this.episode + 1;
    if (nextOrder > this.episodeTotal()) {
      return;
    }
    const ep: QgEpisode | undefined = this.episodes.find((e: QgEpisode): boolean => e.order === nextOrder);
    if (ep === undefined) {
      return;
    }
    this.preResolved = true;
    QgRepository.play(this.dramaId, ep.id).catch((): void => {
    });
  }

  private togglePlay(): void {
    if (this.playing) {
      this.controller.pause();
    } else {
      this.controller.start();
    }
  }

  private pickEpisode(ep: number): void {
    if (this.drama === undefined || ep < 1 || ep > this.episodeTotal() || ep === this.episode) {
      return;
    }
    this.cancelCountdown();
    this.saveRecord();
    this.episode = ep;
    this.pendingResumeSec = 0;
    this.pendingPlay = true;
    this.preResolved = false;
    this.sheetOpen = false;
    this.controlsShown = true;
    this.resolvePlay();
  }

  private prevEpisode(): void {
    this.pickEpisode(this.episode - 1);
  }

  private nextEpisode(): void {
    this.pickEpisode(this.episode + 1);
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

  // ---------- 自动下集倒计时 ----------

  private startCountdown(): void {
    this.cancelCountdown();
    this.countdownToEp = this.episode + 1;
    this.countdownSec = COUNTDOWN_SEC;
    this.controlsShown = false;
    this.countdownTimer = setInterval(() => {
      this.countdownSec--;
      if (this.countdownSec <= 0) {
        const ep: number = this.countdownToEp;
        this.cancelCountdown();
        this.pickEpisode(ep);
      }
    }, 1000);
  }

  private cancelCountdown(): void {
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
    this.countdownSec = 0;
    this.countdownToEp = 0;
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

  private async toggleFullscreen(): Promise<void> {
    this.fullscreen = !this.fullscreen;
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      if (this.fullscreen) {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      } else {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_PORTRAIT);
      }
    } catch (error) {
      // 方向切换失败保持现状
    }
  }

  private restoreOrientation(): void {
    if (!this.fullscreen) {
      return;
    }
    this.fullscreen = false;
    window.getLastWindow(getContext(this))
      .then((win: window.Window): Promise<void> => {
        return win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_PORTRAIT);
      })
      .catch((): void => {
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
      const contentColor: string = playerActive || this.darkOn ? '#FFFFFF' : '#17211A';
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
    this.saveRecord();
    this.cancelHide();
    this.cancelCountdown();
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
        Column({ space: 10 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.playerDim'))
          Text('加载中…')
            .fontSize(14)
            .fontColor($r('app.color.playerDim'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.playerBg'))
      } else {
        this.StageBuilder()
      }
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.playerBg'))
    .onBackPressed((): boolean => {
      if (this.fullscreen) {
        this.toggleFullscreen();
        return true;
      }
      return false;
    })
    .onReady((ctx: NavDestinationContext) => {
      this.stack = ctx.pathStack;
      const p = ctx.pathInfo.param as QgPlayerParam;
      if (p === undefined || p === null || typeof p.dramaId !== 'string' || p.dramaId.length === 0) {
        this.loadErr = '缺少播放参数';
        return;
      }
      const settings: QgAppSettings = QgStore.getInstance().getSettings();
      this.speedIdx = this.speedIndexOf(settings.playSpeed);
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
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.movie_slash'))
        .fontSize(52)
        .fontColor([$r('app.color.playerDim')])
      Text(this.loadErr)
        .fontSize(14)
        .fontColor($r('app.color.playerDim'))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      Text('重试')
        .fontSize(14)
        .fontColor($r('app.color.playerText'))
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .borderRadius(18)
        .backgroundColor('#33000000')
        .onClick(() => {
          this.loadErr = '';
          this.bootstrap(this.dramaId, this.episode);
        })
      Text('返回')
        .fontSize(14)
        .fontColor($r('app.color.playerDim'))
        .padding({ top: 4, bottom: 4 })
        .onClick(() => {
          this.stack.pop();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  StageBuilder() {
    Stack() {
      if (this.playUrl.length > 0) {
        Video({
          src: this.playUrl,
          controller: this.controller,
          currentProgressRate: this.speedBoost ? 2 : SPEEDS[this.speedIdx],
          previewUri: qgCoverOf(this.getD().cover, this.getD().sourceId)
        })
          .autoPlay(false)
          .controls(false)
          .objectFit(ImageFit.Cover)
          .onPrepared((info: PreparedInfo) => {
            if (info.duration > 0) {
              this.totalSec = info.duration;
            }
            if (this.pendingResumeSec > 0) {
              if (this.pendingResumeSec < this.totalSec - 1) {
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
          })
          .onUpdate((event) => {
            if (this.seekDragging || this.panMode === PAN_MODE_SEEK) {
              return;
            }
            this.curSec = event.time;
            this.driveDanmaku();
            if (this.lastSavedSec < 0 || Math.abs(this.curSec - this.lastSavedSec) >= SAVE_EVERY_SEC) {
              this.saveRecord();
            }
            this.preResolveNext();
          })
          .onStart(() => {
            this.playing = true;
            this.scheduleHide();
            this.driveDanmaku();
          })
          .onPause(() => {
            this.playing = false;
            this.controlsShown = true;
            this.cancelHide();
            this.saveRecord();
            this.driveDanmaku();
          })
          .onFinish(() => {
            const autoNext: boolean = QgStore.getInstance().getSettings().autoNext;
            this.saveRecord();
            this.driveDanmaku();
            if (autoNext && this.episode < this.episodeTotal()) {
              this.playing = false;
              this.startCountdown();
            } else {
              this.playing = false;
              this.controlsShown = true;
            }
          })
          .onError(() => {
            this.playing = false;
            this.controlsShown = true;
            if (!this.autoRetried && this.playUrl.length > 0) {
              this.autoRetried = true;
              setTimeout(() => {
                if (this.playUrl.length > 0) {
                  this.applyRoute(this.routeIdx, false);
                }
              }, 1200);
            } else {
              this.playFailed = true;
            }
          })
      } else {
        Column({ space: 10 }) {
          if (this.loadErr.length > 0) {
            SymbolGlyph($r('sys.symbol.movie_slash'))
              .fontSize(44)
              .fontColor([$r('app.color.playerDim')])
            Text(this.loadErr)
              .fontSize(13)
              .fontColor($r('app.color.playerDim'))
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Text('重试')
              .fontSize(14)
              .fontColor($r('app.color.playerText'))
              .padding({ left: 24, right: 24, top: 9, bottom: 9 })
              .borderRadius(18)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.resolvePlay();
              })
          } else {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.playerDim'))
            Text('解析播放地址…')
              .fontSize(13)
              .fontColor($r('app.color.playerDim'))
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 弹幕层（红果源且有 danmakuId 时）
      if (this.danmakuOn && this.danmakuId.length > 0 && this.playUrl.length > 0) {
        QgDanmakuView({
          controller: this.danmakuCtl,
          areaPercent: this.danmakuArea,
          fontScale: this.danmakuFont,
          opacityPercent: this.danmakuOpacity
        })
      }

      // 系统音量面板（离屏驱动系统音量，配合音量手势）
      AVVolumePanel({
        volumeLevel: this.volumeLevel,
        volumeParameter: { position: { x: -100, y: -100 } }
      })
        .width(1)
        .height(1)

      // 手势层：单击/双击/长按/拖动/快滑
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

      // 手势提示：seek / 亮度 / 音量 / 2x
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
        this.HintPillBuilder('2x 快进中')
      }

      // 双击点赞动画
      if (this.likeShow) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(64)
          .fontColor([$r('app.color.accent')])
          .scale({ x: this.likeScale, y: this.likeScale })
          .opacity(this.likeOpacity)
      }

      // 播放失败面板
      if (this.playFailed) {
        this.PlayFailBuilder()
      }

      // 自动下集倒计时卡片
      if (this.countdownSec > 0) {
        Column({ space: 10 }) {
          Text(`即将播放第 ${this.countdownToEp} 集（${this.countdownSec}s）`)
            .fontSize(15)
            .fontColor(Color.White)
          Text('取消')
            .fontSize(13)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 20, right: 20, top: 7, bottom: 7 })
            .borderRadius(15)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.cancelCountdown();
              this.controlsShown = true;
            })
        }
        .padding(20)
        .borderRadius(16)
        .backgroundColor('#B3000000')
      }

      if (this.controlsShown) {
        this.OverlayBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetOpen, this.SheetInnerBuilder(), {
      detents: [SheetSize.MEDIUM],
      dragBar: true,
      backgroundColor: $r('app.color.surface')
    })
  }

  @Builder
  HintPillBuilder(text: string) {
    Text(text)
      .fontSize(14)
      .fontColor(Color.White)
      .padding({ left: 18, right: 18, top: 9, bottom: 9 })
      .borderRadius(18)
      .backgroundColor('#99000000')
  }

  @Builder
  PlayFailBuilder() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.movie_slash'))
        .fontSize(44)
        .fontColor([$r('app.color.playerDim')])
      Text('播放失败，请重试或切换线路')
        .fontSize(13)
        .fontColor($r('app.color.playerDim'))
      Row({ space: 10 }) {
        Text('重试')
          .fontSize(14)
          .fontColor($r('app.color.playerText'))
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(16)
          .backgroundColor('#33000000')
          .onClick(() => {
            this.applyRoute(this.routeIdx, false);
          })
        if (this.routes.length > 1) {
          Text('换线路')
            .fontSize(14)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.applyRoute((this.routeIdx + 1) % this.routes.length, false);
            })
        }
        Text('返回')
          .fontSize(14)
          .fontColor($r('app.color.playerDim'))
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(16)
          .onClick(() => {
            this.stack.pop();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }

  @Builder
  OverlayBuilder() {
    Column() {
      // 顶部：返回 + 标题 + 集数
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor([Color.White])
          .onClick(() => {
            this.saveRecord();
            this.stack.pop();
          })
        Column({ space: 2 }) {
          Text(this.getD().title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`第${this.episode}集 / 共${this.episodeTotal()}集${this.carOn ? ' · 车机' : ''}`)
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: 16,
        right: 16,
        top: (this.fullscreen ? 0 : this.safeTop) + 8,
        bottom: 10
      })
      .linearGradient({
        angle: 180,
        colors: [['#66000000', 0], ['#00000000', 1]]
      })

      Blank()

      // 中央控制
      Row({ space: 44 }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.episode > 1 ? Color.White : $r('app.color.trackOff')])
          .rotate({ angle: 180 })
          .onClick(() => {
            this.prevEpisode();
          })

        SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(44)
          .fontColor([Color.White])
          .onClick(() => {
            this.togglePlay();
          })

        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.episode < this.episodeTotal() ? Color.White : $r('app.color.trackOff')])
          .onClick(() => {
            this.nextEpisode();
          })
      }

      Blank()

      // 底部：进度 + 功能按钮
      Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text(this.formatTime(this.curSec))
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
          Slider({
            value: this.curSec,
            min: 0,
            max: this.totalSec > 0 ? this.totalSec : 100
          })
            .selectedColor($r('app.color.accent'))
            .trackColor($r('app.color.trackOff'))
            .blockColor(Color.White)
            .layoutWeight(1)
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
          Text(this.formatTime(this.totalSec))
            .fontSize(11)
            .fontColor($r('app.color.playerDim'))
          SymbolGlyph(this.fullscreen ?
            $r('sys.symbol.arrow_down_right_and_arrow_up_left') :
            $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize(20)
            .fontColor([Color.White])
            .onClick(() => {
              this.toggleFullscreen();
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text(`${SPEEDS[this.speedIdx]}x`)
            .fontSize(12)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.cancelHide();
              this.sheetOpen = true;
            })
          if (this.danmakuId.length > 0) {
            Text(this.danmakuOn ? '弹幕开' : '弹幕关')
              .fontSize(12)
              .fontColor(this.danmakuOn ? $r('app.color.playerText') : $r('app.color.playerDim'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.toggleDanmaku(!this.danmakuOn);
              })
            Text('弹幕设置')
              .fontSize(12)
              .fontColor($r('app.color.playerText'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.cancelHide();
                this.danmakuStatus = this.danmakuCtl.statusText();
                this.danmakuSheetOpen = true;
              })
              .bindSheet($$this.danmakuSheetOpen, this.DanmakuSheetBuilder(), {
                detents: [SheetSize.MEDIUM],
                dragBar: true,
                backgroundColor: $r('app.color.surface')
              })
          }
          Text('选集')
            .fontSize(12)
            .fontColor($r('app.color.playerText'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#33000000')
            .onClick(() => {
              this.cancelHide();
              this.sheetOpen = true;
            })
          if (this.routes.length > 1) {
            Text(`线路${this.routeIdx + 1}`)
              .fontSize(12)
              .fontColor($r('app.color.playerText'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.cancelHide();
                this.sheetOpen = true;
              })
          }
          if (this.qualities.length > 1) {
            Text(this.quality > 0 ? `${this.quality}P` : '清晰度')
              .fontSize(12)
              .fontColor($r('app.color.playerText'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor('#33000000')
              .onClick(() => {
                this.cancelHide();
                this.sheetOpen = true;
              })
          }
          Blank()
        }
        .width('100%')
      }
      .width('100%')
      .padding({
        left: 16,
        right: 16,
        top: 10,
        bottom: (this.fullscreen ? 12 : this.safeBottom + 12)
      })
      .linearGradient({
        angle: 0,
        colors: [['#00000000', 0], ['#66000000', 1]]
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SectionTitleBuilder(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text'))
      .width('100%')
      .padding({ top: 12, bottom: 8 })
  }

  @Builder
  SheetInnerBuilder() {
    Scroll() {
      Column() {
        this.SectionTitleBuilder('倍速')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SPEEDS, (sp: number) => {
            Text(`${sp}x`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(SPEEDS[this.speedIdx] === sp ? $r('app.color.accentOn') : $r('app.color.textDim'))
              .textAlign(TextAlign.Center)
              .height(36)
              .constraintSize({ minWidth: 52 })
              .padding({ left: 8, right: 8 })
              .borderRadius(10)
              .backgroundColor(SPEEDS[this.speedIdx] === sp ? $r('app.color.accent') : $r('app.color.chipBg'))
              .margin({ right: 8, bottom: 8 })
              .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
              .onClick(() => {
                this.pickSpeed(SPEEDS.indexOf(sp));
              })
          }, (sp: number) => `speed_${sp}`)
        }
        .width('100%')

        if (this.routes.length > 1) {
          this.SectionTitleBuilder('线路')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.routes, (rt: string, idx: number) => {
              Text(`线路 ${idx + 1}`)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.routeIdx === idx ? $r('app.color.accentOn') : $r('app.color.textDim'))
                .textAlign(TextAlign.Center)
                .height(36)
                .padding({ left: 12, right: 12 })
                .borderRadius(10)
                .backgroundColor(this.routeIdx === idx ? $r('app.color.accent') : $r('app.color.chipBg'))
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
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.quality === q ? $r('app.color.accentOn') : $r('app.color.textDim'))
                .textAlign(TextAlign.Center)
                .height(36)
                .constraintSize({ minWidth: 56 })
                .padding({ left: 8, right: 8 })
                .borderRadius(10)
                .backgroundColor(this.quality === q ? $r('app.color.accent') : $r('app.color.chipBg'))
                .margin({ right: 8, bottom: 8 })
                .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
                .onClick(() => {
                  this.pickQuality(q);
                })
            }, (q: number) => `quality_${q}`)
          }
          .width('100%')
        }

        Row() {
          Text('选集')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
          Blank()
          Text(`共${this.episodeTotal()}集`)
            .fontSize(12)
            .fontColor($r('app.color.textFaint'))
        }
        .width('100%')
        .padding({ top: 12, bottom: 8 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.episodes, (ep: QgEpisode) => {
            Text(ep.title.length > 0 ? ep.title : `${ep.order}`)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(ep.order === this.episode ? $r('app.color.accentOn') : $r('app.color.textDim'))
              .textAlign(TextAlign.Center)
              .height(38)
              .constraintSize({ minWidth: 44 })
              .padding({ left: 8, right: 8 })
              .borderRadius(10)
              .backgroundColor(ep.order === this.episode ? $r('app.color.accent') : $r('app.color.chipBg'))
              .margin({ right: 8, bottom: 8 })
              .animation({ duration: 220, curve: curves.springMotion(0.4, 0.8) })
              .onClick(() => {
                this.pickEpisode(ep.order);
              })
          }, (ep: QgEpisode) => `sheet_ep_${ep.id}_${ep.order}`)
        }
        .width('100%')
        .padding({ bottom: 24 })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  @Builder
  DanmakuSheetBuilder() {
    Scroll() {
      Column() {
        Row() {
          Text('弹幕设置')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
          Blank()
          Text(this.danmakuStatus)
            .fontSize(12)
            .fontColor($r('app.color.textFaint'))
            .maxLines(1)
        }
        .width('100%')
        .padding({ top: 12, bottom: 8 })

        Row() {
          Text('开启弹幕')
            .fontSize(15)
            .fontColor($r('app.color.text'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.danmakuOn })
            .onChange((isOn: boolean) => {
              this.toggleDanmaku(isOn);
            })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })

        Row() {
          Text(`不透明度 ${this.danmakuOpacity}%`)
            .fontSize(14)
            .fontColor($r('app.color.textDim'))
        }
        .width('100%')
        .padding({ top: 6 })
        Slider({ value: this.danmakuOpacity, min: 10, max: 100 })
          .selectedColor($r('app.color.accent'))
          .trackColor($r('app.color.trackOff'))
          .blockColor($r('app.color.accent'))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.setDanmakuOpacity(Math.round(value));
            }
          })

        Row() {
          Text(`字号 ${this.danmakuFont}%`)
            .fontSize(14)
            .fontColor($r('app.color.textDim'))
        }
        .width('100%')
        .padding({ top: 6 })
        Slider({ value: this.danmakuFont, min: 50, max: 150 })
          .selectedColor($r('app.color.accent'))
          .trackColor($r('app.color.trackOff'))
          .blockColor($r('app.color.accent'))
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
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.danmakuArea === a ? $r('app.color.accentOn') : $r('app.color.textDim'))
              .textAlign(TextAlign.Center)
              .height(36)
              .padding({ left: 14, right: 14 })
              .borderRadius(10)
              .backgroundColor(this.danmakuArea === a ? $r('app.color.accent') : $r('app.color.chipBg'))
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
            .layoutWeight(1)
            .onChange((v: string) => {
              this.newWord = v;
            })
          Text('添加')
            .fontSize(14)
            .fontColor($r('app.color.accentOn'))
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(14)
            .backgroundColor($r('app.color.accent'))
            .onClick(() => {
              this.addBlockWord();
            })
        }
        .width('100%')

        if (this.blockWords.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.blockWords, (w: string) => {
              Row({ space: 4 }) {
                Text(w)
                  .fontSize(13)
                  .fontColor($r('app.color.textDim'))
                  .maxLines(1)
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(11)
                  .fontColor([$r('app.color.textFaint')])
                  .onClick(() => {
                    this.removeBlockWord(w);
                  })
              }
              .padding({ left: 10, right: 8, top: 6, bottom: 6 })
              .borderRadius(12)
              .backgroundColor($r('app.color.chipBg'))
              .margin({ right: 8, top: 8 })
            }, (w: string) => `word_${w}`)
          }
          .width('100%')
          .padding({ bottom: 8 })
        } else {
          Text('暂无屏蔽词')
            .fontSize(12)
            .fontColor($r('app.color.textFaint'))
            .width('100%')
            .padding({ top: 6, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 24 })
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
