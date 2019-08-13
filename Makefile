GIMBAL_CLUSTER_NAME=gimbal
CLUSTER01_CLUSTER_NAME=blue
CLUSTER02_CLUSTER_NAME=green

GIMBAL_POD_NETWORK='10.241.0.0/16'
CLUSTER01_POD_NETWORK='10.242.0.0/16'
CLUSTER02_POD_NETWORK='10.243.0.0/16'

CONTOUR_IMAGE=gcr.io/heptio-images/contour:v0.14.1
ENVOY_IMAGE=docker.io/envoyproxy/envoy:v1.11.0

deps:
	go get github.com/cbednarski/hostess/cmd/hostess

build: deps build_clusters load_images deploy_contour deploy_apps configure_hosts

build_clusters:
	kind create cluster --name=$(GIMBAL_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-gimbal.yaml & \
	kind create cluster --name=$(CLUSTER01_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-cluster01.yaml & \
	kind create cluster --name=$(CLUSTER02_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-cluster02.yaml & \
	wait;

load_images:
	kind load docker-image $(CONTOUR_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	kind load docker-image $(CONTOUR_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	kind load docker-image $(CONTOUR_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)
	kind load docker-image $(ENVOY_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	kind load docker-image $(ENVOY_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	kind load docker-image $(ENVOY_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)

deploy_contour:
	export KUBECONFIG=$(kind get kubeconfig-path --name=$(GIMBAL_CLUSTER_NAME)
	kubectl apply -f contour

	# Update kubeconfig files
	kubectl config set-cluster $(CLUSTER01_CLUSTER_NAME) --server=https://$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER01_CLUSTER_NAME)-control-plane):6443 --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')
	kubectl config set-cluster $(CLUSTER02_CLUSTER_NAME) --server=https://$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER02_CLUSTER_NAME)-control-plane):6443 --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')

	# Deploy discoverers
	kubectl apply -f ./gimbal/01-common.yaml
	kubectl apply -f ./gimbal/02-kubernetes-discoverer-blue.yaml
	kubectl apply -f ./gimbal/02-kubernetes-discoverer-green.yaml
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER01_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER01_CLUSTER_NAME) 
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER02_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER02_CLUSTER_NAME)

deploy_apps:

configure_hosts:
	sudo hostess add pixelcorp.local 127.0.0.1

	sudo ip route add $(GIMBAL_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(GIMBAL_CLUSTER_NAME)-worker)
	sudo ip route add $(CLUSTER01_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER01_CLUSTER_NAME)-worker)
	sudo ip route add $(CLUSTER02_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER02_CLUSTER_NAME)-worker)

clean:
	kind delete cluster --name=$(GIMBAL_CLUSTER_NAME)
	kind delete cluster --name=$(CLUSTER01_CLUSTER_NAME)
	kind delete cluster --name=$(CLUSTER02_CLUSTER_NAME)

	sudo ip route del $(GIMBAL_POD_NETWORK)
	sudo ip route del $(CLUSTER01_POD_NETWORK)
	sudo ip route del $(CLUSTER02_POD_NETWORK)
	