/**
 * 内置站源模块仓库（对齐上游 module_bundled.go）。
 * 18 个 JS 模块随包内置在 resources/rawfile/modules/{id}/（manifest.json + main.js），
 * 启动时安装/升级到应用沙箱 qg_verified_modules/；旧版在线安装的模块继续可用
 * （版本更高时保留，更低时被内置版本覆盖）。模块状态（loadState/saveState）
 * 仍按 id 持久化，供 QgModuleHost 使用。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { QgDiag } from './QgDiag';
import { QgJson } from './QgJson';
import { qgToHex, qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { qgSha256 } from './QgCrypto';

const STORE_API: number = 1;
const BUNDLED_ROOT: string = 'modules';
const MAX_MANIFEST_BYTES: number = 64 << 10;
const MAX_MODULE_BYTES: number = 4 << 20;
const MAX_PACKAGE_BYTES: number = 6 * MAX_MODULE_BYTES + 6 * MAX_MANIFEST_BYTES + 4096;
const MAX_STATE_BYTES: number = 256 << 10;
const MAX_SOURCE_STATE_BYTES: number = 4 << 20;
const MAX_SOURCE_STATES: number = 32;
const ID_PATTERN: RegExp = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const VERSION_PATTERN: RegExp = /^\d{1,9}\.\d{1,9}\.\d{1,9}$/;
const HOST_PATTERN: RegExp = /^(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/;
const CAPABILITIES: string[] = [
  'search', 'account', 'suggestions', 'recommendations', 'danmaku', 'devices', 'rankings',
  'seasons', 'cover', 'metadata', 'catalogState', 'mediaAuth'
];

export class QgModuleManifest {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  api: number = STORE_API;
  runtime: string = 'js';
  adult: boolean = false;
  hosts: string[] = [];
  capabilities: string[] = [];
  baseUrl: string = '';
  aliases: string[] = [];
  hostSuffixes: string[] = [];
  mediaAuthPaths: string[] = [];
  group: string = '';
  groupName: string = '';
  entryName: string = '';
  continuousFeed: boolean = false;
  allowEmptyCatalog: boolean = false;
  skipVipPrompt: boolean = false;
  noHostRotation: boolean = false;
  keepDetailEpisodes: boolean = false;
  browserFingerprint: boolean = false;

  static parse(raw: string): QgModuleManifest {
    const row: Record<string, Object> | null = QgJson.obj(QgJson.parse(raw));
    if (row === null || row['runtime'] !== 'js' || row['api'] !== STORE_API || typeof row['adult'] !== 'boolean') {
      throw new Error('站源清单格式或接口版本不兼容');
    }
    const manifest: QgModuleManifest = new QgModuleManifest();
    manifest.id = QgJson.str(row['id']);
    manifest.name = QgJson.str(row['name']).trim();
    manifest.version = QgJson.str(row['version']);
    manifest.description = QgJson.str(row['description']);
    manifest.adult = row['adult'] === true;
    manifest.hosts = QgModuleManifest.strings(row['hosts'], 64).map((host: string): string => host.toLowerCase());
    manifest.capabilities = QgModuleManifest.strings(row['capabilities'], 32);
    manifest.baseUrl = QgJson.str(row['baseUrl']);
    manifest.aliases = QgModuleManifest.strings(row['aliases'], 64);
    manifest.hostSuffixes = QgModuleManifest.strings(row['hostSuffixes'], 64);
    manifest.mediaAuthPaths = QgModuleManifest.strings(row['mediaAuthPaths'], 64);
    manifest.group = QgJson.str(row['group']);
    manifest.groupName = QgJson.str(row['groupName']);
    manifest.entryName = QgJson.str(row['entryName']);
    manifest.continuousFeed = row['continuousFeed'] === true;
    manifest.allowEmptyCatalog = row['allowEmptyCatalog'] === true;
    manifest.skipVipPrompt = row['skipVipPrompt'] === true;
    manifest.noHostRotation = row['noHostRotation'] === true;
    manifest.keepDetailEpisodes = row['keepDetailEpisodes'] === true;
    manifest.browserFingerprint = row['browserFingerprint'] === true;
    if (!ID_PATTERN.test(manifest.id) || !VERSION_PATTERN.test(manifest.version) || !manifest.name ||
      manifest.hosts.some((host: string): boolean => !HOST_PATTERN.test(host) || host.length > 253) ||
      manifest.capabilities.some((capability: string): boolean => !CAPABILITIES.includes(capability)) ||
      manifest.capabilities.includes('mediaAuth') !== (manifest.mediaAuthPaths.length > 0) ||
      manifest.mediaAuthPaths.some((path: string): boolean => !path.startsWith('/'))) {
      throw new Error('站源清单缺少必要字段或声明无效');
    }
    return manifest;
  }

  private static strings(value: Object | undefined, limit: number): string[] {
    if (value === undefined) {
      return [];
    }
    if (!Array.isArray(value) || value.length > limit) {
      throw new Error('站源清单字段不是有效列表');
    }
    const result: string[] = [];
    const items: Object[] = value as Object[];
    for (let index: number = 0; index < items.length; index++) {
      const item: Object = items[index];
      if (typeof item !== 'string' || item.trim() === '' || item.length > 1024) {
        throw new Error('站源清单列表项无效');
      }
      result.push(item.trim());
    }
    return result;
  }
}

export class QgModulePackage {
  readonly manifest: QgModuleManifest;
  readonly code: string;
  readonly rawManifest: string;
  readonly manifestHash: string;
  readonly entryHash: string;

  constructor(manifest: QgModuleManifest, code: string, rawManifest: string, manifestHash: string, entryHash: string) {
    this.manifest = manifest;
    this.code = code;
    this.rawManifest = rawManifest;
    this.manifestHash = manifestHash;
    this.entryHash = entryHash;
  }
}

interface QgSavedModule {
  manifest: string;
  code: string;
  manifestHash: string;
  entryHash: string;
}

export class QgModuleStore {
  private static inited: boolean = false;
  private static directory: string = '';
  private static packages: Map<string, QgModulePackage> = new Map();

  /**
   * 初始化：打开沙箱站源目录加载已装模块，然后把 rawfile 内置模块
   * 安装/升级进去（版本不高于已装时跳过，保留用户已有的更新版本）。
   */
  static init(context: common.UIAbilityContext): void {
    if (QgModuleStore.inited || context === null || !context.filesDir) {
      return;
    }
    QgModuleStore.inited = true;
    const directory: string = `${context.filesDir}/qg_verified_modules`;
    try {
      try {
        fileIo.mkdirSync(directory, true);
      } catch (error) {
        if (!fileIo.statSync(directory).isDirectory()) {
          throw new Error('站源存储路径不是文件夹');
        }
      }
      QgModuleStore.directory = directory;
      const names: string[] = fileIo.listFileSync(directory);
      for (let index: number = 0; index < names.length; index++) {
        const name: string = names[index];
        const id: string = name.slice(0, -5);
        if (!name.endsWith('.json') || !ID_PATTERN.test(id)) {
          continue;
        }
        try {
          const path: string = `${directory}/${name}`;
          const size: number = fileIo.statSync(path).size;
          if (size > MAX_PACKAGE_BYTES) {
            throw new Error('站源文件过大');
          }
          const saved: Record<string, Object> | null = QgJson.obj(QgJson.parse(fileIo.readTextSync(path)));
          if (saved === null) {
            throw new Error('站源存档损坏');
          }
          const pkg: QgModulePackage = QgModuleStore.buildPackage(QgJson.str(saved['manifest']), QgJson.str(saved['code']),
            QgJson.str(saved['manifestHash']), QgJson.str(saved['entryHash']));
          if (pkg.manifest.id !== id) {
            throw new Error('站源标识与文件名不符');
          }
          QgModuleStore.packages.set(id, pkg);
        } catch (error) {
          QgDiag.log('Module', `读取 ${id} 失败：${error}`);
        }
      }
    } catch (error) {
      QgDiag.log('Module', `站源目录不可用：${error}`);
    }
    QgModuleStore.installBundled(context);
  }

  /** 安装/升级 rawfile 内置模块（单个失败只记日志，不阻塞其余模块） */
  private static installBundled(context: common.UIAbilityContext): void {
    let ids: string[] = [];
    try {
      ids = context.resourceManager.getRawFileListSync(BUNDLED_ROOT);
    } catch (error) {
      QgDiag.log('Module', `内置站源目录不可读：${error}`);
      return;
    }
    for (let index = 0; index < ids.length; index++) {
      const id: string = ids[index];
      if (!ID_PATTERN.test(id)) {
        continue;
      }
      try {
        const rawManifest: string =
          qgUtf8Decode(context.resourceManager.getRawFileContentSync(`${BUNDLED_ROOT}/${id}/manifest.json`));
        const code: string =
          qgUtf8Decode(context.resourceManager.getRawFileContentSync(`${BUNDLED_ROOT}/${id}/main.js`));
        const manifest: QgModuleManifest = QgModuleManifest.parse(rawManifest);
        if (manifest.id !== id) {
          throw new Error('站源标识与目录名不符');
        }
        const current: QgModulePackage | undefined = QgModuleStore.packages.get(id);
        if (current !== undefined && QgModuleStore.compareVersion(manifest.version, current.manifest.version) <= 0) {
          continue;
        }
        const pkg: QgModulePackage = QgModuleStore.buildPackage(rawManifest, code,
          qgToHex(qgSha256(qgUtf8Encode(rawManifest))), qgToHex(qgSha256(qgUtf8Encode(code))));
        const saved: QgSavedModule = {
          manifest: pkg.rawManifest, code: pkg.code, manifestHash: pkg.manifestHash, entryHash: pkg.entryHash
        };
        QgModuleStore.write(`${QgModuleStore.storePath(id)}.json`, JSON.stringify(saved));
        QgModuleStore.packages.set(id, pkg);
      } catch (error) {
        QgDiag.log('Module', `内置站源 ${id} 安装失败：${error}`);
      }
    }
  }

  static installed(): QgModulePackage[] {
    return Array.from(QgModuleStore.packages.values());
  }

  static load(): QgModulePackage[] {
    return QgModuleStore.installed();
  }

  static loadState(id: string, name: string): string {
    const path: string = QgModuleStore.statePath(id, name);
    try {
      return fileIo.statSync(path).size <= MAX_STATE_BYTES ? fileIo.readTextSync(path) : '';
    } catch (error) {
      return '';
    }
  }

  static saveState(id: string, name: string, value: string): void {
    if (value.length > MAX_STATE_BYTES) {
      throw new Error('模块状态过大');
    }
    const bytes: number = qgUtf8Encode(value).length;
    if (bytes > MAX_STATE_BYTES) {
      throw new Error('模块状态过大');
    }
    const path: string = QgModuleStore.statePath(id, name);
    let total: number = 0;
    let count: number = 0;
    const names: string[] = fileIo.listFileSync(QgModuleStore.directory);
    for (const entry of names) {
      if (entry.startsWith(`${id}.`) && entry.endsWith('.state')) {
        count++;
        const existing: string = `${QgModuleStore.directory}/${entry}`;
        if (existing !== path) {
          total += fileIo.statSync(existing).size;
        }
      }
    }
    if (total + bytes > MAX_SOURCE_STATE_BYTES || count >= MAX_SOURCE_STATES &&
      !names.includes(`${id}.${name}.state`)) {
      throw new Error('模块状态存储已达上限');
    }
    QgModuleStore.write(path, value);
  }

  private static storePath(id: string): string {
    if (!QgModuleStore.directory || !ID_PATTERN.test(id)) {
      throw new Error('站源存储不可用');
    }
    return `${QgModuleStore.directory}/${id}`;
  }

  private static statePath(id: string, name: string): string {
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(name)) {
      throw new Error('无效的模块状态名');
    }
    return `${QgModuleStore.storePath(id)}.${name}.state`;
  }

  private static write(path: string, value: string): void {
    const temporary: string = `${path}.tmp`;
    try {
      const data: Uint8Array = qgUtf8Encode(value);
      const file: fileIo.File = fileIo.openSync(temporary,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        const count: number = fileIo.writeSync(file.fd, data.buffer as ArrayBuffer);
        if (count !== data.length) {
          throw new Error('站源写入不完整');
        }
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(temporary, path);
    } catch (error) {
      try {
        fileIo.unlinkSync(temporary);
      } catch (cleanupError) {
        QgDiag.log('Module', `无法清理临时文件：${cleanupError}`);
      }
      QgDiag.log('Module', `写入失败：${error}`);
      throw new Error('保存站源文件失败，请检查可用空间');
    }
  }

  private static buildPackage(raw: string, code: string, manifestHash: string, entryHash: string): QgModulePackage {
    const manifestBytes: Uint8Array = qgUtf8Encode(raw);
    const codeBytes: Uint8Array = qgUtf8Encode(code);
    if (manifestBytes.length > MAX_MANIFEST_BYTES || codeBytes.length > MAX_MODULE_BYTES || codeBytes.length === 0 ||
      qgToHex(qgSha256(manifestBytes)) !== manifestHash || qgToHex(qgSha256(codeBytes)) !== entryHash) {
      throw new Error('站源文件校验不符');
    }
    return new QgModulePackage(QgModuleManifest.parse(raw), code, raw, manifestHash, entryHash);
  }

  static compareVersion(left: string, right: string): number {
    const leftParts: number[] = left.split('.').map(Number);
    const rightParts: number[] = right.split('.').map(Number);
    for (let index: number = 0; index < 3; index++) {
      const lhs: number = leftParts[index] || 0;
      const rhs: number = rightParts[index] || 0;
      if (lhs !== rhs) {
        return lhs > rhs ? 1 : -1;
      }
    }
    return 0;
  }
}
