# 고친 계산(공식 기준 유가, 고시 조항, 이력 점검, 판정 전환 가격, 노선 운임 변동, 유류세 시나리오)의 독립 검증.
# 사용: python -I -X utf8 verify_new.py <repo> <funcs.ps1> <workdir> <dist-dir>
import json, math, sys
from datetime import date, timedelta
sys.argv = sys.argv[:1] + sys.argv[1:]
repo, funcs, work, distdir = sys.argv[1:5]
sys.argv = [sys.argv[0], repo, funcs, "-", work]
import importlib.util
spec = importlib.util.spec_from_file_location("v", f"{work}/verify_lib.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)
    return cond

cfg = json.load(open(f"{repo}/config.json", encoding="utf-8-sig"))["safeFreight"]
hist = json.load(open(f"{repo}/data-history.json", encoding="utf-8-sig"))
daily = {k: float(x) for k, x in hist["fuel-D047"].items()}
BASE = 1852.78

def round100(x):          # 부대조항 7: 십 원 단위에서 반올림(0.5 는 위로)
    return math.floor(abs(x) / 100 + 0.5) * 100 * (1 if x >= 0 else -1)

# ---- E1. 오늘 입력으로 PS 전망 ---------------------------------------------------------
cases = [dict(id="now", kind="outlook", daily=daily, today="2026-11-08", cfg=cfg)]
# E5. 10~12월이 끝난 뒤(고시 조항 없는 분기가 계산 이력으로 붙는 경우), E6. 정확히 −50.00원
q4 = [date(2026, 10, 1) + timedelta(days=i) for i in range(92)]
syn = dict(daily); syn.update({d.isoformat(): 1790.0 for d in q4})
syn.update({(date(2027, 1, 1) + timedelta(days=i)).isoformat(): 1795.0 for i in range(9)})
cases.append(dict(id="after", kind="outlook", daily=syn, today="2027-01-10", cfg=cfg))
edge = {d.isoformat(): round(BASE - 50, 2) for d in q4}
edge.update({"2027-01-01": 1800.0})
cases.append(dict(id="edge", kind="outlook", daily=edge, today="2027-01-02", cfg=cfg))
out = v.ps(cases)
o = out["now"]["outlook"]

print(f"[E1] 기준 {o['baseFuel']} ({o['baseWindow']}, 잠정 {o['baseProvisional']}) · 적용 {o['applied']['fuel']} {o['applied']['since']}~")
check(o["baseFuel"] == BASE and not o["baseProvisional"], "E1: 기준 유가가 공식 값이 아님")
check(o["applied"]["fuel"] == BASE and o["applied"]["since"] == "2026-11-01", "E1: 적용 중 운임")
w = v.ref_window(daily, date(2026, 10, 1), date(2026, 11, 8), daily[max(daily)])
d_ref, vd_ref = v.ref_verdict(w["avg"], BASE)
print(f"     10~12월 {o['base']['avg']} ({o['base']['diff']:+}) {o['base']['verdict']} · 독립 {w['avg']:.4f} ({d_ref:+}) {vd_ref}")
check(abs(o["base"]["avg"] - w["avg"]) <= 0.01 and o["base"]["verdict"] == vd_ref, "E1: 판정")
print(f"     조항: inNotice={o['window']['inNotice']} · 적용 표기 {o['window']['applyLabel']} · 안내 {len(o['window']['noticeNote'])}자")
check(o["window"]["inNotice"] is False and len(o["window"]["noticeNote"]) > 20, "E1: 10~12월은 조항 없음으로 나와야 함")
for h in o["history"]:
    print(f"     이력 {h['window']} → {h['applyLabel']} {h['verdict']} {h['avg']} (조항 {h['inNotice']}, override {h['override']})")
exp_apply = {"2025년 10~12월": "2026년 2~4월", "2026년 1~3월": "2026년 5~7월", "2026년 4~6월": "2026년 8~10월", "2026년 7~9월": "2026년 11월~2027년 1월"}
for h in o["history"]:
    check(exp_apply.get(h["window"]) == h["applyLabel"] and h["inNotice"], f"E1: 이력 적용 기간 {h['window']}")
print("[E1] 이력 점검(checks)")
for c in o["checks"]:
    print(f"     {c['window']}: {c['avg']} vs {c['base']} = {c['diff']:+} → 규칙 {c['rule']} / 고시 {c['actual']} (일치 {c['match']}, override {c['override']})")
exp = [("2026년 1~3월", "인상", "동결", True), ("2026년 4~6월", "인상", "인상", False), ("2026년 7~9월", "인하", "인하", False)]
check([(c["window"], c["rule"], c["actual"], c["override"]) for c in o["checks"]] == exp, "E1: 이력 점검 결과")

# ---- E2. 판정이 바뀌는 남은 날 평균(인하·인상) ------------------------------------------------
def solve(target):
    lo, hi = 1000.0, 3000.0
    for _ in range(80):
        mid = (lo + hi) / 2
        a = v.ref_window(daily, date(2026, 10, 1), date(2026, 11, 8), mid)["avg"]
        lo, hi = (mid, hi) if a < target else (lo, mid)
    return (lo + hi) / 2
p_dn, p_up = solve(BASE - 50), solve(BASE + 50)
print(f"[E2] 인하 전환 {o['base']['downAt']}원 이하 (독립 {p_dn:.3f}) · 인상 전환 {o['base']['upAt']}원 이상 (독립 {p_up:.3f})")
check(o["base"]["downAt"] == math.floor(p_dn) and o["base"]["upAt"] == math.ceil(p_up), "E2: 전환 가격")
a_at = v.ref_window(daily, date(2026, 10, 1), date(2026, 11, 8), o["base"]["downAt"])["avg"]
a_over = v.ref_window(daily, date(2026, 10, 1), date(2026, 11, 8), o["base"]["downAt"] + 1)["avg"]
check(v.ref_verdict(a_at, BASE)[1] == "인하" and v.ref_verdict(a_over, BASE)[1] == "동결", "E2: 전환 가격에서 판정이 실제로 바뀌어야 함")
print(f"     확인: 남은 날 {o['base']['downAt']}원이면 평균 {a_at:.2f}(인하), {o['base']['downAt'] + 1}원이면 {a_over:.2f}(동결)")

# ---- E3. 유류세 시나리오(145원, 부가세 포함) ----------------------------------------------
s = o["scenario"]
sc = v.ref_window(daily, date(2026, 10, 1), date(2026, 11, 8), daily[max(daily)], date(2026, 11, 30), 145.0)
sn = v.ref_window(daily, date(2027, 1, 1), date(2026, 11, 8), daily[max(daily)], date(2026, 11, 30), 145.0)
print(f"[E3] 시나리오 +{s['won']}원: 10~12월 {s['current']['avg']} ({s['current']['diff']:+}, {s['current']['verdict']}) · "
      f"2027년 1~3월 {s['next']['avg']} ({s['next']['diff']:+}, {s['next']['verdict']}, 조항 {s['next']['inNotice']})")
check(s["won"] == 145 and abs(s["current"]["avg"] - sc["avg"]) <= 0.01 and abs(s["next"]["avg"] - sn["avg"]) <= 0.01, "E3: 시나리오 평균")
check(s["trigger"] and s["trigger"]["inNotice"] is False, "E3: 시나리오 조정은 고시 밖이라 참고로 표시돼야 함")

# ---- E4. 노선 운임 변동 ---------------------------------------------------------------
routes = cfg["routes"]; ref = cfg["fuelRef"]["delta"]
for dlt in (-141.9, -62.78, -50.0, 37.59, 133.7):
    want = [round100(r["rate"] + r["refChange"] * dlt / ref) - r["rate"] for r in routes]
    print(f"[E4] 유가 {dlt:+}원 → 노선 변동 {want}")
imp = o["base"]["fuelOnlyImpact"]
want = [round100(r["rate"] + r["refChange"] * o["base"]["diff"] / ref) - r["rate"] for r in routes]
check([x["change"] for x in imp] == want, f"E4: 연료 몫 변동 {[x['change'] for x in imp]} vs {want}")
ti = s["trigger"]["impact"]
want_t = [round100(r["rate"] + r["refChange"] * s["trigger"]["diff"] / ref) - r["rate"] for r in routes]
check([x["change"] for x in ti] == want_t, "E4: 시나리오 노선 변동")
print(f"     연료 몫(10~12월 {o['base']['diff']:+}원): {[x['change'] for x in imp]} · 시나리오({s['trigger']['diff']:+}원): {[x['change'] for x in ti]}")

# 운임표 전체(1~550km)로 본 방식 비교: 11/1 실제 변동 vs 예전 방식(왕복 km ÷ 3.675 × −141.90)
F, A, N = [{int(k): x for k, x in json.load(open(f"{distdir}/dist-{p}.json")).items()} for p in ("feb", "aug", "nov")]
errs_old = [(k, round100(A[k][6] + 2 * k / 3.675 * -141.9) - A[k][6] - (N[k][6] - A[k][6])) for k in A]
worst = max(errs_old, key=lambda t: abs(t[1]))
mean_abs = sum(abs(e) for _, e in errs_old) / len(errs_old)
print(f"[E4] 예전 방식의 11/1 변동 오차: 평균 {mean_abs:,.0f}원, 최대 {worst[1]:+,}원(구간 {worst[0]}km) / 새 방식은 정의상 0원")
for k in (10, 62, 89, 200, 400):
    print(f"     구간 {k}km(왕복 {2*k}): 실제 {N[k][6]-A[k][6]:+,} · 예전 방식 {round100(A[k][6] + 2*k/3.675*-141.9) - A[k][6]:+,}")
# 다른 구간 시험: 8/1 인상(경유 +392.72)을 11/1 민감도로 예측
ratios = [(A[k][6] - F[k][6]) / ((N[k][6] - A[k][6]) * 392.72 / -141.9) for k in A if k >= 20]
print(f"[E4] 8/1 인상분 ÷ (11/1 민감도로 본 예측): 평균 {sum(ratios)/len(ratios):.3f}배 (구간 20~550km) → 1,700원 아래 구간이 걸리면 운임이 더 움직임")

# ---- E5·E6. 조항 없는 분기가 끝난 뒤, 경계 ------------------------------------------------
oa = out["after"]["outlook"]
last = oa["history"][-1]
print(f"[E5] 2027-01-10: 계산 이력 {last['window']} {last['avg']} {last['verdict']} (조항 {last['inNotice']}, 계산 {last['computed']}) → 다음 기준 {oa['baseFuel']}, 진행 {oa['window']['label']} 조항 {oa['window']['inNotice']}")
check(last["window"] == "2026년 10~12월" and last["verdict"] == "인하" and last["inNotice"] is False and oa["baseFuel"] == 1790, "E5: 조항 없는 분기 계산 이력")
oe = out["edge"]["outlook"]
le = oe["history"][-1]
print(f"[E6] 10~12월 매일 {round(BASE - 50, 2)}원: 평균 {le['avg']} → {le['verdict']}")
check(le["verdict"] == "인하", "E6: 정확히 −50.00원은 인하")

print()
print("결과:", "모두 통과" if not fails else f"{len(fails)}건 실패")
for f in fails:
    print("  -", f)
sys.exit(1 if fails else 0)
