#!/bin/bash
#
# sweep.sh - BraTS Training Sweep Management
#

# ============================================================================
# CONFIGURATION
# ============================================================================

# Defaults
DEFAULT_NUM_AGENTS=4
SWEEP_FILE="sweep.yml"
NAMESPACE="gai-lina-group"
ENTITY="timgsereda"
# WANDB_PROJECT will be set from 'project:' in SWEEP_FILE
# RESOURCE_PREFIX will be set from 'name:' in SWEEP_FILE
USE_JOBS=false

# PVC Offset Configuration (to exclude 1, 2, 3, 4)
PVC_OFFSET=2

# Parse arguments
NUM_AGENTS=$DEFAULT_NUM_AGENTS

for arg in "$@"; do
    case $arg in
        --job|--jobs)
            USE_JOBS=true
            ;;
        [0-9]*)
            NUM_AGENTS=$arg
            ;;
    esac
done

# Set deployment type
if [ "$USE_JOBS" = true ]; then
    DEPLOYMENT_TYPE="job"
    DEPLOYMENT_TYPE_PLURAL="jobs"
    TEMPLATE_FILE="agent_job_tr.yml"
else
    DEPLOYMENT_TYPE="pod"
    DEPLOYMENT_TYPE_PLURAL="pods"
    TEMPLATE_FILE="agent_pod_tr.yml"
fi

# ============================================================================
# FUNCTIONS
# ============================================================================

check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl is not installed. Exiting."
        exit 1
    fi
    
    if ! command -v wandb &> /dev/null; then
        echo "wandb is not installed. Exiting."
        exit 1
    fi
    
    if [ ! -f "$SWEEP_FILE" ]; then
        echo "$SWEEP_FILE not found! Exiting."
        exit 1
    fi
    
    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo "Template file $TEMPLATE_FILE not found! Exiting."
        exit 1
    fi
}

get_project_and_name() {
    # 1. Extract W&B Project Name (from 'project:')
    WANDB_PROJECT=$(grep '^project:' "$SWEEP_FILE" | head -1 | awk '{print $2}' | tr -d '[:space:]' | tr -d '\"\')
    if [ -z "$WANDB_PROJECT" ]; then
        echo "Could not extract 'project' field from $SWEEP_FILE. Exiting."
        exit 1
    fi

    # 2. Extract Kubernetes Resource Prefix (from 'name:')
    RESOURCE_PREFIX=$(grep '^name:' "$SWEEP_FILE" | head -1 | awk '{print $2}' | tr -d '[:space:]' | tr -d '\"\')
    if [ -z "$RESOURCE_PREFIX" ]; then
        echo "Could not extract 'name' field from $SWEEP_FILE. Exiting."
        exit 1
    fi
}

create_sweep() {
    echo "Creating W&B sweep from $SWEEP_FILE..."
    echo "Using W&B Project Name: $WANDB_PROJECT"
    
    # Use $WANDB_PROJECT for the W&B project name
    SWEEP_OUTPUT=$(wandb sweep "$SWEEP_FILE" --entity "$ENTITY" --project "$WANDB_PROJECT" 2>&1)
    echo "$SWEEP_OUTPUT"
    
    SWEEP_ID=""
    FULL_AGENT_CMD=$(echo "$SWEEP_OUTPUT" | grep -oE 'wandb agent [^/]+/[^/]+/[a-zA-Z0-9]+' | head -1)
    if [ -n "$FULL_AGENT_CMD" ]; then
        SWEEP_ID=$(echo "$FULL_AGENT_CMD" | sed 's/.*\///')
    fi
    
    if [ -z "$SWEEP_ID" ]; then
        SWEEP_ID=$(echo "$SWEEP_OUTPUT" | grep -oE 'https://wandb\.ai/[^/]+/[^/]+/sweeps/([a-zA-Z0-9]+)' | sed 's/.*sweeps\///' | head -1)
    fi
    
    if [ -z "$SWEEP_ID" ]; then
        SWEEP_ID=$(echo "$SWEEP_OUTPUT" | grep -oE '\b[a-zA-Z0-9]{8,}\b' | tail -1)
    fi
    
    if [ -z "$SWEEP_ID" ]; then
        echo "Could not extract sweep ID. Check output for errors. Exiting."
        exit 1
    fi
    
    echo "Sweep created. ID: $SWEEP_ID"
    export SWEEP_ID
}

check_existing_resources() {
    RESOURCE_NAME_PREFIX="sweep-$RESOURCE_PREFIX"

    echo "Checking for existing $DEPLOYMENT_TYPE_PLURAL matching resource name prefix '$RESOURCE_NAME_PREFIX-'..."
    
    # Use the appropriate resource type based on the DEPLOYMENT_TYPE_PLURAL variable
    EXISTING_RESOURCES=$(kubectl get "$DEPLOYMENT_TYPE_PLURAL" -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep "$RESOURCE_NAME_PREFIX-")
    
    if [ -n "$EXISTING_RESOURCES" ]; then
        echo "WARNING: Found existing Kubernetes $DEPLOYMENT_TYPE_PLURAL with prefix '$RESOURCE_NAME_PREFIX-':"
        echo "$EXISTING_RESOURCES"
        echo "These resources will continue to run unless manually deleted. New resources will also be deployed."
        # You might want to add a prompt here to stop or continue.
    fi
} # <-- ADDED CLOSING BRACE

deploy_agents() {
    echo "Deploying $NUM_AGENTS training agent(s) as $DEPLOYMENT_TYPE_PLURAL..."
    
    OUTPUT_DIR="${DEPLOYMENT_TYPE_PLURAL}"
    mkdir -p "$OUTPUT_DIR"

    # Use $RESOURCE_PREFIX (value of 'name:') for the K8s name prefix
    K8S_NAME_PREFIX="sweep-$RESOURCE_PREFIX"

    for i in $(seq 1 "$NUM_AGENTS"); do
        # Calculate the PVC index by applying the offset (starts at 5)
        CURRENT_PVC_NUM=$((i + PVC_OFFSET))

        # Final naming scheme: sweep-name-number 
        CURRENT_RESOURCE_NAME="$K8S_NAME_PREFIX-$CURRENT_PVC_NUM"

        echo "[$i/$NUM_AGENTS] Deploying $CURRENT_RESOURCE_NAME (PVC index $CURRENT_PVC_NUM)..."
        
        CONFIG_FILE="$OUTPUT_DIR/$CURRENT_RESOURCE_NAME.yml"
        
        # Substitute the K8s name, sweep ID, PVC index, and W&B project name
        sed -e "s/{RESOURCE_NAME}/$CURRENT_RESOURCE_NAME/g" \
            -e "s/{SWEEP_ID}/$SWEEP_ID/g" \
            -e "s/{PVC_NUM}/$CURRENT_PVC_NUM/g" \
            -e "s/{WANDB_PROJECT}/$WANDB_PROJECT/g" \
            "$TEMPLATE_FILE" > "$CONFIG_FILE"
        
        kubectl apply -f "$CONFIG_FILE"
        
        if [ $? -eq 0 ]; then
            echo "   Successfully deployed."
        else
            echo "   Deployment failed."
        fi
    done
    
    echo "Generated YAML files saved to: $OUTPUT_DIR/"
}

show_monitoring_commands() {
    echo ""
    echo "============================================================"
    echo "Deployment Complete."
    echo "============================================================"
    echo "W&B Project: $WANDB_PROJECT"
    echo "Sweep URL: https://wandb.ai/$ENTITY/$WANDB_PROJECT/sweeps/$SWEEP_ID" 
    echo ""
    kubectl get pods
    sleep 30
    kubectl logs "$CURRENT_RESOURCE_NAME" -f
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo "BraTS Training Sweep Management"
    
    check_prerequisites
    get_project_and_name
    
    echo "W&B Project Name: '$WANDB_PROJECT'"
    echo "K8s Resource Name Prefix: 'sweep-$RESOURCE_PREFIX'"
    echo "Deploying $NUM_AGENTS agents as $DEPLOYMENT_TYPE_PLURAL."
    echo "PVC index starts at: $((1 + PVC_OFFSET)) (Skipping 1, 2, 3, 4)."
    
    create_sweep
    
    echo ""
    echo "NOTE: Resource names are now 'sweep-\$RESOURCE_PREFIX-\$PVC_NUM'."
    echo "The template must use {RESOURCE_NAME}, {SWEEP_ID}, {PVC_NUM}, and {WANDB_PROJECT} placeholders."
    echo ""

    check_existing_resources
    deploy_agents
    show_monitoring_commands
}

main