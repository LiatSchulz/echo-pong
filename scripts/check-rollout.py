#!/usr/bin/env python3
"""Measure HTTP availability through ingress during a local rolling restart."""
import argparse
import concurrent.futures
import json
import pathlib
import subprocess
import threading
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='Ingress URL, not a pod port-forward')
    parser.add_argument('--token-file', default='secrets/token')
    parser.add_argument('--host', default='echo-pong.localhost')
    args = parser.parse_args()
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
            subprocess.run(command + ['rollout', 'restart', 'deployment/echo-pong'], check=True)
            subprocess.run(command + ['rollout', 'status', 'deployment/echo-pong', '--timeout=180s'], check=True)
            time.sleep(5)
        finally:
            stop.set()
            for future in futures:
                future.result()
    print(json.dumps({**results, 'sample_errors': errors}))
    if results['requests'] == 0 or results['failures']:
        raise SystemExit('FAIL: rolling restart interrupted ingress traffic')
    print('PASS: rolling restart completed without observed HTTP failures')


if __name__ == '__main__':
    main()
