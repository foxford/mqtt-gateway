create function update_agent_session_time(_id uuid, _time tstzrange)
returns void as $$
    update session
        set time = _time
        where id = _id
$$ 
language sql volatile;

create function update_broker_session_time(_id uuid, _time tstzrange)
returns void as $$
declare
    _agent_session record;
begin
    -- Updating time of broker session
    perform update_agent_session_time(_id, _time);

    for _agent_session
        in select id, time
            from session
            where broker_session_id = _id
    loop
        -- Updating time of agents sessions
        perform update_agent_session_time(_agent_session.id, session_time_range(lower(_agent_session.time), upper(_time)));
    end loop;
end
$$ 
language plpgsql volatile;

create function close_stale_broker_sessions(_time timestamptz, _leeway interval)
returns void as $$
declare
    _session record;
begin
    -- Finding all stale broker sessions
    for _session in
        select id, time
            from broker_heartbeat as h
            inner join session as s on s.agent_id = h.broker_id
            where is_broker_session_stale(s.time, h.modified_at, _time - _leeway)
    loop
        perform update_broker_session_time(_session.id, session_time_range(lower(_session.time), _time));
    end loop;
end
$$ 
language plpgsql volatile;

create function update_broker_session(_broker_id agent_id, _token bytea, _current timestamptz, _leeway interval)
returns uuid as $$
declare
    _session record;
    _id uuid;
begin
    -- Finding a last broker session
    select s.id, s.time, h.token, h.modified_at into _session
        from broker_heartbeat as h
        inner join session as s on s.agent_id = h.broker_id
        where h.broker_id = _broker_id
        order by s.time desc
        limit 1;

    if _session is not null then
        if is_broker_session_stale(_session.time, _session.modified_at, _current - _leeway) or (_session.token != _token) then
            -- Closing the stale broker session
            perform update_broker_session_time(_session.id, session_time_range(lower(_session.time), _current));

            -- Creating a new broker session
            _id = gen_random_uuid();
            insert into session (id, broker_session_id, agent_id, time)
                values (_id, _id, _broker_id, session_time_range(_current));
        elsif (lower(_session.time) < _current) and (_session.token = _token) then
            -- Opening falsely closed broker session
            perform update_broker_session_time(_id, session_time_range(lower(_session.time)));
        else
            _id = _session.id;
        end if;
    else
        -- Creating a new session
        _id = gen_random_uuid();
        insert into session (id, broker_session_id, agent_id, time)
            values (_id, _id, _broker_id, session_time_range(_current));
    end if;

    -- Updating last heartbeat time
    insert into broker_heartbeat(broker_id, token, modified_at)
        values (_broker_id, _token, _current)
        on conflict (broker_id) do update
        set token = _token, modified_at = _current;

    -- Returning the active session id
    return _id;
end
$$ 
language plpgsql volatile;

create function update_agent_session(_agent_id agent_id, _broker_id agent_id, _current timestamptz)
returns uuid as $$
declare
    _id uuid;
    _broker_session_id uuid;
begin
    -- Finding an active agent session
    select id into _id
        from session
        where  upper_inf(time) and time @> _current and agent_id = _agent_id
        limit 1;

    if _id is null then
        -- Finding an active broker session
        select id into _broker_session_id
            from session
            where  upper_inf(time) and time @> _current and agent_id = _broker_id
            limit 1;

        if _broker_session_id is not null then
            insert into session (broker_session_id, agent_id, time)
                values (_broker_session_id, _agent_id, session_time_range(_current))
                returning id into _id;
        else
            raise exception 'missing active broker session'
                using detail = 'agent ' || _agent_id || ' trying to create a session within broker ' || _broker_id;
        end if;
    end if;

    -- Returning the active session id
    return _id;
end
$$ 
language plpgsql volatile;