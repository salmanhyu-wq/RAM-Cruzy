"""Exercise the real gate with an isolated local streaming server."""
import asyncio
import base64
from contextlib import AsyncExitStack
import importlib.util
from pathlib import Path
import sys
import tempfile
import plistlib

from aiohttp import ClientError, ClientSession, web


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '연결'))
spec = importlib.util.spec_from_file_location('airam_gate', ROOT / '연결/splash_gate.py')
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)


def label(value):
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip('=')


async def serve(app, stack):
    runner = web.AppRunner(app, handler_cancellation=True)
    await runner.setup()
    stack.push_async_callback(runner.cleanup)
    site = web.TCPSite(runner, '127.0.0.1', 0)
    await site.start()
    return runner.addresses[0][1]


async def wait_for(function):
    async with asyncio.timeout(4):
        while True:
            result = await function()
            if result:
                return result
            await asyncio.sleep(.03)


async def run():
    records = {}
    removed = set()
    done = asyncio.Event()
    releases = []
    async with AsyncExitStack() as stack:
        upstream = web.Application()

        async def completion(request):
            assert request.headers.get('X-AIRAM-Session') is None
            body = await request.json()
            assert body['timeout'] == 540
            model = body['model']
            records[model] = body['priority']
            reply = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await reply.prepare(request)
            try:
                for _ in range(60):
                    await reply.write(b'data: processing\n\n')
                    if done.is_set():
                        break
                    await asyncio.sleep(.05)
                await reply.write(b'data: [DONE]\n\n')
            except (ConnectionError, asyncio.CancelledError):
                removed.add(model)
                raise
            return reply

        async def release(request):
            releases.append(True)
            return web.json_response({'released': True})

        upstream.router.add_post('/v1/chat/completions', completion)
        upstream.router.add_post('/v1/memory/release', release)
        gate.UPSTREAM = f'http://127.0.0.1:{await serve(upstream, stack)}'
        gate.PORT = await serve(gate.make_app(), stack)
        base = f'http://127.0.0.1:{gate.PORT}'
        client = await stack.enter_async_context(ClientSession())
        control = {'X-AIRAM-Control': '1'}

        async def request(role, model, turn):
            headers = {'X-AIRAM-Profile': label('예시 봇'), 'X-AIRAM-Session': label('session-1'),
                       'X-AIRAM-Turn': label(turn), 'X-AIRAM-Scope': label('office'),
                       'X-AIRAM-Client': label('Paperclip → Hermes')}
            try:
                async with client.post(f'{base}/{role}/v1/chat/completions', json={'model': model}, headers=headers) as response:
                    return response.status, await response.text()
            except ClientError:
                return None, ''

        async def status():
            async with client.get(base + '/gate', headers=control) as response:
                return await response.json()

        async def post(path, data, headers=control):
            async with client.post(base + path, json=data, headers=headers) as response:
                return response.status

        async def jobs(size):
            data = await status()
            return data if len(data['jobs']) == size else None

        tasks = [asyncio.create_task(request(role, model, model)) for role, model in
                 [('user', 'personal'), ('bot', 'one'), ('bot', 'two'), ('bot', 'three')]]
        try:
            data = await wait_for(lambda: jobs(4))
            assert data['active'] == {'user': 1, 'bot': 3}, data
            assert {a['slot'] for a in data['jobs'] if a['role'] == 'bot'} == {1, 2, 3}
            assert all(a['profile'] == '예시 봇' and a['session'] == 'session-1' for a in data['jobs'])
            assert all(a['scope'] == 'office' and a['client'] == 'Paperclip → Hermes' for a in data['jobs'])
            queued = asyncio.create_task(request('bot', 'queued', 'queued'))
            tasks.append(queued)
            data = await wait_for(lambda: jobs(5))
            pending = next(a for a in data['jobs'] if a['model'] == 'queued')
            assert pending['slot'] is None
            assert await post('/v1/memory/release', {}) == 409
            assert await post('/gate/cancel', {'id': pending['id']}, {'Origin': 'https://example.test', **control}) == 403
            assert await post('/gate/cancel', {'id': pending['id']}) == 202
            assert (await queued)[0] == 422
            assert 'queued' not in records

            selected = next(a for a in data['jobs'] if a['model'] == 'two')
            assert await post('/gate/cancel', {'id': selected['id']}) == 202
            assert (await request('bot', 'two', 'two'))[0] == 422
            data = await wait_for(lambda: jobs(3))
            assert data['active'] == {'user': 1, 'bot': 2}, data

            async def selected_stopped():
                return removed == {'two'}
            await wait_for(selected_stopped)
            done.set()
            for index in (0, 1, 3):
                code, output = await tasks[index]
                assert code == 200 and '[DONE]' in output
            await wait_for(lambda: jobs(0))
            assert await post('/v1/memory/release', {}) == 200
            assert len(releases) == 1
            assert len((await status())['recent_jobs']) == 3
            assert all(job['state'] == 'finished' for job in (await status())['recent_jobs'])
            assert records == {'personal': 'foreground', 'one': 'normal', 'two': 'normal', 'three': 'normal'}
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    plugin_path = ROOT / '연결/Hermes/ai-ram-manager/__init__.py'
    plugin_spec = importlib.util.spec_from_file_location('airam_plugin', plugin_path)
    plugin = importlib.util.module_from_spec(plugin_spec)
    plugin_spec.loader.exec_module(plugin)
    assert plugin.attach_identity({}, 'https://example.test:8002/v1') is None
    payload = plugin.attach_identity({'extra_headers': {'Existing': 'value'}}, 'http://127.0.0.1:8002/bot/v1', 'abc', 'turn')
    assert payload['request']['extra_headers']['Existing'] == 'value'
    assert payload['request']['extra_headers']['X-AIRAM-Session'] == label('abc')
    print('개인 1 + 봇 3, 대기 취소, 선택 슬롯 중단, 같은 턴 재시도 차단, 유휴 회수 및 로컬 메타데이터 검증 완료')


async def check_cache():
    video = True
    cached = True
    running = True
    starts = 0
    loaded_name = 'test'
    stopping = 0

    class TestSplash(gate.SplashSleep):
        def supported(self):
            return True

        async def launchctl(self, operation, *_):
            nonlocal running, starts, loaded_name, stopping
            if operation == 'print':
                if stopping:
                    stopping -= 1
                    if stopping == 0:
                        running = False
                return running
            if operation == 'bootout':
                stopping = 3  # bootout returns while launchd still lists the old service
            if operation == 'bootstrap':
                assert not running and not stopping
                if getattr(self, 'fail_boot', False):
                    self.fail_boot = False
                    raise OSError('simulated startup failure')
                if self.job.exists():
                    args = plistlib.loads(self.job.read_bytes())['ProgramArguments']
                    loaded_name = args[args.index('--model') + 1]
                running = True
                starts += 1
            return True

    async def queue(_):
        return web.json_response({'queue_running': [['video']] if video else [], 'queue_pending': []})

    async def ready(_):
        return web.json_response({'status': 'ready'}, status=200 if running else 503)

    async def status(_):
        return web.json_response({'ready': running, 'instance': {'id': 'one', 'model': loaded_name}, 'active_requests': [],
                                  'transport': {'status_stale': False, 'pending': 0},
                                  'frontend': {'active': 0, 'waiting': 0}, 'weights': {'released': True, 'restoring': False},
                                  'kv': {'pages_active': 0, 'pages_cache': 32 if cached else 0}, 'scheduler': dict.fromkeys(
                                      ('queued', 'prefilling', 'decoding', 'waiting_resources', 'waiting_prefix', 'waiting_mask'), 0)})

    async def models(_):
        return web.json_response({'data': [{'id': 'test'}]})

    async def completion(_):
        assert running
        return web.json_response({'response': 'ok'})

    with tempfile.TemporaryDirectory() as folder:
        TestSplash.marker = Path(folder) / 'sleep.json'
        TestSplash.job = Path(folder) / 'model-server.plist'
        args = ['python3', '-B', '-m', 'install.launcher', 'serve', '--model', 'test']
        TestSplash.job.write_bytes(plistlib.dumps({'ProgramArguments': args}))
        gate.SplashSleep = TestSplash
        async with AsyncExitStack() as stack:
            upstream = web.Application()
            upstream.router.add_get('/queue', queue)
            upstream.router.add_get('/status', status)
            upstream.router.add_get('/v1/models', models)
            upstream.router.add_get('/ready', ready)
            upstream.router.add_post('/v1/chat/completions', completion)
            video_port = await serve(upstream, stack)
            gate.UPSTREAM = f'http://127.0.0.1:{video_port}'
            app_for_test = gate.make_app()
            gate.PORT = await serve(app_for_test, stack)
            base = f'http://127.0.0.1:{gate.PORT}'
            client = await stack.enter_async_context(ClientSession())
            payload = {'video_port': video_port}
            headers = {'X-AIRAM-Control': '1'}

            async def sleep_code(headers):
                async with client.post(base + '/gate/splash/sleep', json=payload, headers=headers) as response:
                    return response.status

            assert await sleep_code({}) == 403
            assert await sleep_code(headers) == 409
            video = False
            cached = False
            assert await sleep_code(headers) == 409
            cached = True
            assert await sleep_code(headers) == 200
            assert not running and TestSplash.marker.exists()
            assert TestSplash(gate.UPSTREAM).saved is not None
            for path in ('/status', '/v1/models', '/ready'):
                async with client.get(base + path) as response:
                    assert response.status == 200
            assert not running and starts == 0
            await asyncio.gather(*(client.post(base + '/v1/chat/completions', json={'model': 'test'}) for _ in range(2)))
            assert running and starts == 1 and not TestSplash.marker.exists()
            async with client.post(base + '/gate/splash/stop', json=payload, headers=headers) as response:
                assert response.status == 200
            assert not running and TestSplash(gate.UPSTREAM).saved['status']['paused'] is True
            async with client.post(base + '/v1/chat/completions', json={'model': 'test'}) as response:
                assert response.status == 503
            assert starts == 1 and not running
            async with client.get(base + '/ready') as response:
                assert response.status == 503
            async with client.post(base + '/gate/splash/wake', json={}, headers=headers) as response:
                assert response.status == 200
            assert running and starts == 2
            TestSplash.home = Path(folder) / 'home'
            model_dir = TestSplash.home / 'Application Support/Splash/local-models/new-model'
            model_dir.mkdir(parents=True)
            TestSplash.job = Path(folder) / 'model-server.plist'
            config = {'Label': TestSplash.label, 'ProgramArguments': ['python3', '-B', '-m', 'install.launcher', 'serve',
                      '--model', 'old', '--model-dir', 'old', '--mmproj', 'old/mmproj.gguf']}
            TestSplash.job.write_bytes(plistlib.dumps(config))
            async with client.post(base + '/gate/splash/load', json={'path': str(model_dir), 'video_port': video_port}, headers=headers) as response:
                assert response.status == 200
            updated = plistlib.loads(TestSplash.job.read_bytes())['ProgramArguments']
            assert updated[updated.index('--model-dir') + 1] == str(model_dir) and '--mmproj' not in updated
            async with client.post(base + '/gate/splash/load', json={'path': '/tmp/outside-model', 'video_port': video_port}, headers=headers) as response:
                assert response.status == 409
            assert running and not TestSplash.marker.exists()
            original = TestSplash.job.read_bytes()
            next_model = model_dir.parent / 'bad-model'
            next_model.mkdir()
            manager = next(route.handler.__self__ for route in app_for_test.router.routes() if getattr(route.handler, '__name__', '') == 'load_model')
            manager.cache.fail_boot = True
            async with client.post(base + '/gate/splash/load', json={'path': str(next_model), 'video_port': video_port}, headers=headers) as response:
                assert response.status == 409
            assert TestSplash.job.read_bytes() == original and running
            async with client.get(base + '/gate', headers=headers) as response:
                assert (await response.json())['splash_problem'] == 'model_switch_failed'
            video = True
            async with client.post(base + '/gate/splash/reset', json=payload, headers=headers) as response:
                assert response.status == 409 and running
            video = False
            async with client.post(base + '/gate/splash/reset', json=payload, headers=headers) as response:
                assert response.status == 200 and not running
            assert TestSplash.job.read_bytes() == original
            assert TestSplash(gate.UPSTREAM).saved['status']['empty'] is True
            async with client.get(base + '/ready') as response:
                assert response.status == 200 and (await response.json())['empty']
            async with client.get(base + '/v1/models') as response:
                assert (await response.json())['data'] == []
            async with client.post(base + '/v1/chat/completions', json={'model': 'test'}) as response:
                assert response.status == 503 and not running
            async with client.get(base + '/gate', headers=headers) as response:
                assert (await response.json())['splash_problem'] is None
            async with client.post(base + '/gate/splash/load', json={'path': str(model_dir), 'video_port': video_port}, headers=headers) as response:
                assert response.status == 200 and running
    print('늦은 서버 종료 대기, 실패 알림, 작업 보호, 빈 서버 초기화, 모델 다시 선택 검증 완료')


if __name__ == '__main__':
    asyncio.run(run())
    asyncio.run(check_cache())
