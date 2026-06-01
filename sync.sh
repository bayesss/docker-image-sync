#!/bin/bash
set -eux # -u: 遇到未定义变量报错；-e: 任何命令失败立即退出；-x: 打印执行的命令

IMAGES_FILE="images.txt"

# 检查配置文件和镜像列表文件是否存在
if [ ! -f "$IMAGES_FILE" ]; then
    echo "Error: images.txt not found! Please create it with a list of images to sync."
    exit 1
fi


# 检查必要的配置变量是否已设置
if [ -z "$ACR_REGISTRY" ] || [ -z "$ACR_NAMESPACE" ]; then
    echo "Error: ACR_REGISTRY or ACR_NAMESPACE not set in github variables. Please check your config."
    exit 1
fi

# 获取远程镜像的指纹，用于跨 Registry 比较镜像是否相同。
# 多架构镜像：对所有平台 manifest digest 排序后求哈希。
# 单架构镜像：使用 config digest。
get_image_fingerprint() {
    local image="$1"
    local manifest
    manifest=$(docker manifest inspect "$image" 2>/dev/null) || return 1

    if echo "$manifest" | jq -e '.manifests | length > 0' >/dev/null 2>&1; then
        echo "$manifest" | jq -r '.manifests[] | .digest' | sort | sha256sum | cut -d' ' -f1
    else
        echo "$manifest" | jq -r '.config.digest'
    fi
}

echo "Starting Docker image synchronization to ACR..."
echo "Target Registry: ${ACR_REGISTRY}"
echo "Target Namespace: ${ACR_NAMESPACE}"
echo "-----------------------------------"

# 遍历 images.txt，逐行处理镜像
while IFS= read -r image; do
    # 跳过空行或以 # 开头的注释行
    if [[ -z "$image" || "$image" =~ ^# ]]; then
        continue
    fi

    echo "--- Processing image: ${image} ---"

    # 分离原始镜像的仓库名和标签
    # 例如：nginx:latest -> original_repo=nginx, original_tag=latest
    # 例如：jenkins/jenkins:lts -> original_repo=jenkins/jenkins, original_tag=lts
    # original_repo=$(echo "$image" | cut -d ':' -f1)
    # original_tag=$(echo "$image" | cut -d ':' -f2)
    
    original_tag="${image##*:}"
    full_repo_path="${image%:*}"
    original_repo="${full_repo_path##*/}"

    acr_compatible_repo_name="${original_repo//\//-}"

    # 构造目标 ACR 完整镜像路径
    target_full_image_path="${ACR_REGISTRY}/${ACR_NAMESPACE}/${acr_compatible_repo_name}:${original_tag}"

    echo "Original image full path: ${image}"
    echo "Target ACR image full path: ${target_full_image_path}"

    # 比较上游镜像与 ACR 镜像的指纹，判断是否需要同步。
    upstream_fp=$(get_image_fingerprint "${image}") || true
    acr_fp=$(get_image_fingerprint "${target_full_image_path}") || true

    if [ -n "$upstream_fp" ] && [ "$upstream_fp" = "$acr_fp" ]; then
        echo "${target_full_image_path} 已是最新，跳过本次同步。"
        echo "-----------------------------------"
        continue
    fi

    if [ -z "$upstream_fp" ]; then
        echo "Warning: 无法获取上游镜像 ${image} 的指纹，尝试同步..."
    elif [ -z "$acr_fp" ]; then
        echo "Image ${target_full_image_path} not found in ACR. Proceeding with sync..."
    else
        echo "Image ${target_full_image_path} 存在但版本不同，重新同步..."
    fi

    # 拉取原始镜像
    echo "Pulling original image: ${image}..."
    docker pull "${image}"

    # 打上阿里云 ACR 的标签
    echo "Tagging image ${image} to ${target_full_image_path}..."
    docker tag "${image}" "${target_full_image_path}"

    # 推送到阿里云 ACR
    echo "Pushing image ${target_full_image_path} to ACR..."
    docker push "${target_full_image_path}"

    # 清理本地拉取和打标签的镜像，释放 GitHub Actions Runner 的磁盘空间
    echo "Cleaning up local images..."
    # 使用 || true 即使删除失败也不会中断脚本，确保后续镜像能继续处理
    docker rmi "${image}" || true
    docker rmi "${target_full_image_path}" || true

    echo "Successfully synced: ${image} to ${target_full_image_path}"
    echo "-----------------------------------"

done < "$IMAGES_FILE"

echo "All specified images processed successfully."
echo "Synchronization process finished."
