from pathlib import Path
import hashlib, json, os, shutil, sys
root=Path(__file__).resolve().parents[2]
b=Path((root/'build/aerial-probe/current-backup.txt').read_text())
entries=json.loads((b/'manifest.json').read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
 return h.hexdigest()
for e in entries:
 assert sha(Path(e['backup']))==e['sha256'], 'Backup mismatch'
e=next(e for e in entries if e['original'].endswith('.mov'))
dst=Path(e['original'])
expected = json.loads((b/'applied.json').read_text())['test_sha256'] if (b/'applied.json').exists() else e['sha256']
assert sha(dst)==expected, 'Aerial changed since last experiment operation; refusing overwrite'
src=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'build/aerial-probe/test-aerial-main10.mov'
assert src.stat().st_size>1000
tmp=dst.with_name(dst.name+'.owe-test.tmp')
shutil.copyfile(src,tmp)
os.chmod(tmp,0o600)
os.replace(tmp,dst)
assert sha(dst)==sha(src)
(b/'applied.json').write_text(json.dumps({'test_sha256':sha(src),'slot':str(dst)},indent=2))
print('Verified test movie installed:',dst)
