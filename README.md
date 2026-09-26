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
   (요일 포함), 그 아래 **베트남·중국 휴무**(아래 `foreignHolidayCalendars` 참고).

   > Nager.Date 는 대체공휴일을 **원래 이름으로, 원래 날짜는 빼고** 줍니다('개천절 10/05').
   > 양력 고정일 공휴일은 날짜가 다르면 `개천절 대체공휴일` 로 고쳐 적습니다. 설날·추석·부처님
   > 오신 날은 음력이라 이 방식으로 가릴 수 없어 그대로 둡니다.
3. **베트남 태풍 감시** — 베트남에서 들어오는 부자재 입고 일정이 태풍으로 지연되는 걸 미리 파악하기
   위한 섹션. 판정은 **태풍의 전체 경로**(GDACS 이벤트별 geometry)를 기준으로 하며, 화물이 지나는
   구간을 세 가지로 나눠 봅니다.

   - **출발지(직접)** — 베트남이 피해국에 포함되거나 경로가 하노이/호치민 500km 이내
     (`typhoonWatchHubs`)
   - **항로** — 경로가 남중국해 항로를 통과하거나 환적항(홍콩·선전 / 가오슝 / 상하이·닝보)
     400km 이내 (`typhoonTransshipHubs`)
   - **도착지** — 경로가 국내 입항 항만(부산 / 울산 / 광양 / 인천) 400km 이내
     (`typhoonArrivalHubs`). 47년치 경로 통계로 연 4.0건이 이 안에 들어오고, 그중 1.6건은
     베트남·항로 어디에도 걸리지 않습니다. 이미 바다에 있는 화물은 피해 갈 수 없어서 배지
     색은 출발지 > 도착지 > 항로 순으로 정합니다.

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

   표시 순서는 `config.json`의 `cardOrder` 배열 하나가 결정합니다. 대시보드와 메일이 같은
   배열을 읽으므로 이것만 고치면 양쪽이 함께 바뀝니다.

   | 순서 | 항목 | 출처 | 주기 |
   |------|------|------|------|
   | 1 | KCl (염화칼륨) | World Bank Pink Sheet | 월간 30개월 |
   | 2 | 원/달러 환율 | Yahoo Finance (`KRW=X`) | 주간 2년 |
   | 3 | 컨테이너 운임지수 (SCFI) | Shanghai Shipping Exchange | 주간, **누적 3주부터 차트** |
   | 4 | CCFI 항로별 운임지수 | Shanghai Shipping Exchange | 주간, 6개 항로 |
   | 5 | 산업용 전기요금 | EPSIS 계약종별 판매단가 | 연간 |
   | 6 | 가성소다 (NaOH) | 정저우상품거래소(CZCE) · Sina | 주간 2년 |
   | 7-8 | 국내 경유·휘발유 (전국평균) | 한국석유공사 오피넷 | 일간 (**누적**) |
   | 9-10 | 폴리프로필렌(PP) / 폴리에틸렌(LLDPE) | 대련상품거래소(DCE) · Sina | 주간 2년 |
   | 11-12 | 국제유가 WTI / 브렌트 | Yahoo Finance 선물 | 주간 2년 |
   | 13 | 기초무기화합물 물가지수 | 한국은행 ECOS | 월간 24개월 |

   SCFI와 CCFI 카드는 페이지에서 별도로 조립되므로 `cardOrder` 값이 정렬 키로 주입됩니다 -
   배열에서 위치를 옮기면 페이지와 메일 양쪽에서 함께 움직입니다.

   **카드 설명**: 각 카드의 `상세 ↗` 팝업 맨 위에 "이 숫자는 무엇인가"가 붙습니다. 무엇을 재는
   숫자인지, 왜 이 책상에 올라오는지, **하면 안 되는 해석**이 무엇인지 순으로 적혀 있고, 문구는
   `config.json`의 `cardAbout`에서 id별로 관리합니다.

   **비교 기준 표기**: ▲/▼ 옆에 무엇과 비교했는지 적습니다(`7월 대비`, `9/17 대비`, `2024년 대비`).
   카드마다 직전 점 간격이 하루~1년이라, 적지 않으면 전기요금의 1년치 +8.2% 가 옆 경유의 하루치
   -0.1% 와 같은 모양으로 보입니다. '전주' 처럼 추정하지 않고 **직전 점의 날짜**로 적습니다 —
   Yahoo 주간 계열은 진행 중인 봉으로 끝나서 직전 점이 지난주가 아닐 수 있습니다.

   - 숫자는 천 단위 구분 + 끝자리 0 제거로 통일(`1355.28` → `1,355.28`, `18.00` → `18`)
   - 변동이 0.05% 미만이면 `보합` (메일과 같은 규칙)
   - 카드 차트는 팝업과 다른 **320 폭 viewBox**를 씁니다. 둘이 560 폭 하나를 공유하던 때는
     카드(약 300px)에서 축 글씨가 5px 가까이로 줄어 읽을 수 없었습니다

   **CCFI 항로별 추이**: 항로 지수도 SCFI 처럼 이번 주·전주 두 값만 공개되므로 항로마다
   `data-history.json`에 쌓고, 3주가 모이면 상세 팝업에 항로별 차트를 그립니다(카드에는 누적
   주수 표시). 합성지수는 유럽·미주 비중이 커서 이 화물이 실제로 타는 동남아 항로가 움직여도
   드러나지 않기 때문입니다.

5. **수급 뉴스** — 유니드 회사 동향, 화학공장 중대재해·안전 관련 헤드라인.

   > 원래는 KOH·K2CO3와 국내 목재 검색이었는데, 2주간 한국 기사가 각각 0건과 1건이라 카드가
   > 최신일 수 없었습니다. 기사가 존재하는 검색어로 바꿨습니다. 뉴스는 `when:` 윈도우로 최근
   > 기사만 남기고, 날짜를 못 읽는 항목은 버립니다 — 최신성이 이 카드의 전부이기 때문입니다.

### 관세청 수입 단가 — 원자재 추가용 (`customsSeries`)

`config.json`의 `customsSeries`에 항목을 넣으면 **코드 수정 없이** 카드가 생깁니다. 지금은 비어
있어 아무것도 조회하지 않습니다. 관세청 API는 금액과 중량을 주므로 **수입금액 ÷ 수입중량**으로
USD/톤 단가를 계산합니다 — 해외 벤치마크가 아니라 **한국이 실제로 지불한 값**이라는 게 이 소스의
가치입니다.

```json
"customsSeries": [
  { "Id": "occ", "DisplayName": "고지(OCC) 수입단가", "HsSgn": "4707" },
  { "Id": "spf", "DisplayName": "캐나다산 S-P-F", "HsSgn": "440713", "CntyCd": "CA" }
]
```

- 필수: `Id`, `DisplayName`, `HsSgn` (4·6·10자리 모두 가능)
- 선택: `CntyCd`(ISO 국가코드), `StatKorMatch`(품목명 부분일치), `Unit`, `Note`, `NewsQuery`
- `DATA_GO_KR_KEY` 시크릿이 없으면 오피넷 카드처럼 조용히 건너뜁니다

**실측 확인된 HS 코드** (2025-08~2026-07 기준):

| HS | 품목 | 연간 수입 | 단가 |
|----|------|----------|------|
| `4707` | 회수 지·판지(고지·OCC) | 713,979톤 | 192~226 USD/톤 |
| `4804` | 크라프트지·판지 | 281,434톤 | 853~938 USD/톤 |
| `4805` | 기타 종이·판지(골판지 원지 계열) | 191,575톤 | 773 USD/톤 |
| `440711`+`CL`/`NZ` | 소나무 제재목(라디에타 파인) | 칠레 34천톤/2개월 | 290~305 USD/톤 |
| `440713`+`CA` | 캐나다산 S-P-F | 15,297톤 | 686~877 USD/톤 |

> **넣기 전에 알아야 할 것.** 월 1회 발표에 **약 1개월 지연**입니다 — 2026-08-28에 조회 가능한
> 최신 월은 2026-07이었습니다. 대시보드에서 가장 느린 축(KCl과 동급)이므로 **선행지표가 아니라
> 사후 확인용**입니다. 빠른 판단을 이 위에 올리지 마세요.
>
> 조회 기간은 **1회 호출당 1년 이내**로 제한됩니다. 더 긴 시계열은 연 단위로 나눠 호출해야 합니다.
>
> 오퍼레이션명 `getNitemtradeList`가 빠지면 `NO_OPENAPI_SERVICE_ERROR`가 납니다.
>
> 존재하지 않는 HS 코드도 `정상서비스`로 응답하면서 `impDlr=0`·`impWgt≠0` 행을 돌려줍니다.
> 중량만 검사하면 0 USD/톤짜리 카드가 그럴듯하게 생기므로 **금액과 중량을 함께** 봐야 합니다.

### 미국산 목재(CME) 카드를 뺀 이유

`LBR=F`는 **북미 주택건설용 SPF 랜덤렝스** 벤치마크라 미국 주택착공에 연동되고, 국내에서 쓰는
미송·낙엽송과는 상관이 약합니다. 게다가 팔레트 목재 가격은 구매팀 소관이라 이 대시보드를 보는
사람이 취할 행동이 없었습니다. **행동으로 이어지지 않는 카드는 나머지 카드를 묻히게 합니다.**

목재 단가가 다시 필요해지면 위 `customsSeries`에 HS 코드를 넣는 쪽이 정확합니다 — 선물 대용치가
아니라 실제 수입 단가이고, 수종·원산지별로 갈립니다.

### 베트남·중국 휴무 (`foreignHolidayCalendars`)

공휴일 카드 아래에 베트남·중국 휴무가 붙습니다. 부자재가 나오는 곳과 화물이 환적되는 곳이 한
주씩 멈추는 시기(뗏·춘절·국경절)를 보기 위한 것입니다. 30일 이내이거나 3일 이상인 연휴를 먼저
보여주고, 3일 이상 연휴가 10일 안으로 다가오면 메일 제목에 붙습니다(`중국 국경절 D-6`).

출처는 **Google 캘린더 공개 공휴일 피드**(키 없음)이고, 날마다 `Public holiday` / `Observance`
구분이 있어 실제 휴무일만 씁니다.

> **Nager.Date 를 쓰지 않는 이유:** 한국 카드는 Nager.Date 를 쓰지만, 2026-09 확인 당시 베트남
> 2027년에 **뗏이 아예 없었고** 중국 국경절은 10/7까지가 아니라 **10/1 하루**였습니다. 되돌리지
> 마세요.

### 기준가 (계약·예산 단가) — 메일 전용

카드별 기준가를 넣으면 메일의 그 카드에 `계약가 $370 대비 +4.6%` 가 붙고, 새 시점 값이
`alertPct` 이상 벗어나면 메일 제목에도 올라갑니다.

```powershell
gh secret set CARD_TARGETS_JSON --repo JHKim0603/work-dashboard --body '{"kcl":{"ref":370,"label":"계약가","alertPct":3}}'
```

- 키는 카드 id(`kcl`, `usdkrw`, `naoh`, `pp`, `pe`, `wti`, `D047` …), `label` 기본값은 `기준가`,
  `alertPct` 기본값은 5
- **페이지에는 절대 나오지 않습니다.** 이 저장소와 페이지는 public 이고 계약 단가는 사내
  자료이므로, 값은 Actions 시크릿에만 두고 메일(수신자 한 명)에서만 씁니다. `config.json` 에
  넣지 마세요
- 로컬 실행은 `secrets.local.json` 에 `"CARD_TARGETS_JSON": { "kcl": { "ref": 370 } }` 형태로

### 카드별 급변 기준 (`cardAlertPct`)

메일 제목의 가격 급변 표시는 기본 5% 입니다. 카드마다 바꾸려면 `config.json` 에
`"cardAlertPct": { "kcl": 3, "usdkrw": 2 }` 처럼 넣습니다. 비율만 담으므로 공개돼도 됩니다.

### 실행 시간 (2026-09 최적화)

한 번 실행에 **84초** 걸리던 것을 **약 25초**로 줄였습니다(같은 PC에서 로컬 측정, 요청마다 시간을
재서 원인을 찾은 결과). 페이지 쪽은 손대지 않았습니다 — 압축 56KB, 이 노트북 크롬에서 화면 완성
60ms 로 이미 충분히 가볍습니다.

| 원인 (최적화 전) | 조치 |
|---|---|
| 태풍 경로 조회 11건 = **45초** (한 건 2.5~7.7초) | 끝난 태풍의 경로를 `typhoon-tracks.json` 에 캐시. 진행 중인 태풍만 매번 조회 |
| 구글 뉴스 23건을 하나씩 + 사이마다 0.3초 = 약 17초 | 주소를 미리 모아 **3건씩 동시에** 받아 두고(`Invoke-Prefetch`), 받은 것은 쉬지 않고 바로 씀 |

- **끝난 태풍만 캐시하는 이유:** 끝난 태풍의 마지막 에피소드는 다시 바뀌지 않지만, 진행 중인
  태풍은 에피소드마다 경로와 예보가 바뀝니다. 캐시는 이번 실행에서 쓴 태풍만 남겨 자라지 않고,
  내용이 같으면 파일을 쓰지 않아 커밋도 새 태풍이 들어올 때만 생깁니다. GDACS 가 느리거나 죽은
  날에도 지난 태풍 이력이 경로 기준 판정을 유지하는 부수 효과가 있습니다.
- **동시 조회가 실패하면:** 실패한 주소(429/503 포함)는 받아 두지 않으므로 원래의 순차 경로가
  재시도와 함께 처리합니다 — 이 층이 망가져도 느려질 뿐 결과가 비지 않습니다. 동시 3건으로 묶은
  것은 러너 IP 를 Google 이 빡빡하게 조이기 때문입니다.
- 같은 사이트에 연달아 보내는 요청 사이의 짧은 대기(Yahoo, SSE 운임, Sina)는 차단 방지용이라
  그대로 둡니다.

### 시계열 누적 (`data-history.json`)

오피넷은 **최근 7일**만, SSE의 SCFI는 **이번 주·전주 2개 값**만 내려줍니다. 두 곳 모두 과거
데이터를 한 번에 받아올 방법이 없어서(SCFI 이력은 구독 계정 전용), 대신 **매 실행마다 그때
받은 값을 `data-history.json`에 병합해 저장소에 커밋**합니다. 날짜를 키로 쓰기 때문에 같은 날
여러 번 돌려도 중복되지 않고, 워크플로가 매일 도는 한 시계열이 알아서 길어집니다.

- 보관 기간: 730일 (그보다 오래된 값은 자동 정리)
- 워크플로의 `Commit accumulated history` 단계가 변경분을 저장소에 되커밋합니다
- 그래서 **오피넷 1년치 그래프는 지금부터 하루씩 쌓여 만들어집니다** — 과거분을 소급해
  채울 무료 소스는 없습니다
- CCFI 항로 6개도 같은 파일에 항로 id별로 쌓입니다
- 카드별 `lastSeen`은 **라벨(시점)이 바뀔 때만** 다시 씁니다. 환율·유가의 마지막 점은 날짜는
  그대로인데 값이 장중에 계속 바뀌어서, 예전엔 하루 여섯 번 실행이 모두 커밋을 만들었습니다

### 메일 제목의 '새 값' 판정 (`mailed-labels.json`)

메일 제목의 가격 특이사항(급변·기준가 이탈)은 **지난 메일에 실린 시점과 비교해** 새 값인지
판단합니다. 스크립트는 매 실행 `mailed-labels.next.json`을 쓰고, 워크플로가 **발송이 확인된
뒤에만** `mailed-labels.json`으로 승격해 커밋합니다(`.last-digest`와 같은 방식).

> 예전에는 직전 실행과 비교했습니다. 실행은 하루 여섯 번이고 메일은 그중 한 번뿐이라, 메일이
> 아닌 실행에 새 값이 들어오면 그 실행이 기준을 덮어써서 다음 날 메일이 '이미 본 값'으로
> 건너뛰었습니다. 발표 시각이 정해지지 않은 월간 KCl·ECOS 는 대부분 어떤 메일에도 실리지
> 못했습니다. 파일이 없거나 거기 없는 카드는 예전처럼 직전 실행 기준으로 떨어집니다.

### 수동 업데이트 버튼

대시보드는 **정적 페이지**라 모든 숫자가 생성 시점에 파일에 박혀 들어갑니다. 따라서 브라우저
버튼만으로는 값을 새로 못 가져오고, 실제로는 **생성 스크립트를 다시 돌려야** 전체 가격이
그날 기준으로 갱신됩니다. 우측 상단 **"🔄 지금 업데이트"** 버튼은 GitHub Actions의
workflow_dispatch 화면을 여는 링크이고, 거기서 **Run workflow**를 누르면 약 1분 뒤 모든
데이터(날씨·공휴일·태풍·원자재·운임·뉴스)가 새로 수집되어 페이지가 다시 배포됩니다.

> 버튼이 한 번에 실행되지 않고 GitHub로 보내는 이유: 워크플로를 페이지에서 직접 트리거하려면
> GitHub 토큰이 필요한데, 이 저장소는 public이라 토큰을 페이지에 넣으면 그대로 노출됩니다.

로컬에서는 `run.bat` 더블클릭이 같은 일을 합니다. 상단의 "데이터 기준" 표기는 경과 시간을
같이 보여주며, **하루가 지나면 빨간색**으로 바뀌어 오래된 페이지를 최신으로 착각하지 않게 합니다.

### 국내 유가 (오피넷 키)

경유·휘발유 카드는 무료 오피넷 API 키로 동작합니다 (1,500 calls/day).
**저장소 시크릿 `OPINET_API_KEY`는 이미 등록되어 있어 Actions 실행 시 자동으로 채워집니다.**

로컬에서 `run.bat`으로 돌릴 때는 `secrets.local.json.example`을 **`secrets.local.json`으로 복사**하고
키를 채워 넣으세요. 이 파일은 `.gitignore`에 있어 커밋되지 않습니다.

```json
{ "OPINET_API_KEY": "발급받은키" }
```

환경변수를 직접 넣어도 됩니다 (환경변수가 우선합니다):

```powershell
$env:OPINET_API_KEY = "발급받은키"
.\run.bat
```

> **이걸 안 하면 로컬 페이지에는 경유·휘발유 카드가 통째로 빠집니다.** 배포된 페이지에는
> 정상적으로 나오기 때문에, 로컬 파일만 보고 "오피넷 연동이 깨졌다"고 오해하기 쉽습니다.
> 로컬 화면을 검토용으로 쓰려면 키를 채워 CI와 같은 화면을 보게 만드는 편이 낫습니다.

> 키는 저장소 파일에 절대 넣지 마세요 — 이 저장소는 public입니다. 키는 GitHub Actions
> 시크릿에만 두고, 스크립트는 `$env:OPINET_API_KEY`로만 읽습니다. 생성되는 `dashboard.html`
> 에는 가격 값만 들어가고 키는 포함되지 않습니다.
>
> 키를 교체하려면: `gh secret set OPINET_API_KEY --repo JHKim0603/work-dashboard`

키가 없으면 해당 카드가 안내 문구로 대체될 뿐, 나머지는 정상 동작합니다.

### PP/PE 가격 — DCE 선물로 해결

**중국 대련상품거래소(DCE) 수지 선물**을 씁니다. Sina의 일봉 API가 키 없이 날짜가 붙은 JSON을
내려주고, PP는 2014년, LLDPE는 2007년까지 거슬러 올라갑니다.

| 심볼 | 품목 | 포장재 용도 |
|------|------|------------|
| `PP0` | 폴리프로필렌 주력연속 | PP밴드, PP마대 |
| `L0` | LLDPE 주력연속 | 스트레치필름, 폴리백, 에어캡 |

> **수치를 조달 단가로 읽지 마세요.** 부가세가 포함된 **중국 내수 선물가(위안/톤)**이지
> 한국 CFR 매입가가 아닙니다. 동북아 수지 시장이 함께 움직이기 때문에 **방향성**이 쓸모 있는
> 것이고, 절대값은 아닙니다. 카드 설명에도 그렇게 적어두었습니다.

앞서 확인했다가 못 쓴 소스는 다음과 같습니다 — 되돌아가지 마세요.

| 소스 | 결과 |
|------|------|
| World Bank Pink Sheet | 89개 품목 전수 확인 — **플라스틱 수지 항목 자체가 없음** (펄프·종이·골판지도 없음) |
| data.go.kr 석유화학 원자재가격동향 | PP/PE 있으나 **회원가입 + 활용신청(키 발급) 필요** |
| SunSirs / 100ppi | **봇 차단(브라우저 챌린지)** — 스케줄 스크립트 접근 불가 |
| FRED (미국 PPI) | 수지 시리즈 **빈 응답** (FRED 자체는 정상 — `DGS10`은 응답함) |
| Sina 실시간 시세 (`hq.sinajs.cn`) | GBK 인코딩에 날짜 필드가 신뢰 불가 — **일봉 API를 쓸 것** |

파싱 시 주의: Windows PowerShell의 `ConvertFrom-Json`은 JSON 배열을 파이프라인에 **객체 하나로**
내보냅니다. `@(... | ConvertFrom-Json)`으로 감싸면 3,000행짜리 배열이 1개 원소 배열이 되어
날짜 필터가 전부 빈 결과를 냅니다. 반드시 **먼저 변수에 담은 뒤** `@()`를 씌우세요.

### KOH·K2CO3 가격을 그래프로 못 넣은 이유

수산화칼륨·탄산칼륨은 **가격 데이터 자체가 유료 구독 상품**이라 무료 시계열이 존재하지 않습니다.

| 소스 | 결과 |
|------|------|
| World Bank Pink Sheet | KCl은 있으나 **KOH·K2CO3 항목 없음** |
| businessanalytiq | 차트가 **Google Looker Studio 임베드** — 스크립트 접근 불가 |
| ECHEMI | 페이지 콘텐츠 **난독화 + 봇 차단** |
| ChemAnalyst / Intratec / IMARC / price-watch / Tridge | **전량 유료 구독** |

대신 세 각도에서 에워쌌습니다. **KCl**은 두 제품 공통의 원료이고(KOH는 염화칼륨 수용액
전기분해, K2CO3는 그 KOH에 CO2 반응), **산업용 전기요금**은 그 전기분해의 비용이며,
**가성소다(NaOH)**는 같은 전해조에서 나오는 대응재라 KOH가 놓이는 판가 환경을 보여줍니다.

### 염소·염산 국내 단가를 못 넣은 이유

전해 공정 부산물인 염소·염산도 **톤당 국내 단가는 무료로 존재하지 않습니다.**

| 소스 | 결과 |
|------|------|
| **관세청 통관 (HS 280110 / 280610)** | 데이터는 나오지만 **쓰면 안 됩니다.** 염소 수출이 1.5~12톤 선적에 톤당 9,000~23,600 USD — 실린더에 담긴 **전자급**입니다. 벌크 염소는 위험물이라 배관·탱크로리로 국내에서만 움직여 통관에 아예 안 잡히고, 이 숫자를 차트로 쓰면 실제와 **두 자릿수 배** 어긋납니다 |
| data.go.kr | 관련 데이터셋 없음 (염산·화학제품 가격·생산자물가 검색 전부) |
| 화학경제연구원 / ChemLocus 등 | 유료 구독 |

대신 **한국은행 ECOS `기초무기화합물` 생산자물가지수**를 넣었습니다 — 염소·염산·가성소다가
한 묶음인 국내 지수입니다. 개별 품목 단가가 아니고 원/톤도 아니라는 한계를 카드 설명에
적어두었습니다.

국내 목재(수종별)는 산림청·임산물유통정보시스템에 **API가 없고**(웹 화면 + 엑셀 수동
다운로드만), KOSIS는 키가 필요한 데다 대부분 연간 단위라 월별 추이를 만들 수 없습니다.
목재 카드 자체를 뺀 경위는 위의 "미국산 목재(CME) 카드를 뺀 이유"를 보세요.

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
- `data-history.json` — accumulated Opinet / SCFI / CCFI-lane series and per-card `lastSeen`,
  committed back by the workflow (see 시계열 누적).
- `.last-digest` / `mailed-labels.json` — KST date and card labels of the last mail that
  actually went out, committed back only after a confirmed send. `mailed-labels.next.json` is
  the per-run candidate and is git-ignored.
- `typhoon-tracks.json` — tracks of storms that have ended, cached so a run does not re-download
  them from GDACS (see 실행 시간). Committed back only when a new storm enters the list.

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

Edit `config.json` → `typhoonWatchHubs` (출발지: 하노이/호치민), `typhoonTransshipHubs` (항로:
홍콩·선전/가오슝/상하이·닝보) or `typhoonArrivalHubs` (도착지: 부산/울산/광양/인천). The whole
GDACS track is checked against them — 500km for 출발지, 400km for 항로·도착지 — plus a
South China Sea crossing test for 항로. The radii are in `Get-TyphoonWatch` in
`Update-WorkDashboard.ps1`.

### Changing material search queries

Edit `config.json` → `materials`. Each entry's `NewsQueries` array is a list of Google News
search terms; results across all queries are de-duplicated and capped at 8 headlines per card.

## Notes

- Requires only Windows PowerShell 5.1 — no Python/Node/npm.
- `.ps1` files must stay saved as **UTF-8 with BOM**, or Windows PowerShell 5.1 misreads the
  Korean text and fails to parse the script.
- JSON injected into the page `<script>` has `</` escaped as `<\/`. pwsh (the runner) doesn't
  escape `<`, so one headline containing `</script>` could blank the whole page. News titles,
  sources and links in the email are HTML-encoded for the same reason.

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

### 자동 발송이 하루 한 번만 나가는 방식

**매일 아침 예약 슬롯 6개**(06:18 / 07:06 / 08:23 / 09:47 / 11:23 / 13:41 KST)가 각각
독립적으로 돕니다. 슬롯 하나가 통과하면 메일이 나가고, 나머지는 페이지만 갱신하고 조용히
지나갑니다. 날씨·공휴일·태풍은 주말에도 멈추지 않으므로 stockdashboard 와 달리 요일을 거르지
않습니다.

왜 4개나 두는가 — GitHub은 부하가 걸리면 예약 실행을 **그냥 버립니다.** 이 워크플로는
`:00`, `:30`에 걸려 있던 3일 동안 **예약 실행이 한 번도 안 됐고**(전체 실행이 전부 수동),
stockdashboard는 같은 큐에서 15분 → 5시간 → 7시간까지 밀렸습니다. 그래서 발송이 특정
슬롯 하나에 의존하지 않게 했습니다. public 저장소는 Actions 사용량이 무제한이라 예비
슬롯 비용은 0입니다.

중복 발송을 막는 것은 **`.last-digest`** 파일입니다. 실제로 메일이 나간 날짜(KST)를 담아
저장소에 커밋되고, 게이트가 이 값을 오늘 날짜와 비교합니다.

> **실행 이력으로 판단하지 않는 이유:** 메일 스텝이 `continue-on-error`라 **발송이 실패해도
> 실행 자체는 success로 남습니다.** 이력을 기준으로 삼으면 뒤 슬롯들이 "오늘은 이미 보냈다"고
> 잘못 판단해 침묵하고, 일시적인 SMTP 오류가 그날 전체 미발송으로 굳어집니다. 마커는 **발송
> 성공 직후에만** 기록되므로, 실패하면 마커가 어제 날짜로 남아 다음 슬롯이 재시도합니다.

수동 실행(`workflow_dispatch`)도 마커를 따릅니다. 오늘 이미 보냈더라도 다시 받으려면 실행
화면에서 **`force_email`**을 켜세요. 예전엔 수동 실행이면 항상 보냈는데, 외부 스케줄러가
dispatch API 로 실행을 걸면 호출마다 메일이 나가 하루 한 번 보장이 깨지기 때문에 바꿨습니다.

히스토리와 마커 커밋은 **메일 발송 이후**에 일어납니다. 그 push가 실패하더라도 메일 발송
여부에는 영향을 주지 못하게 하기 위해서입니다.

### 메일 차트가 페이지 차트와 다르게 만들어진 이유

메일 클라이언트는 SVG·canvas·외부 CSS를 신뢰할 수 없어서 페이지와 같은 방식으로 차트를 그릴
수 없습니다. 가격 추이는 **중첩 테이블 안의 `<td bgcolor>` 막대**로 그리는데, 아웃룩의 Word
렌더러까지 다른 클라이언트와 똑같이 그려주는 형태가 이것뿐이기 때문입니다. 막대마다 위에
스페이서 행을 두어 높이가 `valign` 지원 여부에 의존하지 않게 했습니다.

유니코드 블록 문자(`▁▂▃▄`)를 쓰던 초기 버전은 높이 단계가 8개뿐인 데다 클라이언트가 글꼴을
바꿔치기하면서 baseline이 어긋나, 2년치 주간 종가가 전부 똑같이 밋밋한 덩어리로 도착했습니다.
되돌리지 마세요.

- 막대는 16개로 **버킷 평균**해 줄입니다 — N개마다 샘플링하면 그 사이의 급등락이 통째로 사라집니다
- **막대 개수를 늘릴 때는 메일 용량을 확인하세요.** 막대 하나가 중첩 테이블이라 약 220B이고,
  24개였을 때 차트 9개만으로 45KB(전체 85KB)를 먹어 **Gmail 클리핑 한계 102KB의 83%**까지
  찼습니다. 넘으면 메일 하단(뉴스)부터 `[메시지 잘림]`으로 사라집니다. 베트남·중국 휴무와 기준가가
  붙으며 75KB(74%)까지 올라, 2026-09에 막대 표기를 한 번 더 줄여 **68KB / 67%** 입니다
  (막대 간격을 막대마다의 `padding:0 1px` 대신 바깥 표 `cellspacing=2` 로, 숫자·색 속성은 따옴표
  없이, 태그 사이 줄바꿈은 공백 한 칸으로). 중첩 표와 스페이서 행 구조는 아웃룩 확인을 거친
  모양이라 그대로입니다
- **90KB를 넘으면 실행 화면에 경고**가 뜹니다(Actions 요약의 노란 `warning`). 배포는 막지 않습니다 —
  잘릴 위험이지 틀린 페이지가 아니기 때문입니다. 경고가 보이면 막대 수(`$maxBars`)나 섹션을 줄이세요
- 스케일이 구간 min/max 기준이라 0.5% 표류도 화면을 꽉 채웁니다 → **차트 옆에 구간 값을 항상 표기**
- 변동이 0.05% 미만이면 `보합`으로 적습니다 (예전엔 `-0.0%`로 나와 렌더링 오류처럼 보였습니다)

태풍 경보는 **항로 태풍이면 환적항까지의 거리**를 적습니다. 베트남까지의 거리를 적으면
SAUDEL-26이 "하노이/하이퐁 1223km"로 표시돼 무시해도 되는 정보처럼 읽히지만, 실제로 이
태풍이 지나간 곳은 상하이/닝보 284km 지점이고 그게 선적을 밀어내는 이유입니다.
