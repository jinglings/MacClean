import fs from 'node:fs';
import { once } from 'node:events';
import { HttpError } from './http.js';

const CRLF = Buffer.from('\r\n');
const HEADER_END = Buffer.from('\r\n\r\n');
const MAX_HEADER_BYTES = 16 * 1024;

export function boundaryFrom(contentType) {
  if (typeof contentType !== 'string' || !/^multipart\/form-data\b/i.test(contentType)) return null;
  const match = /;\s*boundary=(?:"([^"]{1,70})"|([^\s;]{1,70}))/i.exec(contentType);
  return match ? (match[1] ?? match[2]) : null;
}

function parseParams(value) {
  // form-data; name="file"; filename="a b.dmg"
  const out = {};
  const re = /;\s*([A-Za-z0-9_*.-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]*))/g;
  let m;
  while ((m = re.exec(value))) out[m[1].toLowerCase()] = m[2] !== undefined ? m[2].replace(/\\(.)/g, '$1') : m[3].trim();
  return out;
}

export function parsePartHeaders(text) {
  const headers = {};
  for (const line of text.split('\r\n')) {
    const i = line.indexOf(':');
    if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
  }
  const params = parseParams(headers['content-disposition'] || '');
  return {
    name: params.name ?? null,
    filename: params.filename ?? null,
    contentType: headers['content-type'] || null,
    headers,
  };
}

/**
 * Incremental multipart/form-data tokenizer. `push(chunk)` returns events in order:
 *   { type: 'part', part }  { type: 'data', data }  { type: 'partEnd' }  { type: 'done' }
 * It only ever holds back (delimiter length - 1) bytes, so file bodies of any size stream through
 * and a boundary split across chunk edges is still found.
 */
export class MultipartTokenizer {
  constructor(boundary) {
    // The first delimiter has no leading CRLF; pretend it does so one search pattern fits all.
    this.delimiter = Buffer.from(`\r\n--${boundary}`);
    this.buffer = Buffer.from(CRLF);
    this.state = 'preamble';
    this.finished = false;
  }

  push(chunk) {
    const events = [];
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    for (;;) {
      if (this.state === 'preamble') {
        const i = this.buffer.indexOf(this.delimiter);
        if (i < 0) {
          this.buffer = this.buffer.subarray(Math.max(0, this.buffer.length - this.delimiter.length + 1));
          if (this.buffer.length > MAX_HEADER_BYTES) throw new HttpError(400, 'Malformed multipart body');
          return events;
        }
        this.buffer = this.buffer.subarray(i + this.delimiter.length);
        this.state = 'afterDelimiter';
      } else if (this.state === 'afterDelimiter') {
        if (this.buffer.length < 2) return events;
        if (this.buffer[0] === 0x2d && this.buffer[1] === 0x2d) {
          this.state = 'epilogue';
          this.finished = true;
          this.buffer = Buffer.alloc(0);
          events.push({ type: 'done' });
          return events;
        }
        // Skip optional transport padding (spaces / tabs) before the CRLF.
        let j = 0;
        while (j < this.buffer.length && (this.buffer[j] === 0x20 || this.buffer[j] === 0x09)) j++;
        if (this.buffer.length < j + 2) return events;
        if (this.buffer[j] !== 0x0d || this.buffer[j + 1] !== 0x0a) throw new HttpError(400, 'Malformed multipart body');
        this.buffer = this.buffer.subarray(j + 2);
        this.state = 'headers';
      } else if (this.state === 'headers') {
        // An empty header block means the CRLFCRLF starts right here.
        const i = this.buffer.subarray(0, 2).equals(CRLF) ? -2 : this.buffer.indexOf(HEADER_END);
        if (i === -1) {
          if (this.buffer.length > MAX_HEADER_BYTES) throw new HttpError(400, 'Multipart headers too large');
          return events;
        }
        const headerText = i === -2 ? '' : this.buffer.subarray(0, i).toString('utf8');
        this.buffer = this.buffer.subarray(i === -2 ? 2 : i + 4);
        events.push({ type: 'part', part: parsePartHeaders(headerText) });
        this.state = 'body';
      } else if (this.state === 'body') {
        const i = this.buffer.indexOf(this.delimiter);
        if (i === -1) {
          const keep = this.delimiter.length - 1;
          if (this.buffer.length > keep) {
            events.push({ type: 'data', data: this.buffer.subarray(0, this.buffer.length - keep) });
            this.buffer = this.buffer.subarray(this.buffer.length - keep);
          }
          return events;
        }
        if (i > 0) events.push({ type: 'data', data: this.buffer.subarray(0, i) });
        events.push({ type: 'partEnd' });
        this.buffer = this.buffer.subarray(i + this.delimiter.length);
        this.state = 'afterDelimiter';
      } else {
        // epilogue: ignore anything after the closing delimiter
        this.buffer = Buffer.alloc(0);
        return events;
      }
    }
  }

  end() {
    if (!this.finished) throw new HttpError(400, 'Unexpected end of multipart body');
  }
}

/**
 * Streams a multipart request. Text fields are collected (bounded); each file part is handed to
 * `onFile(part, fieldsSoFar)`, which returns `{ path, maxBytes }` to stream it to disk or null to reject it.
 * Resolves to `{ fields, files: [{ field, filename, contentType, path, size }] }`. On any error the
 * partially written files are removed.
 */
export async function parseMultipart(req, { onFile, maxFieldBytes = 64 * 1024, maxFields = 30, maxTotalBytes = Infinity }) {
  const boundary = boundaryFrom(req.headers['content-type']);
  if (!boundary) throw new HttpError(400, 'Expected multipart/form-data');
  const declared = Number(req.headers['content-length']);
  if (Number.isFinite(declared) && declared > maxTotalBytes) throw new HttpError(413, 'Upload too large');

  const tokenizer = new MultipartTokenizer(boundary);
  const fields = {};
  const files = [];
  let fieldCount = 0;
  let current = null; // { kind: 'field'|'file'|'skip', ... }
  let total = 0;

  const cleanup = () => {
    if (current?.stream) current.stream.destroy();
    for (const f of files) fs.rmSync(f.path, { force: true });
    if (current?.path) fs.rmSync(current.path, { force: true });
  };

  try {
    for await (const chunk of req.iterator({ destroyOnReturn: false })) {
      total += chunk.length;
      if (total > maxTotalBytes) throw new HttpError(413, 'Upload too large');
      for (const event of tokenizer.push(chunk)) {
        if (event.type === 'part') {
          const { part } = event;
          if (part.filename !== null) {
            const target = onFile(part, fields);
            if (!target) throw new HttpError(400, `Unexpected file field "${part.name}"`);
            const stream = fs.createWriteStream(target.path, { flags: 'wx', mode: 0o640 });
            // Errors surface through `stream.errored` / the awaited events below; this keeps them from crashing the process.
            stream.on('error', () => {});
            current = { kind: 'file', part, stream, path: target.path, maxBytes: target.maxBytes ?? Infinity, size: 0, hash: target.hash };
          } else {
            if (++fieldCount > maxFields) throw new HttpError(400, 'Too many form fields');
            current = { kind: 'field', part, chunks: [], size: 0 };
          }
        } else if (event.type === 'data') {
          current.size += event.data.length;
          if (current.kind === 'field') {
            if (current.size > maxFieldBytes) throw new HttpError(413, `Field "${current.part.name}" too large`);
            current.chunks.push(Buffer.from(event.data));
          } else {
            if (current.size > current.maxBytes) throw new HttpError(413, 'File too large');
            current.hash?.update(event.data);
            if (current.stream.errored) throw current.stream.errored;
            if (!current.stream.write(event.data)) await once(current.stream, 'drain');
          }
        } else if (event.type === 'partEnd') {
          if (current.kind === 'field') {
            if (current.part.name) fields[current.part.name] = Buffer.concat(current.chunks).toString('utf8');
          } else {
            if (current.stream.errored) throw current.stream.errored;
            current.stream.end();
            await once(current.stream, 'finish');
            files.push({
              field: current.part.name, filename: current.part.filename, contentType: current.part.contentType,
              path: current.path, size: current.size, hash: current.hash,
            });
          }
          current = null;
        }
      }
    }
    tokenizer.end();
    return { fields, files };
  } catch (err) {
    cleanup();
    throw err;
  }
}
