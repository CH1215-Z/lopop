# 로또 번호 연구소

로또 6/45 역대 당첨번호 통계와 조건별 번호 뽑기 사이트입니다.
GitHub Pages로 공개되고, GitHub Actions가 매주 토요일 추첨 뒤 `data.json`을 자동으로 업데이트합니다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `index.html` | 사이트 화면 전체 |
| `data.json` | 1회부터 최신 회차까지 당첨번호 |
| `scripts/update.py` | 새 회차를 가져와 `data.json`에 추가 |
| `.github/workflows/update.yml` | 토요일 21:40, 23:40, 일요일 10:00(한국시간)에 `update.py` 자동 실행 |

## 처음 올리는 방법 (웹 브라우저만 사용)

1. GitHub에서 **New repository**를 누르고, 이름을 예를 들어 `lotto`로 정한 뒤 **Public**으로 만듭니다.
2. 새 저장소에서 **Add file → Upload files**를 누르고 `index.html`, `data.json`, `README.md`를 끌어다 놓은 뒤 **Commit changes**를 누릅니다.
3. 다시 **Add file → Create new file**을 누르고 파일 이름 칸에 `scripts/update.py`를 입력합니다. 그리고 `update.py` 내용을 그대로 붙여 넣고 저장합니다.
4. 같은 방법으로 파일 이름 `.github/workflows/update.yml`을 만들고 `update.yml` 내용을 붙여 넣어 저장합니다.
   (`.github`처럼 점으로 시작하는 폴더는 컴퓨터에서 숨김 폴더라 끌어다 놓기로는 빠지기 쉬워서, 직접 만드는 게 안전합니다.)
5. **Settings → Pages**에서 Source를 **Deploy from a branch**, Branch를 **main / (root)**로 정하고 **Save**를 누릅니다.
6. 1~2분 뒤 `https://<내 아이디>.github.io/lotto/`에서 사이트가 열립니다.

## 자동 업데이트 확인

- **Actions** 탭에서 "당첨번호 자동 업데이트"를 고르고 **Run workflow**를 누르면 바로 한 번 실행해 볼 수 있습니다.
- 새 회차가 있으면 `data.json`이 바뀐 커밋이 자동으로 생기고, 사이트에 1~2분 안에 반영됩니다.
- 새 회차가 없으면 "새 회차 없음"만 남기고 끝납니다.
- 저장소에 60일 동안 아무 활동이 없으면 GitHub가 예약 실행을 멈출 수 있습니다. 매주 업데이트 커밋이 생기므로 보통은 문제없지만, 멈췄다면 Actions 탭에서 다시 켜 주세요.
