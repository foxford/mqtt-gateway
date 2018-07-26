create function session_time_range(_created_at timestamptz)
returns tstzrange as $$
    select tstzrange(_created_at, null, '[)')
$$
language sql immutable;

create function session_time_range(_created_at timestamptz, _closed_at timestamptz)
returns tstzrange as $$
    select tstzrange(_created_at, _closed_at, '[)')
$$
language sql immutable;

create function is_broker_session_stale(_time tstzrange, _modified_at timestamptz, _stale_at timestamptz)
returns boolean as $$
    select upper_inf(_time) and (_modified_at < _stale_at);
$$ language sql immutable;