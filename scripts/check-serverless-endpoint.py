"""Report a bootstrap candidate or smoke-test the actual Terraform-created API."""
import json
import os
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def output(name):
    return json.loads(subprocess.check_output(['terraform', '-chdir=infra', 'output', '-json', name], text=True))


def main():
    url = output('api_gateway_url').rstrip('/')
    candidate = output('auth_candidate_version')
    active = output('auth_public_active')
    summary = f'API_GATEWAY_URL={url}\nAUTH_CANDIDATE_VERSION={candidate}\nAUTH_PUBLIC_ACTIVE={str(active).lower()}\n'
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as handle:
            handle.write(summary)
    if not active:
        print('Fresh bootstrap complete. Test the numbered candidate before activating prod; public routes remain disabled.')
        return
    for attempt in range(3):
        try:
            request = Request(url + '/api/auth/cpf', data=b'{"cpf":"11111111111"}',
                              headers={'Content-Type': 'application/json'}, method='POST')
            with urlopen(request, timeout=40) as response:
                status = response.status
        except HTTPError as error:
            status = error.code
            error.close()
        except (URLError, TimeoutError):
            status = 0
        if status == 422:
            print('Actual API endpoint smoke passed: invalid CPF returned HTTP 422.')
            return
        if attempt < 2:
            time.sleep(10)
    raise RuntimeError('Actual API endpoint did not return HTTP 422; response bodies suppressed.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        print('Serverless post-check failed; no credentials or response body printed.', file=sys.stderr)
        sys.exit(1)
