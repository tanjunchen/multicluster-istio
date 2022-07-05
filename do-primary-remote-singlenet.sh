#!/bin/bash
# This script setups two clusters on a single network, that is, the
# two clusters work on same IP space, workload instances can reach
# each other directly without an Istio gateway. One cluster is
# considered primary, the other cluster is considered remote.

ColorOff='\033[0m'        # Text Reset
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green


CLUSTER1_NAME=cluster1
CLUSTER2_NAME=cluster2

if [[ $1 != '' ]]; then
  setupmcs -d
  exit 0
fi

LOADIMAGE=""
HUB="istio"
istioctlversion=$(istioctl version 2>/dev/null|head -1)
if [[ "${istioctlversion}" == *"-dev" ]]; then
  LOADIMAGE="-l"
  HUB="localhost:5000"
  if [[ -z "${TAG}" ]]; then
    TAG=$(docker images "localhost:5000/pilot:*" --format "{{.Tag}}")
  fi
fi
TAG="${TAG:-${istioctlversion}}"

echo ""
echo -e "Hub: ${Green}${HUB}${ColorOff}"
echo -e "Tag: ${Green}${TAG}${ColorOff}"
echo ""

# Use the script to setup a k8s cluster with Metallb installed and setup
cat <<EOF | ./setupmcs.sh ${LOADIMAGE}
[
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER1_NAME}",
    "podSubnet": "10.10.0.0/16",
    "svcSubnet": "10.255.10.0/24",
    "network": "network1",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER1_NAME}"
    }
  },
  {
    "kind": "Kubernetes",
    "clusterName": "${CLUSTER2_NAME}",
    "podSubnet": "10.20.0.0/16",
    "svcSubnet": "10.255.20.0/24",
    "network": "network1",
    "primaryClusterName": "${CLUSTER1_NAME}",
    "configClusterName": "${CLUSTER2_NAME}",
    "meta": {
      "fakeVM": false,
      "kubeconfig": "/tmp/work/${CLUSTER2_NAME}"
    }
  }
]
EOF


# Create the namespace for cluster1
kubectl create --context kind-${CLUSTER1_NAME} namespace istio-system

# Setup the cacerts
./makecerts.sh -c kind-${CLUSTER1_NAME} -s istio-system -n ${CLUSTER1_NAME}

# Create the namespace for cluster2
kubectl create --context kind-${CLUSTER2_NAME} namespace istio-system

# Setup the cacerts
./makecerts.sh -c kind-${CLUSTER2_NAME} -s istio-system -n ${CLUSTER2_NAME}

# Install istio onto the first cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER1_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTER1_NAME}
      network: network1
  components:
    ingressGateways:
    - name: istio-ingressgateway
      label:
        istio: ingressgateway
        app: istio-ingressgateway
        topology.istio.io/network: network1
      enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: "sni-dnat"
        - name: ISTIO_META_REQUESTED_NETWORK_VIEW
          value: network1
        service:
          ports:
          - name: status-port
            port: 15021
            targetPort: 15021
          - name: tls
            port: 15443
            targetPort: 15443
          - name: tls-istiod
            port: 15012
            targetPort: 15012
          - name: tls-webhook
            port: 15017
            targetPort: 15017
EOF

# Expose the control plan
cat << EOF | kubectl apply --context="kind-${CLUSTER1_NAME}" -n istio-system -f -
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istiod-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        name: tls-istiod
        number: 15012
        protocol: tls
      tls:
        mode: PASSTHROUGH        
      hosts:
        - "*"
    - port:
        name: tls-istiodwebhook
        number: 15017
        protocol: tls
      tls:
        mode: PASSTHROUGH          
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: istiod-vs
spec:
  hosts:
  - "*"
  gateways:
  - istiod-gateway
  tls:
  - match:
    - port: 15012
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 15012
  - match:
    - port: 15017
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 443
EOF

# Get the ingress gateway IP address
while : ; do
  DISCOVERY_ADDRESS=$(kubectl --context="kind-${CLUSTER1_NAME}" get svc istio-ingressgateway \
       -n istio-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip }')
  if [[ ! -z ${DISCOVERY_ADDRESS} ]]; then
    break
  fi
  echo -e ${Green}Waiting${ColorOff} for Ingress Gateway to be ready...
  sleep 3
done

istioctl x create-remote-secret --context="kind-${CLUSTER2_NAME}" \
    --name=${CLUSTER2_NAME} | \
    kubectl apply --context="kind-${CLUSTER1_NAME}" -f -

# Install istio onto the second cluster
cat <<EOF | istioctl install --context="kind-${CLUSTER2_NAME}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: ${CLUSTER2_NAME}
      network: network1
      remotePilotAddress: ${DISCOVERY_ADDRESS}
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
EOF
