---
type: index
title: System Backlog - Archive
updated: <date>
tags:
  - "#scope/reference"
---

> **Summary:** Archive of completed, abandoned, or superseded backlog rows. Append-only. Cluster H2s are created on-demand by `backlog-hygiene` from `backlog.clusters[]` when the first row is archived under each cluster.
> **Canonical for:** backlog-archive, completed-project-history
> **Last substantive update:** <date>

# System Backlog - Archive

Rows archived from `System Backlog.md` land here under matching cluster H2. `backlog-hygiene` inserts H2 sections on-demand — the empty file ships without cluster sections so initial install is cluster-list-agnostic.

Row schema matches `System Backlog.md`: `Status | Category | Type | Location | Dependencies | Last Updated | Notes`. Archived rows preserve their final status (`complete`, `archived`, `superseded`) and final Notes pointer.

| Status | Category | Type | Location | Dependencies | Last Updated | Notes |
|---|---|---|---|---|---|---|
