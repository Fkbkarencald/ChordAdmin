#!/usr/bin/env python3
"""Generates the ChordAdmin redesign artboards (*.dc.html) + canvas.json."""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
WAVE_MAIN = open(os.path.join(HERE, "wave_main.txt")).read()
WAVE_MINI = open(os.path.join(HERE, "wave_mini.txt")).read()

# ---------------------------------------------------------------- palette ----
ACC = "#0a6cf5"        # macOS-ish accent blue
GREEN = "#28a745"
GREEN_SYS = "#30b350"
ORANGE = "#f59300"
RED = "#e5372e"
INK = "#1d1d1f"
SUB = "#6e6e73"
FAINT = "#98989e"

CSS = """
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif;background:#e9e9ee;color:#1d1d1f;-webkit-font-smoothing:antialiased}
a{color:#0a63d6}a:hover{color:#084eab}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace}
.win{width:1440px;height:900px;display:flex;flex-direction:column;background:#fff;border-radius:10px;overflow:hidden;position:relative}
.toolbar{height:52px;flex:0 0 52px;display:flex;align-items:center;gap:10px;padding:0 14px;background:linear-gradient(#fafafa,#f1f1f4);border-bottom:1px solid #d9d9de}
.lights{display:flex;gap:8px;margin-right:4px}
.light{width:12px;height:12px;border-radius:50%}
.tbtn{width:30px;height:26px;border-radius:6px;display:flex;align-items:center;justify-content:center;color:#5c5c63}
.btn{display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 12px;border-radius:6px;font-size:12px;font-weight:500;background:linear-gradient(#fff,#f6f6f8);border:1px solid #cfcfd4;box-shadow:0 .5px 1px rgba(0,0,0,.06);color:#1d1d1f;white-space:nowrap}
.btn-primary{background:linear-gradient(#2f8bff,#0a6cf5);border:1px solid #0a5fd0;color:#fff}
.btn-sm{height:23px;padding:0 9px;font-size:11px;border-radius:5.5px}
.pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 10px;border-radius:12px;font-size:11px;font-weight:500}
.body{flex:1;display:flex;min-height:0}
.sidebar{flex:0 0 264px;display:flex;flex-direction:column;background:#f2f2f6;border-right:1px solid #e0e0e4;min-height:0}
.search{display:flex;align-items:center;gap:6px;height:28px;margin:10px 12px 8px;padding:0 8px;border-radius:6.5px;background:#e4e4e9;color:#8a8a90;font-size:12px}
.scope{display:flex;flex-wrap:wrap;gap:5px;padding:0 12px 8px}
.chip{height:21px;padding:0 9px;border-radius:10.5px;font-size:10.5px;font-weight:500;display:inline-flex;align-items:center;gap:4px;background:#e4e4e9;color:#55555c}
.chip-on{background:#4a4a52;color:#fff}
.slist{flex:1;min-height:0;overflow:hidden;padding:2px 8px;display:flex;flex-direction:column;gap:1px}
.srow{display:flex;align-items:center;gap:9px;padding:6px 8px;border-radius:7px}
.sname{font-size:12.5px;font-weight:500;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sartist{font-size:10.5px;color:#86868c;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.thumb{width:34px;height:34px;border-radius:5px;flex:0 0 34px;display:flex;align-items:center;justify-content:center}
.sfoot{border-top:1px solid #e0e0e4;padding:9px 14px;display:flex;flex-direction:column;gap:5px;font-size:10.5px;color:#6e6e73}
.frow{display:flex;align-items:center;gap:6px}
.main{flex:1;min-width:0;display:flex;flex-direction:column;background:#fff;min-height:0}
.transport{height:48px;flex:0 0 48px;display:flex;align-items:center;gap:10px;padding:0 16px;border-bottom:1px solid #ececf0}
.stat{height:22px;padding:0 9px;border-radius:11px;background:#f2f2f6;font-size:11px;font-weight:500;color:#48484e;display:inline-flex;align-items:center;gap:5px;white-space:nowrap}
.waveblock{flex:0 0 132px;border-bottom:1px solid #ececf0;position:relative;background:#fbfbfd;overflow:hidden}
.chart{flex:1;min-height:0;overflow:hidden;padding:14px 20px 0;display:flex;flex-direction:column;gap:12px;position:relative}
.sechead{display:flex;align-items:baseline;gap:8px}
.secname{font-size:13px;font-weight:600}
.secmeta{font-size:10.5px;color:#98989e}
.brow{display:flex;gap:10px}
.bar{flex:1;height:60px;border-radius:8px;background:#f6f6f8;border:1px solid #e7e7ea;position:relative;display:flex;gap:3px;padding:3px}
.barno{position:absolute;top:2px;left:6px;font-size:8.5px;color:#a4a4aa;font-weight:700;z-index:2;font-family:ui-monospace,"SF Mono",Menlo,monospace}
.seg{flex:1;border-radius:5.5px;background:#fff;border:1px solid #e4e4e8;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:600;color:#2b2b30}
.bar-sel{border:1.5px solid #0a6cf5;box-shadow:0 0 0 3px rgba(10,108,245,.14)}
.bar-act{border:1.5px solid #30b350;background:#f0faf2}
.bar-chg{border:1.5px dashed #0a6cf5;background:rgba(10,108,245,.045)}
.pop{position:absolute;display:flex;align-items:center;gap:5px;background:#fff;border:1px solid #d6d6dc;border-radius:9px;padding:5px 6px;box-shadow:0 10px 30px rgba(0,0,0,.18);z-index:6}
.popbtn{height:24px;padding:0 9px;border-radius:6px;font-size:11px;font-weight:500;background:#f4f4f7;display:inline-flex;gap:5px;align-items:center;color:#2b2b30;white-space:nowrap}
.key{font-size:9px;font-weight:700;color:#8a8a90;background:#fff;border:1px solid #d9d9de;border-radius:3px;padding:0 3.5px;line-height:13px}
.inspector{flex:0 0 296px;background:#f7f7fa;border-left:1px solid #e0e0e4;display:flex;flex-direction:column;min-height:0}
.segc{display:flex;background:#e4e4e9;border-radius:7px;padding:2px;margin:12px 12px 0;flex:0 0 auto}
.segi{flex:1;text-align:center;font-size:11px;font-weight:500;padding:4px 0;border-radius:5px;color:#55555c}
.segi-on{background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.14);color:#1d1d1f;font-weight:600}
.ipan{flex:1;min-height:0;overflow:hidden;padding:12px;display:flex;flex-direction:column;gap:10px}
.grp{background:#fff;border:1px solid #e6e6ea;border-radius:9px;padding:10px 12px;display:flex;flex-direction:column;gap:8px}
.glabel{font-size:9.5px;font-weight:600;letter-spacing:.07em;color:#8c8c92;text-transform:uppercase}
.stg{display:flex;align-items:center;gap:8px;font-size:12px;color:#2b2b30}
.stgmeta{margin-left:auto;font-size:10px;color:#a0a0a6;font-family:ui-monospace,"SF Mono",Menlo,monospace}
.minisegc{display:flex;background:#ececf0;border-radius:6px;padding:2px}
.minisegi{flex:1;text-align:center;font-size:10.5px;font-weight:500;padding:3px 0;border-radius:4px;color:#55555c}
.minisegi-on{background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.12);color:#1d1d1f;font-weight:600}
.crow{display:flex;align-items:center;gap:8px;font-size:12px}
.hint{font-size:10.5px;color:#98989e;line-height:1.45}
.card{background:#fff;border:1px solid #e2e2e7;border-radius:11px;box-shadow:0 1px 3px rgba(0,0,0,.05)}
"""

# ------------------------------------------------------------------ icons ----
def svg(size, inner, vb=16):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 {vb} {vb}" '
            f'fill="none" xmlns="http://www.w3.org/2000/svg" style="flex:0 0 auto">{inner}</svg>')

def i_check(size=13, color=GREEN):
    return svg(size, f'<path d="M3 8.5 6.4 12 13 4.5" stroke="{color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')
def i_checkc(size=14, color=GREEN):
    return svg(size, f'<circle cx="8" cy="8" r="6.6" fill="{color}"/><path d="M5.2 8.3 7.2 10.3 10.9 5.9" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>')
def i_xc(size=14, color=RED):
    return svg(size, f'<circle cx="8" cy="8" r="6.6" fill="{color}"/><path d="M5.7 5.7 10.3 10.3M10.3 5.7 5.7 10.3" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/>')
def i_warn(size=14):
    return svg(size, f'<path d="M8 2 14.5 13.2H1.5Z" fill="{ORANGE}"/><path d="M8 6.2v3.2" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.4" r=".9" fill="#fff"/>')
def i_dot(size=9, color=ACC):
    return svg(size, f'<circle cx="8" cy="8" r="6" fill="{color}"/>')
def i_ring(size=13, color="#b9b9c0"):
    return svg(size, f'<circle cx="8" cy="8" r="6" stroke="{color}" stroke-width="1.8" stroke-dasharray="2.6 2.9"/>')
def i_spin(size=13, color=ACC):
    return svg(size, f'<circle cx="8" cy="8" r="6" stroke="#dcdce2" stroke-width="2.2"/><path d="M8 2a6 6 0 0 1 5.6 3.9" stroke="{color}" stroke-width="2.2" stroke-linecap="round"/>')
def i_pend(size=13):
    return svg(size, '<circle cx="8" cy="8" r="6" stroke="#d4d4da" stroke-width="1.8"/>')
def i_pencil(size=12, color=ORANGE):
    return svg(size, f'<path d="M2.5 13.5 3 10.8 10.9 2.9a1.4 1.4 0 0 1 2 0l.2.2a1.4 1.4 0 0 1 0 2L5.2 13z" fill="{color}"/>')
def i_search(size=13, color="#8a8a90"):
    return svg(size, f'<circle cx="7" cy="7" r="4.4" stroke="{color}" stroke-width="1.7"/><path d="m10.4 10.4 3.2 3.2" stroke="{color}" stroke-width="1.7" stroke-linecap="round"/>')
def i_play(size=14, color="#fff"):
    return svg(size, f'<path d="M4.5 2.8v10.4L13 8Z" fill="{color}"/>')
def i_pause(size=14, color="#fff"):
    return svg(size, f'<rect x="4" y="3" width="2.6" height="10" rx="1" fill="{color}"/><rect x="9.4" y="3" width="2.6" height="10" rx="1" fill="{color}"/>')
def i_sidebar(size=16, color="#5c5c63"):
    return svg(size, f'<rect x="1.8" y="3" width="12.4" height="10" rx="2" stroke="{color}" stroke-width="1.5"/><path d="M6.3 3v10" stroke="{color}" stroke-width="1.5"/>')
def i_inspect(size=16, color="#5c5c63"):
    return svg(size, f'<rect x="1.8" y="3" width="12.4" height="10" rx="2" stroke="{color}" stroke-width="1.5"/><path d="M9.7 3v10" stroke="{color}" stroke-width="1.5"/>')
def i_refresh(size=13, color="#3d3d44"):
    return svg(size, f'<path d="M13 8a5 5 0 1 1-1.5-3.6" stroke="{color}" stroke-width="1.7" stroke-linecap="round"/><path d="M11.6 1.6v2.9h-2.9" stroke="{color}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>')
def i_export(size=13, color="currentColor"):
    return svg(size, f'<path d="M8 10V2.6M5 5.2 8 2.2l3 3" stroke="{color}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/><path d="M2.8 10.4v1.8a1.4 1.4 0 0 0 1.4 1.4h7.6a1.4 1.4 0 0 0 1.4-1.4v-1.8" stroke="{color}" stroke-width="1.7" stroke-linecap="round"/>')
def i_person(size=12, color="#6e6e73"):
    return svg(size, f'<circle cx="8" cy="5.2" r="2.8" stroke="{color}" stroke-width="1.6"/><path d="M2.8 13.6a5.4 5.4 0 0 1 10.4 0" stroke="{color}" stroke-width="1.6" stroke-linecap="round"/>')
def i_linkoff(size=12, color="#a0a0a6"):
    return svg(size, f'<path d="M6.4 9.6 9.6 6.4" stroke="{color}" stroke-width="1.5" stroke-linecap="round"/><path d="M7.3 4.5 8.6 3.2a2.6 2.6 0 0 1 3.7 3.7L11 8.2M8.7 11.5 7.4 12.8a2.6 2.6 0 0 1-3.7-3.7l1.3-1.3" stroke="{color}" stroke-width="1.5" stroke-linecap="round"/><path d="m2.5 2.5 11 11" stroke="{color}" stroke-width="1.5" stroke-linecap="round"/>')
def i_queue(size=13, color="#8a8a90"):
    return svg(size, f'<circle cx="8" cy="8" r="6" stroke="{color}" stroke-width="1.6"/><path d="M8 4.8V8l2.2 1.6" stroke="{color}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>')
def i_note(size=14, color="rgba(255,255,255,.9)"):
    return svg(size, f'<path d="M6 12.2V3.4l6-1.2v8.6" stroke="{color}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="4.4" cy="12.3" r="1.8" fill="{color}"/><circle cx="10.4" cy="10.9" r="1.8" fill="{color}"/>')
def i_zoom(minus=False, size=13, color="#5c5c63"):
    line = '<path d="M5 7h4" stroke-linecap="round"/>' if minus else '<path d="M5 7h4M7 5v4" stroke-linecap="round"/>'
    return svg(size, f'<g stroke="{color}" stroke-width="1.6"><circle cx="7" cy="7" r="4.4"/><path d="m10.4 10.4 3.2 3.2" stroke-linecap="round"/>{line}</g>')
def i_follow(size=12, color="#fff"):
    return svg(size, f'<circle cx="8" cy="8" r="4.6" stroke="{color}" stroke-width="1.5"/><circle cx="8" cy="8" r="1.4" fill="{color}"/><path d="M8 1.4v2.2M8 12.4v2.2M1.4 8h2.2M12.4 8h2.2" stroke="{color}" stroke-width="1.5" stroke-linecap="round"/>')
def i_apple(size=12, color="#fff"):
    return svg(size, f'<path d="M11.1 8.5c0-1.7 1.4-2.5 1.4-2.5A3.5 3.5 0 0 0 9.8 4.7c-1.1-.1-2.1.6-2.7.6-.6 0-1.5-.6-2.4-.6A3.6 3.6 0 0 0 1.7 6.5c-1.3 2.2-.3 5.5.9 7.3.6.9 1.3 1.9 2.3 1.8.9 0 1.3-.6 2.4-.6s1.4.6 2.4.6 1.6-.9 2.2-1.8a8 8 0 0 0 1-2.1 3.2 3.2 0 0 1-1.8-3.2ZM9.4 3.2A3.2 3.2 0 0 0 10.2 1a3.3 3.3 0 0 0-2.1 1.1 3 3 0 0 0-.8 2.2 2.7 2.7 0 0 0 2.1-1.1Z" fill="{color}" transform="scale(.95) translate(.4 .2)"/>')

# ------------------------------------------------------------- components ----
def toolbar(title, subtitle_html, right_html, active_win=True):
    lights = "".join(f'<span class="light" style="background:{c};border:.5px solid rgba(0,0,0,.12)"></span>'
                     for c in ("#ff5f57", "#febc2e", "#28c840"))
    return f'''<div class="toolbar">
  <div class="lights">{lights}</div>
  <div class="tbtn">{i_sidebar()}</div>
  <div style="display:flex;flex-direction:column;gap:1px;min-width:0">
    <div style="font-size:13px;font-weight:600;line-height:1.2">{title}</div>
    <div style="font-size:10.5px;color:{SUB};line-height:1.2;display:flex;align-items:center;gap:5px">{subtitle_html}</div>
  </div>
  <div style="flex:1"></div>
  {right_html}
  <div class="tbtn">{i_inspect()}</div>
</div>'''

def thumb(hue, hue2):
    return (f'<div class="thumb" style="background:linear-gradient(135deg,hsl({hue} 42% 62%),hsl({hue2} 48% 44%))">{i_note()}</div>')

STATUS_ICON = {
    "exported": lambda: i_checkc(14),
    "edited":   lambda: svg(14, f'<circle cx="8" cy="8" r="6.6" fill="{ORANGE}"/><path d="M4.9 11.2l.4-1.7 4.6-4.6a1 1 0 0 1 1.4 0l0 0a1 1 0 0 1 0 1.4l-4.6 4.6z" fill="#fff"/>'),
    "analyzed": lambda: i_dot(10, ACC),
    "new":      lambda: i_ring(13),
    "queued":   lambda: i_queue(13),
    "running":  lambda: i_spin(13),
    "nolink":   lambda: i_linkoff(13),
}

def song_row(name, artist, status, hues, selected=False, sub_override=None):
    sel = ' style="background:#0a6cf5"' if selected else ""
    name_c = "#fff" if selected else INK
    art_c = "rgba(255,255,255,.75)" if selected else "#86868c"
    dim = ' opacity:.55;' if status == "nolink" else ""
    sub = sub_override or artist
    icon = STATUS_ICON[status]()
    if selected and status == "edited":
        icon = svg(14, f'<circle cx="8" cy="8" r="6.6" fill="#fff"/><path d="M4.9 11.2l.4-1.7 4.6-4.6a1 1 0 0 1 1.4 0l0 0a1 1 0 0 1 0 1.4l-4.6 4.6z" fill="{ORANGE}"/>')
    return f'''<div class="srow"{sel}>
    {thumb(*hues)}
    <div style="flex:1;min-width:0;{dim}">
      <div class="sname" style="color:{name_c}">{name}</div>
      <div class="sartist" style="color:{art_c}">{sub}</div>
    </div>
    {icon}
  </div>'''

def sidebar(rows_html, footer_rows, chips):
    chips_html = "".join(
        f'<span class="chip{" chip-on" if on else ""}">{label}<span style="opacity:.65">{n}</span></span>'
        for label, n, on in chips)
    foot = "".join(f'<div class="frow">{icon}<span style="min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{text}</span>{extra}</div>'
                   for icon, text, extra in footer_rows)
    return f'''<div class="sidebar">
  <div class="search">{i_search()}<span>Search songs</span></div>
  <div class="scope">{chips_html}</div>
  <div class="slist">{rows_html}</div>
  <div class="sfoot">{foot}</div>
</div>'''

SONGS_MAIN = [
    ("Golden Hour", "Mara Quinn", "edited", (28, 16), True, None),
    ("Paper Lanterns", "The Hollow Suns", "exported", (205, 228), False, None),
    ("Undertow", "Vale", "exported", (168, 185), False, None),
    ("Midnight Parade", "Junie West", "analyzed", (262, 280), False, None),
    ("Salt &amp; Cedar", "Field Notes", "analyzed", (95, 120), False, None),
    ("Wintering", "Aya Rowe", "new", (200, 218), False, None),
    ("Second Story", "The Hollow Suns", "new", (330, 350), False, None),
    ("Glasshouse", "Vale", "new", (180, 200), False, None),
    ("Meridian", "No YouTube link", "nolink", (0, 0), False, None),
    ("Ninety-Nine", "Junie West", "new", (48, 30), False, None),
]

def sidebar_rows(songs):
    return "".join(song_row(n, a, st, h, sel, sub) for n, a, st, h, sel, sub in songs)

CHIPS = [("All", "42", True), ("New", "14", False), ("Analysed", "3", False),
         ("Edited", "6", False), ("Exported", "19", False)]

FOOTER_OK = [
    (i_dot(8, GREEN), f'<span style="font-weight:500;color:#3d3d44">Backend</span>&nbsp;<span class="mono" style="font-size:10px">localhost:5051</span>', ""),
    (i_check(11, GREEN), 'Tools OK <span style="opacity:.7">· yt-dlp · ffmpeg · deno</span>', ""),
    (i_person(), 'you@example.com', f'<span style="margin-left:auto;color:{ACC};font-weight:500">Sign out</span>'),
]

# --------------------------------------------------------------- waveform ----
SECTIONS = [("Intro", 4, "#98989e"), ("Verse A", 16, ACC), ("Chorus", 16, "#9d4fd6"),
            ("Verse B", 16, ACC), ("Chorus", 16, "#9d4fd6"), ("Bridge", 8, ORANGE), ("Outro", 8, "#98989e")]
TOTAL_BARS = 84

def waveform_svg(width=880, playhead_frac=0.107):
    parts = [f'<svg width="{width}" height="132" viewBox="0 0 {width} 132" xmlns="http://www.w3.org/2000/svg" style="display:block">']
    # section band
    x = 0.0
    for name, bars, color in SECTIONS:
        w = bars / TOTAL_BARS * width
        parts.append(f'<rect x="{x:.1f}" y="0" width="{w-1:.1f}" height="15" rx="2" fill="{color}" opacity=".85"/>')
        if w > 34:
            parts.append(f'<text x="{x+6:.1f}" y="11" font-size="9" font-weight="600" fill="#fff" font-family="-apple-system,sans-serif">{name}</text>')
        x += w
    # bar gridlines every 4 bars
    for b in range(0, TOTAL_BARS + 1, 4):
        gx = b / TOTAL_BARS * width
        strong = (b % 16 == 0)
        parts.append(f'<line x1="{gx:.1f}" y1="18" x2="{gx:.1f}" y2="112" stroke="{"#e2e2e8" if strong else "#efeff3"}" stroke-width="1"/>')
        if strong and b < TOTAL_BARS:
            parts.append(f'<text x="{gx+4:.1f}" y="27" font-size="8.5" fill="#b4b4ba" font-family="ui-monospace,Menlo,monospace">{b+1}</text>')
    # wave
    parts.append(f'<g transform="translate(0,27)"><path d="{WAVE_MAIN}" stroke="#79aef2" stroke-width="1.3"/></g>')
    # chord lane
    lane = [("C",4),("Am",3),("F",5),("G",4),("C",5),("Am",4),("F",4),("G",3),("F",5),("C",4),("G",4),("Am",5),("C",4),("F",5),("G",4),("C",5),("Am",4),("F",4),("G",4),("C",4),("F",5),("G",3)]
    total_u = sum(u for _, u in lane)
    x = 0.0
    for k, (ch, u) in enumerate(lane):
        w = u / total_u * width
        fill = "rgba(10,108,245,.08)" if k % 2 == 0 else "rgba(48,179,80,.10)"
        parts.append(f'<rect x="{x:.1f}" y="113" width="{w:.1f}" height="19" fill="{fill}"/>')
        parts.append(f'<line x1="{x:.1f}" y1="113" x2="{x:.1f}" y2="132" stroke="rgba(0,0,0,.10)" stroke-width="1"/>')
        parts.append(f'<text x="{x+4:.1f}" y="126" font-size="8.5" font-weight="600" fill="#6a6a71" font-family="-apple-system,sans-serif">{ch}</text>')
        x += w
    # playhead
    px = playhead_frac * width
    parts.append(f'<line x1="{px:.1f}" y1="15" x2="{px:.1f}" y2="132" stroke="{RED}" stroke-width="2"/>')
    parts.append(f'<path d="M{px-5:.1f} 15h10l-5 7z" fill="{RED}"/>')
    parts.append('</svg>')
    return "".join(parts)

def transport(playing=False, time_str='0:15.8&nbsp;/&nbsp;2:28.4', stats=None, right=None):
    stats = stats if stats is not None else [
        '136.4 BPM <span style="color:#98989e;font-weight:400">detected</span>', '4/4', '84 bars', '7 sections']
    stats_html = "".join(f'<span class="stat">{s}</span>' for s in stats)
    right = right if right is not None else f'''
    <div style="display:flex;align-items:center;gap:6px">
      <span class="tbtn" style="width:26px;height:24px">{i_zoom(minus=True)}</span>
      <span style="font-size:11px;color:{SUB};width:26px;text-align:center">Fit</span>
      <span class="tbtn" style="width:26px;height:24px">{i_zoom()}</span>
      <span class="pill" style="background:{ACC};color:#fff;margin-left:6px">{i_follow()}Follow</span>
    </div>'''
    icon = i_pause() if playing else i_play()
    return f'''<div class="transport">
  <div style="width:30px;height:30px;border-radius:50%;background:{ACC};display:flex;align-items:center;justify-content:center">{icon}</div>
  <span class="mono" style="font-size:12px;color:#3d3d44">{time_str}</span>
  <div style="width:1px;height:20px;background:#e6e6ea;margin:0 2px"></div>
  {stats_html}
  <div style="flex:1"></div>
  {right}
</div>'''

# ------------------------------------------------------------------ chart ----
def bar_cell(num, segs, state=""):
    cls = "bar" + (" " + state if state else "")
    seg_html = "".join(
        f'<div class="seg" style="flex-grow:{units}">{chord}</div>' for chord, units in segs)
    return f'<div class="{cls}"><span class="barno">{num}</span>{seg_html}</div>'

def chart_section(name, meta, color, rows_html):
    return f'''<div style="display:flex;flex-direction:column;gap:8px">
  <div class="sechead"><span style="width:9px;height:9px;border-radius:3px;background:{color};align-self:center"></span>
    <span class="secname">{name}</span><span class="secmeta">{meta}</span></div>
  {rows_html}
</div>'''

def rows(bars):
    out = []
    for r in range(0, len(bars), 4):
        chunk = bars[r:r+4]
        cells = "".join(bar_cell(*b) for b in chunk)
        cells += '<div style="flex:1;visibility:hidden"></div>' * (4 - len(chunk))
        out.append(f'<div class="brow">{cells}</div>')
    return "".join(out)

VERSE_A_BARS = [
    (5, [("C", 1)]), (6, [("Am", 1)]), (7, [("F", 1)]), (8, [("F", 1), ("G", 1)]),
    (9, [("C", 1)]), (10, [("Am", 1)], "bar-act"), (11, [("F", 1)]), (12, [("G", 1)]),
    (13, [("C", 1)]), (14, [("C", 3), ("C/E", 1)], "bar-sel"), (15, [("F", 1)]), (16, [("G", 1)]),
    (17, [("Am", 1)]), (18, [("G", 1)]), (19, [("F", 1)]), (20, [("G", 1), ("G/B", 1)]),
]
INTRO_BARS = [(1, [("C", 1)]), (2, [("C", 1)]), (3, [("F", 1)]), (4, [("G", 1)])]
CHORUS_BARS = [(21, [("F", 1)]), (22, [("C", 1)]), (23, [("G", 1)]), (24, [("Am", 1)])]

def popover():
    return f'''<div class="pop" style="left:255px;top:328px">
  <span class="popbtn">Split here <span class="key">S</span></span>
  <span class="popbtn">Merge with previous <span class="key">M</span></span>
  <span class="popbtn">Rename <span class="key">R</span></span>
  <div style="width:1px;height:16px;background:#e4e4e9"></div>
  <span style="font-size:10px;color:{FAINT};padding-left:2px">Subdivide</span>
  <div class="minisegc" style="width:168px">
    <span class="minisegi minisegi-on">1</span><span class="minisegi">1/2</span><span class="minisegi">1/4</span><span class="minisegi">1/8</span><span class="minisegi">1/16</span>
  </div>
</div>'''

def chart_main():
    return f'''<div class="chart">
  {chart_section("Intro", "Bars 1–4", "#98989e", rows(INTRO_BARS))}
  {chart_section("Verse A", "Bars 5–20 · repeats ×2", ACC, rows(VERSE_A_BARS))}
  {popover()}
  {chart_section("Chorus", "Bars 21–36 · repeats ×2", "#9d4fd6", rows(CHORUS_BARS))}
</div>'''

# -------------------------------------------------------------- inspector ----
def inspector(active, panel_html):
    tabs = "".join(
        f'<span class="segi{" segi-on" if t == active else ""}">{t}</span>'
        for t in ("Bar", "Tuning", "Analysis", "Info"))
    return f'<div class="inspector"><div class="segc">{tabs}</div><div class="ipan">{panel_html}</div></div>'

def chord_row(chord, secs, frac):
    return f'''<div class="crow">
    <span style="font-weight:600;width:38px">{chord}</span>
    <div style="flex:1;height:7px;border-radius:3.5px;background:#eeeef2;overflow:hidden">
      <div style="width:{frac}%;height:7px;border-radius:3.5px;background:{ACC};opacity:.8"></div>
    </div>
    <span class="mono" style="font-size:10.5px;color:{SUB}">{secs}s</span>
  </div>'''

PANEL_BAR = f'''
<div class="grp">
  <div style="display:flex;align-items:baseline;gap:8px">
    <span style="font-size:15px;font-weight:700">Bar 14</span>
    <span class="mono" style="font-size:10.5px;color:{SUB}">0:22.9 – 0:24.6</span>
  </div>
  <div style="display:flex;align-items:center;gap:6px;font-size:11px;color:{SUB}">
    <span style="width:8px;height:8px;border-radius:2.5px;background:{ACC}"></span>Verse A · bar 10 of 16
  </div>
</div>
<div class="grp">
  <div class="glabel">Detected chords</div>
  {chord_row("C", "1.32", 75)}
  {chord_row("C/E", "0.44", 25)}
  <div class="hint">Chords come from the analysis model — correct timing with Tuning, not by editing chords.</div>
</div>
<div class="grp">
  <div class="glabel">Subdivide this bar</div>
  <div class="minisegc"><span class="minisegi minisegi-on">1</span><span class="minisegi">1/2</span><span class="minisegi">1/4</span><span class="minisegi">1/8</span><span class="minisegi">1/16</span></div>
  <div class="hint">Also used when exporting this bar to TheStageBee.</div>
</div>
<div class="grp">
  <div class="glabel">Section</div>
  <span class="btn btn-sm" style="justify-content:space-between">Split “Verse A” at this bar <span class="key">S</span></span>
  <span class="btn btn-sm" style="justify-content:space-between">Merge with previous section <span class="key">M</span></span>
  <span class="btn btn-sm" style="justify-content:space-between">Rename “Verse A” <span class="key">R</span></span>
</div>
<div class="hint" style="padding:0 2px">Shortcuts work while a bar is selected. Click a chord to move the playhead there.</div>
'''

def stage(icon, label, meta="", note=""):
    n = f'<div style="display:flex;gap:8px;font-size:10.5px;color:{ORANGE};padding-left:21px;line-height:1.4">{note}</div>' if note else ""
    return f'<div class="stg">{icon}<span>{label}</span><span class="stgmeta">{meta}</span></div>{n}'

PANEL_ANALYSIS = f'''
<div class="grp" style="gap:9px">
  <div class="glabel">Pipeline — Golden Hour</div>
  {stage(i_checkc(13), "Tools check", "0.2s")}
  {stage(i_checkc(13), "Download audio", "0:12")}
  {stage(i_checkc(13), "Convert to WAV", "0:03")}
  {stage(i_checkc(13), "Read metadata", "0.4s")}
  {stage(i_warn(13), "Audio health", "0.9s", "Very quiet audio (−38 dB mean) — chords may be less reliable")}
  {stage(i_checkc(13), "Backend check", "0.1s")}
  {stage(i_spin(13), '<span style="font-weight:600">Detect beats</span>', "0:42…")}
  {stage(i_pend(13), '<span style="color:#a0a0a6">Beat grid</span>')}
  {stage(i_pend(13), '<span style="color:#a0a0a6">Recognise chords</span>')}
  {stage(i_pend(13), '<span style="color:#a0a0a6">Build chart</span>')}
  {stage(i_pend(13), '<span style="color:#a0a0a6">Detect sections</span>')}
</div>
<div class="grp">
  <div style="display:flex;align-items:center;justify-content:space-between">
    <span class="glabel" style="text-transform:none;font-size:11px;letter-spacing:0">Log</span>
    <span style="font-size:10.5px;color:{ACC};font-weight:500">Show ▸</span>
  </div>
  <div class="hint">Full yt-dlp / ffmpeg / backend output, per stage.</div>
</div>
<div style="flex:1"></div>
<span class="btn" style="justify-content:center;color:{RED}">Cancel analysis</span>
<div class="hint" style="text-align:center">Keeps everything already downloaded.</div>
'''

PANEL_TUNING = f'''
<div class="grp">
  <div class="glabel">Tempo</div>
  <div class="crow"><span style="color:{SUB};width:64px">Detected</span><span class="mono" style="font-weight:600">136.4 BPM</span></div>
  <div class="crow"><span style="color:{SUB};width:64px">Override</span>
    <span class="mono" style="flex:1;height:22px;border:1px solid #d4d4da;border-radius:5px;background:#fff;display:flex;align-items:center;padding:0 8px;font-size:11.5px;color:#b0b0b6">136.4</span>
    <span style="font-size:10.5px;color:{FAINT}">↩ to set</span></div>
  <div class="crow" style="justify-content:space-between"><span>Halve tempo <span style="color:{FAINT};font-size:10.5px">double-time fix</span></span>
    <span style="width:30px;height:18px;border-radius:9px;background:#d9d9de;position:relative"><span style="position:absolute;left:2px;top:2px;width:14px;height:14px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25)"></span></span></div>
</div>
<div class="grp">
  <div class="glabel">Bars</div>
  <div class="crow" style="justify-content:space-between"><span>Pickup beats</span>
    <div class="minisegc" style="width:118px"><span class="minisegi">0</span><span class="minisegi">1</span><span class="minisegi minisegi-on">2</span><span class="minisegi">3</span></div></div>
  <div class="crow" style="justify-content:space-between"><span>Beats per bar</span>
    <div class="minisegc" style="width:118px"><span class="minisegi">2</span><span class="minisegi">3</span><span class="minisegi minisegi-on">4</span></div></div>
  <div class="hint">Changes preview instantly in the chart — nothing is recomputed until you apply.</div>
</div>
<div class="grp">
  <div class="glabel">Re-detect beats</div>
  <div class="crow"><span style="width:14px;height:14px;border-radius:3.5px;background:{ACC};display:inline-flex;align-items:center;justify-content:center">{i_check(9, "#fff")}</span>Constrain BPM range</div>
  <div class="crow" style="padding-left:22px;color:{SUB}">Seed <span class="mono" style="border:1px solid #d4d4da;border-radius:5px;background:#fff;padding:1px 7px;font-size:11.5px;color:{INK}">136</span> → 109–164</div>
  <div class="crow"><span style="width:14px;height:14px;border-radius:3.5px;border:1.5px solid #c4c4ca;background:#fff"></span>Stable tempo <span style="color:{FAINT};font-size:10.5px">resists drift</span></div>
  <span class="btn btn-sm" style="justify-content:center;margin-top:2px">{i_refresh(11)} Re-detect beats &amp; tempo</span>
</div>
'''

# ------------------------------------------------------------- artboards -----
def dc(body, extra_css=""):
    return f'''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>{CSS}{extra_css}</style>
</helmet>
{body}
</x-dc>
</body>
</html>
'''

def toolbar_main():
    right = f'''<span class="btn">{i_refresh()} Re-analyse</span>
  <span class="pill" style="background:rgba(245,147,0,.14);color:#9a5f00">{i_pencil(11)} Edited since last export</span>
  <span class="btn btn-primary">{i_export()} Export to TheStageBee…</span>'''
    return toolbar("Golden Hour", 'Mara Quinn · 2:28 · analysed today 14:02', right)

MAIN_BODY = f'''<div class="win">
  {toolbar_main()}
  <div class="body">
    {sidebar(sidebar_rows(SONGS_MAIN), FOOTER_OK, CHIPS)}
    <div class="main">
      {transport()}
      <div class="waveblock">{waveform_svg()}</div>
      {chart_main()}
    </div>
    {inspector("Bar", PANEL_BAR)}
  </div>
</div>'''

# --- Analyzing ---
SONGS_ANALYZING = [
    ("Golden Hour", "", "running", (28, 16), True, '<span style="color:rgba(255,255,255,.85)">Detecting beats · stage 7 of 11</span>'),
    ("Paper Lanterns", "", "queued", (205, 228), False, "Queued · next"),
    ("Undertow", "", "queued", (168, 185), False, "Queued"),
    ("Midnight Parade", "Junie West", "analyzed", (262, 280), False, None),
    ("Salt &amp; Cedar", "Field Notes", "analyzed", (95, 120), False, None),
    ("Wintering", "Aya Rowe", "new", (200, 218), False, None),
    ("Second Story", "The Hollow Suns", "new", (330, 350), False, None),
    ("Glasshouse", "Vale", "new", (180, 200), False, None),
    ("Meridian", "No YouTube link", "nolink", (0, 0), False, None),
    ("Ninety-Nine", "Junie West", "new", (48, 30), False, None),
]

def toolbar_analyzing():
    right = f'''<span class="pill" style="background:rgba(10,108,245,.12);color:#0a5fd0">{i_queue(12,"#0a5fd0")} 2 queued</span>
  <span class="btn" style="color:{RED}">Cancel</span>'''
    return toolbar("Golden Hour", f'{i_spin(11)} <span>Detecting beats — 0:42 elapsed</span>', right)

def skeleton_bar():
    return '<div class="bar" style="background:#f2f2f5;border-color:#ebebef"><div class="seg" style="background:#ececf0;border-color:#ececf0"></div></div>'

SKELETON_CHART = f'''<div class="chart">
  <div style="display:flex;flex-direction:column;gap:8px;opacity:.6">
    <div style="width:120px;height:13px;border-radius:6.5px;background:#ececf0"></div>
    <div class="brow">{skeleton_bar()*4}</div>
    <div class="brow">{skeleton_bar()*4}</div>
  </div>
  <div style="display:flex;flex-direction:column;gap:8px;opacity:.35">
    <div style="width:160px;height:13px;border-radius:6.5px;background:#ececf0"></div>
    <div class="brow">{skeleton_bar()*4}</div>
  </div>
  <div style="text-align:center;font-size:11.5px;color:{FAINT};padding-top:6px">
    The chart fills in as analysis completes — the layout never jumps around.
  </div>
</div>'''

ANALYZING_WAVE = f'''<div class="waveblock" style="display:flex;align-items:center;justify-content:center">
  <div style="display:flex;flex-direction:column;gap:8px;width:420px">
    <div style="display:flex;justify-content:space-between;font-size:11.5px;color:{SUB}">
      <span style="font-weight:500;color:{INK}">Audio ready — waiting on beat analysis</span>
      <span class="mono" style="font-size:10.5px">analysis.wav · 25.1 MB</span>
    </div>
    <div style="height:5px;border-radius:2.5px;background:#e8e8ec;overflow:hidden">
      <div style="width:58%;height:5px;background:{ACC};border-radius:2.5px"></div>
    </div>
    <div style="font-size:10.5px;color:{FAINT}">Stages 1–6 done · beat detection running on localhost:5051</div>
  </div>
</div>'''

ANALYZING_BODY = f'''<div class="win">
  {toolbar_analyzing()}
  <div class="body">
    {sidebar(sidebar_rows(SONGS_ANALYZING), FOOTER_OK, CHIPS)}
    <div class="main">
      {transport(time_str='–:–&nbsp;/&nbsp;2:28.4', stats=['<span style="color:#98989e">BPM pending</span>', '2:28.4 audio'], right='<span></span>')}
      {ANALYZING_WAVE}
      {SKELETON_CHART}
    </div>
    {inspector("Analysis", PANEL_ANALYSIS)}
  </div>
</div>'''

# --- BeatTuning ---
def mini_strip(n, selected=False, caption=""):
    bar_w, beat_w = 68.6, 17.15
    xs = []
    for k in range(13):
        x = k * bar_w + n * beat_w
        if x <= 780:
            xs.append(x)
    lines = "".join(
        f'<line x1="{x:.1f}" y1="0" x2="{x:.1f}" y2="34" stroke="{ACC if selected else "#9c9ca4"}" stroke-width="1.4" opacity="{.7 if selected else .5}"/>'
        for x in xs)
    border = f'1.5px solid {ACC}' if selected else '1px solid #e2e2e7'
    ring = f'<span style="width:14px;height:14px;border-radius:50%;background:{ACC};display:inline-flex;align-items:center;justify-content:center;flex:0 0 14px">{i_check(9,"#fff")}</span>' if selected \
        else '<span style="width:14px;height:14px;border-radius:50%;border:1.5px solid #c0c0c6;background:#fff;flex:0 0 14px"></span>'
    cap_color = GREEN_SYS if selected else FAINT
    cap = f'<span style="font-size:10.5px;color:{cap_color};font-weight:{500 if selected else 400};flex:1;text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{caption}</span>'
    bg = 'rgba(10,108,245,.05)' if selected else '#fbfbfd'
    return f'''<div style="display:flex;align-items:center;gap:10px;border:{border};border-radius:8px;padding:6px 10px;background:{bg}{';box-shadow:0 0 0 3px rgba(10,108,245,.12)' if selected else ''}">
    {ring}<span style="font-size:12px;font-weight:600;width:60px;flex:0 0 60px">Pickup {n}</span>
    <svg width="780" height="34" viewBox="0 0 780 34" xmlns="http://www.w3.org/2000/svg" style="width:512px;flex:0 0 512px">
      <path d="{WAVE_MINI}" stroke="#a9c8f0" stroke-width="1.1"/>{lines}
    </svg>{cap}
  </div>'''

def toolbar_tuning():
    right = f'''<span class="pill" style="background:rgba(10,108,245,.12);color:#0a5fd0">Previewing — not applied</span>
  <span class="btn">Revert <span class="key">esc</span></span>
  <span class="btn btn-primary">Apply <span class="key" style="border-color:rgba(255,255,255,.5);color:#fff;background:transparent">⏎</span></span>'''
    return toolbar("Golden Hour", 'Mara Quinn · adjusting beats &amp; bars', right)

VERSE_PREVIEW = [
    (5, [("C", 1)]), (6, [("Am", 1)]), (7, [("F", 1)]), (8, [("F", 1)], "bar-chg"),
    (9, [("C", 1)]), (10, [("Am", 1)], "bar-act"), (11, [("F", 3), ("F/A", 1)], "bar-chg"), (12, [("G", 1)]),
]

TUNING_CHART = f'''<div class="chart" style="gap:10px">
  <div class="card" style="padding:12px 14px;display:flex;flex-direction:column;gap:8px">
    <div style="display:flex;align-items:baseline;gap:8px">
      <span style="font-size:13px;font-weight:600">Where does bar 1 start?</span>
      <span style="font-size:10.5px;color:{FAINT}">bar lines drawn over the first 20 seconds — pick the one that lands on the downbeats</span>
    </div>
    {mini_strip(0, caption="early by 2 beats")}
    {mini_strip(1)}
    {mini_strip(2, selected=True, caption="bar lines land on the accents")}
    {mini_strip(3)}
  </div>
  {chart_section("Verse A <span style='font-size:10px;font-weight:500;color:#0a5fd0;background:rgba(10,108,245,.1);border-radius:4px;padding:1px 6px;vertical-align:1px'>live preview</span>", "Bars 5–20 · <span style='color:#0a5fd0'>2 bars differ from the current chart</span> (dashed)", ACC, rows(VERSE_PREVIEW))}
</div>'''

TUNING_BODY = f'''<div class="win">
  {toolbar_tuning()}
  <div class="body">
    {sidebar(sidebar_rows(SONGS_MAIN), FOOTER_OK, CHIPS)}
    <div class="main">
      {transport()}
      <div class="waveblock">{waveform_svg()}</div>
      {TUNING_CHART}
    </div>
    {inspector("Tuning", PANEL_TUNING)}
  </div>
</div>'''

# --- ExportSheet ---
def sec_chip(name, bars):
    return (f'<span style="display:inline-flex;align-items:center;gap:5px;height:22px;padding:0 9px;border-radius:6px;'
            f'background:#f2f2f6;border:1px solid #e6e6ea;font-size:11px;font-weight:500">{name}'
            f'<span style="color:{FAINT};font-weight:400">{bars}</span></span>')

EXPORT_SHEET = f'''<div style="position:absolute;inset:0;background:rgba(30,30,34,.32);z-index:10"></div>
<div class="card" style="position:absolute;left:440px;top:96px;width:560px;z-index:11;box-shadow:0 30px 80px rgba(0,0,0,.35);display:flex;flex-direction:column">
  <div style="padding:18px 22px 14px;display:flex;flex-direction:column;gap:4px">
    <div style="font-size:15px;font-weight:700">Export to TheStageBee</div>
    <div style="font-size:11.5px;color:{SUB}">Updates the existing song document — title, key, artists and links are not touched.</div>
  </div>
  <div style="padding:0 22px 16px;display:flex;flex-direction:column;gap:12px">
    <div style="display:flex;align-items:center;gap:10px;border:1px solid #e6e6ea;border-radius:9px;padding:9px 12px">
      {thumb(28, 16)}
      <div style="flex:1">
        <div style="font-size:12.5px;font-weight:600">Golden Hour</div>
        <div style="font-size:10.5px;color:{SUB}">Mara Quinn</div>
      </div>
      <span class="mono" style="font-size:10px;color:{FAINT}">songs/9fKzR2vXq…</span>
    </div>
    <div style="display:flex;flex-direction:column;gap:10px;border:1px solid #e6e6ea;border-radius:9px;padding:12px">
      <div class="glabel">This will overwrite</div>
      <div style="display:flex;align-items:center;gap:10px;font-size:12px">
        <span style="width:64px;color:{SUB}">Tempo</span>
        <span class="mono" style="color:{FAINT};text-decoration:line-through">132</span>
        <span style="color:{FAINT}">→</span>
        <span class="mono" style="font-weight:700">136</span><span style="color:{SUB};font-size:11px">BPM</span>
      </div>
      <div style="display:flex;gap:10px;font-size:12px">
        <span style="width:64px;color:{SUB};flex:0 0 64px">Sections</span>
        <div style="display:flex;flex-direction:column;gap:7px;min-width:0">
          <div style="font-size:11px;color:{FAINT}">currently 3 — Intro, Verse, Chorus</div>
          <div style="display:flex;flex-wrap:wrap;gap:5px">
            {sec_chip("Intro","4 bars")}{sec_chip("Verse A","16")}{sec_chip("Chorus","16")}{sec_chip("Verse B","16")}{sec_chip("Chorus","16")}{sec_chip("Bridge","8")}{sec_chip("Outro","8")}
          </div>
        </div>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:14px;font-size:11px;color:{SUB}">
      <span style="display:inline-flex;align-items:center;gap:5px">{i_dot(8, GREEN)} Backend reachable</span>
      <span style="display:inline-flex;align-items:center;gap:5px">{i_person(11)} Signed in as you@example.com</span>
    </div>
  </div>
  <div style="border-top:1px solid #ececf0;padding:12px 22px;display:flex;align-items:center;gap:8px;background:#fafafc;border-radius:0 0 11px 11px">
    <span style="font-size:11px;color:{ACC};font-weight:500">Export history…</span>
    <span style="font-size:10.5px;color:{FAINT}">previous values are kept locally</span>
    <div style="flex:1"></div>
    <span class="btn">Cancel</span>
    <span class="btn btn-primary">Overwrite “Golden Hour”</span>
  </div>
</div>'''

EXPORT_BODY = f'''<div class="win">
  {toolbar_main()}
  <div class="body">
    {sidebar(sidebar_rows(SONGS_MAIN), FOOTER_OK, CHIPS)}
    <div class="main">
      {transport()}
      <div class="waveblock">{waveform_svg()}</div>
      <div class="chart">
        {chart_section("Intro", "Bars 1–4", "#98989e", rows(INTRO_BARS))}
        {chart_section("Verse A", "Bars 5–20 · repeats ×2", ACC, rows([(n, s) for n, s, *r in VERSE_A_BARS]))}
      </div>
    </div>
    {inspector("Bar", PANEL_BAR)}
  </div>
  {EXPORT_SHEET}
</div>'''

# --- States ---
def state_card(label, inner):
    return f'''<div style="display:flex;flex-direction:column;gap:8px;min-width:0">
  <div style="font-size:10.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:{FAINT}">{label}</div>
  <div class="card" style="padding:14px 16px;display:flex;flex-direction:column;gap:10px;flex:1">{inner}</div>
</div>'''

CARD_FAIL = f'''
  {stage(i_checkc(13), "Tools check", "0.2s")}
  {stage(i_checkc(13), "Download audio", "0:12")}
  {stage(i_xc(13), '<span style="font-weight:600">Convert to WAV — failed</span>', "0:01")}
  <div class="mono" style="font-size:10.5px;color:{RED};background:rgba(229,55,46,.07);border:1px solid rgba(229,55,46,.2);border-radius:7px;padding:8px 10px;line-height:1.5">ffmpeg: Invalid data found when<br>processing input (audio.original.webm)</div>
  <div style="display:flex;gap:8px">
    <span class="btn btn-sm btn-primary">{i_refresh(11, "#fff")} Retry this stage</span>
    <span class="btn btn-sm">Open log</span>
  </div>
  <div class="hint">The download is kept — retrying never re-does finished stages.</div>'''

CARD_BACKEND = f'''
  <div style="display:flex;align-items:center;gap:8px">
    {i_warn(15)}<span style="font-size:13px;font-weight:600">Audio ready — analysis paused</span>
    <span class="pill" style="background:rgba(229,55,46,.1);color:{RED};margin-left:auto">{i_dot(7, RED)} Backend offline</span>
  </div>
  <div style="font-size:11.5px;color:{SUB};line-height:1.5">Download, conversion and health checks are done. Beat and chord analysis will resume from where it stopped — nothing is re-downloaded.</div>
  <div style="display:flex;gap:8px">
    <span class="btn btn-sm btn-primary">Resume analysis</span>
    <span class="btn btn-sm">{i_refresh(11)} Check backend</span>
  </div>
  <div class="hint mono" style="font-size:10px">GET http://localhost:5051/health → connection refused · start it with ../ChordAdminBackend/start.sh</div>'''

CARD_AUTH = f'''
  <div style="display:flex;align-items:center;gap:8px">
    {i_person(15, "#3d3d44")}<span style="font-size:13px;font-weight:600">Browsing public songs — read-only</span>
  </div>
  <div style="font-size:11.5px;color:{SUB};line-height:1.5">You’re signed out, so only the public catalogue is shown. Analysis still works; exporting to TheStageBee needs a signed-in account with write access.</div>
  <span class="btn btn-sm" style="background:#1d1d1f;border-color:#000;color:#fff;align-self:flex-start">{i_apple(11)} Sign in with Apple</span>
  <div style="display:flex;align-items:center;gap:8px;margin-top:2px">
    <span class="btn btn-sm" style="opacity:.45">{i_export(11)} Export to TheStageBee…</span>
    <span class="hint">the export button says why it’s off, instead of failing later</span>
  </div>'''

def tool_row(name, ok, meta):
    icon = i_checkc(13) if ok else i_xc(13)
    return f'<div class="stg">{icon}<span class="mono" style="font-size:11.5px;font-weight:600">{name}</span><span class="stgmeta">{meta}</span></div>'

CARD_TOOLS = f'''
  <div style="font-size:13px;font-weight:600">Environment check <span style="font-size:10.5px;color:{FAINT};font-weight:400">· runs at launch and before every job</span></div>
  {tool_row("yt-dlp", True, "2025.08.11 · /opt/homebrew/bin")}
  {tool_row("ffmpeg", True, "7.1 · /opt/homebrew/bin")}
  {tool_row("ffprobe", True, "7.1 · /opt/homebrew/bin")}
  {tool_row("deno", False, "not found — needed for YouTube downloads")}
  <div class="mono" style="font-size:10.5px;background:#f4f4f7;border:1px solid #e6e6ea;border-radius:7px;padding:7px 10px">brew install deno</div>
  <span class="btn btn-sm" style="align-self:flex-start">{i_refresh(11)} Check again</span>'''

STATES_BODY = f'''<div style="width:1060px;height:700px;background:#f0f0f3;border-radius:10px;padding:24px 28px;display:flex;flex-direction:column;gap:16px;overflow:hidden;box-sizing:border-box">
  <div>
    <div style="font-size:16px;font-weight:700">When things go wrong</div>
    <div style="font-size:11.5px;color:{SUB};margin-top:2px">Every failure names its stage, keeps finished work, and offers the one action that fixes it — no more green “Completed” badges over missing charts.</div>
  </div>
  <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;flex:1;min-height:0">
    {state_card("Stage failure → retry in place", CARD_FAIL)}
    {state_card("Backend down → resumable, not terminal", CARD_BACKEND)}
    {state_card("Signed out → explicit read-only mode", CARD_AUTH)}
    {state_card("Missing tools → readiness panel", CARD_TOOLS)}
  </div>
</div>'''


# ---------------------------------------------------------- front screen -----
SONGS_FRONT = [(n, a, st, h, False, sub) for n, a, st, h, _sel, sub in SONGS_MAIN]

def toolbar_front():
    return toolbar("ChordAdmin", "TheStageBee library · 42 songs", "")

def continue_card(hues, title, artist, status_html, actions_html):
    return f'''<div class="card" style="flex:1;padding:14px;display:flex;flex-direction:column;gap:10px">
    <div style="display:flex;align-items:center;gap:11px">
      <div class="thumb" style="width:52px;height:52px;flex:0 0 52px;border-radius:8px;background:linear-gradient(135deg,hsl({hues[0]} 42% 62%),hsl({hues[1]} 48% 44%))">{i_note()}</div>
      <div style="flex:1;min-width:0">
        <div style="font-size:13.5px;font-weight:600">{title}</div>
        <div style="font-size:11px;color:{SUB}">{artist}</div>
      </div>
    </div>
    {status_html}
    <div style="display:flex;gap:8px;margin-top:2px">{actions_html}</div>
  </div>'''

def todo_card(hues, title, artist):
    return f'''<div class="card" style="padding:0;overflow:hidden;display:flex;flex-direction:column">
    <div style="height:88px;background:linear-gradient(135deg,hsl({hues[0]} 42% 66%),hsl({hues[1]} 48% 46%));display:flex;align-items:center;justify-content:center">{i_note(20)}</div>
    <div style="padding:9px 11px;display:flex;flex-direction:column;gap:7px">
      <div style="min-width:0">
        <div style="font-size:12px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{title}</div>
        <div style="font-size:10.5px;color:{SUB};white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{artist}</div>
      </div>
      <span class="btn btn-sm" style="justify-content:center">Analyse</span>
    </div>
  </div>'''

def exported_row(hues, title, when):
    return f'''<div style="display:flex;align-items:center;gap:9px">
    <div class="thumb" style="width:28px;height:28px;flex:0 0 28px;border-radius:5px;background:linear-gradient(135deg,hsl({hues[0]} 42% 62%),hsl({hues[1]} 48% 44%))">{i_note(11)}</div>
    <div style="flex:1;min-width:0">
      <div style="font-size:12px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{title}</div>
      <div style="font-size:10px;color:{FAINT}">{when}</div>
    </div>
    {i_checkc(13)}
  </div>'''

CONTINUE_GH = continue_card((28, 16), "Golden Hour", "Mara Quinn",
    f'''<div style="display:flex;align-items:center;gap:6px;font-size:11px;color:#9a5f00">{i_pencil(11)} Edited since last export — 7 sections ready</div>''',
    f'''<span class="btn btn-sm">Open</span><span class="btn btn-sm btn-primary">{i_export(11)} Export to TheStageBee…</span>''')

CONTINUE_MP = continue_card((262, 280), "Midnight Parade", "Junie West",
    f'''<div style="display:flex;align-items:center;gap:6px;font-size:11px;color:#0a5fd0">{i_dot(9, ACC)} Analysed — sections need review</div>''',
    '''<span class="btn btn-sm">Review sections</span>''')

TODO_CARDS = "".join([
    todo_card((200, 218), "Wintering", "Aya Rowe"),
    todo_card((330, 350), "Second Story", "The Hollow Suns"),
    todo_card((180, 200), "Glasshouse", "Vale"),
    todo_card((48, 30), "Ninety-Nine", "Junie West"),
    todo_card((120, 140), "Low Tide", "Field Notes"),
]) + f'''<div style="border:1.5px dashed #d4d4da;border-radius:11px;display:flex;align-items:center;justify-content:center;font-size:11.5px;color:{FAINT}">+ 12 more</div>'''

FRONT_MAIN = f'''<div class="main" style="background:#fafafc">
  <div style="flex:1;min-height:0;overflow:hidden;padding:26px 30px;display:flex;gap:24px">
    <div style="flex:1;min-width:0;display:flex;flex-direction:column;gap:22px">
      <div style="display:flex;flex-direction:column;gap:9px">
        <div class="glabel">Continue</div>
        <div style="display:flex;gap:14px">{CONTINUE_GH}{CONTINUE_MP}</div>
      </div>
      <div style="display:flex;flex-direction:column;gap:9px;min-height:0">
        <div style="display:flex;align-items:center;gap:8px">
          <div class="glabel">New in the library</div>
          <span style="font-size:10.5px;color:{FAINT}">17 songs not yet analysed</span>
          <div style="flex:1"></div>
          <span class="btn btn-sm">{i_queue(11, "#3d3d44")} Analyse all 17</span>
        </div>
        <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px">{TODO_CARDS}</div>
      </div>
      <div style="flex:1"></div>
      <div class="hint">Select a song on the left — or open one above — to see its chart. Analysis runs in the background as a queue; you can keep editing one song while others analyse.</div>
    </div>
    <div style="flex:0 0 300px;display:flex;flex-direction:column;gap:18px">
      <div style="display:flex;flex-direction:column;gap:9px">
        <div class="glabel">Recently exported</div>
        <div class="card" style="padding:12px 13px;display:flex;flex-direction:column;gap:10px">
          {exported_row((205, 228), "Paper Lanterns", "yesterday · 18:40")}
          {exported_row((168, 185), "Undertow", "Mon · 21:12")}
          {exported_row((85, 100), "Cartwheel", "Sun · 10:05")}
          <span style="font-size:10.5px;color:{ACC};font-weight:500">All 19 exported songs ▸</span>
        </div>
      </div>
      <div style="display:flex;flex-direction:column;gap:9px">
        <div class="glabel">Environment</div>
        <div class="card" style="padding:12px 13px;display:flex;flex-direction:column;gap:9px;font-size:11.5px">
          <div class="frow">{i_dot(8, GREEN)}<span>Backend running <span class="mono" style="font-size:10px;color:{FAINT}">localhost:5051</span></span></div>
          <div class="frow">{i_check(11, GREEN)}<span>Tools OK — yt-dlp · ffmpeg · ffprobe · deno</span></div>
          <div class="frow">{i_person(11)}<span style="min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">you@example.com · can export</span></div>
          <span style="font-size:10.5px;color:{ACC};font-weight:500">Details ▸</span>
        </div>
      </div>
    </div>
  </div>
</div>'''

FRONT_BODY = f'''<div class="win">
  {toolbar_front()}
  <div class="body">
    {sidebar(sidebar_rows(SONGS_FRONT), FOOTER_OK, CHIPS)}
    {FRONT_MAIN}
  </div>
</div>'''

# ------------------------------------------------------------------ write ----
TITLES = {
    "FrontScreen": "ChordAdmin — launch dashboard",
    "Main": "ChordAdmin — library, chart & bar inspector",
    "Analyzing": "ChordAdmin — pipeline as a checklist",
    "BeatTuning": "ChordAdmin — sighted beat correction",
    "ExportSheet": "ChordAdmin — export confirmation",
    "States": "ChordAdmin — failure & readiness states",
}
BODIES = {"FrontScreen": FRONT_BODY, "Main": MAIN_BODY, "Analyzing": ANALYZING_BODY, "BeatTuning": TUNING_BODY,
          "ExportSheet": EXPORT_BODY, "States": STATES_BODY}

for name, body in BODIES.items():
    with open(os.path.join(HERE, f"{name}.dc.html"), "w") as f:
        f.write(dc(body))
    print(f"{name}.dc.html  {os.path.getsize(os.path.join(HERE, f'{name}.dc.html'))} bytes")

canvas = {
    "artboards": [
        {"file": "FrontScreen.dc.html", "x": -1560, "y": 0, "w": 1440, "h": 900, "title": "Front screen — launch dashboard"},
        {"file": "Main.dc.html", "x": 0, "y": 0, "w": 1440, "h": 900, "title": "Main — library · chart · inspector"},
        {"file": "Analyzing.dc.html", "x": 1560, "y": 0, "w": 1440, "h": 900, "title": "Analysing — stage checklist & queue"},
        {"file": "BeatTuning.dc.html", "x": 3120, "y": 0, "w": 1440, "h": 900, "title": "Beat tuning — pickup preview"},
        {"file": "ExportSheet.dc.html", "x": 0, "y": 1060, "w": 1440, "h": 900, "title": "Export — confirm before overwrite"},
        {"file": "States.dc.html", "x": 1560, "y": 1060, "w": 1060, "h": 700, "title": "Failure & readiness states"},
    ],
    "annotations": [
        {"id": "overview", "x": -1930, "y": 0, "w": 330, "text": "ChordAdmin redesign — one window, three columns.\nThe front screen (right) is launch with nothing selected: continue where you left off, batch-analyse new songs as a queue, recent exports, environment at a glance.\nSidebar = the work queue: every song shows its state (empty ring = not analysed, blue dot = analysed, orange pencil = edited since export, green check = exported), with filters. Songs without a YouTube link stay visible, just dimmed.\nInspector tabs: Bar · Tuning · Analysis · Info replace the fixed 280pt diagnostics column."},
        {"id": "pipeline-note", "x": 1560, "y": -230, "w": 300, "text": "The 11-stage pipeline becomes a checklist with per-stage timing, inline warnings and Cancel — replacing the colour-capsule badge + raw log console. The log is still there, one disclosure away."},
        {"id": "tuning-note", "x": 3120, "y": -230, "w": 300, "text": "Beat correction goes from blind trial-and-error (each offset click re-ran the whole chart) to a sighted choice: all four pickups drawn over the audio, chart previews live, ⏎ applies."},
        {"id": "export-note", "x": 0, "y": 2010, "w": 300, "text": "Export used to write straight to production Firestore from a tiny button. Now it shows exactly what will be overwritten (tempo + sections diff) and keeps a local snapshot for rollback."},
    ],
    "launch": {"view": "canvas"},
}
with open(os.path.join(HERE, "canvas.json"), "w") as f:
    json.dump(canvas, f, indent=2)
print("canvas.json written")
