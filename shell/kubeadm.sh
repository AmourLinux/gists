#
# Copyright 2018 (c) Yousong Zhou
#
# Use kubeadm to bring up a simple k8s cluster
#
# Good refs:
#
#	- https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm
#	- https://github.com/kelseyhightower/kubernetes-the-hard-way
#
__errmsg() {
	echo "$*" >&2
}

install() {
	cat <<-"EOF" | sudo bash -c 'cat > /etc/yum.repos.d/kubernetes.repo'
		[kubernetes]
		name=Kubernetes
		baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-$basearch
		enabled=1
		gpgcheck=1
		repo_gpgcheck=1
		gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
	EOF
	sudo yum install -y kubelet kubeadm kubectl
}

config() {
	sudo setenforce 0

	# pod scheduling intends to run workload "fast"
	sudo swapoff -a

	# same cgroup driver as with dockerd
	cgroup_drv="$(docker info \
		| grep 'Cgroup Driver:' \
		| cut -f2 -d:)"
	cgroup_drv="${cgroup_drv# }"
	sudo sed -i \
		"s/cgroup-driver=systemd/cgroup-driver=$cgroup_drv/g" \
		/etc/systemd/system/kubelet.service.d/10-kubeadm.conf

	v='Environment="KUBELET_EXTRA_ARGS=--runtime-cgroups=/systemd/system.slice --kubelet-cgroups=/systemd/system.slice"'
	sudo sed -i -n \
		-e "/^Environment=\"KUBELET_EXTRA_ARGS=.*/d" \
		-e "s#^ExecStart=\$#$v\\n\\0#" \
		-e "p" \
		/etc/systemd/system/kubelet.service.d/10-kubeadm.conf

	sudo systemctl daemon-reload
}

init() {
	sudo systemctl enable kubelet
	sudo systemctl restart kubelet

	# --pod-network-cidr, corresponds with flannel's default setting
	# --apiserver-advertise-address, defaults to the primary address of the nic of default route
	#
	#sudo kubeadm init \
	#	--ignore-preflight-errors=Swap,Service-Docker \
	sudo kubeadm init \
		--ignore-preflight-errors=all \
		--apiserver-advertise-address=10.4.237.52 \
		--pod-network-cidr=10.244.0.0/16 \

}

initcfg() {
	# kubelet config file
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

initnet() {
	sudo sysctl -w net.ipv4.ip_forward=1

	# This is necessary for pod to access services whose backend pods sit on
	# the same bridge.  Details follow
	#
	# Pod A wants to access kube-dns through its service ip 10.96.0.10.  The
	# udp request will be seen by host netfilter rules doing DNAT to the
	# kube-dns pod.  Later kube-dns pod on the same node will send udp response
	# with source/dest ip address being in the same subnet and as such L2
	# communication will happen without the node host being able to do the
	# DNAT in the reply direction.  The originating will be see a udp response
	# from unknown source ip.
	sudo sysctl -w net.bridge.bridge-nf-call-iptables=1

	# NOTE: the following two rules are for my local network settings.
	# Otherwise message "Waiting for services and endpoints to be initialized
	# from apiserver..." will be printed continuously by container kubedns
	#
	# kube-dns will contact apiserver on startup to fetch service and
	# endpoint data to initialize, otherwise it will quit.  API master is
	# discovered by default using [environment variables](https://kubernetes.io/docs/concepts/containers/container-environment-variables)
	#
	# The apiserver listens on eth1 on node host and the service was open to
	# cluster pods through service ClusterIP.  The mapping between was done
	# with iptables DNAT rule.  In the response direction, I have policy
	# routing saying that traffic from primary address of eth1 will do route
	# lookup in a separate table where only a single default route was present,
	# thus making it wrong to route traffic to PodCIDR out through eth1 (should
	# be cni0)
	sudo ip route add 10.244.0.0/24 dev cni0 proto kernel scope link src 10.244.0.1 table 2

	# flannel is for node-node communications
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/v0.9.1/Documentation/kube-flannel.yml
}

dashboard() {
	# https://github.com/kubernetes/dashboard/wiki/Access-control
	#
	# Get Service ClusterIP and use socat to access it
	#
	# 	socat TCP-LISTEN:8000,fork,reuseaddr TCP4:10.109.35.228:443
	#
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
	cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-dashboard
  labels:
    k8s-app: kubernetes-dashboard
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: kubernetes-dashboard
  namespace: kube-system
EOF
}

joincmd() {
	sudo kubeadm token create --print-join-command
}

teardown() {
	kubectl get nodes
	kubectl drain titan2.office.mos --delete-local-data --force --ignore-daemonsets
	kubectl delete node titan2.office.mos
	sudo kubeadm reset

	sudo systemctl stop kubelet
	docker ps -a \
		| grep -i kube \
		| cut -f1 -d' ' \
		| xargs docker rm --force
}

zshcomp() {
	local usrenv="$HOME/.usr.env"

	mkdir -p "$usrenv"
	for p in minikube kubeadm kubectl; do
		if which "$p" &>/dev/null; then
			"$p" completion zsh >"$usrenv/$p.completion.zsh"
			# this needs to the after compinit call in .oh-my-zsh.sh
			echo "  source \"$usrenv/$p.completion.zsh\"$nl"
		else
			__errmsg "$p not found: ignoring"
			rm -vf "$usrenv/$p.completion.zsh"
		fi
	done
}

"$@"
