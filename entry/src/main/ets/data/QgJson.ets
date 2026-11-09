/**
 * JSON 值安全访问工具。
 * ArkTS 中 JSON.parse 结果为动态结构，统一经本类做类型收窄，
 * 避免散落的 as 断言与 any。
 */

export class QgJson {
  /** 解析 JSON 文本，失败返回 null */
  static parse(text: string): Object | null {
    try {
      return JSON.parse(text) as Object;
    } catch (error) {
      return null;
    }
  }

  /** 值 → 对象（Record）视图；非对象返回 null */
  static obj(value: Object | undefined | null): Record<string, Object> | null {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return null;
  }

  /** 值 → 数组；非数组返回空数组 */
  static arr(value: Object | undefined | null): Object[] {
    if (Array.isArray(value)) {
      return value as Object[];
    }
    return [];
  }

  /** 值 → 字符串（number/boolean 自动转字符串） */
  static str(value: Object | undefined | null): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number') {
      return `${value}`;
    }
    if (typeof value === 'boolean') {
      return value ? 'true' : 'false';
    }
    return '';
  }

  /** 值 → 数字（解析失败返回 0） */
  static num(value: Object | undefined | null): number {
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string') {
      const parsed: number = Number(value.trim());
      return Number.isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  }

  /** 依次取第一个非空字符串字段 */
  static pick(row: Record<string, Object> | null, keys: string[]): string {
    if (row === null) {
      return '';
    }
    for (let i: number = 0; i < keys.length; i++) {
      const v: string = QgJson.str(row[keys[i]]);
      if (v.trim().length > 0) {
        return v;
      }
    }
    return '';
  }

  /** 取字段的对象视图（可能为 null） */
  static field(row: Record<string, Object> | null, key: string): Record<string, Object> | null {
    if (row === null) {
      return null;
    }
    return QgJson.obj(row[key]);
  }

  /** 取字段的数组视图（可能为空数组） */
  static fieldArr(row: Record<string, Object> | null, key: string): Object[] {
    if (row === null) {
      return [];
    }
    return QgJson.arr(row[key]);
  }

  /** 值是否为 true */
  static isTrue(value: Object | undefined | null): boolean {
    return value === true;
  }
}
