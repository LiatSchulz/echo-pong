#!/usr/bin/env python3
"""Measure ingress availability during a restart, image update, or rollback."""
import argparse
import concurrent.futures
import json
import pathlib
import re
import subprocess
import threading
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='Ingress URL, not a pod port-forward')
    parser.add_argument('--token-file', default='secrets/token')
    parser.add_argument('--host', default='echo-pong.localhost')
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument('--image', help='Deploy an immutable IMAGE@sha256 digest and pull from the registry')
    operation.add_argument('--rollback', action='store_true', help='Undo the previous deployment revision')
    args = parser.parse_args()
    if args.image and not re.fullmatch(r'[^\s@]+@sha256:[a-f0-9]{64}', args.image):
        parser.error('--image requires an immutable IMAGE@sha256:<64 hex characters> reference')
    token = pathlib.Path(args.token_file).read_text().strip()
    stop = threading.Event()
    lock = threading.Lock()
    results = {'requests': 0, 'failures': 0}
    errors = []
    command = ['kubectl', '--context', 'kind-echo-pong', '-n', 'echo-pong']

    def traffic():
        while not stop.is_set():
            try:
                request = urllib.request.Request(args.url.rstrip('/') + '/ping',
                                                 headers={'Authorization': 'Bearer ' + token, 'Host': args.host})
                with urllib.request.urlopen(request, timeout=3) as response:
                    valid = response.status == 200 and json.load(response)['message'] == 'pong'
                if not valid:
                    raise RuntimeError('Unexpected HTTP response')
                error = None
            except Exception as exception:
                error = type(exception).__name__
            with lock:
                results['requests'] += 1
                if error:
                    results['failures'] += 1
                    if len(errors) < 5:
                        errors.append(error)
            stop.wait(0.1)

    subprocess.run(command + ['rollout', 'status', 'deployment/echo-pong', '--timeout=180s'], check=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(traffic) for _ in range(4)]
        try:
            time.sleep(2)
            with lock:
                if results['requests'] == 0 or results['failures']:
                    raise RuntimeError('Ingress traffic failed before rollout')
            if args.image:
                patch = {'spec': {'template': {'spec': {'containers': [
                    {'name': 'echo-pong', 'image': args.image, 'imagePullPolicy': 'Always'}
                ]}}}}
                subprocess.run(command + ['patch', 'deployment', 'echo-pong', '--type=strategic',
                                          '-p', json.dumps(patch)], check=True)
            elif args.rollback:
                subprocess.run(command + ['rollout', 'undo', 'deployment/echo-pong'], check=True)
            else:
                subprocess.run(command + ['rollout', 'restart', 'deployment/echo-pong'], check=True)
            subprocess.run(command + ['rollout', 'status', 'deployment/echo-pong', '--timeout=180s'], check=True)
            time.sleep(5)
        finally:
            stop.set()
            for future in futures:
                future.result()
    print(json.dumps({**results, 'sample_errors': errors}))
    if results['requests'] == 0 or results['failures']:
        raise SystemExit('FAIL: deployment change interrupted ingress traffic')
    print('PASS: deployment change completed without observed HTTP failures')


if __name__ == '__main__':
    main()
