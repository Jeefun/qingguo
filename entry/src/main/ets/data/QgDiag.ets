/**
 * 诊断日志：内存环形缓冲 + hilog 双写。
 * 设置页可导出（dump）用于问题排查；不落盘、不收集隐私。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

export class QgDiag {
  private static lines: string[] = [];
  private static readonly CAP: number = 400;
  private static readonly DOMAIN: number = 0x0100;
  private static readonly TAG: string = 'QingGuo';

  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  static log(tag: string, message: string): void {
    const d: Date = new Date();
    const line: string = `${QgDiag.pad2(d.getHours())}:${QgDiag.pad2(d.getMinutes())}:` +
      `${QgDiag.pad2(d.getSeconds())} [${tag}] ${message}`;
    QgDiag.lines.push(line);
    if (QgDiag.lines.length > QgDiag.CAP) {
      QgDiag.lines.shift();
    }
    hilog.info(QgDiag.DOMAIN, QgDiag.TAG, '%{public}s', line);
  }

  static dump(): string {
    return QgDiag.lines.join('\n');
  }

  static size(): number {
    return QgDiag.lines.length;
  }

  static clear(): void {
    QgDiag.lines = [];
  }
}
