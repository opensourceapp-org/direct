create table if not exists signal_rate (
  ip text primary key,
  window_start bigint not null,
  posts integer not null default 0,
  created integer not null default 0
);

create table if not exists signal_intro (
  from_id text not null,
  to_id text not null,
  last_seen timestamptz not null default now(),
  primary key (from_id, to_id)
);

create index if not exists signal_intro_seen on signal_intro (last_seen);
create index if not exists signal_rate_window on signal_rate (window_start);
