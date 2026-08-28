# Work Dashboard

Local reference dashboard for daily work-planning inputs. No backend, no build step — just
PowerShell + a static HTML/JS template.

**Live:** https://jhkim0603.github.io/work-dashboard/ — republished daily by the GitHub Actions
workflow.

상단은 **날씨 / 공휴일 / 태풍**이 가로 3단으로 나란히 놓이고(좁은 화면에서는 세로로 쌓임),
그 아래에 원자재 섹션이 full-width로 들어갑니다.

1. **날씨 / 온습도** — 울산 남구 현재 기온·습도·체감온도 + **7일 예보를 가로 스트립**으로 표시
   (요일별 아이콘, 기온 막대, 최고/최저, 강수확률). 체감/최고기온이 기상청 특보 기준(단순화)을
   넘으면 "폭염주의보/경보", 최저기온이 기준 이하면 "한파주의보/경보" 멘트가 자동으로 붙습니다.
2. **공휴일 · 연휴** — 오늘 이후 가장 빠른 한국 공휴일 연휴 구간(주말과 이어진 실제 연휴 블록), D-day, 이후 공휴일 목록
3. **베트남 태풍 감시** — 베트남에서 들어오는 부자재 입고 일정이 태풍으로 지연되는 걸 미리 파악하기
   위한 섹션. 하노이/호치민 두 거점 기준으로 GDACS가 추적하는 열대저기압 중 베트남 관련(국가
   목록에 포함되거나 두 거점 800km 이내)인 것만 걸러서 보여줍니다. 활성 태풍이 있으면 경고를
   띄우고, **활성 여부와 무관하게 최근 발생 이력 3건을 "N일 전"과 함께** 항상 표시합니다 —
   지난 태풍이 언제였는지 알면 다음 시기를 가늠할 수 있기 때문입니다.
4. **원자재 · 물류 가격** — 각 카드는 **차트 위에 마우스를 올리면 해당 시점의 날짜와 가격**이
   툴팁으로 표시됩니다 (터치도 지원).

   | 항목 | 출처 | 주기 | 형태 |
   |------|------|------|------|
   | 컨테이너 운임지수 (SCFI) | Shanghai Shipping Exchange | 주간 | 값 + 전주비 |
   | 국제유가 WTI / 브렌트 | Yahoo Finance 선물 | 주간 종가 2년 | 차트 |
   | 미국산 목재 (CME 제재목 선물) | Yahoo Finance | 주간 종가 2년 | 차트 |
   | KCl (염화칼륨) | World Bank Pink Sheet | 월간 30개월 | 차트 |
   | 국내 경유·휘발유 | 오피넷 | 최근 7일 | 차트 — **키 필요, 아래 참고** |

5. **수급 뉴스** — 폴리프로필렌(PP)·폴리에틸렌(PE), 국내 목재 관련 헤드라인.

### 국내 유가를 켜려면 (오피넷 키)

경유·휘발유 카드는 무료 오피넷 API 키가 있어야 채워집니다 (1,500 calls/day).

1. [오피넷 유가정보 API](https://www.opinet.co.kr/user/custapi/custApiInfo.do)에서 회원가입 후 키 발급
2. GitHub 저장소 **Settings → Secrets and variables → Actions**에 `OPINET_API_KEY`로 등록
3. 로컬 실행 시에는 환경변수로: `$env:OPINET_API_KEY = "..."` 후 `run.bat`

키가 없으면 해당 카드가 안내 문구로 대체될 뿐, 나머지는 정상 동작합니다.

### PP/PE 가격을 그래프로 못 넣은 이유

무료·무인증 수치 시계열이 없습니다. 확인한 소스는 다음과 같습니다.

| 소스 | 결과 |
|------|------|
| World Bank Pink Sheet | 원유·KCl·열대산 원목은 있으나 **PP/PE 항목 자체가 없음** |
| data.go.kr 석유화학 원자재가격동향 | PP/PE 있으나 **회원가입 + 활용신청(키 발급) 필요** |
| SunSirs / 100ppi (중국 상품 데이터) | PP/PE 일별 가격 있으나 **봇 차단(브라우저 챌린지)** — 스케줄 스크립트 접근 불가 |
| FRED (미국 PPI) | 해당 수지 시리즈 **빈 응답** |

→ data.go.kr 키를 발급받으면 PP/PE도 다른 항목과 같은 차트로 교체할 수 있습니다.

국내 목재(수종별) 역시 산림청·임산물유통정보시스템에 **API가 없고**(웹 화면 + 엑셀 수동
다운로드만), KOSIS는 키가 필요한 데다 대부분 연간 단위라 월별 추이를 만들 수 없습니다.
대신 **미국산 제재목 선물(CME)**을 국제 목재 시세 지표로 넣었습니다.

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
`Lon`. Coordinates only need to be roughly right — Open-Meteo resolves to the nearest grid point.
Note that the 7-day strip assumes one wide card per location.

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
