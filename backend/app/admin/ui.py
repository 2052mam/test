"""Shared chrome for the admin panel: layout, styles, and small widgets.

Kept separate from the routes so every page renders the same navigation,
filter bar, table and pagination markup instead of each view inventing its own.
"""
from html import escape

NAV_ITEMS = (
    ('', 'داشبورد', '📊'),
    ('users', 'کاربران', '👥'),
    ('chats', 'چت‌ها', '💬'),
    ('messages', 'پیام‌ها', '✉️'),
    ('support', 'پشتیبانی', '🎧'),
    ('reports', 'گزارش‌ها', '🚩'),
    ('media', 'رسانه‌ها', '🖼'),
    ('devices', 'دستگاه‌ها', '📱'),
    ('security', 'امنیت', '🛡'),
    ('audit', 'لاگ سیستم', '📜'),
    ('settings', 'تنظیمات', '⚙️'),
)

BASE_CSS = """
:root{--bg:#0b1220;--card:#121a2b;--card2:#0d1526;--line:#1e2a44;--text:#e8eefc;
--muted:#8b9bb8;--accent:#3b82f6;--accent2:#60a5fa;--ok:#22c55e;--warn:#f59e0b;
--danger:#ef4444;--radius:14px}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Tahoma,Segoe UI,sans-serif;background:var(--bg);color:var(--text);
min-height:100vh;font-size:14px}
a{color:var(--accent2);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:flex;min-height:100vh}
.sidebar{width:210px;background:#0a101d;border-left:1px solid var(--line);
padding:16px 0;position:sticky;top:0;height:100vh;overflow:auto;flex-shrink:0}
.brand{padding:0 18px 16px;font-size:1rem;color:var(--accent2);font-weight:700;
border-bottom:1px solid var(--line);margin-bottom:12px}
.sidebar a{display:flex;align-items:center;gap:10px;padding:11px 18px;color:var(--muted);
font-size:.9rem;border-right:3px solid transparent}
.sidebar a:hover{background:#0f1728;color:#fff;text-decoration:none}
.sidebar a.active{background:#101a2e;color:#fff;border-right-color:var(--accent)}
.sidebar .sep{margin:12px 18px;border-top:1px solid var(--line)}
.main{flex:1;min-width:0;display:flex;flex-direction:column}
.topbar{display:flex;justify-content:space-between;align-items:center;
padding:14px 22px;border-bottom:1px solid var(--line);background:#0d1526;
position:sticky;top:0;z-index:10}
.topbar h1{font-size:1.05rem}
.topbar .who{color:var(--muted);font-size:.82rem}
.content{padding:20px 22px;flex:1}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:18px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:15px;text-align:center}
.stat-value{font-size:1.6rem;font-weight:700;color:var(--accent2)}
.stat-label{color:var(--muted);font-size:.78rem;margin-top:4px}
.stat.warn .stat-value{color:var(--warn)}
.stat.danger .stat-value{color:var(--danger)}
.stat.ok .stat-value{color:var(--ok)}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
padding:16px;margin-bottom:16px;overflow:auto}
.card h2{font-size:1rem;margin-bottom:12px;color:var(--accent2);
display:flex;justify-content:space-between;align-items:center;gap:10px}
.filters{display:flex;flex-wrap:wrap;gap:8px;align-items:flex-end;margin-bottom:14px;
background:var(--card2);border:1px solid var(--line);border-radius:var(--radius);padding:12px}
.filters .f{display:flex;flex-direction:column;gap:4px}
.filters label{font-size:.72rem;color:var(--muted)}
.filters input,.filters select{background:#0b1220;border:1px solid var(--line);
color:var(--text);border-radius:8px;padding:7px 9px;font-family:inherit;font-size:.82rem;min-width:130px}
.filters input:focus,.filters select:focus{outline:1px solid var(--accent)}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th,td{padding:9px 8px;text-align:right;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;background:var(--card2);position:sticky;top:0}
tr:hover td{background:#0d1526}
td.mono{font-family:monospace;font-size:.78rem;color:var(--muted)}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.72rem;white-space:nowrap}
.badge-ok{background:#14532d;color:#86efac}
.badge-off{background:#1e293b;color:#94a3b8}
.badge-bad{background:#7f1d1d;color:#fca5a5}
.badge-warn{background:#78350f;color:#fcd34d}
.badge-info{background:#1e3a8a;color:#93c5fd}
.btn{background:var(--accent);color:#fff;border:none;padding:7px 12px;border-radius:8px;
cursor:pointer;font-size:.8rem;font-family:inherit}
.btn:hover{filter:brightness(1.1)}
.btn-danger{background:var(--danger)}
.btn-warn{background:var(--warn);color:#1a1205}
.btn-ghost{background:#1e293b;color:var(--text)}
.btn-sm{padding:4px 9px;font-size:.74rem}
.actions{display:flex;gap:5px;flex-wrap:wrap}
.pager{display:flex;gap:6px;align-items:center;justify-content:center;margin-top:14px;flex-wrap:wrap}
.pager a,.pager span{padding:6px 11px;border-radius:8px;border:1px solid var(--line);
background:var(--card2);font-size:.8rem}
.pager .cur{background:var(--accent);color:#fff;border-color:var(--accent)}
.pager .off{color:#475569}
.empty{text-align:center;color:var(--muted);padding:34px 10px}
.bar{display:flex;align-items:center;gap:8px;margin-bottom:5px}
.bar-track{flex:1;height:8px;background:#0b1220;border-radius:99px;overflow:hidden}
.bar-fill{height:100%;background:linear-gradient(90deg,#3b82f6,#60a5fa)}
.bar-label{font-size:.76rem;color:var(--muted);min-width:110px}
.bar-value{font-size:.76rem;color:var(--accent2);min-width:42px;text-align:left}
.chart{display:flex;align-items:flex-end;gap:3px;height:120px;padding-top:8px}
.chart .col{flex:1;display:flex;flex-direction:column;justify-content:flex-end;
align-items:center;gap:3px;height:100%}
.chart .col i{display:block;width:100%;background:linear-gradient(180deg,#3b82f6,#1d4ed8);
border-radius:3px 3px 0 0;min-height:2px}
.chart .col b{font-size:.6rem;color:#475569;font-weight:400;writing-mode:vertical-rl}
.thread{max-height:440px;overflow:auto;display:flex;flex-direction:column;gap:9px;padding:4px}
.msg{max-width:78%;padding:9px 12px;border-radius:12px;background:#16233c;font-size:.84rem;
line-height:1.7;white-space:pre-wrap;word-break:break-word}
.msg.mine{background:#1d4ed8;align-self:flex-start}
.msg.theirs{align-self:flex-end}
.msg .meta{display:block;font-size:.68rem;color:#94a3b8;margin-top:5px}
.reply{display:flex;gap:8px;margin-top:12px}
.reply textarea{flex:1;background:#0b1220;border:1px solid var(--line);color:var(--text);
border-radius:10px;padding:10px;font-family:inherit;font-size:.85rem;resize:vertical;min-height:62px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:7px 14px;font-size:.85rem}
.kv dt{color:var(--muted)}
.kv dd{word-break:break-all}
.flash{padding:11px 14px;border-radius:10px;margin-bottom:14px;font-size:.86rem}
.flash-ok{background:#14532d;color:#bbf7d0;border:1px solid #166534}
.flash-err{background:#7f1d1d;color:#fecaca;border:1px solid #991b1b}
.login-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center}
.login-card{width:100%;max-width:380px;background:var(--card);border:1px solid var(--line);
border-radius:16px;padding:28px}
.login-card h2{margin-bottom:14px;color:var(--accent2)}
.login-card input{width:100%;padding:12px;margin:8px 0;border-radius:10px;
border:1px solid var(--line);background:#0b1220;color:#fff;font-family:inherit}
.login-card button{width:100%;margin-top:10px;padding:12px;border:none;border-radius:10px;
background:var(--accent);color:#fff;cursor:pointer;font-size:1rem;font-family:inherit}
.error{color:#fca5a5;margin-top:10px;font-size:.86rem}
.tabs{display:flex;gap:6px;margin-bottom:14px;flex-wrap:wrap}
.tabs a{padding:7px 14px;border-radius:99px;background:var(--card2);
border:1px solid var(--line);font-size:.82rem;color:var(--muted)}
.tabs a.active{background:var(--accent);color:#fff;border-color:var(--accent)}
@media(max-width:820px){.sidebar{width:56px}.sidebar .brand,.sidebar a span{display:none}
.sidebar a{justify-content:center;padding:13px 0}}
"""


def e(value):
    """Escape for HTML text; None renders as an em dash."""
    if value is None or value == '':
        return '—'
    return escape(str(value))


def page(secret, title, body, active='', flash=None):
    """Wrap a page body in the standard shell."""
    nav = ''.join(
        f'<a class="{"active" if active == slug else ""}" '
        f'href="/{secret}/{slug}"><span>{icon} {label}</span>'
        f'<span style="display:none">{icon}</span></a>'
        for slug, label, icon in NAV_ITEMS
    )
    flash_html = ''
    if flash:
        kind, text = flash
        flash_html = (f'<div class="flash flash-{"ok" if kind == "ok" else "err"}">'
                      f'{escape(text)}</div>')
    return f"""<!DOCTYPE html><html lang="fa" dir="rtl"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{escape(title)} · پنل مدیریت</title><style>{BASE_CSS}</style></head><body>
<div class="layout">
<aside class="sidebar">
<div class="brand">✦ Reyno</div>
{nav}
<div class="sep"></div>
<a href="/{secret}/logout"><span>🚪 خروج</span></a>
</aside>
<div class="main">
<div class="topbar"><h1>{escape(title)}</h1>
<span class="who">پنل مدیریت</span></div>
<div class="content">{flash_html}{body}</div>
</div></div></body></html>"""


def stat(value, label, tone=''):
    return (f'<div class="stat {tone}"><div class="stat-value">{e(value)}</div>'
            f'<div class="stat-label">{escape(label)}</div></div>')


def table(headers, rows, empty='چیزی برای نمایش نیست'):
    if not rows:
        return f'<div class="empty">{escape(empty)}</div>'
    head = ''.join(f'<th>{escape(h)}</th>' for h in headers)
    return (f'<table><thead><tr>{head}</tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table>')


def pager(secret, path, page_no, pages, params):
    """Pagination that preserves the active filters."""
    if pages <= 1:
        return ''
    from urllib.parse import urlencode

    def link(target, label, cls=''):
        query = dict(params)
        query['page'] = target
        clean = {k: v for k, v in query.items() if v not in (None, '')}
        return (f'<a class="{cls}" href="/{secret}/{path}?{urlencode(clean)}">'
                f'{label}</a>')

    parts = []
    parts.append(link(page_no - 1, '‹ قبلی') if page_no > 1
                 else '<span class="off">‹ قبلی</span>')
    window = [p for p in range(page_no - 2, page_no + 3) if 1 <= p <= pages]
    if window and window[0] > 1:
        parts.append(link(1, '1'))
        if window[0] > 2:
            parts.append('<span class="off">…</span>')
    for p in window:
        parts.append(f'<span class="cur">{p}</span>' if p == page_no
                     else link(p, str(p)))
    if window and window[-1] < pages:
        if window[-1] < pages - 1:
            parts.append('<span class="off">…</span>')
        parts.append(link(pages, str(pages)))
    parts.append(link(page_no + 1, 'بعدی ›') if page_no < pages
                 else '<span class="off">بعدی ›</span>')
    return f'<div class="pager">{"".join(parts)}</div>'


def filter_bar(secret, path, fields, values):
    """Render a GET filter form.

    ``fields`` is a list of (name, label, kind, options) where kind is
    'text', 'date' or 'select' and options is a list of (value, label).
    """
    inputs = []
    for name, label, kind, options in fields:
        current = values.get(name) or ''
        if kind == 'select':
            opts = ''.join(
                f'<option value="{escape(str(val))}"'
                f'{" selected" if str(current) == str(val) else ""}>'
                f'{escape(text)}</option>'
                for val, text in options)
            control = f'<select name="{name}">{opts}</select>'
        else:
            input_type = 'date' if kind == 'date' else 'text'
            control = (f'<input type="{input_type}" name="{name}" '
                       f'value="{escape(str(current))}" '
                       f'placeholder="{escape(label)}">')
        inputs.append(f'<div class="f"><label>{escape(label)}</label>{control}</div>')
    return (f'<form class="filters" method="get" action="/{secret}/{path}">'
            f'{"".join(inputs)}'
            f'<div class="f"><button class="btn" type="submit">اعمال فیلتر</button></div>'
            f'<div class="f"><a class="btn btn-ghost" style="display:inline-block" '
            f'href="/{secret}/{path}">پاک کردن</a></div></form>')


def action_form(secret, action_path, label, csrf, cls='btn btn-sm',
                confirm=None, hidden=None):
    """A one-button POST form carrying the CSRF token."""
    extra = ''.join(
        f'<input type="hidden" name="{escape(k)}" value="{escape(str(v))}">'
        for k, v in (hidden or {}).items())
    on_submit = (f' onsubmit="return confirm(\'{escape(confirm)}\')"'
                 if confirm else '')
    return (f'<form method="post" action="/{secret}/{action_path}" '
            f'style="display:inline"{on_submit}>'
            f'<input type="hidden" name="csrf_token" value="{escape(csrf)}">'
            f'{extra}<button class="{cls}" type="submit">{escape(label)}</button>'
            f'</form>')


def bars(rows, total=None):
    """Horizontal distribution bars (chat types, message types…)."""
    if not rows:
        return '<div class="empty">داده‌ای نیست</div>'
    top = total or max(v for _, v in rows) or 1
    out = []
    for label, value in rows:
        pct = int(round((value / top) * 100)) if top else 0
        out.append(
            f'<div class="bar"><span class="bar-label">{escape(str(label))}</span>'
            f'<span class="bar-track"><i class="bar-fill" style="width:{pct}%"></i></span>'
            f'<span class="bar-value">{value}</span></div>')
    return ''.join(out)


def sparkline(series, key):
    """Tiny CSS bar chart for the 14-day activity series."""
    if not series:
        return '<div class="empty">داده‌ای نیست</div>'
    peak = max((row[key] for row in series), default=0) or 1
    cols = ''.join(
        f'<div class="col" title="{escape(row["date"])}: {row[key]}">'
        f'<i style="height:{max(2, int(row[key] / peak * 100))}%"></i>'
        f'<b>{escape(row["date"][5:])}</b></div>'
        for row in series)
    return f'<div class="chart">{cols}</div>'
