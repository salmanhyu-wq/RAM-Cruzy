"""Splash loopback admission and per-request management for AI 램 관리."""
import asyncio
import base64
import binascii
from dataclasses import dataclass, field
import json
import logging
import os
import socket
import time
import uuid

import aiohttp
from aiohttp import web
from splash_sleep import SplashSleep
from request_identity import match_request
from memory_fit import (COMFY_ALIAS_PORT, COMFY_BRIDGE_PORT, FIT_GATE_VERSION, MemoryFit,
                        error_body, memory_failure, relay_response)

UPSTREAM = 'http://127.0.0.1:' + os.environ.get('SPLASH_INTERNAL_PORT', '18008')
PORT = int(os.environ.get('SPLASH_SESSION_GATE_PORT', '8002'))
LEGACY_PORT = int(os.environ.get('SPLASH_SHARED_PORT', '0'))
MAX_WAITERS = 16
WAIT_SECONDS = 420
GENERATION_SECONDS = 540
RETRY_BLOCK_SECONDS = 90
HOP_HEADERS = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
               'te', 'trailers', 'transfer-encoding', 'upgrade', 'host', 'content-length'}
GENERATE = {'/v1/chat/completions', '/v1/responses', '/v1/messages', '/v1/completions',
            '/v1/judgments', '/v1/systemone', '/api/chat', '/api/generate'}
CONTROL_POST = {'/v1/chat/completions/count_tokens', '/v1/messages/count_tokens', '/tokenize',
                '/apply-template', '/v1/memory/release'}


def label(value, limit=120):
    if not isinstance(value, str):
        return ''
    return ''.join(c for c in value if c.isprintable())[:limit]


def identity_header(request, name):
    value = request.headers.get('X-AIRAM-' + name, '')
    if not value or len(value) > 700:
        return ''
    try:
        return label(base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True).decode())
    except (UnicodeError, binascii.Error):
        return ''


def client_name(request):
    agent = request.headers.get('User-Agent', '').lower()
    for token, name in (('hermes', 'Hermes'), ('mozilla/', '브라우저'), ('curl/', '터미널')):
        if token in agent:
            return name
    return '로컬 요청'


@dataclass
class Job:
    role: str
    model: str
    profile: str
    session: str
    turn: str
    client: str
    task: asyncio.Task
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    started: float = field(default_factory=time.monotonic)
    slot: int | None = None
    stopping: bool = False
    scope: str = "profiles"
    source: str = ""
    attribution: str = "unknown"

    def view(self):
        return {'id': self.id, 'role': self.role, 'model': self.model, 'profile': self.profile,
                'session': self.session, 'client': self.client, 'slot': self.slot,
                'scope': self.scope, 'source': self.source, 'attribution': self.attribution,
                'seconds': int(time.monotonic() - self.started),
                'state': 'stopping' if self.stopping else 'working' if self.slot else 'queued'}

    @property
    def turn_key(self):
        return (self.profile, self.session, self.turn) if self.profile and self.session and self.turn else None


class Gate:
    def __init__(self):
        self.limit = {'user': 1, 'bot': 3}
        self.slots = {role: asyncio.Semaphore(count) for role, count in self.limit.items()}
        self.used_slots = {role: set() for role in self.limit}
        self.active = dict.fromkeys(self.limit, 0)
        self.waiting = dict.fromkeys(self.limit, 0)
        self.completed = dict.fromkeys(self.limit, 0)
        self.rejected = dict.fromkeys(self.limit, 0)
        self.jobs = {}
        self.recent_jobs = []
        self.cancelled_turns = {}
        self.peak = 0
        self.last_finish = None
        self.releasing = False
        self.control_requests = 0
        self.cache = SplashSleep(UPSTREAM)
        self.waking = None
        self.fit = MemoryFit(PORT, int(os.environ.get('SPLASH_INTERNAL_PORT', '18008')), LEGACY_PORT)

    async def status(self, request):
        # Existing clients (including browser reads on the legacy port) keep the original shape.
        data = {'limit': self.limit, 'active': self.active, 'waiting': self.waiting,
                'completed': self.completed, 'rejected': self.rejected, 'peak': self.peak,
                'wait_seconds': WAIT_SECONDS, 'generation_seconds': GENERATION_SECONDS,
                'idle_seconds': round(time.monotonic() - self.last_finish, 2) if self.last_finish else None}
        if self.is_manager(request):
            data.update(management=1, controls_version=FIT_GATE_VERSION, jobs=[job.view() for job in self.jobs.values()],
                        recent_jobs=[view for stamp, view in self.recent_jobs if time.monotonic() - stamp < 3600],
                        cache_sleep=self.cache.supported(), sleeping=self.cache.saved is not None,
                        splash_transition=self.model_control_busy,
                        splash_problem='model_switch_failed' if self.cache.failed_model else None)
        return web.json_response(data, headers={'Cache-Control': 'no-store'})

    @staticmethod
    def is_manager(request):
        return (request.host in {f'127.0.0.1:{PORT}', f'localhost:{PORT}'}
                and request.headers.get('X-AIRAM-Control') == '1'
                and not request.headers.get('Origin') and not request.headers.get('Sec-Fetch-Site'))

    @staticmethod
    def cancelled():
        return web.json_response({'error': {'message': 'This request was stopped.',
                                  'type': 'invalid_request_error', 'code': 'request_cancelled'}}, status=422)

    async def cancel(self, request):
        if not self.is_manager(request) or request.content_type != 'application/json':
            raise web.HTTPForbidden()
        if request.content_length is None or request.content_length > 2048:
            raise web.HTTPBadRequest()
        try:
            data = await request.json()
        except (ValueError, UnicodeError):
            raise web.HTTPBadRequest() from None
        if not isinstance(data, dict) or not isinstance(data.get('id'), str):
            raise web.HTTPBadRequest()
        job = self.jobs.get(data['id'])
        if job is None:
            raise web.HTTPNotFound()
        if not job.stopping:
            job.stopping = True
            if job.turn_key:
                self.cancelled_turns[job.turn_key] = time.monotonic() + RETRY_BLOCK_SECONDS
            job.task.cancel()
        return web.json_response({'accepted': True}, status=202)

    def capacity_error(self, role):
        self.rejected[role] += 1
        return web.json_response({'error': {'message': 'The local model is busy. Retry after active work has finished.',
                                  'type': 'server_error', 'code': 'local_queue_busy'}},
                                 status=503, headers={'Retry-After': '5'})

    @property
    def model_control_busy(self):
        return self.releasing or (self.waking is not None and not self.waking.done())

    async def sleep_cache(self, request):
        if not self.is_manager(request) or request.content_type != 'application/json':
            raise web.HTTPForbidden()
        if request.content_length is None or request.content_length > 256:
            raise web.HTTPBadRequest()
        try:
            port = (await request.json()).get('video_port')
        except (ValueError, AttributeError):
            raise web.HTTPBadRequest() from None
        if type(port) is not int or not 1024 <= port <= 65535 or port in (PORT, LEGACY_PORT):
            raise web.HTTPBadRequest()
        if self.jobs or self.model_control_busy or self.control_requests:
            raise web.HTTPConflict()
        self.releasing = True
        def busy():
            return self.jobs or self.control_requests

        if request.path.endswith('/reset'):
            control = self.cache.reset(request.app['upstream'], port, busy)
        else:
            control = self.cache.sleep(request.app['upstream'], port, busy, paused=request.path.endswith('/stop'))
        operation = asyncio.create_task(control)
        operation.add_done_callback(lambda _: setattr(self, 'releasing', False))
        if not await asyncio.shield(operation):
            raise web.HTTPConflict()
        return web.json_response({'sleeping': True})

    async def wake_cache(self, request):
        if not self.is_manager(request) or request.content_type != 'application/json':
            raise web.HTTPForbidden()
        if self.releasing:
            raise web.HTTPConflict()
        if self.waking is None or self.waking.done():
            self.waking = asyncio.create_task(self.cache.wake(request.app['upstream'], explicit=True))
        if not await asyncio.shield(self.waking):
            raise web.HTTPServiceUnavailable()
        return web.json_response({'sleeping': False})

    async def load_model(self, request):
        if not self.is_manager(request) or request.content_type != 'application/json':
            raise web.HTTPForbidden()
        if request.content_length is None or request.content_length > 4096:
            raise web.HTTPBadRequest()
        try:
            body = await request.json()
            path, port = body['path'], body['video_port']
            if not isinstance(path, str) or type(port) is not int or not 1024 <= port <= 65535:
                raise ValueError()
        except (ValueError, TypeError, KeyError):
            raise web.HTTPBadRequest() from None
        if self.jobs or self.model_control_busy or self.control_requests:
            raise web.HTTPConflict()
        self.releasing = True
        operation = asyncio.create_task(self.cache.load_model(request.app['upstream'], path, port,
                                        lambda: self.jobs or self.control_requests))
        operation.add_done_callback(lambda _: setattr(self, 'releasing', False))
        if not await asyncio.shield(operation):
            raise web.HTTPConflict()
        return web.json_response({'loaded': True})

    async def ensure_awake(self, request):
        if self.cache.saved is not None and self.cache.saved['status'].get('empty'):
            raise web.HTTPServiceUnavailable(text='Splash is ready. Select a model before sending requests.')
        if self.cache.saved is not None and self.cache.saved['status'].get('paused'):
            raise web.HTTPServiceUnavailable(text='Splash server is turned off. Turn it on in RAM Cruji.')
        if self.cache.saved is None:
            return
        if self.waking is None or self.waking.done():
            self.waking = asyncio.create_task(self.cache.wake(request.app['upstream']))
        if not await asyncio.shield(self.waking):
            raise web.HTTPServiceUnavailable(headers={'Retry-After': '5'})

    async def fit_status(self, request):
        if not self.is_manager(request):
            raise web.HTTPForbidden()
        state = self.fit.snapshot()
        state['routes']['splash']['active'] = max(0, sum(self.active.values()) - state['routes']['splash']['holding'])
        return web.json_response(state, headers={'Cache-Control': 'no-store'})

    async def fit_control(self, request):
        if not self.is_manager(request) or request.content_type != 'application/json':
            raise web.HTTPForbidden()
        if request.content_length is None or request.content_length > 2048:
            raise web.HTTPBadRequest()
        try:
            data = await request.json()
        except (ValueError, UnicodeError):
            raise web.HTTPBadRequest() from None
        if not isinstance(data, dict):
            raise web.HTTPBadRequest()
        if request.path.endswith('/reserve'):
            return web.json_response({'ok': self.fit.reserve(data)})
        state = self.fit.update(data)
        state['routes']['splash']['active'] = max(0, sum(self.active.values()) - state['routes']['splash']['holding'])
        return web.json_response(state, headers={'Cache-Control': 'no-store'})

    async def fit_proxy(self, request):
        ingress = request.transport.get_extra_info('sockname')[1]
        if ingress != PORT:
            raise web.HTTPNotFound()
        return await self.fit.proxy(request, request.match_info['provider'],
                                    '/' + request.match_info['path'], ingress)

    @web.middleware
    async def comfy_bridge(self, request, handler):
        ingress = request.transport.get_extra_info('sockname')[1]
        if ingress == self.fit.comfy_port or ingress in self.fit.comfy_aliases:
            return await self.fit.proxy(request, 'comfy', request.path, ingress)
        return await handler(request)

    async def proxy(self, request):
        role = request.match_info.get('role')
        path = '/' + request.match_info['path']
        ingress = request.transport.get_extra_info('sockname')[1]
        if role is not None and ingress != PORT:
            raise web.HTTPNotFound()
        role = role or 'bot'
        data = await request.read() if request.can_read_body else None
        if request.method in ('GET', 'HEAD', 'OPTIONS') or (request.method == 'DELETE' and path.startswith('/v1/responses/')):
            saved = self.cache.saved
            if saved and request.method in ('GET', 'HEAD'):
                if path == '/status':
                    return web.json_response(saved['status'], headers={'Cache-Control': 'no-store'})
                if path == '/v1/models':
                    return web.json_response(saved['models'], headers={'Cache-Control': 'no-store'})
                if path.startswith('/v1/models/'):
                    model = next((row for row in saved['models']['data'] if row.get('id') == path[11:]), None)
                    if model is None:
                        raise web.HTTPNotFound()
                    return web.json_response(model)
                if path in ('/ready', '/health'):
                    empty = saved['status'].get('empty') is True
                    return web.json_response({'status': 'ready' if path == '/ready' else 'ok',
                                              'sleeping': not empty, 'empty': empty},
                                             status=503 if saved['status'].get('paused') and not empty and path == '/ready' else 200)
                if path in ('/metrics', '/metrics.json'):
                    raise web.HTTPServiceUnavailable(headers={'Retry-After': '5'})
                await self.ensure_awake(request)
            return await self.forward(request, path, data)
        if request.method != 'POST':
            raise web.HTTPMethodNotAllowed(request.method, ('GET', 'HEAD', 'OPTIONS', 'POST'))
        if path == '/v1/memory/release':
            if self.jobs or self.model_control_busy:
                return web.json_response({'error': {'code': 'engine_busy'}}, status=409)
            if self.cache.saved is not None:
                return web.json_response({'released': True, 'weights': {'released': True}})
            self.releasing = True
            try:
                return await self.forward(request, path, data)
            finally:
                self.releasing = False
        if path in CONTROL_POST:
            if self.releasing:
                return self.capacity_error(role)
            self.control_requests += 1
            try:
                await self.ensure_awake(request)
                return await self.forward(request, path, data)
            finally:
                self.control_requests -= 1
        if path not in GENERATE:
            raise web.HTTPNotFound()
        try:
            body = json.loads(data)
            if not isinstance(body, dict):
                raise ValueError('Expected a JSON object')
            body['priority'] = 'foreground' if role == 'user' else 'normal'
            if body.get('timeout') is None:
                body['timeout'] = GENERATION_SECONDS
            data = json.dumps(body, ensure_ascii=False).encode()
        except (ValueError, TypeError):
            return web.json_response({'error': {'message': 'Invalid JSON request', 'type': 'invalid_request_error'}}, status=400)
        if self.releasing or (sum(self.waiting.values()) >= MAX_WAITERS and self.slots[role].locked()):
            return self.capacity_error(role)

        profile, session = identity_header(request, 'Profile'), identity_header(request, 'Session')
        scope = identity_header(request, 'Scope') or 'profiles'
        client = identity_header(request, 'Client') or ('Hermes' if profile else client_name(request))
        source = identity_header(request, 'Source')
        attribution = 'linked' if profile and session else 'unknown'
        if not profile and not session:
            try:
                matched = await asyncio.to_thread(match_request, body)
            except Exception as error:
                logging.warning('Caller attribution unavailable: %s', type(error).__name__)
                matched = {}
            if matched:
                profile, session, scope = matched['profile'], matched['session'], matched['scope']
                client, source, attribution = matched['client'], matched['source'], matched['attribution']
        if self.releasing:
            return self.capacity_error(role)
        job = Job(role, label(body.get('model')), profile, session, identity_header(request, 'Turn'),
                  client, asyncio.current_task(), scope=scope, source=source, attribution=attribution)
        now = time.monotonic()
        self.cancelled_turns = {k: v for k, v in self.cancelled_turns.items() if v > now}
        if job.turn_key and job.turn_key in self.cancelled_turns:
            return self.cancelled()
        self.jobs[job.id] = job
        self.fit.count('splash', 'received')
        try:
            self.waiting[role] += 1
            try:
                async with asyncio.timeout(WAIT_SECONDS):
                    await self.slots[role].acquire()
            except TimeoutError:
                return self.capacity_error(role)
            finally:
                self.waiting[role] -= 1
            job.slot = next(n for n in range(1, self.limit[role] + 1) if n not in self.used_slots[role])
            self.used_slots[role].add(job.slot)
            self.active[role] += 1
            self.peak = max(self.peak, sum(self.active.values()))
            await self.fit.wait_for_release('splash')
            tried = await self.fit.preflight('splash', job.model, PORT)
            await self.ensure_awake(request)
            response = await self.forward(request, path, data, fit_job=job, tried=tried)
            self.completed[role] += 1
            if 200 <= response.status < 300:
                view = job.view()
                view['state'] = 'finished'
                self.recent_jobs.insert(0, (time.monotonic(), view))
                self.recent_jobs = self.recent_jobs[:12]
            return response
        except asyncio.CancelledError:
            if not job.stopping:
                raise
            if request.get('ai_response_started'):
                if request.transport:
                    request.transport.close()
                raise
            return self.cancelled()
        finally:
            self.jobs.pop(job.id, None)
            if job.slot is not None:
                self.used_slots[role].remove(job.slot)
                self.active[role] -= 1
                self.last_finish = time.monotonic()
                self.slots[role].release()

    async def forward(self, request, path, data, fit_job=None, tried=False):
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() not in HOP_HEADERS and not k.lower().startswith('x-airam-')}
        same_origin = request.headers.get('Origin') == 'http://' + request.host and request.host in {
            f'{host}:{port}' for host in ('localhost', '127.0.0.1') for port in (PORT, LEGACY_PORT) if port
        }
        if same_origin:
            headers['Origin'] = UPSTREAM
        if fit_job is not None and self.fit.available:
            headers['Accept-Encoding'] = 'identity'
        retried = False
        try:
            while True:
                async with request.app['upstream'].request(request.method, UPSTREAM + path,
                          params=request.query, headers=headers, data=data, allow_redirects=False) as response:
                    forwarded = {k: v for k, v in response.headers.items()
                                 if k.lower() not in HOP_HEADERS or k.lower() == 'content-length'}
                    if same_origin and forwarded.get('Access-Control-Allow-Origin') == UPSTREAM:
                        forwarded['Access-Control-Allow-Origin'] = 'http://' + request.host
                    buffered, kind = None, None
                    if fit_job is not None and not tried and self.fit.available:
                        buffered, error = await error_body(response)
                        kind = memory_failure('splash', response.status, error)
                    if not kind:
                        result = await relay_response(request, response, forwarded, buffered)
                        if retried and 200 <= response.status < 300:
                            self.fit.count('splash', 'recovered')
                        return result
                    status = response.status
                if not await self.fit.recover('splash', fit_job.model, kind, PORT):
                    return web.Response(status=status, headers=forwarded, body=buffered)
                tried = retried = True
                self.fit.count('splash', 'retried')
        except (aiohttp.ClientError, TimeoutError) as error:
            logging.warning('Splash upstream error for %s: %s', path, type(error).__name__)
            if request.get('ai_response_started'):
                if request.transport:
                    request.transport.close()
                raise asyncio.CancelledError from None
            return web.json_response({'error': {'message': 'Waiting for the Splash local runtime.',
                                      'type': 'server_error', 'code': 'local_upstream_unavailable'}},
                                     status=503, headers={'Retry-After': '3'})


async def upstream_session(app):
    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=600, connect=5, sock_read=570),
        auto_decompress=False, trust_env=False,
    ) as client:
        app['upstream'] = client
        yield


async def profile_connections(app):
    from setup import configure_plugin
    async def synchronize():
        while True:
            try:
                await asyncio.to_thread(configure_plugin, True)
            except Exception as error:
                logging.warning('Identity connection sync unavailable: %s', type(error).__name__)
            await asyncio.sleep(60)
    task = asyncio.create_task(synchronize())
    yield
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)


def make_app(sync_profiles=False, comfy_port=None, comfy_aliases=()):
    gate = Gate()
    gate.fit.comfy_port = comfy_port
    gate.fit.comfy_aliases = set(comfy_aliases)
    app = web.Application(client_max_size=128 * 1024 * 1024, middlewares=[gate.comfy_bridge])
    app.cleanup_ctx.append(upstream_session)
    if sync_profiles:
        app.cleanup_ctx.append(profile_connections)
    app.router.add_get('/gate', gate.status)
    app.router.add_get('/gate/fit', gate.fit_status)
    app.router.add_post('/gate/fit', gate.fit_control)
    app.router.add_post('/gate/fit/reserve', gate.fit_control)
    app.router.add_route('*', '/fit/{provider}/{path:.*}', gate.fit_proxy)
    app.router.add_post('/gate/cancel', gate.cancel)
    app.router.add_post('/gate/splash/sleep', gate.sleep_cache)
    app.router.add_post('/gate/splash/stop', gate.sleep_cache)
    app.router.add_post('/gate/splash/reset', gate.sleep_cache)
    app.router.add_post('/gate/splash/load', gate.load_model)
    app.router.add_post('/gate/splash/wake', gate.wake_cache)
    app.router.add_route('*', '/{role:user|bot}/{path:.*}', gate.proxy)
    app.router.add_route('*', '/{path:.*}', gate.proxy)
    return app


def main():
    logging.basicConfig(level=logging.INFO)
    listeners = []
    try:
        comfy_ports = []
        comfy_listeners = (COMFY_BRIDGE_PORT, COMFY_ALIAS_PORT)
        for port in dict.fromkeys(p for p in (PORT, LEGACY_PORT, *comfy_listeners) if p):
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listeners.append(listener)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind(('127.0.0.1', port))
            except OSError:
                if port in (PORT, LEGACY_PORT):
                    raise
                listener.close()
                listeners.pop()
                logging.warning('ComfyUI RAM bridge port %s is in use', port)
                continue
            listener.listen(128)
            if port in comfy_listeners and port not in (PORT, LEGACY_PORT):
                comfy_ports.append(port)
        comfy_port = comfy_ports[0] if comfy_ports else None
        web.run_app(make_app(sync_profiles=True, comfy_port=comfy_port, comfy_aliases=comfy_ports[1:]),
                    sock=listeners, access_log=None, handler_cancellation=True, shutdown_timeout=10)
    finally:
        for listener in listeners:
            listener.close()


if __name__ == '__main__':
    main()
