"""Build a native launcher on the target OS; no user data or .env is bundled."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent

def run(args): subprocess.run([str(a) for a in args], check=True)

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--output', type=Path, required=True); parser.add_argument('--version', default='preview'); args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.version):
        raise ValueError("Use a simple version label, such as 1.6.2.")
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    target = platform.system() + '-' + platform.machine()
    tools = json.loads((HERE/'tools.json').read_text())[target]
    stage = out/'payload'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir()
    binaries = stage/'bin'; binaries.mkdir(exist_ok=True)
    for name, (url, checksum) in tools.items():
        archive = out/(name+'.tar.gz')
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            urllib.request.urlretrieve(url, archive)
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == checksum, f'{name} checksum mismatch'
        with tarfile.open(archive) as tar:
            member = next(m for m in tar.getmembers() if Path(m.name).name == name and m.isfile())
            with tar.extractfile(member) as src, (binaries/name).open('wb') as dst: shutil.copyfileobj(src,dst)
        (binaries/name).chmod(0o755)
    # Explicit tracked backend files only. Exclude development state and voice clips.
    paths = subprocess.check_output(['git','ls-files','-z','backend'],cwd=ROOT).decode().split('\0')
    for rel in filter(None,paths):
        path = Path(rel)
        if any(part in {'.env','__pycache__','output','uploads'} for part in path.parts) or path.suffix in {'.sqlite3','.pyc','.pem','.key'}: continue
        if 'voice' in path.parts and path.suffix != '.md': continue
        src=ROOT/path
        if not src.is_file() or src.is_symlink(): continue
        dest=stage/path; dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
    for req in HERE.glob('requirements-*.txt'): shutil.copy2(req,stage/req.name)
    # Resolve separately per target OS and CPU/CUDA profile, then ship exact
    # transitive versions and hashes rather than re-resolving on the user's PC.
    for profile in ('auto','cpu'):
        for name in ('serve','extract','tts'):
            lock=stage/f'requirements-{name}-{profile}.txt'
            command=[binaries/'uv','--no-config','pip','compile',HERE/f'requirements-{name}.txt',
                     '--python-version','3.11','--generate-hashes','--no-header','--no-annotate','--quiet','-o',lock]
            if sys.platform=='linux' and profile=='cpu':command+=['--torch-backend','cpu']
            run(command)
    shutil.copytree(HERE/'ui',stage/'ui',dirs_exist_ok=True)
    notices=stage/'licenses'; notices.mkdir(exist_ok=True)
    license_urls={
        'uv-MIT.txt':'https://raw.githubusercontent.com/astral-sh/uv/0.13.4/LICENSE-MIT',
        'uv-Apache.txt':'https://raw.githubusercontent.com/astral-sh/uv/0.13.4/LICENSE-APACHE',
        'tectonic-MIT.txt':'https://raw.githubusercontent.com/tectonic-typesetting/tectonic/tectonic%400.17.0/LICENSE',
    }
    for name,url in license_urls.items(): urllib.request.urlretrieve(url,notices/name)
    shutil.copy2(HERE/'THIRD_PARTY_NOTICES.md',notices/'THIRD_PARTY_NOTICES.md')
    shutil.copy2(ROOT/'LICENSE',notices/'Firebrat-LICENSE.txt')
    urllib.request.urlretrieve(f'https://raw.githubusercontent.com/python/cpython/v{platform.python_version()}/LICENSE',notices/'Python-LICENSE.txt')
    import importlib.metadata
    for package in ('pyinstaller','python-multipart'):
        distribution=importlib.metadata.distribution(package)
        for file in distribution.files or []:
            if file.name.lower().startswith(('license','copying')):
                src=distribution.locate_file(file)
                if src.is_file(): shutil.copy2(src,notices/(package+'-'+file.name))
    (stage/'build-info.json').write_text(json.dumps({'version':args.version,'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'tools':tools},indent=2))

    command=[sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--name','FirebratServer',
             '--distpath',out/'dist','--workpath',out/'work','--specpath',out,
             '--add-data',f'{stage}/build-info.json:.','--add-data',f'{stage}/backend:backend','--add-data',f'{stage}/ui:ui','--add-data',f'{notices}:licenses',
             '--add-binary',f'{binaries}/uv:bin','--add-binary',f'{binaries}/tectonic:bin','--collect-all','python_multipart']
    for req in stage.glob('requirements-*.txt'): command += ['--add-data',f'{req}:.']
    if sys.platform=='darwin': command += ['--windowed','--osx-bundle-identifier','com.firebrat.serverlauncher']
    command.append(HERE/'launcher.py');run(command)
    label=f'Firebrat-Server-{args.version}-{target}'
    if sys.platform=='darwin':
        dmg=out/(label+'-unsigned.dmg'); folder=out/'dmg';folder.mkdir(exist_ok=True)
        app=out/'dist/FirebratServer.app';shutil.copytree(app,folder/app.name,dirs_exist_ok=True,symlinks=True)
        (folder/'Applications').symlink_to('/Applications',target_is_directory=True) if not (folder/'Applications').is_symlink() else None
        shutil.copy2(HERE/'README.md',folder/'Getting Started.md')
        if dmg.exists(): dmg.unlink()
        run(['hdiutil','create','-volname','Firebrat Server','-srcfolder',folder,'-ov','-format','UDZO',dmg])
        products=[dmg]
    else:
        archive=out/(label+'.tar.gz')
        with tarfile.open(archive,'w:gz') as tar: tar.add(out/'dist/FirebratServer',arcname='FirebratServer')
        script='''#!/bin/sh
set -eu
installer_dir="${XDG_DATA_HOME:-$HOME/.local/share}/firebrat-launcher/VERSION"
mkdir -p "$installer_dir"
chmod 700 "$installer_dir"
archive_line=$(awk '/^__FIREBRAT_ARCHIVE__$/ {print NR+1; exit}' "$0")
tail -n +"$archive_line" "$0" | tar -xz -C "$installer_dir"
printf 'Installed in %s\\n' "$installer_dir/FirebratServer"
exec "$installer_dir/FirebratServer/FirebratServer"
__FIREBRAT_ARCHIVE__
'''.replace('VERSION',args.version)
        installer=out/(label+'.run');installer.write_bytes(script.encode()+archive.read_bytes());installer.chmod(0o755)
        products=[archive,installer]
    for product in products: (out/(product.name+'.sha256')).write_text(hashlib.sha256(product.read_bytes()).hexdigest()+'  '+product.name+'\n')
    print('Built:',*[str(p) for p in products])

if __name__=='__main__':main()
