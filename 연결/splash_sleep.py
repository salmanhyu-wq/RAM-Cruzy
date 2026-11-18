"""Put the locally managed Splash backend to sleep without removing its gateway."""

import asyncio
import errno
import json
import os
from pathlib import Path
import plistlib
import tempfile
import copy
import uuid

from aiohttp import ClientConnectorError, ClientError, ClientTimeout


class SplashSleep:
    label = 'local.splash.model-server'
    home = Path.home() / 'Library'
    job = home / 'LaunchAgents' / f'{label}.plist'
    marker = home / 'Application Support/Splash/runtime/airam-sleep.json'
    domain = f'gui/{os.getuid()}'

    def __init__(self, upstream):
        self.upstream = upstream
        self.lock = asyncio.Lock()
        self.saved = None
        self.failed_model = None
        try:
            saved = json.loads(self.marker.read_text())
            if (saved['upstream'] == upstream and isinstance(saved['status']['instance'], dict)
                    and isinstance(saved['models']['data'], list)):
                self.saved = saved
        except (OSError, ValueError, TypeError, KeyError):
            pass

    def supported(self):
        try:
            agent = plistlib.loads(self.job.read_bytes())
            args = agent['ProgramArguments']
            return (agent['Label'] == self.label and args[1:5] == ['-B', '-m', 'install.launcher', 'serve']
                    and Path(args[0]).name == 'python3' and agent.get('RunAtLoad') is True
                    and not agent.get('EnvironmentVariables', {}).get('SPLASH_API_KEY')
                    and '--api-key' not in args and args[args.index('--host') + 1] == '127.0.0.1'
                    and self.upstream == f"http://127.0.0.1:{args[args.index('--port') + 1]}")
        except (KeyError, IndexError, OSError, ValueError, TypeError, plistlib.InvalidFileException):
            return False

    @staticmethod
    async def read(client, url):
        async with client.get(url, timeout=ClientTimeout(total=2), allow_redirects=False) as response:
            response.raise_for_status()
            return await response.json()

    @classmethod
    async def video_idle(cls, client, port):
        try:
            queue = await cls.read(client, f'http://127.0.0.1:{port}/queue')
            return queue.get('queue_pending') == [] and queue.get('queue_running') == []
        except ClientConnectorError as error:
            return error.os_error.errno == errno.ECONNREFUSED
        except (ClientError, TimeoutError, ValueError, AttributeError):
            return False

    @staticmethod
    def idle(status, cache_only=True):
        return (status.get('ready') is True and status.get('active_requests') == []
                and status.get('transport', {}).get('status_stale') is False
                and status.get('transport', {}).get('pending') == 0
                and status.get('frontend', {}).get('active') == 0
                and status.get('frontend', {}).get('waiting') == 0
                and status.get('admission', {}).get('waiting', 0) == 0
                and status.get('kv', {}).get('pages_active') == 0
                and (not cache_only or status.get('kv', {}).get('pages_cache', 0) > 0)
                and (not cache_only or status.get('weights', {}).get('released') is True)
                and status.get('weights', {}).get('restoring') is False
                and all(status.get('scheduler', {}).get(key) == 0 for key in
                        ('queued', 'prefilling', 'decoding', 'waiting_resources', 'waiting_prefix', 'waiting_mask')))

    async def launchctl(self, *arguments):
        command = await asyncio.create_subprocess_exec('/bin/launchctl', *arguments,
                                                      stdout=asyncio.subprocess.DEVNULL,
                                                      stderr=asyncio.subprocess.DEVNULL)
        try:
            return await asyncio.wait_for(command.wait(), 6) == 0
        except TimeoutError:
            if command.returncode is None:
                command.kill()
            await command.wait()
            return False

    async def stop_engine(self):
        target = f'{self.domain}/{self.label}'
        if not await self.launchctl('print', target):
            return True
        await self.launchctl('bootout', target)
        deadline = asyncio.get_running_loop().time() + 8
        while asyncio.get_running_loop().time() < deadline:
            if not await self.launchctl('print', target):
                return True
            await asyncio.sleep(0.15)
        return False

    async def start_engine(self, client, expected, seconds):
        if not await self.launchctl('print', f'{self.domain}/{self.label}'):
            if not await self.launchctl('bootstrap', self.domain, str(self.job)):
                return False
        deadline = asyncio.get_running_loop().time() + seconds
        while asyncio.get_running_loop().time() < deadline:
            try:
                status = await self.read(client, self.upstream + '/status')
                if status.get('ready') is True and status.get('instance', {}).get('model') == expected:
                    return True
            except (ClientError, TimeoutError, OSError, ValueError):
                pass
            await asyncio.sleep(0.4)
        return False

    def save(self, status, models, paused=False):
        data = {'upstream': self.upstream, 'status': {
            'instance': status['instance'], 'weights': {'released': True}, 'active_requests': [],
            'memory_actual': {'current_bytes': 0}, 'sleeping': True, 'paused': paused}, 'models': models}
        self.persist(data)

    def persist(self, data):
        self.marker.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=self.marker.parent, delete=False) as file:
            try:
                json.dump(data, file)
                file.flush()
                os.fsync(file.fileno())
                os.replace(file.name, self.marker)
            finally:
                Path(file.name).unlink(missing_ok=True)
        self.saved = data

    def clear(self):
        self.marker.unlink(missing_ok=True)
        self.saved = None

    async def sleep(self, client, video_port, busy, paused=False):
        async with self.lock:
            if not self.supported() or busy():
                return False
            if self.saved is not None:
                if paused:
                    updated = copy.deepcopy(self.saved)
                    updated['status']['paused'] = True
                    self.persist(updated)
                    return True
                return False
            if not await self.video_idle(client, video_port):
                return False
            try:
                models = await self.read(client, self.upstream + '/v1/models')
                status = await self.read(client, self.upstream + '/status')
                if busy() or not self.idle(status, cache_only=not paused) or not isinstance(models.get('data'), list):
                    return False
                self.save(status, models, paused=paused)
                if await self.stop_engine():
                    return True
            except (ClientError, TimeoutError, OSError, ValueError, KeyError, AttributeError, TypeError):
                pass
            if self.saved is not None and await self.launchctl('print', f'{self.domain}/{self.label}'):
                self.clear()
            return False

    async def wake(self, client, explicit=False):
        async with self.lock:
            if self.saved is not None and self.saved['status'].get('paused') and not explicit:
                return False
            if not self.supported():
                return False
            expected = None
            try:
                args = plistlib.loads(self.job.read_bytes())['ProgramArguments']
                expected = args[args.index('--model') + 1]
                if await self.start_engine(client, expected, 90):
                    self.clear()
                    if self.failed_model == expected:
                        self.failed_model = None
                    return True
            except (OSError, ValueError, KeyError, IndexError):
                pass
            self.failed_model = expected or 'unknown'
            return False

    async def reset(self, client, video_port, busy):
        async with self.lock:
            if not self.supported() or busy() or not await self.video_idle(client, video_port):
                return False
            try:
                status = await self.read(client, self.upstream + '/status')
            except (ClientError, TimeoutError, ValueError):
                status = None
            if busy():
                return False
            if status is not None and not self.idle(status, cache_only=False):
                return False
            if not await self.stop_engine():
                return False
            # Keep the gateway listening; only an explicit model selection can wake the engine.
            self.persist({'upstream': self.upstream, 'status': {
                'instance': {'id': 'splash-empty'}, 'ready': True, 'empty': True, 'paused': True,
                'active_requests': [], 'weights': {'released': True}, 'memory_actual': {'current_bytes': 0},
            }, 'models': {'object': 'list', 'data': []}})
            self.failed_model = None
            return True

    @staticmethod
    def write_job(path, contents):
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
            try:
                file.write(contents)
                file.flush()
                os.fsync(file.fileno())
                os.chmod(file.name, 0o600)
                os.replace(file.name, path)
            finally:
                Path(file.name).unlink(missing_ok=True)

    async def load_model(self, client, model_path, video_port, busy):
        root = self.home / 'Application Support/Splash/local-models'
        candidate = Path(model_path)
        if candidate.parent != root or not candidate.exists() or not self.supported():
            return False
        if candidate.is_file() and candidate.suffix.lower() != '.gguf':
            return False
        async with self.lock:
            if busy() or not await self.video_idle(client, video_port):
                return False
            original = self.job.read_bytes()
            before = copy.deepcopy(self.saved)
            if self.saved is None:
                try:
                    models = await self.read(client, self.upstream + '/v1/models')
                    status = await self.read(client, self.upstream + '/status')
                except (ClientError, TimeoutError, ValueError):
                    return False
                if busy() or not self.idle(status, cache_only=False):
                    return False
                self.save(status, models)
            agent = plistlib.loads(original)
            arguments = agent['ProgramArguments']
            arguments[arguments.index('--model') + 1] = 'local/' + candidate.name
            arguments[arguments.index('--model-dir') + 1] = str(candidate)
            if '--mmproj' in arguments:
                index = arguments.index('--mmproj')
                del arguments[index:index + 2]
            projectors = list(candidate.glob('mmproj*.gguf')) if candidate.is_dir() else []
            if len(projectors) == 1:
                arguments += ['--mmproj', str(projectors[0])]
            backup = self.marker.parent / ('server-before-model-' + uuid.uuid4().hex + '.plist')
            self.write_job(backup, original)
            try:
                if not await self.stop_engine():
                    self.persist(before) if before else self.clear()
                    return False
                loading = copy.deepcopy(self.saved)
                loading['status']['instance'] = dict(loading['status']['instance'], model='local/' + candidate.name)
                loading['status']['weights'] = {'released': False, 'restoring': True}
                loading['status'].update(paused=False, ready=False)
                loading['status'].pop('empty', None)
                self.persist(loading)
                self.write_job(self.job, plistlib.dumps(agent))
                if await self.start_engine(client, 'local/' + candidate.name, 110):
                    self.clear()
                    self.failed_model = None
                    return True
            except (OSError, ValueError, KeyError):
                pass
            self.failed_model = 'local/' + candidate.name
            stopped = await self.stop_engine()
            self.write_job(self.job, original)
            if before is not None:
                self.persist(before)
            else:
                self.clear()
                if stopped:
                    await self.launchctl('bootstrap', self.domain, str(self.job))
            return False
