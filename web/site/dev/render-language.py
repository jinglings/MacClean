"""Render existing translation keys as static HTML using only the Python standard library."""
import json, sys, re
from html import escape
from html.parser import HTMLParser
payload = json.load(sys.stdin)
translations = payload['translations']
public = {'/', '/index.html', '/download.html', '/support.html', '/privacy.html', '/terms.html', *payload.get('public_paths', [])}
void = {'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}
def localize_link(value):
    path, sep, fragment = value.partition('#')
    if path in public:
        return ('/en/' if path in {'/', '/index.html'} else '/en' + path) + (sep + fragment)
    return value
class Renderer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.skip = 0
    def handle_starttag(self, tag, attrs):
        if self.skip:
            if tag not in void: self.skip += 1
            return
        values = dict(attrs)
        for pair in values.get('data-i18n-attr','').split(','):
            if ':' in pair:
                attr, key = [s.strip() for s in pair.split(':',1)]
                values[attr] = translations[key]
        if tag == 'html': values.update(lang='en', **{'data-site-locale':'en'})
        if tag == 'a' and values.get('id') == 'lang-btn':
            values['href'] = payload['chinese_url']
        elif tag == 'a' and 'href' in values:
            values['href'] = localize_link(values['href'])
        if tag == 'img' and 'data-shot' in values:
            values['src'] = values['src'].replace('light-zh-', 'light-en-')
            if 'srcset' in values: values['srcset'] = values['srcset'].replace('light-zh-', 'light-en-')
            values['alt'] = 'MacClean — ' + values['data-shot'].replace('_', ' ')
        self.out.append('<' + tag + ''.join(' '+k if v is None else ' '+k+'="'+escape(v,quote=True)+'"' for k,v in values.items()) + '>')
        if 'data-i18n' in values and tag not in void:
            # Translations contain intentional HTML (links/emphasis). Localize their links too.
            translated = translations[values['data-i18n']]
            translated = re.sub(r'href="([^"]+)"', lambda m: 'href="'+localize_link(m[1])+'"', translated)
            self.out.append(translated)
            self.skip = 1
    def handle_startendtag(self, tag, attrs):
        if self.skip: return
        self.handle_starttag(tag, attrs)
        if tag not in void: self.out.append('</'+tag+'>')
    def handle_endtag(self, tag):
        if self.skip:
            self.skip -= 1
            if self.skip: return
        self.out.append('</'+tag+'>')
    def handle_data(self, data):
        if not self.skip: self.out.append(data)
    def handle_entityref(self, name):
        if not self.skip: self.out.append('&'+name+';')
    def handle_charref(self, name):
        if not self.skip: self.out.append('&#'+name+';')
    def handle_comment(self, data):
        if not self.skip: self.out.append('<!--'+data+'-->')
    def handle_decl(self, decl): self.out.append('<!'+decl+'>')
r = Renderer()
r.feed(payload['html'])
assert r.skip == 0
sys.stdout.write(''.join(r.out))
