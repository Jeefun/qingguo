/**
 * 本地 HTTP 媒体网关。
 * 参照真果鉴 Go 网关（app_stream.go）：在 127.0.0.1 随机端口起 HTTP 服务，
 * 播放器 / Image 组件只连本地网关；网关负责注入 Referer/UA、透传 Range、
 * 改写 m3u8（分片 / EXT-X-KEY / EXT-X-MAP 地址全部回落网关）。
 * 上游拉取用 http.requestInStream 流式接口（>5MB 大文件必须流式）。
 *
 * URL 方案（无状态）：
 *   http://127.0.0.1:{port}/{token}/f/{fileName}?u={encUpstream}&r={encReferer}&ua={encUa}
 * fileName 仅用于扩展名提示（u 参数才是权威上游地址）。
 */
import { http, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { QgDiag } from './QgDiag';
import { QgHttp, QgHttpProxy } from './QgHttp';

const GATEWAY_HOST: string = '127.0.0.1';
const LISTEN_ATTEMPTS: number = 20;
const SEND_QUEUE_CAP: number = 32 * 1024 * 1024;
const UPSTREAM_CONNECT_TIMEOUT: number = 10000;
const UPSTREAM_READ_TIMEOUT: number = 30000;

/** 单个客户端连接的代理状态 */
class QgGatewayConn {
  conn: socket.TCPSocketConnection | null = null;
  clientId: number = -1;
  buf: Uint8Array = new Uint8Array(0);
  handled: boolean = false;
  closed: boolean = false;
  /** 串行发送链，保证不并发写坏流 */
  sendChain: Promise<void> = Promise.resolve();
  queuedBytes: number = 0;
  /** 上游流式请求实例（用完必须 destroy） */
  upstream: http.HttpRequest | null = null;
  /** 响应头是否已写入客户端 */
  headersSent: boolean = false;
  /** 是否处于 playlist 缓冲模式 */
  buffering: boolean = false;
  /** 缓冲的 body（playlist 模式） */
  bodyParts: Uint8Array[] = [];
  /** 上游响应头（小写 key） */
  upstreamHeader: Record<string, string> = {};
  /** 本次请求的上游地址与注入头（m3u8 改写时复用） */
  upstreamUrl: string = '';
  upstreamReferer: string = '';
  upstreamUa: string = '';
}

export class QgGateway {
  private static server: socket.TCPSocketServer | null = null;
  private static port: number = 0;
  private static token: string = '';
  private static startPromise: Promise<void> | null = null;
  private static conns: Map<number, QgGatewayConn> = new Map<number, QgGatewayConn>();

  /** 是否已成功启动 */
  static isRunning(): boolean {
    return QgGateway.port > 0;
  }

  /** 确保网关已监听（幂等；失败则保持关闭，媒体走原始地址） */
  static async ready(): Promise<void> {
    if (QgGateway.port > 0) {
      return;
    }
    if (QgGateway.startPromise === null) {
      QgGateway.startPromise = QgGateway.doStart();
    }
    await QgGateway.startPromise;
  }

  private static async doStart(): Promise<void> {
    QgGateway.token = QgGateway.randomToken(16);
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    server.on('connect', (clientSocket: socket.TCPSocketConnection) => {
      QgGateway.onClient(clientSocket);
    });
    let bound: boolean = false;
    for (let attempt: number = 0; attempt < LISTEN_ATTEMPTS && !bound; attempt++) {
      const port: number = 49152 + Math.floor(Math.random() * 10000);
      try {
        const addr: socket.NetAddress = {
          address: GATEWAY_HOST,
          port: port,
          family: 1
        };
        await server.listen(addr);
        QgGateway.server = server;
        QgGateway.port = port;
        bound = true;
        QgDiag.log('Gateway', `listening on ${GATEWAY_HOST}:${port}`);
      } catch (error) {
        // 端口占用等情况，换下一个随机端口重试
      }
    }
    if (!bound) {
      QgDiag.log('Gateway', 'listen failed, gateway disabled');
    }
  }

  private static randomToken(bytes: number): string {
    let out: string = '';
    for (let i: number = 0; i < bytes; i++) {
      const v: number = Math.floor(Math.random() * 256);
      out += (v < 16 ? '0' : '') + v.toString(16);
    }
    return out;
  }

  /**
   * 播放地址包装：本地网关地址（未启动时原样返回）。
   * @param upstream 上游媒体地址（http/https）
   * @param headers  需要注入的请求头（Referer / User-Agent）
   */
  static mediaUrl(upstream: string, headers: Record<string, string>): string {
    if (!QgGateway.isRunning() || !QgGateway.isHttpUrl(upstream)) {
      return upstream;
    }
    return QgGateway.buildUrl(upstream, headers);
  }

  /** 封面地址包装（与媒体同端点，走网关注入头） */
  static imageUrl(upstream: string, headers: Record<string, string>): string {
    return QgGateway.mediaUrl(upstream, headers);
  }

  /** 网关地址是否可达（用于 UI 提示） */
  static endpoint(): string {
    return `http://${GATEWAY_HOST}:${QgGateway.port}`;
  }

  private static isHttpUrl(url: string): boolean {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  private static headerOf(headers: Record<string, string>, key: string): string {
    const v1: string | undefined = headers[key];
    if (v1 !== undefined && v1.length > 0) {
      return v1;
    }
    const lower: string = key.toLowerCase();
    const v2: string | undefined = headers[lower];
    if (v2 !== undefined && v2.length > 0) {
      return v2;
    }
    const upper: string = key.toUpperCase();
    const v3: string | undefined = headers[upper];
    return v3 !== undefined ? v3 : '';
  }

  private static buildUrl(upstream: string, headers: Record<string, string>): string {
    const referer: string = QgGateway.headerOf(headers, 'Referer');
    const ua: string = QgGateway.headerOf(headers, 'User-Agent');
    const name: string = QgGateway.fileNameOf(upstream);
    let url: string = `http://${GATEWAY_HOST}:${QgGateway.port}/${QgGateway.token}/f/` +
      `${name}?u=${encodeURIComponent(upstream)}`;
    if (referer.length > 0) {
      url += `&r=${encodeURIComponent(referer)}`;
    }
    if (ua.length > 0) {
      url += `&ua=${encodeURIComponent(ua)}`;
    }
    return url;
  }

  /** 上游 URL 最后一个路径段（扩展名提示用） */
  private static fileNameOf(upstream: string): string {
    let path: string = upstream;
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const slash: number = path.lastIndexOf('/');
    const name: string = slash >= 0 ? path.substring(slash + 1) : '';
    if (name.length === 0) {
      return 'stream.bin';
    }
    return name;
  }

  // ---------- 连接管理 ----------

  private static onClient(clientSocket: socket.TCPSocketConnection): void {
    const c: QgGatewayConn = new QgGatewayConn();
    c.conn = clientSocket;
    c.clientId = clientSocket.clientId;
    QgGateway.conns.set(c.clientId, c);
    clientSocket.on('message', (msgInfo: socket.SocketMessageInfo) => {
      QgGateway.onClientData(c, msgInfo.message);
    });
    clientSocket.on('close', () => {
      QgGateway.dropConn(c);
    });
  }

  private static dropConn(c: QgGatewayConn): void {
    if (c.closed) {
      return;
    }
    c.closed = true;
    QgGateway.conns.delete(c.clientId);
    QgGateway.destroyUpstream(c);
    const conn: socket.TCPSocketConnection | null = c.conn;
    if (conn !== null) {
      conn.close().catch(() => {
      });
    }
  }

  private static destroyUpstream(c: QgGatewayConn): void {
    const up: http.HttpRequest | null = c.upstream;
    c.upstream = null;
    if (up !== null) {
      try {
        up.destroy();
      } catch (error) {
        // 忽略销毁异常
      }
    }
  }

  private static onClientData(c: QgGatewayConn, chunk: ArrayBuffer): void {
    if (c.closed || c.handled) {
      return;
    }
    c.buf = QgGateway.concatBytes(c.buf, new Uint8Array(chunk));
    const end: number = QgGateway.headerEnd(c.buf);
    if (end < 0) {
      if (c.buf.length > 16384) {
        QgGateway.dropConn(c);
      }
      return;
    }
    c.handled = true;
    const headText: string = qgUtf8Decode(c.buf.subarray(0, end));
    QgGateway.handleRequest(c, headText);
  }

  private static concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  /** 找到 \r\n\r\n 的结束位置（header 区结尾，返回 4 字节定界符之后） */
  private static headerEnd(data: Uint8Array): number {
    const limit: number = data.length - 3;
    for (let i: number = 0; i < limit; i++) {
      if (data[i] === 13 && data[i + 1] === 10 && data[i + 2] === 13 && data[i + 3] === 10) {
        return i + 4;
      }
    }
    return -1;
  }

  // ---------- 请求处理 ----------

  private static handleRequest(c: QgGatewayConn, headText: string): void {
    const lines: string[] = headText.split('\r\n');
    if (lines.length === 0) {
      QgGateway.dropConn(c);
      return;
    }
    const parts: string[] = lines[0].split(' ');
    if (parts.length < 2) {
      QgGateway.respondSimple(c, 400, 'Bad Request', '');
      return;
    }
    const method: string = parts[0].toUpperCase();
    const target: string = parts[1];
    const clientHeader: Record<string, string> = {};
    for (let i: number = 1; i < lines.length; i++) {
      const colon: number = lines[i].indexOf(':');
      if (colon > 0) {
        clientHeader[lines[i].substring(0, colon).trim().toLowerCase()] = lines[i].substring(colon + 1).trim();
      }
    }
    // 校验 token：/{token}/f/{name}?...
    const pathAndQuery: string[] = QgGateway.splitQuery(target);
    const segs: string[] = pathAndQuery[0].split('/').filter((s: string): boolean => s.length > 0);
    const query: Record<string, string> = QgGateway.parseQuery(pathAndQuery[1]);
    if (segs.length < 3 || segs[0] !== QgGateway.token) {
      QgGateway.respondSimple(c, 404, 'Not Found', '');
      return;
    }
    const upstream: string = query['u'] !== undefined ? query['u'] : '';
    if (upstream.length === 0 || !QgGateway.isHttpUrl(upstream)) {
      QgGateway.respondSimple(c, 400, 'Bad Request', '');
      return;
    }
    if (method !== 'GET' && method !== 'HEAD') {
      QgGateway.respondSimple(c, 405, 'Method Not Allowed', '');
      return;
    }
    QgGateway.proxy(c, method, upstream, query, clientHeader);
  }

  private static splitQuery(target: string): string[] {
    const q: number = target.indexOf('?');
    if (q < 0) {
      return [target, ''];
    }
    return [target.substring(0, q), target.substring(q + 1)];
  }

  private static parseQuery(raw: string): Record<string, string> {
    const out: Record<string, string> = {};
    if (raw.length === 0) {
      return out;
    }
    const pairs: string[] = raw.split('&');
    for (let i: number = 0; i < pairs.length; i++) {
      const eq: number = pairs[i].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k: string = pairs[i].substring(0, eq);
      const v: string = pairs[i].substring(eq + 1);
      try {
        out[decodeURIComponent(k)] = decodeURIComponent(v);
      } catch (error) {
        out[k] = v;
      }
    }
    return out;
  }

  /** 简单文本响应后关闭 */
  private static respondSimple(c: QgGatewayConn, code: number, reason: string, text: string): void {
    const body: Uint8Array = qgUtf8Encode(text);
    const head: string = `HTTP/1.1 ${code} ${reason}\r\n` +
      `Content-Type: text/plain\r\n` +
      `Content-Length: ${body.length}\r\n` +
      `Connection: close\r\n\r\n`;
    QgGateway.sendBytes(c, qgUtf8Encode(head));
    QgGateway.sendBytes(c, body);
    QgGateway.finish(c);
  }

  /** 数据入发送队列（串行 + 背压上限） */
  private static sendBytes(c: QgGatewayConn, data: Uint8Array): void {
    if (c.closed) {
      return;
    }
    c.queuedBytes += data.length;
    if (c.queuedBytes > SEND_QUEUE_CAP) {
      QgGateway.destroyUpstream(c);
      QgGateway.dropConn(c);
      return;
    }
    const conn: socket.TCPSocketConnection | null = c.conn;
    if (conn === null) {
      return;
    }
    const buffer: ArrayBuffer = QgGateway.toArrayBuffer(data);
    c.sendChain = c.sendChain.then((): Promise<void> => {
      c.queuedBytes -= data.length;
      if (c.closed) {
        return Promise.resolve();
      }
      return conn.send({ data: buffer });
    }).catch(() => {
      QgGateway.dropConn(c);
    });
  }

  private static toArrayBuffer(data: Uint8Array): ArrayBuffer {
    const buffer: ArrayBuffer = new ArrayBuffer(data.length);
    new Uint8Array(buffer).set(data, 0);
    return buffer;
  }

  /** 响应完毕：等待发送链冲刷后关闭 */
  private static finish(c: QgGatewayConn): void {
    c.sendChain = c.sendChain.then(() => {
      QgGateway.dropConn(c);
    }).catch(() => {
      QgGateway.dropConn(c);
    });
  }

  // ---------- 上游代理 ----------

  private static proxy(c: QgGatewayConn, method: string, upstream: string,
    query: Record<string, string>, clientHeader: Record<string, string>): void {
    const referer: string = query['r'] !== undefined ? query['r'] : '';
    const ua: string = query['ua'] !== undefined ? query['ua'] : '';
    c.upstreamUrl = upstream;
    c.upstreamReferer = referer;
    c.upstreamUa = ua;
    const upstreamHeader: Record<string, string> = {};
    upstreamHeader['Accept-Encoding'] = 'identity';
    if (referer.length > 0) {
      upstreamHeader['Referer'] = referer;
    }
    if (ua.length > 0) {
      upstreamHeader['User-Agent'] = ua;
    }
    const range: string | undefined = clientHeader['range'];
    if (range !== undefined && range.length > 0) {
      upstreamHeader['Range'] = range;
    }

    const client: http.HttpRequest = http.createHttp();
    c.upstream = client;
    // 注意：headersReceive / dataReceive / dataEnd 必须在 requestInStream 之前同步订阅
    client.once('headersReceive', (header: Object) => {
      try {
        const parsed: Record<string, string> =
          JSON.parse(JSON.stringify(header)) as Record<string, string>;
        const keys: string[] = Object.keys(parsed);
        for (let i: number = 0; i < keys.length; i++) {
          c.upstreamHeader[keys[i].toLowerCase()] = `${parsed[keys[i]]}`;
        }
      } catch (error) {
        // 头解析失败按空处理
      }
    });
    client.on('dataReceive', (data: ArrayBuffer) => {
      QgGateway.onUpstreamChunk(c, data);
    });
    client.on('dataEnd', () => {
      QgGateway.onUpstreamEnd(c);
    });

    const options: http.HttpRequestOptions = {
      method: method === 'HEAD' ? http.RequestMethod.HEAD : http.RequestMethod.GET,
      header: upstreamHeader,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      connectTimeout: UPSTREAM_CONNECT_TIMEOUT,
      readTimeout: UPSTREAM_READ_TIMEOUT,
      usingProtocol: http.HttpProtocol.HTTP1_1
    };
    const proxy: QgHttpProxy = QgHttp.proxy;
    if (proxy.enabled && proxy.host.length > 0 && proxy.port > 0) {
      options.usingProxy = {
        host: proxy.host,
        port: proxy.port,
        exclusionList: []
      };
    }
    QgDiag.log('Gateway', `${method} ${upstream.substring(0, 96)}`);
    client.requestInStream(upstream, options)
      .then((code: number) => {
        QgGateway.onUpstreamStatus(c, code, method);
      })
      .catch((error: BusinessError) => {
        QgDiag.log('Gateway', `upstream failed: ${error.code} ${error.message}`);
        if (!c.headersSent) {
          QgGateway.respondSimple(c, 502, 'Bad Gateway', `upstream error ${error.code}`);
        } else {
          QgGateway.dropConn(c);
        }
      });
  }

  private static onUpstreamStatus(c: QgGatewayConn, code: number, method: string): void {
    if (c.closed) {
      return;
    }
    const contentType: string = c.upstreamHeader['content-type'] !== undefined
      ? c.upstreamHeader['content-type'] : '';
    const isPlaylist: boolean = contentType.toLowerCase().indexOf('mpegurl') >= 0 ||
      QgGateway.urlLooksLikePlaylist(c.upstreamUrl);
    if (isPlaylist) {
      c.buffering = true;
      c.bodyParts = [];
      return;
    }
    if (method === 'HEAD') {
      QgGateway.writeHead(c, code, false, -1);
      QgGateway.finish(c);
      return;
    }
    // 透传 Range 相关头与 Content-Length
    let length: number = -1;
    const lenText: string = c.upstreamHeader['content-length'] !== undefined
      ? c.upstreamHeader['content-length'] : '';
    if (lenText.length > 0) {
      const parsed: number = Number(lenText);
      if (!Number.isNaN(parsed) && parsed >= 0) {
        length = parsed;
      }
    }
    QgGateway.writeHead(c, code, false, length);
  }

  /** 写响应状态行 + 头（length>=0 用 Content-Length，否则 chunked） */
  private static writeHead(c: QgGatewayConn, code: number, dropRange: boolean, length: number): void {
    if (c.closed || c.headersSent) {
      return;
    }
    c.headersSent = true;
    let head: string = `HTTP/1.1 ${code} ${QgGateway.reasonOf(code)}\r\n`;
    const contentType: string = c.upstreamHeader['content-type'] !== undefined
      ? c.upstreamHeader['content-type'] : 'application/octet-stream';
    head += `Content-Type: ${contentType}\r\n`;
    if (length >= 0) {
      head += `Content-Length: ${length}\r\n`;
    } else {
      head += `Transfer-Encoding: chunked\r\n`;
    }
    if (!dropRange) {
      const range: string = c.upstreamHeader['content-range'] !== undefined
        ? c.upstreamHeader['content-range'] : '';
      if (range.length > 0) {
        head += `Content-Range: ${range}\r\n`;
      }
    }
    head += `Accept-Ranges: bytes\r\n`;
    if (contentType.toLowerCase().indexOf('image/') === 0) {
      head += `Cache-Control: public, max-age=86400\r\n`;
    } else {
      head += `Cache-Control: no-store\r\n`;
    }
    head += `Connection: close\r\n\r\n`;
    QgGateway.sendBytes(c, qgUtf8Encode(head));
  }

  private static reasonOf(code: number): string {
    switch (code) {
      case 200: return 'OK';
      case 206: return 'Partial Content';
      case 301: return 'Moved Permanently';
      case 302: return 'Found';
      case 304: return 'Not Modified';
      case 400: return 'Bad Request';
      case 403: return 'Forbidden';
      case 404: return 'Not Found';
      case 405: return 'Method Not Allowed';
      case 416: return 'Range Not Satisfiable';
      case 500: return 'Internal Server Error';
      case 502: return 'Bad Gateway';
      case 503: return 'Service Unavailable';
      default: return 'Response';
    }
  }

  private static onUpstreamChunk(c: QgGatewayConn, data: ArrayBuffer): void {
    if (c.closed) {
      return;
    }
    if (c.buffering) {
      c.bodyParts.push(new Uint8Array(data));
      return;
    }
    if (!c.headersSent) {
      // 状态头尚未写（理论上不会先于 headersReceive），保守缓冲
      c.bodyParts.push(new Uint8Array(data));
      return;
    }
    QgGateway.writeBody(c, new Uint8Array(data));
  }

  /** body 写出：有 Content-Length 时裸写，chunked 时按块编码 */
  private static writeBody(c: QgGatewayConn, data: Uint8Array): void {
    const lenText: string = c.upstreamHeader['content-length'] !== undefined
      ? c.upstreamHeader['content-length'] : '';
    const hasLength: boolean = lenText.length > 0 && !Number.isNaN(Number(lenText));
    if (hasLength) {
      QgGateway.sendBytes(c, data);
      return;
    }
    if (data.length === 0) {
      return;
    }
    const sizeHex: string = data.length.toString(16);
    const chunkHead: Uint8Array = qgUtf8Encode(`${sizeHex}\r\n`);
    const chunkTail: Uint8Array = qgUtf8Encode('\r\n');
    QgGateway.sendBytes(c, QgGateway.concatBytes(QgGateway.concatBytes(chunkHead, data), chunkTail));
  }

  private static onUpstreamEnd(c: QgGatewayConn): void {
    QgGateway.destroyUpstream(c);
    if (c.closed) {
      return;
    }
    if (c.buffering) {
      QgGateway.flushPlaylist(c);
      return;
    }
    if (!c.headersSent) {
      // 一直没有状态（异常防御），按空 200 结束
      QgGateway.writeHead(c, 200, false, 0);
      QgGateway.finish(c);
      return;
    }
    const lenText: string = c.upstreamHeader['content-length'] !== undefined
      ? c.upstreamHeader['content-length'] : '';
    const hasLength: boolean = lenText.length > 0 && !Number.isNaN(Number(lenText));
    if (!hasLength) {
      QgGateway.sendBytes(c, qgUtf8Encode('0\r\n\r\n'));
    }
    QgGateway.finish(c);
  }

  /** playlist 缓冲完成：改写分片/密钥地址后整体下发 */
  private static flushPlaylist(c: QgGatewayConn): void {
    const merged: Uint8Array = QgGateway.concatAll(c.bodyParts);
    c.bodyParts = [];
    const text: string = qgUtf8Decode(merged);
    const upstreamUrl: string = QgGateway.currentUpstreamOf(c);
    const rewritten: string = QgGateway.rewritePlaylist(text, upstreamUrl, c);
    const body: Uint8Array = qgUtf8Encode(rewritten);
    c.upstreamHeader['content-type'] = 'application/vnd.apple.mpegurl';
    QgGateway.writeHead(c, 200, true, body.length);
    QgGateway.sendBytes(c, body);
    QgGateway.finish(c);
  }

  /** URL 路径是否以 .m3u8 结尾（content-type 不规范时的兜底判断） */
  private static urlLooksLikePlaylist(url: string): boolean {
    let path: string = url;
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    return path.toLowerCase().endsWith('.m3u8');
  }

  private static concatAll(parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let i: number = 0; i < parts.length; i++) {
      out.set(parts[i], offset);
      offset += parts[i].length;
    }
    return out;
  }

  /** 连接记录的上游地址（playlist 改写时用于相对地址解析） */
  private static currentUpstreamOf(c: QgGatewayConn): string {
    return c.upstreamUrl;
  }

  /**
   * 改写 m3u8：分片行 / EXT-X-KEY / EXT-X-MAP / EXT-X-I-FRAME-STREAM-INF 的 URI
   * 全部解析为绝对地址后包装成本地网关地址（携带相同 Referer/UA）。
   */
  static rewritePlaylist(text: string, playlistUrl: string, c: QgGatewayConn): string {
    const lines: string[] = text.split('\n');
    const out: string[] = [];
    for (let i: number = 0; i < lines.length; i++) {
      let line: string = lines[i];
      const trimmed: string = line.trim();
      if (trimmed.length === 0) {
        out.push(line);
        continue;
      }
      if (trimmed.startsWith('#EXT-X-KEY') || trimmed.startsWith('#EXT-X-MAP') ||
        trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF') || trimmed.startsWith('#EXT-X-MEDIA')) {
        line = QgGateway.rewriteAttrUri(trimmed, playlistUrl);
      } else if (!trimmed.startsWith('#')) {
        const abs: string = QgGateway.resolveUrl(playlistUrl, trimmed);
        line = QgGateway.buildProxyLine(abs, c);
      }
      out.push(line);
    }
    return out.join('\n');
  }

  /** 改写标签行里的 URI="..." 属性 */
  private static rewriteAttrUri(line: string, playlistUrl: string): string {
    const marker: string = 'URI="';
    const idx: number = line.indexOf(marker);
    if (idx < 0) {
      return line;
    }
    const start: number = idx + marker.length;
    const end: number = line.indexOf('"', start);
    if (end < 0) {
      return line;
    }
    const uri: string = line.substring(start, end);
    if (!QgGateway.isHttpUrl(uri)) {
      return line;
    }
    const abs: string = QgGateway.resolveUrl(playlistUrl, uri);
    return line.substring(0, start) + abs + line.substring(end);
  }

  /** 绝对媒体地址 → 本地网关地址行（沿用该连接的 Referer/UA） */
  private static buildProxyLine(absUrl: string, c: QgGatewayConn): string {
    if (!QgGateway.isHttpUrl(absUrl)) {
      return absUrl;
    }
    const headers: Record<string, string> = {};
    const referer: string = c.upstreamReferer;
    const ua: string = c.upstreamUa;
    if (referer !== undefined && referer.length > 0) {
      headers['Referer'] = referer;
    }
    if (ua !== undefined && ua.length > 0) {
      headers['User-Agent'] = ua;
    }
    return QgGateway.buildUrl(absUrl, headers);
  }

  /** 相对地址 → 绝对地址（标准 URL join 简化版） */
  static resolveUrl(base: string, ref: string): string {
    if (QgGateway.isHttpUrl(ref)) {
      return ref;
    }
    const schemeEnd: number = base.indexOf('://');
    if (schemeEnd < 0) {
      return ref;
    }
    const scheme: string = base.substring(0, schemeEnd);
    let rest: string = base.substring(schemeEnd + 3);
    const pathSlash: number = rest.indexOf('/');
    let host: string = pathSlash >= 0 ? rest.substring(0, pathSlash) : rest;
    let basePath: string = pathSlash >= 0 ? rest.substring(pathSlash) : '/';
    const q: number = basePath.indexOf('?');
    if (q >= 0) {
      basePath = basePath.substring(0, q);
    }
    if (ref.startsWith('//')) {
      return `${scheme}:${ref}`;
    }
    if (ref.startsWith('/')) {
      return `${scheme}://${host}${ref}`;
    }
    const dirEnd: number = basePath.lastIndexOf('/');
    const dir: string = dirEnd >= 0 ? basePath.substring(0, dirEnd + 1) : '/';
    return `${scheme}://${host}${QgGateway.normalizePath(`${dir}${ref}`)}`;
  }

  /** 处理路径里的 ./ 与 ../ */
  static normalizePath(path: string): string {
    const segs: string[] = path.split('/');
    const stack: string[] = [];
    for (let i: number = 0; i < segs.length; i++) {
      const s: string = segs[i];
      if (s === '..') {
        if (stack.length > 1) {
          stack.pop();
        }
      } else if (s !== '.' && s.length > 0) {
        stack.push(s);
      }
    }
    let out: string = stack.join('/');
    if (!out.startsWith('/')) {
      out = `/${out}`;
    }
    return out;
  }
}
