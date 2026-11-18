# 07. GitOps 기본: Argo CD

> 진행 중. 설치, 드리프트 감지와 self-heal, 잘못된 변경 병합과 `git revert` 롤백까지 했다. app-of-apps와 `prune`(Application 삭제)까지 했다. ApplicationSet은 하지 않았다.

## 1. 목표

Git을 클러스터의 기준으로 삼는다. `kubectl`로 클러스터를 직접 바꾸면 감지되고 되돌려지는지 확인한다(01번의 "Git에 안 남는 변경" 문제를 도구로 해결).

## 2. 구성

| 파일 | 설명 |
| --- | --- |
| `gitops/argocd-values.yaml` | Argo CD helm values (차트 `argo/argo-cd` 10.18.1, Argo CD v3.6.1) |
| `gitops/root.yaml` | app-of-apps: `gitops/applications/`를 읽어 Application을 만드는 Application. 사람이 `kubectl apply`하는 유일한 파일 |
| `gitops/applications/podinfo.yaml` | Application: Git `main`의 `apps/podinfo`를 `default` 네임스페이스에 맞춤 |
| `gitops/applications/podinfo-monitoring.yaml` | Application: `monitoring/podinfo-*.yaml`(ServiceMonitor, PrometheusRule) 관리 |

- 설치: `helm install argocd argo/argo-cd --version 10.18.1 -n argocd --create-namespace -f gitops/argocd-values.yaml`
- 로컬 자원을 아끼려고 `dex`(SSO)와 `notifications`를 껐다. 설치 후 노드 메모리는 여유가 있었다(노드당 7~23%).
- 관리 범위는 `apps/podinfo`만이다. `labs/`(장애 재현용)와 helm으로 직접 설치한 모니터링 스택은 넣지 않았다.
- 처음에는 Application을 `kubectl apply`로 올렸다(부트스트랩). 이때는 Argo CD가 읽는 경로가 `apps/podinfo`뿐이라 `gitops/applications/podinfo.yaml`을 Git에서 고쳐도 반영되지 않았다. 이 구멍은 아래 app-of-apps로 메웠다.
- Application 리소스는 Argo CD가 감시하는 `argocd` 네임스페이스에 두고, 앱의 리소스는 `destination.namespace`(`default`)에 만들어진다.
- CLI는 `argocd ... --core`로 로그인 없이 클러스터에 직접 접근해 썼다.

## 3. 실습 결과

### 이미 `kubectl apply`로 배포된 리소스를 넘겨받기
- Application을 만들자 4개 리소스(Service, Deployment, HPA, PDB)가 모두 `OutOfSync`로 나왔다. `argocd app diff`로 보니 **차이는 `argocd.argoproj.io/tracking-id` 어노테이션 하나**였고 설정값은 Git과 같았다. Argo CD가 "이 리소스는 이 Application 소유"라고 표시하는 어노테이션이 아직 없어서였다.
- 수동 sync(1초)로 어노테이션이 붙으며 `Synced`가 됐다. 파드 목록은 그대로였다(메타데이터만 바뀌어 롤아웃이 없었다).

### 드리프트 감지 (수동 sync 모드)
- `kubectl patch hpa podinfo`로 `maxReplicas`를 6 → 10으로 바꾸자 **약 15초 안에 `OutOfSync`로 표시됐다.** 값은 그대로 10으로 남았다(감지만 하고 되돌리지는 않음).

### self-heal (`syncPolicy.automated.selfHeal: true`)
- 자동 동기화를 켠 뒤 같은 상태(max 10)가 **약 5초 만에 6으로 되돌아갔다.**
- PDB를 `kubectl delete`로 지우자 **1초 만에 새 UID로 다시 만들어졌다.**
- 설정한 옵션: `selfHeal`(직접 수정을 되돌림), `prune`(Git에서 지운 리소스를 클러스터에서도 삭제). `prune`은 동작을 아직 확인하지 않았다.

### HPA와 `replicas`
- Deployment 매니페스트에 `replicas`가 없어서 Argo CD가 HPA가 정한 파드 수를 드리프트로 보지 않았다. sync 전후 파드 3개가 유지됐다.

### CI는 통과하지만 런타임에서 실패하는 변경 (PR #12, 병합 후 revert)
- `readinessProbe.path`를 `/readyz` → `/readyz-typo`로 바꾼 PR은 `validate`를 통과했고(스키마상 문제없음) 병합했다.
- 병합 약 113초 뒤 Argo CD가 반영했다(`Synced/Progressing`). 새 파드는 `0/1`에서 `Readiness probe failed: statuscode: 404`로 멈췄고 **기존 파드 3개가 유지**됐다. 엔드포인트 3개, `probe-client`의 최근 300건은 모두 200이었다. 롤아웃이 새 파드가 Ready가 될 때까지 기존 파드를 내리지 않아서다(`maxSurge: 1`).
- 약 12분이 지난 시점에도 Argo CD 상태는 `Progressing`이었다(`Degraded` 전환은 보지 못했다).
- `git revert -m 1`로 되돌리는 PR(#13)을 병합하자 **약 17초 만에** 반영되어 `Synced/Healthy`, 파드 3개로 복구됐다.
- Argo CD는 Git의 결과를 그대로 반영할 뿐 런타임 정상 여부를 판단해서 막지 않는다. 그래서 정상 판단은 probe와 롤링 업데이트 설정이 맡는다.
- 반영 지연은 병합 후 113초(오타)와 17초(revert)로 차이가 났다. 폴링 주기와 병합 시점의 어긋남으로 추정하지만 확인하지 않았다.

### CI가 잡는 변경과 못 잡는 변경
- 존재하지 않는 이미지 태그(`6.17.0-typo`) PR은 **CI가 막았다.** 원인은 설계한 검사가 아니라 `trivy image`(보고만 하게 둔 4단계)가 이미지를 가져오지 못해 실행 오류로 실패한 것이다. 결과적으로 이미지 존재 확인 역할을 한다(의도한 동작은 아니다). 병합하지 않고 닫았다.
- probe 경로 오타 같은 의미상의 오류는 스키마 검증이 못 잡는다.

### app-of-apps
- `gitops/root.yaml`(Application `root`, `automated` + `selfHeal` + `prune`)을 `kubectl apply`했다. `root`는 `gitops/applications/`를 읽는다. `root.yaml`을 `applications/` 밖에 둔 것은 안에 두면 `root`가 자기 자신을 관리하기 때문이다.
- 기존 `podinfo` Application을 `root`가 넘겨받았다(`tracking-id`가 `root:argoproj.io/Application:argocd/podinfo`로 바뀜).
- **`kubectl` 없이 Git만으로** `podinfo-monitoring` Application을 추가했다(PR 병합 후 약 146초에 `Synced/Healthy`). `monitoring/`에는 helm values도 섞여 있어서 `directory.include: "podinfo-*.yaml"`로 필요한 파일만 읽게 했다. PrometheusRule은 `monitoring`, ServiceMonitor는 `default`에 만들어졌다(리소스에 적힌 네임스페이스가 있으면 그대로, 없으면 `destination.namespace`).
- CI의 kubeconform 대상에 `gitops/`를 추가했고, Argo CD의 Application도 CRD 카탈로그 스키마로 검증됐다.

### prune: Application 파일을 Git에서 삭제
- `podinfo-monitoring.yaml`을 지우는 PR을 병합하자 **약 97초 뒤 Application이 사라졌다.** 하지만 PrometheusRule과 ServiceMonitor는 **그대로 남았다**(AGE가 유지됨). Application에 `resources-finalizer`가 없어서 Application만 지워지고, 배포된 리소스는 고아가 된다.
- 즉 Git에서 파일을 지우는 것과 클러스터에서 리소스가 사라지는 것이 같지 않다. 리소스까지 지우려면 Application에 finalizer(`resources-finalizer.argocd.argoproj.io`)를 둬야 한다고 알고 있다(이번에는 확인하지 않았다).
- revert PR로 되돌리자 약 237초 뒤 Application이 복원됐고 남아 있던 CR을 다시 소유했다(`tracking-id`가 `podinfo-monitoring:...`).
- 반영 지연이 97초, 146초, 237초로 다양했다. 모두 폴링 주기 안으로 추정하지만 확인하지 않았다.

## 4. 배운 점

- **감지와 복구는 별개 설정이다.** 기본(수동 sync)은 `OutOfSync`로 알려만 주고, `selfHeal`을 켜야 되돌린다. 운영에서는 자동 복구 전에 알림만 받고 싶은 경우도 있다.
- `kubectl`로 한 변경은 몇 초 안에 사라진다. 급한 장애 대응에서 직접 고친 설정이 곧 되돌려지면 혼란스러우므로, 이 도구를 쓰는 클러스터에서는 팀이 "수정은 Git으로"를 규칙으로 알고 있어야 한다.
- 기존 리소스를 도구에 넘기는 첫 sync는 `OutOfSync`로 시작할 수 있다. 원인을 diff로 확인하면 소유 표시 하나뿐이라는 것을 알 수 있다.
- **부트스트랩은 한 번은 사람이 한다.** app-of-apps로 줄일 수 있는 것은 수동 단계의 수이지 0이 되는 것은 아니다. `root`를 `kubectl`로 지우면 아무도 되살리지 않는다.
- `prune`은 Git에서 지운 것을 클러스터에서도 지운다는 뜻이지만, 대상이 Application일 때는 finalizer 없이는 배포된 리소스가 남는다. 삭제 동작은 쓰기 전에 직접 확인해야 한다.
- GitOps에서 롤백은 `git revert`를 PR로 병합하는 것이다. 클러스터에 직접 되돌리면 self-heal이 다시 Git 상태로 만든다.
- 롤아웃 설정(`maxSurge`, probe, PDB)이 잘못된 변경의 피해를 줄여 준다. GitOps는 배포 속도를 높이는 만큼 이런 안전장치가 중요해진다.
- 설정을 직접 읽지 않은 상태에서 "달라 보인다"고 판단하지 말고 diff를 본다.

## 5. 검증하지 않은 것

- 반영 지연이 폴링 주기(기본 3분이라고 알고 있다) 때문인지, 웹훅이나 `refresh`로 줄일 수 있는지
- 롤아웃이 멈춘 채로 `progressDeadlineSeconds`(기본 600초)를 넘기면 Argo CD가 `Degraded`가 되는지
- finalizer를 붙였을 때 Application 삭제가 리소스까지 지우는지
- `prune`이 앱 내부 리소스(예: `apps/podinfo`에서 파일을 지울 때)에도 같은 방식으로 도는지
- 동기화 실패 진단
- ApplicationSet
- HPA가 `replicas`를 바꿔도 드리프트로 잡히지 않는 것은 이번 환경에서 관찰했지만, `ignoreDifferences` 없이도 항상 그런지는 확인하지 않았다
- Argo CD UI, 초기 admin 시크릿 삭제 (CLI `--core`만 사용)

## 6. 다음 할 일

- [x] Argo CD 설치, podinfo Application 등록
- [x] 드리프트 감지(수동 모드)와 self-heal
- [x] 런타임에서 실패하는 변경을 PR로 병합했을 때의 동작과 `git revert` 롤백
- [x] app-of-apps, Application 삭제 시 `prune` 확인
- [ ] 동기화 실패 진단
- [ ] ApplicationSet(선택)
