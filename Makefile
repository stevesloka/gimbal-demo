GIMBAL_CLUSTER_NAME=gimbal
CLUSTER01_CLUSTER_NAME=blue
CLUSTER02_CLUSTER_NAME=green
CLUSTER03_CLUSTER_NAME=vmware

GIMBAL_POD_NETWORK='10.241.0.0/16'
CLUSTER01_POD_NETWORK='10.242.0.0/16'
CLUSTER02_POD_NETWORK='10.243.0.0/16'

CONTOUR_IMAGE=projectcontour/contour:v1.0.0
ENVOY_IMAGE=docker.io/envoyproxy/envoy:v1.11.2	
ECHO_IMAGE=hashicorp/http-echo:0.2.3
GIMBAL_IMAGE=stevesloka/gimbal:vmware
APP_IMAGE=stevesloka/echo-server
UTIL_IMAGE=arunvelsriram/utils

VMWARE_URL=https://192.168.2.200/sdk
VMWARE_USERNAME=administrator@vsphere.local
VMWARE_PASSWORD=VMware1!

deps:
	go get github.com/cbednarski/hostess/cmd/hostess
	sudo mv $(GOPATH)/bin/hostess /usr/local/bin

	docker pull $(CONTOUR_IMAGE)
	docker pull $(ENVOY_IMAGE)
	docker pull $(ECHO_IMAGE)
	docker pull $(GIMBAL_IMAGE)
	docker pull $(APP_IMAGE)
	docker pull $(UTIL_IMAGE)

build: deps build_clusters deploy_contour deploy_apps configure_hosts

build_clusters:
	kind create cluster --name=$(GIMBAL_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-gimbal.yaml & \
	kind create cluster --name=$(CLUSTER01_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-cluster01.yaml & \
	kind create cluster --name=$(CLUSTER02_CLUSTER_NAME) --wait=4m --config=kind-configs/kind-cluster02.yaml & \
	wait;

load_images:
	# kind load docker-image $(CONTOUR_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	# kind load docker-image $(GIMBAL_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	# kind load docker-image $(ENVOY_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	kind load docker-image $(UTIL_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	kind load docker-image $(UTIL_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)
	kind load docker-image $(UTIL_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	# kind load docker-image $(APP_IMAGE) --name=$(GIMBAL_CLUSTER_NAME)
	# kind load docker-image $(APP_IMAGE) --name=$(CLUSTER01_CLUSTER_NAME)
	# kind load docker-image $(APP_IMAGE) --name=$(CLUSTER02_CLUSTER_NAME)

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
	kubectl apply -f ./gimbal/02-kubernetes-discoverer-vmware.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

	# Create discoverer secret
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER01_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER01_CLUSTER_NAME) --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl create secret -n gimbal-discovery generic remote-discover-kubecfg-$(CLUSTER02_CLUSTER_NAME) --from-file="$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')" --from-literal=backend-name=$(CLUSTER02_CLUSTER_NAME) --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl create secret -n gimbal-discovery generic remote-discover-$(CLUSTER03_CLUSTER_NAME) --from-literal=VMWARE_URL=$(VMWARE_URL) --from-literal=VMWARE_USERNAME=$(VMWARE_USERNAME) --from-literal=VMWARE_PASSWORD=$(VMWARE_PASSWORD) --from-literal=backend-name=$(CLUSTER03_CLUSTER_NAME) --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

	# Apply DNS Configuration
	cat ./gimbal/upstream-clusters.yaml | sed "s/GIMBALIP/$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(GIMBAL_CLUSTER_NAME)-worker)/g" | kubectl apply --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)') -f -
	cat ./gimbal/upstream-clusters.yaml | sed "s/GIMBALIP/$(shell docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(GIMBAL_CLUSTER_NAME)-worker)/g" | kubectl apply --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)') -f -
	kubectl apply -f ./gimbal/gimbal-dns.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')
	kubectl apply -f ./gimbal/gimbal-dns.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')
	kubectl apply -f ./gimbal/gimbal-dns.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')

deploy_apps:
	# VMWARE_URL=$(VMWARE_URL) VMWARE_USERNAME=$(VMWARE_USERNAME) VMWARE_PASSWORD=$(VMWARE_PASSWORD) vmware-discoverer --backend-name=vmware --gimbal-kubecfg-file=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)') --vmware-insecure &

	kubectl apply -f ./example-apps/deployment-blue.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER01_CLUSTER_NAME)')
	kubectl apply -f ./example-apps/deployment-green.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(CLUSTER02_CLUSTER_NAME)')
	kubectl apply -f ./demo/kubecon/01-root-httpproxy.yaml --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')

configure_hosts:
	sudo hostess add pixelproxy.io 127.0.0.1
	sudo hostess add blue.pixelproxy.io 127.0.0.1
	sudo hostess add green.pixelproxy.io 127.0.0.1
	sudo hostess add marketing.pixelproxy.io 127.0.0.1

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

	# Stop discoverer
	# pkill -f "vmware-discoverer"

resetdemo:
	kubectl delete -f ./demo/kubecon --kubeconfig=$(shell kind get kubeconfig-path --name='$(GIMBAL_CLUSTER_NAME)')