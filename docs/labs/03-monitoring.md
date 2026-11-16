# 03. 메트릭 수집과 대시보드

로컬 kind 클러스터에 metrics-server와 kube-prometheus-stack을 설치하는 절차와, 설치 중 만난 문제를 정리한 문서입니다. Helm 개념과 명령어는 [Helm 명령어 정리](../helm-cheatsheet.md)를 참고합니다.

- 환경: kind 클러스터 (control-plane 1 + worker 3), Docker 메모리 약 7.7GiB
- 브랜치: `feat/monitoring-prometheus`

## 1. 구성

| release | 네임스페이스 | chart | values |
| --- | --- | --- | --- |
| `metrics-server` | `kube-system` | metrics-server 3.14.0 | `monitoring/metrics-server-values.yaml` |
| `kps` | `monitoring` | kube-prometheus-stack 93.3.0 | `monitoring/kube-prometheus-stack-values.yaml` |

helm release가 아닌 리소스로 `monitoring/podinfo-servicemonitor.yaml`(ServiceMonitor)을 `kubectl apply`로 적용합니다. 7번 항목을 참고합니다.

release 이름은 `kps`로 통일합니다. 파드와 Service 이름 앞에 release 이름이 붙으므로(`kps-grafana`), 다른 이름으로 설치하면 아래 접속 명령이 달라집니다.

### metrics-server와 Prometheus의 차이

둘은 같은 원천(kubelet)에서 따로 가져가는 별개의 경로입니다. 서로 대체하지 못합니다.

| | metrics-server | Prometheus |
| --- | --- | --- |
| 경로 | kubelet → metrics-server → API 서버 | kubelet(cAdvisor) → Prometheus |
| 데이터 | CPU/메모리 현재값 | 수천 종류의 메트릭, 시계열 저장 |
| 소비자 | `kubectl top`, HPA | Grafana, 알림, 장애 분석 |

kube-prometheus-stack에는 metrics-server가 포함되지 않습니다.

### values에서 기본값과 다르게 둔 것

| 설정 | 이유 |
| --- | --- |
| `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`를 `enabled: false` | kind에서는 control-plane 컴포넌트가 localhost에만 바인딩되어 수집할 수 없음. 켜 두면 계속 DOWN으로 표시됨 |
| `defaultRules.rules`의 같은 컴포넌트를 `false` | 수집을 껐는데 규칙이 남아 있으면 메트릭 부재 알림이 울림 |
| `prometheusSpec.retention: 6h` | 로컬 실습용. 영속 볼륨이 없어 파드가 재시작되면 데이터도 사라짐 |
| `*SelectorNilUsesHelmValues: false` (3개) | 기본값은 `release: <release 이름>` 라벨이 붙은 ServiceMonitor/PodMonitor/PrometheusRule만 읽음. 직접 만드는 리소스도 수집하도록 라벨 조건을 해제 |
| 컴포넌트별 `resources` | 노드 4개가 Docker 메모리 7.7GiB를 나눠 쓰므로 requests를 작게 잡음. limits는 메모리만 설정 |

## 2. 설치

```bash
# 0. 사전 확인: 클러스터, 이미 설치된 release
kubectl config current-context
kubectl get nodes
helm list -A

# 1. 저장소 등록
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

# 2. metrics-server
helm install metrics-server metrics-server/metrics-server \
  --version 3.14.0 -n kube-system \
  -f monitoring/metrics-server-values.yaml

# 3. kube-prometheus-stack (설치 전에 values 반영을 확인하려면 helm template로 먼저 렌더링)
helm install kps prometheus-community/kube-prometheus-stack \
  --version 93.3.0 -n monitoring --create-namespace \
  -f monitoring/kube-prometheus-stack-values.yaml
```

values를 고친 뒤 반영할 때는 `install` 대신 `upgrade`를 쓰고 같은 `-f` 파일을 지정합니다.

```bash
helm upgrade kps prometheus-community/kube-prometheus-stack \
  --version 93.3.0 -n monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml
```

## 3. 확인

```bash
kubectl top nodes                          # metrics-server 동작 확인
kubectl -n monitoring get pods             # 전부 Running, READY n/n
helm list -A                               # STATUS: deployed
helm get values kps -n monitoring          # 적용된 값이 파일과 같은지
```

기대하는 파드:

| 파드 | 개수 |
| --- | --- |
| `alertmanager-kps-kube-prometheus-stack-alertmanager-0` | 1 |
| `prometheus-kps-kube-prometheus-stack-prometheus-0` | 1 |
| `kps-grafana-*` | 1 |
| `kps-kube-prometheus-stack-operator-*` | 1 |
| `kps-kube-state-metrics-*` | 1 |
| `kps-prometheus-node-exporter-*` | 노드 수(4) |

## 4. 접속

터미널을 각각 따로 열어 실행합니다. 외부에 노출하지 않고 port-forward로만 접속합니다.

```bash
# Grafana: http://localhost:3000 (ID: admin)
kubectl -n monitoring port-forward svc/kps-grafana 3000:80

# Prometheus: http://localhost:9090
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090

# Grafana admin 비밀번호
kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Prometheus의 **Status → Targets**에서 etcd, scheduler, controller-manager, kube-proxy는 목록에 없고 나머지는 UP이어야 합니다. Grafana의 기본 대시보드 `Kubernetes / Compute Resources / Pod`에서 파드별 CPU/메모리를 볼 수 있습니다.

## 5. 정리

```bash
helm uninstall kps -n monitoring
helm uninstall metrics-server -n kube-system
kubectl delete ns monitoring
kubectl get crd | grep monitoring.coreos.com    # CRD는 남음. 필요하면 직접 삭제
```

## 6. 겪은 문제 (설치)

### 같은 chart를 release 이름만 바꿔 두 번 설치함

- 증상: 파드가 `kps-*`와 `monitoring-*` 두 세트로 떴고, 나중에 설치한 `monitoring-prometheus-node-exporter-*` 4개가 `Pending`이었음
- 이벤트: `0/4 nodes are available: 1 node(s) didn't have free ports for the requested pod ports, 3 node(s) didn't satisfy plugin(s) [NodeAffinity]`
- 원인: node-exporter는 노드의 9100번 포트를 직접 점유(hostPort)하므로, 먼저 설치된 `kps`의 node-exporter와 충돌함. `NodeAffinity` 메시지는 DaemonSet 파드가 각자 담당 노드가 정해져 있어 나머지 노드가 대상이 아니라는 뜻이고 이상이 아님
- 조치: `helm list -A`로 중복을 확인하고 `monitoring` release를 `helm uninstall`. 두 세트는 Prometheus와 Grafana도 둘씩 띄워 메모리를 두 배로 쓰므로 하나만 남김
- 교훈: 설치 전에 `helm list -A`로 같은 chart가 이미 있는지 확인하고, release 이름을 문서로 고정함

### `helm template | grep -m1 retention`이 `120h`를 보여 줌

- 원인: `retention`은 Alertmanager(기본 `120h`)와 Prometheus(우리가 `6h`로 덮어씀)에 모두 있고, `-m1`은 첫 매칭만 출력함
- 조치: `grep -n retention`으로 전부 출력해서 `"6h"`가 있는지 확인함

### Grafana가 OOMKilled로 재시작되어 port-forward가 끊김

- 증상: `kubectl port-forward svc/kps-grafana 3000:80` 중에 `connection refused`와 `error: lost connection to pod`가 출력되고 접속이 끊김
- 확인: `kubectl -n monitoring get pods`에서 `RESTARTS 1`. `describe pod`의 `grafana` 컨테이너가 `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`. 사이드카 컨테이너 2개(`grafana-sc-*`)는 재시작 0
- 원인: `grafana.resources.limits.memory`가 `384Mi`였는데 기본 대시보드를 열 때 쿼리가 한꺼번에 실행되어 한도를 넘음. 컨테이너가 죽은 동안 파드 안의 3000번 포트가 닫혀 있어서 port-forward가 `connection refused`로 끊김
- 조치: values의 `grafana.resources.limits.memory`를 `512Mi`로 올리고 `helm upgrade kps ...` 실행. 첫 시도(REVISION 2)는 `context canceled`로 `failed`였고, 값도 `384Mi` 그대로였음. 파일(`512Mi`), release에 기록된 값, 라이브 클러스터를 각각 비교해서 파일만 바뀌고 upgrade는 성공한 적이 없음을 확인한 뒤 다시 실행해 REVISION 4에서 `512Mi`로 반영됨
- 확인: `helm get values kps`(release 값), `kubectl get deploy ... -o jsonpath`(라이브 값), `helm template -f`(파일 기준 렌더링) 세 곳을 비교하면 어디서 어긋났는지 알 수 있음. 새 Grafana 파드가 떠도 대시보드는 ConfigMap에 있어서 그대로 복원됨
- 교훈: 02번 실습의 OOMKilled가 우리 모니터링에서 실제로 일어남. 메모리 limit을 너무 작게 잡으면 도구 자체가 죽고, 접속이 끊기는 증상으로 먼저 드러남

### `helm get values` 출력에 오타(`emory`)가 보였지만 실제로는 없었음

- 증상: 터미널 출력을 복사해 붙이는 과정에서 `prometheus-node-exporter.resources.limits`가 `memory`가 아니라 `emory`로 보였음
- 확인: 클러스터에서 다시 `helm get values kps -n monitoring`을 실행하니 `memory: 64Mi`로 올바르게 들어 있었음. `REVISION`도 1 그대로여서 `helm upgrade`를 한 적이 없음. 설치된 값에는 처음부터 오타가 없었고 복사/붙여넣기 중 글자가 빠진 것이었음
- 교훈: 이상한 값이 보이면 붙여 넣은 텍스트가 아니라 **클러스터에서 직접 다시 조회**해서 확인함. 키 이름 오타는 에러 없이 무시되므로 `helm get values`와 `helm template`로 반영 여부를 확인하는 습관이 필요함

## 7. podinfo 메트릭 수집 (ServiceMonitor)

### 메트릭은 누가 만들고 누가 가져가나

ServiceMonitor와 Prometheus는 메트릭을 만들지 않습니다. 메트릭은 **측정 대상이 노출**하고, Prometheus가 **pull**해 갑니다.

| 구성 요소 | 역할 |
| --- | --- |
| podinfo 앱 (파드 안의 프로세스) | 요청을 처리하며 직접 센 값을 `/metrics`로 노출 (계측, instrumentation) |
| ServiceMonitor | 어디를(어떤 Service, 포트), 어떻게(경로, 주기) 수집할지 적은 선언 |
| prometheus-operator | ServiceMonitor를 읽고 Prometheus의 수집 설정을 자동으로 갱신 |
| Prometheus | 설정된 주소로 주기적으로 가서 메트릭을 가져와 저장 |
| Grafana | 저장된 데이터를 그래프로 표시 |

```
podinfo가 /metrics 노출 ←(15초마다 GET)← Prometheus ←(설정 생성)← operator ←(읽음)← ServiceMonitor
```

- 메트릭을 만드는 것은 **podinfo 앱**이지 쿠버네티스의 Service 오브젝트가 아닙니다. Service는 대상 파드를 찾는 수단일 뿐이고, 수집은 Service를 거치지 않고 엔드포인트의 **파드 3개에 각각 직접** 접속해 이루어집니다. 그래서 `pod` 라벨로 파드별 값을 구분할 수 있습니다.
- 앱이 `/metrics`를 노출하지 않으면 ServiceMonitor를 만들어도 수집할 것이 없습니다. 노출하지 않는 대상(MySQL, Redis 등)은 옆에 exporter를 붙입니다.
- 같은 파드라도 지표마다 측정 주체가 다릅니다.

| 지표 | 노출하는 곳 |
| --- | --- |
| 요청 수, 지연시간 같은 앱 고유 지표 | 앱 자신 (`/metrics`) |
| 컨테이너 CPU/메모리 | kubelet (cAdvisor) |
| 노드 자원 | node-exporter |
| 파드/Deployment 상태, 재시작 횟수 | kube-state-metrics |

podinfo는 `/metrics`를 서비스 포트(9898)로 노출합니다.

```bash
kubectl exec deploy/podinfo -- curl -s localhost:9898/metrics | grep -E "^(http_request|go_goroutines)" | head
```

### CRD와 CR

`monitoring/podinfo-servicemonitor.yaml`은 CRD가 아니라 **CR(Custom Resource)**입니다.

| | 의미 | 위치 |
| --- | --- | --- |
| CRD | "ServiceMonitor라는 종류가 있다"는 정의 | kube-prometheus-stack이 설치할 때 등록 |
| CR | 그 정의를 따라 만든 실제 오브젝트 | 우리가 작성한 `podinfo-servicemonitor.yaml` |

```bash
kubectl get crd servicemonitors.monitoring.coreos.com   # CRD
kubectl get servicemonitor podinfo                       # CR
```

### 적용한 변경

| 파일 | 변경 | 이유 |
| --- | --- | --- |
| `apps/podinfo/service.yaml` | `metadata.labels: app: podinfo` 추가 | ServiceMonitor가 Service를 라벨로 선택함 |
| `apps/podinfo/service.yaml` | 포트에 `name: http` 추가 | ServiceMonitor의 `endpoints.port`가 포트를 이름으로 지정함 |
| `monitoring/podinfo-servicemonitor.yaml` (새 파일) | `app: podinfo` Service의 `http` 포트를 `/metrics`로 15초마다 수집 | podinfo 수집 대상 등록 |

```bash
kubectl apply -f apps/podinfo/service.yaml -f monitoring/podinfo-servicemonitor.yaml
```

`serviceMonitorSelectorNilUsesHelmValues: false`를 values에 두었기 때문에 ServiceMonitor에 `release: kps` 라벨을 붙이지 않아도 Prometheus가 읽습니다. 이 설정이 없으면 라벨이 없는 ServiceMonitor는 무시됩니다.

### 수집 확인 (미확인)

적용까지만 했고 **Prometheus가 실제로 수집하는지는 아직 확인하지 않았습니다.** Prometheus를 port-forward로 열고 아래를 확인합니다.

- **Status → Targets**에서 `serviceMonitor/default/podinfo`가 보이고 파드 3개가 UP
- **Graph**에서 `up{job="podinfo"}`를 조회하면 3개 시리즈가 `1`

수집 대상에 안 뜨면 다음 순서로 확인합니다: Service 라벨과 ServiceMonitor `selector` 일치 여부, 포트 이름(`http`) 일치 여부, `namespaceSelector`, `kubectl get endpoints podinfo`에 파드가 있는지.

## 8. 02번 장애를 지표로 보기

02번의 `labs/02/` 파드를 다시 띄우고 Prometheus에서 쿼리했습니다. 한 번에 파드 하나씩 띄우고, 끝나면 `kubectl delete -f`로 내렸습니다. 메트릭이 수집되기까지 15~30초가 걸리므로 띄운 직후에는 결과가 비어 있을 수 있습니다.

### OOMKilled (`oom-test`)

```promql
kube_pod_container_status_restarts_total{pod="oom-test"}
kube_pod_container_status_last_terminated_reason{pod="oom-test", reason="OOMKilled"}
container_memory_working_set_bytes{pod="oom-test", container!=""}
```

- `kubectl`로는 `OOMKilled`, `Exit Code: 137`이었고 3분 20초 동안 재시작이 5회였음
- 지표로는 `restarts_total`의 최대값이 4, `last_terminated_reason`이 `OOMKilled`로 확인됨. 마지막 1회는 수집되기 전에 파드를 삭제해서 빠짐
- **메모리 그래프에서는 한도(100Mi) 근처의 값이 관측되지 않았음.** `stress`가 시작하자마자 150M를 할당하다 바로 죽어서, 15초 간격의 수집이 그 순간을 잡지 못함. `container!=""` 조건에서는 시리즈가 비고, 파드 단위(`container` 라벨 없음) 값만 0.2~0.4MiB로 나옴. 수집 주기보다 짧게 일어나는 일은 지표에 보이지 않으므로, OOM은 메모리 그래프가 아니라 `restarts_total`과 `last_terminated_reason`으로 감지함
- 파드를 삭제해도 시리즈는 보관 기간(6h) 동안 Prometheus에 남음. 삭제된 파드는 `kubectl`로 조회할 수 없지만 지표로는 이력을 볼 수 있음

### CPU throttling (`cpu-test`)

```promql
rate(container_cpu_usage_seconds_total{pod="cpu-test", container!=""}[1m])
kube_pod_container_resource_limits{pod="cpu-test", resource="cpu"}
rate(container_cpu_cfs_throttled_periods_total{pod="cpu-test", container!=""}[1m])
  / rate(container_cpu_cfs_periods_total{pod="cpu-test", container!=""}[1m])
kube_pod_container_status_restarts_total{pod="cpu-test"}
```

- 최근 30분 기준으로 사용량 최대 **0.1코어**(limit과 같음), throttling 비율 약 **0.99**, 재시작 **0**이었음. 한도에서 잘리지만 **죽지 않음**
- OOM은 한도를 넘으면 죽고(재시작이 증가), CPU는 한도를 넘으려 해도 느려지기만 한다는 차이를 지표로 구분할 수 있음

### liveness probe (`liveness-test`)

```promql
kube_pod_container_status_restarts_total{pod="liveness-test"}
prober_probe_total{pod="liveness-test"}
```

- `/readyz/disable` 호출 후 재시작이 1회 발생함 (`kube_pod_container_status_restarts_total`도 1)
- **kubelet의 probe 지표가 실제로 나옴.** kube-prometheus-stack의 kubelet ServiceMonitor가 `/metrics/probes` 경로를 수집하고(Targets에서 `UP`), `prober_probe_total`이 클러스터 전체에서 104개 시리즈로 존재함
- `liveness-test`의 `probe_type="Liveness"` 기준 `result="failed"`가 **3**, `result="successful"`이 **2**. 실패 3회는 `failureThreshold: 3`과 일치함. 02번에서 `describe`의 이벤트로 본 "probe 실패 3회 후 재시작"을 지표로도 확인함
- 같은 결과의 시리즈가 2개씩 나옴. 원인은 확인하지 않았음 (재시작 전후 컨테이너 인스턴스가 다르기 때문일 것으로 추정)
- 삭제된 파드의 지표는 인스턴트 쿼리(최근 5분 조회)로는 비어 보이므로, `max_over_time(...[30m])`처럼 범위 함수로 조회해야 함

### 쿼리를 쓸 때 알게 된 점

- 카운터(`*_total`)는 그대로 보지 않고 `rate()`로 변화율을 봄
- `container!=""` 조건이 없으면 파드 전체(`container=""`)와 개별 컨테이너 시리즈가 섞임
- 메트릭 이름을 모를 때는 `count by (__name__) ({job="podinfo"})`처럼 라벨로 먼저 좁힘

## 9. 대시보드 (ConfigMap으로 배포)

02번 장애 지표를 한 화면에서 보는 대시보드를 JSON으로 작성하고 ConfigMap으로 배포했습니다.

| 파일 | 내용 |
| --- | --- |
| `monitoring/dashboards/lab02-failures.json` | 대시보드 원본. 변수 3개(데이터소스, 네임스페이스, 파드), 패널 5개 |
| `monitoring/dashboards/lab02-failures-configmap.yaml` | 위 JSON을 담은 ConfigMap. `grafana_dashboard: "1"` 라벨 |

| 패널 | 쿼리의 핵심 | 보는 것 |
| --- | --- | --- |
| 컨테이너 재시작 횟수 | `kube_pod_container_status_restarts_total` | OOM, liveness 재시작 감지 |
| 마지막 종료 사유 | `kube_pod_container_status_last_terminated_reason == 1` | `OOMKilled` 등 종료 이유 |
| CPU 사용량 vs limit | `rate(container_cpu_usage_seconds_total[1m])`, `kube_pod_container_resource_limits` | limit에서 잘리는지 |
| CPU throttling 비율 | `throttled_periods / periods` | 한도에 걸려 멈춘 비율 |
| probe 실패 횟수 | `increase(prober_probe_total{result="failed"}[5m])` | kubelet이 센 probe 실패 |

- 데이터소스는 UID를 고정하지 않고 **변수**로 받아 환경이 달라져도 동작함
- probe 패널은 같은 결과의 시리즈가 2개씩 나오므로 `sum`이 아니라 `max by`를 사용함

### 생성과 적용

JSON을 원본으로 두고 ConfigMap은 명령으로 생성합니다. 사람이 YAML에 JSON을 붙여 넣으면 원본과 어긋나기 쉽습니다.

```bash
kubectl -n monitoring create configmap lab02-failures-dashboard \
  --from-file=lab02-failures.json=monitoring/dashboards/lab02-failures.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 app.kubernetes.io/part-of=k8s-ops-lab -o yaml \
  > monitoring/dashboards/lab02-failures-configmap.yaml

kubectl apply -f monitoring/dashboards/lab02-failures-configmap.yaml
```

JSON을 고쳤다면 위 두 명령을 다시 실행합니다. UI에서 고친 내용은 저장되지 않으므로 **Export → JSON**으로 내려받아 JSON 파일을 교체합니다.

### 동작 방식

Grafana 파드의 `grafana-sc-dashboard` 사이드카가 라벨이 붙은 ConfigMap을 감시해서 대시보드를 불러옵니다. 파드 YAML에는 ConfigMap 이름이 없고, 찾는 규칙(라벨)만 있습니다.

```bash
kubectl -n monitoring get deploy kps-grafana \
  -o jsonpath='{range .spec.template.spec.containers[?(@.name=="grafana-sc-dashboard")].env[*]}{.name}={.value}{"\n"}{end}'
```

| 환경변수 | 값 | 의미 |
| --- | --- | --- |
| `LABEL`, `LABEL_VALUE` | `grafana_dashboard`, `1` | 이 라벨이 붙은 리소스를 찾음 |
| `NAMESPACE` | `ALL` | 모든 네임스페이스를 감시 |
| `METHOD` | `WATCH` | 변경을 즉시 통지받음 (주기적 조회가 아님) |
| `RESOURCE` | `both` | ConfigMap과 Secret 모두 대상 |
| `FOLDER` | `/tmp/dashboards` | 찾은 내용을 파일로 저장하는 폴더 (Grafana와 공유) |
| `REQ_URL` | `.../api/admin/provisioning/dashboards/reload` | 파일 저장 후 Grafana에 reload를 호출 |

- 사이드카 로그에서 `Writing /tmp/dashboards/lab02-failures.json` 직후(약 0.05초) reload가 `200 OK`로 응답한 것을 확인함. 적용하면 몇 초 안에 반영됨
- ConfigMap은 helm release에 포함되지 않음. `helm uninstall kps`로 지워지지 않으므로 `kubectl delete -f`로 직접 삭제해야 함 (podinfo ServiceMonitor도 같음)
- 사이드카 컨테이너는 `resources`가 비어 있음. values의 `grafana.resources`는 Grafana 본체에만 적용됨

## 10. 다음 할 일

- [x] podinfo 수집 확인 (`serviceMonitor/default/podinfo/0`, 파드 3개의 `instance`/`pod` 라벨 확인)
- [x] podinfo 지표 쿼리 (PromQL)
- [x] 02번의 `oom-test`, `cpu-test`를 다시 띄워 재시작 횟수와 CPU throttling이 지표로 어떻게 보이는지 확인
- [x] kubelet의 probe 관련 지표(`prober_probe_total`)가 실제로 나오는지 확인
- [x] 대시보드 구성, `monitoring/dashboards/`에 대시보드 JSON 저장

로드맵 03번의 항목은 모두 끝났습니다. 다음은 04번(알림 규칙과 Alertmanager, 로깅)이고, 이 문서의 쿼리를 PrometheusRule의 알림 조건으로 옮깁니다.
