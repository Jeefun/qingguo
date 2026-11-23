import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { connection } from '@kit.NetworkKit';
import url from '@ohos.url';
import { QgModulePackage, QgModuleStore } from './QgModuleStore';
import { QgHttp, QgHttpResponse } from './QgHttp';
import { QgJson } from './QgJson';
import { QgDiag } from './QgDiag';
import { qgBase64Decode, qgBase64Encode, qgConcat, qgFromHex, qgToHex, qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { qgHmacSha256, qgMd5, qgSha256, qgSha512 } from './QgCrypto';
import { qgGzipStored, qgGunzip } from './QgDeflate';
import { parseModuleHtml } from './QgModuleHtml';

const MAX_BODY: number = 2 << 20;
const MAX_CRYPTO: number = 1 << 20;
const MAX_CACHE: number = 512;
const MAX_CACHE_BYTES: number = 8 << 20;

class QgModuleCacheValue {
  value: string;
  expires: number;
  constructor(value: string, expires: number) { this.value = value; this.expires = expires; }
}

class QgModuleHostFailure extends Error {
  status: number = 0;
  body: string = '';
  blocked: boolean = false;
  oversized: boolean = false;
  backoff: boolean = false;
}

class QgModuleFetchResult {
  status: number;
  headers: Record<string, string[]>;
  body: string;
  bytes: number[] | null = null;
  blocked: boolean;
  oversized: boolean = false;
  url: string;
  constructor(response: QgHttpResponse, address: string) {
    this.status = response.status;
    this.body = response.text();
    this.url = address;
    this.blocked = this.status === 403 || this.status === 429;
    this.headers = {};
    Object.keys(response.headers).forEach((key: string) => { this.headers[key] = [response.headers[key]]; });
  }
}

interface QgModuleUrl {
  scheme: string;
  host: string;
  hostname: string;
  port: string;
  path: string;
  query: string;
  fragment: string;
  userInfo: boolean;
  href: string;
}

interface QgModuleKeyPair {
  privateKey: number[];
  publicKey: number[];
}

interface QgModuleHostResponse {
  value: Object | null;
}

interface QgModuleHostError {
  error: string;
  status: number;
  body: string;
  blocked: boolean;
  oversized: boolean;
  backoff: boolean;
}

interface QgModuleCatalogContext {
  more: boolean;
  background: boolean;
}

interface QgModuleTextResult { body: string; url: string; }
interface QgModulePlaylistResult { playlist: string; url: string; durationMs: number; }

export class QgModuleHost {
  private pkg: QgModulePackage;
  private static cache: Map<string, Map<string, QgModuleCacheValue>> = new Map();
  private preferred: string = '';
  private known: Set<string> = new Set();
  private more: boolean = false;
  private deadline: number = Date.now() + 60000;

  constructor(pkg: QgModulePackage) { this.pkg = pkg; }

  beginCall(): void { this.deadline = Date.now() + 60000; }

  async validateMediaUrl(raw: string): Promise<void> {
    const parsed: url.URL = this.allowed(raw, true);
    await this.publicDns(parsed.hostname);
  }

  validateCoverUrl(raw: string): void { this.allowed(raw, true); }

  setKnown(ids: string[], more: boolean): void {
    this.known = new Set(ids);
    this.more = more;
  }

  handle(method: string, argsJson: string, respond: (responseJson: string) => void): void {
    this.dispatch(method, argsJson).then((value: Object | null) => {
      const response: QgModuleHostResponse = { value: value };
      const encoded: string = JSON.stringify(response);
      respond(encoded.length <= 12 << 20 ? encoded : '{"error":"站源返回内容过大"}');
    }).catch((error: Error) => {
      const failure: QgModuleHostFailure = error as QgModuleHostFailure;
      const response: QgModuleHostError = {
        error: error.message || String(error), status: failure.status ?? 0, body: failure.body ?? '',
        blocked: failure.blocked === true, oversized: failure.oversized === true, backoff: failure.backoff === true
      };
      respond(JSON.stringify(response));
    });
  }

  private async dispatch(method: string, encoded: string): Promise<Object | null> {
    if (Date.now() > this.deadline || encoded.length > 12 << 20) throw new Error('站源请求超时或内容过大');
    const args: Object[] = QgJson.arr(QgJson.parse(encoded));
    const first: string = QgJson.str(args[0]);
    switch (method) {
      case 'retries': return 2;
      case 'maxPages': return 100;
      case 'reserve': {
        const request: Record<string, Object> = this.record(args[0]);
        this.allowed(QgJson.str(request['url']));
        return Date.now();
      }
      case 'sleep': {
        const milliseconds: number = Math.max(0, Math.min(QgJson.num(args[0]), 10000, this.deadline - Date.now()));
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, milliseconds); });
        return null;
      }
      case 'catalogContext': {
        const result: QgModuleCatalogContext = { more: this.more, background: false };
        return result;
      }
      case 'isKnown': return this.known.has(first);
      case 'reportProgress': return null;
      case 'cacheGet': return this.cacheGet(first);
      case 'cacheSet': this.cacheSet(first, args[1], QgJson.num(args[2])); return null;
      case 'loadState': return QgModuleStore.loadState(this.pkg.manifest.id, first);
      case 'saveState': QgModuleStore.saveState(this.pkg.manifest.id, first, QgJson.str(args[1])); return null;
      case 'log': QgDiag.log('Module', this.pkg.manifest.id + ': ' + first.slice(0, 1000)); return null;
      case 'preserveIntegers': return this.preserveIntegers(first);
      case 'parseUrl': return this.parsedUrl(first);
      case 'resolveUrl': return url.URL.parseURL(QgJson.str(args[1]), first).toString();
      case 'parseHtml': return parseModuleHtml(first);
      case 'preferredSite': return this.preferred;
      case 'fetch': return this.fetch(this.record(args[0]));
      case 'fetchText': return this.fetchText(this.record(args[0]));
      case 'fetchPlaylist': return this.playlist(this.record(args[0]));
      case 'finishMedia':
      case 'prepareWebMedia': return this.media(this.record(args[0]));
      case 'utf8Encode': return Array.from(qgUtf8Encode(first));
      case 'utf8Decode': return qgUtf8Decode(this.bytes(args[0]));
      case 'hexEncode': return qgToHex(this.bytes(args[0]));
      case 'hexDecode': {
        if (first.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(first)) throw new Error('十六进制内容无效');
        return Array.from(qgFromHex(first));
      }
      case 'base64Encode': return qgBase64Encode(this.bytes(args[0]));
      case 'base64Decode': {
        if (!/^[A-Za-z0-9+/]*={0,2}$/.test(first.trim()) || first.trim().length % 4 === 1) {
          throw new Error('Base64 内容无效');
        }
        return Array.from(qgBase64Decode(first));
      }
      case 'md5': return Array.from(qgMd5(this.bytes(args[0])));
      case 'sha256': return Array.from(qgSha256(this.bytes(args[0])));
      case 'sha512': return Array.from(qgSha512(this.bytes(args[0])));
      case 'gzip': return Array.from(qgGzipStored(this.bytes(args[0], MAX_BODY)));
      case 'gunzip': return Array.from(this.gunzip(this.bytes(args[0], MAX_BODY)));
      case 'randomBytes': {
        const length: number = QgJson.num(args[0]);
        if (!Number.isInteger(length) || length < 0 || length > 1024) throw new Error('随机字节数无效');
        if (length === 0) return [];
        return Array.from((await cryptoFramework.createRandom().generateRandom(length)).data);
      }
      case 'aesCbcEncrypt': return Array.from(await this.aes('CBC', true, args));
      case 'aesCbcDecrypt': return Array.from(await this.aes('CBC', false, args));
      case 'aesGcmSeal': return Array.from(await this.aes('GCM', true, args));
      case 'aesGcmOpen': return Array.from(await this.aes('GCM', false, args));
      case 'hkdfSha256': return Array.from(this.hkdf(args));
      case 'ecdhP256KeyPair': return this.keyPair();
      case 'ecdhP256': return Array.from(await this.ecdh(args));
      default: throw new Error('站源调用了不支持的宿主接口：' + method);
    }
  }

  private record(value: Object | undefined): Record<string, Object> {
    const result: Record<string, Object> | null = QgJson.obj(value);
    if (result === null) throw new Error('站源请求参数格式无效');
    return result;
  }

  private bytes(value: Object | undefined, limit: number = MAX_CRYPTO): Uint8Array {
    if (typeof value === 'string') {
      if (value.length > limit) throw new Error('字节内容过大');
      return qgUtf8Encode(value);
    }
    if (!Array.isArray(value) || value.length > limit) throw new Error('字节内容无效或过大');
    const result: Uint8Array = new Uint8Array(value.length);
    for (let index: number = 0; index < value.length; index++) {
      const item: Object = value[index];
      if (typeof item !== 'number' || !Number.isInteger(item) || item < 0 || item > 255) throw new Error('字节内容无效');
      result[index] = item;
    }
    return result;
  }

  private gunzip(data: Uint8Array): Uint8Array {
    if (data.length < 10 || data[0] !== 0x1f || data[1] !== 0x8b) throw new Error('gzip 内容无效');
    try {
      return qgGunzip(data, MAX_BODY);
    } catch (error) {
      const message: string = (error as Error).message;
      if (message.includes('解压输出超出限制') || message.includes('解压后内容过大')) {
        throw new Error('解压后内容过大');
      }
      throw new Error('gzip 内容无效');
    }
  }

  private parsedUrl(raw: string): QgModuleUrl {
    if (raw.length > 8192) throw new Error('请求地址过长');
    const address: url.URL = url.URL.parseURL(raw);
    const result: QgModuleUrl = {
      scheme: address.protocol.replace(/:$/, ''), host: address.host, hostname: address.hostname,
      port: address.port, path: address.pathname, query: address.search.replace(/^\?/, ''),
      fragment: address.hash.replace(/^#/, ''), userInfo: !!address.username || !!address.password, href: address.toString()
    };
    return result;
  }

  private allowed(raw: string, media: boolean = false): url.URL {
    const parsed: url.URL = url.URL.parseURL(raw);
    const host: string = parsed.hostname.toLowerCase();
    if (raw.length > 8192 || !['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password ||
      !host || this.privateAddress(host) || (parsed.port !== '' && parsed.port !== '80' && parsed.port !== '443')) {
      throw new Error('站源请求地址无效');
    }
    if (!media && !this.pkg.manifest.hosts.some((pattern: string): boolean =>
      pattern.startsWith('*.') ? host.endsWith(pattern.slice(1)) && host !== pattern.slice(2) : host === pattern)) {
      throw new Error('站源清单未声明访问 ' + host);
    }
    return parsed;
  }

  private privateAddress(value: string): boolean {
    const host: string = value.toLowerCase().replace(/^\[|\]$/g, '');
    if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) return true;
    if (host.includes(':')) return !/^[23][0-9a-f]{0,3}:/.test(host);
    if (!/^\d+\.\d+\.\d+\.\d+$/.test(host)) return false;
    const parts: number[] = host.split('.').map(Number);
    return parts[0] === 0 || parts[0] === 10 || parts[0] === 127 || parts[0] >= 224 ||
      (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] === 192 && (parts[1] === 168 || parts[1] === 0)) ||
      (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) || (parts[0] === 198 && parts[1] >= 18 && parts[1] <= 19);
  }

  private async publicDns(host: string): Promise<void> {
    if (QgHttp.resolveProxy(this.pkg.manifest.id).enabled) return;
    const addresses: connection.NetAddress[] = await connection.getAddressesByName(host);
    if (addresses.length === 0 || addresses.some((item: connection.NetAddress): boolean => this.privateAddress(item.address))) {
      throw new Error('站源域名解析到了本地网络地址');
    }
  }

  private async fetch(request: Record<string, Object>, media: boolean = false): Promise<QgModuleFetchResult> {
    let address: string = QgJson.str(request['url']);
    let method: string = QgJson.str(request['method']).toUpperCase() || 'GET';
    if (!['GET', 'POST', 'HEAD', 'PUT', 'DELETE'].includes(method)) throw new Error('不支持的站源请求方法');
    let headers: Record<string, string> = {};
    const rawHeaders: Record<string, Object> | null = QgJson.obj(request['headers']);
    if (rawHeaders !== null) {
      for (const name of Object.keys(rawHeaders)) {
        const value: string = QgJson.str(rawHeaders[name]);
        if (name.length > 128 || value.length > 8192 || !/^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/.test(name) ||
          /[\r\n]/.test(value) || ['host', 'content-length', 'connection', 'proxy-authorization'].includes(name.toLowerCase())) {
          throw new Error('站源请求头无效');
        }
        headers[name] = value;
      }
    }
    if (Object.keys(headers).length > 64) throw new Error('站源请求头过多');
    const rawBody: Object | undefined = request['body'];
    let body: Uint8Array | null = null;
    if (typeof rawBody === 'string') {
      body = qgUtf8Encode(rawBody);
    } else if (rawBody !== undefined && rawBody !== null) {
      body = this.bytes(rawBody, MAX_BODY);
    }
    if (body !== null && body.length > MAX_BODY) throw new Error('站源请求内容过大');
    const binary: boolean = request['binary'] === true;
    const limit: number = Math.max(1, Math.min(QgJson.num(request['limit']) || MAX_BODY, MAX_BODY));
    for (let redirect: number = 0; redirect < 6; redirect++) {
      const parsed: url.URL = this.allowed(address, media);
      await this.publicDns(parsed.hostname);
      const timeout: number = Math.max(1, Math.min(QgJson.num(request['timeoutMs']) || 20000, 30000,
        this.deadline - Date.now()));
      if (Date.now() >= this.deadline) throw new Error('站源请求超时');
      const response: QgHttpResponse = await QgHttp.request(address, method, headers, body, timeout, limit, 0,
        this.pkg.manifest.id);
      const result: QgModuleFetchResult = new QgModuleFetchResult(response, address);
      if (response.data.length > limit) {
        const error: QgModuleHostFailure = new QgModuleHostFailure('站源响应过大');
        error.oversized = true;
        throw error;
      }
      if ([301, 302, 303, 307, 308].includes(response.status) && request['followRedirects'] !== false) {
        const next: string = url.URL.parseURL(response.headers['location'] || '', address).toString();
        if (!response.headers['location']) throw new Error('站源重定向地址缺失');
        if (this.allowed(next, media).host !== parsed.host) {
          const forwarded: Record<string, string> = {};
          for (const name of Object.keys(headers)) {
            if (!['authorization', 'cookie', 'origin', 'referer'].includes(name.toLowerCase())) forwarded[name] = headers[name];
          }
          headers = forwarded;
        }
        address = next;
        if (response.status === 303 || ((response.status === 301 || response.status === 302) && method === 'POST')) {
          method = 'GET';
          body = null;
        }
        continue;
      }
      const accepts: Object[] = QgJson.arr(request['acceptStatus']);
      const accepted: boolean = accepts.some((item: Object): boolean => item === response.status) && QgJson.parse(result.body) !== null;
      if (request['anyStatus'] !== true && !accepted && (response.status < 200 || response.status >= 400)) {
        const error: QgModuleHostFailure = new QgModuleHostFailure(this.pkg.manifest.name + ' HTTP ' + response.status);
        error.status = result.status;
        error.body = result.body.slice(0, 128 << 10);
        error.blocked = result.blocked;
        error.backoff = result.status === 429;
        throw error;
      }
      this.preferred = parsed.protocol + '//' + parsed.host;
      if (binary) {
        result.bytes = Array.from(response.data);
        result.body = '';
      }
      return result;
    }
    throw new Error('站源重定向次数过多');
  }

  private async fetchText(request: Record<string, Object>): Promise<QgModuleTextResult> {
    const addresses: string[] = [QgJson.str(request['url'])];
    QgJson.arr(request['mirrors']).forEach((address: Object) => { if (typeof address === 'string') addresses.push(address); });
    let failure: Error = new Error('站源请求失败');
    for (const address of addresses.slice(0, 8)) {
      try {
        const headers: Record<string, string> = {};
        if (request['referer']) headers['Referer'] = QgJson.str(request['referer']);
        if (request['userAgent']) headers['User-Agent'] = QgJson.str(request['userAgent']);
        if (request['cookie']) headers['Cookie'] = QgJson.str(request['cookie']);
        const body: string = QgJson.str(request['body']);
        const options: Record<string, Object> = {};
        options['url'] = address;
        options['headers'] = headers;
        options['body'] = body;
        options['method'] = body ? 'POST' : 'GET';
        options['followRedirects'] = true;
        const response: QgModuleFetchResult = await this.fetch(options);
        const result: QgModuleTextResult = { body: response.body, url: response.url };
        return result;
      } catch (error) { failure = error as Error; }
    }
    throw failure;
  }

  private async playlist(request: Record<string, Object>): Promise<QgModulePlaylistResult> {
    const headers: Record<string, string> = {};
    const credentials: Record<string, Object> | null = QgJson.obj(request['credentials']);
    if (request['referer']) headers['Referer'] = QgJson.str(request['referer']);
    if (credentials !== null) {
      for (const key of ['cookie', 'origin', 'referer', 'userAgent']) {
        if (credentials[key]) headers[key === 'userAgent' ? 'User-Agent' : key] = QgJson.str(credentials[key]);
      }
    }
    const options: Record<string, Object> = {};
    options['url'] = QgJson.str(request['url']);
    options['headers'] = headers;
    options['method'] = 'GET';
    options['followRedirects'] = true;
    const response: QgModuleFetchResult = await this.fetch(options, true);
    if (!response.body.trimStart().startsWith('#EXTM3U')) throw new Error('站源未返回有效的 HLS 清单');
    let duration: number = 0;
    const pattern: RegExp = /#EXTINF:([0-9.]+)/g;
    let match: RegExpExecArray | null = pattern.exec(response.body);
    while (match !== null) { duration += Number(match[1]) || 0; match = pattern.exec(response.body); }
    const result: QgModulePlaylistResult = { playlist: response.body, url: response.url, durationMs: Math.round(duration * 1000) };
    return result;
  }

  private media(input: Record<string, Object>): Record<string, Object> {
    if (input['url']) this.allowed(QgJson.str(input['url']), true);
    for (const key of ['cencKey', 'hlsKey']) {
      if (Array.isArray(input[key])) input[key] = qgBase64Encode(this.bytes(input[key]));
    }
    return input;
  }

  private cacheMap(): Map<string, QgModuleCacheValue> {
    const id: string = this.pkg.manifest.id + '@' + this.pkg.entryHash;
    let found: Map<string, QgModuleCacheValue> | undefined = QgModuleHost.cache.get(id);
    if (found === undefined) {
      const prefix: string = this.pkg.manifest.id + '@';
      for (const key of Array.from(QgModuleHost.cache.keys())) {
        if (key.startsWith(prefix)) QgModuleHost.cache.delete(key);
      }
      found = new Map(); QgModuleHost.cache.set(id, found);
    }
    return found;
  }

  private cacheGet(key: string): string | null {
    const cache: Map<string, QgModuleCacheValue> = this.cacheMap();
    const hit: QgModuleCacheValue | undefined = cache.get(key);
    if (hit === undefined) return null;
    if (hit.expires !== 0 && hit.expires < Date.now()) { cache.delete(key); return null; }
    return hit.value;
  }

  private cacheSet(key: string, value: Object | undefined, ttl: number): void {
    if (key.length > 512 || (typeof value !== 'string' && value !== null && value !== undefined)) throw new Error('站源缓存值无效');
    const cache: Map<string, QgModuleCacheValue> = this.cacheMap();
    if (value === null || value === undefined) { cache.delete(key); return; }
    const text: string = QgJson.str(value);
    if (text.length > 1 << 20) throw new Error('站源缓存内容过大');
    let size: number = 0;
    cache.forEach((item: QgModuleCacheValue) => { size += item.value.length * 2; });
    if (cache.size >= MAX_CACHE || size + text.length * 2 > MAX_CACHE_BYTES) cache.clear();
    cache.set(key, new QgModuleCacheValue(text, ttl > 0 ? Date.now() + Math.min(ttl, 30 * 86400000) : 0));
  }

  private preserveIntegers(text: string): string {
    if (text.length > MAX_BODY) throw new Error('JSON 内容过大');
    return text.replace(/"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g, (token: string): string => {
      if (token.startsWith('"') || /[.eE]/.test(token)) return token;
      const value: number = Number(token);
      return Number.isSafeInteger(value) ? token : '"' + token + '"';
    });
  }

  private async aes(mode: string, encrypt: boolean, args: Object[]): Promise<Uint8Array> {
    const key: Uint8Array = this.bytes(args[0]);
    const iv: Uint8Array = this.bytes(args[1]);
    let input: Uint8Array = this.bytes(args[2]);
    if (![16, 24, 32].includes(key.length)) throw new Error('AES 密钥长度无效');
    const algorithm: string = 'AES' + key.length * 8;
    const generator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator(algorithm);
    const nativeKey: cryptoFramework.SymKey = await generator.convertKey({ data: key });
    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(algorithm + '|' + mode + '|NoPadding');
    let parameters: cryptoFramework.ParamsSpec;
    if (mode === 'CBC') {
      if (iv.length !== 16 || input.length % 16 !== 0) throw new Error('AES 向量或数据长度无效');
      const ivParameters: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } };
      parameters = ivParameters;
    } else {
      if (iv.length !== 12 || (!encrypt && input.length < 16)) throw new Error('AES-GCM 数据无效');
      const authTag: Uint8Array = encrypt ? new Uint8Array(16) : input.slice(input.length - 16);
      if (!encrypt) input = input.slice(0, input.length - 16);
      const gcmParameters: cryptoFramework.GcmParamsSpec = {
        algName: 'GcmParamsSpec', iv: { data: iv }, aad: { data: this.bytes(args[3]) }, authTag: { data: authTag }
      };
      parameters = gcmParameters;
    }
    await cipher.init(encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE,
      nativeKey, parameters);
    return (await cipher.doFinal({ data: input })).data;
  }

  private hkdf(args: Object[]): Uint8Array {
    const length: number = QgJson.num(args[3]);
    if (!Number.isInteger(length) || length < 1 || length > 1024) throw new Error('HKDF 长度无效');
    const salt: Uint8Array = this.bytes(args[1]);
    const extracted: Uint8Array = qgHmacSha256(salt.length ? salt : new Uint8Array(32), this.bytes(args[0]));
    const info: Uint8Array = this.bytes(args[2]);
    let previous: Uint8Array = new Uint8Array(0);
    const chunks: Uint8Array[] = [];
    for (let index: number = 1; index <= Math.ceil(length / 32); index++) {
      previous = qgHmacSha256(extracted, qgConcat([previous, info, Uint8Array.from([index])]));
      chunks.push(previous);
    }
    return qgConcat(chunks).slice(0, length);
  }

  private fixedInteger(value: bigint): Uint8Array {
    return qgFromHex(value.toString(16).padStart(64, '0'));
  }

  private async keyPair(): Promise<QgModuleKeyPair> {
    const pair: cryptoFramework.KeyPair = await cryptoFramework.createAsyKeyGenerator('ECC256').generateKeyPair();
    const privateKey: Uint8Array = this.fixedInteger(pair.priKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_SK_BN) as bigint);
    const x: Uint8Array = this.fixedInteger(pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_X_BN) as bigint);
    const y: Uint8Array = this.fixedInteger(pair.pubKey.getAsyKeySpec(cryptoFramework.AsyKeySpecItem.ECC_PK_Y_BN) as bigint);
    const result: QgModuleKeyPair = { privateKey: Array.from(privateKey), publicKey: Array.from(qgConcat([Uint8Array.from([4]), x, y])) };
    return result;
  }

  private async ecdh(args: Object[]): Promise<Uint8Array> {
    const secret: Uint8Array = this.bytes(args[0]);
    const publicKey: Uint8Array = this.bytes(args[1]);
    if (secret.length !== 32 || publicKey.length !== 65 || publicKey[0] !== 4) throw new Error('ECDH 密钥无效');
    const privateDer: Uint8Array = qgConcat([qgFromHex('3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420'), secret]);
    const publicDer: Uint8Array = qgConcat([qgFromHex('3059301306072a8648ce3d020106082a8648ce3d030107034200'), publicKey]);
    const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('ECC256');
    const privatePair: cryptoFramework.KeyPair = await generator.convertKey(null, { data: privateDer });
    const publicPair: cryptoFramework.KeyPair = await generator.convertKey({ data: publicDer }, null);
    return (await cryptoFramework.createKeyAgreement('ECC256').generateSecret(privatePair.priKey, publicPair.pubKey)).data;
  }
}
