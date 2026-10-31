#!/usr/bin/env python3
"""Prepare an isolated Debug project using original user-provided assets. Does not modify the app project."""
from pathlib import Path
import shutil,json,datetime,subprocess,argparse,hashlib
from zoneinfo import ZoneInfo
tool_root=Path(__file__).resolve().parent
repo=tool_root.parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--assets-root',type=Path,default=repo/'user_data'/'marketing'/'generated',help='Private originals and generated outputs; never committed')
parser.add_argument('--run',type=Path,help='Capture archive directory; a new timestamped run is the default')
args=parser.parse_args()
root=args.assets_root.resolve()
assert (root/'asset-manifest.json').is_file(), f'Missing original image manifest: {root}'
run=(args.run or root/'runs'/datetime.datetime.now(ZoneInfo('Asia/Seoul')).strftime('%Y%m%d-%H%M%S')).resolve()
run.mkdir(parents=True,exist_ok=True)
if not (run/'source-state.json').exists():
 for file in [*root.iterdir(),*tool_root.iterdir()]:
  if file.is_file() and file.suffix in ['.py','.sh','.swift','.txt','.json','.zip']: shutil.copy2(file,run/file.name)
 if (root/'screenshots'/'ko').exists(): shutil.copytree(root/'screenshots'/'ko',run/'previous-iphone-screenshots')
 state={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (repo/'native-ios').rglob('*') if p.is_file() and not any(s in p.parts for s in ['build','.build','DerivedData','xcuserdata'])}
 (run/'source-state.json').write_text(json.dumps(state,indent=2))
(root/'current-capture-run.txt').write_text(str(run)+'\n')
stage=Path('/tmp/tegnal-marketing-'+run.name)
assert not stage.exists(), f'Capture stage already exists: {stage}'
shutil.copytree(repo/'native-ios',stage,ignore=shutil.ignore_patterns('build','.build','DerivedData','xcuserdata'))
manifest=json.loads((root/'asset-manifest.json').read_text())
assert len(manifest)==24
for item in manifest:
 assert hashlib.sha256((root/item['file']).read_bytes()).hexdigest()==item['sha256'], item['file']
resources=stage/'TEGNAL'/'MarketingAssets'; resources.mkdir()
folder_names=['미분류','풍경','공간','식물','계절','여행의 순간']
folder_ids={name:'unsorted' if name=='미분류' else next(m['folder_id'] for m in manifest if m['folder_name']==name) for name in folder_names}
colors=[4284922736,0xFF2563EB,0xFF059669,0xFFEA580C,0xFFE11D48,0xFF7C3AED]
folders=[dict(id=folder_ids[name],name='' if name=='미분류' else name,color=colors[i]) for i,name in enumerate(folder_names)]
# Interleave groups so the feed shows varied colors and subjects.
groups={name:[m for m in manifest if m['folder_name']==name] for name in folder_names}
assets=[groups[name][i] for i in range(4) for name in folder_names]
tags={'미분류':['still_life','sunlight'],'풍경':['scenery','sky'],'공간':['indoors','plants'],'식물':['nature','plants'],'계절':['nature','scenery'],'여행의 순간':['travel','scenery']}
server=dict(id='marketing-local',name='샘플 이미지',baseURL='https://marketing.invalid',engine='danbooru')
favorites=[]
now=datetime.datetime.now(datetime.timezone.utc).timestamp()
for i,item in enumerate(assets):
 post_id=1001+i;filename=f'marketing-{post_id}.png'
 shutil.copy2(root/item['file'],resources/filename)
 url=f'https://marketing.invalid/{filename}'
 post=dict(serverID=server['id'],postID=post_id,previewURL=url,sampleURL=url,fileURL=url,width=item['width'],height=item['height'],tags=tags[item['folder_name']],artists=[],rating='g',score=0,fileExtension='png',poolIDs=[])
 favorites.append(dict(post=post,folderID=folder_ids[item['folder_name']],savedAt=now-i))
backup=dict(format='tegnal-image-library',version=1,exportedAt=now-978307200,servers=[server],folders=folders,favorites=favorites,history=[dict(serverID=server['id'],query=query,usedAt=now-i) for i,query in enumerate(['scenery sky','nature plants','indoors plants','travel scenery'])],savedTags=[dict(serverID=server['id'],name=q,kind='search') for q in ['scenery sky','nature plants','indoors plants','travel scenery']]+[dict(serverID=server['id'],name=q,kind='tag') for q in ['scenery','plants','nature','sky','indoors']],blacklist={server['id']:''},selectedServerIDs=[server['id']])
(root/'marketing-library.json').write_text(json.dumps(backup,ensure_ascii=False,indent=2)+'\n')
shutil.copy2(root/'marketing-library.json',resources/'marketing-library.json')
shutil.copy2(tool_root/'MarketingCapture.swift',stage/'TEGNAL'/'MarketingCapture.swift')
shutil.copy2(tool_root/'MarketingScreenshotsTests.swift',stage/'TEGNALUITests'/'MarketingScreenshotsTests.swift')
def patch(file,old,new):
 p=stage/file;s=p.read_text();assert old in s,(file,old);p.write_text(s.replace(old,new))
patch(Path('TEGNAL/Presentation/Content/ContentUITestSupport.swift'),'        var env = AppEnvironment.preview()','        if MarketingCapture.enabled { return MarketingCapture.environment() }\n        var env = AppEnvironment.preview()')
patch(Path('TEGNAL/Presentation/Booru/BooruUITestSupport.swift'),'    static let source = BooruFixtureSource()','    static let source: any BooruProviding = MarketingCapture.enabled ? MarketingSource() : BooruFixtureSource()')
p=Path('TEGNAL/Presentation/Booru/BooruMediaView.swift')
patch(p,'if BooruUITestSupport.enabled {','if BooruUITestSupport.enabled && !MarketingCapture.enabled {')
patch(p,'return BooruUITestSupport.enabled','return BooruUITestSupport.enabled && !MarketingCapture.enabled')
patch(p,'    private func imageSource(_ url: URL, server: BooruServer) async throws -> (CGImageSource, URL?) {','    private func imageSource(_ url: URL, server: BooruServer) async throws -> (CGImageSource, URL?) {\n        if MarketingCapture.enabled, let data = MarketingCapture.data(url), let source = CGImageSourceCreateWithData(data as CFData, nil) { return (source, nil) }')
patch(p,'        var source = url?.absoluteString ?? ""','        var source = url?.absoluteString ?? ""\n        if MarketingCapture.enabled, let url = post.fileURL, let data = MarketingCapture.data(url) { source = "data:image/png;base64," + data.base64EncodedString() }')
patch(Path('TEGNAL/Presentation/Booru/BooruPostView.swift'),'if BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled {','if MarketingCapture.enabled { Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityLabel(mediaStatus).accessibilityIdentifier("marketing.mediaStatus") } else if BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled {')
patch(p,'    private func download(url: URL, server: BooruServer) async throws -> Data {','    private func download(url: URL, server: BooruServer) async throws -> Data {\n        if MarketingCapture.enabled, let data = MarketingCapture.data(url) { return data }')
project=stage/'project.yml'
text=project.read_text().replace('  postGenCommand: python3 scripts/sync_test_plan_ids.py\n','')
text=text.replace('PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.share','PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.capture.share')
text=text.replace('PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal\n','PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.capture\n')
text=text.replace('PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.tests','PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.capture.tests')
text=text.replace('PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.uitests','PRODUCT_BUNDLE_IDENTIFIER: work.nextline.tegnal.capture.uitests')
text+='\n  MarketingCapture:\n    build:\n      targets:\n        TEGNAL: all\n    test:\n      targets: [TEGNALUITests]\n'
project.write_text(text)
subprocess.run(['xcodegen' ,'generate','--spec',str(stage/'project.yml')],check=True)
profile=json.loads((root/'capture-profile.json').read_text()) if (root/'capture-profile.json').exists() else {}
profile.setdefault('capture_devices', {'iphone':'B051CA3E-4BD0-4746-AB15-EEB40059A502','ipad-13':'95C6B447-91E0-455E-94D1-00F40279CBD4','iphone-duo':'E2E4B030-DE00-49D6-B474-F242D8E38956'})
profile.update(status='assets_prepared',source='user_generated_original_images',external_site=None,folders=folders,asset_manifest='asset-manifest.json',backup='marketing-library.json',device_locale='ko_KR',fixture_project=str(stage),capture_run=str(run),capture_bundle_id='work.nextline.tegnal.capture',notes='Local Debug fixture; marketing.invalid is a reserved non-network address, not a service. Original images are bundled only into the isolated capture app. The JSON library requires this asset bridge; it is not a public image host.')
(root/'capture-profile.json').write_text(json.dumps(profile,ensure_ascii=False,indent=2)+'\n')
print('Capture project:',stage)
