#!/usr/bin/env bash

set -e -u -o pipefail

TIMEOUT="${TIMEOUT:-120s}"

monitoring() {
	cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |-
    enableUserWorkload: true
    prometheusK8s:
      retentionSize: 4GiB
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 5Gi
EOF

	cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |-
    prometheus:
      enforcedSampleLimit: 10000
      enforcedLabelLimit: 64
      enforcedLabelNameLengthLimit: 64
      enforcedLabelValueLengthLimit: 1024
      retentionSize: 4GiB
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 5Gi
EOF
}

cluster_logging_operator() {
	cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

	cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
  - openshift-logging
EOF

	cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: "stable"
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

	oc wait --for=condition=NamesAccepted=true --for=condition=Established=true --timeout="${TIMEOUT}" crd clusterloggings.logging.openshift.io
}

loki_operator() {
	cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

	cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-operators-redhat
  namespace: openshift-operators-redhat
spec: {}
EOF

	cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

	oc wait --for=condition=NamesAccepted=true --for=condition=Established=true --timeout="${TIMEOUT}" crd lokistacks.loki.grafana.com
}

minio() {
	cat <<EOF | oc create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio
  namespace: openshift-logging
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

	cat <<EOF | oc create -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: openshift-logging
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: loki-operator
      app.kubernetes.io/part-of: loki-operator
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: loki-operator
        app.kubernetes.io/part-of: loki-operator
    spec:
      containers:
      - command:
        - /bin/sh
        - -c
        - |
          mkdir -p /storage/loki && \
          minio server /storage
        env:
        - name: MINIO_ACCESS_KEY
          value: ${MINIO_ACCESS_KEY:-minio}
        - name: MINIO_SECRET_KEY
          value: ${MINIO_SECRET_KEY:-minio123}
        image: minio/minio
        name: minio
        ports:
        - containerPort: 9000
        volumeMounts:
        - mountPath: /storage
          name: storage
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: minio
EOF

	cat <<EOF | oc create -f -
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: openshift-logging
spec:
  ports:
  - port: 9000
    protocol: TCP
    targetPort: 9000
  selector:
    app.kubernetes.io/name: loki-operator
    app.kubernetes.io/part-of: loki-operator
  type: ClusterIP
EOF

	oc wait --for=condition=Available=true -n openshift-logging --timeout="${TIMEOUT}" deployments minio
}

loki_stack() {
	cat <<EOF | oc create -f -
apiVersion: v1
kind: Secret
metadata:
  name: test
  namespace: openshift-logging
stringData:
  access_key_id: ${MINIO_ACCESS_KEY:-minio}
  access_key_secret: ${MINIO_SECRET_KEY:-minio123}
  bucketnames: loki
  endpoint: http://minio.openshift-logging.svc:9000
type: Opaque
EOF

	cat <<EOF | oc create -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.extra-small
  storage:
    schemas:
    - version: v12
      effectiveDate: "2022-06-01"
    secret:
      name: test
      type: s3
  storageClassName: ${STORAGE_CLASS:-gp3-csi}
  tenants:
    mode: openshift-logging
EOF

	oc wait --for=condition=Degraded=false --for=condition=Ready=true --for=condition=Pending=false -n openshift-logging --timeout="${TIMEOUT}" lokistacks logging-loki
}

cluster_logging_collector() {
	cat <<EOF | oc create -f -
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance
  namespace: openshift-logging
spec:
  managementState: Managed
  logStore:
    type: lokistack
    lokistack:
      name: logging-loki
  collection:
    type: vector
EOF

	oc wait --for=condition=CollectorDeadEnd=false -n openshift-logging --timeout="${TIMEOUT}" clusterlogging instance
}

monitoring
cluster_logging_operator
loki_operator
minio
loki_stack
cluster_logging_collector
