# verify.py 와 verify_new.py 가 함께 쓰는 독립 계산과 PowerShell 실행기.
import calendar, json, math, random, subprocess, sys
from datetime import date, timedelta

repo, funcs, live_path, work = sys.argv[1:5]
THR = 50.0

def add_months(d, k):
    y = d.year + (d.month - 1 + k) // 12
    m = (d.month - 1 + k) % 12 + 1
    return date(y, m, 1)

def qstart(d):
    return date(d.year, (d.month - 1) // 3 * 3 + 1, 1)

def days_of(y, m):
    return [date(y, m, i) for i in range(1, calendar.monthrange(y, m)[1] + 1)]

def ref_window(daily, qs, today, proj, step_after=None, step_won=0.0):
    """고시: 산정 기간(3개월) 평균유가. 대시보드는 월평균 3개의 단순평균으로 본다(업무 표 방식)."""
    mav, act, prj, past = [], 0, 0, 0
    for i in range(3):
        ms = add_months(qs, i)
        vals = []
        for d in days_of(ms.year, ms.month):
            k = d.isoformat()
            if d <= today:
                past += 1
            if k in daily:
                vals.append(daily[k]); act += 1
            elif d > today:
                vals.append(proj + (step_won if step_after and d > step_after else 0.0)); prj += 1
        mav.append(sum(vals) / len(vals) if vals else None)
    avg = sum(mav) / 3 if all(v is not None for v in mav) else None
    return dict(avg=avg, months=mav, actualDays=act, projectedDays=prj, pastDays=past)

def ref_verdict(avg, base):
    diff = round(avg - base, 2)          # 고시 금액은 소수 둘째 자리
    return diff, ("인상" if diff >= THR else "인하" if diff <= -THR else "동결")

def ps(cases):
    cp = f"{work}/cases.json"; op = f"{work}/ps-out.json"
    json.dump(cases, open(cp, "w", encoding="utf-8"), ensure_ascii=False)
    r = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f"{work}/run.ps1",
                        "-funcs", funcs, "-cases", cp, "-out", op], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode:
        print(r.stdout, r.stderr); raise SystemExit("PowerShell run failed")
    out = json.load(open(op, encoding="utf-8-sig"))
    return {o["id"]: o for o in (out if isinstance(out, list) else [out])}

