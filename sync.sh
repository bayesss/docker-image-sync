#!/bin/bash
set -euo pipefail

# 本地调试时可把 secrets 写入 .env（勿提交）；GitHub Actions 由 workflow env 注入。
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

IMAGES_FILE="images.txt"
DIGEST_PARALLELISM="${DIGEST_PARALLELISM:-14}"
SYNC_PARALLELISM="${SYNC_PARALLELISM:-3}"

if [ ! -f "$IMAGES_FILE" ]; then
    echo "Error: images.txt not found! Please create it with a list of images to sync."
    exit 1
fi

if [ -z "${ACR_REGISTRY:-}" ] || [ -z "${ACR_NAMESPACE:-}" ]; then
    echo "Error: ACR_REGISTRY or ACR_NAMESPACE not set. Please check your config."
    exit 1
fi

if ! command -v crane >/dev/null 2>&1; then
    echo "Error: crane not found. Install crane before running this script."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found. Install jq before running this script."
    exit 1
fi

DIGEST_DIR=$(mktemp -d)
trap 'rm -rf "$DIGEST_DIR"' EXIT

# 获取用于跨 Registry 比对的镜像指纹。
# docker pull + push 会重写 manifest，manifest digest 在上下游必然不同；
# 单架构镜像用 config digest 比对（与 docker push 后 ACR 中内容一致）。
get_image_fingerprint() {
    local image="$1"
    local manifest=""

    if [ -n "${DOCKER_PLATFORM:-}" ]; then
        manifest=$(crane manifest --platform "${DOCKER_PLATFORM}" "$image" 2>/dev/null) || true
    fi
    if [ -z "$manifest" ]; then
        manifest=$(crane manifest "$image" 2>/dev/null) || return 1
    fi

    if echo "$manifest" | jq -e '.manifests | length > 0' >/dev/null 2>&1; then
        echo "$manifest" | jq -r '.manifests[].digest' | sort | sha256sum | cut -d' ' -f1
    else
        local config_digest
        config_digest=$(echo "$manifest" | jq -r '.config.digest // empty')
        [ -n "$config_digest" ] || return 1
        echo "$config_digest"
    fi
}

# 根据上游镜像名构造 ACR 目标路径。
build_target_image_path() {
    local image="$1"
    local registry="$2"
    local namespace="$3"

    local original_tag="${image%%@*}"
    original_tag="${original_tag##*:}"
    local full_repo_path="${image%%@*}"
    full_repo_path="${full_repo_path%:*}"
    local original_repo="${full_repo_path##*/}"
    local acr_compatible_repo_name="${original_repo//\//-}"

    echo "${registry}/${namespace}/${acr_compatible_repo_name}:${original_tag}"
}

digest_key() {
    printf '%s' "$1" | sha256sum | cut -c1-16
}

acr_digest_key() {
    printf '%s|%s' "$1" "$2" | sha256sum | cut -c1-16
}

# 收集所有 ACR 目标（支持第二个 ACR），以换行分隔供子进程读取。
build_target_specs_str() {
    TARGET_SPECS_STR="${ACR_REGISTRY}|${ACR_NAMESPACE}"
    if [ -n "${ACR_REGISTRY2:-}" ] && [ -n "${ACR_NAMESPACE2:-}" ]; then
        TARGET_SPECS_STR+=$'\n'"${ACR_REGISTRY2}|${ACR_NAMESPACE2}"
    fi
}

read_target_specs() {
    TARGET_SPECS=()
    while IFS= read -r spec; do
        [ -n "$spec" ] && TARGET_SPECS+=("$spec")
    done <<< "$TARGET_SPECS_STR"
}

# 阶段 1：并行查询上游 digest。
digest_upstream_one() {
    local image="$1"
    local key outfile
    key=$(digest_key "$image")
    outfile="${DIGEST_DIR}/upstream_${key}"
    if digest=$(get_image_fingerprint "$image"); then
        printf '%s' "$digest" > "$outfile"
    else
        : > "${outfile}.failed"
    fi
}

# 阶段 2：并行查询 ACR digest。输入格式：image<TAB>target_path
digest_acr_one() {
    local image target_path key outfile
    image="${1%%$'\t'*}"
    target_path="${1#*$'\t'}"
    key=$(acr_digest_key "$image" "$target_path")
    outfile="${DIGEST_DIR}/acr_${key}"
    if digest=$(get_image_fingerprint "$target_path"); then
        printf '%s' "$digest" > "$outfile"
    else
        : > "${outfile}.missing"
    fi
}

read_upstream_digest() {
    local image="$1"
    local key="${DIGEST_DIR}/upstream_$(digest_key "$image")"
    if [ -f "${key}.failed" ]; then
        return 1
    fi
    if [ -f "$key" ]; then
        cat "$key"
        return 0
    fi
    return 1
}

read_acr_digest() {
    local image="$1"
    local target_path="$2"
    local key="${DIGEST_DIR}/acr_$(acr_digest_key "$image" "$target_path")"
    if [ -f "${key}.missing" ]; then
        return 1
    fi
    if [ -f "$key" ]; then
        cat "$key"
        return 0
    fi
    return 1
}

# 阶段 3：仅对需要同步的镜像执行 pull + push。job 格式：image|||target1,target2
sync_one_image_from_job() {
    local job="$1"
    local image="${job%%|||*}"
    local targets_csv="${job#*|||}"
    sync_one_image "$image" "$targets_csv"
}

sync_one_image() {
    local image="$1"
    local targets_csv="$2"
    local -a targets_to_sync=()
    IFS=',' read -r -a targets_to_sync <<< "$targets_csv"

    echo "--- Syncing image: ${image} ---"
    local transfer_start transfer_elapsed
    transfer_start=$(date +%s)

    echo "Pulling original image: ${image}..."
    if [ -n "${DOCKER_PLATFORM:-}" ]; then
        docker pull --platform "${DOCKER_PLATFORM}" "${image}"
    else
        docker pull "${image}"
    fi

    local target
    for target in "${targets_to_sync[@]}"; do
        echo "Tagging ${image} -> ${target}..."
        docker tag "${image}" "${target}"
    done

    echo "Pushing to ${#targets_to_sync[@]} target(s)..."
    local push_pids=()
    for target in "${targets_to_sync[@]}"; do
        docker push "${target}" &
        push_pids+=("$!")
    done

    local pid failed=0
    for pid in "${push_pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done
    if [ "$failed" -ne 0 ]; then
        echo "Error: push failed for ${image}"
        return 1
    fi

    echo "Cleaning up local images..."
    docker rmi "${image}" || true
    for target in "${targets_to_sync[@]}"; do
        docker rmi "${target}" || true
    done

    transfer_elapsed=$(($(date +%s) - transfer_start))
    echo "[timing] ${image} pull+push: ${transfer_elapsed}s"
    echo "Successfully synced: ${image}"
    echo "-----------------------------------"
}

build_target_specs_str
read_target_specs

echo "Starting Docker image synchronization to ACR..."
echo "Digest parallelism: ${DIGEST_PARALLELISM}"
echo "Sync parallelism: ${SYNC_PARALLELISM}"
while IFS= read -r spec; do
    [ -n "$spec" ] && echo "Target: ${spec%%|*}/${spec#*|}"
done <<< "$TARGET_SPECS_STR"
echo "-----------------------------------"

mapfile -t IMAGES < <(grep -v '^[[:space:]]*#' "$IMAGES_FILE" | grep -v '^[[:space:]]*$' || true)

if [ "${#IMAGES[@]}" -eq 0 ]; then
    echo "No images to sync."
    exit 0
fi

export DIGEST_DIR
export DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
export -f get_image_fingerprint digest_upstream_one digest_acr_one digest_key acr_digest_key

# 阶段 1：并行 crane digest 所有上游镜像。
phase1_start=$(date +%s)
printf '%s\n' "${IMAGES[@]}" | xargs -r -P "$DIGEST_PARALLELISM" -I {} bash -c 'digest_upstream_one "$@"' _ {}
phase1_elapsed=$(($(date +%s) - phase1_start))
echo "[timing] phase 1 upstream fingerprint (${#IMAGES[@]} images, -P ${DIGEST_PARALLELISM}): ${phase1_elapsed}s"

# 阶段 2：并行 crane digest 所有 ACR 镜像。
mapfile -t ACR_DIGEST_JOBS < <(
    for image in "${IMAGES[@]}"; do
        for spec in "${TARGET_SPECS[@]}"; do
            registry="${spec%%|*}"
            namespace="${spec#*|}"
            target_path=$(build_target_image_path "$image" "$registry" "$namespace")
            printf '%s\t%s\n' "$image" "$target_path"
        done
    done
)
phase2_start=$(date +%s)
printf '%s\n' "${ACR_DIGEST_JOBS[@]}" | xargs -r -P "$DIGEST_PARALLELISM" -I {} bash -c 'digest_acr_one "$@"' _ {}
phase2_elapsed=$(($(date +%s) - phase2_start))
echo "[timing] phase 2 ACR fingerprint (${#ACR_DIGEST_JOBS[@]} checks, -P ${DIGEST_PARALLELISM}): ${phase2_elapsed}s"

# 比对 digest，确定需要同步的镜像。
declare -a IMAGES_TO_SYNC=()
declare -a TARGETS_CSV_FOR_SYNC=()

for image in "${IMAGES[@]}"; do
    echo "--- Checking image: ${image} ---"

    upstream_digest=""
    upstream_digest=$(read_upstream_digest "$image") || true

    local_targets=()
    for spec in "${TARGET_SPECS[@]}"; do
        registry="${spec%%|*}"
        namespace="${spec#*|}"
        target_path=$(build_target_image_path "$image" "$registry" "$namespace")

        if [ -z "$upstream_digest" ]; then
            echo "Warning: 无法获取上游镜像 ${image} 的 digest，将尝试同步到 ${target_path}..."
            local_targets+=("$target_path")
            continue
        fi

        target_digest=""
        target_digest=$(read_acr_digest "$image" "$target_path") || true
        if [ -n "$target_digest" ] && [ "$target_digest" = "$upstream_digest" ]; then
            echo "${target_path} 已是最新 (fingerprint: ${upstream_digest})，跳过。"
        elif [ -z "$target_digest" ]; then
            echo "${target_path} 不存在，需要同步。"
            local_targets+=("$target_path")
        else
            echo "${target_path} 指纹不同 (ACR: ${target_digest}, upstream: ${upstream_digest})，需要同步。"
            local_targets+=("$target_path")
        fi
    done

    if [ "${#local_targets[@]}" -eq 0 ]; then
        echo "-----------------------------------"
        continue
    fi

    IFS=',' 
    targets_csv="${local_targets[*]}"
    IFS=$' \t\n'
    IMAGES_TO_SYNC+=("$image")
    TARGETS_CSV_FOR_SYNC+=("$targets_csv")
    echo "-----------------------------------"
done

if [ "${#IMAGES_TO_SYNC[@]}" -eq 0 ]; then
    echo "All images are up to date. No pull/push needed."
    exit 0
fi

echo "Images requiring sync: ${#IMAGES_TO_SYNC[@]} / ${#IMAGES[@]}"

export -f sync_one_image sync_one_image_from_job

# 阶段 3：仅对 digest 不一致的镜像并行 pull + push。
phase3_start=$(date +%s)
for i in "${!IMAGES_TO_SYNC[@]}"; do
    printf '%s|||%s\n' "${IMAGES_TO_SYNC[$i]}" "${TARGETS_CSV_FOR_SYNC[$i]}"
done | xargs -r -P "$SYNC_PARALLELISM" -I {} bash -c 'sync_one_image_from_job "$@"' _ {}

phase3_elapsed=$(($(date +%s) - phase3_start))
echo "[timing] phase 3 pull+push (${#IMAGES_TO_SYNC[@]} images, -P ${SYNC_PARALLELISM}): ${phase3_elapsed}s"

echo "All specified images processed successfully."
echo "Synchronization process finished."
