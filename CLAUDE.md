# work-dashboard 작업 안내

세 대시보드가 함께 따르는 규칙은 아래 파일에 있습니다. 먼저 읽고 따릅니다.

@DASHBOARD-RULES.md

## 이 저장소

- 이름: **물류팀 운영 참고지표 Dashboard**(화면 제목, 메일 제목·머리, 보내는 사람, 주간 보고 머리글). 물류 업무 참고용입니다.
- 페이지: https://jhkim0603.github.io/work-dashboard/ (경영진 요약 화면은 `?view=exec`), 기본 가지는 `main` 입니다.
- 주요 파일
  - `Update-WorkDashboard.ps1`: 운임·원자재·환율·날씨·일정·태풍·뉴스를 받아 `dashboard.html` 과 매일 메일을 만듭니다.
  - `template.html`: 화면. 자료는 `__…_JSON__` 자리표시자에 들어갑니다.
  - `config.json`: 지표, 지역, 일정, 내륙운송료(안전운임) 설정.
  - `tools/safe-freight-verify/`: 내륙운송료 판정 검증 도구(고시 원문 대조).
  - `news-filter.ps1`, `mail_charts.py`: stockdashboard 와 똑같은 파일입니다. 고치면 두 저장소를 같이 고칩니다.

## 실행과 확인

- 로컬 실행(Windows PowerShell 5.1, 브라우저를 열지 않음, 약 3~5분): `$env:CI = "1"; .\Update-WorkDashboard.ps1`
  로컬에는 오피넷 키가 없으면 경유·휘발유 계열이 빠지는 것이 정상입니다(`secrets.local.json.example` 참고).
- 로컬 실행 뒤 되돌릴 파일(봇이 관리): `data-history.json`, `typhoon-tracks.json`, `mailed-labels.json`, `.last-digest`
- 시험 실행: `gh workflow run update-dashboard.yml -R JHKim0603/work-dashboard -f send_email=false`
- 메일 본문은 90KB 를 넘으면 실행 화면에 경고가 뜹니다. 막대나 표를 늘릴 때 용량을 확인합니다.

## 이 저장소의 색과 표현

- 색은 비용 기준입니다. 비용이 오르면 빨강(`--bad`), 내리면 초록(`--good`)입니다.
- 함께 보기처럼 여러 지표를 겹치는 선에는 빨강과 초록을 쓰지 않습니다(파랑, 주황, 보라, 노랑, 분홍).
- 판정 이름은 상승, 하락, 보합, 상승 후 조정, 하락 후 반등입니다. 1개월과 3개월 변화를 지표마다 평소 움직임과 비교해 정합니다.
- 예상 범위가 지금 값의 30% 를 넘으면 숫자 대신 '예측 어려움'으로 적습니다(화면과 메일 같음).
- 메일 순서는 화면 구역과 같습니다: [핵심 지표] → 수집 실패 → [주간 보고] → [날씨·일정·태풍] → [수급 뉴스].
- 표의 이름 아래 작은 글씨는 눈여겨볼 위치(1년 최고·최저, 몇 년 중 상위·하위 10% 안)와 연속 기록만 적습니다.
