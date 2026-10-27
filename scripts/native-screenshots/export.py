#!/usr/bin/env python3
"""Package native screenshot captures. No scaling, cropping, frames, or UI retouching."""
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse,hashlib,json,re,shutil,subprocess,zipfile

tool_root=Path(__file__).resolve().parent
repo=tool_root.parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('result',type=Path)
parser.add_argument('--assets-root',type=Path,default=repo/'user_data'/'marketing'/'generated')
parser.add_argument('--device',choices=['iphone','ipad-13','iphone-duo'],default='iphone')
parser.add_argument('--attachments',type=Path)
parser.add_argument('--overrides',type=Path,action='append',default=[],help='Supplemental native capture attachments, e.g. a settled selection frame')
args=parser.parse_args()
from PIL import Image,ImageOps,ImageDraw
root=args.assets_root.resolve()
result=args.result.resolve()
attachments=args.attachments or result.parent/(result.stem+'-attachments')
if not (attachments/'manifest.json').exists():
 subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),'--output-path',str(attachments)],check=True)
names=['01-library-top','01-library','02-explore','03-viewer','04-viewer-controls','05-saved-searches','06-organize','07-backup','08-search-history','09-settings','10-safe-mode']
source={}
for capture_folder in [attachments,*args.overrides]:
 for test in json.loads((capture_folder/'manifest.json').read_text()):
  for item in test.get('attachments',[]):
   file=capture_folder/item['exportedFileName']
   if file.suffix.lower()!='.png': continue
   match=re.match(r'(\d{2}-[a-z-]+)_',item.get('suggestedHumanReadableName',''))
   if match and match[1] in names: source[match[1]]=file
assert set(source)==set(names), ('Missing captures',set(names)-set(source))
profile_path=root/'capture-profile.json';profile=json.loads(profile_path.read_text())
run=Path(profile.get('capture_run') or (root/'current-capture-run.txt').read_text().strip())
snapshot=json.loads((run/'source-state.json').read_text())
changed=[name for name,digest in snapshot.items() if not (repo/name).exists() or hashlib.sha256((repo/name).read_bytes()).hexdigest()!=digest]
assert not changed, ('Production source changed while staging capture',changed)
for item in json.loads((root/'asset-manifest.json').read_text()):
 assert hashlib.sha256((root/item['file']).read_bytes()).hexdigest()==item['sha256'], item['file']
folder=root/'screenshots' if args.device=='iphone' else root/'screenshots'/args.device
output=folder/'ko';output.mkdir(parents=True,exist_ok=True)
records=[]
size=None
for name in names:
 file=source[name];target=output/(name+'.png')
 with Image.open(file) as image:
  if size is None: size=image.size
  assert image.size==size, (name,image.size,size)
  if args.device=='ipad-13': assert size==(2064,2752),size
  if args.device=='iphone-duo': assert size in [(2034,1398),(1398,2034),(2853,2007),(2007,2853)],size
  if args.device=='iphone': assert image.width>=1000 and image.height>image.width,size
  if 'A' in image.getbands():
   assert image.getchannel('A').getextrema()==(255,255), (name,'non-opaque alpha')
  if image.mode=='RGB': shutil.copy2(file,target)
  else: image.convert('RGB').save(target,format='PNG',icc_profile=image.info.get('icc_profile'))
 records.append(dict(file='ko/'+target.name,width=size[0],height=size[1],format='PNG',color_mode='RGB',sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
labels={'iphone':'iPhone 18 Pro','ipad-13':'iPad Pro 13-inch (M5)','iphone-duo':'iPhone Duo'}
project_settings=Path(profile['fixture_project'],'project.yml').read_text()
app_version=re.search(r'MARKETING_VERSION:\s*(\S+)',project_settings)[1]
build_number=re.search(r'CURRENT_PROJECT_VERSION:\s*(\S+)',project_settings)[1]
manifest=dict(app='TEGNAL',device=labels[args.device],runtime='iOS 27.1 Simulator' if args.device=='iphone-duo' else 'iOS 27.0 Simulator',
 date=datetime.now(ZoneInfo('Asia/Seoul')).strftime('%Y-%m-%d'),locale='ko-KR',appearance='dark',
 source='Latest working-tree app UI with an isolated local fixture and 24 unchanged user-provided original images',
 resized=False,cropped=False,retouched=False,alpha='Opaque alpha removed only; RGB pixels preserved',
 git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
 source_snapshot_sha256=hashlib.sha256(json.dumps(snapshot,sort_keys=True).encode()).hexdigest(),
 capture_bundle_id='work.nextline.tegnal.capture',app_version=app_version,build_number=build_number,xcresult=str(result),supplemental_capture_attachments=[str(p.resolve()) for p in args.overrides],files=records)
(folder/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
archive=root/f'tegnal-{args.device}-screenshots-ko.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as out:
 for name in names: out.write(output/(name+'.png'),name+'.png')
# Historical names remain usable, while canonical names use the current app brand.
legacy={'iphone':'number-memo-screenshots-ko.zip','ipad-13':'number-memo-ipad-13-screenshots-ko.zip'}
if args.device in legacy: shutil.copy2(archive,root/legacy[args.device])
# Contact sheets are inspection aids and never go into the screenshot archives.
w=250
h=round((w-16)*size[1]/size[0])+34
sheet=Image.new('RGB',(4*w,((len(names)+3)//4)*h),'#252525');draw=ImageDraw.Draw(sheet)
for index,name in enumerate(names):
 x=(index%4)*w;y=(index//4)*h
 draw.text((x+8,y+6),name,fill='white')
 with Image.open(output/(name+'.png')) as im:
  small=ImageOps.contain(im,(w-16,h-34))
  sheet.paste(small,(x+(w-small.width)//2,y+26))
sheet.save(folder/'contact-sheet.jpg',quality=90)
profile['status']='captured';profile['capture_bundle_id']='work.nextline.tegnal.capture'
profile.setdefault('latest_captures',{})[args.device]=dict(manifest=str((folder/'manifest.json').relative_to(root)),archive=archive.name,width=size[0],height=size[1],count=len(names),date=manifest['date'])
profile_path.write_text(json.dumps(profile,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(dict(device=args.device,count=len(records),size=size,archive=str(archive),manifest=str(folder/'manifest.json'),source_preserved=True,original_assets_verified=24),ensure_ascii=False))
