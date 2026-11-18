"""Hold an unstarted local request while RAM Cruzy frees memory."""
import asyncio
from collections import Counter
from dataclasses import dataclass, field
import json
import os
import re
import time
import uuid

import aiohttp
from aiohttp import web
from yarl import URL


FIT_GATE_VERSION = 6
COMFY_ENGINE_PORT = int(os.environ.get('AIRAM_COMFY_ENGINE_PORT', '8188'))
COMFY_BRIDGE_PORT = int(os.environ.get('AIRAM_COMFY_BRIDGE_PORT', '8189'))
COMFY_ALIAS_PORT = 8189
COMFY_ENGINE_LABEL = 'org.ramcruzy.comfy-engine'
DEFAULT_PORTS = {'mlxServe': 11234, 'lmStudio': 1234, 'mlxStudio': 8080, 'comfy': COMFY_ENGINE_PORT}
WAIT_SECONDS = 30
HEARTBEAT_SECONDS = 15
MAX_HELD = 8
ERROR_LIMIT = 16 * 1024
HOP_HEADERS = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
               'te', 'trailers', 'transfer-encoding', 'upgrade'}
CHAT_PATHS = {'/v1/chat/completions', '/v1/completions', '/v1/responses', '/v1/messages',
              '/api/chat', '/api/generate'}
API_READS = {'/v1/models', '/api/tags', '/api/ps', '/v1/load-progress', '/health', '/props', '/api/v1/models'}
GENERATION = {
    'mlxServe': CHAT_PATHS | {'/v1/embeddings', '/api/embed', '/api/embeddings', '/v1/load-model',
                              '/v1/images/generations', '/v1/images/edits', '/v1/video/generations',
                              '/v1/videos/generations', '/v1/music/generations', '/v1/3d/generations',
                              '/v1/audio/speech', '/v1/audio/transcriptions', '/v1/audio/generations',
                              '/v1/audio/music-generations', '/v1/audio/sound-generations'},
    'lmStudio': CHAT_PATHS | {'/api/v1/chat', '/api/v1/models/load', '/v1/embeddings'},
    'mlxStudio': CHAT_PATHS | {'/v1/embeddings', '/api/embed', '/api/embeddings'},
    'comfy': {'/prompt', '/api/prompt'},
}
MEMORY_CODES = {'resource_timeout', 'insufficient_memory', 'insufficient_gpu_memory',
                'insufficient_vram', 'out_of_memory', 'gpu_out_of_memory', 'vram_out_of_memory',
                'memory_pressure', 'metal_out_of_memory'}
GPU_CODES = {'insufficient_gpu_memory', 'insufficient_vram', 'gpu_out_of_memory',
             'vram_out_of_memory', 'metal_out_of_memory'}
MEMORY_MESSAGE = re.compile(
    r'\b(?:out of (?:gpu |device )?memory|'
    r'(?:not enough|insufficient) (?:free |available )?(?:gpu memory|unified memory|system memory|memory|vram)|'
    r'(?:gpu|metal) (?:memory )?allocation (?:has )?failed|'
    r'requires? [\d.]+\s*(?:gib|gb|mib|mb) (?:of )?free (?:gpu memory|vram))\b', re.I)


def memory_failure(provider, status, payload):
    if status not in (400, 422, 500, 503, 507) or not isinstance(payload, dict):
        return None
    error = payload.get('error')
    if not isinstance(error, (str, dict)):
        return None
    code = (error.get('code') or error.get('type') or '') if isinstance(error, dict) else ''
    message = error.get('message', '') if isinstance(error, dict) else error
    if not isinstance(code, str) or not isinstance(message, str):
        return None
    code = code.lower()
    if code in MEMORY_CODES:
        return 'gpu' if code in GPU_CODES else 'memory'
    if provider == 'splash' or code in ('capacity_exhausted', 'context_length_exceeded', 'request_quarantined'):
        return None
    match = MEMORY_MESSAGE.search(message[:500])
    if match:
        return 'gpu' if re.search(r'gpu|metal|vram', match[0], re.I) else 'memory'
    return None


async def error_body(response):
    length = response.content_length
    if (response.status not in (400, 422, 500, 503, 507) or length is None or length > ERROR_LIMIT
            or response.headers.get('Content-Encoding', 'identity') != 'identity'
            or response.content_type != 'application/json'):
        return None, None
    data = await response.read()
    try:
        return data, json.loads(data)
    except (ValueError, UnicodeError):
        return data, None


def response_headers(response):
    connection = {name.strip().lower() for name in response.headers.get('Connection', '').split(',')}
    return [(key, value) for key, value in response.headers.items()
            if key.lower() not in HOP_HEADERS | connection]


async def relay_response(request, upstream, headers, buffered=None):
    response = web.StreamResponse(status=upstream.status, headers=headers)
    request['ai_response_started'] = True
    await response.prepare(request)
    if buffered is not None:
        if buffered:
            await response.write(buffered)
    else:
        async for chunk in upstream.content.iter_any():
            await response.write(chunk)
    await response.write_eof()
    return response


@dataclass
class HeldRequest:
    provider: str
    model: str
    reason: str
    port: int
    result: asyncio.Future
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    claimed: bool = False
    reserved: set = field(default_factory=set)

    def view(self):
        return {'id': self.id, 'provider': self.provider, 'model': self.model,
                'reason': self.reason, 'port': self.port, 'claimed': self.claimed}


class MemoryFit:
    def __init__(self, splash_port, internal_port, legacy_port):
        self.splash_port = splash_port
        self.internal_port = internal_port
        self.legacy_port = legacy_port
        self.ports = DEFAULT_PORTS.copy()
        self.comfy_port = None
        self.comfy_aliases = set()
        self.comfy_launch = None
        self.last_seen = 0
        self.enabled = False
        self.critical = False
        self.warning = False
        self.held = {}
        self.active = Counter()
        self.traffic = {provider: Counter() for provider in ('splash', *self.ports)}
        self.changed = asyncio.Event()

    def count(self, provider, key):
        self.traffic[provider][key] += 1

    def snapshot(self):
        return {'held': [job.view() for job in self.held.values()],
                'comfy_port': self.comfy_port, 'enabled': self.available,
                'routes': {provider: {
                    'active': self.active[provider],
                    'holding': sum(job.provider == provider and not job.result.done() for job in self.held.values()),
                    'received': counts['received'], 'retried': counts['retried'], 'recovered': counts['recovered'],
                } for provider, counts in self.traffic.items()}}

    @property
    def available(self):
        return self.enabled and time.monotonic() - self.last_seen < HEARTBEAT_SECONDS

    def update(self, data):
        self.last_seen = time.monotonic()
        self.enabled = data.get('enabled') is True
        self.critical = data.get('critical') is True
        self.warning = data.get('warning') is True
        supplied = data.get('ports')
        if isinstance(supplied, dict):
            forbidden = {self.splash_port, self.internal_port, self.legacy_port, self.comfy_port} | self.comfy_aliases
            for provider in self.ports:
                port = supplied.get(provider)
                if type(port) is int and 1024 <= port <= 65535 and port not in forbidden:
                    self.ports[provider] = port
        if not self.enabled:
            for job in self.held.values():
                if not job.result.done():
                    job.result.set_result(False)
        result = data.get('result')
        if isinstance(result, dict) and isinstance(result.get('id'), str):
            job = self.held.get(result['id'])
            if job and job.claimed and not job.result.done():
                job.result.set_result(result.get('changed') is True)
        claim = None
        if self.enabled and data.get('ready') is True and not any(j.claimed for j in self.held.values()):
            job = next(iter(self.held.values()), None)
            if job and not job.result.done():
                job.claimed = True
                claim = job.view()
        return {**self.snapshot(), 'claim': claim}

    def reserve(self, data):
        id_ = data.get('id')
        job = self.held.get(id_) if isinstance(id_, str) else None
        if not self.available or not job or not job.claimed or job.result.done():
            return False
        provider = data.get('provider')
        if provider is None:
            return True
        if (not isinstance(provider, str) or provider == job.provider or self.active[provider]
                or provider not in ('splash', 'mlxServe', 'comfy')):
            return False
        if data.get('port') != (self.splash_port if provider == 'splash' else self.ports[provider]):
            return False
        job.reserved.add(provider)
        return True

    def is_reserved(self, provider):
        return any(provider in job.reserved for job in self.held.values())

    async def wait_for_release(self, provider):
        async with asyncio.timeout(WAIT_SECONDS):
            while self.is_reserved(provider):
                await self.changed.wait()

    async def recover(self, provider, model, reason, port):
        if not self.available or len(self.held) >= MAX_HELD:
            return False
        job = HeldRequest(provider, model, reason, port, asyncio.get_running_loop().create_future())
        self.held[job.id] = job
        try:
            return await asyncio.wait_for(job.result, WAIT_SECONDS)
        except TimeoutError:
            return False
        finally:
            del self.held[job.id]
            self.changed.set()
            self.changed.clear()

    async def preflight(self, provider, model, port, media=False):
        if not self.available or not (self.critical or (media and self.warning)):
            return False
        await self.recover(provider, model, 'pressure', port)
        if self.available and self.critical:
            raise web.HTTPServiceUnavailable(headers={'Retry-After': '5'}, content_type='application/json',
                text=json.dumps({'error': {'message': '아직 작업을 시작할 램이 부족해요.',
                                          'code': 'memory_pressure'}}, ensure_ascii=False))
        return True

    @staticmethod
    def model_name(data):
        if not data:
            return ''
        try:
            model = json.loads(data).get('model')
        except (ValueError, UnicodeError, AttributeError):
            return ''
        return model[:240] if isinstance(model, str) else ''

    async def start_comfy_if_needed(self, port):
        if COMFY_ENGINE_PORT == 8188 or port != COMFY_ENGINE_PORT:
            return

        async def listening():
            try:
                async with asyncio.timeout(.5):
                    _, writer = await asyncio.open_connection('127.0.0.1', port)
                    writer.close()
                    await writer.wait_closed()
                return True
            except (OSError, TimeoutError):
                return False

        async def start():
            if await listening():
                return
            target = f'gui/{os.getuid()}/{COMFY_ENGINE_LABEL}'
            process = await asyncio.create_subprocess_exec('/bin/launchctl', 'kickstart', target,
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            if await process.wait() == 0:
                for _ in range(48):
                    if await listening():
                        return
                    await asyncio.sleep(.5)

        if await listening():
            return
        if self.comfy_launch is None or self.comfy_launch.done():
            self.comfy_launch = asyncio.create_task(start())
        await asyncio.shield(self.comfy_launch)

    async def proxy(self, request, provider, path, ingress):
        is_comfy_port = ingress == self.comfy_port or ingress in self.comfy_aliases
        if provider not in self.ports or (provider == 'comfy') != is_comfy_port:
            raise web.HTTPNotFound()
        if request.host not in {f'localhost:{ingress}', f'127.0.0.1:{ingress}'}:
            raise web.HTTPForbidden()
        origin = request.headers.get('Origin')
        if (origin is not None and origin != f'http://{request.host}'
                or request.headers.get('Sec-Fetch-Site') in {'cross-site', 'same-site'}):
            raise web.HTTPForbidden()
        generation = request.method == 'POST' and path in GENERATION[provider]
        media = provider == 'comfy' or (provider == 'mlxServe' and any(
            path.startswith('/v1/' + category + '/') for category in ('images', 'video', 'videos', 'audio', 'music', '3d')))
        model_read = path.startswith('/v1/models/') and not {'.', '..'} & set(path.split('/'))
        if provider != 'comfy' and not (generation or (request.method in ('GET', 'HEAD')
                and (path in API_READS or model_read))):
            raise web.HTTPNotFound()

        port = self.ports[provider]
        target = URL(f'http://127.0.0.1:{port}').with_path(path).with_query(request.query)
        if target.host != '127.0.0.1' or target.port != port:
            raise web.HTTPBadRequest()
        headers = {key: value for key, value in request.headers.items()
                   if key.lower() not in HOP_HEADERS | {'host', 'content-length', 'expect'}
                   and not key.lower().startswith(('sec-websocket-', 'x-airam-'))}
        if origin is not None:
            headers['Origin'] = str(target.origin())
        if generation and self.available:
            headers['Accept-Encoding'] = 'identity'
        if provider == 'comfy' and path in ('/ws', '/api/ws') and request.headers.get('Upgrade', '').lower() == 'websocket':
            return await self.websocket(request, target, headers)

        # Only submission requests must be replayable. Uploads and other ComfyUI routes stream.
        data = await request.read() if generation else request.content if request.can_read_body else None
        model = self.model_name(data) if generation and provider != 'comfy' else ''
        if generation:
            self.count(provider, 'received')
        retried = False
        try:
            tried = generation and await self.preflight(provider, model, port, media=media)
            if provider == 'comfy' and (generation or path in ('/', '/system_stats', '/api/system_stats')):
                await self.start_comfy_if_needed(port)
            while True:
                if generation:
                    await self.wait_for_release(provider)
                    if self.ports[provider] != port:
                        raise web.HTTPConflict()
                    self.active[provider] += 1
                try:
                    async with request.app['upstream'].request(request.method, target, headers=headers, data=data,
                              allow_redirects=False) as upstream:
                        buffered, kind = None, None
                        if generation and not tried and self.available:
                            buffered, error = await error_body(upstream)
                            kind = memory_failure(provider, upstream.status, error)
                        if not kind:
                            result = await relay_response(request, upstream, response_headers(upstream), buffered)
                            if retried and 200 <= upstream.status < 300:
                                self.count(provider, 'recovered')
                            return result
                        status, result_headers = upstream.status, response_headers(upstream)
                finally:
                    if generation:
                        self.active[provider] -= 1
                if not await self.recover(provider, model, kind, port):
                    return web.Response(status=status, headers=result_headers, body=buffered)
                tried = retried = True
                self.count(provider, 'retried')
        except (aiohttp.ClientError, TimeoutError):
            if request.get('ai_response_started'):
                if request.transport:
                    request.transport.close()
                raise asyncio.CancelledError
            return web.json_response({'error': {'message': '로컬 서버에 연결하지 못했어요.',
                                                'code': 'local_upstream_unavailable'}},
                                     status=503, headers={'Retry-After': '5'})

    @staticmethod
    async def websocket(request, target, headers):
        try:
            async with request.app['upstream'].ws_connect(target, headers=headers, heartbeat=30,
                                                           max_msg_size=64 * 1024 * 1024) as upstream:
                browser = web.WebSocketResponse(heartbeat=30, max_msg_size=64 * 1024 * 1024)
                await browser.prepare(request)

                async def pipe(source, destination):
                    async for msg in source:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            await destination.send_str(msg.data)
                        elif msg.type == aiohttp.WSMsgType.BINARY:
                            await destination.send_bytes(msg.data)
                        elif msg.type == aiohttp.WSMsgType.ERROR:
                            break

                tasks = (asyncio.create_task(pipe(browser, upstream)), asyncio.create_task(pipe(upstream, browser)))
                try:
                    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for task in tasks:
                        task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    await browser.close()
                return browser
        except aiohttp.ClientError:
            raise web.HTTPServiceUnavailable(text='ComfyUI 화면에 연결하지 못했어요.') from None
