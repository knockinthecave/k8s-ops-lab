# 04. 알림 규칙

> 상태: **알림 규칙, 로깅 설치 완료**. 로그 기반 알림, 오탐/미탐 조정, receiver 연결은 남았다.

## 1. 목표

03번에서 확인한 지표를 PrometheusRule로 옮겨서, 장애를 일으켰을 때 알림이 실제로 발화하고 해소되는지 확인한다.

## 2. 적용한 설정

- `monitoring/podinfo-alerts.yaml`: PrometheusRule `workload-alerts` (default 네임스페이스 대상)
- Alertmanager receiver는 설정하지 않았다. 기본값 `"null"`이라 알림은 외부로 전달되지 않고, Prometheus `/alerts`와 Alertmanager UI에서만 확인한다.

기본 규칙(`KubePodCrashLooping`, `KubePodNotReady`, `CPUThrottlingHigh`)은 `for: 15m`이라 감지가 느리고 OOMKilled 전용 알림이 없어서, 대체하지 않고 더 빠르고 원인이 구체적인 규칙을 추가했다.

| 알림 | 조건 | for | severity |
| --- | --- | --- | --- |
| ContainerRestartingRepeatedly | 10분간 재시작 2회 이상 | 1m | warning |
| ContainerOOMKilled | 마지막 종료 사유가 OOMKilled이고 최근 10분 내 재시작 | 없음 | critical |
| ContainerCPUThrottled | 5분간 throttle 비율 50% 초과 | 3m | warning |
| PodNotReady | Running인데 Ready가 아닌 상태 | 2m | warning |

### 이름과 선택 조건 (커스터마이징 가능한 부분)

- `metadata.name`(`workload-alerts`)은 자유롭게 정하는 이름이다. 알림 로직과 무관하고, Operator가 규칙 파일명(`monitoring-workload-alerts-<uid>.yaml`)을 만들 때 쓴다. 이 파일명은 Prometheus API(`/api/v1/rules`)의 `file` 필드에서 확인했다.
- 알림 이름(`alert:`)과 그룹 이름(`workload.rules`)도 임의다. 단 알림 이름은 Alertmanager의 route 매칭(`alertname`)과 알림 메시지에 쓰이므로 바꾸면 영향이 간다.
- 이 규칙이 읽히려면 Prometheus 리소스의 `ruleSelector`와 `ruleNamespaceSelector`에 맞아야 한다. values에서 `ruleSelectorNilUsesHelmValues: false`로 두었고, 실제 두 값이 `{}`(전부 선택)인 것을 확인했다.

## 3. 동작 구조 (Q&A로 정리)

### apply하면 무슨 일이 일어나는가
`kubectl apply`는 PrometheusRule 리소스를 저장할 뿐이고, 반영은 컨트롤러가 한다. Docker Compose와 달리 설정 변경을 감시하는 주체가 있어서 재시작이 필요 없다.

```
kubectl apply (PrometheusRule 저장)
  → Prometheus Operator가 API를 watch하다가 변경을 감지
  → 규칙 파일을 갱신 (파드에 마운트된 파일 내용이 바뀜)
  → config-reloader 사이드카가 파일 변경을 감지
  → Prometheus에 reload 요청 (프로세스는 재시작하지 않음)
```

확인한 것: Prometheus 컨테이너 restartCount가 0이고, `config-reloader` 로그에 규칙을 apply한 시각(11-17 07:15:38)의 `Reload triggered`가 있다.
확인하지 않은 것: Prometheus의 `/-/reload` 엔드포인트를 직접 호출해 보지는 않았다(일반 지식).

### Prometheus와 Alertmanager의 연결
- 차트가 설치 때 Prometheus CR의 `spec.alerting.alertmanagers`에 Alertmanager Service(`kps-kube-prometheus-stack-alertmanager`, 포트 `http-web`)를 넣어 둔다. `values.yaml`에는 이 값이 없고 차트 기본값이다.
- 규칙을 추가해도 이 연결은 바뀌지 않는다. 모든 규칙이 같은 연결을 쓴다.
- 확인한 것: `kubectl get prometheus -o jsonpath='{.items[0].spec.alerting}'`로 설정 값을, `/api/v1/alertmanagers`의 `activeAlertmanagers`로 실제 대상(`10.244.3.5:9093`)을 확인했다.
- 처음에는 확인하지 않았던 것: 발화한 알림이 Alertmanager에 실제로 도착했는지(Prometheus의 `/api/v1/alerts`만 봤다). 5절에서 `oom-test`로 다시 확인했다.

```
Prometheus(규칙 평가) --조건 충족--> Alertmanager --> receiver "null" (외부로 안 나감)
```

### 역할 분담
| | Prometheus | Alertmanager |
| --- | --- | --- |
| 하는 일 | 수집, 저장, 규칙 평가 | 그룹핑, 중복 제거, 라우팅, 전달 |
| 설정 | PrometheusRule | alertmanager.yaml, AlertmanagerConfig |

규칙(Prometheus)과 전달(Alertmanager)이 분리되어 있어서, receiver 없이 규칙만 먼저 검증할 수 있었다. 둘은 별도 파드다.

### Grafana와의 관계
- Grafana는 Prometheus를 조회해서 그래프를 그린다. 지금의 알림 경로에는 없다.
- Grafana에는 자체 알림 기능(Grafana-managed alert)과 내장 Alertmanager가 있다. 이 클러스터의 Alertmanager 파드와는 별개이고, 지금은 사용하지 않는다(일반 지식, 확인하지 않음).
- 비교:

| | PrometheusRule (현재) | Grafana-managed alert |
| --- | --- | --- |
| 정의 | Git의 YAML | UI 또는 provisioning 파일 |
| 평가 | Prometheus | Grafana |
| 전달 | Alertmanager 파드 | Grafana 내장 Alertmanager |
| 재현성 | `kubectl apply` | UI에서 만들면 Grafana 재시작 시 사라질 수 있음 (영속 볼륨 없음) |
| 다른 데이터 소스 (Loki) | 불가 | 가능 |

- 방침: 메트릭 알림은 PrometheusRule, 로그 알림은 Grafana-managed alert로 만들고 provisioning 파일로 저장한다.

### 이 규칙은 helm release와 별개다
PrometheusRule은 helm release에 포함되지 않는다. `helm uninstall kps`로 지워지지 않으므로 `kubectl delete -f monitoring/podinfo-alerts.yaml`로 직접 지워야 한다(03번의 ServiceMonitor, 대시보드 ConfigMap과 같다).

### 실무와의 차이 (일반 지식, 이 저장소에서 검증하지 않음)
실무에서는 PR 리뷰 후 Argo CD/Flux가 적용하고, CI에서 `promtool check rules`로 검사하며, Slack/PagerDuty로 전달하고, SLO 기반으로 임계값을 정한다. 이 저장소에서는 07번(CI), 08번(GitOps), 12번(SLO)에서 다룬다.

### webhook(receiver)은 나중에 Alertmanager 설정에 추가한다
- `AlertmanagerConfig` CRD 또는 values의 `alertmanager.config`로 넣는다. CRD 방식은 route에 `namespace` 매처가 자동으로 붙어 해당 네임스페이스의 알림만 매칭된다.
- Discord는 Alertmanager v0.35.0과 CRD의 `discordConfigs`로 가능한 것을 확인했다.
- webhook URL은 인증 수단이라 Git에 올리지 않고 Secret으로 만들어 참조한다(GitOps에서의 Secret 관리는 14번).
- 규칙의 `severity` 라벨로 route를 나눌 수 있어서 규칙은 바꿀 필요가 없다.

## 4. 실습

`labs/02`의 `oom-test`, `cpu-test`, `liveness-test`를 띄우고 알림 상태를 관찰했다.

| 시각 | 사건 |
| --- | --- |
| 16:16:41 | PodNotReady(oom-test) pending |
| 16:17:11 | ContainerOOMKilled(oom-test) **firing**, ContainerCPUThrottled(cpu-test) pending |
| 16:17:42 | ContainerRestartingRepeatedly(oom-test) pending |
| 16:18:42 | ContainerRestartingRepeatedly, PodNotReady(oom-test) **firing** |
| 16:20:14 | ContainerCPUThrottled(cpu-test) **firing** |
| 약 16:20:30 | 장애 파드 삭제 |
| 16:27:41 | 모든 알림 해소 |

### 확인한 것
- 규칙 4개가 모두 로드되어 `health: ok`였고, 평상시에는 `inactive`였다.
- 규칙 4개가 모두 장애 주입 후 발화했다. `for`가 없는 OOMKilled가 가장 먼저(주입 후 약 1분) 발화했다.
- 파드 삭제 후 알림이 모두 해소되었다.

### 확인하지 못한 것
- `liveness-test`는 이 매니페스트 그대로는 재시작 0회라 알림이 없었다(정상 기준 파드). probe 실패 상태에서의 알림은 검증하지 않았다.
- 파드를 지운 뒤에도 알림이 약 7분간 firing으로 남았다. `increase()`의 조회 구간 때문일 수 있다고 추정했지만 검증하지 않았다(10분 윈도우 기준 예상보다 일찍 해소됨).
- 알림 4개 중 Alertmanager 도착은 `ContainerOOMKilled`만 확인했다(5절). 나머지 3개는 같은 연결을 쓰지만 도착 자체는 확인하지 않았다.
- Alertmanager 라우팅과 외부 전달(Discord 등)은 하지 않았다.

## 5. 로깅 (Loki, Alloy)

### 구성

| 구성요소 | 차트 | 파일 |
| --- | --- | --- |
| Loki (로그 저장·조회) | `grafana/loki` 7.6.0 (앱 3.6.18) | `monitoring/loki-values.yaml` |
| Alloy (로그 수집, DaemonSet) | `grafana/alloy` 1.16.0 (앱 v1.22.0) | `monitoring/alloy-values.yaml` |
| Grafana 데이터 소스 | ConfigMap (`grafana_datasource=1` 라벨) | `monitoring/loki-datasource.yaml` |

```
각 노드의 Alloy --(Kubernetes API로 pods/log 읽기)--> Loki --(데이터 소스)--> Grafana
```

데이터 소스는 `helm upgrade` 없이 대시보드와 같은 방식(사이드카가 라벨 ConfigMap을 감시)으로 추가했다. 사이드카 로그에서 파일 기록을 확인했고, `/api/datasources/uid/loki/health`가 `Data source successfully connected.`를 반환했다.

### Loki 차트 기본값에서 바꿔야 했던 것
차트 기본값(`helm show values`로 확인)은 로컬 단일 노드에서 그대로 동작하지 않는다.

| 항목 | 기본값 | 설정 | 비고 |
| --- | --- | --- | --- |
| `deploymentMode` | `SimpleScalable` | `SingleBinary` | |
| `singleBinary.replicas` | `0` | `1` | 안 바꾸면 파드가 안 뜸 |
| `read`/`write`/`backend.replicas` | 0이 아님 | `0` | 안 바꾸면 차트 검증(`validate.yaml`)이 "single binary와 simple scalable 동시 설정"으로 `helm template`을 거부함 (직접 겪음) |
| `loki.storage.type` | `s3` | `filesystem` | |
| `loki.schemaConfig` | 비어 있음 | tsdb v13 직접 지정 | `useTestSchema`는 테스트용이라 쓰지 않음 |
| `loki.commonConfig.replication_factor` | `3` | `1` | |
| `loki.auth_enabled` | `true` | `false` | 단일 테넌트 |
| `resultsCache`, `chunksCache`, `gateway`, `lokiCanary`, `test` | enabled | 끔 | 메모리 절약 |

보관 기간은 24h(`retention_period` + compactor `retention_enabled`)이고, 데이터는 2Gi PVC(`standard`, local-path)에 저장한다. 보관 기간이 실제로 지나서 삭제되는지는 확인하지 않았다.

### Alloy의 중복 수집 방지
`loki.source.kubernetes`는 API로 로그를 읽기 때문에, DaemonSet의 모든 인스턴스가 모든 노드의 파드를 읽으면 같은 로그가 3번 들어간다. `NODE_NAME`을 `spec.nodeName`으로 주입하고 `discovery.kubernetes`의 `selectors`로 자기 노드의 파드만 대상으로 했다.
- 확인한 것: `loki-0`의 최근 30분 로그가 Loki 163줄, `kubectl logs` 163줄로 같고 모두 고유했다(중복 없음).
- Alloy는 control-plane 노드에는 뜨지 않는다(worker 3대에만). 따라서 **control-plane 노드 파드의 로그는 수집되지 않는다.** taint 허용(`tolerations`)은 설정하지 않았다.

### Alloy가 로그를 수집하는 방식 (Q&A로 정리)

#### Helm이 한 것과 직접 쓴 것
차트 기본 설정은 로그 수집용이 아니다. 노드, 서비스 같은 리소스를 찾기만 하는 예시 구성이고(`discovery.kubernetes`가 `pods`, `nodes`, `services` 등), 기본 `pods`에는 `selectors`가 없다. 기본 설정의 앞 40줄만 확인했고 `loki.write`는 그 범위에 없었다.

| | Helm 차트 | 내가 쓴 `alloy-values.yaml` |
| --- | --- | --- |
| 실행 틀 | DaemonSet, ConfigMap, 서비스 계정 | `controller.type: daemonset` |
| 권한 | ClusterRole(`pods`, `pods/log` 등 get/list/watch) | (차트 기본값 사용) |
| 설정 파일 | `/etc/alloy/config.alloy`로 마운트, config-reloader 추가 | |
| 환경변수 | | `NODE_NAME` ← `spec.nodeName` |
| 어떤 파드를 찾을지 | 기본은 조건 없음 | `selectors`로 내 노드만 |
| 어떤 라벨을 붙일지 | | `discovery.relabel` |
| 로그를 읽을지, 어디로 보낼지 | | `loki.source.kubernetes`, `loki.write`의 Loki URL |

Helm은 실행 환경과 권한을 만들고, 무엇을 수집해서 어디로 보낼지는 `configMap.content`에 쓴 내용이 전부 정한다. Helm은 이 내용을 해석하지 않고 문자열로 ConfigMap에 넣는다.

확인한 것: DaemonSet `args`(`run /etc/alloy/config.alloy`), 볼륨(`config → ConfigMap alloy`), config-reloader의 감시 경로(`/etc/alloy`).

#### Alloy와 Loki의 연결
`loki.write`의 URL(`http://loki.monitoring.svc:3100/loki/api/v1/push`) 한 줄이 연결이다. Prometheus와 Alertmanager의 연결은 Operator가 CR을 보고 만들어 주지만, Alloy와 Loki는 Operator가 없어서 URL을 직접 써야 하고 서비스 이름이나 포트가 바뀌면 같이 고쳐야 한다. 컴포넌트는 `forward_to`와 `종류.이름.출력` 참조로 파이프라인처럼 이어진다.

```
discovery.kubernetes.pods --targets--> discovery.relabel.pods --output--> loki.source.kubernetes.pods
   --forward_to--> loki.write.default --HTTP POST--> Loki
```

#### 요청 순서: 목록 조회 → 파드별 로그 조회
노드 필터는 `pods/log`가 아니라 **파드 목록 조회**에 붙는다. `pods/log`는 파드 하나를 지정해서 부르는 API라 노드 조건을 줄 자리가 없고, 쿼리 파라미터는 읽는 방식(`container`, `tailLines`, `sinceSeconds`, `follow`, `previous` 등)만 정한다.

```
① GET /api/v1/pods?fieldSelector=spec.nodeName=<내 노드>   (discovery.kubernetes의 selectors)
   → 내 노드의 파드 목록
② 목록의 파드마다 GET /api/v1/namespaces/<ns>/pods/<pod>/log?container=<c>   (loki.source.kubernetes)
   → 로그를 받아 라벨을 붙이고 Loki로 전송
```

- 쿠버네티스가 기본 제공하는 것: `pods/log`는 API 서버의 파드 하위 리소스(`/api/v1`의 리소스 목록에서 `pods/log ['get']` 확인). `kubectl logs`도 같은 API를 쓴다. 로그의 실체는 노드의 파일이고 API 서버가 kubelet을 통해 가져오는 것으로 알고 있다(확인하지 않음).
- `pods/log`는 `pods`와 별개의 리소스라 ClusterRole에 따로 적혀 있다.
- `loki.source.kubernetes`는 "이 파드가 내 노드에 있나"를 판단하지 않고, 앞 단계에서 받은 목록을 전부 읽는다. DaemonSet은 노드마다 파드를 하나씩 띄우는 것까지만 보장하고, "자기 노드만"은 보장하지 않는다. 필터가 없으면 3개 인스턴스가 같은 전체 파드를 읽어 중복이 생길 것으로 예상한다(필터 없이 재현하지는 않음).
- 직접 재현: 같은 종류의 요청을 `kubectl get --raw`로 손으로 보냈다. 목록 요청(`fieldSelector=spec.nodeName=...`)은 노드별로 다른 파드 7개씩을 돌려주었고, 로그 요청은 동작했다. 로그 API는 노드를 따지지 않아서(목록에 없던 `loki-0`도 조회됨) 필터는 목록 단계에만 있다. **Alloy가 실제로 보내는 요청을 캡처한 것은 아니다.**

#### `NODE_NAME`은 어디서 채워지는가
`alloy-values.yaml`에는 노드 이름이 적혀 있지 않다. `fieldRef: spec.nodeName`은 "파드 객체 자신의 필드를 값으로 쓴다"는 뜻(Downward API)이고 값은 스케줄러가 파드를 노드에 배치할 때 기록한다.
- 확인한 것: DaemonSet 템플릿의 `spec.nodeName`은 비어 있고, 파드마다 서로 다른 노드(`worker`, `worker2`, `worker3`)가 기록되어 있다. 컨테이너 안에서 `printenv NODE_NAME`을 하면 파드마다 자기 노드 이름이 나온다.

```
values: NODE_NAME ← "파드의 spec.nodeName을 읽어라" → 스케줄러가 노드 배치 후 기록
  → kubelet이 컨테이너 시작 시 환경변수 채움 → Alloy 설정의 sys.env("NODE_NAME")이 읽음
  → "spec.nodeName=<자기 노드>" 조건으로 API 서버에 목록 요청 → API 서버가 거름
```

값을 읽는 주체가 다르다: `fieldRef`는 kubelet, `configMap.content`의 `selectors`와 `sys.env`는 Alloy, 요청에 담긴 `fieldSelector`는 API 서버.

#### 필드 셀렉터는 허용된 필드만 된다
이름은 객체의 경로(`spec.nodeName`)와 같지만 API 서버가 리소스별로 허용한 필드만 쓸 수 있다.
- 동작: `spec.nodeName`, `status.phase`
- 거부(`field label not supported`): `spec.containers[0].image`, `metadata.labels.app`
- 라벨은 필드 셀렉터가 아니라 라벨 셀렉터(`-l`)로 거른다.

#### 다른 `selector`와 헷갈리지 않기
Alloy의 `selectors`는 Alloy 설정 문법이고, Service의 `selector`(라벨로 트래픽 대상 파드를 고름), Prometheus CR의 `ruleSelector`와는 이름만 비슷하고 별개다. `configMap.content: |` 안쪽은 쿠버네티스도 Helm도 해석하지 않는 문자열이다.

### 알림 → 로그 흐름 검증
`oom-test`를 띄워서 다음을 확인했다.
- 알림이 **Alertmanager에 도착**했다. `/api/v2/alerts`에 `ContainerOOMKilled`(oom-test)가 `active`로 있고 receiver는 `null`이었다. (4절에서 확인하지 못했던 것을 이번에 확인)
- Loki에서 `{pod="oom-test"}`로 해당 파드의 로그를 조회할 수 있었다.
- OOMKilled로 강제 종료된 프로세스는 **오류 로그를 남기지 않는다.** Loki에는 시작 메시지(`stress: info: ... dispatching hogs`)만 있었고, 원인은 파드 상태(`reason: OOMKilled`, `exitCode: 137`)에서 확인했다. 즉 이 유형은 로그가 아니라 메트릭/파드 상태가 단서다.
- `kubectl logs --previous`는 이번에 `unable to retrieve container logs`로 실패했다. 원인은 확인하지 않았다(컨테이너가 이미 정리된 시점이었을 가능성).

### 리소스
설치 후 Loki 185Mi(limit 768Mi), Alloy 파드 96~196Mi(limit 256Mi). Alloy 한 파드가 limit의 약 77%라 로그량이 늘면 OOMKilled가 날 수 있다(`top`은 파드 단위라 `alloy`와 `config-reloader`가 합쳐진 값일 수 있음). 노드 메모리는 13~21%였다.

### 정리 방법
`helm uninstall loki alloy -n monitoring`, `kubectl delete -f monitoring/loki-datasource.yaml`. PVC(`storage-loki-0`)는 `enableStatefulSetAutoDeletePVC` 기본값이 true라 함께 삭제되는 것으로 알고 있으나 확인하지 않았다.

## 6. 배운 점

- 같은 증상이라도 기본 규칙의 `for: 15m`은 실습에서 관찰하기에 너무 느리다. 운영에서는 오탐과 감지 시간의 균형이므로 값은 환경에서 조정한다.
- `kube_pod_container_status_last_terminated_reason`은 다음 종료 전까지 값이 유지된다. 재시작 증가 조건을 함께 걸지 않으면 오래된 OOMKilled 기록으로 계속 발화한다.
- 알림 해소는 파드 삭제 직후가 아니라 시간이 지나야 일어났다.

## 7. 다음 할 일

- [x] 로깅: Loki, Alloy를 helm 차트로 설치하고 Grafana 데이터 소스로 연결
- [x] 알림이 Alertmanager에 도착하는지 확인
- [ ] 로그 기반 알림은 Grafana-managed alert로 만들고 provisioning 파일로 저장
- [ ] 알림 → 대시보드 → 로그 순서의 진단 흐름 기록
- [ ] 오탐/미탐 조정 (현재는 장애를 일으킨 경우만 확인)
