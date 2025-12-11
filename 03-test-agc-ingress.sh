#!/bin/bash

# Compare responses served by two ingress routes (legacy NGINX vs AGC)
# Defaults target the sample migration walkthrough where the original ingress
# is `store-front` and the migrated ingress is `store-front-agc-controller`
# (or `store-front-agc` when following the quickstart scripts in this repo).

set -euo pipefail

NAMESPACE=${NAMESPACE:-aks-store}
ORIGINAL_INGRESS=${ORIGINAL_INGRESS:-store-front}
MIGRATED_INGRESS_DEFAULT=${MIGRATED_INGRESS:-store-front-agc}

if [[ $# -ge 1 ]]; then
	ORIGINAL_INGRESS=$1
fi

if [[ $# -ge 2 ]]; then
	MIGRATED_INGRESS_DEFAULT=$2
fi

# Resolve namespace/ingress existence and fall back to store-front-agc when the
# controller-style name isn't present.
if ! kubectl get ingress "$ORIGINAL_INGRESS" -n "$NAMESPACE" >/dev/null 2>&1; then
	echo "Original ingress '$ORIGINAL_INGRESS' not found in namespace '$NAMESPACE'." >&2
	exit 1
fi

if ! kubectl get ingress "$MIGRATED_INGRESS_DEFAULT" -n "$NAMESPACE" >/dev/null 2>&1; then
	if kubectl get ingress store-front-agc -n "$NAMESPACE" >/dev/null 2>&1; then
		MIGRATED_INGRESS_DEFAULT=store-front-agc
	else
		echo "Migrated ingress '$MIGRATED_INGRESS_DEFAULT' not found (no fallback)." >&2
		exit 1
	fi
fi

# shellcheck disable=SC2034 # For clarity when printing results later
MIGRATED_INGRESS=$MIGRATED_INGRESS_DEFAULT

fetch_ingress_content() {
	local ingress=$1
	local namespace=$2
	local output=$3

	local lb_ip lb_host host rule_host tls_host scheme port url
	lb_ip=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
	lb_host=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
	host=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
	tls_host=$(kubectl get ingress "$ingress" -n "$namespace" -o jsonpath='{.spec.tls[0].hosts[0]}' 2>/dev/null || true)

	if [[ -n "$tls_host" ]]; then
		scheme=https
		host=$tls_host
		port=443
	else
		scheme=http
		port=80
	fi

	if [[ -z "$lb_ip" && -z "$lb_host" ]]; then
		echo "Ingress '$ingress' has no external address assigned yet." >&2
		return 1
	fi

	local curl_args=(--silent --show-error --fail --location)
	[[ "$scheme" == https ]] && curl_args+=(-k)

	if [[ -n "$lb_host" ]]; then
		url="$scheme://$lb_host/"
	elif [[ -n "$lb_ip" ]]; then
		if [[ -n "$host" ]]; then
			curl_args+=(--resolve "$host:$port:$lb_ip")
			url="$scheme://$host/"
		else
			url="$scheme://$lb_ip/"
		fi
	else
		echo "Unable to determine URL for ingress '$ingress'." >&2
		return 1
	fi

	# When host is defined but curl already targets that hostname, no extra header
	# is required. Otherwise explicitly set the Host header for correctness.
	if [[ -n "$host" && "$url" != "$scheme://$host/" ]]; then
		curl_args+=(-H "Host: $host")
	fi

	curl "${curl_args[@]}" "$url" >"$output"
}

tmp_original=$(mktemp)
tmp_migrated=$(mktemp)
trap 'rm -f "$tmp_original" "$tmp_migrated"' EXIT

echo "Fetching response from $ORIGINAL_INGRESS (namespace: $NAMESPACE)..."
fetch_ingress_content "$ORIGINAL_INGRESS" "$NAMESPACE" "$tmp_original"

echo "Fetching response from $MIGRATED_INGRESS (namespace: $NAMESPACE)..."
fetch_ingress_content "$MIGRATED_INGRESS" "$NAMESPACE" "$tmp_migrated"

if diff -q "$tmp_original" "$tmp_migrated" >/dev/null; then
	bytes=$(wc -c <"$tmp_original")
	echo "✅ Responses match ($bytes bytes)."
else
	echo "⚠️ Responses differ. Showing unified diff:"
	diff -u "$tmp_original" "$tmp_migrated" || true
	exit 2
fi

