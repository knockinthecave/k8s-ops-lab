# k8s-ops-lab

쿠버네티스 운영을 실습하는 저장소입니다. 로컬 [kind](https://kind.sigs.k8s.io/) 클러스터에 [podinfo](https://github.com/stefanprodan/podinfo) 앱을 배포하며 매니페스트 작성과 운영 흐름을 익힙니다.

## 디렉터리 구조

```
.
├── cluster/
│   └── kind.yml              # kind 클러스터 설정 (control-plane 1 + worker 3)
└── apps/
    └── podinfo/
        ├── deployment.yaml   # podinfo 파드 3개를 선언적으로 관리
        └── service.yaml      # 파드에 접근하는 ClusterIP 서비스 (9898)
```

## 매니페스트란?

쿠버네티스에 "원하는 최종 상태"를 선언하는 YAML 파일입니다. 명령을 내리는 대신 상태를 적어두면, 쿠버네티스가 현재 상태와 비교해 알아서 맞춥니다. 각 파일의 필드 설명은 매니페스트 안의 주석을 참고하세요.

| 파일 | 설명 |
| --- | --- |
| `cluster/kind.yml` | kind 클러스터 구성. 쿠버네티스 리소스가 아니라 kind가 읽는 설정 파일 |
| `apps/podinfo/deployment.yaml` | podinfo `6.17.0` 이미지, 복제본 3개 유지 |
| `apps/podinfo/service.yaml` | 라벨 `app: podinfo` 파드로 트래픽 전달, 포트 `9898` |

## 사전 준비

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## 사용 방법

```bash
# 1. 클러스터 생성
kind create cluster --config cluster/kind.yml

# 2. 앱 배포
kubectl apply -f apps/podinfo/

# 3. 상태 확인
kubectl get deploy,pods,svc

# 4. 로컬에서 접속 확인
kubectl port-forward svc/podinfo 9898:9898
curl http://localhost:9898

# 5. 정리
kubectl delete -f apps/podinfo/
kind delete cluster
```

## 브랜치 규칙

`main`은 항상 동작하는 상태로 유지하고, 변경은 `feat/*` 브랜치에서 작업한 뒤 PR로 머지합니다.
