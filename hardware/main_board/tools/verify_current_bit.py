"""Check the recorded current bit without touching hardware."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'CURRENT_PROJECT.json').read_text(encoding='utf-8'))
bit=root/manifest['latest_bit']
actual=hashlib.sha256(bit.read_bytes()).hexdigest()
if actual!=manifest['bit_sha256'].lower():raise SystemExit('Current BIT differs from CURRENT_PROJECT.json; record the new build before programming')
print('PASS current bit SHA256:',actual)
print(manifest['latest_status'])
if manifest.get('bit_matches_source') is False:
    print('NOTE: existing BIT predates current source changes; rebuild to include the UART implementation')
