import fs from 'node:fs';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

export const MIME = {
  '.dmg': 'application/x-apple-diskimage',
  '.zip': 'application/zip',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.woff2': 'font/woff2',
};

/** Resolves `relative` under `root`, refusing traversal, dotfiles and odd characters. Returns null when unsafe. */
export function safeJoin(root, relative) {
  let decoded;
  try { decoded = decodeURIComponent(relative); } catch { return null; }
  if (decoded.includes('\0') || decoded.includes('\\')) return null;
  const segments = decoded.split('/').filter(Boolean);
  if (segments.some((s) => s.startsWith('.'))) return null;
  const full = path.resolve(root, ...segments);
  const rootResolved = path.resolve(root);
  if (full !== rootResolved && !full.startsWith(rootResolved + path.sep)) return null;
  return full;
}

/**
 * Parses a single `bytes=` range against `size`. Returns `{ start, end }`, `null` for "ignore and send
 * everything" (absent, malformed or multi-range), or `'unsatisfiable'`.
 */
export function parseRange(header, size) {
  if (typeof header !== 'string') return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;
  let start;
  let end;
  if (m[1] === '') {
    const suffix = Number(m[2]);
    if (suffix === 0) return 'unsatisfiable';
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1);
    if (start > end && m[2] !== '') return start >= size ? 'unsatisfiable' : null;
  }
  if (start >= size || size === 0) return 'unsatisfiable';
  return { start, end };
}

/** Streams a file with ETag/Last-Modified, HEAD and single-range support. Returns false if the file is missing. */
export async function serveFile(req, res, filePath, { cacheControl = 'no-cache', headers = {}, contentType } = {}) {
  let stat;
  try { stat = await fs.promises.stat(filePath); } catch { return false; }
  if (!stat.isFile()) return false;

  const etag = `"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
  const lastModified = stat.mtime.toUTCString();
  const base = {
    'Content-Type': contentType || MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Cache-Control': cacheControl,
    'Last-Modified': lastModified,
    ETag: etag,
    'X-Content-Type-Options': 'nosniff',
    ...headers,
  };

  const inm = req.headers['if-none-match'];
  if (inm && inm.split(',').map((s) => s.trim()).includes(etag)) {
    res.writeHead(304, { ETag: etag, 'Cache-Control': cacheControl, 'Last-Modified': lastModified });
    res.end();
    return true;
  }

  let range = parseRange(req.headers.range, stat.size);
  const ifRange = req.headers['if-range'];
  if (range && ifRange && ifRange !== etag && ifRange !== lastModified) range = null;

  if (range === 'unsatisfiable') {
    res.writeHead(416, { 'Content-Range': `bytes */${stat.size}`, 'Content-Length': 0, 'Accept-Ranges': 'bytes' });
    res.end();
    return true;
  }

  const { start, end } = range || { start: 0, end: stat.size - 1 };
  const length = stat.size === 0 ? 0 : end - start + 1;
  if (range) {
    res.writeHead(206, { ...base, 'Content-Length': length, 'Content-Range': `bytes ${start}-${end}/${stat.size}` });
  } else {
    res.writeHead(200, { ...base, 'Content-Length': length });
  }
  if (req.method === 'HEAD' || length === 0) {
    res.end();
    return true;
  }
  try {
    await pipeline(fs.createReadStream(filePath, { start, end }), res);
  } catch {
    // Client went away mid-download; nothing to do.
  }
  return true;
}
