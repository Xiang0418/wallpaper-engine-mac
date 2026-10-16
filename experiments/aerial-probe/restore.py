"""Restore only the two files recorded in this experiment's verified manifest."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess
root=Path(__file__).resolve().parents[2]
b=Path((root/'build/aerial-probe/current-backup.txt').read_text())
entries=json.loads((b/'manifest.json').read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
 return h.hexdigest()
for e in entries:
 assert sha(Path(e['backup']))==e['sha256'], 'Backup checksum mismatch; aborting'
for e in entries:
 dst=Path(e['original']); tmp=dst.with_name(dst.name+'.owe-restore.tmp')
 shutil.copy2(e['backup'],tmp)
 os.replace(tmp,dst)
 assert sha(dst)==e['sha256']
 print('Restored:',dst)
for name in ['WallpaperAerialsExtension','WallpaperAgent']:
 subprocess.run(['/usr/bin/killall','-u',str(os.getuid()),name],check=False)
print('Original movie and wallpaper settings restored. Backup retained.')
