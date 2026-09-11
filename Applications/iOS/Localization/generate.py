"""Generate and validate Apple .strings resources from the reviewed translation table."""
import csv, json, re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rows = list(csv.DictReader((root / 'Localization/translations.tsv').open(), delimiter='\t'))
keys = [r['key'] for r in rows]
assert len(keys) == len(set(keys)), 'Duplicate localization keys'
for language in ['en', 'ru', 'de', 'es', 'fr', 'fi']:
    values = {}
    for row in rows:
        key = row['key'].replace('\\n', '\n')
        value = (row['key'] if language == 'en' else row[language]).replace('\\n', '\n')
        assert value.strip(), (language, key)
        assert sorted(re.findall(r'%(?:lld|@)', key)) == sorted(re.findall(r'%(?:lld|@)', value)), (language, key)
        values[key] = value
    folder = root / 'Resources/Localizations' / (language + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    quote = lambda s: json.dumps(s, ensure_ascii=False)
    (folder / 'Localizable.strings').write_text('\n'.join(f'{quote(k)} = {quote(v)};' for k,v in values.items()) + '\n')
    (folder / 'InfoPlist.strings').write_text('"NSMicrophoneUsageDescription" = ' + quote(values['Murmator transcribes your voice on this device.']) + ';\n')
print(f'Validated {len(keys)} keys in 6 languages; format placeholders match.')
