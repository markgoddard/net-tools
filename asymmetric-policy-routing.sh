#!/bin/bash -ex

# Small test environment for policy based routing as a solution in asymmetric
# routing environments.

# Creates a virtual networking environment with 2 hosts and a router connected
# via a bridge. Each host has a veth pair with one end attached to the bridge
# and the other in a network namespace. The hosts have the following VLAN
# interfaces and IP addresses in their namespace:
# r1: VLAN 1 / 10.0.1.1, VLAN 2 / 10.0.2.1
# h1: VLAN 1 / 10.0.1.2
# h2: VLAN 1 / 10.0.1.3, VLAN 2 / 10.0.2.3
# Assumes IP routing has been enabled.


hosts="h1 h2 r1"

function add_vlan_ip {
  # usage: <netns> <interface> <vlan> <ip>
  sudo ip -n $1 l add link $2  name $2.$3 type vlan id $3
  sudo ip -n $1 a add $4 dev $2.$3
  sudo ip -n $1 l set $2.$3 up
  sudo ip -n $1 a
  # Use strict mode reverse path filtering.
  sudo ip netns exec $1 sysctl -w net.ipv4.conf.$2/$3.rp_filter=1
}

function check_connectivity {
  # usage: <netns> <remote ip> [<source ip>]
  echo "Checking ping from NS $1 to $2${3:+ (source $3)}"
  sudo ip -n $1 route get $2
  opts=""
  if [[ -n $3 ]]; then
    opts="$opts -I $3"
  fi
  sudo ip netns exec $1 ping -c1 -w 2 $2 $opts
}

function check_no_connectivity {
  # usage: <netns> <remote ip> [<source ip>]
  echo "Checking no ping from NS $1 to $2{3:+ (source $3)}"
  sudo ip -n $1 route get $2
  opts=""
  if [[ -n $3 ]]; then
    opts="$opts -I $3"
  fi
  if sudo ip netns exec $1 ping -c1 -w 2 $2 $opts; then
    return 1
  fi
}

function cleanup {
  set +e
  sudo ip l del br0
  sudo ip -n h2 rule del from 10.0.2.0/24 table test
  sudo ip -n h2 rule del to 10.0.2.0/24 table test
  sudo sed -i -e '/42 test/d' /etc/iproute2/rt_tables
  for h in $hosts; do
    sudo ip l del $h-br
    sudo ip netns del $h
  done
}

function test_ip_source_routing {
  # Create bridge.
  sudo brctl addbr br0
  sudo ip l set br0 up

  # Create hosts and veth pairs.
  for h in $hosts; do
    sudo ip l add $h-br type veth peer name $h-h
    sudo ip l set $h-br up
    sudo brctl addif br0 $h-br
    # Namespace == hostname.
    sudo ip netns add $h
    sudo ip link set $h-h netns $h
    sudo ip -n $h link set $h-h up
    # Use strict mode reverse path filtering.
    sudo ip netns exec $h sysctl -w net.ipv4.conf.$h-h.rp_filter=1
  done
  
  # Add VLAN interfaces and IPs.
  add_vlan_ip h1 h1-h 1 10.0.1.2/24
  sudo ip -n h1 r add default via 10.0.1.1
  
  add_vlan_ip h2 h2-h 1 10.0.1.3/24
  add_vlan_ip h2 h2-h 2 10.0.2.3/24
  sudo ip -n h2 r add default via 10.0.1.1
  
  add_vlan_ip r1 r1-h 1 10.0.1.1/24
  add_vlan_ip r1 r1-h 2 10.0.2.1/24

  # Check connectivity.

  # These should work:
  check_connectivity h1 10.0.1.3
  check_connectivity h2 10.0.1.2
  
  # These should not:
  check_no_connectivity h1 10.0.2.3
  check_no_connectivity h2 10.0.1.2 10.0.2.3 # Force traversal of the router.
  
  # Now enable source routing
  echo "Enabling source routing"
  echo "42 test" | sudo tee -a /etc/iproute2/rt_tables
  sudo ip -n h2 rule add from 10.0.2.0/24 table test
  sudo ip -n h2 rule add to 10.0.2.0/24 table test
  sudo ip -n h2 route add default via 10.0.2.1 table test
  
  # Check connectivity.

  # These should all work:
  check_connectivity h1 10.0.1.3
  check_connectivity h2 10.0.1.2
  check_connectivity h1 10.0.2.3
  check_connectivity h2 10.0.1.2 10.0.2.3 # Force traversal of the router.
}

if [[ $1 = cleanup ]]; then
  cleanup
else
  test_ip_source_routing
fi
