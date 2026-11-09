create table if not exists signal_sessions (
  id text primary key,
  nonce text not null default '',
  direct_id text,
  bundle text,
  watch text[] not null default '{}',
  hello_count integer not null default 0,
  last_seen timestamptz not null default now()
);

create table if not exists signal_peers (
  direct_id text primary key,
  bundle text not null,
  session_id text,
  closed_at timestamptz
);

create table if not exists signal_inbox (
  id bigserial primary key,
  session_id text not null,
  payload text not null,
  created_at timestamptz not null default now()
);

create index if not exists signal_inbox_session on signal_inbox (session_id, id);
create index if not exists signal_sessions_watch on signal_sessions using gin (watch);
