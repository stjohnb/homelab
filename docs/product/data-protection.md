# Data protection

**Reference**

Read this when changing backups, migration jobs, data storage, or recovery procedures.
Read [PRODUCT.md](../PRODUCT.md) first; read the relevant backup or storage deep dive for mechanics.

## Problem

Local storage, network configuration, and self-hosted forge data need recoverable copies despite nodes that are not always online.

## Users

The operator restores services and configuration; household users depend on retained application data.

## Requirements

### Keep a bounded nightly backup of UniFi console configuration on operator-controlled storage

The console backup must be retained on the NAS, fail visibly when no real archive is returned, and be restorable through the console.

**Why:** Console configuration cannot be recovered from vendor cloud backup or reconstructed reliably from memory.

### Treat Forgejo dumps as the off-node recovery copy for migrated repositories

The scheduled dump must preserve repositories and forge metadata; archived GitHub copies are not an active mirror strategy.

**Why:** The owner chose a complete, operator-controlled dump over maintaining live GitHub push mirrors.

### Make generated migration state reconcile automatically after merge

Pending migrations execute through Flux without an operator running each script.

**Why:** Reproducible cluster state must be attainable on reconciliation rather than dependent on an undocumented manual sequence.

### Serve application databases in Datasette only as redacted, consistent nightly snapshots

Only redacted copies taken with the SQLite online backup API (never a plain copy of a live database) reach Datasette's served volume, they stay home-only behind ForwardAuth, and a failed source keeps serving its previous snapshot.

**Why:** Querying the media pipeline with SQL is useful, but the app databases hold indexer, download-client and media-server credentials, and a torn copy would be misleading.

## Non-goals & rejected ideas

- A separate cloneable NAS git-backup tree for Forgejo repositories.

## Open questions

- Which restore procedures need scheduled rehearsal rather than manual verification?
