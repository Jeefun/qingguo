/**
 * CENC 解密的后台任务。
 *
 * 纯 JS AES-CTR 要对整个 MP4 逐 16 字节块运算，实测在主线程连续占用超过 6 秒，
 * 会触发 THREAD_BLOCK_6S（AppFreeze）并被系统杀掉，表现为「点播放卡死然后闪退」。
 * 这里交给 TaskPool 工作线程执行，主线程只等 Promise，不再参与计算。
 */
import { qgCencDecryptMp4 } from './QgMp4Cenc';

@Concurrent
export async function qgDecryptInWorker(data: Uint8Array, key: Uint8Array): Promise<Uint8Array | null> {
  // 工作线程不需要让出主线程事件循环，关掉分块 yield 以免依赖 setTimeout
  const ok: boolean = await qgCencDecryptMp4(data, key, false);
  return ok ? data : null;
}
