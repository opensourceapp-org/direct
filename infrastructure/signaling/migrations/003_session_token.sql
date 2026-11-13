alter table signal_sessions
  add column if not exists token_hash text;
