drop function update_agent_session_time(_id uuid, _time tstzrange);
drop function update_broker_session_time(_id uuid, _time tstzrange);
drop function close_stale_broker_sessions(_time timestamptz, _leeway interval);
drop function update_broker_session(_broker_id agent_id, _token bytea, _current timestamptz, _leeway interval);
drop function update_agent_session(_agent_id agent_id, _broker_id agent_id, _current timestamptz);