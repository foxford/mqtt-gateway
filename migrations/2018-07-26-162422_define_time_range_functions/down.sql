drop function session_time_range(_created_at timestamptz);
drop function session_time_range(_created_at timestamptz, _closed_at timestamptz);
drop function is_broker_session_stale(_time tstzrange, _modified_at timestamptz, _stale_at timestamptz);