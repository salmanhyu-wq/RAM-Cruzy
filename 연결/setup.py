"""Opt in to the existing Splash gate and Hermes profiles on this Mac."""

import argparse
import io
import json
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq

from memory_fit import FIT_GATE_VERSION

PROJECT = Path(__file__).resolve().parent
HOME = Path.home()
HERMES = HOME / '.hermes'
PLUGIN = 'ai-ram-manager'
LABEL = 'local.splash.hermes-session-gate'
AGENT = HOME / 'Library/LaunchAgents' / f'{LABEL}.plist'
BACKUP = HOME / 'Library/Application Support/AI 램 관리/splash-gate.before.plist'
DOMAIN = f'gui/{os.getuid()}'
TARGET = f'{DOMAIN}/{LABEL}'
GATE = PROJECT / 'splash_gate.py'
PLUGIN_DIR = PROJECT / 'Hermes' / PLUGIN
CONFIG_YAML = YAML()
CONFIG_YAML.preserve_quotes = True


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def current_status(port):
    request = Request(f'http://127.0.0.1:{port}/gate', headers={'X-AIRAM-Control': '1'})
    with urlopen(request, timeout=3) as response:
        status = json.load(response)
    if status.get('limit') != {'user': 1, 'bot': 3}:
        raise RuntimeError('개인 1칸, 봇 3칸인 기존 Splash 중계기를 찾지 못했어요.')
    return status


def register_gate():
    deadline = time.monotonic() + 8
    while True:
        result = subprocess.run(['/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('macOS 중계기 등록 실패: ' + (result.stderr.strip() or str(result.returncode)))
        time.sleep(0.3)


def wait_unregistered():
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        result = subprocess.run(['/bin/launchctl', 'print', TARGET], capture_output=True)
        if result.returncode != 0:
            return
        time.sleep(0.2)
    raise RuntimeError('기존 중계기가 아직 내려가지 않았어요.')


def switch_gate(config, contents, before, port):
    status = current_status(port)
    if any(status['active'].values()) or any(status['waiting'].values()):
        raise RuntimeError('Splash에 실행 중이거나 대기 중인 요청이 있어요. 작업이 끝난 뒤 다시 실행해 주세요.')
    if status.get('sleeping') is True:
        wake = Request(f'http://127.0.0.1:{port}/gate/splash/wake', data=b'{}',
                       headers={'X-AIRAM-Control': '1', 'Content-Type': 'application/json'})
        with urlopen(wake, timeout=106):
            pass
    target_path = str(config['ProgramArguments'][-1])
    atomic_write(AGENT, contents, 0o600)
    try:
        subprocess.run(['/bin/launchctl', 'bootout', TARGET], check=True, capture_output=True)
        wait_unregistered()
        register_gate()
        for _ in range(20):
            try:
                actual = current_status(port)
                if target_path == str(GATE):
                    if actual.get('management') == 1 and actual.get('controls_version', 0) >= FIT_GATE_VERSION:
                        return
                elif actual.get('management') != 1:
                    return
            except (OSError, ValueError):
                pass
            time.sleep(0.15)
        raise RuntimeError('Splash 중계기가 새 설정으로 응답하지 않았어요.')
    except (OSError, RuntimeError, subprocess.SubprocessError):
        subprocess.run(['/bin/launchctl', 'bootout', TARGET], capture_output=True)
        atomic_write(AGENT, before, 0o600)
        wait_unregistered()
        register_gate()
        raise


def reload_if_needed(port):
    status = current_status(port)
    if status.get('controls_version', 0) >= FIT_GATE_VERSION:
        return
    if any(status['active'].values()) or any(status['waiting'].values()) or status.get('splash_transition'):
        raise RuntimeError('Splash에 실행 중이거나 대기 중인 작업이 있어요. 작업이 끝난 뒤 다시 실행해 주세요.')
    subprocess.run(['/bin/launchctl', 'kickstart', '-k', TARGET], check=True, capture_output=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            if current_status(port).get('controls_version', 0) >= FIT_GATE_VERSION:
                return
        except (OSError, ValueError):
            pass
        time.sleep(.25)
    raise RuntimeError('비집고 넣기 중계기를 확인할 수 없어요.')


def profiles():
    for config in [HERMES / 'config.yaml', *sorted((HERMES / 'profiles').glob('*/config.yaml')),
                   *sorted((HERMES / 'office-runtime/profiles').glob('*/config.yaml'))]:
        if config.is_file() and not config.is_symlink():
            yield config


def configure_plugin(enable):
    changed = []
    for config in profiles():
        deleted = HERMES / 'profiles' / '.deleted' / config.parent.name
        if enable and config.parent != HERMES and deleted.exists():
            continue
        old = config.read_bytes()
        try:
            data = CONFIG_YAML.load(old.decode())
        except (ValueError, OSError):
            continue
        if not isinstance(data, dict):
            continue
        # A profile can select Splash per chat even when its default model is remote.
        # The middleware itself accepts only the loopback Splash gate.
        plugins = data.get('plugins')
        if not isinstance(plugins, dict):
            if not enable or plugins is not None:
                continue
            plugins = data['plugins'] = CommentedMap()
        enabled = plugins.get('enabled')
        if not isinstance(enabled, list):
            if not enable or enabled is not None:
                continue
            enabled = plugins['enabled'] = CommentedSeq()
        link = config.parent / 'plugins' / PLUGIN
        if enable:
            if PLUGIN in (plugins.get('disabled') or []):
                continue
            if (link.exists() or link.is_symlink()) and (not link.is_symlink() or link.resolve() != PLUGIN_DIR):
                raise RuntimeError(f'다른 플러그인이 같은 이름을 쓰고 있어요. {link}')
            if not link.is_symlink():
                link.parent.mkdir(mode=0o700, exist_ok=True)
                link.symlink_to(PLUGIN_DIR, target_is_directory=True)
            if PLUGIN in enabled:
                continue
            enabled.append(PLUGIN)
        else:
            if not link.is_symlink() or link.resolve() != PLUGIN_DIR:
                continue
            if PLUGIN in enabled:
                enabled.remove(PLUGIN)
            else:
                link.unlink()
                continue
        stream = io.StringIO()
        if old.lstrip().startswith(b'{'):
            contents = (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()
        else:
            CONFIG_YAML.dump(data, stream)
            contents = stream.getvalue().encode()
        # Retain the first pre-connection file outside the live profile.
        recovery = HOME / 'Library/Application Support/AI 램 관리/hermes-identity-before'
        relative = config.relative_to(HERMES)
        backup = recovery / relative
        if not backup.exists():
            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_write(backup, old, 0o600)
        if config.read_bytes() != old:
            continue  # A caller changed the profile during this sync; retry next time.
        atomic_write(config, contents, config.stat().st_mode & 0o777)
        if not enable:
            link.unlink()
        changed.append(config.parent.name)
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['enable', 'disable'])
    args = parser.parse_args()
    enable = args.mode == 'enable'
    try:
        before = AGENT.read_bytes()
        config = plistlib.loads(before)
        options = config['ProgramArguments']
        env = config['EnvironmentVariables']
        port = int(env['SPLASH_SESSION_GATE_PORT'])
        if port != 8002 or env.get('SPLASH_SHARED_PORT') not in ('8000', '0'):
            raise RuntimeError('예상과 다른 포트예요. Splash 중계기 설정을 먼저 확인해 주세요.')
        original = HOME / 'Library/Application Support/Splash/hermes-session-gate.py'
        if config.get('Label') != LABEL or len(options) != 4 or options[1:3] != ['-B', '-u']:
            raise RuntimeError('현재 중계기 설정 형식이 예상과 달라요.')
        if options[-1] not in (str(original), str(GATE)):
            raise RuntimeError('다른 중계기가 사용 중이에요.')
        if enable and options[-1] == str(original):
            BACKUP.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            atomic_write(BACKUP, before, 0o600)
            options[-1] = str(GATE)
            switch_gate(config, plistlib.dumps(config), before, port)
        elif enable:
            reload_if_needed(port)
        elif options[-1] == str(GATE):
            backup = BACKUP.read_bytes()
            restored = plistlib.loads(backup)
            if restored.get('ProgramArguments', [])[-1:] != [str(original)]:
                raise RuntimeError('원래 중계기 복구 파일을 확인할 수 없어요.')
            switch_gate(restored, backup, before, port)
        changed = configure_plugin(enable)
        print(f'연결 {"켜짐" if enable else "꺼짐"}. Hermes 설정 변경 {len(changed)}개.')
        print('열려 있는 Hermes는 작업이 끝난 뒤 다시 열어 주세요.')
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f'설정을 완료하지 못했어요. {error}')
        raise SystemExit(1)


if __name__ == '__main__':
    main()
