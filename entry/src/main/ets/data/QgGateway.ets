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
import { taskpool, url } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { qgFromHex, qgUtf8Decode, qgUtf8Encode } from './QgBytes';
import { QgDiag } from './QgDiag';
import { QgHttp, QgHttpProxy, QgHttpResponse } from './QgHttp';
import { qgDecryptInWorker } from './QgCencTask';

const GATEWAY_HOST: string = '127.0.0.1';
const LISTEN_ATTEMPTS: number = 20;
const SEND_QUEUE_CAP: number = 32 * 1024 * 1024;
const UPSTREAM_CONNECT_TIMEOUT: number = 10000;
const UPSTREAM_READ_TIMEOUT: number = 30000;
const PLAYLIST_BYTES_LIMIT: number = 4 * 1024 * 1024;
const MEDIA_SESSION_LIMIT: number = 16;

class QgGatewayMediaSession {
  headers: Record<string, string> = {};
  playlist: string = '';
  upstream: string = '';
  hlsKey: Uint8Array = new Uint8Array(0);
  /** 按站源代理：所属站源 ID（空=跟随全局） */
  sourceId: string = '';
}

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
  sessionId: string = '';
  /** 按站源代理：本次上游请求所属站源（空=跟随全局） */
  sourceId: string = '';
  bufferedBytes: number = 0;
  upstreamEnded: boolean = false;
  statusReceived: boolean = false;
}

export class QgGateway {
  private static server: socket.TCPSocketServer | null = null;
  private static port: number = 0;
  private static token: string = '';
  private static startPromise: Promise<void> | null = null;
  private static conns: Map<number, QgGatewayConn> = new Map<number, QgGatewayConn>();
  /** CENC 解密结果缓存（key = keyHex|upstream），最多 2 份（约 60MB） */
  private static decCache: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  /** 进行中的解密任务（并发 Range 请求去重） */
  private static decPending: Map<string, Promise<Uint8Array>> = new Map<string, Promise<Uint8Array>>();
  private static mediaSessions: Map<string, QgGatewayMediaSession> = new Map<string, QgGatewayMediaSession>();

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
    try {
      await QgGateway.startPromise;
    } finally {
      // 启动失败时不能把失败的 Promise 永久缓存，否则后续播放永远不会重试
      if (QgGateway.port === 0) {
        QgGateway.startPromise = null;
      }
    }
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
        const err: BusinessError = error as BusinessError;
        QgDiag.log('Gateway', `listen ${port} 失败: ${err.code} ${err.message}`);
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
   * @param sourceId 站源 ID（按站源代理用，空=跟随全局）
   */
  static mediaUrl(upstream: string, headers: Record<string, string>, sourceId: string = ''): string {
    if (!QgGateway.isRunning() || !QgGateway.isHttpUrl(upstream)) {
      return upstream;
    }
    // 已是本网关地址（解密端点等）不再二次包装
    if (upstream.startsWith(`http://${GATEWAY_HOST}:${QgGateway.port}/`)) {
      return upstream;
    }
    return QgGateway.buildUrl(upstream, headers, sourceId);
  }

  /** 封面地址包装（与媒体同端点，走网关注入头） */
  static imageUrl(upstream: string, headers: Record<string, string>, sourceId: string = ''): string {
    return QgGateway.mediaUrl(upstream, headers, sourceId);
  }

  static async playlistMediaUrl(text: string, upstream: string, headers: Record<string, string>,
    hlsKey: Uint8Array = new Uint8Array(0), sourceId: string = ''): Promise<string> {
    if (!QgGateway.isHttpUrl(upstream) || qgUtf8Encode(text).length > PLAYLIST_BYTES_LIMIT ||
      (text.length > 0 && !text.trim().replace(/^\uFEFF/, '').startsWith('#EXTM3U')) ||
      (hlsKey.length !== 0 && hlsKey.length !== 16)) {
      throw new Error('模块播放列表或密钥无效');
    }
    await QgGateway.ready();
    if (!QgGateway.isRunning()) {
      throw new Error('本地播放网关未启动');
    }
    const sessionId: string = QgGateway.storeMediaSession(headers, text, upstream, hlsKey, sourceId);
    if (text.length === 0) {
      return QgGateway.buildSessionUrl(upstream, sessionId, sourceId);
    }
    return `${QgGateway.endpoint()}/${QgGateway.token}/playlist/${sessionId}/index.m3u8`;
  }

  private static storeMediaSession(headers: Record<string, string>, playlist: string,
    upstream: string, hlsKey: Uint8Array, sourceId: string = ''): string {
    const clean: Record<string, string> = QgGateway.cleanMediaHeaders(headers);
    const encoded: string = JSON.stringify(clean);
    if (playlist.length === 0 && hlsKey.length === 0) {
      for (const entry of QgGateway.mediaSessions.entries()) {
        const previous: QgGatewayMediaSession = entry[1];
        if (previous.playlist.length === 0 && previous.hlsKey.length === 0 &&
          previous.sourceId === sourceId &&
          JSON.stringify(previous.headers) === encoded) {
          QgGateway.mediaSessions.delete(entry[0]);
          QgGateway.mediaSessions.set(entry[0], previous);
          return entry[0];
        }
      }
    }
    while (QgGateway.mediaSessions.size >= MEDIA_SESSION_LIMIT) {
      const oldest: string | undefined = QgGateway.mediaSessions.keys().next().value;
      if (oldest === undefined) break;
      QgGateway.mediaSessions.delete(oldest);
    }
    const session: QgGatewayMediaSession = new QgGatewayMediaSession();
    session.headers = clean;
    session.playlist = playlist;
    session.upstream = upstream;
    session.hlsKey = new Uint8Array(hlsKey);
    session.sourceId = sourceId;
    const id: string = QgGateway.randomToken(16);
    QgGateway.mediaSessions.set(id, session);
    return id;
  }

  private static cleanMediaHeaders(headers: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const name of Object.keys(headers)) {
      const lower: string = name.toLowerCase();
      const value: string = headers[name];
      if (!/^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/.test(name) || /[\r\n]/.test(value) ||
        lower === 'host' || lower === 'connection' || lower === 'content-length' ||
        lower === 'transfer-encoding' || lower.startsWith('sec-fetch-')) continue;
      out[name] = value;
    }
    return out;
  }

  private static buildSessionUrl(upstream: string, sessionId: string, sourceId: string = ''): string {
    let url: string = `${QgGateway.endpoint()}/${QgGateway.token}/f/${QgGateway.fileNameOf(upstream)}` +
      `?u=${encodeURIComponent(upstream)}&s=${sessionId}`;
    if (sourceId.length > 0) {
      url += `&src=${encodeURIComponent(sourceId)}`;
    }
    return url;
  }

  /**
   * CENC 加密媒体地址包装：本地网关解密端点（未启动时原样返回）。
   * 网关收到请求后下载上游加密 MP4 → 就地 AES-CTR 解密 → 缓存并支持 Range 下发。
   * @param upstream 上游加密 MP4 地址
   * @param headers  注入 Referer / User-Agent
   * @param keyHex   16 字节内容密钥的 hex（32 字符）
   */
  static decryptedMediaUrl(upstream: string, headers: Record<string, string>, keyHex: string,
    sourceId: string = ''): string {
    if (!QgGateway.isRunning() || !QgGateway.isHttpUrl(upstream) || keyHex.length !== 32) {
      return upstream;
    }
    const referer: string = QgGateway.headerOf(headers, 'Referer');
    const ua: string = QgGateway.headerOf(headers, 'User-Agent');
    const name: string = QgGateway.fileNameOf(upstream);
    let url: string = `http://${GATEWAY_HOST}:${QgGateway.port}/${QgGateway.token}/dec/` +
      `${name}?u=${encodeURIComponent(upstream)}&k=${keyHex}`;
    if (referer.length > 0) {
      url += `&r=${encodeURIComponent(referer)}`;
    }
    if (ua.length > 0) {
      url += `&ua=${encodeURIComponent(ua)}`;
    }
    if (sourceId.length > 0) {
      url += `&src=${encodeURIComponent(sourceId)}`;
    }
    const clean: Record<string, string> = QgGateway.cleanMediaHeaders(headers);
    if (Object.keys(clean).some((name: string): boolean =>
      name.toLowerCase() !== 'referer' && name.toLowerCase() !== 'user-agent')) {
      url += `&s=${QgGateway.storeMediaSession(clean, '', '', new Uint8Array(0), sourceId)}`;
    }
    return url;
  }

  /** 网关地址是否可达（用于 UI 提示） */
  static endpoint(): string {
    return `http://${GATEWAY_HOST}:${QgGateway.port}`;
  }

  /**
   * 预热 CENC 解密缓存：提前下载并解密下一集，切集时 Range 请求直接命中内存。
   * 与播放共用 decCache/decPending（并发去重、≤2 份 FIFO），不额外占内存配额。
   */
  static prewarmDecrypted(upstream: string, headers: Record<string, string>,
    keyHex: string, sourceId: string = ''): Promise<Uint8Array> {
    const referer: string = QgGateway.headerOf(headers, 'Referer');
    const ua: string = QgGateway.headerOf(headers, 'User-Agent');
    const clean: Record<string, string> = QgGateway.cleanMediaHeaders(headers);
    const hasExtra: boolean = Object.keys(clean).some((name: string): boolean =>
      name.toLowerCase() !== 'referer' && name.toLowerCase() !== 'user-agent');
    return QgGateway.fetchDecrypted(upstream, referer, ua, keyHex, hasExtra ? clean : {}, sourceId);
  }

  private static isHttpUrl(raw: string): boolean {
    try {
      const parsed: url.URL = new url.URL(raw);
      return (parsed.protocol === 'http:' || parsed.protocol === 'https:') && parsed.hostname.length > 0 &&
        parsed.username.length === 0 && parsed.password.length === 0;
    } catch (error) {
      return false;
    }
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

  private static buildUrl(upstream: string, headers: Record<string, string>, sourceId: string = ''): string {
    const clean: Record<string, string> = QgGateway.cleanMediaHeaders(headers);
    if (Object.keys(clean).some((name: string): boolean =>
      name.toLowerCase() !== 'referer' && name.toLowerCase() !== 'user-agent')) {
      const sessionId: string = QgGateway.storeMediaSession(clean, '', '', new Uint8Array(0), sourceId);
      return QgGateway.buildSessionUrl(upstream, sessionId, sourceId);
    }
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
    if (sourceId.length > 0) {
      url += `&src=${encodeURIComponent(sourceId)}`;
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
    if (method !== 'GET' && method !== 'HEAD') {
      QgGateway.respondSimple(c, 405, 'Method Not Allowed', '');
      return;
    }
    if (segs[1] === 'playlist' || segs[1] === 'key') {
      QgGateway.serveSession(c, method, segs[2], segs[1] === 'key');
      return;
    }
    const sessionId: string = query['s'] ?? '';
    if (sessionId.length > 0 && !QgGateway.mediaSessions.has(sessionId)) {
      QgGateway.respondSimple(c, 410, 'Gone', 'media session expired');
      return;
    }
    if (segs[1] !== 'f' && segs[1] !== 'dec') {
      QgGateway.respondSimple(c, 404, 'Not Found', '');
      return;
    }
    const upstream: string = query['u'] !== undefined ? query['u'] : '';
    if (upstream.length === 0 || !QgGateway.isHttpUrl(upstream)) {
      QgGateway.respondSimple(c, 400, 'Bad Request', '');
      return;
    }
    c.sourceId = query['src'] ?? '';
    if (segs[1] === 'dec') {
      QgGateway.serveDecrypted(c, method, upstream, query, clientHeader);
      return;
    }
    QgGateway.proxy(c, method, upstream, query, clientHeader);
  }

  private static serveSession(c: QgGatewayConn, method: string, id: string, key: boolean): void {
    const session: QgGatewayMediaSession | undefined = QgGateway.mediaSessions.get(id);
    if (session === undefined || (key && session.hlsKey.length !== 16) || (!key && session.playlist.length === 0)) {
      QgGateway.respondSimple(c, 404, 'Not Found', '');
      return;
    }
    QgGateway.mediaSessions.delete(id);
    QgGateway.mediaSessions.set(id, session);
    c.sessionId = id;
    c.upstreamUrl = session.upstream;
    c.upstreamReferer = QgGateway.headerOf(session.headers, 'Referer');
    c.upstreamUa = QgGateway.headerOf(session.headers, 'User-Agent');
    c.sourceId = session.sourceId;
    try {
      const body: Uint8Array = key ? session.hlsKey :
        qgUtf8Encode(QgGateway.rewritePlaylist(session.playlist, session.upstream, c));
      const contentType: string = key ? 'application/octet-stream' : 'application/vnd.apple.mpegurl';
      const head: string = `HTTP/1.1 200 OK\r\nContent-Type: ${contentType}\r\n` +
        `Content-Length: ${body.length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`;
      c.headersSent = true;
      QgGateway.sendBytes(c, qgUtf8Encode(head));
      if (method === 'GET') QgGateway.sendBytes(c, body);
      QgGateway.finish(c);
    } catch (error) {
      QgGateway.respondSimple(c, 502, 'Bad Gateway', (error as Error).message);
    }
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

  // ---------- CENC 解密端点 ----------

  /** /dec 请求入口：下载 + 解密（去重）后按 Range 下发 */
  private static serveDecrypted(c: QgGatewayConn, method: string, upstream: string,
    query: Record<string, string>, clientHeader: Record<string, string>): void {
    const keyHex: string = query['k'] !== undefined ? query['k'] : '';
    if (keyHex.length !== 32) {
      QgGateway.respondSimple(c, 400, 'Bad Request', 'invalid cenc key');
      return;
    }
    const referer: string = query['r'] !== undefined ? query['r'] : '';
    const ua: string = query['ua'] !== undefined ? query['ua'] : '';
    const session: QgGatewayMediaSession | undefined = QgGateway.mediaSessions.get(query['s'] ?? '');
    QgGateway.fetchDecrypted(upstream, referer, ua, keyHex, session?.headers ?? {}, c.sourceId)
      .then((data: Uint8Array): void => {
        QgGateway.serveDecryptedBuffer(c, method, data, clientHeader);
      })
      .catch((error: Error): void => {
        QgDiag.log('Gateway', `dec failed: ${error.message}`);
        if (!c.headersSent && !c.closed) {
          QgGateway.respondSimple(c, 502, 'Bad Gateway', `decrypt error: ${error.message}`);
        } else {
          QgGateway.dropConn(c);
        }
      });
  }

  /** 下载上游加密 MP4 → 就地解密 → 缓存（并发去重） */
  private static fetchDecrypted(upstream: string, referer: string, ua: string,
    keyHex: string, extraHeaders: Record<string, string> = {},
    sourceId: string = ''): Promise<Uint8Array> {
    const cacheKey: string = `${keyHex}|${upstream}|${JSON.stringify(extraHeaders)}`;
    const cached: Uint8Array | undefined = QgGateway.decCache.get(cacheKey);
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    const pending: Promise<Uint8Array> | undefined = QgGateway.decPending.get(cacheKey);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<Uint8Array> =
      QgGateway.downloadAndDecrypt(upstream, referer, ua, keyHex, cacheKey, extraHeaders, sourceId);
    QgGateway.decPending.set(cacheKey, task);
    return task;
  }

  /** 复制请求头并按需附加 Range（ArkTS 不用对象展开） */
  private static copyHeaders(src: Record<string, string>, range: string): Record<string, string> {
    const out: Record<string, string> = {};
    const keys: string[] = Object.keys(src);
    for (let i: number = 0; i < keys.length; i++) {
      out[keys[i]] = src[keys[i]];
    }
    if (range.length > 0) {
      out['Range'] = range;
    }
    return out;
  }

  /**
   * 大文件并发分段下载：先用 HEAD 取 Content-Length，再按 4 段带 Range 并发 GET。
   * CDN 单连接实测 15MB 要 8.3 秒，是「缓存时间」的主要来源；分段可显著缩短。
   * 任何一步不支持或长度不符都自动回退单连接下载，保证可用性。
   */
  private static async fetchUpstream(upstream: string,
    headers: Record<string, string>, sourceId: string = ''): Promise<Uint8Array> {
    try {
      // 用 1 字节 Range 探测：实测该 CDN 拒绝 HEAD，但可能支持 Range。
      const probe: QgHttpResponse = await QgHttp.request(upstream, 'GET',
        QgGateway.copyHeaders(headers, 'bytes=0-0'), null, 15000, 0, 30, sourceId);
      if (probe.status !== 206) {
        // 服务器忽略 Range 直接给了整份文件，直接复用，避免重复下载
        if (probe.status === 200 && probe.data.length >= 2 * 1024 * 1024) {
          return probe.data;
        }
        return QgHttp.getBytes(upstream, headers, 120000, sourceId);
      }
      const rangeText: string = probe.headers['content-range'] !== undefined
        ? probe.headers['content-range'] : '';
      const matched: RegExpMatchArray | null = rangeText.match(/bytes 0-0\/([0-9]+)/);
      if (matched === null) {
        return QgHttp.getBytes(upstream, headers, 120000, sourceId);
      }
      const total: number = Number(matched[1]);
      if (Number.isNaN(total) || total < 2 * 1024 * 1024) {
        return QgHttp.getBytes(upstream, headers, 120000, sourceId);
      }
      const parts: number = 4;
      const chunk: number = Math.ceil(total / parts);
      const pending: Promise<Uint8Array>[] = [];
      for (let i: number = 0; i < parts; i++) {
        const start: number = i * chunk;
        const end: number = Math.min(total - 1, (i + 1) * chunk - 1);
        if (start >= total) {
          break;
        }
        pending.push(QgHttp.getBytes(upstream,
          QgGateway.copyHeaders(headers, `bytes=${start}-${end}`), 120000, sourceId));
      }
      const out: Uint8Array = new Uint8Array(total);
      let off: number = 0;
      for (let i: number = 0; i < pending.length; i++) {
        const seg: Uint8Array = await pending[i];
        if (off + seg.length > total) {
          throw new Error('Range 响应超长');
        }
        out.set(seg, off);
        off += seg.length;
      }
      if (off !== total) {
        throw new Error(`Range 长度不符 ${off}/${total}`);
      }
      QgDiag.log('Gateway', `parallel fetch ${total}B in ${pending.length} parts`);
      return out;
    } catch (error) {
      const err: Error = error as Error;
      QgDiag.log('Gateway', `parallel fetch fallback: ${err.message}`);
      return QgHttp.getBytes(upstream, headers, 120000, sourceId);
    }
  }

  private static async downloadAndDecrypt(upstream: string, referer: string, ua: string,
    keyHex: string, cacheKey: string, extraHeaders: Record<string, string> = {},
    sourceId: string = ''): Promise<Uint8Array> {
    try {
      const headers: Record<string, string> = QgGateway.cleanMediaHeaders(extraHeaders);
      headers['Accept-Encoding'] = 'identity';
      if (referer.length > 0) {
        headers['Referer'] = referer;
      }
      if (ua.length > 0) {
        headers['User-Agent'] = ua;
      }
      const started: number = Date.now();
      const data: Uint8Array = await QgGateway.fetchUpstream(upstream, headers, sourceId);
      if (data.length < 64) {
        throw new Error('上游文件过小');
      }
      const key: Uint8Array = qgFromHex(keyHex);
      if (key.length !== 16) {
        throw new Error('密钥长度无效');
      }
      QgDiag.log('Gateway', `dec start ${data.length}B (taskpool)`);
      // 解密在 TaskPool 工作线程完成，主线程只等结果，避免 THREAD_BLOCK_6S。
      // 跨线程传参是拷贝，因此必须使用返回的明文 buffer，而不是本地的加密 buffer。
      const result: Object = await taskpool.execute(qgDecryptInWorker, data, key);
      const plaintext: Uint8Array | null = result as Uint8Array | null;
      if (plaintext === null) {
        throw new Error('CENC 解密失败（结构不支持）');
      }
      QgDiag.log('Gateway', `dec ok ${plaintext.length}B in ${Date.now() - started}ms`);
      while (QgGateway.decCache.size >= 2) {
        const oldest: string | undefined = QgGateway.decCache.keys().next().value;
        if (oldest === undefined) {
          break;
        }
        QgGateway.decCache.delete(oldest);
      }
      QgGateway.decCache.set(cacheKey, plaintext);
      return plaintext;
    } finally {
      QgGateway.decPending.delete(cacheKey);
    }
  }

  /** 解密缓冲下发：支持 Range / HEAD */
  private static serveDecryptedBuffer(c: QgGatewayConn, method: string, data: Uint8Array,
    clientHeader: Record<string, string>): void {
    if (c.closed) {
      return;
    }
    const total: number = data.length;
    const rangeText: string = clientHeader['range'] !== undefined ? clientHeader['range'] : '';
    let start: number = 0;
    let end: number = total - 1;
    let partial: boolean = false;
    const match: RegExpMatchArray | null = rangeText.match(/^bytes=(\d*)-(\d*)$/);
    if (match !== null) {
      const startText: string = match[1];
      const endText: string = match[2];
      if (startText.length === 0) {
        // 后缀区间 bytes=-N
        const suffix: number = Number(endText);
        if (suffix > 0) {
          start = Math.max(0, total - suffix);
          end = total - 1;
          partial = true;
        }
      } else {
        start = Number(startText);
        end = endText.length > 0 ? Math.min(Number(endText), total - 1) : total - 1;
        partial = true;
      }
      if (start >= total || start > end) {
        const head416: string = `HTTP/1.1 416 Range Not Satisfiable\r\n` +
          `Content-Range: bytes */${total}\r\n` +
          `Content-Length: 0\r\nConnection: close\r\n\r\n`;
        QgGateway.sendBytes(c, qgUtf8Encode(head416));
        QgGateway.finish(c);
        return;
      }
    }
    const slice: Uint8Array = data.subarray(start, end + 1);
    let head: string = partial ?
      `HTTP/1.1 206 Partial Content\r\nContent-Range: bytes ${start}-${end}/${total}\r\n` :
      `HTTP/1.1 200 OK\r\n`;
    head += `Content-Type: video/mp4\r\nContent-Length: ${slice.length}\r\n` +
      `Accept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`;
    QgGateway.sendBytes(c, qgUtf8Encode(head));
    if (method === 'GET') {
      QgGateway.sendBytes(c, slice);
    }
    QgGateway.finish(c);
  }

  // ---------- 上游代理 ----------

  private static proxy(c: QgGatewayConn, method: string, upstream: string,
    query: Record<string, string>, clientHeader: Record<string, string>): void {
    const referer: string = query['r'] !== undefined ? query['r'] : '';
    const ua: string = query['ua'] !== undefined ? query['ua'] : '';
    c.upstreamUrl = upstream;
    c.upstreamReferer = referer;
    c.upstreamUa = ua;
    c.sessionId = query['s'] ?? '';
    const session: QgGatewayMediaSession | undefined = QgGateway.mediaSessions.get(c.sessionId);
    const upstreamHeader: Record<string, string> = QgGateway.cleanMediaHeaders(session?.headers ?? {});
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
    const proxy: QgHttpProxy = QgHttp.resolveProxy(c.sourceId);
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
    c.statusReceived = true;
    const contentType: string = c.upstreamHeader['content-type'] !== undefined
      ? c.upstreamHeader['content-type'] : '';
    const isPlaylist: boolean = contentType.toLowerCase().indexOf('mpegurl') >= 0 ||
      QgGateway.urlLooksLikePlaylist(c.upstreamUrl);
    if (isPlaylist && code >= 200 && code < 300 && method !== 'HEAD') {
      c.buffering = true;
      if (c.upstreamEnded) QgGateway.onUpstreamEnd(c);
      return;
    }
    if (method === 'HEAD') {
      // HEAD 不能回 chunked：原实现写 Transfer-Encoding: chunked 却不发终止块，
      // 播放器探测时长/类型时会一直等到超时，直接表现为「播不出来」。
      QgGateway.writeHead(c, code, false, 0);
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
    if (c.upstreamEnded) QgGateway.onUpstreamEnd(c);
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
    // requestInStream 的 dataReceive 可能早于 Promise resolve（onUpstreamStatus）。
    // 早到的字节暂存在 bodyParts，写头后必须立刻冲刷，否则播放器拿到的是断裂的流。
    if (!c.buffering && c.bodyParts.length > 0) {
      const pending: Uint8Array[] = c.bodyParts;
      c.bodyParts = [];
      for (let i: number = 0; i < pending.length; i++) {
        QgGateway.writeBody(c, pending[i]);
      }
    }
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
      c.bufferedBytes += data.byteLength;
      if (c.bufferedBytes > PLAYLIST_BYTES_LIMIT) {
        QgGateway.destroyUpstream(c);
        QgGateway.respondSimple(c, 502, 'Bad Gateway', 'playlist too large');
        return;
      }
      c.bodyParts.push(new Uint8Array(data));
      return;
    }
    if (!c.headersSent) {
      c.bufferedBytes += data.byteLength;
      if (c.bufferedBytes > PLAYLIST_BYTES_LIMIT) {
        QgGateway.destroyUpstream(c);
        QgGateway.respondSimple(c, 502, 'Bad Gateway', 'buffer too large');
        return;
      }
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
    c.upstreamEnded = true;
    if (!c.statusReceived) return;
    QgGateway.destroyUpstream(c);
    if (c.closed) {
      return;
    }
    if (c.buffering) {
      try {
        QgGateway.flushPlaylist(c);
      } catch (error) {
        QgGateway.respondSimple(c, 502, 'Bad Gateway', (error as Error).message);
      }
      return;
    }
    if (!c.headersSent) {
      // 异常时序兜底：状态码 Promise 未及时 resolve 时也要把已缓冲的媒体数据发出去。
      // 与 writeBody 保持同一套 hasLength 判断，避免 Content-Length 与 chunked 冲突。
      const lenText: string = c.upstreamHeader['content-length'] !== undefined
        ? c.upstreamHeader['content-length'] : '';
      const hasLen: boolean = lenText.length > 0 && !Number.isNaN(Number(lenText));
      QgGateway.writeHead(c, 200, false, hasLen ? Number(lenText) : -1);
      if (!hasLen) {
        QgGateway.sendBytes(c, qgUtf8Encode('0\r\n\r\n'));
      }
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
      if (trimmed.startsWith('#') && trimmed.includes('URI="')) {
        line = QgGateway.rewriteAttrUri(trimmed, playlistUrl, c);
      } else if (!trimmed.startsWith('#')) {
        const abs: string = QgGateway.resolveUrl(playlistUrl, trimmed);
        line = QgGateway.buildProxyLine(abs, c);
      }
      out.push(line);
    }
    return out.join('\n');
  }

  /** 改写标签行里的 URI="..." 属性 */
  private static rewriteAttrUri(line: string, playlistUrl: string, c: QgGatewayConn): string {
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
    if (uri.startsWith('data:')) {
      return line;
    }
    const abs: string = QgGateway.resolveUrl(playlistUrl, uri);
    const session: QgGatewayMediaSession | undefined = QgGateway.mediaSessions.get(c.sessionId);
    const key: boolean = line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-SESSION-KEY:');
    const replacement: string = key && session !== undefined && session.hlsKey.length === 16 ?
      `${QgGateway.endpoint()}/${QgGateway.token}/key/${c.sessionId}` : QgGateway.buildProxyLine(abs, c);
    return line.substring(0, start) + replacement + line.substring(end);
  }

  /** 绝对媒体地址 → 本地网关地址行（沿用该连接的 Referer/UA） */
  private static buildProxyLine(absUrl: string, c: QgGatewayConn): string {
    if (!QgGateway.isHttpUrl(absUrl)) {
      throw new Error('播放列表中的媒体地址无效');
    }
    if (c.sessionId.length > 0) {
      return QgGateway.buildSessionUrl(absUrl, c.sessionId, c.sourceId);
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
    try {
      return new url.URL(ref, base).toString();
    } catch (error) {
      return '';
    }
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
