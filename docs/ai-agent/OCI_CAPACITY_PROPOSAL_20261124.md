# GSD Oracle — regional capacity and expansion options

## Outcome

**The read-only assessment completed successfully. The selected home region currently has 194 GB allocated against a 200 GB storage limit, leaving 6 GB.** The earlier proposal to add 25 GB to each GSD server volume would reach 244 GB and exceed that observed limit by 44 GB.

No provider backup, resize, IAM change, billing change, guest-filesystem modification, service restart or live-fixture change was performed. The application source frozen for native acceptance was untouched.

The exact server and attached volume binding remains in [the verified target mapping](OCI_TARGET_MAPPING_20261124.md), commit `d6e6a9d039185842cebcf51bff68e2441ee9ef95`. This follow-up supplies the previously missing regional aggregate, home-region and resource-limit evidence.

## Actual API observations

Official OCI Python SDK **2.192.0**, using only the existing Windows `DEFAULT` profile and region `il-jerusalem-1`, made **10 bounded read-only requests, all HTTP 200**, from **05:27:59 to 05:28:33 UTC on 24 November 2026**.

| Observation | Returned result |
|---|---|
| Tenancy home-region key | `MTZ`, corresponding to `il-jerusalem-1` |
| Active compartment discovery | Root only; no active child compartments returned; complete pagination |
| Available boot volumes | 2, totaling **94 GB** |
| Available data volumes | 1, totaling **100 GB** |
| Combined provisioned capacity | **194 GB** |
| Performance | All three volumes at **10 VPU/GB**, autotune disabled |
| Boot-volume backups | **0** |
| Data-volume backups | **0** |
| Target server volumes | Still **47 GB boot + 100 GB data**; match prior mapping |
| Enumeration gaps or duplicate resource rows | **None** |

The extra boot volume was counted only in aggregate. Its name, ID, contents and project ownership were not disclosed or inspected. No deletion of another volume is proposed. This is a timestamped, non-atomic metadata snapshot of the selected region and its active compartment tree; it is not an inventory of other regions or accounts.

The separate limits API corroborated the resource counts:

| Limit | Scope returned | Limit value | Used | Available |
|---|---|---:|---:|---:|
| `total-storage-gb` | Availability domain | **200 GB** | **194 GB** | **6 GB** |
| `backup-count` | Region | **5** | **0** | **5** |

These values prove the observed resource-limit arithmetic. They do not independently verify a billing entitlement or permission to update resources.

The successful calls were `GetTenancy`, complete `ListCompartments` with root/subtree/ANY scope, boot/data volume lists, both backup lists, and `ListLimitValues` plus `GetResourceAvailability` for the two selected block-storage limits. No broad IAM-policy read or cloud write was issued. [Sanitized API receipt](evidence/capacity-20261124/oci-regional-aggregate.json)

## The local endpoint failure was diagnosed and corrected

The first aggregate attempt, `job_c4bd0c4dfb9e`, installed the SDK successfully but stopped at local configuration with `RuntimeError` and `calls=[]`. Its wrapper saved that failure receipt and exited zero; this was never an assessment pass or proof of an OCI authorization denial.

Static inspection of the official pinned SDK source identified the cause. `BlockstorageClient` retains a dual-stack option inside its `base_client.endpoint` template; that property is not yet the final hostname. The official `base_client.get_endpoint()` resolves the option before returning the actual service endpoint. The original local guard incorrectly parsed the unresolved template.

The corrected assessment validates the official resolved endpoint with the **same HTTPS, oraclecloud.com domain and exact selected-region constraints**. It adds fixed operation phases and safe guard codes; arbitrary exception text and configuration values remain suppressed. The completed runtime receipt confirms that the old raw-template guard rejects the block-storage template while the resolved host passes.

| SDK service | Verified resolved HTTPS host |
|---|---|
| Identity | `identity.il-jerusalem-1.oci.oraclecloud.com` |
| Block storage | `iaas.il-jerusalem-1.oraclecloud.com` |
| Limits | `limits.il-jerusalem-1.oci.oraclecloud.com` |

The selected profile region was also independently read back unchanged; its configuration file still had its prior October mtime. No configuration or credential was edited.

[Official BlockstorageClient source, v2.192.0](https://github.com/oracle/oci-python-sdk/blob/v2.192.0/src/oci/core/blockstorage_client.py) · [Official BaseClient source, v2.192.0](https://github.com/oracle/oci-python-sdk/blob/v2.192.0/src/oci/base_client.py) · [Guard diagnosis](evidence/capacity-20261124/sdk-endpoint-guard-diagnosis.json)

## Concrete options for root review

These quantities use OCI's returned `size_in_gbs` fields. They do not imply a byte-level billing conversion.

| Option | Target boot | Target data | Regional aggregate afterward | Assessment |
|---|---:|---:|---:|---|
| Current state | 47 GB | 100 GB | 194 GB | Root/data free space remains low |
| Bounded candidate | **50 GB** | **103 GB** | **200 GB** | Uses the observed remaining 6 GB; modest headroom |
| Earlier +25/+25 candidate | 72 GB | 125 GB | 244 GB | Rejected after aggregate review: exceeds the observed limit by 44 GB |

Both proposed options retain 10 VPU/GB with autotune disabled. Two provider-level backups before expansion would take the observed backup count from zero to two, within the returned limit of five; none has been created.

The bounded candidate would provide temporary additional filesystem headroom, not a verified long-term capacity forecast. At the last completed cleanup observation, **04:22:32 UTC**, root had **277,323,776 bytes (264.48 MiB)** available and data had **702,832,640 bytes (670.27 MiB)**. These are prior timestamped measurements, not a new free-space check.

Both inspected ext4 superblocks had zero reserved blocks. Root ends at the containing disk's last usable sector, and data already fills its device. Filesystem-only growth within existing allocation is therefore not established. [Cleanup and whole-disk evidence](ORACLE_CAPACITY_CLEANUP_20261124.md)

## Allowance, cost and execution boundary

Oracle's current Always Free documentation describes **200 GB combined boot/block storage and five combined volume backups in the home region**, subject to eligibility. The observed home-region match, 194 GB consumption and zero backup count are now verified; the account's billing label and applicable contractual price were not queried. [Oracle Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)

For context only, the official global price list dated **1 November 2026**, page 73, lists storage SKU B91961 at **US$0.0255 per GB-month** and performance SKU B91962 at **US$0.0017 per VPU/GB-month**. At 10 VPU/GB, the proposed additional 6 GB at standard list rates calculates to **US$0.255/month** before taxes, discounts, allowances and backup storage. This is not an account quote, a zero-cost guarantee or an authorization to spend. No paid-tier or quota upgrade is proposed.

The same price-list PDF's B91445 free-volume row states 100 GB, while the service documentation states 200 GB. This discrepancy is preserved rather than silently turned into a zero-cost guarantee. [Oracle global price list](https://www.oracle.com/il-en/a/ocom/docs/corporate/pricing/oracle-paas-and-iaas-global-price-list.pdf)

Successful inspection does not prove `VOLUME_UPDATE`. Oracle's procedure allows increasing volume sizes online, but not shrinking them, and advises a whole-volume backup before expansion. The verified GSD application backup is separate from a backup of the complete shared boot/data volumes. [Inspection/update permissions](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm) · [Resize requirements](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/resizingavolume.htm) · [Online resize procedure](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/update-online-resize-block-boot-volume.htm)

Any approved implementation would require fresh exact-target/limit checks, completed provider backups, an explicit native-safe operation window, unchanged performance settings, the provider size update, then the appropriate guest device/partition/filesystem growth and service-health verification. No step in that mutation sequence was started by this assessment.

## Setup, cleanup and evidence

The corrected job was `job_be64f4f17f28`, running **05:24:23–05:29:22 UTC**. Its official SDK installation exited zero, the metadata phase completed in **34.781 seconds**, and its isolated Windows SDK environment was removed at **05:29:22 UTC**. No installation occurred on Oracle or inside a project environment.

The corrected operational script's SHA-256 was `406e251cf2a20bdc04f0e0967e8b78fb3ec06516abf248eba2c0e348cc25900d`. These temporary operational scripts are not application-source changes.

- [Completed regional aggregate and isolated cleanup](evidence/capacity-20261124/oci-regional-aggregate.json)
- [Original pre-request failure receipt](evidence/capacity-20261124/aggregate-attempt-failed.json)
- [Selected-region and own-directory readback](evidence/capacity-20261124/aggregate-configuration-readback.json)
- [Static and runtime endpoint-guard diagnosis](evidence/capacity-20261124/sdk-endpoint-guard-diagnosis.json)
- [Prior verified exact-target binding](OCI_TARGET_MAPPING_20261124.md)

**Remaining decision:** root is preparing review of the modest 50/103 GB candidate under the existing maintenance authorization. The larger option is rejected. The exact backup, guarded resize, guest-growth and continuity procedure still needs review and a native-safe window. All cloud and guest writes remain on hold; this report itself authorizes no billing, backup or resize operation.

## Later execution outcome

The separately reviewed 50/103 GB operation completed with final verification at 06:51:02 UTC. See [the execution evidence](OCI_BOUNDED_EXPANSION_EXECUTION_20261124.md) and [the exact runbook](OCI_BOUNDED_EXPANSION_RUNBOOK_20261124.md). This dated assessment remains the original pre-change observation; later allocation is 200/200 GB.
