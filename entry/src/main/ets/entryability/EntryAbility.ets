/**
 * 青果APP 入口 Ability。
 *
 * 沉浸式窗口 + 超级桌面（Mate 60 Pro → 问界M9）流转适配，方案取自实战验证形态：
 * - layoutFullScreen：内容延伸到状态栏与手势条下方，页面按避让区留白；
 * - 车机虚拟屏检测：displayIdChange 实时维护，流转/迁回都即时刷新；
 * - 车机侧 enableLandscapeMultiWindow + maximize/resize 兜底铺满（避免「只有中间一条竖窗」）；
 * - 安全区与窗口尺寸写入 AppStorage（vp），页面用 @StorageProp 订阅。
 */
import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { QgStore } from '../data/QgStore';

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
  /** 当前窗口所在屏幕 id：0=手机主屏，>0=车机虚拟屏 */
  private currentDisplayId: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    QgStore.getInstance().init(this.context);
    this.applyColorMode();
    this.currentDisplayId = this.readConfigDisplayId();
    AppStorage.setOrCreate('carMode', this.currentDisplayId > 0);
    AppStorage.setOrCreate('systemDark', this.isDarkMode());
    AppStorage.setOrCreate('darkMode', this.isDarkEffective());
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
      AppStorage.setOrCreate('carMode', id > 0);
      this.fillTries = 0;
      this.syncCarOrientation();
      this.ensureFillScreen();
      this.syncWindowMetrics();
    });
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
      const onCar: boolean = displays.length > 1 || deviceInfo.deviceType === 'car' || this.currentDisplayId > 0;
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
    if (win === null || this.filling || this.fillTries >= 3) {
      return;
    }
    this.filling = true;
    try {
      const before: window.Rect = win.getWindowProperties().windowRect;
      const displays: display.Display[] = await display.getAllDisplays();
      const onCar: boolean = displays.length > 1 || deviceInfo.deviceType === 'car' || this.currentDisplayId > 0;
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
      if (target.width - before.width <= 48 && target.height - before.height <= 48) {
        return;
      }
      this.fillTries++;
      try {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
      } catch (maxError) {
        try {
          await win.maximize();
        } catch (retryError) {
          hilog.warn(0x0001, TAG, 'maximize 不可用');
        }
      }
      let after: window.Rect = win.getWindowProperties().windowRect;
      if (target.width - after.width > 48 || target.height - after.height > 48) {
        try {
          await win.setWindowLimits({
            maxWidth: target.width,
            maxHeight: target.height,
            minWidth: 320,
            minHeight: 320
          } as window.WindowLimits);
        } catch (limitError) {
          hilog.warn(0x0001, TAG, 'setWindowLimits 不可用');
        }
        try {
          await win.resize(target.width, target.height);
          await win.moveWindowTo(0, 0);
        } catch (resizeError) {
          hilog.warn(0x0001, TAG, 'resize 被拒绝');
        }
        after = win.getWindowProperties().windowRect;
      }
      hilog.info(0x0001, TAG, `fill after=${after.width}x${after.height} target=${target.width}x${target.height}`);
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
    const contentColor: string = this.isDarkMode() || playerActive ? '#FFFFFF' : '#17211A';
    try {
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
