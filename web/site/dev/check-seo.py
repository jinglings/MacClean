"""Verify crawlable bilingual output and links; this does not verify Google indexing."""
import argparse
import html as html_module
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent
BASE_PAGES = ['index.html', 'download.html', 'support.html', 'privacy.html', 'terms.html']
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
BACKEND = ('/api/', '/files/', '/download/', '/admin')


class Node:
    def __init__(self, tag='', attrs=None):
        self.tag, self.attrs, self.children = tag, attrs or {}, []

    def text(self):
        return ''.join(c.text() if isinstance(c, Node) else c for c in self.children)

    def descendants(self, tag=None):
        for child in self.children:
            if isinstance(child, Node):
                if tag is None or child.tag == tag:
                    yield child
                yield from child.descendants(tag)


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.root = Node()
        self.stack = [self.root]
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs))
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)
        elif tag == 'br':
            node.children.append(' ')

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)

    def select(self, tag, **attrs):
        return [n for n in self.root.descendants(tag) if all(n.attrs.get(k) == v for k, v in attrs.items())]


def normalized(value):
    # Answer text may contain HTML; compare readable text with the visible answer.
    parsed = Page(value)
    return re.sub(r'\s+', ' ', html_module.unescape(parsed.root.text())).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def expected_files():
    files = list(BASE_PAGES)
    config = ROOT / 'dev/seo-guides.json'
    if config.exists():
        payload = json.loads(config.read_text())
        guides = payload if isinstance(payload, list) else payload['guides']
        files.append('guides/index.html')
        files.extend('guides/' + guide['slug'] + '.html' for guide in guides)
    return files + ['en/' + file for file in files]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Read deployed pages and check same-origin static links/assets over HTTP.')
    parser.add_argument('--origin', default='https://thulem.com', help='Canonical site origin (default: https://thulem.com).')
    args = parser.parse_args()
    origin = args.origin.rstrip('/')
    sources, pages, checked_assets = {}, {}, set()

    def read(path):
        if path in sources:
            return sources[path]
        if args.live:
            requested_url = origin + path
            request = urllib.request.Request(requested_url, headers={'User-Agent': 'MacClean-SEO-Check/1.0'})
            try:
                with urllib.request.urlopen(request, timeout=25) as response:
                    require(response.status == 200, f'{requested_url}: HTTP {response.status}')
                    require('noindex' not in response.headers.get('X-Robots-Tag', '').lower(), f'{requested_url}: HTTP noindex')
                    source = response.read().decode('utf-8')
            except urllib.error.HTTPError as error:
                raise ValueError(f'GET {requested_url}: HTTP {error.code} {error.reason}') from error
            except urllib.error.URLError as error:
                raise ValueError(f'GET {requested_url}: {error.reason}') from error
        else:
            target = ROOT / unquote(path.lstrip('/'))
            if path.endswith('/'):
                target /= 'index.html'
            source = target.read_text()
        sources[path] = source
        return source

    def page_for(path):
        if path not in pages:
            pages[path] = Page(read(path))
        return pages[path]

    files = expected_files()
    expected = {origin + '/' + re.sub(r'(^|/)index\.html$', r'\1', file) for file in files}
    urls = [node.text for node in ET.fromstring(read('/sitemap.xml')).iter('{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
    require(len(urls) == len(set(urls)), 'sitemap.xml: duplicate URLs')
    require(set(urls) == expected, f'sitemap.xml: missing {sorted(expected - set(urls))}, unexpected {sorted(set(urls) - expected)}')
    titles, descriptions, alternates_by_url = {}, {}, {}

    for url in urls:
        path = urlsplit(url).path
        page = page_for(path)
        canonical = page.select('link', rel='canonical')
        require(len(canonical) == 1 and canonical[0].attrs.get('href') == url, f'{path}: canonical must match sitemap URL')
        require(len(page.select('h1')) == 1, f'{path}: expected one h1')
        title_nodes = page.select('title')
        require(len(title_nodes) == 1, f'{path}: expected one title')
        title = normalized(title_nodes[0].text())
        description_nodes = page.select('meta', name='description')
        require(len(description_nodes) == 1, f'{path}: expected one meta description')
        description = normalized(description_nodes[0].attrs.get('content', ''))
        require(title and description, f'{path}: empty title or description')
        require(title not in titles, f'{path}: duplicate title with {titles.get(title)}')
        require(description not in descriptions, f'{path}: duplicate description with {descriptions.get(description)}')
        titles[title], descriptions[description] = url, url
        robots = page.select('meta', name='robots')
        require(len(robots) == 1 and 'noindex' not in robots[0].attrs.get('content', '').lower(), f'{path}: missing robots or noindex')
        english = path.startswith('/en/')
        locale, language = ('en', 'en') if english else ('zh', 'zh-CN')
        html_nodes = page.select('html')
        require(len(html_nodes) == 1 and html_nodes[0].attrs.get('lang') == language and html_nodes[0].attrs.get('data-site-locale') == locale, f'{path}: language must be static and correct')
        alternate_nodes = [n for n in page.select('link', rel='alternate') if 'hreflang' in n.attrs]
        alternates = {n.attrs['hreflang']: n.attrs.get('href') for n in alternate_nodes}
        require(len(alternate_nodes) == 3 and set(alternates) == {'zh-CN', 'en', 'x-default'}, f'{path}: expected three unique hreflang links')
        require(all(value in expected for value in alternates.values()) and alternates['x-default'] == alternates['zh-CN'] and alternates[language] == url, f'{path}: invalid hreflang target')
        alternates_by_url[url] = alternates
        switches = page.select('a', id='lang-btn')
        require(len(switches) == 1 and urljoin(url, switches[0].attrs.get('href', '')) == alternates['zh-CN' if english else 'en'], f'{path}: invalid language switch')
        for property_name, expected_value in [('og:url', url), ('og:title', title), ('og:description', description)]:
            tags = page.select('meta', property=property_name)
            require(len(tags) == 1 and normalized(tags[0].attrs.get('content', '')) == expected_value, f'{path}: {property_name} does not match page metadata')
        scripts = page.select('script', type='application/ld+json')
        require(len(scripts) == 1, f'{path}: expected one JSON-LD graph')
        schema = json.loads(scripts[0].text())
        require(schema.get('@context') == 'https://schema.org' and isinstance(schema.get('@graph'), list), f'{path}: invalid JSON-LD graph')
        graph = schema['@graph']
        require(all(isinstance(node, dict) and node.get('@type') for node in graph), f'{path}: schema nodes must have @type')
        web_pages = [node for node in graph if node.get('@id') == url + '#webpage']
        require(len(web_pages) == 1 and web_pages[0].get('url') == url and web_pages[0].get('inLanguage') == language, f'{path}: missing matching WebPage schema')
        visible_faq = []
        for detail in page.select('details'):
            summaries = list(detail.descendants('summary'))
            answers = [node for node in detail.descendants('div') if 'ans' in node.attrs.get('class', '').split()]
            if summaries and answers:
                visible_faq.append((normalized(summaries[0].text()), normalized(answers[0].text())))
        schema_faq = []
        for node in graph:
            types = node['@type'] if isinstance(node['@type'], list) else [node['@type']]
            if 'FAQPage' in types:
                for question in node.get('mainEntity', []):
                    require(question.get('@type') == 'Question' and question.get('acceptedAnswer', {}).get('@type') == 'Answer', f'{path}: invalid FAQ question/answer schema')
                    schema_faq.append((normalized(question.get('name', '')), normalized(question['acceptedAnswer'].get('text', ''))))
        if schema_faq or path.endswith('support.html') or '/guides/' in path:
            require(visible_faq == schema_faq, f'{path}: visible FAQ and JSON-LD questions/answers differ')
        print('PASS', url, flush=True)

    for url, alternates in alternates_by_url.items():
        require(all(alternates_by_url[counterpart] == alternates for counterpart in alternates.values()), f'{url}: hreflang is not reciprocal')

    for url in urls:
        path = urlsplit(url).path
        page = page_for(path)
        for node in page.root.descendants():
            links = [node.attrs[attr] for attr in ('href', 'src', 'poster') if node.attrs.get(attr)]
            links.extend(item.strip().split()[0] for item in node.attrs.get('srcset', '').split(',') if item.strip())
            for link in links:
                target = urlsplit(urljoin(url, link))
                if target.scheme not in {'http', 'https'} or target.netloc != urlsplit(origin).netloc or target.path.startswith(BACKEND):
                    continue
                # Cloudflare replaces mailto links with encoded-email pseudo-links.
                # Its browser script decodes these anchors; the handler is not a static file.
                # Skip only a valid even-length hex token, leaving other /cdn-cgi targets checked.
                if node.tag == 'a' and target.path == '/cdn-cgi/l/email-protection' and re.fullmatch(r'(?:[0-9a-fA-F]{2})+', target.fragment):
                    continue
                asset_path = target.path or '/'
                if asset_path not in checked_assets:
                    if args.live and asset_path not in sources:
                        requested_url = origin + asset_path
                        request = urllib.request.Request(requested_url, method='HEAD', headers={'User-Agent': 'MacClean-SEO-Check/1.0'})
                        try:
                            with urllib.request.urlopen(request, timeout=25) as response:
                                require(response.status == 200, f'{path}: HEAD {requested_url}: HTTP {response.status} (source link {link})')
                        except urllib.error.HTTPError as error:
                            if error.code not in {404, 405}:
                                raise ValueError(f'{path}: HEAD {requested_url}: HTTP {error.code} {error.reason} (source link {link})') from error
                            # Some CDN assets (including Cloudflare's email decoder) serve GET
                            # but return 404/405 to HEAD. Verify the real browser method before
                            # reporting a broken target; genuinely missing files still fail GET.
                            get_request = urllib.request.Request(requested_url, headers={'User-Agent': 'MacClean-SEO-Check/1.0'})
                            try:
                                with urllib.request.urlopen(get_request, timeout=25) as response:
                                    require(response.status == 200, f'{path}: GET {requested_url}: HTTP {response.status} after HEAD {error.code} (source link {link})')
                                    response.read(1)  # Confirm GET can start transferring without downloading full assets.
                            except urllib.error.HTTPError as get_error:
                                raise ValueError(f'{path}: HEAD {requested_url}: HTTP {error.code}; GET {requested_url}: HTTP {get_error.code} {get_error.reason} (source link {link})') from get_error
                            except urllib.error.URLError as get_error:
                                raise ValueError(f'{path}: GET {requested_url} after HEAD {error.code}: {get_error.reason} (source link {link})') from get_error
                        except urllib.error.URLError as error:
                            raise ValueError(f'{path}: HEAD {requested_url}: {error.reason} (source link {link})') from error
                    elif not args.live:
                        target_file = ROOT / unquote(asset_path.lstrip('/'))
                        if asset_path.endswith('/'):
                            target_file /= 'index.html'
                        require(target_file.is_file(), f'{path}: missing static target {link}')
                    checked_assets.add(asset_path)
                if target.fragment and (asset_path.endswith(('.html', '.svg')) or asset_path.endswith('/')):
                    target_page = page_for(asset_path)
                    ids = {n.attrs['id'] for n in target_page.root.descendants() if 'id' in n.attrs}
                    require(unquote(target.fragment) in ids, f'{path}: missing fragment target {link}')

    require('Sitemap: ' + origin + '/sitemap.xml' in read('/robots.txt'), 'robots.txt: missing sitemap declaration')
    print(f'PASS: {len(urls)} pages; unique metadata, reciprocal languages, FAQ parity and {len(checked_assets)} static targets.')
    print('Technical eligibility only; use Search Console for actual indexing and search performance.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError) as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(1)
