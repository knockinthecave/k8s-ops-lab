# Helm 명령어 정리

이 저장소에서 쓰는 Helm(v4)의 개념과 자주 쓰는 명령어를 정리한 문서입니다.

## 1. 개념

Helm은 쿠버네티스용 패키지 매니저입니다. 여러 YAML을 하나의 패키지(chart)로 묶어 설치·업그레이드·롤백합니다.

| 용어 | 의미 |
| --- | --- |
| Chart | 템플릿(YAML 틀)과 기본값을 묶은 패키지 |
| Values | 템플릿의 빈칸에 채워 넣는 설정값 |
| Release | 클러스터에 설치된 chart의 인스턴스. 이름을 붙여 구분함 |
| Repo | chart를 모아 둔 저장소 |

### 동작 순서

```
chart 템플릿 + chart 기본 values.yaml
        ↓  -f 로 준 values 파일이 기본값을 덮어씀
   최종 values
        ↓  템플릿의 {{ .Values.xxx }} 를 채워 렌더링
   완성된 매니페스트 → 클러스터에 적용 → release 기록 저장
```

- 이 저장소의 `monitoring/*-values.yaml`은 chart의 `values.yaml`을 복사한 것이 아니라, **기본값에서 바꾸고 싶은 키만 적은 override 파일**입니다. 적지 않은 키는 chart 기본값을 씁니다.
- values의 키 이름은 chart가 정한 것입니다. 오타를 내도 에러 없이 무시되거나(키 이름 오타), 의도와 다른 값이 들어갑니다(값 오타). 적용 전에 `helm template`으로 확인합니다.
- kube-prometheus-stack의 `grafana`, `prometheus-node-exporter`, `kube-state-metrics`는 서브차트이고, values에서 서브차트 이름이 최상위 키가 됩니다.

### release 이름 규칙

release 이름은 리소스 이름 앞에 붙습니다 (`kps` → `kps-grafana`). 같은 chart를 이름만 바꿔 같은 네임스페이스에 또 설치하면 두 세트가 공존하고, node-exporter처럼 노드 포트(hostPort)를 쓰는 리소스는 충돌합니다. 설치 전에 `helm list -A`로 이미 있는지 확인합니다.

## 2. 저장소(repo)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts  # 저장소 등록 (클러스터에는 영향 없음)
helm repo list                                  # 등록된 저장소
helm repo update                                # 저장소의 chart 목록 갱신
helm repo remove prometheus-community           # 등록 해제
```

## 3. chart 조회

```bash
helm search repo prometheus-community                          # 저장소의 chart 검색
helm search repo kube-prometheus-stack --versions | head       # 설치 가능한 버전 목록
helm show chart  prometheus-community/kube-prometheus-stack --version 93.3.0   # chart 메타정보
helm show values prometheus-community/kube-prometheus-stack --version 93.3.0   # 기본 values 전체
helm show readme prometheus-community/kube-prometheus-stack --version 93.3.0   # README
```

`helm show values`로 키 이름과 기본값을 찾고, 바꿀 것만 우리 values 파일에 옮겨 적습니다.

## 4. 설치 전 검증

```bash
# 클러스터에 적용하지 않고, 렌더링된 매니페스트만 출력
helm template kps prometheus-community/kube-prometheus-stack \
  --version 93.3.0 -f monitoring/kube-prometheus-stack-values.yaml | less

# values가 반영됐는지 특정 값만 확인 (키가 여러 곳에 있으면 전부 출력해서 확인)
helm template kps prometheus-community/kube-prometheus-stack \
  --version 93.3.0 -f monitoring/kube-prometheus-stack-values.yaml | grep -n retention

# 서버에 보내 보되 적용은 하지 않음 (CRD 검증 등)
helm install kps prometheus-community/kube-prometheus-stack \
  --version 93.3.0 -n monitoring -f monitoring/kube-prometheus-stack-values.yaml --dry-run=server
```

`helm template`의 출력에서 `grep -m1`은 첫 매칭만 보여 줍니다. `retention`은 Alertmanager(`120h`)와 Prometheus(`6h`) 양쪽에 있으므로 `-n`으로 전부 봐야 합니다.

## 5. 설치, 업그레이드, 삭제

```bash
# 설치
helm install <release> <repo>/<chart> --version <버전> -n <ns> --create-namespace -f <values 파일>

# 설치가 없으면 설치, 있으면 업그레이드 (스크립트에서 편함)
helm upgrade --install <release> <repo>/<chart> --version <버전> -n <ns> -f <values 파일>

# values를 고친 뒤 반영 (바뀐 부분만 적용, REVISION 증가)
helm upgrade <release> <repo>/<chart> --version <버전> -n <ns> -f <values 파일>

# 삭제 (CRD는 남음)
helm uninstall <release> -n <ns>
```

- `upgrade` 때는 처음 설치할 때와 **같은 `-f` 파일을 다시 지정**해야 합니다. 빼면 해당 값이 기본값으로 돌아갑니다 (`--reuse-values`를 쓰면 기존 값을 유지하지만, chart 기본값 변경분이 반영되지 않으므로 권장하지 않습니다).
- 값 한두 개만 임시로 덮어쓸 때는 `--set key=value`를 씁니다. 재현성을 위해 실습에서는 파일로 관리합니다.
- `--wait`를 붙이면 파드가 Ready가 될 때까지 기다립니다 (`--timeout 10m`과 함께).

## 6. 상태 확인과 롤백

```bash
helm list -A                          # 모든 네임스페이스의 release
helm list -n monitoring               # 특정 네임스페이스
helm status <release> -n <ns>         # release 상태와 설치 후 안내(NOTES)
helm history <release> -n <ns>        # 리비전 이력
helm rollback <release> <리비전> -n <ns>   # 해당 리비전으로 되돌리기
```

### 적용된 값 확인

```bash
helm get values   <release> -n <ns>          # 내가 덮어쓴 값만
helm get values   <release> -n <ns> --all    # 기본값까지 합친 최종값
helm get manifest <release> -n <ns>          # 실제로 적용된 매니페스트
helm get notes    <release> -n <ns>          # 설치 후 안내문
```

## 7. CRD 주의

kube-prometheus-stack은 CRD(`ServiceMonitor`, `PrometheusRule` 등)를 설치합니다. Helm은 CRD를 `uninstall`할 때 지우지 않고, `upgrade`할 때도 갱신하지 않습니다. chart 메이저 버전을 올릴 때는 해당 chart의 업그레이드 안내를 확인합니다.

```bash
kubectl get crd | grep monitoring.coreos.com     # 남아 있는 CRD 확인
```

완전히 지우려면 release를 uninstall한 뒤 CRD를 직접 삭제합니다. CRD를 지우면 그 종류의 리소스가 모두 사라지므로, 다른 release가 쓰고 있지 않은지 먼저 확인합니다.

## 8. 자주 만나는 문제

| 증상 | 확인 | 원인과 조치 |
| --- | --- | --- |
| 파드가 `Pending`, 이벤트에 `didn't have free ports` | `kubectl describe pod` | 같은 chart의 다른 release가 노드 포트(node-exporter 9100)를 쓰는 중. `helm list -A`로 중복 release를 찾아 하나를 제거 |
| `helm template`에서 값이 안 바뀜 | 키 경로와 들여쓰기 | 키 이름이 chart의 `helm show values`와 다름. 오타는 에러 없이 무시됨 |
| 설정이 의도와 다르게 보임 | `helm get values <release>` | 설치된 값에 오타가 있으면 파일을 고치고 `helm upgrade`. 복사한 출력이 아니라 클러스터에서 다시 조회해서 확인 |
| 파드가 `OOMKilled`로 재시작 | `kubectl describe pod`의 `Last State` | `resources.limits.memory`를 올리고 `helm upgrade` |
| `upgrade` 후 설정이 기본값으로 돌아감 | `helm get values --all` | `-f`를 빼먹음. 항상 같은 values 파일을 지정 |
| uninstall했는데 리소스가 남음 | `kubectl get crd` | CRD는 남는 것이 정상. 필요하면 직접 삭제 |

## 9. 이 저장소에서 쓰는 release

| release | chart | 네임스페이스 | values 파일 |
| --- | --- | --- | --- |
| `metrics-server` | `metrics-server/metrics-server` 3.14.0 | `kube-system` | `monitoring/metrics-server-values.yaml` |
| `kps` | `prometheus-community/kube-prometheus-stack` 93.3.0 | `monitoring` | `monitoring/kube-prometheus-stack-values.yaml` |

설치 절차는 [03. 메트릭 수집과 대시보드](labs/03-monitoring.md)를 참고합니다.
