#!/usr/bin/env python3
"""Compute a non-overlapping subnet for Application Gateway for Containers.

This helper selects the first available subnet within a VNet address space that
doesn't conflict with existing subnet prefixes. The default behaviour mirrors
Azure's AGC quickstart guidance by looking for the first /24 block. If the VNet
is already more specific than /24, the helper falls back to using the entire
network provided it doesn't overlap with any existing subnet.

Usage examples:
    $ VNET_PRIMARY_PREFIX=10.224.0.0/15 \
      EXISTING_SUBNET_PREFIXES="10.224.0.0/16" \
      scripts/compute_non_overlapping_subnet.py

    # With explicit arguments and multiple prefixes:
    $ scripts/compute_non_overlapping_subnet.py \
        --vnet-prefix 10.0.0.0/8 \
        --existing-prefix 10.0.0.0/16 \
        --existing-prefix 10.1.0.0/16

Environment variables:
    VNET_PRIMARY_PREFIX
        Default value for --vnet-prefix when the flag isn't supplied.
    EXISTING_SUBNET_PREFIXES
        Whitespace-delimited list of existing subnet prefixes. Used when
        --existing-prefix isn't provided.
    TARGET_PREFIX
        Optional integer CIDR prefix length to search for (defaults to 24).
"""

from __future__ import annotations

import argparse
import ipaddress
import os
import sys
from typing import Iterable, List, Optional


def parse_networks(raw: Iterable[str]) -> List[ipaddress.IPv4Network]:
    """Convert a sequence of strings into ipaddress networks, ignoring invalid."""

    networks: List[ipaddress.IPv4Network] = []
    for value in raw:
        value = value.strip()
        if not value:
            continue
        # Values may include comma-separated entries; split on commas and spaces
        for token in value.replace(",", " ").split():
            token = token.strip()
            if not token:
                continue
            try:
                networks.append(ipaddress.ip_network(token, strict=False))
            except ValueError:
                # Skip malformed input and continue gracefully
                continue
    return networks


def find_available_subnet(
    vnet: ipaddress._BaseNetwork,
    reserved: Iterable[ipaddress._BaseNetwork],
    target_prefix: int,
) -> Optional[ipaddress._BaseNetwork]:
    """Return the first non-overlapping subnet, preferring target_prefix sizes."""

    reserved_list = list(reserved)

    def overlaps(candidate: ipaddress._BaseNetwork) -> bool:
        return any(candidate.overlaps(existing) for existing in reserved_list)

    if vnet.prefixlen <= target_prefix:
        for subnet in vnet.subnets(new_prefix=target_prefix):
            if not overlaps(subnet):
                return subnet

    # Fallback: use the full VNet range if it's unused.
    if not overlaps(vnet):
        return vnet

    return None


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--vnet-prefix",
        dest="vnet_prefix",
        default=os.environ.get("VNET_PRIMARY_PREFIX"),
        help="Parent VNet CIDR block (default: $VNET_PRIMARY_PREFIX).",
    )
    parser.add_argument(
        "--existing-prefix",
        dest="existing",
        action="append",
        default=None,
        help="Existing subnet CIDRs to avoid. Repeatable. "
        "Default reads $EXISTING_SUBNET_PREFIXES.",
    )
    parser.add_argument(
        "--target-prefix",
        dest="target_prefix",
        type=int,
        default=int(os.environ.get("TARGET_PREFIX", "24")),
        help="Preferred subnet prefix length to carve (default: 24).",
    )

    args = parser.parse_args(list(argv) if argv is not None else None)

    if not args.vnet_prefix:
        parser.error("--vnet-prefix (or $VNET_PRIMARY_PREFIX) is required")

    try:
        vnet_network = ipaddress.ip_network(args.vnet_prefix, strict=False)
    except ValueError as exc:
        parser.error(f"Invalid VNet prefix '{args.vnet_prefix}': {exc}")

    existing_prefixes_source = args.existing
    if existing_prefixes_source is None:
        env_value = os.environ.get("EXISTING_SUBNET_PREFIXES", "")
        existing_prefixes_source = env_value.splitlines()

    reserved_networks = parse_networks(existing_prefixes_source)

    result = find_available_subnet(vnet_network, reserved_networks, args.target_prefix)
    if result is None:
        sys.stderr.write(
            "No available subnet found: VNet overlaps with all existing prefixes\n"
        )
        return 1

    print(str(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
