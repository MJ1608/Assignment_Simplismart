#!/bin/bash

set -e

NAMESPACE="simplismart"

# Parse global flags
while [[ "$1" =~ ^- ]]; do
    case $1 in
        -n|--namespace)
            shift
            NAMESPACE="$1"
            shift
            ;;
        -h|--help)
            SHOW_HELP=1
            shift
            ;;
        *)
            echo "Unknown flag: $1"
            exit 1
            ;;
    esac
done

function print_header() {
    echo -e "\n============================"
    echo "$1"
    echo "============================"
}

function install_helm() {
    print_header "Installing Helm (if not present)"
    if ! command -v helm &>/dev/null; then
        curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
    else
        echo "Helm already installed"
    fi
}

function install_keda() {
    print_header "Installing KEDA using Helm"

    # Check if Helm release 'keda' exists in 'keda' namespace
    if helm status keda -n keda &>/dev/null; then
        echo "KEDA is already installed in the 'keda' namespace."
        echo "Skipping installation."
        return 0
    fi

    # Ensure namespace exists
    if ! kubectl get namespace keda &>/dev/null; then
        echo "Creating 'keda' namespace..."
        kubectl create namespace keda
    else
        echo "Namespace 'keda' already exists."
    fi

    # Add Helm repo if it doesn't already exist
    if ! helm repo list | grep -q "kedacore"; then
        echo "Adding KEDA Helm repository..."
        helm repo add kedacore https://kedacore.github.io/charts
    else
        echo "KEDA Helm repository already added."
    fi

    echo "Updating Helm repositories..."
    helm repo update

    # Install KEDA with helm
    echo "Installing KEDA..."
    helm install keda kedacore/keda --namespace keda --create-namespace

    # Wait for operator to be ready
    echo "Waiting for KEDA operator to become ready..."
        sleep 10
    kubectl rollout status deployment/keda-operator -n keda

    echo "KEDA installation completed."
}


function connect_cluster() {
    print_header "Verifying Kubernetes cluster connectivity"
    if ! kubectl cluster-info; then
        echo " Cannot connect to Kubernetes cluster"
        exit 1
    fi
    echo "Connected to Kubernetes cluster"
}

function create_application() {
    DEPLOY_PATH="module"

    print_header "Creating resources in namespace $NAMESPACE"
    
    # Create namespace if not already created
    if ! kubectl create namespace "$NAMESPACE" 2>/dev/null; then
        echo "Namespace '$NAMESPACE' already exists."
    else
        echo "Namespace '$NAMESPACE' created successfully."
    fi

    # Apply deployment, service, and HPA YAML files
    if ! kubectl apply -n "$NAMESPACE" -f "$DEPLOY_PATH/deployment.yaml"; then
        echo "Failed to apply deployment in namespace $NAMESPACE. Exiting..."
        exit 1
    fi

    if ! kubectl apply -n "$NAMESPACE" -f "$DEPLOY_PATH/service.yaml"; then
        echo "Failed to apply service in namespace $NAMESPACE. Exiting..."
        exit 1
    fi

    if ! kubectl apply -n "$NAMESPACE" -f "$DEPLOY_PATH/scaledObject.yaml"; then
        echo "Failed to apply scaled object in namespace $NAMESPACE. Exiting..."
        exit 1
    fi

}


function get_application_details() {
    
    
    echo -e "\nResources created in Namespace '$NAMESPACE' with below details :"
    
    echo -e "\nDeployment:"
    local DEPLOYMENT_NAME=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    if [ -n "$DEPLOYMENT_NAME" ]; then
        local REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath="{.status.replicas}")
        local AVAILABLE=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath="{.status.availableReplicas}")
        echo "  Name:         $DEPLOYMENT_NAME"
        echo "  Replicas:     $REPLICAS"
        echo "  Available:    $AVAILABLE"
    else
        echo "  No deployments found."
    fi

    echo -e "\nService:"
    local SERVICE_NAME=$(kubectl get svc -n "$NAMESPACE" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    if [ -n "$SERVICE_NAME" ]; then
        local TYPE=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.type}")
        local CLUSTER_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.clusterIP}")
        local NODE_PORT=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.ports[0].nodePort}")
        echo "  Name:         $SERVICE_NAME"
        echo "  Type:         $TYPE"
        echo "  Cluster IP:   $CLUSTER_IP"
        echo "  Node Port:    $NODE_PORT"
    else
        echo "  No services found."
    fi

    echo -e "\nScaledObject :"
    local SCALEDOBJECT_NAME=$(kubectl get scaledobject -n "$NAMESPACE" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
    if [ -n "$SCALEDOBJECT_NAME" ]; then
        local TARGET_NAME=$(kubectl get scaledobject "$SCALEDOBJECT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.scaleTargetRef.name}")
        local MINPODS=$(kubectl get scaledobject "$SCALEDOBJECT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.minReplicaCount}")
        local MAXPODS=$(kubectl get scaledobject "$SCALEDOBJECT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.maxReplicaCount}")
        local TRIGGERS=$(kubectl get scaledobject "$SCALEDOBJECT_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.triggers[*].type}" | tr ' ' ',')
    
        echo "  ScaledObject Name: $SCALEDOBJECT_NAME"
        echo "  Target Kind:       $TARGET_KIND"
        echo "  Target Name:       $TARGET_NAME"
        echo "  Min Pods:          $MINPODS"
        echo "  Max Pods:          $MAXPODS"
        echo "  Triggers:          $TRIGGERS"
    else
        echo "  No ScaledObject found."
    fi

    

}


function get_health_status() {
    local DEPLOY_NAME=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")

    print_header "Deployment Status"
    kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" || { echo "Deployment not found"; return 1; }

    print_header "Pod Status"
    kubectl get pods -l app="$DEPLOY_NAME" -n "$NAMESPACE"


    print_header "Resource Usage (CPU/Memory)"
    kubectl top pods -l app="$DEPLOY_NAME" -n "$NAMESPACE" || echo "⚠️  Metrics server might not be installed or is not working."

    print_header "Recent Events in Namespace"
    kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 20
}

function print_usage() {
    echo -e "Script Usage :"

    echo -e "1. To check connectivity towards Kubernetes, please execute the script with the connect argument as shown below:"
    echo -e "./k8s-keda-manager.sh connect\n"

    echo -e "2. To create deployment, services, and HPA, please execute the script with below two arguments :"
    echo -e "./k8s-keda-manager.sh <-n namespace> apply\n"

    echo -e "3. To check the health status and metrics of the application, please execute the script with two arguments :"
    echo -e "./k8s-keda-manager.sh <-n namespace> status"
}



# Dispatcher
case "$1" in
    connect)
        connect_cluster
        install_helm
        install_keda
        ;;
    apply)
        create_application 
		get_application_details 
        ;;
    status)
        get_health_status
        ;;
    *)
        print_usage
        ;;
esac
