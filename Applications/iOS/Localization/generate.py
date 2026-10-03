"""Generate and validate Apple .strings resources from the reviewed translation table."""
import csv, json, re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rows = list(csv.DictReader((root / 'Localization/translations.tsv').open(), delimiter='\t'))
keys = [r['key'] for r in rows]
assert len(keys) == len(set(keys)), 'Duplicate localization keys'
def merge_strings(path, values):
    text = path.read_text() if path.exists() else ''
    seen = set()
    def replace(match):
        key, old = json.loads(match[1]), json.loads(match[2])
        seen.add(key)
        if key not in values or values[key] == old:
            return match[0]
        return json.dumps(key, ensure_ascii=False) + ' = ' + json.dumps(values[key], ensure_ascii=False) + ';'
    text = re.sub(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', replace, text)
    if text and not text.endswith('\n'): text += '\n'
    text += ''.join(json.dumps(k, ensure_ascii=False) + ' = ' + json.dumps(v, ensure_ascii=False) + ';\n' for k,v in values.items() if k not in seen)
    path.write_text(text)
for language in ['en', 'ru', 'de', 'es', 'fr', 'fi']:
    values = {}
    # Some shipped strings predate the table. Preserve them until migrated into it.
    existing = root / 'Resources/Localizations' / (language + '.lproj') / 'Localizable.strings'
    if existing.exists():
        for key, value in re.findall(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', existing.read_text()):
            values[json.loads(key)] = json.loads(value)
    for row in rows:
        key = row['key'].replace('\\n', '\n')
        value = (values.get(key, row['key']) if language == 'en' else row[language]).replace('\\n', '\n')
        assert value.strip(), (language, key)
        assert sorted(re.findall(r'%(?:lld|@)', key)) == sorted(re.findall(r'%(?:lld|@)', value)), (language, key)
        values[key] = value
    folder = root / 'Resources/Localizations' / (language + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    quote = lambda s: json.dumps(s, ensure_ascii=False)
    merge_strings(folder / 'Localizable.strings', values)
    info = folder / 'InfoPlist.strings'
    privacy = {'NSCameraUsageDescription': values['Murmator reads and translates text from a photo on this device.']}
    if not info.exists() or '"NSMicrophoneUsageDescription"' not in info.read_text():
        privacy['NSMicrophoneUsageDescription'] = values['Murmator transcribes your voice on this device.']
    merge_strings(info, privacy)
print(f'Validated {len(keys)} keys in 6 languages; format placeholders match.')
