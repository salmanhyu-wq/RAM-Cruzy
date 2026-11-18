"""Integration coverage for the recovery bridge with isolated model servers."""
import asyncio
from contextlib import AsyncExitStack
from pathlib import Path
import socket
import sys

import aiohttp
from aiohttp import web

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '연결'))
import memory_fit
import splash_gate as gate


async def serve(app, stack, sock=None):
    runner = web.AppRunner(app, handler_cancellation=True)
    await runner.setup()
    stack.push_async_callback(runner.cleanup)
    site = web.SockSite(runner, sock) if sock else web.TCPSite(runner, '127.0.0.1', 0)
    await site.start()
    return runner.addresses[0][1]


def listener(stack):
    sock = stack.enter_context(socket.socket())
    sock.bind(('127.0.0.1', 0))
    sock.listen()
    return sock


async def run():
    calls = {}
    stream_visible = asyncio.Event()
    stream_finish = asyncio.Event()
    recovery_done = asyncio.Event()

    async def generate(request):
        body = await request.json()
        model = body.get('model', 'comfy')
        calls.setdefault(model, []).append(body)
        if model == 'running':
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            await response.write(b'data: started\n\n')
            stream_visible.set()
            await stream_finish.wait()
            return response
        if model == 'hard':
            return web.json_response({'error': {'code': 'capacity_exhausted', 'message': 'out of memory'}}, status=400)
        if model == 'invalid':
            return web.json_response({'error': {'code': 'bad_request'}}, status=400)
        if model == 'comfy':
            assert recovery_done.is_set(), 'workflow was submitted before recovery'
            return web.json_response({'prompt_id': 'original'})
        if len(calls[model]) == 1 or model == 'twice':
            return web.json_response({'error': {'code': 'resource_timeout', 'message': 'memory timed out'}},
                                     status=503, headers={'Retry-After': '5'})
        return web.json_response({'model': model, 'generated': True})

    async def asset(request):
        return web.Response(text=request.headers.get('Origin', '') + '|' + request.query.get('file', ''))

    async def websocket(request):
        assert request.headers.get('Origin', '').endswith(str(request.transport.get_extra_info('sockname')[1]))
        response = web.WebSocketResponse()
        await response.prepare(request)
        async for message in response:
            await response.send_str(message.data)
            await response.send_bytes(b'preview')
        return response

    async with AsyncExitStack() as stack:
        upstream = web.Application()
        for endpoint in ('/v1/chat/completions', '/api/v1/chat', '/v1/video/generations', '/api/prompt'):
            upstream.router.add_post(endpoint, generate)
        upstream.router.add_get('/view', asset)
        upstream.router.add_get('/ws', websocket)
        ports = {provider: await serve(upstream, stack) for provider in memory_fit.DEFAULT_PORTS}
        splash_upstream = await serve(upstream, stack)
        gate.UPSTREAM = f'http://127.0.0.1:{splash_upstream}'
        gate_sock, comfy_sock = listener(stack), listener(stack)
        gate.PORT, comfy_port = gate_sock.getsockname()[1], comfy_sock.getsockname()[1]
        app = gate.make_app(comfy_port=comfy_port)
        runner = web.AppRunner(app, handler_cancellation=True)
        await runner.setup()
        stack.push_async_callback(runner.cleanup)
        for sock in (gate_sock, comfy_sock):
            await web.SockSite(runner, sock).start()
        client = await stack.enter_async_context(aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)))
        base = f'http://127.0.0.1:{gate.PORT}'
        comfy = f'http://127.0.0.1:{comfy_port}'
        control = {'X-AIRAM-Control': '1'}

        async def post(url, body, headers=None):
            async with client.post(url, json=body, headers=headers) as response:
                return response.status, await response.json(), response.headers

        async def update(**options):
            status, data, _ = await post(base + '/gate/fit', {'enabled': True, 'ports': ports, **options}, control)
            assert status == 200
            return data

        async def claim():
            async with asyncio.timeout(3):
                while True:
                    status = await update(ready=True, critical=critical)
                    if status['claim']:
                        return status['claim'], status
                    await asyncio.sleep(.02)

        async def reserve(job, provider):
            status, body, _ = await post(base + '/gate/fit/reserve',
                                        {'id': job['id'], 'provider': provider, 'port': ports[provider]}, control)
            return status == 200 and body['ok']

        critical = False
        await update()
        routes = (('splash', '/user/v1/chat/completions'), ('mlxServe', '/fit/mlxServe/v1/video/generations'),
                  ('lmStudio', '/fit/lmStudio/api/v1/chat'), ('mlxStudio', '/fit/mlxStudio/v1/chat/completions'))
        for provider, path in routes:
            job = asyncio.create_task(post(base + path, {'model': provider, 'seed': 7}))
            ticket, status = await claim()
            assert ticket['model'] == ticket['provider'] == provider and len(status['held']) == 1
            assert await reserve(ticket, 'comfy')
            await update(result={'id': ticket['id'], 'changed': True})
            assert (await job)[0] == 200 and len(calls[provider]) == 2
            assert calls[provider][0] == calls[provider][1]

        first = asyncio.create_task(post(base + '/fit/lmStudio/api/v1/chat', {'model': 'twice'}))
        ticket, _ = await claim()
        await update(result={'id': ticket['id'], 'changed': True})
        assert (await first)[0] == 503 and len(calls['twice']) == 2

        for model in ('hard', 'invalid'):
            result = await post(base + '/user/v1/chat/completions', {'model': model})
            assert result[0] == 400 and len(calls[model]) == 1
            assert not (await update(ready=True))['held']

        denied = asyncio.create_task(post(base + '/fit/lmStudio/api/v1/chat', {'model': 'no-space'}))
        ticket, _ = await claim()
        await update(result={'id': ticket['id'], 'changed': False})
        status, result, headers = await denied
        assert status == 503 and headers['Retry-After'] == '5'
        assert result['error']['code'] == 'resource_timeout' and len(calls['no-space']) == 1

        async with client.post(base + '/fit/mlxServe/v1/chat/completions', json={'model': 'running'}) as response:
            assert await response.content.readline() == b'data: started\n'
            await stream_visible.wait()
            attempt = asyncio.create_task(post(base + '/fit/lmStudio/api/v1/chat', {'model': 'with-stream'}))
            ticket, _ = await claim()
            assert not await reserve(ticket, 'mlxServe')
            await update(result={'id': ticket['id'], 'changed': True})
            assert (await attempt)[0] == 200
            stream_finish.set()

        critical = True
        await update(critical=True)
        prompt = asyncio.create_task(post(comfy + '/api/prompt', {'prompt': {'workflow': 1}}, {'Origin': comfy}))
        ticket, _ = await claim()
        assert ticket['provider'] == 'comfy' and ticket['reason'] == 'pressure'
        assert 'comfy' not in calls and not await reserve(ticket, 'comfy')
        recovery_done.set()
        critical = False
        await update(result={'id': ticket['id'], 'changed': True})
        assert (await prompt)[1]['prompt_id'] == 'original' and len(calls['comfy']) == 1

        critical = True
        await update(critical=True)
        prompt = asyncio.create_task(post(comfy + '/api/prompt', {'prompt': {}}, {'Origin': comfy}))
        ticket, _ = await claim()
        await update(critical=True, result={'id': ticket['id'], 'changed': False})
        assert (await prompt)[1]['error']['code'] == 'memory_pressure' and len(calls['comfy']) == 1
        await update(critical=False)
        critical = False

        async with client.get(comfy + '/view', params={'file': '한글 + #.png'}, headers={'Origin': comfy}) as response:
            assert await response.text() == f"http://127.0.0.1:{ports['comfy']}|한글 + #.png"
        async with client.ws_connect(comfy + '/ws', origin=comfy) as ws:
            await ws.send_str('progress')
            assert (await ws.receive()).data == 'progress'
            assert (await ws.receive()).data == b'preview'
        async with client.post(comfy + '/api/prompt', json={}, headers={'Origin': 'https://invalid.test'}) as response:
            assert response.status == 403

        waiting = asyncio.create_task(post(base + '/fit/lmStudio/api/v1/chat', {'model': 'disabled'}))
        await claim()
        await update(enabled=False)
        assert (await waiting)[0] == 503 and len(calls['disabled']) == 1
        assert not (await update())['held']

    print('비집고 넣기 확인: 서버 5종, 한 번 재시도, 실패 응답 유지, 실행 중 보호, ComfyUI 접수·화면·진행 표시')


if __name__ == '__main__':
    asyncio.run(run())
