#!/bin/bash
set -e

# Start total time tracking
START_TIME=$(date +%s)

# Default values
IMAGE_TAG="vllm-node"
REBUILD_DEPS=false
REBUILD_VLLM=false
COPY_HOST=""
SSH_USER="$USER"
NO_BUILD=false
TRITON_REF="v3.5.1"
VLLM_REF="main"
BUILD_JOBS="16"

# Help function
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -t, --tag <tag>           : Image tag (default: 'vllm-node')"
    echo "  --rebuild-deps            : Set cache bust for dependencies"
    echo "  --rebuild-vllm            : Set cache bust for vllm"
    echo "  --triton-ref <ref>        : Triton commit SHA, branch or tag (default: 'v3.5.1')"
    echo "  --vllm-ref <ref>          : vLLM commit SHA, branch or tag (default: 'main')"
    echo "  -j, --build-jobs <jobs>   : Number of concurrent build jobs (default: \${BUILD_JOBS})"
    echo "  -h, --copy-to-host <host> : Host address to copy the image to (if not set, don't copy)"
    echo "  -u, --user <user>         : Username for ssh command (default: \$USER)"
    echo "  --no-build                : Skip building, only copy image (requires --copy-to-host)"
    echo "  --help                    : Show this help message"
    exit 1
}

# Argument parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--tag) IMAGE_TAG="$2"; shift ;;
        --rebuild-deps) REBUILD_DEPS=true ;;
        --rebuild-vllm) REBUILD_VLLM=true ;;
        --triton-ref) TRITON_REF="$2"; shift ;;
        --vllm-ref) VLLM_REF="$2"; shift ;;
        -j|--build-jobs) BUILD_JOBS="$2"; shift ;;
        -h|--copy-to-host) COPY_HOST="$2"; shift ;;
        -u|--user) SSH_USER="$2"; shift ;;
        --no-build) NO_BUILD=true ;;
        --help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate --no-build usage
if [ "$NO_BUILD" = true ] && [ -z "$COPY_HOST" ]; then
    echo "Error: --no-build requires --copy-to-host to be specified"
    exit 1
fi

# Build image (unless --no-build is set)
BUILD_TIME=0
if [ "$NO_BUILD" = false ]; then
    # Construct build command
    CMD=("docker" "build" "-t" "$IMAGE_TAG")

    if [ "$REBUILD_DEPS" = true ]; then
        echo "Setting CACHEBUST_DEPS..."
        CMD+=("--build-arg" "CACHEBUST_DEPS=$(date +%s)")
    fi

    if [ "$REBUILD_VLLM" = true ]; then
        echo "Setting CACHEBUST_VLLM..."
        CMD+=("--build-arg" "CACHEBUST_VLLM=$(date +%s)")
    fi

    # Add TRITON_REF to build arguments
    CMD+=("--build-arg" "TRITON_REF=$TRITON_REF")

    # Add VLLM_REF to build arguments
    CMD+=("--build-arg" "VLLM_REF=$VLLM_REF")

    # Add BUILD_JOBS to build arguments
    CMD+=("--build-arg" "BUILD_JOBS=$BUILD_JOBS")

    # Add build context
    CMD+=(".")

    # Execute build
    echo "Building image with command: ${CMD[*]}"
    BUILD_START=$(date +%s)
    "${CMD[@]}"
    BUILD_END=$(date +%s)
    BUILD_TIME=$((BUILD_END - BUILD_START))
else
    echo "Skipping build (--no-build specified)"
fi

# Copy to host if requested
COPY_TIME=0
if [ -n "$COPY_HOST" ]; then
    echo "Copying image '$IMAGE_TAG' to ${SSH_USER}@${COPY_HOST}..."
    COPY_START=$(date +%s)
    # Using the pipe method from README.md
    docker save "$IMAGE_TAG" | ssh "${SSH_USER}@${COPY_HOST}" "docker load"
    COPY_END=$(date +%s)
    COPY_TIME=$((COPY_END - COPY_START))
    echo "Copy complete."
else
    echo "No host specified, skipping copy."
fi

# Calculate total time
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Display timing statistics
echo ""
echo "========================================="
echo "         TIMING STATISTICS"
echo "========================================="
if [ "$BUILD_TIME" -gt 0 ]; then
    echo "Docker Build:  $(printf '%02d:%02d:%02d' $((BUILD_TIME/3600)) $((BUILD_TIME%3600/60)) $((BUILD_TIME%60)))"
fi
if [ "$COPY_TIME" -gt 0 ]; then
    echo "Image Copy:    $(printf '%02d:%02d:%02d' $((COPY_TIME/3600)) $((COPY_TIME%3600/60)) $((COPY_TIME%60)))"
fi
echo "Total Time:    $(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))"
echo "========================================="
echo "Done."
