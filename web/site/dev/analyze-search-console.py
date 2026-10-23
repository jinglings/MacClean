"""Analyze exported Search Console CSVs without claiming traffic or missing pages not in the data."""
import argparse
import csv
import io
import json
import re
import sys
from collections import defaultdict
from datetime import date
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlsplit

ALIASES = {
    'query': ['query', 'queries', 'top queries', '热门查询', '熱門查詢', '最常见查询', '最常見查詢', '查询', '查詢', '查询最多的字词', '查詢最多的字詞'],
    'page': ['page', 'pages', 'top pages', 'url', 'landing page', '网页', '網頁', '页面', '頁面', '热门网页', '熱門網頁'],
    'clicks': ['clicks', 'click', '点击次数', '點擊次數', '点击数', '點擊數', '点击', '點擊'],
    'impressions': ['impressions', 'impression', '展示次数', '顯示次數', '曝光次数', '曝光次數', '展示量', '曝光量', '展示', '曝光', '曝光數'],
    'ctr': ['ctr', 'click through rate', 'click-through rate', '点击率', '點擊率', '点击率 (CTR)', '點擊率 (CTR)'],
    'position': ['position', 'average position', 'avg position', '平均排名', '排名', '平均排序'],
}
BRAND = re.compile(r'\bmacclean\b|\bmac\s+clean\b|thulem', re.I)
PDF = re.compile(r'pdf|rotate[- _]?pdf|merge[- _]?pdf|旋转.*pdf|合并.*pdf', re.I)
MAC = re.compile(r'\bmac(?:os|book)?\b|苹果电脑|蘋果電腦', re.I)
CLEANUP = re.compile(r'clean|storag|space|disk|cache|uninstall|duplicate|leftover|system.?data|wechat|wecom|qq|清理|储存|儲存|存储|存儲|空间|空間|磁盘|磁碟|缓存|快取|卸载|移除|重复|重複|系统数据|系統資料|微信', re.I)
DEVELOPER = re.compile(r'xcode|derived.?data|ollama|hugging.?face|lm.?studio|(?:npm|pip|gradle|docker).*(?:cache|clean|space|缓存|清理)', re.I)
TOPICS = [
    ('wechat_storage', re.compile(r'wechat|wecom|微信|企业微信|企業微信', re.I), 'wechat-storage-cleanup'),
    ('system_data', re.compile(r'system.?data|系统数据|系統資料|系统资料|系統數據', re.I), 'mac-system-data-cleanup'),
    ('developer_cache', re.compile(r'xcode|derived.?data|(?:npm|pip|gradle).*(?:cache|缓存|快取|清理)', re.I), 'xcode-cache-cleanup'),
]
CATEGORIES = ['brand', 'relevant_nonbrand', 'unrelated_historical_pdf', 'other']


def header_key(value):
    return re.sub(r'[\s_\-()%（）]+', '', value.lstrip('\ufeff').strip().lower())


HEADER_LOOKUP = {header_key(alias): name for name, aliases in ALIASES.items() for alias in aliases}


def number(value, name, row_number, required=True):
    cleaned = re.sub(r'[,\s\u00a0\u202f]', '', value or '').replace('％', '%')
    if cleaned.lower() in {'', '-', '—', '--', 'n/a', 'na'}:
        if required:
            raise ValueError(f'row {row_number}: missing {name}')
        return None
    percent = cleaned.endswith('%')
    try:
        result = Decimal(cleaned.rstrip('%'))
    except InvalidOperation:
        raise ValueError(f'row {row_number}: invalid {name} {value!r}') from None
    if not result.is_finite() or result < 0:
        raise ValueError(f'row {row_number}: {name} must be finite and nonnegative')
    if name in {'clicks', 'impressions'}:
        if percent or result != result.to_integral_value():
            raise ValueError(f'row {row_number}: {name} must be a whole count')
        return int(result)
    if name == 'ctr':
        result /= 100 if percent or result > 1 else 1
        if result > 1:
            raise ValueError(f'row {row_number}: CTR exceeds 100%')
    elif percent or (name == 'position' and result <= 0):
        raise ValueError(f'row {row_number}: invalid {name}')
    return float(result)


def load_export(path, dimension, require_page=False):
    source = Path(path).read_text(encoding='utf-8-sig')
    try:
        dialect = csv.Sniffer().sniff(source[:8192], delimiters=',\t;')
    except csv.Error:
        dialect = csv.excel
    reader = csv.DictReader(io.StringIO(source), dialect=dialect)
    fields = {}
    for header in reader.fieldnames or []:
        canonical = HEADER_LOOKUP.get(header_key(header))
        if canonical:
            if canonical in fields:
                raise ValueError(f'{path}: duplicate {canonical} columns')
            fields[canonical] = header
    needed = {dimension, 'clicks', 'impressions'}
    if require_page:
        needed.add('page')
    if not needed <= fields.keys():
        raise ValueError(f'{path}: missing columns {sorted(needed - fields.keys())}; use English or Chinese GSC headers')
    rows = []
    for index, row in enumerate(reader, 2):
        if not any(value and str(value).strip() for value in row.values()):
            continue
        if None in row:
            raise ValueError(f'{path}: row {index} has excess columns; quote numbers containing commas')
        label = (row.get(fields[dimension]) or '').strip()
        if not label:
            raise ValueError(f'{path}: row {index} has an empty {dimension}')
        metrics = {key: number(row.get(fields[key]), key, index, required=key in {'clicks', 'impressions'}) for key in ('clicks', 'impressions', 'ctr', 'position') if key in fields}
        if metrics['clicks'] > metrics['impressions']:
            raise ValueError(f'{path}: row {index} has more clicks than impressions')
        result = {key: (row.get(fields[key]) or '').strip() for key in ('query', 'page') if key in fields}
        result.update(metrics)
        result['exported_ctr'] = result.pop('ctr', None)
        result['ctr'] = metrics['clicks'] / metrics['impressions'] if metrics['impressions'] else None
        result.setdefault('position', None)
        rows.append(result)
    return rows


def query_category(query):
    if PDF.search(query):
        return 'unrelated_historical_pdf'
    if BRAND.search(query):
        return 'brand'
    if DEVELOPER.search(query) or (MAC.search(query) and CLEANUP.search(query)) or re.search(r'微信.*(?:清理|占用|缓存|空间)|(?:清理|缓存|空间).*微信', query):
        return 'relevant_nonbrand'
    return 'other'


def page_category(page):
    parsed = urlsplit(page)
    if PDF.search(parsed.path):
        return 'unrelated_historical_pdf'
    if parsed.netloc and parsed.hostname not in {'thulem.com', 'www.thulem.com'}:
        return 'other'
    path = re.sub(r'^/en(?=/)', '', parsed.path).rstrip('/') or '/'
    if path in {'/', '/index.html', '/download.html', '/support.html', '/privacy.html', '/terms.html'} or path.startswith('/guides/') or path == '/guides':
        return 'relevant_product_page'
    return 'other'


def topic_for(query):
    for name, pattern, slug in TOPICS:
        if pattern.search(query):
            return name, '/guides/' + slug + '.html'
    return None, None


def aggregate(rows):
    clicks = sum(row['clicks'] for row in rows)
    impressions = sum(row['impressions'] for row in rows)
    positioned = [row for row in rows if row['position'] is not None and row['impressions']]
    position_weight = sum(row['impressions'] for row in positioned)
    return {
        'rows': len(rows), 'clicks': clicks, 'impressions': impressions,
        'ctr': clicks / impressions if impressions else None,
        'impression_weighted_position_from_exported_rows': sum(row['position'] * row['impressions'] for row in positioned) / position_weight if position_weight else None,
    }


def recommendation(row, args):
    category = row['category']
    if category not in {'brand', 'relevant_nonbrand'} or row['impressions'] < args.min_impressions:
        return None
    topic, relevant_guide = topic_for(row['query'])
    actual_page = row.get('page') or None
    position, ctr = row['position'], row['ctr']
    low_ctr = ctr is not None and ctr < args.low_ctr
    reasons = []
    priority = 3
    if low_ctr and position is not None and position <= 10:
        reasons.append('review title/description against the exact query; compare search results and devices')
        priority = 1
    elif position is not None and 10 < position <= 30:
        reasons.append('review answer depth, headings and contextual internal links for this intent')
        priority = 2
    elif position is not None and position > 30:
        reasons.append('inspect intent and competing results before expanding content')
    elif low_ctr:
        reasons.append('inspect query position and snippet; low CTR alone does not identify the cause')
    if actual_page and relevant_guide:
        normalized_path = re.sub(r'^/en(?=/)', '', urlsplit(actual_page).path)
        if normalized_path != relevant_guide:
            reasons.append('inspect landing intent: exported page differs from the relevant guide; this does not prove the guide is missing')
            priority = min(priority, 2)
    if not reasons:
        return None
    if not actual_page:
        action = 'candidate: inspect landing URL; ' + '; '.join(reasons)
    else:
        action = '; '.join(reasons)
    return {**row, 'priority': priority, 'topic': topic, 'candidate_guide': relevant_guide, 'landing_page_evidence': 'query-page row' if actual_page else 'unavailable in query-only export', 'action': action}


def build_report(args):
    queries = load_export(args.queries, 'query')
    for row in queries:
        row['category'] = query_category(row['query'])
    page_rows = load_export(args.pages, 'page') if args.pages else []
    for row in page_rows:
        row['category'] = page_category(row['page'])
    query_pages = load_export(args.query_pages, 'query', require_page=True) if args.query_pages else []
    if query_pages and not all(row.get('page') for row in query_pages):
        raise ValueError('--query-pages requires query and page columns in every row')
    for row in query_pages:
        row['category'] = query_category(row['query'])
    evidence_rows = query_pages or queries
    opportunities = [recommendation(row, args) for row in evidence_rows]
    opportunities = sorted((row for row in opportunities if row), key=lambda row: (row['priority'], -row['impressions'], row['query']))
    groups = defaultdict(list)
    for row in queries:
        groups[row['category']].append(row)
    page_groups = defaultdict(list)
    for row in page_rows:
        page_groups[row['category']].append(row)
    unrelated = [row for row in queries if row['category'] == 'unrelated_historical_pdf']
    return {
        'date_span': {'start': args.start_date, 'end': args.end_date, 'source': 'provided CLI arguments' if args.start_date else 'not provided; CSV metrics are not date-stamped here'},
        'inputs': {'queries': str(args.queries), 'pages': str(args.pages) if args.pages else None, 'query_pages': str(args.query_pages) if args.query_pages else None},
        'thresholds': {'min_impressions_per_row': args.min_impressions, 'low_ctr': args.low_ctr},
        'query_export_totals': aggregate(queries),
        'queries_by_category': {category: aggregate(groups[category]) for category in CATEGORIES},
        'product_query_export_totals_excluding_pdf_and_other': aggregate([row for row in queries if row['category'] in {'brand', 'relevant_nonbrand'}]),
        'pages_by_category': {category: aggregate(rows) for category, rows in page_groups.items()},
        'opportunities': opportunities[:args.limit],
        'opportunity_count_before_limit': len(opportunities),
        'excluded_historical_pdf_queries': sorted(unrelated, key=lambda row: -row['impressions'])[:args.limit],
        'queries': queries,
        'pages': page_rows,
        'query_pages': query_pages,
        'limitations': [
            'Totals describe exported rows only, not the entire property; anonymized queries and export limits may omit traffic.',
            'Separate Queries and Pages exports do not join queries to landing URLs. Only a row with both dimensions provides that evidence.',
            'CTR is calculated from exported clicks/impressions. Weighted position is calculated only from rows with a position.',
            'Relevance categories are heuristics for review. Historical PDF queries are excluded from MacClean product totals.',
            'Sample thresholds prioritize inspection; low CTR, ranking or a suggested guide is not proof of a content gap or a promised gain.',
            'Search clicks do not establish downloads, completed trials or purchases.',
        ],
    }


def display_number(value, digits=1):
    return '—' if value is None else f'{value:,.{digits}f}'


def markdown(report):
    span = report['date_span']
    lines = ['# MacClean Search Console export review', '', f"Date span: {span['start']} to {span['end']}" if span['start'] else 'Date span: not provided.', '', 'Metrics below cover exported rows only. Query-only data cannot identify a missing landing page.', '', '| Query category | Rows | Clicks | Impressions | CTR | Weighted position |', '|---|---:|---:|---:|---:|---:|']
    for category, metrics in report['queries_by_category'].items():
        lines.append(f"| {category} | {metrics['rows']} | {metrics['clicks']:,} | {metrics['impressions']:,} | {display_number(metrics['ctr'] * 100 if metrics['ctr'] is not None else None)}% | {display_number(metrics['impression_weighted_position_from_exported_rows'])} |")
    lines.extend(['', '## Prioritized inspection candidates', '', f"Minimum sample: {report['thresholds']['min_impressions_per_row']} impressions per row; low CTR threshold: {report['thresholds']['low_ctr']:.1%}. These are inspection thresholds, not industry benchmarks.", '', '| Priority | Query | Landing evidence | Clicks / impressions | CTR | Position | Next action |', '|---|---|---|---:|---:|---:|---|'])
    escape = lambda value: str(value).replace('|', '\\|').replace('\n', ' ')
    for row in report['opportunities']:
        landing = row.get('page') or 'unavailable: inspect landing URL'
        ctr = display_number(row['ctr'] * 100 if row['ctr'] is not None else None)
        lines.append(f"| P{row['priority']} | {escape(row['query'])} | {escape(landing)} | {row['clicks']:,} / {row['impressions']:,} | {ctr}% | {display_number(row['position'])} | {escape(row['action'])} |")
    if not report['opportunities']:
        lines.append('| — | No exported rows met the inspection thresholds | — | — | — | — | Collect a larger comparable sample. |')
    if report['pages_by_category']:
        lines.extend(['', '## Separate page export', '', 'These aggregates do not establish which queries reached each page.', '', '| Page category | Rows | Clicks | Impressions |', '|---|---:|---:|---:|'])
        for category, metrics in report['pages_by_category'].items():
            lines.append(f"| {category} | {metrics['rows']} | {metrics['clicks']:,} | {metrics['impressions']:,} |")
    lines.extend(['', '## Excluded historical PDF traffic', ''])
    for row in report['excluded_historical_pdf_queries']:
        lines.append(f"- {escape(row['query'])}: {row['clicks']:,} clicks / {row['impressions']:,} impressions; excluded from product-query totals.")
    if not report['excluded_historical_pdf_queries']:
        lines.append('No PDF queries matched the heuristic in this export.')
    lines.extend(['', '## Limits', ''] + ['- ' + limitation for limitation in report['limitations']])
    return '\n'.join(lines) + '\n'


def csv_report(report):
    buffer = io.StringIO()
    fields = ['start_date', 'end_date', 'priority', 'query', 'category', 'page', 'clicks', 'impressions', 'ctr', 'position', 'topic', 'candidate_guide', 'landing_page_evidence', 'action']
    writer = csv.DictWriter(buffer, fieldnames=fields, extrasaction='ignore')
    writer.writeheader()
    writer.writerows({**row, 'start_date': report['date_span']['start'], 'end_date': report['date_span']['end']} for row in report['opportunities'])
    return buffer.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, epilog='Example (replace dates with the actual export range):\n  python3 analyze-search-console.py --queries Queries.csv --pages Pages.csv --start-date 2026-10-07 --end-date 2026-11-03 --format markdown --output review.md\n\nUse equal date spans and the same search type, country, device and URL filters when comparing exports.\nA separate Pages CSV cannot establish query-to-page attribution. Use --query-pages only for an export with both dimensions.')
    parser.add_argument('--queries', required=True, type=Path, help='GSC Queries CSV, with English/Chinese headers; UTF-8 BOM is accepted.')
    parser.add_argument('--pages', type=Path, help='Optional separate Pages CSV (aggregates only, never joined to query rows).')
    parser.add_argument('--query-pages', type=Path, help='Optional export containing both query and page dimensions in the same rows.')
    parser.add_argument('--start-date', type=date.fromisoformat, help='Actual inclusive start date of the exported report (YYYY-MM-DD).')
    parser.add_argument('--end-date', type=date.fromisoformat, help='Actual inclusive end date of the exported report (YYYY-MM-DD).')
    parser.add_argument('--min-impressions', type=int, default=20, help='Minimum impressions per candidate row (default: 20).')
    parser.add_argument('--low-ctr', type=float, default=0.02, help='CTR fraction for inspection, e.g. 0.02 = 2%% (default: 0.02).')
    parser.add_argument('--limit', type=int, default=20, help='Maximum displayed candidates/PDF rows (default: 20; JSON still includes all raw rows).')
    parser.add_argument('--format', choices=['markdown', 'json', 'csv'], default='markdown', help='Report format (default: markdown). CSV contains inspection candidates only.')
    parser.add_argument('--output', type=Path, help='Write the report here; otherwise print to stdout.')
    args = parser.parse_args()
    if bool(args.start_date) != bool(args.end_date):
        parser.error('provide --start-date and --end-date together')
    if args.start_date and args.start_date > args.end_date:
        parser.error('--start-date must not be after --end-date')
    if args.min_impressions < 1 or args.limit < 1 or not 0 <= args.low_ctr <= 1:
        parser.error('sample/limit must be positive and --low-ctr must be between 0 and 1')
    args.start_date = args.start_date.isoformat() if args.start_date else None
    args.end_date = args.end_date.isoformat() if args.end_date else None
    report = build_report(args)
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n' if args.format == 'json' else csv_report(report) if args.format == 'csv' else markdown(report)
    if args.output:
        args.output.write_text(output, encoding='utf-8')
        print(f'Wrote {args.output}; {report["opportunity_count_before_limit"]} inspection candidates from exported rows.', file=sys.stderr)
    else:
        sys.stdout.write(output)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, csv.Error) as error:
        print('ERROR:', error, file=sys.stderr)
        sys.exit(1)
