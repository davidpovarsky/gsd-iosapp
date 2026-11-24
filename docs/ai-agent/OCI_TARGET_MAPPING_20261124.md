# GSD Oracle — verified read-only target mapping

## Outcome and scope

The existing Windows `DEFAULT` profile successfully authenticated to the exact `torah-social` instance identified by selected IMDSv2 metadata. From **04:47:02 to 04:47:29 UTC on 24 November 2026**, five bounded, read-only OCI calls returned HTTP 200: `GetInstance`, boot-attachment and data-attachment lists filtered to that exact instance, and one GET for each attached volume.

One boot volume and one data volume were attached. No cloud resource, backup, permission, billing setting, volume size, guest filesystem, service or live GSD fixture was changed. Application source and native acceptance were not modified.

Exact instance, compartment, attachment and volume identifiers are retained only in a private receipt on the authorized Windows host. Its SHA-256 is `ec71e521ae5d5b130dbe6f5b825f1977f484c7e7521a45fa48e2c74c4d09dfd1`. Published receipts contain identifier fingerprints and selected metadata; no keys, credentials or instance user-data.

## Attached volume metadata

| Role | Provider display name | API `size_in_gbs` | API `size_in_mbs` | VPU/GB | Autotune | State |
|---|---|---:|---:|---:|---|---|
| Boot | torah-social (Boot Volume) | 47 | 47,694 | 10 | Disabled | AVAILABLE; ATTACHED |
| Data | development-projects-20261122 | 100 | 102,400 | 10 | Disabled | AVAILABLE; ATTACHED |

The data attachment is paravirtualized, read-write and nonshareable. The API's device fields were null. The guest association therefore uses the unique attached role and exact capacity agreement, rather than a device pathname returned by OCI:

- Boot: `47,694 × 1,048,576 = 50,010,783,744` bytes, exactly the observed `/dev/sda` size. Root uses `/dev/sda1`.
- Data: `102,400 × 1,048,576 = 107,374,182,400` bytes, exactly the observed `/dev/sdb` size. The data filesystem mounts this entire device at `/mnt/development`.

Provider GB/MB fields are reported as returned, not as a billing calculation. Storage belongs to the shared server; no project-exclusive ownership is inferred, and no other project's files were inspected.

## Whole boot disk resolves the earlier topology limitation

The earlier [capacity report](ORACLE_CAPACITY_CLEANUP_20261124.md) compared root only with its mounted partition. A read-only partition-table inspection at **04:30:17 UTC** now covers the containing `/dev/sda` disk:

- Disk size: **50,010,783,744 bytes**; GPT; 512-byte sectors.
- Root `/dev/sda1` starts at sector **2,099,200** and spans **95,578,079** sectors.
- Its inclusive end, **97,677,278**, equals the GPT last usable sector.
- No trailing space is available to grow root.
- Three small alignment gaps before the partitions total **3,127,296 bytes**; they are not adjacent growth space at the end of root.

The data filesystem already fills its 100 GiB device. Both inspected ext4 superblocks have zero reserved blocks. There is no meaningful already-allocated headroom established by these observations. No partition, reservation or filesystem modification was attempted.

## Setup evidence and cleanup

Oracle recommends isolating its SDK in a virtual environment; its configuration loader selects the existing `DEFAULT` profile. This assessment used official SDK **2.192.0** under Windows Python **3.12.5**. [Oracle installation](https://docs.oracle.com/en-us/iaas/tools/python/latest/installation.html) · [Configuration](https://docs.oracle.com/en-us/iaas/tools/python/latest/configuration.html)

The first wheel-install attempt reached its 300-second limit before any authenticated OCI API request. Its environment was removed and its receipt retained. The precise installer substep was not established, so the timeout is not described as an authentication or permission failure.

A single authorized retry used pip's documented `--no-compile` option to omit eager bytecode compilation. Installation exited zero, then the five scoped reads succeeded. Both temporary SDK environments were removed. No Oracle or project-environment installation occurred. [pip option](https://pip.pypa.io/en/stable/cli/pip_install/#cmdoption-no-compile)

Only selected IMDS instance ID, compartment ID and display name were retrieved for target binding; region had been separately verified. No instance-principal credential endpoint was queried. Attachment lists used the exact instance filter, and volume GETs used only returned attached IDs. [IMDS reference](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/gettingmetadata.htm) · [Compute filters](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/core/client/oci.core.ComputeClient.html)

## Remaining prerequisites before expansion

Successful reads prove inspection access to these exact targets. They do not prove resize permission: Oracle distinguishes `VOLUME_INSPECT` for volume GETs from `VOLUME_UPDATE` for boot/data updates. No write, dry-run mutation or broad IAM-policy inspection was issued. [Core Services permissions](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm)

This mapping did not query home-region eligibility, tenancy-wide storage or backup consumption, subscription status, limits or billing. No free-tier entitlement or zero-cost expansion is inferred. A separately authorized metadata-only aggregation is the next prerequisite for a concrete capacity/cost proposal.

Oracle supports increasing an attached volume online, but not shrinking it; its guidance calls for a volume backup before resizing. The existing GSD application backup is not evidence of a provider-level backup of the whole shared volume. No provider backup or resize was created here. [Resizing requirements](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/resizingavolume.htm) · [Online expansion](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/update-online-resize-block-boot-volume.htm)

## Evidence

- [Sanitized authenticated mapping](evidence/capacity-20261124/oci-target-mapping.json)
- [Whole boot disk and partition table](evidence/capacity-20261124/boot-parent-capacity.json)
- [Original timeout, single retry and cleanup](evidence/capacity-20261124/sdk-setup-attempts.json)

The prior cache cleanup is separately documented in commit `0d137fb3e7302e44b01d14ce0058ccd624597cba`. This follow-up establishes metadata access and stated observations only. Native UI acceptance, personal ChatGPT Connect and TestFlight retain their separate gates.
