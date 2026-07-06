# G2 lean RPC/schema packet — moved

The reviewed G2 first-persistence SQL packet that used to live here as
`g2_lean_rpc_packet_20260705.sql` was **applied on 2026-07-05** and promoted to the
permanent migration source-of-truth:

- **Migration (source of truth):** [`migrations/20260705_g2_trade_group_rpcs.sql`](../../migrations/20260705_g2_trade_group_rpcs.sql)
- **Apply record:** [`g2_schema_apply_closeout.md`](./g2_schema_apply_closeout.md)

The migration's executable body is byte-identical to the reviewed packet; only the top
comment banner was updated from "review artifact / draft" to "applied" status. The duplicate
`.sql` under `artifacts/` was removed to avoid two divergent copies of the same DDL.
