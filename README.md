# Work Dashboard

Local reference dashboard for daily work-planning inputs. No backend, no build step — just
PowerShell + a static HTML/JS template.

**Live:** https://jhkim0603.github.io/work-dashboard/ — republished daily by the GitHub Actions
workflow.

## What's on it

1. **날씨 / 온습도** — 울산 남구 현재 기온·습도·체감온도, 3일 예보(강수확률 포함). 체감/최고기온이
   기상청 특보 기준(단순화)을 넘으면 "폭염주의보/경보" 멘트가, 최저기온이 기준 이하면
   "한파주의보/경보" 멘트가 자동으로 붙습니다.
2. **공휴일 · 연휴** — 오늘 이후 가장 빠른 한국 공휴일 연휴 구간(주말과 이어진 실제 연휴 블록), D-day, 이후 공휴일 목록
3. **베트남 태풍 감시** — 베트남에서 들어오는 부자재 입고 일정이 태풍으로 지연되는 걸 미리 파악하기
   위한 섹션. 일별 날씨 대신, 하노이/호치민 두 거점 기준으로 GDACS가 추적하는 열대저기압 중
   베트남 관련(국가 목록에 포함되거나 두 거점 800km 이내)인 것만 걸러서 보여줍니다. 활성 태풍이
   있으면 경고, 없으면 최근 10일 내 소멸한 태풍(여파 참고용) 또는 "영향 없음"을 표시합니다.
4. **원자재 수급** — PP/PE 가격·수급, 국내 목재 수급(수종별) 관련 최신 뉴스 헤드라인

## Files

- `Update-WorkDashboard.ps1` — fetches everything above and renders `template.html` into
  `dashboard.html`.
- `config.json` — weather locations (lat/lon) and material news search queries. Edit this to
  add/remove a location or change a search query.
- `template.html` — the dashboard UI.
- `run.bat` — double-click launcher (bypasses PowerShell execution-policy prompts).
- `dashboard.html` — generated output, opened automatically after each run. Not tracked in git.
- `email-summary.html` / `email-subject.txt` — generated daily email body/subject. Written every
  run for local preview; actually *sending* it only happens in the GitHub Actions workflow. Not
  tracked in git.

## Usage

Double-click `run.bat`, or:

```powershell
powershell -ExecutionPolicy Bypass -File Update-WorkDashboard.ps1
```

### Adding/changing a weather location

Edit `config.json` → `weatherLocations`. Each entry needs `Id`, `DisplayName`, `Country`, `Lat`,
`Lon`. Coordinates only need to be roughly right — wttr.in resolves to the nearest weather
station.

### Changing the typhoon-watch hubs

Edit `config.json` → `typhoonWatchHubs` (currently 하노이/호치민). A GDACS tropical cyclone is
shown if it either lists Vietnam among its affected countries, or its current/last position is
within 800km of any hub — adjust that radius in `Get-TyphoonWatch` in
`Update-WorkDashboard.ps1` if it's too wide/narrow.

### Changing material search queries

Edit `config.json` → `materials`. Each entry's `NewsQueries` array is a list of Google News
search terms; results across all queries are de-duplicated and capped at 8 headlines per card.

## Notes

- Requires only Windows PowerShell 5.1 — no Python/Node/npm.
- `.ps1` files must stay saved as **UTF-8 with BOM**, or Windows PowerShell 5.1 misreads the
  Korean text and fails to parse the script.
- PP/PE 가격 및 목재 수급은 실시간 수치 API가 아니라 뉴스 헤드라인 기반입니다 (정부 공식 API는
  data.go.kr 회원가입+활용신청이 필요해 우선 제외함 — 나중에 키를 발급받으면 실제 가격 수치로
  교체 가능).

## Email summary (GitHub Actions only)

The daily workflow (`.github/workflows/update-dashboard.yml`) emails `email-summary.html` to
`jhyupkim@unid.co.kr` via Gmail SMTP after each run — same setup as the
[stockdashboard](https://github.com/JHKim0603/stockdashboard) repo, reusing the same Gmail
sending account (add the secrets to *this* repo too, since GitHub repo secrets aren't shared
across repos):

1. Repo **Settings → Secrets and variables → Actions → New repository secret**, add:
   - `GMAIL_USERNAME` — the sending Gmail address
   - `GMAIL_APP_PASSWORD` — the 16-character Gmail App Password
2. To change the recipient, edit the `to:` line in the workflow's "Send email summary" step.

Local runs (`run.bat`) still generate `email-summary.html` for preview but never send it — only
the Actions workflow has the secrets.
