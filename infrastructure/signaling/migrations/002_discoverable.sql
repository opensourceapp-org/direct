alter table signal_peers
  add column if not exists discoverable boolean not null default false;

create index if not exists signal_peers_discoverable
  on signal_peers (direct_id)
  where discoverable is true and session_id is not null;
