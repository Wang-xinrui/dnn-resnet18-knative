#!/usr/bin/env bash
set -Eeuo pipefail

#Knative Service 名称
SERVICE="${SERVICE:-dnn-resnet18-cpu}"
#命名空间
NAMESPACE="${NAMESPACE:-default}"
#并发测试总请求数
REQUESTS="${REQUESTS:-20}"
#并发线程数
CONCURRENCY="${CONCURRENCY:-10}"
#每个请求执行的模型前向次数
REPEAT="${REPEAT:-100}"
#热请求测试次数
WARM_REQUESTS="${WARM_REQUESTS:-3}"
#等待缩容到零的超时秒数
WAIT_ZERO_TIMEOUT="${WAIT_ZERO_TIMEOUT:-300}"
#副本数采样间隔（秒）
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOAD_TEST_SCRIPT="${LOAD_TEST_SCRIPT:-${SCRIPT_DIR}/load_test.py}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="${RESULT_DIR:-${PWD}/results/${SERVICE}-${STAMP}}"
mkdir -p "$RESULT_DIR"

kctl(){ sudo k3s kubectl "$@"; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$RESULT_DIR/run.log"; }
pod_count(){ kctl get pods -n "$NAMESPACE" -l "serving.knative.dev/service=${SERVICE}" --no-headers 2>/dev/null | wc -l | tr -d ' '; }
wait_for_zero(){
  local deadline=$((SECONDS+WAIT_ZERO_TIMEOUT))
  log "Waiting for ${SERVICE} to scale to zero."
  while (( SECONDS < deadline )); do
    local c; c="$(pod_count)"; log "Current pod count: ${c}"
    [[ "$c" == "0" ]] && { log "Scale-to-zero confirmed."; return 0; }
    sleep 5
  done
  log "Timed out waiting for scale-to-zero."; return 1
}
monitor(){
  local revision="$1" output="$2"
  printf 'timestamp,pod_count,revision_actual,revision_desired,pod_names\n' > "$output"
  while true; do
    local ts c a d n
    ts="$(date --iso-8601=seconds)"; c="$(pod_count)"
    a="$(kctl get revision "$revision" -n "$NAMESPACE" -o jsonpath='{.status.actualReplicas}' 2>/dev/null || true)"
    d="$(kctl get revision "$revision" -n "$NAMESPACE" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
    n="$(kctl get pods -n "$NAMESPACE" -l "serving.knative.dev/service=${SERVICE}" -o jsonpath='{range .items[*]}{.metadata.name}{";"}{end}' 2>/dev/null || true)"
    printf '%s,%s,%s,%s,"%s"\n' "$ts" "${c:-0}" "${a:-0}" "${d:-0}" "$n" >> "$output"
    sleep "$SAMPLE_INTERVAL"
  done
}
json_field(){ python3 - "$1" "$2" <<'PY2'
import json,sys
try:
    print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2],''))
except Exception:
    print('')
PY2
}
cleanup(){ [[ -n "${MONITOR_PID:-}" ]] && kill "$MONITOR_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

sudo -v
URL="$(kctl get ksvc "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.url}')"
REVISION="$(kctl get ksvc "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.latestReadyRevisionName}')"
[[ -n "$URL" && -n "$REVISION" ]] || { log 'Cannot resolve URL or revision.'; exit 1; }
printf '%s\n' "$URL" > "$RESULT_DIR/service-url.txt"
printf '%s\n' "$REVISION" > "$RESULT_DIR/revision.txt"
log "Result directory: $RESULT_DIR"
log "Service URL: $URL"
log "Revision: $REVISION"
kctl get ksvc "$SERVICE" -n "$NAMESPACE" -o yaml > "$RESULT_DIR/ksvc.yaml"
wait_for_zero
monitor "$REVISION" "$RESULT_DIR/replica-timeline.csv" & MONITOR_PID=$!
sleep 2

log 'Sending cold-start request.'
curl -sS -o "$RESULT_DIR/cold-response.json"   -w 'http_code=%{http_code}\ntime_namelookup=%{time_namelookup}\ntime_connect=%{time_connect}\ntime_starttransfer=%{time_starttransfer}\ntime_total=%{time_total}\n'   "$URL/infer/synthetic?repeat=1" > "$RESULT_DIR/cold-curl-metrics.txt"
cat "$RESULT_DIR/cold-curl-metrics.txt" | tee -a "$RESULT_DIR/run.log"
COLD_POD="$(json_field "$RESULT_DIR/cold-response.json" pod)"
log "Cold response pod: ${COLD_POD:-unknown}"
if [[ -n "$COLD_POD" ]] && kctl get pod "$COLD_POD" -n "$NAMESPACE" >/dev/null 2>&1; then
  kctl logs "$COLD_POD" -n "$NAMESPACE" -c user-container > "$RESULT_DIR/cold-pod.log" 2>&1 || true
fi
curl -sS "$URL/metadata" > "$RESULT_DIR/metadata-after-cold.json"

printf 'request,time_starttransfer,time_total,response_file\n' > "$RESULT_DIR/warm-metrics.csv"
for i in $(seq 1 "$WARM_REQUESTS"); do
  f="$RESULT_DIR/warm-response-${i}.json"
  m="$(curl -sS -o "$f" -w '%{time_starttransfer},%{time_total}' "$URL/infer/synthetic?repeat=1")"
  printf '%s,%s,%s\n' "$i" "$m" "$f" >> "$RESULT_DIR/warm-metrics.csv"
  sleep 1
done

log "Running autoscaling load: requests=${REQUESTS}, concurrency=${CONCURRENCY}, repeat=${REPEAT}."
python3 "$LOAD_TEST_SCRIPT" --url "$URL" --requests "$REQUESTS" --concurrency "$CONCURRENCY" --repeat "$REPEAT" | tee "$RESULT_DIR/autoscale-load-result.txt"
kctl get pods -n "$NAMESPACE" -l "serving.knative.dev/service=${SERVICE}" -o wide > "$RESULT_DIR/pods-after-load.txt" 2>&1 || true
log 'Waiting for replicas to return to zero.'
wait_for_zero
cleanup; MONITOR_PID=''
kctl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' > "$RESULT_DIR/events.txt" 2>&1 || true

python3 - "$RESULT_DIR" <<'PY3'
import csv,json,pathlib,sys
r=pathlib.Path(sys.argv[1])
def text(n):
 p=r/n
 return p.read_text(encoding='utf-8',errors='replace') if p.exists() else ''
def js(n):
 try:return json.loads(text(n))
 except:return {}
metrics={}
for line in text('cold-curl-metrics.txt').splitlines():
 if '=' in line:
  k,v=line.split('=',1); metrics[k]=v
cold=js('cold-response.json'); meta=js('metadata-after-cold.json')
peak=0
p=r/'replica-timeline.csv'
if p.exists():
 for row in csv.DictReader(p.open(encoding='utf-8')):
  try: peak=max(peak,int(row.get('pod_count') or 0))
  except: pass
warm=[]
p=r/'warm-metrics.csv'
if p.exists():
 for row in csv.DictReader(p.open(encoding='utf-8')):
  try:warm.append(float(row['time_total']))
  except:pass
summary={
 'service_url':text('service-url.txt').strip(),
 'revision':text('revision.txt').strip(),
 'cold_start':{'http_code':metrics.get('http_code'),'time_starttransfer_s':metrics.get('time_starttransfer'),'time_total_s':metrics.get('time_total'),'response_pod':cold.get('pod'),'inference_ms':cold.get('inference_ms')},
 'metadata_after_cold':{'pod':meta.get('pod'),'model_load_ms':meta.get('model_load_ms'),'warmup_ms':meta.get('warmup_ms'),'same_pod_as_cold_response':bool(meta.get('pod')) and meta.get('pod')==cold.get('pod')},
 'warm_requests':{'count':len(warm),'mean_time_total_s':round(sum(warm)/len(warm),6) if warm else None,'min_time_total_s':min(warm) if warm else None,'max_time_total_s':max(warm) if warm else None},
 'autoscaling':{'peak_observed_pods':peak,'returned_to_zero':True,'timeline_file':'replica-timeline.csv','load_result_file':'autoscale-load-result.txt'}
}
(r/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
md=[
 '# Knative DNN Experiment Summary','',
 f"- Service URL: {summary['service_url']}",
 f"- Revision: {summary['revision']}",
 f"- Cold-start HTTP code: {summary['cold_start']['http_code']}",
 f"- Cold-start time to first byte: {summary['cold_start']['time_starttransfer_s']} s",
 f"- Cold-start total time: {summary['cold_start']['time_total_s']} s",
 f"- Cold inference time: {summary['cold_start']['inference_ms']} ms",
 f"- Cold response pod: {summary['cold_start']['response_pod']}",
 f"- Metadata pod: {summary['metadata_after_cold']['pod']}",
 f"- Metadata came from same pod: {summary['metadata_after_cold']['same_pod_as_cold_response']}",
 f"- Model load time: {summary['metadata_after_cold']['model_load_ms']} ms",
 f"- Warmup time: {summary['metadata_after_cold']['warmup_ms']} ms",
 f"- Warm request mean total time: {summary['warm_requests']['mean_time_total_s']} s",
 f"- Peak observed pods: {summary['autoscaling']['peak_observed_pods']}",
 f"- Returned to zero: {summary['autoscaling']['returned_to_zero']}",
]
(r/'summary.md').write_text('\n'.join(md)+'\n',encoding='utf-8')
PY3
log 'Experiment complete.'
cat "$RESULT_DIR/summary.md"
