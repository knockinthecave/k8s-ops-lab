# 05. 가용성 설계 (PDB와 drain)

> 진행 중. 이 문서는 PDB 실습까지만 기록했다. topologySpread, HPA, ResourceQuota는 아직 하지 않았다.

## 1. 목표

노드를 drain할 때 서비스가 끊기는지, PodDisruptionBudget(PDB)이 이를 어떻게 막는지 직접 확인한다.

## 2. 환경과 측정 방법

- kind 클러스터(control-plane 1 + worker 3), podinfo `6.17.0`, replicas 3
- 측정: `labs/05/probe-client.yaml`. 클러스터 안에서 `podinfo` Service로 0.2초마다 `/healthz`를 호출해 `시각 HTTP코드`를 로그로 남긴다(시각은 UTC, 000/비200은 실패).
- 조건 맞추기: 파드가 노드마다 하나씩 퍼져 있으면 drain해도 파드 하나만 빠져 차이가 보이지 않는다. 그래서 `worker2`, `worker3`를 cordon한 뒤 `rollout restart`로 **파드 3개를 `worker` 한 노드에 몰고**, cordon을 풀고 `worker`를 drain했다.

## 3. 실습 결과

| 조건 | drain 소요 | 비정상 응답 |
| --- | --- | --- |
| PDB 없음 | 약 4초 | 503 8건 (약 3초 구간) |
| PDB `minAvailable: 2` | 약 15초 | 0건 (62건 모두 200) |

- PDB 없음: 파드 3개가 동시에 evict됐다. 새 파드가 뜨기 전까지 정상 엔드포인트가 부족한 구간이 있었다.
- PDB 있음: `Cannot evict pod as it would violate the pod's disruption budget.`가 나오며 drain이 5초 간격으로 재시도했고, 새 파드가 Ready가 된 뒤에 다음 파드가 evict됐다. `ALLOWED DISRUPTIONS`는 1이었다.
- 롤아웃(`rollout restart`) 시작 시점에도 503이 1건 있었다(PDB 없음 실험 직전). 원인은 확인하지 않았다.

### `minAvailable`을 replicas와 같게 둔 경우 (`labs/05/pdb-min3.yaml`)
- `kubectl get pdb`의 `ALLOWED DISRUPTIONS`가 **0**이 됐다. `worker3`(podinfo 파드 2개)를 `--timeout=30s`로 drain하자 파드마다 약 6번 재시도하다가 `global timeout reached: 30s`로 실패했다. 파드는 하나도 evict되지 않았고 노드는 `Ready,SchedulingDisabled`로 남았다. 요청 125건은 모두 200이었다(서비스는 영향 없음).
- 실무 의미: 이 설정은 **노드 비우기를 영원히 막는다.** 업그레이드나 노드 교체 자동화가 이 PDB 때문에 멈출 수 있다. 증상은 drain이 끝나지 않는 것이고, 진단은 `kubectl get pdb`에서 `ALLOWED DISRUPTIONS: 0`을 확인하는 것이다.
- 해결: `kubectl apply -f apps/podinfo/pdb.yaml`로 `minAvailable: 2`로 되돌리자 같은 drain이 9초 만에 끝났고 요청 43건 모두 200이었다.
- 처음 시도는 PDB와 무관하게 실패했다. `probe-client`가 컨트롤러 없는 단독 파드이고 `worker3`에 고정돼 있어서 drain이 `cannot delete Pods that declare no controller (use --force to override)`로 거부했다(시작 전 검사 단계). 클라이언트를 `worker`로 옮겨서 다시 했다. PDB 실험과 헷갈리지 않도록 에러 메시지를 구분해서 읽어야 한다.

## 4. 개념 정리

일반 지식이며, 이 실습에서 직접 확인한 범위는 3절과 표시한 부분뿐이다.

### evict와 drain
- **evict(축출)**: API 서버의 eviction API(`pods/eviction`)로 파드 종료를 요청하는 방식. 요청을 받으면 API 서버가 먼저 PDB를 확인하고, 위반이면 거부한다(`Cannot evict pod...`). 허용되면 graceful 종료(SIGTERM 후 대기)로 파드를 지운다.
- **drain**: `cordon`(새 파드 배치 금지) 후 노드 위 파드를 하나씩 evict한다. 거부당한 파드는 5초 뒤 재시도한다(실습 로그의 `will retry after 5s`).
- 파드를 "옮기는" 게 아니라 **지우고, 컨트롤러(ReplicaSet)가 다른 노드에 새로 만든다.** 컨트롤러가 없는 단독 파드는 drain하면 사라지므로 kubectl이 기본으로 막는다(`--force` 필요).
- drain은 노드를 복구하지 않는다. 끝난 뒤 `uncordon`을 직접 해야 한다(실습에서 확인).
- 사용한 옵션: `--ignore-daemonsets`(DaemonSet 파드는 evict해도 바로 다시 생기므로 건너뜀, 없으면 에러), `--delete-emptydir-data`(emptyDir 데이터 삭제 허용).

| 명령 | 효과 |
| --- | --- |
| `kubectl cordon 노드` | 새 파드 배치만 막음 |
| `kubectl drain 노드` | cordon + 파드 evict |
| `kubectl uncordon 노드` | 다시 스케줄 가능하게 복구 |

### PDB가 보장하는 것
- 보장하는 것은 **개수**다. evict하기 전에 "evict한 뒤에도 Ready 파드가 `minAvailable` 이상 남는가"를 확인하고, 아니면 거부한다. PDB가 파드를 직접 유지하는 게 아니라 **기준 아래로 내리는 evict를 거부**하는 방식이다.
- `minAvailable: 2`(replicas 3)는 `maxUnavailable: 1`과 같은 효과다.
- 진행 순서(실습에서 확인한 흐름): 파드 A evict → 새 파드 A'가 Ready가 될 때까지 B evict는 거부 → A' Ready 후 B evict → 같은 방식으로 C. 이 대기 때문에 drain이 4초에서 15초로 늘었다.
- 이미 Ready 파드가 기준 이하이면 evict가 계속 막히고, drain은 복구될 때까지 재시도한다.

### 자발적 중단과 비자발적 중단
| 구분 | 예 | PDB 적용 |
| --- | --- | --- |
| 자발적 (eviction API 경유) | `kubectl drain`, 클러스터 업그레이드의 노드 비우기, 오토스케일러의 노드 축소 | 적용 |
| 비자발적 | 노드 장애, 전원 차단, OOMKilled | 적용 안 됨 |
| 직접 삭제 | `kubectl delete pod` | eviction API를 거치지 않아 PDB 무시 |

직접 확인한 것은 drain뿐이다. 나머지는 일반 지식이다.

### 트래픽 관점
트래픽은 Ready 상태인 파드(Service의 엔드포인트)로만 간다. drain 중 엔드포인트 수는 `3 → 2 → 3 → 2 → 3 → 2 → 3`처럼 오르내리고, 그 사이 요청은 남은 파드로 나뉜다.
- 파드 하나가 빠졌을 때 남은 파드가 부하를 감당할 수 있어야 한다(리소스 설계 문제).
- 엔드포인트에서 빠지는 시점과 각 노드의 kube-proxy가 이를 반영하는 시점 사이의 시차 때문에, 요청이 많거나 종료가 느린 앱은 짧게 실패할 수 있다고 알고 있다. 이 실습의 62건에서는 재현되지 않았다. 대응으로 preStop `sleep` 등이 있다.
- 이번 drain 중 엔드포인트 수 변화를 직접 찍지는 않았다(클라이언트 로그로만 확인).

### 배치와 중단은 다른 문제다
| 문제 | 도구 |
| --- | --- |
| 파드가 한 노드에 몰릴 수 있다 (배치) | `topologySpreadConstraints`, `podAntiAffinity` |
| 중단할 때 한꺼번에 너무 많이 내려간다 (속도 제한) | PDB |

- 이 실습은 파드 3개를 일부러 한 노드에 몰아 PDB 효과를 극적으로 보였다. PDB가 배치를 해결해 주는 것은 아니다.
- 파드가 한 노드에 몰려 있을 때 그 노드가 **장애**로 죽으면 PDB는 소용이 없다(비자발적 중단). 막아 주는 것은 분산 배치다.
- 스케줄러는 기본적으로 어느 정도 분산하지만 보장하지는 않는다. 실습 전에 파드가 노드마다 하나씩 퍼져 있던 것은 이 기본 동작 때문으로 보인다. 강제하려면 `topologySpreadConstraints`를 명시한다.
- 따라서 PDB는 의도적으로 노드를 비울 때의 속도 제한, topologySpread는 예상치 못한 장애에 대비한 분산이다. 둘은 함께 쓴다.

## 5. 배운 점

- PDB는 **자발적 중단**(drain, 업그레이드)에서 동시에 내려가는 파드 수를 제한한다. 그 대가로 drain이 느려진다.
- 보호가 되려면 PDB가 선택하는 파드의 Ready 수가 기준이다. 파드가 한 노드에 몰려 있어도 PDB가 서비스 단절은 막지만, 노드 장애 같은 비자발적 중단은 막지 못한다(아래 "하지 않은 것").

## 6. 검증하지 않은 것

- 503의 정확한 출처(종료 중인 파드의 응답인지 다른 경로인지)
- 노드 장애(비자발적 중단)에서 PDB가 무관하다는 점

## 7. 정리

drain한 노드는 모두 `kubectl uncordon`으로 복구했고, PDB는 `apps/podinfo/pdb.yaml`(`minAvailable: 2`) 상태다. `probe-client` 파드는 `worker`에 두고 다음 실험에 쓰려고 남겨 두었다(`kubectl delete -f labs/05/probe-client.yaml`로 삭제).

## 8. 다음 할 일

- [x] PDB 없이 drain
- [x] PDB 적용 후 drain
- [x] `minAvailable`을 replicas와 같게 해서 drain이 멈추는 경우
- [ ] `topologySpreadConstraints`로 노드 분산
- [ ] HPA (부하 중 스케일 동작과 지연)
- [ ] ResourceQuota, LimitRange
