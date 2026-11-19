#!/bin/sh
# Reports the versions of the host components netwrangler depends on, one
# "name: value" line each, so the output of two hosts, or of one host before
# and after an upgrade, can be compared with diff.
#
#   sh check-host-versions.sh > "$(hostname).versions"
#
# POSIX sh rather than Ruby, because cluster nodes rarely have Ruby installed.

set -u

PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

section() {
  printf '\n# %s\n' "$1"
}

field() {
  printf '%s: %s\n' "$1" "$2"
}

# First output line of a tool's version option, stderr included, since some
# tools print their version there
tool_version() {
  executable=$1
  shift

  if ! command -v "$executable" >/dev/null 2>&1; then
    printf 'not installed'
    return
  fi

  "$executable" "$@" 2>&1 | head -n 1
}

report_tool() {
  label=$1
  executable=$2
  shift 2

  field "$label" "$(tool_version "$executable" "$@")"

  if command -v "$executable" >/dev/null 2>&1; then
    field "$label path" "$(command -v "$executable")"
  fi
}

# Version of the first installed package among the candidate names, which
# differ between distributions (libnftnl11 on Debian, libnftnl on Fedora)
package_version() {
  for name in "$@"; do
    if command -v dpkg-query >/dev/null 2>&1; then
      version=$(dpkg-query --show --showformat='${Status} ${Version}' "$name" 2>/dev/null |
        sed -n 's/^install ok installed //p')

      if [ -n "$version" ]; then
        printf '%s (%s)' "$version" "$name"
        return
      fi
    fi

    if command -v rpm >/dev/null 2>&1; then
      if version=$(rpm --query --queryformat '%{VERSION}-%{RELEASE}' "$name" 2>/dev/null); then
        printf '%s (%s)' "$version" "$name"
        return
      fi
    fi

    if command -v apk >/dev/null 2>&1; then
      version=$(apk info --installed --verbose "$name" 2>/dev/null | head -n 1)

      if [ -n "$version" ]; then
        printf '%s' "$version"
        return
      fi
    fi
  done

  printf 'not installed'
}

# The shared libraries the host's nft loads, resolved to their real file
# names, which show the release in use when several are installed
report_nft_libraries() {
  nft_path=$(command -v nft 2>/dev/null) || return
  command -v ldd >/dev/null 2>&1 || return

  ldd "$nft_path" 2>/dev/null | awk '/libnftnl|libmnl|libjansson|libxtables|libgmp/ { print $1, $3 }' |
    while read -r name path; do
      field "nft links $name" "$(readlink -f "$path")"
    done
}

# Whether a kernel module is loaded, built in, available to load, or missing
module_state() {
  module=$1
  release=$(uname -r)

  if grep -q "^${module} " /proc/modules 2>/dev/null; then
    printf 'loaded'
  elif grep -q "/${module}\.ko" "/lib/modules/${release}/modules.builtin" 2>/dev/null; then
    printf 'built in'
  elif command -v modinfo >/dev/null 2>&1 && modinfo "$module" >/dev/null 2>&1; then
    printf 'available, not loaded'
  else
    printf 'missing'
  fi
}

os_name() {
  name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')

  printf '%s' "${name:-unknown}"
}

section "System"
field "os" "$(os_name)"
field "architecture" "$(uname -m)"
field "kernel" "$(uname -r)"
report_tool "kubelet" kubelet --version
report_tool "containerd" containerd --version

section "Tools"
report_tool "nft" nft --version
report_tool "ip" ip -V
report_tool "wg" wg --version
report_tool "arping" arping -V
report_tool "iptables" iptables -V
report_nft_libraries

section "Packages"
field "nftables" "$(package_version nftables)"
field "libnftnl" "$(package_version libnftnl11 libnftnl)"
field "libmnl" "$(package_version libmnl0 libmnl)"
field "iproute2" "$(package_version iproute2 iproute)"
field "wireguard-tools" "$(package_version wireguard-tools)"
field "iputils arping" "$(package_version iputils-arping iputils)"
field "iptables" "$(package_version iptables)"

section "Kernel modules"
for module in nf_tables nft_ct nft_nat nft_chain_nat nf_nat nf_conntrack wireguard; do
  field "$module" "$(module_state "$module")"
done
