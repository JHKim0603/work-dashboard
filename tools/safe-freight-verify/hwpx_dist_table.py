# 고시 전문(hwpx)의 '거리(km)별 운임(왕복)' 표를 행 단위로 읽는다. 구간거리 -> (왕복거리, 40위탁, 40운사, 40운송, 20위탁, 20운사, 20운송)
import sys, zipfile, re, json
from xml.etree import ElementTree as ET
def cell_text(tc):
    return ''.join(x.text or '' for x in tc.iter() if x.tag.endswith('}t')).strip()
def rows(path):
    z = zipfile.ZipFile(path)
    for n in sorted(n for n in z.namelist() if re.match(r'Contents/section\d+\.xml$', n)):
        root = ET.fromstring(z.read(n))
        for tbl in root.iter():
            if not tbl.tag.endswith('}tbl'): continue
            for tr in tbl:
                if not tr.tag.endswith('}tr'): continue
                yield [cell_text(tc) for tc in tr if tc.tag.endswith('}tc')]
out = {}
for r in rows(sys.argv[1]):
    if len(r) == 8 and all(re.fullmatch(r'[\d,]+', c or 'x') for c in r):
        v = [int(c.replace(',', '')) for c in r]
        if v[0] in out: break          # 시멘트 표 등 다음 표가 시작되면 멈춘다
        out[v[0]] = v[1:]
json.dump(out, open(sys.argv[2], 'w'))
ks = sorted(out); print(len(out), 'rows', ks[:3], ks[-3:])
