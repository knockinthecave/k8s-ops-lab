# 01. 안정성 기본기 (probe, resources, 롤링 업데이트)

podinfo Deployment에 안정성 설정을 넣고, **설정이 실제로 동작하는지 직접 깨뜨려 가며 검증**한 기록입니다.

- 대상: `apps/podinfo/deployment.yaml`
- 환경: kind 클러스터 (control-plane 1 + worker 3), podinfo `6.17.0`, replicas 3
- 브랜치: `feat/podinfo-stability`

## 1. 목표

설정을 "넣었다"와 "동작한다"는 다릅니다. 아래 질문에 직접 답하는 것이 목표입니다.

- 프로세스가 죽으면 어떻게 복구되는가 (liveness)
- 준비되지 않은 파드는 트래픽에서 빠지는가 (readiness)
- 배포 중에 요청이 끊기지 않는가 (롤링 업데이트)
- 배포가 실패하면 서비스는 어떻게 되는가 (롤백)
- 메모리 limit이 너무 낮으면 어떻게 되는가 (resources)

## 2. 적용한 설정

| 항목 | 값 | 역할 |
| --- | --- | --- |
| `strategy.rollingUpdate` | `maxSurge: 1`, `maxUnavailable: 0` | 배포 중에도 Ready 파드 3개 유지 (무중단) |
| `minReadySeconds` | `5` | Ready 후 5초 안정적이어야 다음 파드로 진행 |
| `revisionHistoryLimit` | `5` | 롤백용 이력 보관 |
| `resources.requests` | cpu `50m`, memory `64Mi` | 스케줄링 시 보장되는 최소 자원 |
| `resources.limits` | cpu `200m`, memory `128Mi` | 초과 시 CPU throttling, 메모리 OOMKilled |
| `startupProbe` | `/healthz`, 1초 간격, 최대 30회 | 기동 완료 전까지 다른 probe 유예 |
| `livenessProbe` | `/healthz`, 10초 간격 | 실패 시 컨테이너 재시작 |
| `readinessProbe` | `/readyz`, 5초 간격 | 실패 시 Service 엔드포인트에서 제외 |

resources 값은 실측이 아니라 시작값으로 정한 것입니다.

적용 전에 `kubectl apply --dry-run=server`로 검증했고, 파드 안에서 `/healthz`, `/readyz`가 `{"status":"OK"}`로 응답하는 것을 확인했습니다.

## 3. 실습

### 준비

```bash
POD=$(kubectl get pod -l app=podinfo -o name | head -1)
echo $POD          # pod/podinfo-... 형태로 나와야 함
kubectl get pods -w                # 다른 터미널에서 상태 관찰
```

### 실습 1. 프로세스 종료 후 재시작 확인

```bash
kubectl exec $POD -- curl -s localhost:9898/panic
kubectl get pods
kubectl describe $POD | grep -A5 "Last State"
```

결과:
- 대상 파드만 `RESTARTS`가 1이 되고, 나머지 두 파드는 `0`으로 영향이 없었습니다.
- `Last State: Terminated`, `Reason: Error`, `Exit Code: 255`
- 파드가 새로 만들어지는 게 아니라 **같은 파드의 컨테이너만 재시작**됩니다.

참고: 이 재시작은 liveness probe가 아니라 프로세스 종료로 일어난 것입니다. probe가 없어도 죽은 컨테이너는 다시 뜹니다. liveness probe가 필요한 경우는 프로세스는 살아 있는데 응답하지 못하는 상태입니다. 이 경우는 이번에 따로 검증하지 않았습니다.

### 실습 2. readiness 실패 시 트래픽 제외

```bash
kubectl get endpoints podinfo -w                       # 다른 터미널
kubectl exec $POD -- curl -s -X POST localhost:9898/readyz/disable
kubectl get pods
kubectl get endpoints podinfo
kubectl exec $POD -- curl -s -X POST localhost:9898/readyz/enable
```

결과:
- 파드가 `0/1 Running`이 되었고 `RESTARTS`는 늘지 않았습니다. 컨테이너를 죽이지 않고 트래픽만 막습니다.
- 엔드포인트가 3개에서 2개로 줄었습니다 (해당 파드 IP `10.244.1.3`이 빠짐).
- `enable` 후 `1/1`로 복귀하고 엔드포인트도 3개로 돌아왔습니다.

### 실습 3. 롤링 업데이트 중 무중단 확인

클러스터 안에서 Service 주소로 요청을 반복해 보냅니다. `port-forward`는 연결된 파드가 교체되면 끊겨서 측정에 부적합합니다.

```bash
# 터미널 A: 요청 반복 (한 줄로 실행)
kubectl run loadtest --rm -it --image=curlimages/curl --restart=Never --command -- sh -c 'while true; do c=$(curl -s -o /dev/null -w "%{http_code}" -m 2 http://podinfo:9898/healthz); if [ "$c" = "200" ]; then echo "$(date +%T) $c"; else echo "$(date +%T) $c ERROR"; fi; sleep 0.1; done'

# 터미널 B: 롤링 업데이트
kubectl rollout restart deploy/podinfo
kubectl rollout status deploy/podinfo
```

결과:
- 롤아웃 내내 응답이 계속 `200`이었습니다.
- 파드 상태 변화는 "새 파드가 `1/1`이 된 뒤에 기존 파드가 `Terminating`"이 파드마다 하나씩 반복되는 패턴이었습니다. `maxSurge: 1`, `maxUnavailable: 0`이 의도대로 동작한 모습입니다.

주의: 처음에 요청 반복을 몇 초만 보고 "무중단"이라고 판단하면 안 됩니다. 롤아웃 전체 구간 동안 이어서 관찰해야 합니다.

### 실습 4. 배포 실패와 롤백

존재하지 않는 이미지 태그로 일부러 배포를 실패시킵니다.

```bash
kubectl set image deploy/podinfo podinfo=ghcr.io/stefanprodan/podinfo:no-such-tag
kubectl rollout status deploy/podinfo --timeout=30s
kubectl get pods
kubectl get events --sort-by=.lastTimestamp | tail
kubectl rollout history deploy/podinfo
kubectl rollout undo deploy/podinfo
```

결과:
- 새 파드 1개만 `ErrImagePull` → `ImagePullBackOff`가 되었고, 기존 파드 3개는 `1/1 Running`을 유지했습니다. Deployment는 `READY 3/3`, `UP-TO-DATE 1`이었습니다.
- `rollout status`는 타임아웃(`timed out waiting for the condition`)으로 끝났습니다. 롤아웃은 실패가 아니라 **진행되지 못하고 멈춘 상태**입니다.
- 원인은 이벤트에서 확인합니다: `failed to resolve reference ".../podinfo:no-such-tag": ... not found`
- 같은 시간 동안 요청 반복 534건이 모두 `200`, 에러 0건이었습니다.
- `rollout undo` 후 정상 복구되었고 `kubectl diff`에도 차이가 없었습니다.

배포가 실패해도 서비스가 영향받지 않은 이유는 새 파드가 Ready가 되지 않으면 기존 파드를 내리지 않기 때문입니다 (readinessProbe + `maxUnavailable: 0`).

### 실습 5. 메모리 limit이 너무 낮을 때

```bash
kubectl set resources deploy/podinfo --limits=memory=8Mi
kubectl set resources deploy/podinfo --requests=memory=4Mi --limits=memory=8Mi
```

결과:
- 첫 번째 명령은 **API 서버가 거부**했습니다: `requests: Invalid value: "64Mi": must be less than or equal to memory limit of 8Mi`. 클러스터는 바뀌지 않았습니다.
- 두 번째 명령은 적용되었고, 새 파드가 `CrashLoopBackOff`가 되었습니다. 이벤트: `container init was OOM-killed (memory limit too low?)`, `Reason: StartError`, `Exit Code: 128`
- 기존 파드 3개는 `1/1`로 유지되었습니다.

참고: 이번에 본 것은 컨테이너 **초기화 단계**에서 OOM으로 죽은 경우입니다. 앱이 실행 중에 메모리를 넘어서 `Reason: OOMKilled`(보통 Exit Code 137)로 죽는 상황은 limit을 더 현실적인 값으로 잡아야 볼 수 있는데, 이번에는 시도하지 않았습니다.

### 원복

실습 4, 5에서 `kubectl set ...`으로 클러스터만 바꿨으므로, 끝나면 파일 기준으로 되돌립니다.

```bash
kubectl apply -f apps/podinfo/deployment.yaml
kubectl rollout status deploy/podinfo
kubectl diff -f apps/podinfo/deployment.yaml     # 차이 없으면 정상
```

## 4. 배운 점

- 안정성 설정은 **조합으로 효과**가 납니다. `maxUnavailable: 0`만으로는 부족하고, readinessProbe가 있어야 "준비된 파드만 트래픽을 받고, 준비된 새 파드가 있을 때만 기존 파드를 내린다"가 성립합니다.
- liveness와 readiness는 실패 시 동작이 다릅니다. liveness는 재시작, readiness는 트래픽 차단만 합니다.
- 배포 실패는 서비스 장애로 이어지지 않을 수 있지만, 롤아웃이 멈춘 채로 남습니다. `rollout status`, `describe`, `events`로 원인을 찾는 연습이 필요합니다.
- **`kubectl rollout undo`보다 파일을 고치고 `apply`하는 쪽이 안전합니다.** `undo`는 `last-applied-configuration` 어노테이션을 갱신하지 않아서 이후 `apply`와 어긋날 수 있다는 경고가 나왔습니다. `kubectl set ...`으로 직접 바꾼 변경은 Git에 남지 않으므로, 실습 후 반드시 파일 기준으로 되돌려야 합니다. GitOps를 쓰는 이유와 이어지는 부분입니다.
- `rollout history`의 `CHANGE-CAUSE`는 `<none>`이었습니다. 변경 이유는 Git 커밋 메시지가 대신합니다.

## 5. 자주 만나는 문제

| 증상 | 원인 | 해결 |
| --- | --- | --- |
| `error: pod, type/name or --filename must be specified` | `$POD`가 비어 있음. 셸 변수는 터미널마다 따로 존재 | 사용하는 터미널에서 `POD=$(...)`를 다시 실행 |
| `zsh: command not found: --restart=Never` 등 | 긴 명령이 붙여넣기 중 줄바꿈으로 끊김 | 한 줄로 실행하거나 스크립트 파일로 저장해 실행 |
| `Warning: v1 Endpoints is deprecated in v1.33+` | `Endpoints`가 `EndpointSlice`로 대체되는 중 | 동작에는 문제 없음. `kubectl get endpointslices -l kubernetes.io/service-name=podinfo`로 대체 가능 |
| `requests ... must be less than or equal to memory limit` | requests가 limits보다 큼 | requests도 함께 낮추거나 limits를 올림 |

## 6. 다음 단계

- `OOMKilled`(실행 중 초과) 재현
- 잘못된 probe 경로로 liveness 실패를 재현해 "멈춘 앱" 복구 확인
- PodDisruptionBudget, 노드 drain, 파드 분산 배치
- Ingress, Gateway API
