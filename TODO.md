# TODO

- Add validation that VipGateway routeTable/routingPriority values do not
  overlap with the VipConfig allocation range (firewallMark to
  firewallMark + maxAddressCount - 1, same for routeTable and
  routingPriority). The controller should reject or warn if a VipGateway
  uses values in the VipAddress allocation range, since the agent's
  `remove_vip_routes` could delete VipAddress routes from shared tables.
- Make `WireguardUpdater#discover_peers` and `#remove_allowed_ip` private.
  They are currently public but only called internally. Keep public only if
  needed for direct unit testing.
