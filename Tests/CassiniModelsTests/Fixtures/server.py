#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Loopback-only model contract fixture; never contacts dist or any other host."""
import argparse,hashlib,http.server,json,socket,sys,threading,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--scenario',required=True);p.add_argument('--log',type=Path,required=True)
a=p.parse_args();root=Path(__file__).resolve().parent
state={'artifacts':0,'truncated':False};lock=threading.Lock()
prefix_persisted=threading.Event()
def receive_control():
 for line in sys.stdin:
  if line.strip()=='prefix-persisted':prefix_persisted.set()
threading.Thread(target=receive_control,daemon=True).start()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_GET(self):
  with lock:
   with a.log.open('a') as f:f.write(json.dumps({'path':self.path,'range':self.headers.get('Range'),'ifRange':self.headers.get('If-Range'),'encoding':self.headers.get('Accept-Encoding'),'userAgent':self.headers.get('User-Agent')})+'\n')
  if self.path=='/manifest.json':
   value=json.loads((root/'manifest.json').read_text());base=f'http://127.0.0.1:{self.server.server_port}'
   value['base_url']=base
   for item in value['artifacts']:item['url']=base+'/'+item['key']
   if a.scenario=='raw-hash':value['artifacts'][0]['uncompressed_sha256']='0'*64
   if a.scenario=='unsafe-path':value['models'][0]['files'][0]['path']='../outside'
   if a.scenario=='wrong-origin':value['artifacts'][0]['url']='http://example.invalid/model.zst'
   body=json.dumps(value).encode();self.send_response(200);self.send_header('Content-Length',len(body));self.end_headers();self.wfile.write(body);return
  if self.path=='/NOTICE.txt':
   body=b'Local fixture model - public test data; no real model.\n'
   self.send_response(200);self.send_header('Content-Length',len(body));self.end_headers();self.wfile.write(body);return
  objects=json.loads((root/'manifest.json').read_text())['artifacts'];item=next((x for x in objects if '/'+x['key']==self.path),None)
  if not item:self.send_error(404);return
  data=(root/item['filename']).read_bytes();offset=0
  with lock:
   state['artifacts']+=1
   first=not state['truncated'];state['truncated']=True
  if a.scenario=='redirect':self.send_response(302);self.send_header('Location','http://example.invalid/model.zst');self.end_headers();return
  ranged=self.headers.get('Range')
  if ranged and a.scenario=='503' and state['artifacts']==2:self.send_error(503);return
  if ranged and a.scenario=='416':self.send_response(416);self.send_header('Content-Range',f'bytes */{len(data)}');self.end_headers();return
  if ranged and a.scenario!='ignore-range':offset=int(ranged.removeprefix('bytes=').removesuffix('-'))
  self.send_response(206 if offset else 200)
  digest=item['sha256'] if not (ranged and a.scenario=='changed-etag') else '0'*64
  self.send_header('ETag','"'+digest+'"')
  if a.scenario!='no-length':self.send_header('Content-Length',len(data)-offset)
  if offset:self.send_header('Content-Range',f'bytes {offset}-{len(data)-1}/{len(data)}' if a.scenario!='bad-range' else 'bytes 0-1/2')
  self.end_headers()
  if a.scenario=='compressed-hash':data=bytes([data[0]^1])+data[1:]
  truncating=a.scenario in ('truncated','416','changed-etag','ignore-range','bad-range','503') and first
  if truncating:
   self.wfile.write(data[:len(data)//2]);self.wfile.flush()
   # Only cut the connection once the client has actually written a prefix.
   # The deadline fails the fixture; elapsed time never supplies the event.
   if not prefix_persisted.wait(timeout=10):raise TimeoutError('client did not acknowledge a persisted prefix')
   self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
  if a.scenario=='slow':
   try:
    for start in range(offset,len(data),1024):self.wfile.write(data[start:start+1024]);self.wfile.flush();time.sleep(.01)
   except (BrokenPipeError,ConnectionResetError):pass
  else:
   try:self.wfile.write(data[offset:])
   except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(f'http://127.0.0.1:{server.server_port}',flush=True);server.serve_forever()
