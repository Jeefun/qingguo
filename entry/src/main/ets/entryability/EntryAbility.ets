/**
 * 青果APP 入口 Ability。
 *
 * 沉浸式窗口 + 超级桌面（Mate 60 Pro → 问界M9）流转适配，方案取自实战验证形态：
 * - layoutFullScreen：内容延伸到状态栏与手势条下方，页面按避让区留白；
 * - 车机虚拟屏检测：displayIdChange 实时维护，流转/迁回都即时刷新；
 * - 车机侧 enableLandscapeMultiWindow + 浮窗预调整 + maximize 兜底铺满（避免「只有中间一条竖窗」）；
 * - 安全区与窗口尺寸写入 AppStorage（vp），页面用 @StorageProp 订阅。
 */
import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { smartMobilityCommon } from '@kit.CarKit';
import { QgStore } from '../data/QgStore';
import { QgModuleStore } from '../data/QgModuleStore';
import { QgGateway } from '../data/QgGateway';

const TAG: string = 'QingGuoEntry';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /** 已挂监听的窗口实例（超级桌面会在车机侧另建窗口舞台，换窗口要重新挂监听） */
  private boundWindow: window.Window | null = null;
  /** 车机全屏兜底尝试次数（失败不无限重试） */
  private fillTries: number = 0;
  private filling: boolean = false;
  /** 是否由本应用主动改过窗口方向（断开座舱后要还原） */
  private forcedLandscape: boolean = false;
  private orienting: boolean = false;
  /** 是否已开启多窗横向模式 */
  private landscapeMultiOn: boolean = false;
  /** 当前窗口所在屏幕 id；超级桌面镜像形态下也可能为 0 */
  private currentDisplayId: number = 0;
  /** Car Kit 超级桌面（流转）状态感知实例 */
  private carAwareness: smartMobilityCommon.SmartMobilityAwareness | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    QgModuleStore.init(this.context.filesDir);
    QgStore.getInstance().init(this.context);
    AppStorage.setOrCreate('qgTheme', QgStore.getInstance().getTheme());
    this.applyColorMode();
    this.currentDisplayId = this.readConfigDisplayId();
    AppStorage.setOrCreate('carMode', this.currentDisplayId > 0 || deviceInfo.deviceType === 'car');
    AppStorage.setOrCreate('systemDark', this.isDarkMode());
    AppStorage.setOrCreate('darkMode', this.isDarkEffective());
    // Car Kit：监听超级桌面流转状态，连接/断开瞬间立即刷新方向与铺满
    this.listenSuperLauncher();
    // 本地媒体网关尽早启动：封面与播放地址都要经网关注入 Referer/UA
    QgGateway.ready().catch(() => {
    });
  }

  onDestroy(): void {
    if (this.carAwareness !== null) {
      try {
        const types: smartMobilityCommon.SmartMobilityType[] =
          [smartMobilityCommon.SmartMobilityType.SUPER_LAUNCHER];
        this.carAwareness.off('smartMobilityStatus', types);
      } catch (error) {
        hilog.warn(0x0001, TAG, 'smartMobilityStatus 注销失败');
      }
      this.carAwareness = null;
    }
  }

  /**
   * Car Kit 超级桌面状态监听（社区官方指南）：
   * 应用流转到车机/迁回手机时，超级桌面服务状态变化是比 displayIdChange
   * 更直接的时机信号；此处重置铺满计数并立即刷新方向、铺满与窗口度量。
   * 权限 ohos.permission.ACCESS_CAR_DISTRIBUTED_ENGINE（module.json5 已声明，
   * system_grant）；不支持的设备（如 2in1）通过 canIUse 跳过。
   */
  private listenSuperLauncher(): void {
    if (!canIUse('SystemCapability.CarService.DistributedEngine')) {
      return;
    }
    try {
      this.carAwareness = smartMobilityCommon.getSmartMobilityAwareness();
      const types: smartMobilityCommon.SmartMobilityType[] =
        [smartMobilityCommon.SmartMobilityType.SUPER_LAUNCHER];
      const callback = (info: smartMobilityCommon.SmartMobilityInfo): void => {
        hilog.info(0x0001, TAG,
          `smartMobility status=${info.status} type=${info.type}`);
        this.fillTries = 0;
        this.syncCarOrientation();
        this.ensureFillScreen();
        this.syncWindowMetrics();
      };
      this.carAwareness.on('smartMobilityStatus', types, callback);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `smartMobilityStatus 注册失败 code=${err.code}`);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色切换时同步状态栏图标颜色与全局暗色标记
    AppStorage.setOrCreate('systemDark', this.isDarkMode());
    AppStorage.setOrCreate('darkMode', this.isDarkEffective());
    this.applySystemBar();
  }

  /** 实际生效的暗色模式：用户设置优先，其次系统 */
  private isDarkEffective(): boolean {
    const mode: string = QgStore.getInstance().getSettings().colorMode;
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    return this.isDarkMode();
  }

  private readConfigDisplayId(): number {
    try {
      const id: number | undefined = this.context.config.displayId;
      return typeof id === 'number' ? id : 0;
    } catch (error) {
      return 0;
    }
  }

  private isDarkMode(): boolean {
    try {
      return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      return false;
    }
  }

  /** 按用户设置应用颜色模式（跟随系统 / 强制浅色 / 强制深色） */
  private applyColorMode(): void {
    const mode: string = QgStore.getInstance().getSettings().colorMode;
    const appCtx = this.context.getApplicationContext();
    try {
      if (mode === 'light') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (mode === 'dark') {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, '颜色模式设置失败');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(0x0001, TAG, `loadContent 失败: ${err.code}`);
        return;
      }
      this.setupWindow(windowStage);
    });
  }

  /** 沉浸式窗口设置：全屏布局 + 避让区/尺寸监听 + 车机铺满兜底 */
  private async setupWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const win: window.Window = await windowStage.getMainWindow();
      this.mainWindow = win;
      this.fillTries = 0;

      await win.setWindowLayoutFullScreen(true);

      // 先摆正方向再要尺寸；先把窗口铺满再算布局度量
      await this.syncCarOrientation();
      await this.ensureFillScreen();
      // 车机侧窗口有时在 setup 之后才定型，延时补一次（次数有上限）
      setTimeout(() => {
        this.ensureFillScreen();
      }, 900);

      this.syncWindowMetrics();
      this.bindWindowEvents(win);
      await this.applySystemBar();
    } catch (error) {
      hilog.warn(0x0001, TAG, '沉浸式窗口设置失败');
    }
  }

  private bindWindowEvents(win: window.Window): void {
    if (this.boundWindow === win) {
      return;
    }
    this.boundWindow = win;

    win.on('windowSizeChange', (size: window.Size) => {
      this.syncWindowMetrics();
      this.syncCarOrientation();
      this.ensureFillScreen();
    });

    win.on('avoidAreaChange', () => {
      this.syncWindowMetrics();
    });

    win.on('windowStatusChange', () => {
      this.syncWindowMetrics();
    });

    // 超级桌面流转/迁回（API 14+）：窗口跨屏迁移最可靠的时机信号
    win.on('displayIdChange', (id: number) => {
      hilog.info(0x0001, TAG, `displayIdChange: ${this.currentDisplayId} -> ${id}`);
      this.currentDisplayId = id;
      // 车机判定必须同步刷新：PlayerPage 等页面用 carMode 决定画面拉伸策略
      AppStorage.setOrCreate('carMode', id > 0 || deviceInfo.deviceType === 'car');
      this.fillTries = 0;
      this.syncCarOrientation();
      this.ensureFillScreen();
      this.syncWindowMetrics();
    });
  }

  /**
   * 车机/超级桌面判定。
   * displayId 在镜像投屏时可能仍为 0，因此再结合车机设备类型、多屏和
   * 「非全屏的宽屏桌面窗口」兜底，避免问界 M9 超级桌面漏判。
   */
  private isCarContext(win: window.Window, displays: display.Display[]): boolean {
    const props: window.WindowProperties = win.getWindowProperties();
    const windowDisplayId: number = typeof props.displayId === 'number'
      ? props.displayId
      : this.currentDisplayId;
    if (deviceInfo.deviceType === 'car' || this.currentDisplayId > 0 || windowDisplayId > 0 || displays.length > 1) {
      return true;
    }

    let activeDisplay: display.Display = display.getDefaultDisplaySync();
    try {
      activeDisplay = display.getDisplayByIdSync(windowDisplayId);
    } catch (error) {
      // 镜像场景退回默认屏幕信息
    }
    const displayLandscape: boolean = activeDisplay.width > activeDisplay.height;
    const displayWidthVp: number = activeDisplay.width / Math.max(activeDisplay.densityPixels, 1);
    const status: window.WindowStatusType = win.getWindowStatus();
    // 超级桌面在部分车机 DPI 下宽屏 vp 会低于 960，但窗口状态仍是自由窗口。
    // 手机横屏普通全屏为 FULL_SCREEN，不会命中；分屏也不会命中。
    const freeformDesktop: boolean =
      status === window.WindowStatusType.FLOATING || status === window.WindowStatusType.MAXIMIZE;
    const desktopLike: boolean = deviceInfo.deviceType === 'phone' &&
      displayLandscape &&
      (freeformDesktop || displayWidthVp >= 960);
    return desktopLike;
  }

  /**
   * 车机上把窗口变成横向。
   * ① enableLandscapeMultiWindow：多窗横向，超级桌面（投屏/多窗形态）下
   *    setPreferredOrientation 会静默失效，真正生效的是这个开关；
   *    前提：module.json5 的 preferMultiWindowOrientation = landscape_auto（已配置）。
   * ② setPreferredOrientation(LANDSCAPE)：仅全屏窗口下生效，作补刀。
   * 「在车机上」用 多屏 / 设备类型 / displayId 任一判定；离开座舱全部还原。
   */
  private async syncCarOrientation(): Promise<void> {
    const win: window.Window | null = this.mainWindow;
    if (win === null || this.orienting) {
      return;
    }
    this.orienting = true;
    try {
      const displays: display.Display[] = await display.getAllDisplays();
      const onCar: boolean = this.isCarContext(win, displays);
      AppStorage.setOrCreate('carMode', onCar);
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const portrait: boolean = rect.height > rect.width;

      if (onCar) {
        if (!this.landscapeMultiOn) {
          try {
            await win.enableLandscapeMultiWindow();
            this.landscapeMultiOn = true;
          } catch (mwError) {
            const mwErr = mwError as BusinessError;
            hilog.warn(0x0001, TAG, `enableLandscapeMultiWindow 失败 code=${mwErr.code}`);
          }
        }
        if (portrait) {
          try {
            await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
            this.forcedLandscape = true;
          } catch (orientError) {
            const oErr = orientError as BusinessError;
            hilog.warn(0x0001, TAG, `setPreferredOrientation 失败 code=${oErr.code}`);
          }
        }
      } else if (this.landscapeMultiOn || this.forcedLandscape) {
        this.fillTries = 0;
        if (this.landscapeMultiOn) {
          try {
            await win.disableLandscapeMultiWindow();
            this.landscapeMultiOn = false;
          } catch (disError) {
            hilog.warn(0x0001, TAG, 'disableLandscapeMultiWindow 失败');
          }
        }
        if (this.forcedLandscape) {
          try {
            await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
            this.forcedLandscape = false;
          } catch (restoreError) {
            hilog.warn(0x0001, TAG, '还原自动旋转失败');
          }
        }
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, '车机方向同步失败');
    } finally {
      this.orienting = false;
    }
  }

  /**
   * 车机全屏兜底：窗口明显小于车机屏时主动要一次整屏。
   * 只在「确实在车机上」时动手，手机上永远命中不到；尝试上限 3 次。
   */
  private async ensureFillScreen(): Promise<void> {
    const win: window.Window | null = this.mainWindow;
    if (win === null || this.filling || this.fillTries >= 3 ||
      AppStorage.get<boolean>('playerActive') === true) {
      return;
    }
    this.filling = true;
    try {
      const before: window.Rect = win.getWindowProperties().windowRect;
      const displays: display.Display[] = await display.getAllDisplays();
      const onCar: boolean = this.isCarContext(win, displays);
      if (!onCar) {
        return;
      }
      let target: display.Display | null = null;
      if (this.currentDisplayId > 0) {
        try {
          target = display.getDisplayByIdSync(this.currentDisplayId);
        } catch (targetError) {
          target = null;
        }
      }
      if (target === null) {
        for (const item of displays) {
          if (item.width <= item.height) {
            continue;
          }
          if (target === null || item.width * item.height > target.width * target.height) {
            target = item;
          }
        }
      }
      if (target === null) {
        return;
      }
      const status: window.WindowStatusType = win.getWindowStatus();
      const sizeAlreadyFull: boolean =
        target.width - before.width <= 48 && target.height - before.height <= 48;
      const fullScreenStatus: boolean =
        status === window.WindowStatusType.FULL_SCREEN || status === window.WindowStatusType.MAXIMIZE;
      if (sizeAlreadyFull && fullScreenStatus) {
        return;
      }
      this.fillTries++;

      // resize/move 只在浮窗状态有效，必须在 maximize 之前完成。
      if (status === window.WindowStatusType.FLOATING) {
        try {
          await win.setWindowLimits({
            maxWidth: target.width,
            maxHeight: target.height,
            minWidth: Math.min(320, target.width),
            minHeight: Math.min(320, target.height)
          } as window.WindowLimits);
        } catch (limitError) {
          hilog.warn(0x0001, TAG, 'setWindowLimits 不可用');
        }
        try {
          await win.resizeAsync(target.width, target.height);
          await win.moveWindowToAsync(0, 0);
        } catch (resizeError) {
          hilog.warn(0x0001, TAG, '浮窗预调整被拒绝');
        }
      }

      try {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
      } catch (maxError) {
        try {
          await win.maximize();
        } catch (retryError) {
          hilog.warn(0x0001, TAG, 'maximize 不可用');
        }
      }
      const after: window.Rect = win.getWindowProperties().windowRect;
      hilog.info(0x0001, TAG,
        `fill status=${win.getWindowStatus()} rect=${after.width}x${after.height} target=${target.width}x${target.height}`);
    } catch (error) {
      hilog.warn(0x0001, TAG, '车机铺满失败');
    } finally {
      this.filling = false;
    }
  }

  /** 窗口矩形与避让区换算成 vp 写入 AppStorage，页面用 @StorageProp 订阅 */
  private syncWindowMetrics(): void {
    const win: window.Window | null = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      let density: number = display.getDefaultDisplaySync().densityPixels;
      if (this.currentDisplayId > 0) {
        try {
          density = display.getDisplayByIdSync(this.currentDisplayId).densityPixels;
        } catch (error) {
          // 回退主屏密度
        }
      }
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      const leftVp: number = Math.max(sys.leftRect.width, nav.leftRect.width) / density;
      const rightVp: number = Math.max(sys.rightRect.width, nav.rightRect.width) / density;

      AppStorage.setOrCreate('safeTop', sys.topRect.height / density);
      AppStorage.setOrCreate('safeBottom', nav.bottomRect.height / density);
      AppStorage.setOrCreate('safeLeft', leftVp);
      AppStorage.setOrCreate('safeRight', rightVp);
      AppStorage.setOrCreate('screenWidth', rect.width / density);
      AppStorage.setOrCreate('screenHeight', rect.height / density);
    } catch (error) {
      hilog.warn(0x0001, TAG, '窗口度量读取失败');
    }
  }

  /** 系统栏透明 + 图标随主题反色；播放页激活时强制白（压在深色视频上） */
  private async applySystemBar(): Promise<void> {
    if (this.mainWindow === null) {
      return;
    }
    const playerActive: boolean = AppStorage.get<boolean>('playerActive') === true;
    const contentColor: string = this.isDarkEffective() || playerActive ? '#FFFFFF' : '#0E110D';
    try {
      // 「夜幕 · 青柠」：系统栏始终透明，让首页沉浸海报与详情背景铺到状态栏下方
      await this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      } as window.SystemBarProperties);
    } catch (error) {
      hilog.warn(0x0001, TAG, '系统栏配色设置失败');
    }
  }
}
