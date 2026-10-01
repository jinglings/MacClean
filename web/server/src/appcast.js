import { rfc822 } from './time.js';

export function escapeXml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function escapeHtml(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** CDATA cannot contain `]]>`; split it across two sections. */
export function cdata(value) {
  return `<![CDATA[${String(value ?? '').replaceAll(']]>', ']]]]><![CDATA[>')}]]>`;
}

/**
 * Release notes are plain text / light Markdown. Sparkle shows the description as HTML, so turn
 * `# headings`, `- lists` and paragraphs into escaped HTML.
 */
export function notesToHtml(notes) {
  const lines = String(notes ?? '').replace(/\r\n?/g, '\n').split('\n');
  const out = [];
  let list = false;
  let para = [];
  const inline = (s) => escapeHtml(s).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/`([^`]+)`/g, '<code>$1</code>');
  const flushPara = () => {
    if (para.length) out.push(`<p>${para.map(inline).join('<br>')}</p>`);
    para = [];
  };
  const closeList = () => {
    if (list) out.push('</ul>');
    list = false;
  };
  for (const raw of lines) {
    const line = raw.trimEnd();
    const heading = /^(#{1,3})\s+(.*)$/.exec(line);
    const item = /^\s*[-*•]\s+(.*)$/.exec(line);
    if (heading) {
      flushPara(); closeList();
      out.push(`<h3>${inline(heading[2])}</h3>`);
    } else if (item) {
      flushPara();
      if (!list) { out.push('<ul>'); list = true; }
      out.push(`<li>${inline(item[1])}</li>`);
    } else if (!line.trim()) {
      flushPara(); closeList();
    } else {
      closeList();
      para.push(line.trim());
    }
  }
  flushPara(); closeList();
  return out.join('\n');
}

/** Sparkle 2 appcast for `releases` (newest first); only releases with an EdDSA signature are listed. */
export function buildAppcast(releases, { publicBaseUrl, title = 'MacClean' }) {
  const items = releases.filter((r) => r.ed_signature).map((r) => `    <item>
      <title>${escapeXml(`Version ${r.version}`)}</title>
      <pubDate>${escapeXml(rfc822(r.published_at))}</pubDate>
      <sparkle:version>${escapeXml(r.build)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXml(r.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${escapeXml(r.min_os)}</sparkle:minimumSystemVersion>
      <description>${cdata(notesToHtml(r.notes))}</description>
      <enclosure url="${escapeXml(`${publicBaseUrl}/files/releases/${encodeURIComponent(r.file_name)}`)}" length="${Number(r.size)}" type="application/octet-stream" sparkle:edSignature="${escapeXml(r.ed_signature)}"/>
    </item>`);
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${escapeXml(title)}</title>
    <link>${escapeXml(`${publicBaseUrl}/appcast.xml`)}</link>
    <description>${escapeXml(`${title} updates`)}</description>
    <language>zh</language>
${items.join('\n')}
  </channel>
</rss>
`;
}
