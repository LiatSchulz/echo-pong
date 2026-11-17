#!/usr/bin/env python3
"""Exercise an image with production-style runtime restrictions."""
import argparse
import json
import pathlib
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def docker(*args):
    result = subprocess.run(['docker', *args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'Docker {args[0]} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def request(base, path, token=None):
    headers = {'Authorization': token} if token else {}
    try:
        with urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=2) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', nargs='?', default='echo-pong:local')
    args = parser.parse_args()
    config = json.loads(docker('image', 'inspect', args.image))[0]['Config']
    if config['User'] != '65532:65532':
        raise RuntimeError('Image must default to UID/GID 65532')
    secret_dir = pathlib.Path(__file__).resolve().parent.parent / 'secrets'
    secret_dir.mkdir(exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(dir=secret_dir) as temporary:
        token = secrets.token_hex(32)
        token_file = pathlib.Path(temporary) / 'token'
        token_file.write_text(token)
        token_file.chmod(0o444)
        mount = f'type=bind,src={token_file},dst=/var/run/secrets/echo-pong/token,readonly'
        container = docker('run', '-d', '--read-only', '--cap-drop=ALL',
                           '--security-opt=no-new-privileges', '--pids-limit=64',
                           '--memory=64m', '--mount', mount, '-p', '127.0.0.1::8080', args.image)
        try:
            base = 'http://' + docker('port', container, '8080/tcp').splitlines()[0]
            deadline = time.monotonic() + 40
            while True:
                try:
                    status, body = request(base, '/health')
                    if status == 200 and body['status'] == 'healthy':
                        break
                except (OSError, urllib.error.URLError):
                    pass
                if time.monotonic() >= deadline:
                    raise RuntimeError('Container did not become healthy')
                time.sleep(0.5)
            for path, message in [('/ping', 'pong'), ('/pong', 'ping')]:
                for authorization in (token, 'Bearer ' + token):
                    status, body = request(base, path, authorization)
                    if status != 200 or body['message'] != message:
                        raise RuntimeError(f'Authenticated {path} failed')
                for authorization in (None, 'wrong-token'):
                    if request(base, path, authorization)[0] != 401:
                        raise RuntimeError(f'{path} accepted invalid credentials')
            docker('stop', '--time=30', container)
            state = json.loads(docker('inspect', container))[0]['State']
            if state['ExitCode'] != 0 or state['OOMKilled']:
                raise RuntimeError(f'Unclean shutdown: exit {state["ExitCode"]}')
            for command, message in [('ping', 'pong'), ('pong', 'ping')]:
                output = docker('run', '--rm', '--read-only', '--cap-drop=ALL',
                                '--security-opt=no-new-privileges', '--mount', mount,
                                args.image, '--mode=cli', '--password=' + token, command)
                if f'"message": "{message}"' not in output:
                    raise RuntimeError(f'CLI {command} failed')
            print('PASS: non-root image, restricted runtime, health, authentication, CLI, clean SIGTERM exit')
        finally:
            docker('rm', '-f', container)


if __name__ == '__main__':
    main()
