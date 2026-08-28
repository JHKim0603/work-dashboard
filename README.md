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
   위한 섹션. 판정은 **태풍의 전체 경로**(GDACS 이벤트별 geometry)를 기준으로 하며, 영향을 두
   종류로 구분합니다.

   - **직접** — 베트남이 피해국에 포함되거나 경로가 하노이/호치민 500km 이내
   - **항로** — 경로가 남중국해 항로를 통과하거나 환적항(홍콩·선전 / 가오슝 / 상하이·닝보)
     400km 이내

   활성 태풍이 있으면 경고를 띄우고, **활성 여부와 무관하게 최근 발생 이력 6건을 "N일 전"과 함께**
   항상 표시합니다 — 지난 태풍이 언제였는지 알면 다음 시기를 가늠할 수 있기 때문입니다.

   > **왜 "항로"까지 보는가:** 초기 버전은 GDACS가 알려주는 *마지막 위치* 한 점만 보고
   > 하노이/호치민 800km 이내인지 따졌습니다. 그 결과 2026년 8월 현지 업체가 실제로 지연을
   > 통보한 태풍들을 전부 놓쳤습니다 — NOUL-26은 남중국해를 건너 **홍콩/선전 78km**를
   > 지났고, DOLPHIN-26과 SAUDEL-26은 대만·상하이 쪽을 훑었습니다. 셋 다 베트남에
   > 상륙하지 않아 피해국 목록에 없고 최종 위치도 베트남에서 1,200km 넘게 떨어져 있지만,
   > 베트남 화물이 거쳐가는 환적항을 직격해 선적 일정을 밀어냅니다.
4. **원자재 · 물류 가격** — 각 카드는 **차트 위에 마우스를 올리면 해당 시점의 날짜와 가격**이
   툴팁으로 표시됩니다 (터치도 지원). 카드의 **"상세 ↗"** 버튼을 누르면 팝업이 열려
   ① 큰 차트 ② 1/3/6개월·1년 변화율 ③ 자동 생성한 추이 해설 ④ **가격 변동 배경 뉴스**를
   함께 보여줍니다. 해설은 시계열에서 계산한 요약이고 뉴스는 해당 품목 검색 결과라,
   기사와 가격 움직임의 인과관계가 검증된 것은 아닙니다.

   | 항목 | 출처 | 주기 | 형태 |
   |------|------|------|------|
   | 컨테이너 운임지수 (SCFI) | Shanghai Shipping Exchange | 주간 | 값 + 전주비, **누적 3주부터 차트** |
   | 국제유가 WTI / 브렌트 | Yahoo Finance 선물 | 주간 종가 2년 | 차트 |
   | 미국산 목재 (CME 제재목 선물) | Yahoo Finance | 주간 종가 2년 | 차트 |
   | KCl (염화칼륨) | World Bank Pink Sheet | 월간 30개월 | 차트 |
   | 국내 경유·휘발유 (전국평균) | 한국석유공사 오피넷 | 일간 | 차트 (**누적**) |

5. **수급 뉴스** — 수산화칼륨(KOH)·탄산칼륨(K2CO3), 폴리프로필렌(PP)·폴리에틸렌(PE), 국내 목재 관련 헤드라인.

### 시계열 누적 (`data-history.json`)

오피넷은 **최근 7일**만, SSE의 SCFI는 **이번 주·전주 2개 값**만 내려줍니다. 두 곳 모두 과거
데이터를 한 번에 받아올 방법이 없어서(SCFI 이력은 구독 계정 전용), 대신 **매 실행마다 그때
받은 값을 `data-history.json`에 병합해 저장소에 커밋**합니다. 날짜를 키로 쓰기 때문에 같은 날
여러 번 돌려도 중복되지 않고, 워크플로가 매일 도는 한 시계열이 알아서 길어집니다.

- 보관 기간: 730일 (그보다 오래된 값은 자동 정리)
- 워크플로의 `Commit accumulated history` 단계가 변경분을 저장소에 되커밋합니다
- 그래서 **오피넷 1년치 그래프는 지금부터 하루씩 쌓여 만들어집니다** — 과거분을 소급해
  채울 무료 소스는 없습니다

### 수동 업데이트 버튼

대시보드는 **정적 페이지**라 모든 숫자가 생성 시점에 파일에 박혀 들어갑니다. 따라서 브라우저
버튼만으로는 값을 새로 못 가져오고, 실제로는 **생성 스크립트를 다시 돌려야** 전체 가격이
그날 기준으로 갱신됩니다. 우측 상단 **"🔄 지금 업데이트"** 버튼은 GitHub Actions의
workflow_dispatch 화면을 여는 링크이고, 거기서 **Run workflow**를 누르면 약 1분 뒤 모든
데이터(날씨·태풍·유가·목재·KCl·SCFI·뉴스)가 새로 수집되어 페이지가 다시 배포됩니다.

> 버튼이 한 번에 실행되지 않고 GitHub로 보내는 이유: 워크플로를 페이지에서 직접 트리거하려면
> GitHub 토큰이 필요한데, 이 저장소는 public이라 토큰을 페이지에 넣으면 그대로 노출됩니다.

로컬에서는 `run.bat` 더블클릭이 같은 일을 합니다. 상단의 "데이터 기준" 표기는 경과 시간을
같이 보여주며, **하루가 지나면 빨간색**으로 바뀌어 오래된 페이지를 최신으로 착각하지 않게 합니다.

### 국내 유가 (오피넷 키)

경유·휘발유 카드는 무료 오피넷 API 키로 동작합니다 (1,500 calls/day).
**저장소 시크릿 `OPINET_API_KEY`는 이미 등록되어 있어 Actions 실행 시 자동으로 채워집니다.**

로컬에서 `run.bat`으로 돌릴 때만 환경변수를 직접 넣어주면 됩니다:

```powershell
$env:OPINET_API_KEY = "발급받은키"
.\run.bat
```

> 키는 저장소 파일에 절대 넣지 마세요 — 이 저장소는 public입니다. 키는 GitHub Actions
> 시크릿에만 두고, 스크립트는 `$env:OPINET_API_KEY`로만 읽습니다. 생성되는 `dashboard.html`
> 에는 가격 값만 들어가고 키는 포함되지 않습니다.
>
> 키를 교체하려면: `gh secret set OPINET_API_KEY --repo JHKim0603/work-dashboard`

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

### KOH·K2CO3 가격을 그래프로 못 넣은 이유

수산화칼륨·탄산칼륨은 **가격 데이터 자체가 유료 구독 상품**이라 무료 시계열이 존재하지 않습니다.

| 소스 | 결과 |
|------|------|
| World Bank Pink Sheet | KCl은 있으나 **KOH·K2CO3 항목 없음** |
| businessanalytiq | 차트가 **Google Looker Studio 임베드** — 스크립트 접근 불가 |
| ECHEMI | 페이지 콘텐츠 **난독화 + 봇 차단** |
| ChemAnalyst / Intratec / IMARC / price-watch / Tridge | **전량 유료 구독** |

대신 **KCl 차트를 원가 지표로 쓸 수 있습니다.** KOH는 염화칼륨 수용액 전기분해로, K2CO3는
그 KOH에 CO2를 반응시켜 만들기 때문에 KCl이 두 제품 공통의 원료입니다. KCl 카드에도 그렇게
표기해 두었고, KOH·K2CO3 카드에서 해당 차트를 참고하도록 안내합니다.

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
sending account. **`GMAIL_USERNAME`과 `GMAIL_APP_PASSWORD`는 이 저장소에 등록되어 있어
발송까지 정상 동작합니다.** (GitHub 저장소 시크릿은 저장소 간에 공유되지 않으므로, 두
저장소가 같은 Gmail 계정을 쓰더라도 앱 비밀번호는 각각 별도로 발급·등록되어 있습니다.)

- 앱 비밀번호를 교체하려면 [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
  에서 새로 발급한 뒤 `gh secret set GMAIL_APP_PASSWORD --repo JHKim0603/work-dashboard`.
  구글은 발급 시점에 한 번만 값을 보여주므로 기존 값을 다시 읽어올 수는 없습니다.
- 수신자를 바꾸려면 워크플로의 "Send email summary" 스텝에서 `to:` 줄을 수정하세요.
- 메일 발송 스텝은 `continue-on-error: true`라 SMTP가 실패해도 대시보드 배포는 계속됩니다.
  발송 여부는 스텝 로그에서 확인하세요.

Local runs (`run.bat`) still generate `email-summary.html` for preview but never send it — only
the Actions workflow has the secrets.
