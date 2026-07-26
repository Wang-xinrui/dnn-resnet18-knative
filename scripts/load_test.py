#!/usr/bin/env python3
import argparse,concurrent.futures,json,statistics,time,urllib.request,urllib.error

def send(url,i):
 s=time.perf_counter()
 try:
  with urllib.request.urlopen(url,timeout=600) as r:
   p=json.loads(r.read().decode())
   return {'request_id':i,'ok':True,'elapsed_s':time.perf_counter()-s,'pod':p.get('pod'),'inference_ms':p.get('inference_ms')}
 except Exception as e:
  return {'request_id':i,'ok':False,'elapsed_s':time.perf_counter()-s,'error':str(e)}

def pct(v,f):
 if not v:return None
 v=sorted(v); return v[min(len(v)-1,round((len(v)-1)*f))]

def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--url',required=True); ap.add_argument('--requests',type=int,default=20); ap.add_argument('--concurrency',type=int,default=10); ap.add_argument('--repeat',type=int,default=100); a=ap.parse_args()
 endpoint=a.url.rstrip('/')+f'/infer/synthetic?repeat={a.repeat}'
 s=time.perf_counter()
 with concurrent.futures.ThreadPoolExecutor(max_workers=a.concurrency) as ex:
  rs=[f.result() for f in [ex.submit(send,endpoint,i) for i in range(1,a.requests+1)]]
 wall=time.perf_counter()-s; ok=[x for x in rs if x['ok']]; fail=[x for x in rs if not x['ok']]; lat=[x['elapsed_s'] for x in ok]; pods=sorted({x.get('pod') for x in ok if x.get('pod')})
 out={'requests':a.requests,'concurrency':a.concurrency,'repeat':a.repeat,'successes':len(ok),'failures':len(fail),'wall_seconds':round(wall,3),'throughput_rps':round(len(ok)/wall,3) if wall else None,'latency_mean_s':round(statistics.mean(lat),3) if lat else None,'latency_p50_s':round(statistics.median(lat),3) if lat else None,'latency_p95_s':round(pct(lat,.95),3) if lat else None,'latency_max_s':round(max(lat),3) if lat else None,'pods_seen':pods,'pod_count_seen':len(pods)}
 print(json.dumps(out,ensure_ascii=False,indent=2))
 if fail: print('Failures:'); print(json.dumps(fail,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
