# Cluster operation

[← Back to README](../README.md)

Ultimate Updater is normally installed once on a Proxmox cluster. The central
installation coordinates the inventory, checks, updates, status, jobs, and
notifications. A standalone Proxmox node is also supported.

Remote Proxmox nodes are reached through the cluster's known node addresses
and SSH paths. Guests remain associated with their owning node. A check or
update started from another node is dispatched to the owner when required;
the owner remains the source of truth for execution and logs.

The Web UI presents cluster nodes and their LXC/VM guests in one overview.
Remote status is imported into the central status model so completed remote
jobs do not leave stale or permanently pending values.

Before installation, make sure cluster hostnames and addresses resolve
consistently and that the central node can use the required SSH fingerprints.
Do not install another administrative updater instance on every node.

Related: [Installation](installation.md), [SSH and VM access](ssh.md),
[Checks and updates](checks-and-updates.md).
