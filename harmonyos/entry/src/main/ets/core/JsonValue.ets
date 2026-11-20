/**
 * 服务端返回的结构在不同接口之间差异很大，且会随 App 版本变化。
 * 这里用一个动态 JSON 表示，配合深度查找，避免为每个接口硬写模型。
 *
 * 与 iOS 侧 `JSONValue.swift` 一一对应。
 */
export enum JsonKind {
  String,
  Number,
  Bool,
  Object,
  Array,
  Null
}

export class JsonValue {
  readonly kind: JsonKind;
  private readonly str: string;
  private readonly num: number;
  private readonly boolVal: boolean;
  private readonly obj: Map<string, JsonValue> | null;
  private readonly arr: JsonValue[] | null;

  private constructor(kind: JsonKind, str: string, num: number, boolVal: boolean,
    obj: Map<string, JsonValue> | null, arr: JsonValue[] | null) {
    this.kind = kind;
    this.str = str;
    this.num = num;
    this.boolVal = boolVal;
    this.obj = obj;
    this.arr = arr;
  }

  static ofString(value: string): JsonValue {
    return new JsonValue(JsonKind.String, value, 0, false, null, null);
  }

  static ofNumber(value: number): JsonValue {
    return new JsonValue(JsonKind.Number, '', value, false, null, null);
  }

  static ofBool(value: boolean): JsonValue {
    return new JsonValue(JsonKind.Bool, '', 0, value, null, null);
  }

  static ofObject(value: Map<string, JsonValue>): JsonValue {
    return new JsonValue(JsonKind.Object, '', 0, false, value, null);
  }

  static ofArray(value: JsonValue[]): JsonValue {
    return new JsonValue(JsonKind.Array, '', 0, false, null, value);
  }

  static nullValue(): JsonValue {
    return new JsonValue(JsonKind.Null, '', 0, false, null, null);
  }

  /** 从 JSON 文本解析。解析失败返回 null。 */
  static parse(text: string): JsonValue | null {
    try {
      const raw: object | null = JSON.parse(text) as object | null;
      return JsonValue.fromRaw(raw);
    } catch (e) {
      return null;
    }
  }

  /** 从 JSON.parse 的原始结果构造。 */
  static fromRaw(raw: object | string | number | boolean | null | undefined): JsonValue {
    if (raw === null || raw === undefined) {
      return JsonValue.nullValue();
    }
    if (typeof raw === 'string') {
      return JsonValue.ofString(raw);
    }
    if (typeof raw === 'number') {
      return JsonValue.ofNumber(raw);
    }
    if (typeof raw === 'boolean') {
      return JsonValue.ofBool(raw);
    }
    if (Array.isArray(raw)) {
      const items: JsonValue[] = [];
      const rawItems = raw as object[];
      for (let i = 0; i < rawItems.length; i++) {
        items.push(JsonValue.fromRaw(rawItems[i]));
      }
      return JsonValue.ofArray(items);
    }
    const map = new Map<string, JsonValue>();
    const record = raw as Record<string, object>;
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      map.set(keys[i], JsonValue.fromRaw(record[keys[i]]));
    }
    return JsonValue.ofObject(map);
  }

  /** 取对象字段，非对象或字段不存在返回 null。 */
  get(key: string): JsonValue | null {
    if (this.kind !== JsonKind.Object || this.obj === null) {
      return null;
    }
    const value = this.obj.get(key);
    return value === undefined ? null : value;
  }

  /** 连续取多层字段。 */
  path(...keys: string[]): JsonValue | null {
    let current: JsonValue | null = this;
    for (let i = 0; i < keys.length; i++) {
      if (current === null) {
        return null;
      }
      current = current.get(keys[i]);
    }
    return current;
  }

  get objectValue(): Map<string, JsonValue> | null {
    return this.kind === JsonKind.Object ? this.obj : null;
  }

  get arrayValue(): JsonValue[] | null {
    return this.kind === JsonKind.Array ? this.arr : null;
  }

  /** 数字、布尔、字符串统一转成字符串，方便直接参与签名和展示。 */
  get stringValue(): string | null {
    switch (this.kind) {
      case JsonKind.String:
        return this.str;
      case JsonKind.Bool:
        return this.boolVal ? 'true' : 'false';
      case JsonKind.Number: {
        const value = this.num;
        if (value === Math.round(value) && Math.abs(value) < 1e15) {
          return String(Math.trunc(value));
        }
        return String(value);
      }
      default:
        return null;
    }
  }

  get intValue(): number | null {
    switch (this.kind) {
      case JsonKind.Number:
        return Math.trunc(this.num);
      case JsonKind.String: {
        const parsed = Number(this.str);
        return Number.isFinite(parsed) ? Math.trunc(parsed) : null;
      }
      case JsonKind.Bool:
        return this.boolVal ? 1 : 0;
      default:
        return null;
    }
  }

  get doubleValue(): number | null {
    switch (this.kind) {
      case JsonKind.Number:
        return this.num;
      case JsonKind.String: {
        const parsed = Number(this.str);
        return Number.isFinite(parsed) ? parsed : null;
      }
      case JsonKind.Bool:
        return this.boolVal ? 1 : 0;
      default:
        return null;
    }
  }

  /** 深度优先查找第一个满足条件的对象节点。 */
  firstObject(predicate: (dict: Map<string, JsonValue>) => boolean): Map<string, JsonValue> | null {
    if (this.kind === JsonKind.Object && this.obj !== null) {
      if (predicate(this.obj)) {
        return this.obj;
      }
      let found: Map<string, JsonValue> | null = null;
      this.obj.forEach((value: JsonValue) => {
        if (found === null) {
          const child = value.firstObject(predicate);
          if (child !== null) {
            found = child;
          }
        }
      });
      if (found !== null) {
        return found;
      }
    }
    if (this.kind === JsonKind.Array && this.arr !== null) {
      for (let i = 0; i < this.arr.length; i++) {
        const found = this.arr[i].firstObject(predicate);
        if (found !== null) {
          return found;
        }
      }
    }
    return null;
  }

  /** 收集所有满足条件的对象节点。 */
  allObjects(predicate: (dict: Map<string, JsonValue>) => boolean): Map<string, JsonValue>[] {
    const out: Map<string, JsonValue>[] = [];
    if (this.kind === JsonKind.Object && this.obj !== null) {
      if (predicate(this.obj)) {
        out.push(this.obj);
      }
      this.obj.forEach((value: JsonValue) => {
        const children = value.allObjects(predicate);
        for (let i = 0; i < children.length; i++) {
          out.push(children[i]);
        }
      });
    }
    if (this.kind === JsonKind.Array && this.arr !== null) {
      for (let i = 0; i < this.arr.length; i++) {
        const children = this.arr[i].allObjects(predicate);
        for (let j = 0; j < children.length; j++) {
          out.push(children[j]);
        }
      }
    }
    return out;
  }

  /** 接口返回码：code / result / status 任一存在即可。 */
  get responseCode(): string | null {
    const keys: string[] = ['code', 'result', 'status'];
    for (let i = 0; i < keys.length; i++) {
      const value = this.get(keys[i]);
      if (value !== null && value.stringValue !== null) {
        return value.stringValue;
      }
    }
    return null;
  }

  get responseMessage(): string {
    const keys: string[] = ['msg', 'message', 'error'];
    for (let i = 0; i < keys.length; i++) {
      const value = this.get(keys[i]);
      if (value !== null && value.stringValue !== null && value.stringValue.length > 0) {
        return value.stringValue;
      }
    }
    return '';
  }

  get isSuccess(): boolean {
    const success = this.get('success');
    if (success !== null && success.kind === JsonKind.Bool && success.boolVal) {
      return true;
    }
    const code = this.responseCode;
    if (code === null) {
      return true;
    }
    return code === '0' || code === '200';
  }

  /** 排查用的可读文本。键排序，方便两次响应直接对比。 */
  get prettyPrinted(): string {
    return JSON.stringify(this.toPlain(), null, 2) ?? '(无法序列化)';
  }

  /** 还原成普通 JS 值（对象键按字典序），用于序列化。 */
  toPlain(): object | string | number | boolean | null {
    switch (this.kind) {
      case JsonKind.String:
        return this.str;
      case JsonKind.Number:
        return this.num;
      case JsonKind.Bool:
        return this.boolVal;
      case JsonKind.Null:
        return null;
      case JsonKind.Array: {
        const items: (object | string | number | boolean | null)[] = [];
        const arr = this.arr ?? [];
        for (let i = 0; i < arr.length; i++) {
          items.push(arr[i].toPlain());
        }
        return items;
      }
      case JsonKind.Object: {
        const record: Record<string, object | string | number | boolean | null> = {};
        const obj = this.obj ?? new Map<string, JsonValue>();
        const keys: string[] = [];
        obj.forEach((_value: JsonValue, key: string) => {
          keys.push(key);
        });
        keys.sort();
        for (let i = 0; i < keys.length; i++) {
          const child = obj.get(keys[i]);
          if (child !== undefined) {
            record[keys[i]] = child.toPlain();
          }
        }
        return record;
      }
      default:
        return null;
    }
  }
}
