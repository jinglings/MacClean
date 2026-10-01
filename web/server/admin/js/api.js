// JSON client for /api/admin. Every request carries the CSRF header the server requires on mutations.

export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

const listeners = new Set();
/** Called when any request comes back 401 (session expired / logged out elsewhere). */
export function onUnauthorized(fn) {
  listeners.add(fn);
}

export async function api(method, path, body) {
  const headers = { 'X-Requested-With': 'macclean-admin', Accept: 'application/json' };
  const init = { method, headers, credentials: 'same-origin', cache: 'no-store' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ApiError('网络连接失败，请检查网络后重试', 0);
  }
  let data = null;
  try { data = await res.json(); } catch { /* empty or non-JSON body */ }
  if (res.status === 401 && !/\/api\/admin\/(login|setup|password)$/.test(path)) listeners.forEach((fn) => fn());
  if (!res.ok) throw new ApiError(data?.error || `请求失败（HTTP ${res.status}）`, res.status);
  return data;
}

export const get = (path) => api('GET', path);
export const post = (path, body = {}) => api('POST', path, body);
export const put = (path, body) => api('PUT', path, body);
export const patch = (path, body) => api('PATCH', path, body);
export const del = (path) => api('DELETE', path);

export function qs(params) {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') sp.set(k, v);
  const str = sp.toString();
  return str ? `?${str}` : '';
}

/**
 * Multipart upload through XHR (fetch has no upload progress). Returns `{ promise, abort }`;
 * `onProgress(loaded, total)` fires as bytes leave the browser.
 */
export function upload(path, formData, onProgress) {
  const xhr = new XMLHttpRequest();
  const promise = new Promise((resolve, reject) => {
    xhr.open('POST', path);
    xhr.setRequestHeader('X-Requested-With', 'macclean-admin');
    xhr.responseType = 'json';
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) onProgress?.(e.loaded, e.total); };
    xhr.onload = () => {
      const data = xhr.response;
      if (xhr.status === 401) listeners.forEach((fn) => fn());
      if (xhr.status >= 200 && xhr.status < 300) resolve(data);
      else reject(new ApiError(data?.error || `上传失败（HTTP ${xhr.status}）`, xhr.status));
    };
    xhr.onerror = () => reject(new ApiError('上传中断：网络错误或文件被服务器拒绝', 0));
    xhr.onabort = () => reject(new ApiError('已取消上传', -1));
    xhr.send(formData);
  });
  return { promise, abort: () => xhr.abort() };
}
