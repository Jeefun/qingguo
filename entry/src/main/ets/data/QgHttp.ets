/**
 * HTTP 封装：统一字节级请求/响应、代理、超时与诊断日志。
 * 每次请求独立 http.createHttp()（官方要求不可复用），用后销毁。
 */
import { http, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { QgDiag } from './QgDiag';

/** HTTP 响应（字节统一表示） */
export class QgHttpResponse {
  status: number = 0;
  data: Uint8Array = new Uint8Array(0);
  headers: Record<string, string> = {};

  text(): string {
    return qgUtf8Decode(this.data);
  }
}

/** 代理配置（由设置页更新） */
export class QgHttpProxy {
  enabled: boolean = false;
  host: string = '';
  port: number = 7890;
}

export class QgHttp {
  /** 全局代理配置；enabled 时走指定代理，否则走系统默认 */
  static proxy: QgHttpProxy = new QgHttpProxy();
  /** 按站源解析代理（由 QgStore 注册）：返回该站源的生效代理，无覆盖时回落全局 */
  static proxyResolver: ((sourceId: string) => QgHttpProxy) | null = null;

  /** 解析某站源的生效代理；无注册解析器或无覆盖时即全局代理 */
  static resolveProxy(sourceId: string): QgHttpProxy {
    if (sourceId.length > 0 && QgHttp.proxyResolver !== null) {
      return QgHttp.proxyResolver(sourceId);
    }
    return QgHttp.proxy;
  }

  private static methodOf(method: string): http.RequestMethod {
    if (method === 'POST') {
      return http.RequestMethod.POST;
    }
    if (method === 'PUT') {
      return http.RequestMethod.PUT;
    }
    if (method === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    if (method === 'HEAD') {
      return http.RequestMethod.HEAD;
    }
    return http.RequestMethod.GET;
  }

  /**
   * 发起请求。
   * @param url     完整 URL
   * @param method  GET/POST/...
   * @param headers 请求头
   * @param body    请求体（可空）
   * @param timeoutMs 连接/读取超时（毫秒）
   * @param sourceId 站源 ID（可选）：有按站源代理覆盖时使用该站源的代理
   */
  static async request(url: string, method: string, headers: Record<string, string>,
    body: Uint8Array | null, timeoutMs: number, maxBytes: number = 0, maxRedirects: number = 30,
    sourceId: string = ''): Promise<QgHttpResponse> {
    const client: http.HttpRequest = http.createHttp();
    const started: number = Date.now();
    try {
      const options: http.HttpRequestOptions = {
        method: QgHttp.methodOf(method),
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        maxRedirects: maxRedirects
      };
      if (maxBytes > 0) {
        options.maxLimit = maxBytes;
      }
      const proxy: QgHttpProxy = QgHttp.resolveProxy(sourceId);
      if (proxy.enabled && proxy.host.length > 0 && proxy.port > 0) {
        const hp: connection.HttpProxy = {
          host: proxy.host,
          port: proxy.port,
          exclusionList: []
        };
        options.usingProxy = hp;
      }
      if (body !== null) {
        options.extraData = qgBytesToArrayBuffer(body);
      }
      const resp: http.HttpResponse = await client.request(url, options);
      const result: QgHttpResponse = new QgHttpResponse();
      result.status = resp.responseCode;
      const raw: string | Object | ArrayBuffer = resp.result;
      if (raw === undefined || raw === null) {
        result.data = new Uint8Array(0);
      } else if (raw instanceof ArrayBuffer) {
        result.data = new Uint8Array(raw);
      } else if (typeof raw === 'string') {
        result.data = qgUtf8Encode(raw);
      } else {
        const serialized: string | undefined = JSON.stringify(raw);
        result.data = serialized !== undefined ? qgUtf8Encode(serialized) : new Uint8Array(0);
      }
      const rawHeader: Record<string, string> =
        JSON.parse(JSON.stringify(resp.header)) as Record<string, string>;
      const keys: string[] = Object.keys(rawHeader);
      for (let i: number = 0; i < keys.length; i++) {
        const k: string = keys[i];
        result.headers[k.toLowerCase()] = `${rawHeader[k]}`;
      }
      QgDiag.log('Http', `${method} ${url} -> ${result.status} ${result.data.length}B ` +
        `${Date.now() - started}ms`);
      return result;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      QgDiag.log('Http', `${method} ${url} 失败: ${err.code} ${err.message}`);
      throw new Error(`网络请求失败(${err.code}): ${err.message}`);
    } finally {
      client.destroy();
    }
  }

  /** GET 文本 */
  static async getText(url: string, headers: Record<string, string>,
    timeoutMs: number, sourceId: string = ''): Promise<string> {
    const resp: QgHttpResponse = await QgHttp.request(url, 'GET', headers, null, timeoutMs, 0, 30, sourceId);
    return resp.text();
  }

  /** GET 字节 */
  static async getBytes(url: string, headers: Record<string, string>,
    timeoutMs: number, sourceId: string = ''): Promise<Uint8Array> {
    const resp: QgHttpResponse = await QgHttp.request(url, 'GET', headers, null, timeoutMs, 0, 30, sourceId);
    return resp.data;
  }
}

/** Uint8Array → ArrayBuffer（拷贝，脱离原视图） */
export function qgBytesToArrayBuffer(data: Uint8Array): ArrayBuffer {
  const buffer: ArrayBuffer = new ArrayBuffer(data.length);
  const view: Uint8Array = new Uint8Array(buffer);
  view.set(data, 0);
  return buffer;
}
