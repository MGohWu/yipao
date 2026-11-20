import { http } from '@kit.NetworkKit';
import { JsonValue } from './JsonValue';
import { LeapError } from './LeapError';
import { DiagLog } from './DiagLog';

export interface HttpResult {
  status: number;
  json: JsonValue;
  rawText: string;
}

/** 请求体形式。三选一，与 iOS 版 request(...) 的 jsonBody/formBody/emptyBody 对应。 */
export enum BodyKind {
  none,
  json,
  form,
  empty
}

export class HttpTransport {
  /** 拼 query string。值按 URL 组件编码。 */
  static buildURL(base: string, query: Map<string, string> | null): string {
    if (query === null || query.size === 0) {
      return base;
    }
    const parts: string[] = [];
    query.forEach((value: string, key: string) => {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    });
    const separator = base.includes('?') ? '&' : '?';
    return base + separator + parts.join('&');
  }

  private static formEncode(body: Map<string, string>): string {
    const parts: string[] = [];
    body.forEach((value: string, key: string) => {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    });
    return parts.join('&');
  }

  private static toHeaderObject(headers: Map<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    headers.forEach((value: string, key: string) => {
      out[key] = value;
    });
    return out;
  }

  /** 发一个 JSON 请求。非 2xx 抛 LeapError.http。 */
  static async request(url: string, method: string, headers: Map<string, string>,
    query: Map<string, string> | null = null,
    bodyKind: BodyKind = BodyKind.none,
    body: Map<string, string> | null = null,
    timeoutMs: number = 20000): Promise<JsonValue> {
    const requestUrl = HttpTransport.buildURL(url, query);
    const requestHeaders = HttpTransport.toHeaderObject(headers);
    let content: string | undefined = undefined;

    if (bodyKind === BodyKind.json && body !== null) {
      requestHeaders['content-type'] = 'application/json; charset=utf-8';
      const obj: Record<string, string> = {};
      body.forEach((value: string, key: string) => {
        obj[key] = value;
      });
      content = JSON.stringify(obj);
    } else if (bodyKind === BodyKind.form && body !== null) {
      requestHeaders['content-type'] = 'application/x-www-form-urlencoded; charset=utf-8';
      content = HttpTransport.formEncode(body);
    }
    // BodyKind.empty 这里什么都不做，是有意的。
    // NetworkKit 校验 extraData 时不接受长度为 0 的值——空字符串和空 ArrayBuffer
    // 都会被判成「参数错误」直接抛 401（真机实测），请求根本发不出去。
    // 干脆不带这个字段：curl 依然发出 POST，Content-Length: 0，
    // 与 iOS 版给这类接口发空 body 的行为一致。

    // 只打方法和路径：query 里带着加密手机号和签名，不能进日志。
    const path = requestUrl.split('?')[0];
    const started = Date.now();
    DiagLog.note(`[http] → ${method} ${path}`);

    const httpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: requestHeaders,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      };
      if (content !== undefined && content.length > 0) {
        options.extraData = content;
      }
      let response: http.HttpResponse;
      try {
        response = await httpRequest.request(requestUrl, options);
      } catch (e) {
        DiagLog.note(`[http] ✗ ${method} ${path} ${Date.now() - started}ms ${LeapError.messageOf(e as object)}`);
        throw e as Error;
      }
      const status = response.responseCode as number;
      DiagLog.note(`[http] ← ${status} ${method} ${path} ${Date.now() - started}ms`);
      const text = typeof response.result === 'string' ? response.result : '';
      let value: JsonValue;
      if (text.length === 0) {
        value = JsonValue.nullValue();
      } else {
        const parsed = JsonValue.parse(text);
        if (parsed !== null) {
          value = parsed;
        } else {
          const wrapper = new Map<string, JsonValue>();
          wrapper.set('raw', JsonValue.ofString(text));
          value = JsonValue.ofObject(wrapper);
        }
      }
      if (status < 200 || status >= 300) {
        const message = value.responseMessage.length > 0 ? value.responseMessage : text.substring(0, 200);
        throw LeapError.http(status, message);
      }
      return value;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 下载二进制（车模型 ZIP）。返回 ArrayBuffer 与状态码。 */
  static async download(url: string, headers: Map<string, string>,
    timeoutMs: number = 120000): Promise<ArrayBuffer | null> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: HttpTransport.toHeaderObject(headers),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      const status = response.responseCode as number;
      if (status < 200 || status >= 300) {
        return null;
      }
      if (response.result instanceof ArrayBuffer) {
        return response.result;
      }
      return null;
    } catch (e) {
      return null;
    } finally {
      httpRequest.destroy();
    }
  }
}
