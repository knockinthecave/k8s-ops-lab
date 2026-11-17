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

### 노드 장애: 분산 배치가 없을 때와 있을 때
`docker stop k8s-ops-lab-cluster-worker3`로 노드를 갑자기 죽였다(비자발적 중단). 두 실험 모두 PDB(`minAvailable: 2`)가 적용된 상태였다. 측정은 같은 `probe-client`(0.2초 간격)로 했고 시각은 UTC다.

| | A. 파드 3개가 죽은 노드에 몰림 | B. `topologySpreadConstraints`로 1/1/1 분산 |
| --- | --- | --- |
| 노드 `NotReady` | +44초 | +44초 |
| Ready 엔드포인트 | 0개 (서비스 완전 중단) | 2개 (서비스 유지) |
| 새 파드 생성 | +351초 근처 (기존 파드는 `Terminating`) | +351초 근처 (1개) |
| 비정상 응답 | 000 516건 + 503 14건, 약 346초간 | 000 24건 + 503 5건, 약 42초간 |
| 정상 응답 | - | 1456건 |

- **PDB는 이 상황에서 아무 보호도 하지 못했다.** A에서 3개가 한꺼번에 사라졌다.
- A의 실패는 장애 직후부터 새 파드가 뜰 때까지 계속됐다. B의 실패 29건은 모두 장애 직후 약 42초 안에 났고, 이후에는 남은 2개 파드로 계속 응답했다. 이 구간은 노드가 죽은 것을 쿠버네티스가 알아채기 전이라 엔드포인트에 죽은 파드가 남아 있던 때로 보인다(노드 `NotReady` 전환이 +44초).
- 파드 재생성은 장애 후 약 5~6분이 걸렸다. 40초(노드 NotReady 판정)에 파드 종료 허용 시간 300초가 더해진 값으로 알고 있다(기본 `tolerationSeconds: 300`). 이 값은 확인하지 않았다.
- 노드를 `docker start`로 되살린 뒤에도 파드는 되돌아가지 않았다. 파드는 `worker` 2개, `worker2` 1개, `worker3` 0개로 남았다. 스케줄러의 분산은 파드를 만들 때만 적용되고 사후에 균형을 다시 맞추지 않는다(재배치는 별도 도구가 필요한 것으로 알고 있으며, 확인하지 않았다).

### `topologySpreadConstraints`와 롤링 업데이트
- `labelSelector: app=podinfo`만 쓰고 `kubectl apply`하자 파드가 `worker` 2, `worker3` 1, `worker2` 0으로 놓였다. `maxSkew: 1`인데 차이가 2다.
- `matchLabelKeys: [pod-template-hash]`를 추가하자 롤아웃 두 번 모두 노드마다 1개씩(1/1/1) 놓였다.
- 가설: 롤링 업데이트 중에는 이전 버전 파드도 같은 라벨이라 함께 세어져서 새 파드의 분포가 어긋난다. `pod-template-hash`는 ReplicaSet별 값이라 새 파드끼리만 세게 된다. 결과는 가설과 일치하지만, 두세 번의 관찰이라 원인을 확정한 것은 아니다.
- `whenUnsatisfiable: DoNotSchedule`은 조건을 못 맞추면 파드를 `Pending`으로 둔다. `ScheduleAnyway`는 선호만 한다. 노드 하나가 죽었을 때 `DoNotSchedule`이 파드를 Pending으로 만드는지는 이번에 확인하지 않았다(B에서 새 파드는 정상 생성됐다).
- `nodeTaintsPolicy: Honor`는 테인트로 파드를 받을 수 없는 노드(control-plane)를 분산 계산에서 뺀다. 이 값 없이 한 경우는 확인하지 않았다.

### taint와 toleration
- **taint**: 노드에 붙이는 "아무 파드나 오지 마" 표시. `키=값:효과` 형식이다. 이 클러스터의 control-plane 노드에는 `node-role.kubernetes.io/control-plane:NoSchedule`이 붙어 있다(확인함). 그래서 podinfo 같은 일반 파드는 그 노드에 배치되지 않는다.
- **toleration**: 파드에 붙이는 "그 taint를 견딜 수 있다" 표시. 맞는 toleration이 있는 파드만 taint가 붙은 노드에 올 수 있다.
- 효과(effect): `NoSchedule`(새 파드 배치 금지), `PreferNoSchedule`(가급적 피함), `NoExecute`(이미 있는 파드도 쫓아냄).
- 노드 장애 때 쿠버네티스는 노드에 `not-ready:NoExecute` 같은 taint를 자동으로 붙이고, 파드에는 기본으로 300초짜리 toleration이 붙어 있어 그 시간 뒤에 파드가 쫓겨난다고 알고 있다. 위의 5~6분 지연과 일치하지만 이 부분은 확인하지 않았다.
- `cordon`도 노드에 `unschedulable` taint를 붙이는 것과 비슷하게 동작한다고 알고 있다(확인하지 않음).

### HPA 설정 (`apps/podinfo/hpa.yaml`) - 부하 실험은 아직 하지 않음
- 설정: CPU 평균 사용률 50%(requests `50m` 기준 파드당 25m), `minReplicas: 3`, `maxReplicas: 6`, `behavior`는 기본값. 스케일 지연의 기본 동작을 보려고 기본값을 그대로 뒀다.
- metrics-server가 정상이다: `kubectl top pods`가 동작하고 `v1beta1.metrics.k8s.io`가 `True`다. HPA 적용 20초 뒤 `cpu: 4%/50%`로 인식됐다.
- `scaleTargetRef`는 `apiVersion`, `kind`, `name`으로 대상을 가리킨다. `name`은 Deployment의 `metadata.name`과 같아야 하고, 같은 네임스페이스의 리소스만 찾는다. 파드 라벨로 찾지 않는다(일반 지식).
- **`replicas`와 HPA**: `deployment.yaml`에 `replicas: 3`이 있으면 `apply`할 때마다 그 값으로 덮어써서 HPA와 충돌한다. 그래서 `replicas`를 지웠다.
  - 확인한 것: 지우고 `apply`하자 `kubectl diff`에 `replicas: 3 → 1`이 나왔고, 실제로 1로 떨어졌다가 **약 16초 만에 HPA가 3으로 복구**했다. 그동안 probe 482건 중 503이 2건이었다. 이미 운영 중인 Deployment에서 이 변경을 할 때 순간적으로 1개가 되는 구간이 생긴다.
  - 최소 개수는 이제 HPA의 `minReplicas`가 정한다.
- 적용: 지금은 `kubectl apply -f apps/podinfo/`로 폴더째 적용한다. 실무에서는 Git에 커밋하고 GitOps 도구(Argo CD 등)가 반영하며, 이때도 `replicas`는 매니페스트에 적지 않는다(일반 지식, 로드맵 07번에서 다룸).

#### 부하 도구에서 만난 문제 (`labs/05/load-job.yaml`)
- `hey`를 `-n 1`로 시험하면 사용법 오류가 난다. 요청 수가 동시성(기본 50)보다 작으면 안 된다.
- 첫 부하 Job이 **`OOMKilled`**로 실패했다(메모리 limit 128Mi). `hey`가 요청 결과를 메모리에 모으기 때문으로 추정하지만 확인하지는 않았다. 요청 속도를 제한(`-q 40`)하고 limit을 512Mi로 올렸다. 수정 후 실행은 아직 하지 않았다.
- 폴링 스크립트에서 `kubectl get hpa`의 TARGETS 열(`cpu: 4%/50%`)에 공백이 있어 `awk` 열 번호가 어긋났고, 그 실행 기록은 쓸 수 없었다. 이런 출력은 `awk` 대신 `-o jsonpath`로 읽는다.

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

- **중단의 종류마다 필요한 도구가 다르다.**

  | 중단 종류 | 도구 | 이번 실험 결과 |
  | --- | --- | --- |
  | 자발적 (drain 등) | PDB | 비정상 응답 8건 → 0건. drain은 4초 → 15초로 느려짐 |
  | 비자발적 (노드 장애) | 분산 배치(`topologySpreadConstraints`) | 서비스 중단 약 346초 → 약 42초 구간의 일부 실패 |

- PDB는 자발적 중단에서 동시에 내려가는 파드 수를 제한할 뿐, 노드 장애는 막지 못한다(직접 확인: PDB가 있는 상태에서 파드 3개가 한꺼번에 사라졌다).
- **replicas 수와 장애 격리는 별개다.** 파드가 3개여도 한 노드에 있으면 사실상 1개짜리와 같다.
- 스케줄러의 기본 분산은 보장이 아니다. 분산을 보장하려면 규칙을 명시해야 하고, **적용한 뒤 실제 분포를 확인해야 한다**(`matchLabelKeys` 없이 2/1/0으로 어긋났던 사례).
- 분산 배치는 장애 중 서비스를 유지하게 해 줄 뿐 복구를 빠르게 하지는 않는다. 파드 재생성은 약 5~6분이 걸렸고, 노드가 돌아와도 파드는 재배치되지 않았다.
- `minAvailable`을 replicas와 같게 두면 drain이 영원히 멈춘다. 증상은 drain이 끝나지 않는 것이고 `ALLOWED DISRUPTIONS: 0`으로 진단한다.
- 실험 도구도 조건을 만든다: 컨트롤러 없는 단독 파드(`probe-client`)가 drain을 막아 실험이 의도와 다르게 실패했다. 에러 메시지를 읽어 원인을 구분해야 한다.

## 6. 검증하지 않은 것

- 503의 정확한 출처(종료 중인 파드의 응답인지 다른 경로인지)
- HPA의 스케일 업/다운 동작과 지연, 부하 중 CPU 지표 (부하 실험 미실시)
- 이미 운영 중인 Deployment에서 `replicas`를 지울 때 1로 떨어지는 동작은 이 환경에서만 확인했다
- 노드 장애 후 파드 재생성 지연이 `tolerationSeconds: 300`에서 오는지
- `nodeTaintsPolicy: Honor`를 빼면 분산이 달라지는지
- 노드가 죽은 상태에서 `DoNotSchedule`이 파드를 Pending으로 만드는지

## 7. 정리

drain한 노드는 모두 `kubectl uncordon`으로 복구했고, PDB는 `apps/podinfo/pdb.yaml`(`minAvailable: 2`) 상태다. `probe-client` 파드는 `worker`에 두고 다음 실험에 쓰려고 남겨 두었다(`kubectl delete -f labs/05/probe-client.yaml`로 삭제). HPA(`podinfo`)는 적용된 상태이고, 부하 Job(`load`)은 실패한 채 남아 있을 수 있어 `kubectl delete job load`로 지운다.

## 8. 다음 할 일

- [x] PDB 없이 drain
- [x] PDB 적용 후 drain
- [x] `minAvailable`을 replicas와 같게 해서 drain이 멈추는 경우
- [x] `topologySpreadConstraints`로 노드 분산 (노드 장애 비교 포함)
- [ ] HPA (매니페스트 적용과 `replicas` 제거까지 완료, 부하 중 스케일 동작과 지연은 미실시)
- [ ] ResourceQuota, LimitRange
