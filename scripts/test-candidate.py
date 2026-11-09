"""Invoke an explicitly selected published candidate, without moving the prod alias."""
import argparse,base64,hashlib,hmac,json,os,subprocess,tempfile,time
from pathlib import Path

def verify_token(token,secret):
    parts=token.split('.')
    if len(parts)!=3:raise ValueError('Invalid JWT structure')
    def decode(value):return base64.urlsafe_b64decode(value+'='*((-len(value))%4))
    header=json.loads(decode(parts[0]));claims=json.loads(decode(parts[1]))
    signature=hmac.new(secret.encode(),(parts[0]+'.'+parts[1]).encode(),hashlib.sha256).digest()
    if header.get('alg')!='HS256' or not hmac.compare_digest(signature,decode(parts[2])):raise ValueError('Candidate JWT signature mismatch')
    audience=claims.get('aud');valid_audience=audience=='workshop-service' or isinstance(audience,list) and 'workshop-service' in audience
    if claims.get('iss')!='workshop-auth' or not valid_audience or not claims.get('sub') or claims.get('exp',0)<=time.time():raise ValueError('Candidate JWT claims mismatch')
    return True

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--function',required=True);p.add_argument('--version',required=True);a=p.parse_args()
    if not a.version.isdecimal() or int(a.version)<1:p.error('Use a numbered immutable candidate version; never prod or $LATEST')
    if not os.environ.get('TEST_CPF') or not os.environ.get('JWT_SECRET'):p.error('Configure private TEST_CPF and JWT_SECRET environment variables')
    with tempfile.TemporaryDirectory() as directory:
        request=Path(directory)/'request.json';response=Path(directory)/'response.json'
        request.write_text(json.dumps({'version':'2.0','body':json.dumps({'cpf':os.environ['TEST_CPF']}),'isBase64Encoded':False}),encoding='utf-8')
        call=subprocess.run(['aws','lambda','invoke','--function-name',a.function,'--qualifier',a.version,'--cli-binary-format','raw-in-base64-out','--payload','fileb://'+request.as_posix(),str(response)],check=True,capture_output=True,text=True)
        metadata=json.loads(call.stdout)
        if metadata.get('FunctionError'):raise RuntimeError('Candidate invocation failed; review private CloudWatch diagnostics')
        data=json.loads(response.read_text(encoding='utf-8'))
        if data.get('statusCode')!=200:raise RuntimeError('Candidate did not authenticate the eligible test identity')
        verify_token(json.loads(data['body'])['accessToken'],os.environ['JWT_SECRET'])
    print('Candidate HTTP identity and JWT verified. No alias or route was changed; no token or CPF printed.')
if __name__=='__main__':main()
