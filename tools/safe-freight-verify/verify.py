# 안전운임 유가연동 판정의 독립 검증.
# 1) 고시 문구만 보고 새로 짠 Python 계산(아래 ref_*)으로
# 2) 대시보드 PS1 함수를 그대로 뽑아 PowerShell 5.1 에서 돌린 결과와
# 3) 배포된 페이지에 실린 결과를 같은 입력에서 비교한다.
# 사용: python -I -X utf8 verify.py <repo> <funcs.ps1> <live-sf.json> <workdir>
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

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)

cfg = json.load(open(f"{repo}/config.json", encoding="utf-8-sig"))["safeFreight"]
hist = json.load(open(f"{repo}/data-history.json", encoding="utf-8-sig"))
daily = {k: float(v) for k, v in hist["fuel-D047"].items()}
live = json.load(open(live_path, encoding="utf-8"))

# ---- A. 배포 페이지 재현 ---------------------------------------------------------------
today = date(2026, 11, 8)
latest_k = max(daily)
base_fuel = live["baseFuel"]
w = ref_window(daily, qstart(today), today, daily[latest_k])
diff, vd = ref_verdict(w["avg"], base_fuel)
print(f"[A] 독립 계산 10~12월 평균 {w['avg']:.4f} (월 {[round(m, 4) for m in w['months']]}), 기준 {base_fuel} 대비 {diff} → {vd}")
print(f"    배포 페이지         {live['base']['avg']} / {live['base']['diff']} → {live['base']['verdict']}")
check(abs(w["avg"] - live["base"]["avg"]) <= 0.01, "A: 평균 불일치")
check(vd == live["base"]["verdict"], "A: 판정 불일치")
# 일수 가중 평균(달력 일수로 가중)으로 바꾸면 얼마나 달라지는지 - 방식 차이의 크기
wd = [v for v in [w["months"]]][0]
dw = sum(m * len(days_of(2026, 10 + i)) for i, m in enumerate(wd)) / sum(len(days_of(2026, 10 + i)) for i in range(3))
print(f"    참고: 일수 가중 평균이면 {dw:.4f} (차이 {dw - w['avg']:+.4f}원)")
# 추이(날마다 그날까지 값만으로 다시 계산)
evo_ok = 0
for e in live["evolution"]:
    d = date.fromisoformat(e["date"])
    part = {k: v for k, v in daily.items() if qstart(today).isoformat() <= k <= e["date"]}
    we = ref_window(part, qstart(today), d, daily[e["date"]])
    check(abs(we["avg"] - e["avg"]) <= 0.01, f"A: 추이 {e['date']} {we['avg']:.3f} vs {e['avg']}")
    evo_ok += abs(we["avg"] - e["avg"]) <= 0.01
print(f"    추이 {evo_ok}/{len(live['evolution'])}일 일치")
# 시나리오(유류세 인하 종료)
s = live["scenario"]
for won, tag in [(s["won"], "페이지 가정"), (145.0, "145원(부가세 포함 인하폭)")]:
    sc = ref_window(daily, qstart(today), today, daily[latest_k], date(2026, 11, 30), won)
    sn = ref_window(daily, date(2027, 1, 1), today, daily[latest_k], date(2026, 11, 30), won)
    d1, v1 = ref_verdict(sc["avg"], base_fuel)
    nb = sc["avg"] if v1 != "동결" else base_fuel
    d2, v2 = ref_verdict(sn["avg"], nb)
    print(f"    시나리오 +{won}원({tag}): 10~12월 {sc['avg']:.2f}({d1:+}, {v1}) · 2027년 1~3월 {sn['avg']:.2f}({d2:+}, {v2})")
    if won == s["won"]:
        check(abs(sc["avg"] - s["current"]["avg"]) <= 0.01 and v1 == s["current"]["verdict"], "A: 시나리오 이번 분기 불일치")
        check(abs(sn["avg"] - s["next"]["avg"]) <= 0.01 and v2 == s["next"]["verdict"], "A: 시나리오 다음 분기 불일치")

# ---- B. 무작위 산정 기간 계산: PS 함수 vs 독립 계산 --------------------------------------
rng = random.Random(20261108)
cases, refs = [], {}
for n in range(400):
    qs = rng.choice([date(2026, 7, 1), date(2026, 10, 1), date(2027, 1, 1)])
    start = qs - timedelta(days=rng.randint(0, 40))
    today_c = qs + timedelta(days=rng.randint(-5, 100))
    p = rng.uniform(1600, 2100); dd = {}
    d = start
    while d <= min(today_c, qs + timedelta(days=95)):
        p += rng.gauss(0, 4)
        if rng.random() > 0.06:           # 6% 는 수집 공백
            dd[d.isoformat()] = round(p, 2)
        d += timedelta(days=1)
    if not dd:
        continue
    proj = dd[max(dd)]
    step_after = rng.choice([None, qs + timedelta(days=rng.randint(10, 80))])
    step_won = rng.choice([0.0, 145.0, -80.0])
    base = round(rng.uniform(1700, 2000), 2)
    cid = f"w{n}"
    cases.append(dict(id=cid, kind="window", daily=dd, qstart=qs.isoformat(), today=today_c.isoformat(), proj=proj,
                      stepAfter=step_after.isoformat() if step_after else None, stepWon=step_won, base=base))
    refs[cid] = (ref_window(dd, qs, today_c, proj, step_after, step_won), base)

# 경계: 정확히 기준 ±50.00, ±49.99, ±50.01
for j, off in enumerate([-50.0, -49.99, -50.01, 50.0, 49.99, 50.01]):
    base = 1852.78
    dd = {d.isoformat(): base + off for m in (10, 11, 12) for d in days_of(2026, m)}
    cid = f"b{j}"
    cases.append(dict(id=cid, kind="window", daily=dd, qstart="2026-10-01", today="2027-01-05", proj=0, stepAfter=None, stepWon=0, base=base))
    refs[cid] = (ref_window(dd, date(2026, 10, 1), date(2027, 1, 5), 0), base)

out = ps(cases)
nb = 0
for cid, (rw, base) in refs.items():
    o = out[cid]
    if rw["avg"] is None:
        check(o["avg"] is None, f"B {cid}: PS 평균이 있어야 하지 않음"); continue
    check(o["avg"] is not None and abs(o["avg"] - rw["avg"]) <= 0.011, f"B {cid}: 평균 {o['avg']} vs {rw['avg']:.4f}")
    check(o["actualDays"] == rw["actualDays"] and o["projectedDays"] == rw["projectedDays"], f"B {cid}: 일수")
    d_ref, v_ref = ref_verdict(rw["avg"], base)
    near = abs(abs(rw["avg"] - base) - THR) < 0.011
    if not near:
        check(o["verdict"] == v_ref, f"B {cid}: 판정 {o['verdict']} vs {v_ref} (차이 {d_ref})")
    if cid.startswith("b"):
        print(f"[B] 경계 {cid}: 기준 {base} + {round(rw['avg'] - base, 2):+} → PS {o['verdict']} / 독립 {v_ref}")
        check(o["verdict"] == v_ref, f"B {cid}: 경계 판정 불일치")
    nb += 1
print(f"[B] 산정 기간 계산 {nb}건 비교")

# ---- C. 전체 전망 함수(Get-SafeFreightOutlook): 오늘 입력 그대로 PS 실행 ----------------------
oc = [dict(id="live", kind="outlook", daily=daily, today="2026-11-08", cfg=cfg)]
po = ps(oc)["live"]["outlook"]
check(abs(po["base"]["avg"] - live["base"]["avg"]) < 0.005 and po["base"]["verdict"] == live["base"]["verdict"], "C: PS 5.1 결과가 배포 페이지와 다름")
print(f"[C] PS 5.1 재실행: {po['window']['label']} {po['base']['avg']} ({po['base']['diff']:+}) {po['base']['verdict']} · 기준 {po['baseFuel']} · 적용 {po['window']['applyLabel']}")

# ---- D. 공식 이력 재현(분기 평균만으로 규칙을 돌린다) ------------------------------------
official = [("2025-Q4", 1601.96, "새 고시(2/1)"), ("2026-Q1", 1674.92, "동결(5월 고시 없음)"),
            ("2026-Q2", 1994.68, "인상(8/1, 제2026-402호)"), ("2026-Q3", 1852.78, "인하(11/1, 제2026-595호)")]
applied = official[0][1]
print("[D] 공식 이력 재현 (기준 = 지금 운임에 반영된 유가)")
for key, avg, actual in official[1:]:
    d, v = ref_verdict(avg, applied)
    mark = "일치" if actual.startswith(v) else "불일치 → 위원회 판단"
    print(f"    {key} {avg} vs {applied} = {d:+} → 규칙 {v} / 실제 {actual}: {mark}")
    if actual.startswith(("인상", "인하")):
        applied = avg

print()
print("결과:", "모두 통과" if not fails else f"{len(fails)}건 실패")
for f in fails[:30]:
    print("  -", f)
sys.exit(1 if fails else 0)
