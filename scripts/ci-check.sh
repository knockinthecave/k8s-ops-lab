#!/usr/bin/env bash
# 매니페스트 검증. 로컬과 CI(.github/workflows/ci.yaml)가 같은 스크립트를 쓴다.
# 필요한 도구: yamllint, kubeconform, trivy
#
# 단계
#   1. yamllint        YAML 문법과 형식              (실패하면 종료)
#   2. kubeconform     쿠버네티스 스키마 검증        (실패하면 종료)
#   3. trivy config    설정 오설정 스캔, CRITICAL만 차단 (HIGH 이하는 보고만)
#   4. trivy image     podinfo 이미지 취약점 스캔    (보고만, SCAN_IMAGE=0이면 생략)
set -euo pipefail
cd "$(dirname "$0")/.."

# kubeconform이 검증할 쿠버네티스 리소스 파일.
# helm values(*-values.yaml)와 kind 설정(cluster/kind.yaml)은 리소스가 아니라서 제외한다.
K8S_TARGETS=(
  apps labs
  monitoring/podinfo-alerts.yaml
  monitoring/podinfo-servicemonitor.yaml
  monitoring/loki-datasource.yaml
  monitoring/dashboards/lab02-failures-configmap.yaml
)
# 클러스터 버전(1.37)의 스키마가 없을 수 있어 확인된 버전으로 검증한다.
K8S_VERSION="${K8S_VERSION:-1.34.0}"
IMAGE="$(grep -m1 'image:' apps/podinfo/deployment.yaml | awk '{print $2}')"

echo "== 1/4 yamllint"
yamllint .

echo "== 2/4 kubeconform (k8s ${K8S_VERSION})"
# ServiceMonitor, PrometheusRule 같은 CRD는 커뮤니티 스키마 카탈로그에서 가져온다.
kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "${K8S_TARGETS[@]}"

echo "== 3/4 trivy config (CRITICAL이면 실패, HIGH 이하는 보고만)"
trivy config --severity HIGH --exit-code 0 apps
trivy config --severity CRITICAL --exit-code 1 apps

if [ "${SCAN_IMAGE:-1}" = "1" ]; then
  echo "== 4/4 trivy image ${IMAGE} (보고만)"
  trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 0 "${IMAGE}"
else
  echo "== 4/4 trivy image 생략 (SCAN_IMAGE=0)"
fi
