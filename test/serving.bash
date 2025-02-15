#!/usr/bin/env bash

# disable SC2086(Double quote to prevent globbing and word splitting)
# as go_test_e2e wants to split OPENSHIFT_TEST_OPTIONS by space.
#
# shellcheck disable=SC2086

# For SC2164
set -e

function prepare_knative_serving_tests {
  logger.debug 'Preparing Serving tests'

  cd "$KNATIVE_SERVING_HOME"

  # Don't bother with the chaosduck downstream for now
  rm -fv test/config/chaosduck.yaml

  # workaround until https://github.com/knative/operator/issues/431 was fixed.
  rm -fv test/config/config-deployment.yaml

  # Create test resources (namespaces, configMaps, secrets)
  ytt \
    -f "test/config/ytt/lib" \
    -f "test/config/ytt/values.yaml" \
    -f test/config/ytt/core/resources.yaml | oc apply -f -
  # Adding scc for anyuid to test TestShouldRunAsUserContainerDefault.
  oc adm policy add-scc-to-user anyuid -z default -n serving-tests
  # Add networkpolicy to test namespace and label to serving namespaces for testing under the strict networkpolicy.
  add_networkpolicy "serving-tests"
  add_networkpolicy "serving-tests-alt"
  add_systemnamespace_label

  export GATEWAY_OVERRIDE="kourier"
  export GATEWAY_NAMESPACE_OVERRIDE="${INGRESS_NAMESPACE}"
}

function upstream_knative_serving_e2e_and_conformance_tests {
  logger.info "Running Serving E2E and conformance tests"

  prepare_knative_serving_tests

  # Enable allow-zero-initial-scale before running e2e tests (for test/e2e/initial_scale_test.go)
  oc -n "${SERVING_NAMESPACE}" patch knativeserving/knative-serving \
    --type=merge \
    --patch='{"spec": {"config": { "autoscaler": {"allow-zero-initial-scale": "true"}}}}'

  image_template="registry.ci.openshift.org/openshift/knative-${KNATIVE_SERVING_VERSION}:knative-serving-test-{{.Name}}"
  OPENSHIFT_TEST_OPTIONS="--kubeconfig $KUBECONFIG --enable-beta --enable-alpha --resolvabledomain"

  local parallel=3

  if [[ $(oc get infrastructure cluster -ojsonpath='{.status.platform}') = VSphere ]]; then
    # Since we don't have LoadBalancers working, gRPC tests will always fail.
    rm ./test/e2e/grpc_test.go
    parallel=2
  fi

  SYSTEM_NAMESPACE=knative-serving go_test_e2e -tags=e2e -timeout=30m -parallel=$parallel \
    ./test/e2e ./test/conformance/api/... ./test/conformance/runtime/... \
    ${OPENSHIFT_TEST_OPTIONS} \
    --imagetemplate "$image_template"

  # Run the helloworld test with an image pulled into the internal registry.
  oc tag -n serving-tests "registry.ci.openshift.org/openshift/knative-${KNATIVE_SERVING_VERSION}:knative-serving-test-helloworld" "helloworld:latest" --reference-policy=local
  SYSTEM_NAMESPACE=knative-serving go_test_e2e -tags=e2e -timeout=30m ./test/e2e -run "^(TestHelloWorld)$" \
    ${OPENSHIFT_TEST_OPTIONS} \
    --imagetemplate "image-registry.openshift-image-registry.svc:5000/serving-tests/{{.Name}}"
  
  # Prevent HPA from scaling to make HA tests more stable
  local max_replicas min_replicas
  max_replicas=$(oc get hpa activator -n "$SERVING_NAMESPACE" -ojsonpath='{.spec.maxReplicas}')
  min_replicas=$(oc get hpa activator -n "$SERVING_NAMESPACE" -ojsonpath='{.spec.minReplicas}')

  # Keep this in sync with test/ha/ha.go
  readonly REPLICAS=2
  # TODO: Increase BUCKETS size more than 1 when operator supports configmap/config-leader-election setting.
  readonly BUCKETS=1

  # Changing the bucket count and cycling the controllers will leave around stale
  # lease resources at the old sharding factor, so clean these up.
  oc -n "${SERVING_NAMESPACE}" delete leases --all

  # Wait for a new leader Controller to prevent race conditions during service reconciliation
  wait_for_leader_controller

  # Dump the leases post-setup.
  oc get lease -n "${SERVING_NAMESPACE}"

  # Give the controller time to sync with the rest of the system components.
  sleep 30

  oc -n "$SERVING_NAMESPACE" patch hpa activator \
    --patch '{"spec": {"maxReplicas": '${REPLICAS}', "minReplicas": '${REPLICAS}'}}'

  # Run HA tests separately as they're stopping core Knative Serving pods
  # Define short -spoofinterval to ensure frequent probing while stopping pods
  SYSTEM_NAMESPACE=knative-serving go_test_e2e -tags=e2e -timeout=15m -failfast -parallel=1 ./test/ha \
    -replicas="${REPLICAS}" -buckets="${BUCKETS}" -spoofinterval="10ms" \
    ${OPENSHIFT_TEST_OPTIONS} \
    --imagetemplate "$image_template"

  # Restore the original maxReplicas for any tests running after this test suite
  oc -n "$SERVING_NAMESPACE" patch hpa activator --patch \
    '{"spec": {"maxReplicas": '"${max_replicas}"', "minReplicas": '"${min_replicas}"'}}'
}
