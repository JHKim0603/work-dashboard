import sys, zipfile, re
from xml.etree import ElementTree as ET
z = zipfile.ZipFile(sys.argv[1])
names = sorted(n for n in z.namelist() if re.match(r'Contents/section\d+\.xml$', n))
out = []
for n in names:
    root = ET.fromstring(z.read(n))
    for p in root.iter():
        if p.tag.endswith('}p'):
            t = ''.join(x.text or '' for x in p.iter() if x.tag.endswith('}t'))
            if t.strip():
                out.append(t)
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out))
print(len(out), 'paragraphs')
