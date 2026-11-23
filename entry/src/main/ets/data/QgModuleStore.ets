import { fileIo } from '@kit.CoreFileKit';
import { QgDiag } from './QgDiag';
import { QgHttp, QgHttpResponse } from './QgHttp';
import { QgJson } from './QgJson';
import { qgToHex, qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { qgSha256 } from './QgCrypto';

const INDEX_URLS: string[] = [
  'https://raw.githubusercontent.com/guoapp-modules/index/main/index.json',
  'https://api.github.com/repos/guoapp-modules/index/contents/index.json?ref=main',
  'https://fastly.jsdelivr.net/gh/guoapp-modules/index@main/index.json',
  'https://gcore.jsdelivr.net/gh/guoapp-modules/index@main/index.json',
  'https://cdn.jsdelivr.net/gh/guoapp-modules/index@main/index.json'
];
const FILE_URLS: string[] = [
  'https://raw.githubusercontent.com/{repo}/{tag}/{file}',
  'https://fastly.jsdelivr.net/gh/{repo}@{tag}/{file}',
  'https://gcore.jsdelivr.net/gh/{repo}@{tag}/{file}',
  'https://cdn.jsdelivr.net/gh/{repo}@{tag}/{file}',
  'https://gh-proxy.com/https://raw.githubusercontent.com/{repo}/{tag}/{file}',
  'https://api.github.com/repos/{repo}/contents/{file}?ref={tag}'
];
const STORE_API: number = 1;
const MAX_INDEX_BYTES: number = 1 << 20;
const MAX_MANIFEST_BYTES: number = 64 << 10;
const MAX_MODULE_BYTES: number = 4 << 20;
const MAX_PACKAGE_BYTES: number = 6 * MAX_MODULE_BYTES + 6 * MAX_MANIFEST_BYTES + 4096;
const MAX_STATE_BYTES: number = 256 << 10;
const MAX_SOURCE_STATE_BYTES: number = 4 << 20;
const MAX_SOURCE_STATES: number = 32;
const ID_PATTERN: RegExp = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const VERSION_PATTERN: RegExp = /^\d{1,9}\.\d{1,9}\.\d{1,9}$/;
const HASH_PATTERN: RegExp = /^[0-9a-f]{64}$/;
const HOST_PATTERN: RegExp = /^(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/;
const CAPABILITIES: string[] = [
  'search', 'account', 'suggestions', 'recommendations', 'danmaku', 'devices', 'rankings',
  'seasons', 'cover', 'metadata', 'catalogState', 'mediaAuth'
];

export class QgModuleEntry {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  adult: boolean = false;
  repo: string = '';
  tag: string = '';
  manifestHash: string = '';
  entryHash: string = '';
  installedVersion: string = '';

  static fromObject(value: Object): QgModuleEntry | null {
    const row: Record<string, Object> | null = QgJson.obj(value);
    if (row === null || row['api'] !== STORE_API || typeof row['adult'] !== 'boolean') {
      return null;
    }
    const hashes: Record<string, Object> | null = QgJson.field(row, 'sha256');
    if (hashes === null) {
      return null;
    }
    const item: QgModuleEntry = new QgModuleEntry();
    item.id = QgJson.str(row['id']);
    item.name = QgJson.str(row['name']).trim();
    item.version = QgJson.str(row['version']);
    item.description = QgJson.str(row['description']);
    item.adult = row['adult'] === true;
    item.repo = QgJson.str(row['repo']);
    item.tag = QgJson.str(row['tag']);
    item.manifestHash = QgJson.str(hashes['manifest.json']);
    item.entryHash = QgJson.str(hashes['main.js']);
    if (!ID_PATTERN.test(item.id) || item.name.length === 0 || !VERSION_PATTERN.test(item.version) ||
      item.repo !== `guoapp-modules/${item.id}` || item.tag !== `v${item.version}` ||
      !HASH_PATTERN.test(item.manifestHash) || !HASH_PATTERN.test(item.entryHash)) {
      return null;
    }
    return item;
  }

  installed(): boolean {
    return this.installedVersion.length > 0;
  }

  hasUpdate(): boolean {
    return this.installed() && QgModuleStore.compareVersion(this.version, this.installedVersion) > 0;
  }
}

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
  private static directory: string = '';
  private static accepted: Map<string, QgModuleEntry> = new Map();
  private static packages: Map<string, QgModulePackage> = new Map();
  private static prepared: WeakSet<QgModulePackage> = new WeakSet();

  static init(filesDir: string): void {
    if (QgModuleStore.directory || !filesDir) {
      return;
    }
    const directory: string = `${filesDir}/qg_verified_modules`;
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
          const pkg: QgModulePackage = QgModuleStore.verify(QgJson.str(saved['manifest']), QgJson.str(saved['code']),
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
  }

  static installed(): QgModulePackage[] {
    return Array.from(QgModuleStore.packages.values());
  }

  static load(): QgModulePackage[] {
    return QgModuleStore.installed();
  }

  static async index(): Promise<QgModuleEntry[]> {
    let reason: string = '';
    for (let index: number = 0; index < INDEX_URLS.length; index++) {
      try {
        const data: Uint8Array = await QgModuleStore.get(INDEX_URLS[index], MAX_INDEX_BYTES);
        const parsed: Record<string, Object> | null = QgJson.obj(QgJson.parse(qgUtf8Decode(data)));
        if (parsed === null || !Array.isArray(parsed['modules'])) {
          throw new Error('索引格式无效');
        }
        if (parsed['format'] !== 1) {
          throw new Error('索引格式不兼容，请更新青果');
        }
        const entries: Map<string, QgModuleEntry> = new Map();
        const rows: Object[] = QgJson.arr(parsed['modules']);
        for (let row: number = 0; row < rows.length; row++) {
          const entry: QgModuleEntry | null = QgModuleEntry.fromObject(rows[row]);
          if (entry !== null && !entries.has(entry.id)) {
            entry.installedVersion = QgModuleStore.packages.get(entry.id)?.manifest.version ?? '';
            entries.set(entry.id, entry);
          }
        }
        QgModuleStore.accepted = entries;
        return Array.from(entries.values());
      } catch (error) {
        reason = error instanceof Error ? error.message : String(error);
      }
    }
    throw new Error(`无法连接官方站源商店，请检查网络后刷新。${reason ? ' ' + reason : ''}`);
  }

  static async download(entry: QgModuleEntry): Promise<QgModulePackage> {
    const approved: QgModuleEntry | undefined = QgModuleStore.accepted.get(entry.id);
    if (approved === undefined || approved.version !== entry.version || approved.manifestHash !== entry.manifestHash ||
      approved.entryHash !== entry.entryHash) {
      throw new Error('站源索引已变化，请刷新后重试');
    }
    const installed: string = QgModuleStore.packages.get(approved.id)?.manifest.version ?? '';
    if (installed && QgModuleStore.compareVersion(approved.version, installed) < 0) {
      throw new Error('线上版本低于已安装版本');
    }
    const files: Uint8Array[] = await Promise.all([
      QgModuleStore.fetch(approved, 'manifest.json', approved.manifestHash, MAX_MANIFEST_BYTES),
      QgModuleStore.fetch(approved, 'main.js', approved.entryHash, MAX_MODULE_BYTES)
    ]);
    const pkg: QgModulePackage = QgModuleStore.verify(qgUtf8Decode(files[0]), qgUtf8Decode(files[1]),
      approved.manifestHash, approved.entryHash);
    if (pkg.manifest.id !== approved.id || pkg.manifest.version !== approved.version || pkg.manifest.adult !== approved.adult) {
      throw new Error('站源清单与线上索引不符');
    }
    QgModuleStore.prepared.add(pkg);
    return pkg;
  }

  static commit(pkg: QgModulePackage): void {
    if (!QgModuleStore.prepared.has(pkg)) {
      throw new Error('请先从官方商店下载站源');
    }
    const verified: QgModulePackage = QgModuleStore.verify(pkg.rawManifest, pkg.code, pkg.manifestHash, pkg.entryHash);
    if (verified.manifest.id !== pkg.manifest.id || verified.manifest.version !== pkg.manifest.version) {
      throw new Error('站源清单在安装前已变化');
    }
    const current: QgModulePackage | undefined = QgModuleStore.packages.get(pkg.manifest.id);
    if (current !== undefined && QgModuleStore.compareVersion(pkg.manifest.version, current.manifest.version) < 0) {
      throw new Error('线上版本低于已安装版本');
    }
    const saved: QgSavedModule = {
      manifest: pkg.rawManifest, code: pkg.code, manifestHash: pkg.manifestHash, entryHash: pkg.entryHash
    };
    QgModuleStore.write(`${QgModuleStore.storePath(pkg.manifest.id)}.json`, JSON.stringify(saved));
    QgModuleStore.packages.set(pkg.manifest.id, verified);
    QgModuleStore.prepared.delete(pkg);
  }

  static remove(id: string): void {
    const path: string = `${QgModuleStore.storePath(id)}.json`;
    fileIo.unlinkSync(path);
    QgModuleStore.packages.delete(id);
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

  private static verify(raw: string, code: string, manifestHash: string, entryHash: string): QgModulePackage {
    const manifestBytes: Uint8Array = qgUtf8Encode(raw);
    const codeBytes: Uint8Array = qgUtf8Encode(code);
    if (manifestBytes.length > MAX_MANIFEST_BYTES || codeBytes.length > MAX_MODULE_BYTES || codeBytes.length === 0 ||
      qgToHex(qgSha256(manifestBytes)) !== manifestHash || qgToHex(qgSha256(codeBytes)) !== entryHash) {
      throw new Error('站源文件校验不符');
    }
    return new QgModulePackage(QgModuleManifest.parse(raw), code, raw, manifestHash, entryHash);
  }

  private static async get(url: string, limit: number): Promise<Uint8Array> {
    const accept: string = url.startsWith('https://api.github.com/') ? 'application/vnd.github.raw+json' : '*/*';
    const response: QgHttpResponse = await QgHttp.request(url, 'GET', { 'Accept': accept, 'User-Agent': 'QingGuo' },
      null, 12000, limit, 0);
    if (response.status !== 200) {
      throw new Error(`HTTP ${response.status}`);
    }
    if (response.data.length === 0 || response.data.length > limit) {
      throw new Error('站源文件为空或过大');
    }
    return response.data;
  }

  private static async fetch(entry: QgModuleEntry, file: string, expected: string, limit: number): Promise<Uint8Array> {
    let reason: string = '';
    for (let index: number = 0; index < FILE_URLS.length; index++) {
      try {
        const url: string = FILE_URLS[index].replace('{repo}', entry.repo).replace('{tag}', entry.tag).replace('{file}', file);
        const data: Uint8Array = await QgModuleStore.get(url, limit);
        if (qgToHex(qgSha256(data)) !== expected) {
          throw new Error('SHA-256 校验不符');
        }
        return data;
      } catch (error) {
        reason = error instanceof Error ? error.message : String(error);
      }
    }
    throw new Error(`下载 ${entry.name} 的 ${file} 失败：${reason}`);
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
