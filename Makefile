GIMBAL_CLUSTER_NAME=gimbal
CLUSTER01_CLUSTER_NAME=blue
CLUSTER02_CLUSTER_NAME=green

GIMBAL_POD_NETWORK='10.241.0.0/16'
CLUSTER01_POD_NETWORK='10.242.0.0/16'
CLUSTER02_POD_NETWORK='10.243.0.0/16'

CONTOUR_IMAGE=gcr.io/heptio-images/contour:v0.14.1
ENVOY_IMAGE=docker.io/envoyproxy/envoy:v1.11.0
ECHO_IMAGE=hashicorp/http-echo
GIMBAL_IMAGE=gcr.io/heptio-images/gimbal-discoverer:v0.4.0

deps:
	go get github.com/cbednarski/hostess/cmd/hostess

	docker pull $(CONTOUR_IMAGE)
	docker pull $(ENVOY_IMAGE)
	docker pull $(ECHO_IMAGE)
	docker pull $(GIMBAL_IMAGE)

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
	kind load docker-image $(ECHO_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	kind load docker-image $(ECHO_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)
	kind load docker-image $(GIMBAL_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	kind load docker-image $(GIMBAL_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)

deploy_contour:
	# Deploy Gimbal/Contour
	kubectl apply -f contour --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

	# Update kubeconfig files
	kubectl config set-cluster $(CLUSTER01_CLUSTER_NAME) --server=https://$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER01_CLUSTER_NAME)-control-plane):6443 --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')
	kubectl config set-cluster $(CLUSTER02_CLUSTER_NAME) --server=https://$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER02_CLUSTER_NAME)-control-plane):6443 --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')

	# Deploy discoverers
	kubectl apply -f ./gimbal/01-common.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl apply -f ./gimbal/02-kubernetes-discoverer-blue.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl apply -f ./gimbal/02-kubernetes-discoverer-green.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

	# Create discoverer secrets
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER01_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER01_CLUSTER_NAME) --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER02_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER02_CLUSTER_NAME) --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')


deploy_apps:
	kubectl apply -f ./example-apps/deployment-blue.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')
	kubectl apply -f ./example-apps/deployment-green.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')
	kubectl apply -f ./example-apps/ingressroute.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

configure_hosts:
	sudo hostess add pixelcorp.local 127.0.0.1

	# Add static routes to enable routing
	sudo ip route add $(GIMBAL_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(GIMBAL_CLUSTER_NAME)-worker)
	sudo ip route add $(CLUSTER01_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER01_CLUSTER_NAME)-worker)
	sudo ip route add $(CLUSTER02_POD_NETWORK) via $(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(CLUSTER02_CLUSTER_NAME)-worker)

clean:
	# Delete kind clusters
	kind delete cluster --name=$(GIMBAL_CLUSTER_NAME)
	kind delete cluster --name=$(CLUSTER01_CLUSTER_NAME)
	kind delete cluster --name=$(CLUSTER02_CLUSTER_NAME)

	# Remove static routes
	sudo ip route del $(GIMBAL_POD_NETWORK)
	sudo ip route del $(CLUSTER01_POD_NETWORK)
	sudo ip route del $(CLUSTER02_POD_NETWORK)
	