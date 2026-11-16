# 02. 장애 재현 (liveness, OOMKilled, CPU throttling)

01번에서 검증하지 못한 부분을 이어서 확인한 기록입니다. 실습용 리소스는 `apps/podinfo`의 Deployment를 건드리지 않고 별도 파드(`labs/02/`)로 만들었습니다.

- 환경: kind 클러스터 (control-plane 1 + worker 3), Kubernetes v1.37.0
- 브랜치: `feat/podinfo-failure-injection`

## 1. 목표

- 프로세스는 살아 있는데 응답하지 못할 때, liveness probe가 컨테이너를 재시작하는가
- 실행 중 메모리가 limit을 넘으면 어떻게 보이는가 (01번의 초기화 단계 OOM과 비교)
- CPU limit을 넘으면 메모리와 같이 죽는가

## 2. 실습용 매니페스트

| 파일 | 내용 |
| --- | --- |
| `labs/02/liveness-test.yaml` | podinfo 파드. liveness probe가 `/readyz`를 봄 (10초 간격, 3회 실패 시 재시작) |
| `labs/02/oom-test.yaml` | `polinux/stress` 파드. memory limit `100Mi`인데 `150M` 할당 |
| `labs/02/cpu-test.yaml` | `polinux/stress` 파드. cpu limit `100m`인데 CPU 1코어를 쓰려 함 |

podinfo에는 메모리를 쓰게 만드는 엔드포인트가 없어서 OOM과 CPU 실습에는 `stress`를 썼습니다.

## 3. 실습

### 실습 1. liveness 실패 -> 재시작

```bash
kubectl apply -f labs/02/liveness-test.yaml
kubectl exec liveness-test -- curl -s -X POST localhost:9898/readyz/disable
kubectl get pod liveness-test -w
kubectl describe pod liveness-test | grep -E "Last State|Reason|Exit Code|Liveness probe failed|Killing"
```

`/readyz/disable`을 호출하면 프로세스는 살아 있지만 `/readyz`가 503을 반환합니다. "살아 있지만 응답하지 못하는 앱"을 흉내 낸 것입니다.

결과:
- 호출 후 **30초**(10초 x 3회) 뒤에 `RESTARTS`가 1이 되었습니다.
- 이벤트: `Liveness probe failed: HTTP probe failed with statuscode: 503` 3회, 이어서 `Container podinfo failed liveness probe, will be restarted`
- `Last State: Terminated`, `Reason: Completed`, `Exit Code: 0`. kubelet이 SIGTERM을 보냈고 앱이 정상 종료한 것입니다. 01번 실습 1(`/panic`)의 `Reason: Error`, `Exit Code: 255`와 다릅니다. **프로세스가 스스로 죽은 경우와 probe가 죽인 경우는 종료 상태로 구분됩니다.**
- 재시작 후에는 새 프로세스라 `/readyz`가 다시 200이 되었습니다.

변형: `periodSeconds: 5`, `failureThreshold: 1`로 바꾼 파드는 **8초** 만에 재시작되었습니다. 재시작까지의 시간은 대략 `periodSeconds x failureThreshold`이고, probe 주기와 호출 시점이 어긋나면 한 주기만큼 오차가 납니다. 값을 너무 공격적으로 잡으면 일시적인 지연에도 재시작되므로, 보통 `failureThreshold`는 1보다 크게 둡니다.

### 실습 2. OOMKilled (실행 중 초과)

```bash
kubectl apply -f labs/02/oom-test.yaml
kubectl get pod oom-test -w
kubectl describe pod oom-test | grep -E "State:|Reason|Exit Code|Restart Count"
```

결과:
- `STATUS`에 `OOMKilled`가 그대로 보였고, `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`이었습니다. 137은 128 + 9(SIGKILL)입니다.
- 죽을 때마다 재시작되며 `RESTARTS`가 증가했고, 재시작 간격이 점점 길어지면서 `OOMKilled`와 `CrashLoopBackOff`를 오갔습니다 (3분 30초 동안 5회).
- 01번 실습 5와의 비교:

| | 01 실습 5 (limit 8Mi) | 02 실습 2 (limit 100Mi, 150M 할당) |
| --- | --- | --- |
| 죽은 시점 | 컨테이너 초기화 단계 | 앱 실행 중 |
| Reason | `StartError` | `OOMKilled` |
| Exit Code | 128 | 137 |

### 실습 3. CPU throttling

```bash
kubectl apply -f labs/02/cpu-test.yaml
kubectl exec cpu-test -- cat /sys/fs/cgroup/cpu.max
kubectl exec cpu-test -- cat /sys/fs/cgroup/cpu.stat
```

결과:
- 파드는 죽지 않고 `Running`, `RESTARTS 0`을 유지했습니다.
- `cpu.max`는 `10000 100000`(100ms 구간마다 10ms만 사용 가능)이었습니다.
- 약 21초 동안 `usage_usec` 2.1초(한 코어의 약 10%), 209개 구간 중 `nr_throttled` 180, `throttled_usec` 약 16.5초였습니다. 쓰려는 만큼 쓰지 못하고 **기다리게 될 뿐**입니다.
- 이번에는 응답 시간 같은 지연을 직접 측정하지 않고 cgroup 통계로만 확인했습니다.

### 정리

```bash
kubectl delete -f labs/02/ --ignore-not-found
```

## 4. 배운 점

- **메모리는 죽고, CPU는 느려집니다.** 같은 limit이어도 초과 시 동작이 다릅니다. 메모리는 `OOMKilled`로 재시작, CPU는 throttling입니다.
- liveness는 "프로세스가 살아 있는가"가 아니라 "probe가 통과하는가"를 봅니다. 앱이 멈추거나 응답하지 못하는 상태를 복구하려면 probe가 그 상태를 반영하는 경로를 봐야 합니다. 단 liveness가 의존성(DB 등)까지 검사하면 의존성 장애 때 전체가 재시작되는 문제가 생기므로 가볍게 유지합니다.
- 컨테이너가 왜 재시작됐는지는 `Last State`의 `Reason`/`Exit Code`로 구분합니다: `Completed/0`(SIGTERM으로 정상 종료, 예: liveness 실패), `Error/255`(프로세스 비정상 종료), `OOMKilled/137`, `StartError/128`(초기화 실패).
- OOMKilled 파드는 `CrashLoopBackOff`로 보이기도 해서, STATUS만 보지 말고 `describe`의 `Last State`를 봐야 원인을 알 수 있습니다.

## 5. 자주 만나는 문제

| 증상 | 원인 | 해결 |
| --- | --- | --- |
| 파드의 probe 설정을 `apply`로 바꿀 수 없음 | 단독 파드의 `spec`은 대부분 변경 불가 | 파드를 삭제하고 다시 생성 (Deployment는 롤링 업데이트로 교체됨) |
| `kubectl exec`로 메모리를 써도 OOMKilled가 안 보임 | OOM killer가 컨테이너 PID 1이 아니라 exec한 프로세스를 죽일 수 있음 | 메모리를 쓰는 프로세스가 PID 1인 별도 파드로 재현 |

## 6. 다음 단계

- PodDisruptionBudget, 노드 drain (03번)
- 파드 분산 배치 (`topologySpreadConstraints`)
- CPU throttling이 응답 시간에 미치는 영향 직접 측정
