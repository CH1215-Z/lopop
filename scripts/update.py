"""data.json 에 새로 추첨된 로또 6/45 회차를 추가합니다.

GitHub Actions 가 매주 토요일 밤 자동으로 실행합니다.
1순위: 동행복권 공식 조회 주소, 2순위: 공개 데이터 저장소(smok95/lotto).
새 회차가 없으면 아무것도 바꾸지 않습니다.
"""
import json
import sys
import urllib.request
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data.json"
UA = {"User-Agent": "Mozilla/5.0 (lotto-lab updater)"}


def get_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def from_official(no):
    d = get_json(f"https://www.dhlottery.co.kr/common.do?method=getLottoNumber&drwNo={no}")
    if d.get("returnValue") != "success":
        return None
    nums = sorted(d[f"drwtNo{i}"] for i in range(1, 7))
    return [no, d["drwNoDate"], nums, d["bnusNo"], d.get("firstWinamnt", 0), d.get("firstPrzwnerCo", 0)]


_mirror = None


def from_mirror(no):
    global _mirror
    if _mirror is None:
        rows = get_json("https://raw.githubusercontent.com/smok95/lotto/main/results/all.json")
        _mirror = {r["draw_no"]: r for r in rows}
    r = _mirror.get(no)
    if not r:
        return None
    first = r["divisions"][0] if r.get("divisions") else {}
    return [no, r["date"][:10], sorted(r["numbers"]), r["bonus_no"], first.get("prize", 0), first.get("winners", 0)]


def valid(row, no):
    n, b = row[2], row[3]
    return (row[0] == no and len(n) == 6 and len(set(n)) == 6
            and all(1 <= x <= 45 for x in n + [b]) and b not in n)


def fetch(no):
    for src in (from_official, from_mirror):
        try:
            row = src(no)
            if row and valid(row, no):
                print(f"{no}회: {src.__name__} → {row[2]} + {row[3]}")
                return row
        except Exception as e:  # 한 곳이 막혀도 다른 곳을 시도
            print(f"{no}회: {src.__name__} 실패 ({e})")
    return None


def main():
    data = json.loads(DATA.read_text(encoding="utf-8"))
    assert [r[0] for r in data] == list(range(1, len(data) + 1)), "회차 번호가 이어지지 않아요"
    added = 0
    while True:
        row = fetch(data[-1][0] + 1)
        if not row:
            break
        data.append(row)
        added += 1
    if added:
        DATA.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"추가한 회차: {added}개 / 최신 {data[-1][0]}회")
    return 0


if __name__ == "__main__":
    sys.exit(main())
