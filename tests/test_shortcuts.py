"""Tests for the binary-VDF codec behind `deckdroid shortcuts`.

shortcuts.vdf is a file Steam owns and the user's hand-made entries live in it,
so a codec bug means silently eating someone's library. These lock down the
round-trip and the merge filter that decides what we are allowed to replace.
"""

import importlib.util
import struct
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / 'src' / 'deckdroid-shortcuts'


def load():
  spec = importlib.util.spec_from_loader('deckdroid_shortcuts', loader=None)
  mod = importlib.util.module_from_spec(spec)
  body = SRC.read_text().split('if __name__')[0]
  exec(compile(body, str(SRC), 'exec'), mod.__dict__)
  return mod


m = load()
failures = []


def check(label, cond):
  print(f'{"ok  " if cond else "FAIL"} {label}')
  if not cond:
    failures.append(label)


entry = m.build_entry('/home/deck/Android_Waydroid/bin/deckdroid',
                      'org.lineageos.jelly', 'Jelly', None)
foreign = dict(entry, AppName='Hand made', tags={})
doc = {'shortcuts': {'0': entry, '1': foreign}}
blob = m.vdf_dump(doc)

check('round-trips without loss', m.vdf_load(blob) == doc)
check('serialisation is byte-stable', m.vdf_dump(m.vdf_load(blob)) == blob)
check('starts with the map/"shortcuts" header Steam expects',
      blob.startswith(b'\x00shortcuts\x00'))
check('ends with the two terminators Steam expects', blob.endswith(b'\x08\x08'))

aid = m.shortcut_appid('"/x/deckdroid"', 'Jelly')
check('appid has the non-Steam high bit set', bool(aid & 0x80000000))
check('appid stored as signed int32', entry['appid'] < 0)
check('appid signed/unsigned pair agree',
      struct.unpack('<I', struct.pack('<i', entry['appid']))[0] ==
      m.shortcut_appid(entry['Exe'], 'Jelly'))
check('appid is stable across calls',
      m.shortcut_appid('"/x/deckdroid"', 'Jelly') == aid)

kept = [v for v in m.vdf_load(blob)['shortcuts'].values()
        if m.TAG not in (v.get('tags') or {}).values()]
check('merge keeps shortcuts we did not create', len(kept) == 1)
check('merge identifies our own entries', kept[0]['AppName'] == 'Hand made')

check('int values survive as ints', isinstance(m.vdf_load(blob)['shortcuts']['0']['IsHidden'], int))
check('empty strings survive', m.vdf_load(blob)['shortcuts']['0']['ShortcutPath'] == '')

# A launch option is what makes one shortcut differ from another.
check('launch options carry the package',
      entry['LaunchOptions'] == 'launch org.lineageos.jelly')

print()
if failures:
  print(f'{len(failures)} failed: {failures}')
  sys.exit(1)
print('all shortcut tests passed')
