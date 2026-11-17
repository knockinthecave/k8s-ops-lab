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

## 4. 배운 점

- PDB는 **자발적 중단**(drain, 업그레이드)에서 동시에 내려가는 파드 수를 제한한다. 그 대가로 drain이 느려진다.
- 보호가 되려면 PDB가 선택하는 파드의 Ready 수가 기준이다. 파드가 한 노드에 몰려 있어도 PDB가 서비스 단절은 막지만, 노드 장애 같은 비자발적 중단은 막지 못한다(아래 "하지 않은 것").

## 5. 검증하지 않은 것

- 503의 정확한 출처(종료 중인 파드의 응답인지 다른 경로인지)
- `minAvailable`을 replicas와 같게 두면 drain이 멈추는지
- 노드 장애(비자발적 중단)에서 PDB가 무관하다는 점

## 6. 정리

`kubectl uncordon k8s-ops-lab-cluster-worker`로 노드를 복구했다. `probe-client` 파드는 다음 실험에 쓰려고 남겨 두었다(`kubectl delete -f labs/05/probe-client.yaml`로 삭제).

## 7. 다음 할 일

- [x] PDB 없이 drain
- [x] PDB 적용 후 drain
- [ ] `minAvailable`을 replicas와 같게 해서 drain이 멈추는 경우
- [ ] `topologySpreadConstraints`로 노드 분산
- [ ] HPA (부하 중 스케일 동작과 지연)
- [ ] ResourceQuota, LimitRange
