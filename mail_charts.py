"""메일용 그래프 그림(PNG)을 만들고 메일 본문의 자리표시(<!--MAIL_CHARTS-->)에 끼운다.

업무 대시보드와 주식 대시보드가 같은 파일을 쓴다(두 저장소에 같은 내용으로 둔다).
  python3 mail_charts.py work    # 업무 참고지표 메일: 핵심 지표 6개월 흐름, 내륙운송료
  python3 mail_charts.py stock   # 주식 메일: 매수 단계 지도, 공포·탐욕지수 1년

메일 프로그램은 화면의 그래프(SVG, 자바스크립트)를 보여 주지 않는다. 그래서 대시보드와 같은 자료(생성된
dashboard.html 안의 JSON)로 SVG 를 그리고 크롬으로 2배 해상도 PNG 를 찍는다. 메일 발송 도구
(dawidd6/action-send-mail)는 첨부 파일마다 파일 이름을 cid 로 붙이므로 본문에서 <img src="cid:파일이름"> 으로 부른다.
그림을 하나도 만들지 못하면 자리표시를 그대로 두어(보이지 않는 주석) 메일은 지금처럼 글로만 나간다.
표준 라이브러리만 쓴다(실행 환경에 따로 설치할 것 없음, 한글 글꼴만 필요).
"""
import datetime as dt
import html
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "mail-charts"
MARKER = "<!--MAIL_CHARTS-->"

INK, INK2, MUTED, GRID = "#0b0b0b", "#52514e", "#6e6c66", "#e1e0d9"
# GitHub 실행 환경(우분투)에는 워크플로가 fonts-nanum 을 설치한다. 내 PC(윈도우)에서는 맑은 고딕.
FONT = "'Malgun Gothic','NanumGothic','Noto Sans KR',sans-serif"


def grab(src, name):
    m = re.search(r"^\s*const " + name + r" = (.*?);\n", src, re.S | re.M)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def esc(s):
    return html.escape(str(s), quote=True)


def day(s):
    s = str(s)
    return dt.date.fromisoformat(s[:10]) if len(s) >= 10 else dt.date(int(s[:4]), int(s[5:7]), 1)


def fmt(v, dec=0):
    return f"{v:,.{dec}f}"


def pct(v):
    if abs(v) < 0.05:
        return "0.0%"
    return ("+" if v > 0 else "−") + f"{abs(v):.1f}%"


def text(x, y, s, size=13, color=INK2, weight=400, anchor="start"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" font-weight="{weight}" '
            f'text-anchor="{anchor}">{esc(s)}</text>')


# ------------------------------------------------------------------ 업무: 핵심 지표 6개월 흐름
def work_trends(page):
    prices = {c.get("id"): c for c in (grab(page, "PRICES") or [])}
    BAD, GOOD, LINE = "#b3221f", "#006300", "#2a78d6"
    spec = [("kcci-sea", "부산→동남아 운임", lambda v: f"${fmt(v)}", "/FEU"),
            ("kcci", "부산발 운임 종합(KCCI)", lambda v: fmt(v), "pt"),
            ("pp", "PP 가격(중국 선물)", lambda v: f"¥{fmt(v)}", "/톤"),
            ("pe", "PE 가격(중국 선물)", lambda v: f"¥{fmt(v)}", "/톤"),
            ("usdkrw", "원/달러 환율", lambda v: f"{fmt(v)}원", ""),
            ("brent", "국제유가(브렌트)", lambda v: f"${v:,.2f}", "/배럴")]
    panels = []
    for cid, name, vf, unit in spec:
        c = prices.get(cid)
        pts = [(day(p["label"]), float(p["value"])) for p in (c or {}).get("points") or [] if p.get("value") is not None]
        if len(pts) < 10:
            continue
        panels.append((name, vf, unit, pts))
    if len(panels) < 2:
        return None
    W, PW, PH, GAP = 600, 290, 178, 20
    rows = (len(panels) + 1) // 2
    H = rows * PH + (rows - 1) * 12 + 26
    g = []
    for k, (name, vf, unit, pts) in enumerate(panels):
        end = pts[-1][0]
        six = [p for p in pts if p[0] >= end - dt.timedelta(days=183)]

        def back(days):
            t = end - dt.timedelta(days=days)
            c = [p for p in pts if p[0] <= t]
            return c[-1][1] if c else None
        last = pts[-1][1]
        b1, b3 = back(30), back(91)
        m1 = (last / b1 - 1) * 100 if b1 else None
        m3 = (last / b3 - 1) * 100 if b3 else None
        ox, oy = (k % 2) * (PW + GAP), (k // 2) * (PH + 12)
        g.append(f'<rect x="{ox}" y="{oy}" width="{PW}" height="{PH}" rx="8" fill="#ffffff" stroke="{GRID}"/>')
        g.append(text(ox + 14, oy + 24, name, 14, INK2, 600))
        g.append(f'<text x="{ox + 14}" y="{oy + 52}" font-size="22" font-weight="700" fill="{INK}">{esc(vf(last))}'
                 f'<tspan font-size="13" font-weight="400" fill="{MUTED}" dx="4">{esc(unit)}</tspan></text>')
        for i, (lab, v) in enumerate((("1개월", m1), ("3개월", m3))):
            if v is None:
                continue
            col = BAD if v > 0.05 else GOOD if v < -0.05 else INK2
            g.append(f'<text x="{ox + PW - 14}" y="{oy + 30 + 20 * i}" font-size="13" text-anchor="end" fill="{MUTED}">{lab} '
                     f'<tspan fill="{col}" font-weight="700">{esc(pct(v))}</tspan></text>')
        x0, x1, y0, y1 = ox + 14, ox + PW - 18, oy + 70, oy + PH - 30
        lo, hi = min(v for _, v in six), max(v for _, v in six)
        pad = (hi - lo) * 0.12 or 1
        lo, hi = lo - pad, hi + pad
        t0, t1 = six[0][0], six[-1][0]
        X = lambda d: x0 + (d - t0).days / max(1, (t1 - t0).days) * (x1 - x0)
        Y = lambda v: y1 - (v - lo) / (hi - lo) * (y1 - y0)
        path = " ".join(("M" if i == 0 else "L") + f"{X(d):.1f},{Y(v):.1f}" for i, (d, v) in enumerate(six))
        g.append(f'<line x1="{x0}" x2="{x1}" y1="{y1}" y2="{y1}" stroke="{GRID}"/>')
        t3 = end - dt.timedelta(days=91)
        if t3 > t0:   # 3개월 전 위치: 3개월 변화를 그림에서 확인하는 기준선
            g.append(f'<line x1="{X(t3):.1f}" x2="{X(t3):.1f}" y1="{y0}" y2="{y1}" stroke="{GRID}"/>')
            g.append(text(X(t3), y1 + 17, "3개월 전", 12, MUTED, anchor="middle"))
        g.append(f'<path d="{path} L{X(t1):.1f},{y1} L{X(t0):.1f},{y1} Z" fill="{LINE}" opacity="0.10"/>')
        g.append(f'<path d="{path}" fill="none" stroke="{LINE}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        g.append(f'<circle cx="{X(t1):.1f}" cy="{Y(last):.1f}" r="4.5" fill="{LINE}" stroke="#ffffff" stroke-width="2"/>')
        g.append(text(x0, y1 + 17, f"{t0.month}월", 12, MUTED))
        g.append(text(x1, y1 + 17, f"{t1.month}/{t1.day}", 12, MUTED, anchor="end"))
    g.append(text(0, H - 4, "빨강은 비용이 오르는 쪽, 초록은 내리는 쪽입니다. 파란 선은 최근 6개월, 점은 최근 값입니다.", 12, MUTED))
    return {"file": "work-trends.png", "w": W, "h": H, "svg": "".join(g),
            "title": "핵심 지표 6개월 흐름", "sub": "1개월·3개월 변화",
            "alt": "부산→동남아 운임, KCCI 종합, PP, PE, 원/달러 환율, 브렌트유의 최근 6개월 흐름과 1개월·3개월 변화"}


# ------------------------------------------------------------------ 업무: 내륙운송료
def work_freight(page):
    sf = grab(page, "SAFE_FREIGHT")
    if not sf or not sf.get("evolution") or not sf.get("window"):
        return None
    BAD, GOOD, LINE = "#b3221f", "#006300", "#2a78d6"
    base = float(sf.get("baseFuel") or 0)
    thr = float(sf.get("threshold") or 50)
    if not base:
        return None
    evo = [(day(e["date"]), float(e["avg"])) for e in sf["evolution"] if e.get("avg") is not None]
    if len(evo) < 3:
        return None
    key = str(sf["window"].get("key") or "")
    m = re.match(r"(\d{4})-Q([1-4])", key)
    if not m:
        return None
    yr, q = int(m.group(1)), int(m.group(2))
    win_start = dt.date(yr, 3 * q - 2, 1)
    win_end = (dt.date(yr + 1, 1, 1) if q == 4 else dt.date(yr, 3 * q + 1, 1)) - dt.timedelta(days=1)
    scen = sf.get("scenario") or {}
    s_avg = (scen.get("current") or {}).get("avg")
    W, H = 600, 310
    L, R, T, B = 58, 160, 30, 48
    vals = [v for _, v in evo] + ([float(s_avg)] if s_avg else [])
    lo, hi = min(base - thr - 40, min(vals) - 20), max(base + thr + 30, max(vals) + 20)
    X = lambda d: L + (d - win_start).days / max(1, (win_end - win_start).days) * (W - L - R)
    Y = lambda v: T + (hi - v) / (hi - lo) * (H - T - B)
    g = [f'<rect x="{L}" y="{Y(base + thr):.1f}" width="{W - L - R}" height="{Y(base - thr) - Y(base + thr):.1f}" fill="#f0efec"/>']
    for v in range(int(lo // 50 * 50 + 50), int(hi), 50):
        g.append(text(L - 8, Y(v) + 4, fmt(v), 12, MUTED, anchor="end"))
    g.append(f'<line x1="{L}" x2="{W - R}" y1="{Y(base + thr):.1f}" y2="{Y(base + thr):.1f}" stroke="{BAD}" stroke-width="1.5" stroke-dasharray="5 4"/>')
    g.append(f'<line x1="{L}" x2="{W - R}" y1="{Y(base - thr):.1f}" y2="{Y(base - thr):.1f}" stroke="{GOOD}" stroke-width="1.5" stroke-dasharray="5 4"/>')
    g.append(f'<line x1="{L}" x2="{W - R}" y1="{Y(base):.1f}" y2="{Y(base):.1f}" stroke="{MUTED}" stroke-width="1" stroke-dasharray="2 3"/>')
    g.append(text(W - R + 8, Y(base + thr) + 4, f"인상 기준 {fmt(base + thr)}", 13, BAD, 700))
    g.append(text(W - R + 8, Y(base) + 4, f"기준 {fmt(base)}", 13, INK2))
    g.append(text(W - R + 8, Y(base - thr) + 4, f"인하 기준 {fmt(base - thr)}", 13, GOOD, 700))
    g.append(text(L + 8, Y(base) - 8, "이 안이면 운임 동결", 12, MUTED))
    path = " ".join(("M" if i == 0 else "L") + f"{X(d):.1f},{Y(v):.1f}" for i, (d, v) in enumerate(evo))
    g.append(f'<path d="{path}" fill="none" stroke="{LINE}" stroke-width="2.2" stroke-linejoin="round"/>')
    td, tv = evo[-1]
    g.append(f'<line x1="{X(td):.1f}" x2="{X(td):.1f}" y1="{T}" y2="{H - B}" stroke="{GRID}"/>')
    g.append(text(X(td), T - 6, "오늘", 12, INK2, 700, anchor="middle"))
    g.append(f'<circle cx="{X(td):.1f}" cy="{Y(tv):.1f}" r="5" fill="{LINE}" stroke="#fff" stroke-width="2"/>')
    g.append(text(X(td) - 10, Y(tv) + 24, f"지금 추정 {fmt(round(tv))}원", 13, INK, 700, anchor="end"))
    if s_avg and scen.get("until") and str(scen["until"]) >= td.isoformat():
        sx, sy = X(win_end) - 2, Y(float(s_avg))
        until = day(scen["until"])
        g.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="5" fill="#ffffff" stroke="{BAD}" stroke-width="2"/>')
        g.append(text(sx - 12, sy + 5, f"유류세 인하가 {until.month}/{until.day}에 끝나면", 12, BAD, anchor="end"))
        gap = base + thr - float(s_avg)
        tail = f"(인상 기준까지 {fmt(round(gap))}원)" if gap > 0 else "(인상 기준 넘음)"
        g.append(text(sx - 12, sy + 22, f"{fmt(round(float(s_avg)))}원{tail}", 13, BAD, 700, anchor="end"))
    ticks = [win_start, dt.date(win_start.year, win_start.month + 1, 1), dt.date(win_start.year, win_start.month + 2, 1), win_end]
    for d in ticks:
        g.append(text(X(d), H - B + 18, f"{d.month}/{d.day}", 12, MUTED, anchor="middle"))
    g.append(text(L, H - 4, "경유 평균(원/L), 남은 날은 지금 가격이 이어진다고 보고 계산", 12, MUTED))
    verdict = str((sf.get("base") or {}).get("verdict") or "")
    apply_label = str(sf["window"].get("applyLabel") or "")
    title = f"{apply_label} 내륙운송료: {verdict} 예상" if verdict and apply_label else "컨테이너 내륙운송료"
    return {"file": "work-freight.png", "w": W, "h": H, "svg": "".join(g),
            "title": title, "sub": f"{sf['window'].get('label', '')} 경유 평균 추정",
            "alt": f"{sf['window'].get('label', '')} 경유 평균 추정 {fmt(round(tv))}원, 인상 기준 {fmt(base + thr)}원, 인하 기준 {fmt(base - thr)}원"}


# ------------------------------------------------------------------ 주식: 매수 단계 지도
def stock_stages(page):
    st = grab(page, "stocks") or []
    ACC = "#0f766e"
    rows = sorted([x for x in st if isinstance(x.get("ddNow"), (int, float))], key=lambda x: -x["ddNow"])
    if not rows:
        return None
    W, RH, TOP = 600, 28, 8
    H = TOP + RH * len(rows) + 46
    L, TR, R = 104, 372, 600
    axis_max = max(70, int((max(x["ddNow"] for x in rows) + 9) // 10 * 10))
    X = lambda v: L + min(v, axis_max) / axis_max * (TR - L)
    g = []
    for i, x in enumerate(rows):
        y = TOP + i * RH
        steps = [float(s) for s in ((x.get("dip") or {}).get("steps") or [10, 20, 30])][:3]
        lv = int((x.get("dip") or {}).get("level") or 0)
        g.append(text(0, y + 18, x.get("name", x.get("symbol", "")), 13, INK, 600))
        g.append(f'<rect x="{L}" y="{y + 5}" width="{TR - L}" height="16" rx="3" fill="#f3f2ee"/>')
        for k, s in enumerate(steps):
            nx = steps[k + 1] if k + 1 < len(steps) else axis_max
            g.append(f'<rect x="{X(s):.1f}" y="{y + 5}" width="{max(0, X(nx) - X(s)):.1f}" height="16" fill="{ACC}" opacity="{[0.07, 0.13, 0.2][k]}"/>')
        col = "#a8a69e" if lv == 0 else ACC
        op = [1, 0.5, 0.75, 1][min(lv, 3)]
        g.append(f'<rect x="{L}" y="{y + 9}" width="{max(2, X(x["ddNow"]) - L):.1f}" height="8" rx="4" fill="{col}" opacity="{op}"/>')
        g.append(text(TR + 12, y + 18, f"−{x['ddNow']:.1f}%", 13, INK, 700))
        g.append(text(TR + 72, y + 18, f"{lv}단계" if lv else "단계 전", 13, ACC if lv else MUTED, 700 if lv else 400))
        nxt = next((s for s in steps if s > x["ddNow"]), None)
        if nxt is not None:
            g.append(text(R, y + 18, f"다음 단계까지 {nxt - x['ddNow']:.1f}%", 12, MUTED, anchor="end"))
    yb = TOP + RH * len(rows) + 4
    for v in range(0, axis_max + 1, 20):
        g.append(text(X(v), yb + 14, "0" if v == 0 else f"−{v}%", 12, MUTED, anchor="middle"))
    g.append(text(0, H - 6, "막대: 52주 고점 대비 하락률, 배경: 분할 1·2·3단계 구간(코인은 20·40·60%)", 12, MUTED))
    return {"file": "stock-stages.png", "w": W, "h": H, "svg": "".join(g),
            "title": "매수 단계 지도", "sub": "52주 고점 대비, 깊이 내려온 순",
            "alt": "관심 종목의 52주 고점 대비 하락률과 분할 매수 단계"}


# ------------------------------------------------------------------ 주식: 공포·탐욕지수 1년
def stock_fg(page):
    fg = grab(page, "fearGreed")
    if not fg or not fg.get("trend"):
        return None
    tr = [(day(p["d"]), float(p["s"])) for p in fg["trend"] if p and p.get("s") is not None]
    if len(tr) < 20:
        return None
    W, H = 600, 262
    L, R, T, B = 34, 112, 14, 50
    t0, t1 = tr[0][0], tr[-1][0]
    X = lambda d: L + (d - t0).days / max(1, (t1 - t0).days) * (W - L - R)
    Y = lambda v: T + (100 - v) / 100 * (H - T - B)
    zones = [(0, 25, "극단적 공포", "#c0392b", 0.13), (25, 45, "공포", "#e67e22", 0.10), (45, 56, "중립", None, 0),
             (56, 76, "탐욕", None, 0), (76, 101, "극단적 탐욕", None, 0)]
    now = tr[-1][1]
    g = []
    for a, b, name, col, op in zones:
        bb = min(b, 100)
        if col:
            g.append(f'<rect x="{L}" y="{Y(bb):.1f}" width="{W - L - R}" height="{Y(a) - Y(bb):.1f}" fill="{col}" opacity="{op}"/>')
        here = a <= now < b
        g.append(text(W - R + 12, (Y(a) + Y(bb)) / 2 + 4, name + (f" ← 지금 {now:.0f}" if here else ""),
                      13 if here else 12, INK if here else (INK2 if col else MUTED), 700 if here else (600 if col else 400)))
    for v in (0, 25, 50, 75, 100):
        g.append(f'<line x1="{L}" x2="{W - R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" stroke="{GRID}"/>')
        g.append(text(L - 6, Y(v) + 4, str(v), 12, MUTED, anchor="end"))
    path = " ".join(("M" if i == 0 else "L") + f"{X(d):.1f},{Y(v):.1f}" for i, (d, v) in enumerate(tr))
    g.append(f'<path d="{path}" fill="none" stroke="{INK}" stroke-width="1.6" stroke-linejoin="round"/>')
    g.append(f'<circle cx="{X(t1):.1f}" cy="{Y(now):.1f}" r="5" fill="{INK}" stroke="#fff" stroke-width="2"/>')
    seen = set()
    for d, _ in tr:
        if d.month in (1, 4, 7, 10) and (d.year, d.month) not in seen and d.day <= 7:
            seen.add((d.year, d.month))
            g.append(text(X(d), H - B + 18, f"{str(d.year)[2:]}.{d.month}", 12, MUTED, anchor="middle"))
    low = sum(1 for _, v in tr if v < 25)
    g.append(text(L, H - 4, f"최근 1년 중 24 이하(극단적 공포)였던 날 {low}일", 12, MUTED))
    return {"file": "stock-feargreed.png", "w": W, "h": H, "svg": "".join(g),
            "title": "시장 심리", "sub": "CNN 공포·탐욕지수 최근 1년",
            "alt": f"공포·탐욕지수 최근 1년 흐름, 지금 {now:.0f}"}


# ------------------------------------------------------------------ 그림 찍기, 메일에 끼우기
def find_chrome():
    for c in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome"):
        p = shutil.which(c)
        if p:
            return p
    for p in (r"C:\Program Files\Google\Chrome\Application\chrome.exe", r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"):
        if os.path.exists(p):
            return p
    return None


def shoot(chrome, chart, tmp):
    page = (f'<!doctype html><html><head><meta charset="utf-8"><style>html,body{{margin:0;background:#fff;overflow:hidden}}'
            f'svg{{display:block;font-family:{FONT}}}</style></head><body>'
            f'<svg width="{chart["w"]}" height="{chart["h"]}" viewBox="0 0 {chart["w"]} {chart["h"]}" xmlns="http://www.w3.org/2000/svg">'
            f'{chart["svg"]}</svg></body></html>')
    src = pathlib.Path(tmp) / (chart["file"] + ".html")
    src.write_text(page, encoding="utf-8")
    out = OUT / chart["file"]
    if out.exists():
        out.unlink()
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
                    "--force-device-scale-factor=2", f"--window-size={chart['w']},{chart['h']}",
                    f"--screenshot={out}", src.as_uri()], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    return out.exists() and out.stat().st_size > 2000


def block(chart, width):
    # Outlook 은 CSS 폭을 무시하고 width 속성을 따르므로 둘 다 적는다.
    return (f'<div style="margin:0 0 14px;">'
            f'<div style="font-size:13.5px;font-weight:700;color:#0b0b0b;margin:0 0 6px;">{esc(chart["title"])}'
            f' <span style="font-weight:400;font-size:12px;color:#6e6c66;">{esc(chart["sub"])}</span></div>'
            f'<img src="cid:{chart["file"]}" width="{width}" alt="{esc(chart["alt"])}" '
            f'style="display:block;width:100%;max-width:{width}px;height:auto;border:0;"></div>')


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else ""
    page_path = ROOT / (sys.argv[2] if len(sys.argv) > 2 else "dashboard.html")
    mail_path = ROOT / (sys.argv[3] if len(sys.argv) > 3 else "email-summary.html")
    makers = {"work": ([work_trends, work_freight], 536), "stock": ([stock_stages, stock_fg], 568)}
    if kind not in makers:
        sys.exit("사용법: python3 mail_charts.py work|stock")
    funcs, width = makers[kind]
    page = page_path.read_text(encoding="utf-8")
    mail = mail_path.read_text(encoding="utf-8")
    if MARKER not in mail:
        print("메일 본문에 그림 자리표시가 없어 그림을 넣지 않습니다.")
        return
    chrome = find_chrome()
    if not chrome:
        print("크롬을 찾지 못해 그림 없이 보냅니다.")
        return
    OUT.mkdir(exist_ok=True)
    for f in OUT.glob("*.png"):
        f.unlink()
    done = []
    with tempfile.TemporaryDirectory() as tmp:
        for fn in funcs:
            try:
                chart = fn(page)
            except Exception as e:   # 그림 하나가 실패해도 나머지와 메일은 나간다
                print(f"그림 만들기 실패({fn.__name__}): {e}")
                continue
            if not chart:
                print(f"자료가 부족해 건너뜀: {fn.__name__}")
                continue
            if shoot(chrome, chart, tmp):
                done.append(chart)
                print(f"그림 {chart['file']}: {(OUT / chart['file']).stat().st_size // 1024}KB")
            else:
                print(f"그림 찍기 실패: {chart['file']}")
    if done:
        mail = mail.replace(MARKER, "".join(block(c, width) for c in done), 1)
        mail_path.write_text(mail, encoding="utf-8")
    print(f"메일 그림 {len(done)}장 넣음")


if __name__ == "__main__":
    main()
