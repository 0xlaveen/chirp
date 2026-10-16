#!/bin/bash
# User-scoped macOS toolchain; no sudo, Homebrew services or emulator images.
set -euo pipefail
cd "$(dirname "$0")/.."
export CHIRP_TOOLS="${CHIRP_TOOLS:-$HOME/.local/share/chirp-android}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$CHIRP_TOOLS" "$ANDROID_HOME"
python3 - <<'PY'
import hashlib,json,os,pathlib,platform,shutil,subprocess,tempfile,urllib.request,xml.etree.ElementTree as ET
root=pathlib.Path(os.environ['CHIRP_TOOLS']); sdk=pathlib.Path(os.environ['ANDROID_HOME'])
arch='aarch64' if platform.machine()=='arm64' else 'x64'
def download(url,path,checksum,algorithm='sha256'):
    urllib.request.urlretrieve(url,path)
    if hashlib.new(algorithm,path.read_bytes()).hexdigest()!=checksum: raise RuntimeError('Download checksum mismatch')
with tempfile.TemporaryDirectory(prefix='chirp-toolchain-') as tmp:
    tmp=pathlib.Path(tmp)
    if not (root/'jdk/Contents/Home/bin/java').exists():
        assets=json.load(urllib.request.urlopen(f'https://api.azul.com/metadata/v1/zulu/packages/?java_version=21&os=macos&arch={arch}&archive_type=tar.gz&java_package_type=jdk&release_status=ga&availability_types=CA&latest=true'))
        asset=next(a for a in assets if '-fx-' not in a['name'] and '-crac-' not in a['name'])
        pkg=json.load(urllib.request.urlopen('https://api.azul.com/metadata/v1/zulu/packages/'+asset['package_uuid']))
        archive=tmp/'jdk.tar.gz'
        download(pkg['download_url'],archive,pkg['sha256_hash'])
        subprocess.run(['tar','-xzf',str(archive),'-C',str(tmp)],check=True)
        extracted=next(p.parent for p in tmp.rglob('Contents') if (p/'Home/bin/java').exists())
        shutil.move(str(extracted),root/'jdk')
    if not (sdk/'cmdline-tools/latest/bin/sdkmanager').exists():
        repo=ET.fromstring(urllib.request.urlopen('https://dl.google.com/android/repository/repository2-3.xml').read())
        pkg=next(p for p in repo.findall('remotePackage') if p.attrib['path']=='cmdline-tools;latest')
        choices=[a for a in pkg.findall('.//archive') if a.findtext('host-os')=='macosx']
        archive=next((a for a in choices if ('arm64' in a.findtext('.//url'))==(arch=='aarch64')),choices[0])
        z=tmp/'tools.zip'; complete=archive.find('complete')
        download('https://dl.google.com/android/repository/'+complete.findtext('url'),z,complete.findtext('checksum'),'sha1')
        subprocess.run(['unzip','-q',str(z),'-d',str(tmp/'tools')],check=True)
        (sdk/'cmdline-tools').mkdir(exist_ok=True)
        shutil.move(str(tmp/'tools/cmdline-tools'),sdk/'cmdline-tools/latest')
PY
export JAVA_HOME="$CHIRP_TOOLS/jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
# sdkmanager closes stdin after consuming licenses (ignore yes's SIGPIPE only).
set +o pipefail
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null
set -o pipefail
sdkmanager --sdk_root="$ANDROID_HOME" 'platform-tools' 'platforms;android-37.2' 'build-tools;37.0.0'
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties
cat > "$CHIRP_TOOLS/env.sh" <<ENV
export JAVA_HOME='$JAVA_HOME'
export ANDROID_HOME='$ANDROID_HOME'
export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$PATH"
ENV
printf 'Ready. Run: source %s/env.sh\n' "$CHIRP_TOOLS"
