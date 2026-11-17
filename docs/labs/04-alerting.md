# 04. 알림 규칙

> 상태: **알림 규칙 부분 완료**. 로깅(Loki, Alloy)은 아직 하지 않았다.

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
- 확인하지 않은 것: 발화한 알림이 Alertmanager에 실제로 도착했는지. Prometheus의 알림 상태(`/api/v1/alerts`)만 봤다.

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
- 발화한 알림이 Alertmanager에 실제로 도착했는지는 확인하지 않았다(연결 설정과 `activeAlertmanagers`만 확인).
- Alertmanager 라우팅과 외부 전달(Discord 등)은 하지 않았다.

## 5. 배운 점

- 같은 증상이라도 기본 규칙의 `for: 15m`은 실습에서 관찰하기에 너무 느리다. 운영에서는 오탐과 감지 시간의 균형이므로 값은 환경에서 조정한다.
- `kube_pod_container_status_last_terminated_reason`은 다음 종료 전까지 값이 유지된다. 재시작 증가 조건을 함께 걸지 않으면 오래된 OOMKilled 기록으로 계속 발화한다.
- 알림 해소는 파드 삭제 직후가 아니라 시간이 지나야 일어났다.

## 6. 다음 할 일

- [ ] 로깅: Loki, Alloy를 helm 차트로 설치하고 Grafana 데이터 소스로 연결
- [ ] 로그 기반 알림은 Grafana-managed alert로 만들고 provisioning 파일로 저장
- [ ] 알림 → 대시보드 → 로그 순서의 진단 흐름 기록
- [ ] 오탐/미탐 조정 (현재는 장애를 일으킨 경우만 확인)
